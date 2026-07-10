// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart' as xmlp;

import '../app_state.dart';
import '../config/api_keys.dart';
import '../models/product.dart';
import '../services/bulk_ocr_service.dart';
import '../user_state.dart';
import '../view_as_state.dart';
import '../util.dart';
import '../utils/render_log.dart';
import 'auth/login_screen.dart';

// ─── Loading step ─────────────────────────────────────────────────────────────

enum _LoadStep { idle, readingFile, aiAnalyzing, matching }

// ─── Data ─────────────────────────────────────────────────────────────────────

enum _MatchStatus { matched, partial, unrecognized, manuallyMatched }

class _MatchRow {
  final String lineItem;
  final int qty;
  _MatchStatus status;
  final List<Product> candidates;
  int selectedIndex;
  bool isHidden;
  bool isRetrying = false;
  _MatchStatus? _preHideStatus; // saved on hide, restored on unhide
  final String _displaySku;
  final String _displayPrice;
  final Rect? bbox;     // name_box_2d — drives the crop thumbnail
  Rect? lineBbox;       // whole-line box_2d — used for vertical clamp calculation only
  // Handwriting crop PNG (grayscale→alpha, black ink, transparent bg).
  // Set after canvas processing in _pickAndProcess; never serialized.
  Uint8List? processedCrop;

  // Product chosen via the per-line manual search field (overrides selectedIndex).
  Product? _manualProduct;
  // The product that was line-1 before the last manual pick (demoted to line-2).
  Product? _previousLine1;

  _MatchRow({
    required this.lineItem,
    required this.qty,
    required this.status,
    required this.candidates,
    this.selectedIndex = 0,
    this.isHidden = false,
    _MatchStatus? preHideStatus,
    String displaySku = 'No match found',
    String displayPrice = '-',
    this.bbox,
  })  : _preHideStatus = preHideStatus,
        _displaySku = displaySku,
        _displayPrice = displayPrice;

  void hide() {
    if (!isHidden) {
      _preHideStatus = status;
      isHidden = true;
    }
  }

  void unhide() {
    if (isHidden) {
      if (_preHideStatus != null) status = _preHideStatus!;
      _preHideStatus = null;
      isHidden = false;
    }
  }

  Product? get selectedProduct {
    if (_manualProduct != null) return _manualProduct;
    return candidates.isEmpty ? null : candidates[selectedIndex];
  }

  String get matchedSku {
    final p = selectedProduct;
    if (p != null) return p.packSize.isNotEmpty ? '${p.name} (${p.packSize})' : p.name;
    return _displaySku;
  }

  String get price => selectedProduct != null ? rupees(selectedProduct!.b2bPrice) : _displayPrice;

  Map<String, dynamic> toJson() => {
        'lineItem': lineItem,
        'qty': qty,
        'status': status.name,
        'selectedIndex': selectedIndex,
        'isHidden': isHidden,
        if (_preHideStatus != null) 'preHideStatus': _preHideStatus!.name,
        'candidates': candidates.map((p) => p.toJson()).toList(),
        if (_manualProduct != null) 'manualProduct': _manualProduct!.toJson(),
        if (_previousLine1 != null) 'previousLine1': _previousLine1!.toJson(),
        if (bbox     != null) 'bbox':     {'x': bbox!.left,     'y': bbox!.top,     'w': bbox!.width,     'h': bbox!.height},
        if (lineBbox != null) 'lineBbox': {'x': lineBbox!.left, 'y': lineBbox!.top, 'w': lineBbox!.width, 'h': lineBbox!.height},
      };

  factory _MatchRow.fromJson(Map<String, dynamic> m) {
    _MatchStatus? preHide;
    final preStr = m['preHideStatus'] as String?;
    if (preStr != null) {
      for (final s in _MatchStatus.values) {
        if (s.name == preStr) { preHide = s; break; }
      }
    }
    Rect? bbox;
    final bm = m['bbox'] as Map<String, dynamic>?;
    if (bm != null) {
      final bx = (bm['x'] as num?)?.toDouble() ?? 0;
      final by = (bm['y'] as num?)?.toDouble() ?? 0;
      final bw = (bm['w'] as num?)?.toDouble() ?? 0;
      final bh = (bm['h'] as num?)?.toDouble() ?? 0;
      if (bw > 0 && bh > 0) bbox = Rect.fromLTWH(bx, by, bw, bh);
    }
    final row = _MatchRow(
      lineItem: (m['lineItem'] as String?) ?? '',
      qty: (m['qty'] as int?) ?? 1,
      status: _MatchStatus.values.firstWhere(
        (s) => s.name == (m['status'] as String?),
        orElse: () => _MatchStatus.unrecognized,
      ),
      selectedIndex: (m['selectedIndex'] as int?) ?? 0,
      isHidden: (m['isHidden'] as bool?) ?? false,
      preHideStatus: preHide,
      candidates: (m['candidates'] as List<dynamic>?)
              ?.map((e) => Product.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      bbox: bbox,
    );
    final mp = m['manualProduct'] as Map<String, dynamic>?;
    if (mp != null) row._manualProduct = Product.fromJson(mp);
    final pl1 = m['previousLine1'] as Map<String, dynamic>?;
    if (pl1 != null) row._previousLine1 = Product.fromJson(pl1);
    final lm = m['lineBbox'] as Map<String, dynamic>?;
    if (lm != null) {
      final lx = (lm['x'] as num?)?.toDouble() ?? 0;
      final ly = (lm['y'] as num?)?.toDouble() ?? 0;
      final lw = (lm['w'] as num?)?.toDouble() ?? 0;
      final lh = (lm['h'] as num?)?.toDouble() ?? 0;
      if (lw > 0 && lh > 0) row.lineBbox = Rect.fromLTWH(lx, ly, lw, lh);
    }
    return row;
  }
}

// Sample rows for display before a file is uploaded.
// Candidates are empty so no dropdown; real matching runs on "Add to cart".
final _kSampleRows = <_MatchRow>[
  _MatchRow(lineItem: 'Augmentin 625',    qty: 5,  status: _MatchStatus.matched,  candidates: [], displaySku: 'Augmentin 625 Duo Tab (10s)',       displayPrice: '₹210.00'),
  _MatchRow(lineItem: 'Pan 40',           qty: 10, status: _MatchStatus.matched,  candidates: [], displaySku: 'Pan 40mg Tab (15s)',                 displayPrice: '₹96.50'),
  _MatchRow(lineItem: 'Dolo 650',         qty: 20, status: _MatchStatus.matched,  candidates: [], displaySku: 'Dolo 650mg Tab (15s)',               displayPrice: '₹58.36'),
  _MatchRow(lineItem: 'Metformin 500 SR', qty: 8,  status: _MatchStatus.matched,  candidates: [], displaySku: 'Glycomet 500 SR Tab (20s)',          displayPrice: '₹52.00'),
  _MatchRow(lineItem: 'Atorva 10',        qty: 6,  status: _MatchStatus.matched,  candidates: [], displaySku: 'Atorvastatin 10mg Tab (10s)',        displayPrice: '₹89.00'),
  _MatchRow(lineItem: 'Azithro 500',      qty: 4,  status: _MatchStatus.matched,  candidates: [], displaySku: 'Azithromycin 500mg Tab (5s)',        displayPrice: '₹75.40'),
  _MatchRow(lineItem: 'Montar LC',        qty: 5,  status: _MatchStatus.partial,  candidates: [], displaySku: 'Montelukast+Levo 5+2.5mg (10s)',     displayPrice: '₹148.80'),
  _MatchRow(lineItem: 'Vitamin D sachet', qty: 12, status: _MatchStatus.matched,  candidates: [], displaySku: 'D-Rise 60K IU Sachet',              displayPrice: '₹43.80'),
];

// ─── WhatsApp convert session ─────────────────────────────────────────────────

class _WaConvertSession {
  final Uint8List imageBytes;
  final String mimeType;
  final String imageName;
  final String imageId;
  final String userId;
  final String customerName;
  final String pharmacy;
  final String phone;
  final String address;
  final bool isApproved;
  const _WaConvertSession({
    required this.imageBytes,
    required this.mimeType,
    required this.imageName,
    required this.imageId,
    required this.userId,
    required this.customerName,
    required this.pharmacy,
    required this.phone,
    required this.address,
    required this.isApproved,
  });
}

// File-private callback registered by _BulkUploadScreenState so
// BulkUploadScreen.startWaConvert() can trigger it without a GlobalKey.
void Function()? _gWaConvertTrigger;

// ─── Screen ───────────────────────────────────────────────────────────────────

class BulkUploadScreen extends StatefulWidget {
  final List<({String name, int qty})>? preloadedItems;
  final String? preloadedTitle;
  const BulkUploadScreen({super.key, this.preloadedItems, this.preloadedTitle});

  // ── WA Convert API ──────────────────────────────────────────────────────────

  // Pending convert session (set before state picks it up).
  static _WaConvertSession? _pendingWaConvert;

  /// Registered by HomeShell to navigate to index 2 (BulkUploadScreen).
  static VoidCallback? navToBulkUpload;

  // CHANGE #323: shared WA-finalize hook — called by cart_screen after placing
  // any ViewAs order so source='whatsapp' + mark-done always run, even if the
  // user tapped the cart's "Place Order" instead of "Place WhatsApp Order".
  static Future<void> Function(String orderId)? onWaOrderPlaced;

  /// Called by the Convert-to-Order handler in admin_customer_screen.dart.
  /// Stores the session and triggers the already-live state to pick it up.
  static void startWaConvert({
    required Uint8List imageBytes,
    required String mimeType,
    required String imageName,
    required String imageId,
    required String userId,
    required String customerName,
    required String pharmacy,
    required String phone,
    required String address,
    required bool isApproved,
  }) {
    _pendingWaConvert = _WaConvertSession(
      imageBytes: imageBytes,
      mimeType: mimeType,
      imageName: imageName,
      imageId: imageId,
      userId: userId,
      customerName: customerName,
      pharmacy: pharmacy,
      phone: phone,
      address: address,
      isApproved: isApproved,
    );
    _gWaConvertTrigger?.call();
  }

  @override
  State<BulkUploadScreen> createState() => _BulkUploadScreenState();
}

class _BulkUploadScreenState extends State<BulkUploadScreen> {
  final ScrollController _scrollCtrl = ScrollController();
  List<_MatchRow> _rows = _kSampleRows;
  _LoadStep _step = _LoadStep.idle;
  int _matchProgress = 0;
  int _matchTotal = 0;
  bool _isFromFile = false;
  String? _fileName;
  bool _addingToCart = false;
  bool _isRetrying = false;
  double _retryProgress = 0.0;

  // ── CHANGE #322: WhatsApp Convert session ────────────────────────────────────
  _WaConvertSession? _waConvert;
  // Maps row index (as string) → productId that row last added to cart.
  // Enables precise per-row removal: when a row changes product, only ITS old
  // product is removed — nothing else is touched. Persisted with session.
  Map<String, String> _bulkLineItemMap = {};
  // Original image bytes/mime/size — live in screen State so they survive
  // layout breakpoint switches (web↔mobile), which can recreate child widget
  // States but never recreate _BulkUploadScreenState itself.
  Uint8List? _uploadedImageBytes;
  Size? _uploadedImageSize;
  String? _uploadedMimeType;
  // Shared crop scale: ONE value for ALL rows so every crop renders at the
  // same apparent handwriting size. Computed from median line height after OCR.
  double? _cropGlobalScale;

  // CHANGE #419: bulk OCR now runs as an app-level background job so it
  // survives tab switches / app restarts instead of dying with this State.
  // Inline (Bulk-tab-only) error banner — replaces the old global toast.
  String? _bulkOcrError;
  // Raw content + binary-ness of the file currently in flight, kept so the
  // BulkOcrService listener (which fires later, out of band) can still fall
  // back to local heuristic parsing on failure exactly like the old inline
  // try/catch did.
  String? _pendingRawContent;
  bool _pendingIsBinary = false;
  // Dedup guard so a 'done'/'error' job state is only applied once — needed
  // because resumeLatestIfAny() can re-observe the same finished job every
  // time the Bulk tab remounts.
  String? _lastAppliedOcrSignature;

  // Static (session-lifetime) cache of the last uploaded image.
  // Survives State recreation caused by GlobalKey reparenting failures,
  // navigation away-and-back, or any other rebuild path that calls initState.
  // Cleared on _clearSession so stale bytes don't bleed into a fresh upload.
  static Uint8List? _cachedImageBytes;
  static Size? _cachedImageSize;
  static String? _cachedMimeType;

  bool get _isLoading => _step != _LoadStep.idle;

  static const _kSessionKey = 'bulk_upload_session';
  static const _kImageKey = 'bulk_upload_image';
  static const _kImageMetaKey = 'bulk_upload_image_meta';

  Future<void> _saveImageToPrefs(Uint8List bytes, String mimeType, Size size) async {
    try {
      final b64 = base64Encode(bytes);
      if (b64.length > 6 * 1024 * 1024) return; // too large for localStorage
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kImageKey, b64);
      await prefs.setString(_kImageMetaKey,
          jsonEncode({'mime': mimeType, 'w': size.width, 'h': size.height}));
    } catch (e) {
      debugPrint('[ImgCache] Save failed: $e');
    }
  }

  Future<bool> _loadImageFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final b64 = prefs.getString(_kImageKey);
      final metaStr = prefs.getString(_kImageMetaKey);
      if (b64 == null || metaStr == null) return false;
      final bytes = base64Decode(b64);
      final meta = jsonDecode(metaStr) as Map<String, dynamic>;
      _uploadedImageBytes = bytes;
      _uploadedImageSize = Size(
          (meta['w'] as num).toDouble(), (meta['h'] as num).toDouble());
      _uploadedMimeType = (meta['mime'] as String?) ?? 'image/jpeg';
      _cachedImageBytes = bytes;
      _cachedImageSize = _uploadedImageSize;
      _cachedMimeType = _uploadedMimeType;
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _clearImageFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kImageKey);
      await prefs.remove(_kImageMetaKey);
    } catch (_) {}
  }

  @override
  void dispose() {
    if (_gWaConvertTrigger == _checkAndStartConvert) _gWaConvertTrigger = null;
    if (BulkUploadScreen.onWaOrderPlaced == _doWaFinalize) BulkUploadScreen.onWaOrderPlaced = null;
    BulkOcrService.instance.removeListener(_onBulkOcrChanged);
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    BulkOcrService.instance.addListener(_onBulkOcrChanged);
    // Covers app-close mid-processing: re-checks the DB for the latest job
    // so a still-running or just-finished OCR shows up without a fresh upload.
    BulkOcrService.instance.resumeLatestIfAny();
    _gWaConvertTrigger = _checkAndStartConvert;
    // Pick up any pending convert that was set before initState ran.
    if (BulkUploadScreen._pendingWaConvert != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkAndStartConvert();
      });
    } else if (widget.preloadedItems != null) {
      _loadPreloadedItems();
    } else {
      _loadSession();
    }
  }

  // Called by BulkUploadScreen.startWaConvert() when a convert request is pending.
  void _checkAndStartConvert() {
    final session = BulkUploadScreen._pendingWaConvert;
    if (session == null) return;
    BulkUploadScreen._pendingWaConvert = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startWaConvert(session);
    });
  }

  Future<void> _loadPreloadedItems() async {
    final items = widget.preloadedItems!;
    if (items.isEmpty) return;
    setState(() {
      _step = _LoadStep.matching;
      _matchTotal = items.length;
      _matchProgress = 0;
    });
    final names = items.map((i) => i.name).toList();
    final qtys = items.map((i) => i.qty).toList();
    final noBboxes = List<Rect?>.filled(items.length, null);
    final rows = await _bulkMatchRpc(names, qtys, noBboxes, noBboxes);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _isFromFile = true;
      _fileName = widget.preloadedTitle;
      _step = _LoadStep.idle;
      _bulkLineItemMap = {};
      _matchProgress = rows.length;
    });
  }

  // ── CHANGE #322/#323: WhatsApp Convert ─────────────────────────────────────

  Future<void> _startWaConvert(_WaConvertSession session) async {
    RenderLog.write('c322_bulk_preload', 'imageId:${session.imageId} user:${session.userId}');
    RenderLog.write('c323_wa_session', 'imageId:${session.imageId} userId:${session.userId}');
    await _clearSession();
    setState(() {
      _waConvert = session;
      // CHANGE #323: clear demo/prior rows immediately so they can never be
      // placed — they stay empty (loading spinner) until OCR match populates them.
      _rows = const [];
      _step = _LoadStep.readingFile;
      _fileName = session.imageName;
      _matchProgress = 0;
      _matchTotal = 0;
      _bulkLineItemMap = {};
      _isFromFile = true;
      _bulkOcrError = null;
    });
    // CHANGE #323: register hook so cart_screen can finalize the WA order
    // (source stamp + mark done) when the user taps cart Place Order.
    BulkUploadScreen.onWaOrderPlaced = _doWaFinalize;
    await _processImageBytesForConvert(session.imageBytes, session.mimeType, session.imageName);
  }

  // CHANGE #323/#324: WA finalize — stamp source + mark image done.
  Future<void> _doWaFinalize(String orderId) async {
    final session = _waConvert;
    if (session == null) return;
    RenderLog.write('c323_wa_finalize', 'imageId:${session.imageId} orderId:$orderId');
    String orderCode = orderId;
    try {
      final code = await Supabase.instance.client.rpc(
        'wa_set_order_source',
        params: {'p_order_id': orderId, 'p_source': 'whatsapp'},
      );
      if (code != null) orderCode = code.toString();
    } catch (_) {}
    try {
      await Supabase.instance.client.rpc(
        'wa_mark_image_done',
        params: {'p_image_id': session.imageId, 'p_order_code': orderCode},
      );
    } catch (_) {}
    // Unregister hook — session is now complete.
    BulkUploadScreen.onWaOrderPlaced = null;
    if (mounted) {
      setState(() {
        _waConvert = null;
        _bulkLineItemMap = {};
        _rows = _kSampleRows;
      });
    }
  }

  Future<void> _processImageBytesForConvert(
      Uint8List bytes, String mimeType, String imageName) async {
    final session = _waConvert;
    if (session == null) return;
    try {
      _uploadedImageBytes = bytes;
      _uploadedMimeType = mimeType;
      _uploadedImageSize = await _getImageSize(bytes, mimeType);
      _cachedImageBytes = bytes;
      _cachedImageSize = _uploadedImageSize;
      _cachedMimeType = mimeType;
      _saveImageToPrefs(bytes, mimeType, _uploadedImageSize!);
      RenderLog.write('c323_wa_image_loaded', 'bytes:${bytes.length} mime:$mimeType name:$imageName');

      setState(() => _step = _LoadStep.aiAnalyzing);
      final rawContent = 'IMAGE_BYTES:$mimeType:${base64Encode(bytes)}';
      _pendingRawContent = rawContent;
      _pendingIsBinary = true;
      // Fires _onBulkOcrChanged asynchronously when the job completes — even
      // if the user has since navigated away from Bulk.
      await _startOcrJob(rawContent);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _LoadStep.idle;
        _isFromFile = false;
        _fileName = null;
        _bulkLineItemMap = {};
        _bulkOcrError = _friendlyError(e);
      });
    }
  }

  /// Shared second-half of the file processing pipeline: parse bboxes,
  /// bulk-match, process crops, update rows.
  // CHANGE #381 — the whole OCR-already-done -> parse -> match sequence below
  // is wrapped in try/finally: whatever happens (chunk timeout, bad RPC shape,
  // unexpected exception), `finally` unconditionally clears the loading flag
  // so the UI can never stick on "Matching medicines…"/"AI is identifying
  // items…" forever. If there are zero parseable items, loading is cleared
  // immediately and the existing empty-state UI (via _isFromFile/_rows) shows.
  Future<void> _runMatchPipeline(
    List<Map<String, dynamic>> extracted,
    Uint8List? origImageBytes,
    Size? origImageSize,
    String origMimeType,
    String fileName,
  ) async {
    try {
      await _runMatchPipelineInner(
          extracted, origImageBytes, origImageSize, origMimeType, fileName);
    } finally {
      if (mounted && _step != _LoadStep.idle) {
        setState(() => _step = _LoadStep.idle);
      }
    }
  }

  Future<void> _runMatchPipelineInner(
    List<Map<String, dynamic>> extracted,
    Uint8List? origImageBytes,
    Size? origImageSize,
    String origMimeType,
    String fileName,
  ) async {
    final bNames = <String>[];
    final bQtys = <int>[];
    final bNameBboxes = <Rect?>[];
    final bLineBboxes = <Rect?>[];
    for (final item in extracted) {
      final name = item['name']?.toString().trim() ?? '';
      final qty = (int.tryParse(item['qty']?.toString() ?? '') ?? 1).clamp(1, 99999);
      if (name.isNotEmpty) {
        Rect? lineBbox;
        Rect? nameBbox;
        if (origImageSize != null) {
          Rect? parseBox(dynamic raw) {
            if (raw is! List || raw.length != 4) return null;
            final yMin = (raw[0] as num).toDouble() / 1000;
            final xMin = (raw[1] as num).toDouble() / 1000;
            final yMax = (raw[2] as num).toDouble() / 1000;
            final xMax = (raw[3] as num).toDouble() / 1000;
            final w = (xMax - xMin).clamp(0.0, 1.0);
            final h = (yMax - yMin).clamp(0.0, 1.0);
            return (w > 0 && h > 0) ? Rect.fromLTWH(xMin, yMin, w, h) : null;
          }
          lineBbox = parseBox(item['box_2d']);
          nameBbox = parseBox(item['name_box_2d']);
          if (nameBbox == null ||
              (lineBbox != null && nameBbox.width < lineBbox.width * 0.15)) {
            nameBbox = lineBbox;
          }
          if (lineBbox == null) {
            final bm = item['bbox'] as Map<String, dynamic>?;
            if (bm != null) {
              final bx = (bm['x'] as num?)?.toDouble() ?? 0;
              final by = (bm['y'] as num?)?.toDouble() ?? 0;
              final bw = (bm['w'] as num?)?.toDouble() ?? 0;
              final bh = (bm['h'] as num?)?.toDouble() ?? 0;
              if (bw > 0 && bh > 0) {
                lineBbox = Rect.fromLTWH(bx, by, bw, bh);
                nameBbox = lineBbox;
              }
            }
          }
        }
        bNames.add(name);
        bQtys.add(qty);
        bNameBboxes.add(nameBbox);
        bLineBboxes.add(lineBbox ?? nameBbox);
      }
    }
    if (!mounted) return;

    // CHANGE #381 — zero parseable items: clear loading immediately and show
    // the empty state rather than calling the matcher with nothing.
    if (bNames.isEmpty) {
      setState(() {
        _rows = const [];
        _isFromFile = true;
        _step = _LoadStep.idle;
        _bulkLineItemMap = {};
      });
      return;
    }

    final rows = await _bulkMatchRpc(bNames, bQtys, bNameBboxes, bLineBboxes);
    if (!mounted) return;
    setState(() => _matchProgress = rows.length);

    if (origImageBytes != null && origImageSize != null) {
      final imgEl = await _loadImageForProcessing(origImageBytes, origMimeType);
      if (imgEl != null) {
        final srcW = imgEl.naturalWidth;
        final srcH = imgEl.naturalHeight;
        const targetHeightPx = 46.0;
        final lineHeights = rows
            .where((r) => r.lineBbox != null)
            .map((r) => r.lineBbox!.height * srcH)
            .toList()..sort();
        double globalScale = 0.4;
        if (lineHeights.isNotEmpty) {
          final median = lineHeights[lineHeights.length ~/ 2];
          if (median > 0) globalScale = targetHeightPx / median;
        }
        _cropGlobalScale = globalScale;
        for (int ri = 0; ri < rows.length; ri++) {
          final row = rows[ri];
          if (row.bbox == null) continue;
          final lineBbox = row.lineBbox ?? row.bbox!;
          final prevLineBbox = ri > 0 ? (rows[ri - 1].lineBbox ?? rows[ri - 1].bbox) : null;
          final nextLineBbox = ri < rows.length - 1 ? (rows[ri + 1].lineBbox ?? rows[ri + 1].bbox) : null;
          row.processedCrop = _processOneCrop(
            imgEl, srcW, srcH, row.bbox!, lineBbox, globalScale,
            prevLineBbox: prevLineBbox, nextLineBbox: nextLineBbox,
          );
        }
      }
    }
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _isFromFile = true;
      _step = _LoadStep.idle;
      _bulkLineItemMap = {};
    });
    _saveSession();
    unawaited(_autoRetryUnrecognized());
  }

  Future<void> _loadSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSessionKey);
    if (raw == null) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final fileName = m['fileName'] as String?;
      final rows = (m['rows'] as List<dynamic>)
          .map((e) => _MatchRow.fromJson(e as Map<String, dynamic>))
          .toList();
      final lineItemMap = (m['bulkLineItemMap'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          {};
      final savedScale = (m['cropGlobalScale'] as num?)?.toDouble();
      if (rows.isNotEmpty && mounted) {
        setState(() {
          _rows = rows;
          _fileName = fileName;
          _isFromFile = true;
          _bulkLineItemMap = lineItemMap;
          if (savedScale != null) _cropGlobalScale = savedScale;
        });
        // Rehydrate image bytes: prefer static cache (survives layout reparent);
        // fall back to SharedPreferences (survives page refresh).
        if (_uploadedImageBytes == null && _cachedImageBytes != null) {
          _uploadedImageBytes = _cachedImageBytes;
          _uploadedImageSize = _cachedImageSize;
          _uploadedMimeType = _cachedMimeType ?? 'image/jpeg';
          debugPrint('[BulkUpload] Rehydrated ${_cachedImageBytes!.length} B image from static cache');
          _reprocessCropsFromCache();
        } else if (_uploadedImageBytes == null) {
          final loaded = await _loadImageFromPrefs();
          if (loaded && mounted) {
            debugPrint('[BulkUpload] Rehydrated ${_uploadedImageBytes!.length} B image from prefs');
            _reprocessCropsFromCache();
          }
        }
      }
    } catch (_) {}
  }

  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kSessionKey,
      jsonEncode({
        'fileName': _fileName,
        'rows': _rows.map((r) => r.toJson()).toList(),
        'bulkLineItemMap': _bulkLineItemMap,
        if (_cropGlobalScale != null) 'cropGlobalScale': _cropGlobalScale,
      }),
    );
  }

  Future<void> _clearSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessionKey);
    _cachedImageBytes = null;
    _cachedImageSize = null;
    _cachedMimeType = null;
    await _clearImageFromPrefs();
  }

  // Reprocesses crops for rows that have a bbox but no processedCrop yet.
  // Called after State rehydrates from the static image cache (i.e., after State
  // was recreated and _loadSession restored rows-with-bboxes but lost processedCrop).
  Future<void> _reprocessCropsFromCache() async {
    final bytes = _uploadedImageBytes;
    final mime = _uploadedMimeType ?? 'image/jpeg';
    if (bytes == null) return;
    final imgEl = await _loadImageForProcessing(bytes, mime);
    if (imgEl == null || !mounted) return;
    final srcW = imgEl.naturalWidth;
    final srcH = imgEl.naturalHeight;
    // Re-derive globalScale from restored rows if not already in state.
    double? gs = _cropGlobalScale;
    if (gs == null) {
      final heights = _rows
          .where((r) => r.lineBbox != null)
          .map((r) => r.lineBbox!.height * srcH)
          .toList()..sort();
      if (heights.isNotEmpty) {
        final median = heights[heights.length ~/ 2];
        if (median > 0) gs = 30.0 / median;
      }
    }
    if (gs == null) return;
    bool anyUpdated = false;
    for (int ri = 0; ri < _rows.length; ri++) {
      final row = _rows[ri];
      if (row.processedCrop == null && row.bbox != null) {
        row.processedCrop = _processOneCrop(
          imgEl, srcW, srcH, row.bbox!, row.lineBbox ?? row.bbox!, gs);
        debugPrint('[Crop] Reprocessed "${row.lineItem}" → ${row.processedCrop?.length ?? 0} B');
        anyUpdated = true;
      }
    }
    if (anyUpdated && mounted) setState(() {});
  }

  String get _loadingMessage {
    switch (_step) {
      case _LoadStep.readingFile:
        return '📂 Reading file...';
      case _LoadStep.aiAnalyzing:
        return '🤖 AI analyzing file structure...';
      case _LoadStep.matching:
        return '🔍 Matching medicines with database... ($_matchProgress/$_matchTotal)';
      case _LoadStep.idle:
        return '';
    }
  }

  // ── File picking & orchestration ───────────────────────────────────────────

  // CHANGE #312: camera button — web capture input, no native plugin.
  Future<void> _onCameraTap() async {
    try { RenderLog.write('c312_camera_tap', '1'); } catch (_) {}
    final input = html.FileUploadInputElement()
      ..accept = 'image/*'
      ..multiple = false;
    input.setAttribute('capture', 'environment');
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty) return;
    try { RenderLog.write('c312_camera_got', '1'); } catch (_) {}
    await _processHtmlFile(files.first);
  }

  // CHANGE #312: upload button — keeps existing accept list.
  Future<void> _pickAndProcess() async {
    try { RenderLog.write('c312_upload_tap', '1'); } catch (_) {}
    final input = html.FileUploadInputElement()
      ..accept = '.csv,.xlsx,.xls,.pdf,.ods,.tsv,.txt,.docx,.doc,.html,.htm,.jpg,.jpeg,.png,.webp,.heic,.heif,.gif'
      ..multiple = false;
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty) return;
    try { RenderLog.write('c312_upload_got', '1'); } catch (_) {}
    await _processHtmlFile(files.first);
  }

  // CHANGE #312: shared ingest entry — both camera and upload feed here.
  Future<void> _processHtmlFile(html.File file) async {
    try { RenderLog.write('c312_ingest_start', file.name); } catch (_) {}
    // Always start fresh — clear any stale session (including old bbox coordinates)
    // so the previous result never bleeds into the new upload's crop display.
    await _clearSession();

    setState(() {
      _step = _LoadStep.readingFile;
      _fileName = file.name;
      _matchProgress = 0;
      _matchTotal = 0;
      _bulkOcrError = null;
    });

    try {
      // Step 1: extract raw text / bytes from file
      final rawContent = await _getRawFileContent(file);

      // Step 2: Try AI; silently fall back to header-column matching on failure
      setState(() => _step = _LoadStep.aiAnalyzing);
      // CHANGE #316 item 3: auto-scroll to preview on mobile only.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final width = MediaQuery.of(context).size.width;
        if (width < 600) {
          try { RenderLog.write('c316_autoscroll_mobile', '1'); } catch (_) {}
          _scrollCtrl.animateTo(
            600,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeInOut,
          );
        }
      });
      final isBinary = rawContent.startsWith('PDF_BYTES:') ||
          rawContent.startsWith('IMAGE_BYTES:');
      // Structured spreadsheets have unambiguous column layout; parse locally
      // to avoid Gemini misidentifying the qty column as rate/amount/mrp.
      final fileExt = file.name.toLowerCase().split('.').last;
      final isStructuredSheet =
          const {'xlsx', 'xls', 'ods', 'csv', 'tsv'}.contains(fileExt);

      // Extract original image bytes + size. Stored in screen State (not in
      // rows) so they survive layout breakpoint switches without re-decoding.
      Uint8List? origImageBytes;
      Size? origImageSize;
      String origMimeType = 'image/jpeg';
      if (rawContent.startsWith('IMAGE_BYTES:')) {
        final withoutPrefix = rawContent.substring('IMAGE_BYTES:'.length);
        final colonIdx = withoutPrefix.indexOf(':');
        origMimeType = withoutPrefix.substring(0, colonIdx);
        final base64Data = withoutPrefix.substring(colonIdx + 1);
        origImageBytes = base64Decode(base64Data);
        origImageSize = await _getImageSize(origImageBytes, origMimeType);
        debugPrint('[BulkUpload] Original image: ${origImageSize?.width.toInt()}x${origImageSize?.height.toInt()}');
        _uploadedImageBytes = origImageBytes;
        _uploadedImageSize = origImageSize;
        _uploadedMimeType = origMimeType;
        // Populate static cache (survives layout reparent) and prefs (survives refresh).
        _cachedImageBytes = origImageBytes;
        _cachedImageSize = origImageSize;
        _cachedMimeType = origMimeType;
        _saveImageToPrefs(origImageBytes, origMimeType, origImageSize!);
      }

      if (isStructuredSheet) {
        final extracted = _extractWithFallback(rawContent);
        if (extracted.isEmpty) throw Exception('No medicine rows found in file');
        setState(() {
          _step = _LoadStep.matching;
          _matchTotal = extracted.length;
          _matchProgress = 0;
        });
        await _runMatchPipeline(extracted, origImageBytes, origImageSize, origMimeType, file.name);
        try { RenderLog.write('c312_ingest_done', file.name); } catch (_) {}
        return;
      }

      // Non-structured (image/PDF/plain-text) content — hand off to the
      // background OCR job. _onBulkOcrChanged() picks up the result later,
      // even if the user has since navigated away from the Bulk tab.
      _pendingRawContent = rawContent;
      _pendingIsBinary = isBinary;
      await _startOcrJob(rawContent);
      try { RenderLog.write('c312_ingest_done', file.name); } catch (_) {}
    } catch (e) {
      try { RenderLog.write('c312_ingest_err', e.toString().length > 80 ? e.toString().substring(0, 80) : e.toString()); } catch (_) {}
      if (!mounted) return;
      setState(() {
        _step = _LoadStep.idle;
        _isFromFile = false;
        _fileName = null;
        _bulkLineItemMap = {};
        _bulkOcrError = _friendlyError(e);
      });
      _clearSession();
    }
  }

  // ── Raw content extraction ─────────────────────────────────────────────────

  /// Converts any supported file to either a plain-text string (spreadsheets,
  /// CSV, TSV, TXT, DOCX) or a base64-prefixed string for images sent to Gemini.
  Future<String> _getRawFileContent(html.File file) async {
    final ext = file.name.toLowerCase().split('.').last;
    switch (ext) {
      case 'csv':
      case 'tsv':
      case 'txt':
      case 'html':
      case 'htm':
        return _readAsText(file);
      case 'pdf':
        final bytes = await _readBinaryBytes(file);
        // Try local text extraction first (works for typed PDFs)
        final localText = await _extractPdfText(bytes);
        if (localText.trim().length > 20) return localText;
        // Scanned/image PDF — send to Gemini
        return 'PDF_BYTES:${base64Encode(bytes)}';
      case 'xlsx':
      case 'xls':
        return _xlsxToRawText(file);
      case 'ods':
        return _odsToRawText(file);
      case 'docx':
        return _docxToRawText(file);
      case 'doc':
        return _docToRawText(file);
      case 'jpg':
      case 'jpeg':
        return 'IMAGE_BYTES:image/jpeg:${base64Encode(await _readBinaryBytes(file))}';
      case 'png':
        return 'IMAGE_BYTES:image/png:${base64Encode(await _readBinaryBytes(file))}';
      case 'webp':
        return 'IMAGE_BYTES:image/webp:${base64Encode(await _readBinaryBytes(file))}';
      case 'heic':
      case 'heif':
        return 'IMAGE_BYTES:image/heic:${base64Encode(await _readBinaryBytes(file))}';
      case 'gif':
        return 'IMAGE_BYTES:image/gif:${base64Encode(await _readBinaryBytes(file))}';
      default:
        // Try unknown format as plain text before giving up
        try {
          return await _readAsText(file);
        } catch (_) {
          throw Exception(
              'Format .$ext is not supported. Please use CSV, Excel, PDF, TXT, or DOCX.');
        }
    }
  }

  Future<String> _readAsText(html.File file) async {
    final reader = html.FileReader();
    reader.readAsText(file);
    await reader.onLoad.first;
    return (reader.result as String)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
  }

  Future<Uint8List> _readBinaryBytes(html.File file) async {
    final reader = html.FileReader();
    reader.readAsDataUrl(file);
    await reader.onLoad.first;
    final dataUrl = reader.result as String;
    return base64Decode(dataUrl.split(',').last);
  }

  /// Extracts plain text from a typed PDF using syncfusion. Returns empty string
  /// for scanned/image-only PDFs so caller can fall back to Gemini.
  Future<String> _extractPdfText(Uint8List bytes) async {
    try {
      final doc = PdfDocument(inputBytes: bytes);
      final extractor = PdfTextExtractor(doc);
      final text = extractor.extractText();
      doc.dispose();
      return text;
    } catch (_) {
      return '';
    }
  }

  /// Parses DOCX ZIP+XML structure and returns paragraph text as plain lines.
  Future<String> _docxToRawText(html.File file) async {
    final bytes = await _readBinaryBytes(file);

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw Exception('Could not open DOCX file. Make sure it is a valid Word document.');
    }

    ArchiveFile? docFile;
    for (final f in archive) {
      if (f.name.toLowerCase() == 'word/document.xml') {
        docFile = f;
        break;
      }
    }
    if (docFile == null) throw Exception('Not a valid DOCX file — document.xml missing.');

    final xmlStr = utf8.decode(docFile.content as List<int>);
    final doc = xmlp.XmlDocument.parse(xmlStr);

    final sb = StringBuffer();
    for (final para in doc.descendants
        .whereType<xmlp.XmlElement>()
        .where((e) => e.localName == 'p')) {
      final text = para.descendants
          .whereType<xmlp.XmlElement>()
          .where((e) => e.localName == 't')
          .map((e) => e.innerText)
          .join();
      if (text.trim().isNotEmpty) sb.writeln(text);
    }
    return sb.toString();
  }

  /// Extracts readable text from legacy binary .doc files.
  /// Tries plain-text read first (works for RTF-based .doc), then ASCII runs.
  Future<String> _docToRawText(html.File file) async {
    try {
      final text = await _readAsText(file);
      if (text.isNotEmpty) {
        final printable = text.codeUnits
            .where((c) => c >= 32 && c < 127 || c == 9 || c == 10 || c == 13)
            .length;
        final ratio = printable / text.length.clamp(1, 1 << 30);
        if (ratio > 0.70) {
          // RTF: strip control words and return plain text
          if (text.startsWith('{\\rtf')) {
            return text
                .replaceAll(RegExp(r'\\[a-z]+\d* ?'), '')
                .replaceAll(RegExp(r'\{[^{}]{0,200}\}'), '')
                .replaceAll(RegExp(r'[^\x20-\x7E\n\t]'), ' ')
                .trim();
          }
          return text;
        }
      }
    } catch (_) {}

    // Binary DOC: extract printable ASCII runs of ≥6 chars
    final bytes = await _readBinaryBytes(file);
    final sb = StringBuffer();
    int runStart = -1;
    for (int i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b >= 32 && b < 127) {
        if (runStart == -1) runStart = i;
      } else {
        if (runStart != -1 && i - runStart >= 6) {
          sb.writeln(String.fromCharCodes(bytes.sublist(runStart, i)));
        }
        runStart = -1;
      }
    }
    if (runStart != -1 && bytes.length - runStart >= 6) {
      sb.writeln(String.fromCharCodes(bytes.sublist(runStart)));
    }
    final result = sb.toString().trim();
    if (result.isEmpty) {
      throw Exception(
          'Could not read DOC file content. Please save as DOCX or CSV format.');
    }
    return result;
  }

  /// Parses XLSX ZIP+XML structure and returns all sheet data as tab-separated rows.
  Future<String> _xlsxToRawText(html.File file) async {
    final bytes = await _readBinaryBytes(file);

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw Exception('Excel file could not be opened. Save as .xlsx format (Excel 2007+).');
    }

    ArchiveFile? findFile(String path) {
      final lower = path.toLowerCase();
      for (final f in archive) {
        if (f.name.toLowerCase() == lower) return f;
      }
      return null;
    }

    // Build shared-strings table (t="s" cells reference this by index)
    final sharedStrings = <String>[];
    final ssFile = findFile('xl/sharedStrings.xml');
    if (ssFile != null) {
      try {
        final ssXml = utf8.decode(ssFile.content as List<int>);
        final doc = xmlp.XmlDocument.parse(ssXml);
        for (final si in doc.findAllElements('si')) {
          sharedStrings.add(si.findAllElements('t').map((t) => t.innerText).join());
        }
      } catch (_) {}
    }

    // Find the first sheet
    ArchiveFile? sheetFile;
    for (int n = 1; n <= 10; n++) {
      sheetFile = findFile('xl/worksheets/sheet$n.xml');
      if (sheetFile != null) break;
    }
    if (sheetFile == null) throw Exception('No worksheet found in Excel file.');

    final wsXml = utf8.decode(sheetFile.content as List<int>);
    final wsDoc = xmlp.XmlDocument.parse(wsXml);

    String? readCell(xmlp.XmlElement cell) {
      final t = cell.getAttribute('t');
      if (t == 'inlineStr') {
        return cell.findAllElements('t').map((e) => e.innerText).join();
      } else if (t == 's') {
        final v = cell.findElements('v').firstOrNull?.innerText;
        if (v == null) return null;
        final idx = int.tryParse(v);
        if (idx == null || idx >= sharedStrings.length) return null;
        return sharedStrings[idx];
      } else if (t == 'str') {
        return cell.findElements('v').firstOrNull?.innerText;
      } else {
        return cell.findElements('v').firstOrNull?.innerText;
      }
    }

    final sb = StringBuffer();
    for (final row in wsDoc.findAllElements('row')) {
      final cells = <String, String>{};
      for (final cell in row.findElements('c')) {
        final ref = cell.getAttribute('r') ?? '';
        final col = ref.replaceAll(RegExp(r'[0-9]'), '');
        if (col.isNotEmpty) cells[col] = readCell(cell) ?? '';
      }
      if (cells.isEmpty) continue;
      final cols = cells.keys.toList()..sort();
      sb.writeln(cols.map((c) => cells[c]!).join('\t'));
    }
    return sb.toString();
  }

  /// Parses ODS content.xml and returns all table data as tab-separated rows.
  Future<String> _odsToRawText(html.File file) async {
    final bytes = await _readBinaryBytes(file);

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw Exception('ODS file could not be opened.');
    }

    ArchiveFile? contentFile;
    for (final f in archive) {
      if (f.name.toLowerCase() == 'content.xml') {
        contentFile = f;
        break;
      }
    }
    if (contentFile == null) throw Exception('Not a valid ODS file — content.xml missing.');

    final xmlStr = utf8.decode(contentFile.content as List<int>);
    final doc = xmlp.XmlDocument.parse(xmlStr);

    String cellText(xmlp.XmlElement cell) {
      final paragraphs = cell.descendants
          .whereType<xmlp.XmlElement>()
          .where((e) => e.localName == 'p');
      if (paragraphs.isNotEmpty) {
        return paragraphs.map((e) => e.innerText).join(' ').trim();
      }
      for (final attr in cell.attributes) {
        if (attr.localName == 'value') return attr.value;
      }
      return '';
    }

    final tables = doc.descendants
        .whereType<xmlp.XmlElement>()
        .where((e) => e.localName == 'table');
    if (tables.isEmpty) throw Exception('No sheets found in ODS file.');

    final sb = StringBuffer();
    for (final row in tables.first.descendants
        .whereType<xmlp.XmlElement>()
        .where((e) => e.localName == 'table-row')) {
      final cells = row.children
          .whereType<xmlp.XmlElement>()
          .where((e) => e.localName == 'table-cell')
          .toList();
      if (cells.isEmpty) continue;
      sb.writeln(cells.map(cellText).join('\t'));
    }
    return sb.toString();
  }

  // ── Gemini AI extraction ──────────────────────────────────────────────────

  // Applies grayscale + contrast boost + resize to ≤1600px using HTML Canvas.
  // Falls back to the original bytes on any error.
  Future<String> _enhanceImageForOCR(String rawContent) async {
    final withoutPrefix = rawContent.substring('IMAGE_BYTES:'.length);
    final colonIdx = withoutPrefix.indexOf(':');
    final mimeType = withoutPrefix.substring(0, colonIdx);
    final base64Data = withoutPrefix.substring(colonIdx + 1);
    try {
      final bytes = base64Decode(base64Data);
      final blob = html.Blob([bytes], mimeType);
      final url = html.Url.createObjectUrlFromBlob(blob);
      final img = html.ImageElement()..src = url;
      await img.onLoad.first.timeout(const Duration(seconds: 10));
      html.Url.revokeObjectUrl(url);
      final srcW = img.naturalWidth;
      final srcH = img.naturalHeight;
      if (srcW == 0 || srcH == 0) throw Exception('image dimensions 0');
      const maxDim = 1600;
      int dstW = srcW, dstH = srcH;
      if (srcW > maxDim || srcH > maxDim) {
        final scale = maxDim / (srcW > srcH ? srcW : srcH);
        dstW = (srcW * scale).round();
        dstH = (srcH * scale).round();
      }
      final canvas = html.CanvasElement(width: dstW, height: dstH);
      final ctx = canvas.context2D;
      ctx.filter = 'grayscale(100%) contrast(160%) brightness(108%)';
      ctx.drawImageScaled(img, 0, 0, dstW.toDouble(), dstH.toDouble());
      final dataUrl = canvas.toDataUrl('image/jpeg', 0.92);
      final enhanced = 'IMAGE_BYTES:image/jpeg:${dataUrl.split(',').last}';
      debugPrint('[ImageEnhance] ${srcW}x$srcH → ${dstW}x$dstH, out=${enhanced.length} chars');
      return enhanced;
    } catch (e) {
      debugPrint('[ImageEnhance] Failed ($e) — using original');
      return rawContent;
    }
  }

  Future<Size?> _getImageSize(Uint8List bytes, String mimeType) async {
    try {
      final blob = html.Blob([bytes], mimeType);
      final url = html.Url.createObjectUrlFromBlob(blob);
      final img = html.ImageElement()..src = url;
      await img.onLoad.first.timeout(const Duration(seconds: 10));
      html.Url.revokeObjectUrl(url);
      final w = img.naturalWidth;
      final h = img.naturalHeight;
      if (w > 0 && h > 0) return Size(w.toDouble(), h.toDouble());
    } catch (e) {
      debugPrint('[ImageSize] Failed: $e');
    }
    return null;
  }

  // Loads original image bytes into an ImageElement for canvas processing.
  Future<html.ImageElement?> _loadImageForProcessing(Uint8List bytes, String mimeType) async {
    try {
      final blob = html.Blob([bytes], mimeType);
      final url = html.Url.createObjectUrlFromBlob(blob);
      final img = html.ImageElement()..src = url;
      await img.onLoad.first.timeout(const Duration(seconds: 15));
      html.Url.revokeObjectUrl(url);
      return img.naturalWidth > 0 ? img : null;
    } catch (e) {
      debugPrint('[CropLoad] Failed: $e');
      return null;
    }
  }

  /// Generates a crop PNG using a SHARED globalScale so every row's handwriting
  /// renders at the same apparent height.
  ///
  /// [nameBbox]  — name_box_2d (0–1): x left-anchor, gives first letter position.
  /// [lineBbox]    — box_2d (0–1): this line's vertical extent.
  /// [globalScale] — pixels-per-source-pixel, same value for every row.
  /// [prevLineBbox]/[nextLineBbox] — adjacent lines for midpoint-clamped erase.
  ///
  /// Output: height = round(actualSrcH * globalScale), width = name width at globalScale + margin.
  /// Generates a crop PNG using a SHARED globalScale so every row's handwriting
  /// renders at the same apparent height.
  ///
  /// CHANGE #381 — tightened to the medicine-NAME region only:
  ///   WIDTH:  uses [nameBbox]'s own right edge when Gemini gave a real
  ///           name-only box (narrower than the full line) — that edge IS the
  ///           qty-column boundary. Falls back to a fixed 65% of the line
  ///           width when Gemini collapsed name_box_2d to the full line.
  ///           Replaces the old ink-mask right-edge scan (#370-#373), which
  ///           could still pull in the qty column when no clean ink gap was
  ///           found.
  ///   HEIGHT: insets a little INTO this line's own y-range (not the old
  ///           outward pad) so ascenders/descenders from the line above/below
  ///           can never bleed in; the prev/next-line midpoint is kept as a
  ///           hard safety clamp.
  ///
  /// [nameBbox]    — name_box_2d (0–1): name text extent, if Gemini gave one.
  /// [lineBbox]    — box_2d (0–1): this line's full extent (name + qty).
  /// [globalScale] — pixels-per-source-pixel, same value for every row.
  /// [prevLineBbox]/[nextLineBbox] — adjacent lines, for the safety clamp.
  ///
  /// Output: original-colour PNG, no filter/threshold.
  Uint8List? _processOneCrop(
    html.ImageElement img, int srcW, int srcH,
    Rect nameBbox, Rect lineBbox, double globalScale, {
    Rect? prevLineBbox,
    Rect? nextLineBbox,
  }) {
    try {
      const leftPadPx = 3.0;      // output-px gap before first letter
      const rightPadFrac = 0.02;  // small right-side breathing room (line-width fraction)
      const insetFrac = 0.06;     // shave this fraction of line height off top/bottom

      // ── Vertical region — THIS line only, inset a little (never padded
      // outward) so neighbor ascenders/descenders can't bleed in. ───────────
      final lineH = lineBbox.height;
      double topFrac = lineBbox.top + lineH * insetFrac;
      double botFrac = lineBbox.bottom - lineH * insetFrac;
      if (botFrac <= topFrac) {
        topFrac = lineBbox.top;
        botFrac = lineBbox.bottom;
      }
      // Hard safety clamp: never cross the midpoint with the adjacent line.
      if (prevLineBbox != null) {
        final midAbove = (prevLineBbox.bottom + lineBbox.top) / 2.0;
        if (topFrac < midAbove) topFrac = midAbove;
      }
      if (nextLineBbox != null) {
        final midBelow = (lineBbox.bottom + nextLineBbox.top) / 2.0;
        if (botFrac > midBelow) botFrac = midBelow;
      }
      final srcTop = (topFrac * srcH).clamp(0.0, srcH.toDouble());
      final srcBot = (botFrac * srcH).clamp(0.0, srcH.toDouble());
      final actualSrcH = (srcBot - srcTop).clamp(1.0, srcH - srcTop);
      if (actualSrcH < 1) return null;

      // ── Horizontal region — name column only, qty column dropped. ────────
      // A real name_box_2d (meaningfully narrower than the full line) already
      // IS the name/qty column boundary from Gemini — trust it. Otherwise
      // (Gemini collapsed name_box_2d to the full line) fall back to a fixed
      // 65% of line width (ticket's 62–68% range).
      final hasRealNameBox = nameBbox.width < lineBbox.width * 0.9;
      final srcXStart = (nameBbox.left * srcW - leftPadPx / globalScale)
          .clamp(0.0, srcW.toDouble());
      final double nameRightFrac =
          hasRealNameBox ? nameBbox.right : lineBbox.left + lineBbox.width * 0.65;
      final srcXEnd = ((nameRightFrac + lineBbox.width * rightPadFrac) * srcW)
          .clamp(srcXStart + 1.0, srcW.toDouble());
      final cropSrcW = (srcXEnd - srcXStart).clamp(1.0, srcW - srcXStart);

      final outH = (actualSrcH * globalScale).round().clamp(4, 300);
      final outW = (cropSrcW * globalScale).round().clamp(10, 9999);

      // ── Draw ORIGINAL-COLOUR crop directly at output size (no binarization,
      // no ink-mask classification, no filter). ─────────────────────────────
      final canvas = html.CanvasElement(width: outW, height: outH);
      final ctx = canvas.context2D;
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, outW.toDouble(), outH.toDouble());
      ctx.imageSmoothingEnabled = true;
      ctx.drawImageScaledFromSource(
        img,
        srcXStart, srcTop, cropSrcW, actualSrcH,
        0, 0, outW.toDouble(), outH.toDouble(),
      );

      final dataUrl = canvas.toDataUrl('image/png');
      return base64Decode(dataUrl.split(',').last);
    } catch (e) {
      debugPrint('[CropProcess] Failed: $e');
      return null;
    }
  }

  static const _ocrEdgeFn =
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/gemini-ocr';

  // CHANGE #419: enqueues one bulk_ocr_jobs row and returns immediately — the
  // actual OCR result/error arrives later via BulkOcrService's polling and
  // is picked up by _onBulkOcrChanged(), so it survives navigating away from
  // the Bulk tab (or closing the app) while the job is still running.
  Future<void> _startOcrJob(String rawContent) async {
    final isPdf = rawContent.startsWith('PDF_BYTES:');
    final isImage = rawContent.startsWith('IMAGE_BYTES:');

    // Preprocess image once, exactly as the old direct-call path did.
    final content = isImage ? await _enhanceImageForOCR(rawContent) : rawContent;

    String imageBase64 = '';
    String mimeType = 'text/plain';
    String prompt;

    if (isImage) {
      final withoutPrefix = content.substring('IMAGE_BYTES:'.length);
      final colonIdx = withoutPrefix.indexOf(':');
      mimeType = withoutPrefix.substring(0, colonIdx);
      imageBase64 = withoutPrefix.substring(colonIdx + 1);
      prompt = _geminiImagePrompt;
    } else if (isPdf) {
      imageBase64 = content.substring('PDF_BYTES:'.length);
      mimeType = 'application/pdf';
      prompt = _geminiPrompt;
    } else {
      prompt = _geminiTextPrompt(content);
    }

    await BulkOcrService.instance.start(
      imageBase64: imageBase64,
      mimeType: mimeType,
      prompt: prompt,
      mode: null,
    );
  }

  // Parses the JSON items array out of job.result — the same string
  // gemini-ocr used to return as data['text'] (bare `[...]`, or the array
  // embedded inside `{"items": [...]}` for the image prompt).
  List<Map<String, dynamic>> _parseGeminiResponseText(String text) {
    if (text.isEmpty) return [];
    final match = RegExp(r'\[[\s\S]*\]').firstMatch(text);
    if (match == null) throw Exception('no_json_in_response');
    return (jsonDecode(match.group(0)!) as List).cast<Map<String, dynamic>>();
  }

  // Reacts to BulkOcrService state changes — fires even if the user has
  // navigated away from the Bulk tab (it stays alive in the IndexedStack) or
  // reopened the app mid-job (via resumeLatestIfAny in initState).
  void _onBulkOcrChanged() {
    if (!mounted) return;
    final st = BulkOcrService.instance.state;
    if (st.phase == 'processing') {
      if (_step == _LoadStep.idle) setState(() => _step = _LoadStep.aiAnalyzing);
      return;
    }
    if (st.phase == 'idle') return;

    // Only act once per finished job — resumeLatestIfAny() can re-observe
    // the same done/error row every time the Bulk tab remounts.
    final signature = st.phase == 'done' ? 'done:${st.result}' : 'error:${st.error}';
    if (signature == _lastAppliedOcrSignature) return;
    _lastAppliedOcrSignature = signature;

    if (st.phase == 'done') {
      _handleOcrDone(st.result ?? '');
    } else {
      _handleOcrFailure(Exception(st.error ?? 'AI failed'));
    }
  }

  Future<void> _handleOcrDone(String text) async {
    List<Map<String, dynamic>> extracted;
    try {
      extracted = _parseGeminiResponseText(text);
    } catch (e) {
      _handleOcrFailure(e);
      return;
    }

    if (extracted.isEmpty && _waConvert == null && !_pendingIsBinary &&
        _pendingRawContent != null) {
      extracted = _extractWithFallback(_pendingRawContent!);
    }
    if (extracted.isEmpty) {
      _handleOcrFailure(Exception(_waConvert != null
          ? 'No medicines found in image'
          : 'No medicine rows found in file'));
      return;
    }

    if (!mounted) return;
    setState(() {
      _step = _LoadStep.matching;
      _matchTotal = extracted.length;
      _matchProgress = 0;
    });
    await _runMatchPipeline(extracted, _uploadedImageBytes, _uploadedImageSize,
        _uploadedMimeType ?? 'image/jpeg', _fileName ?? '');
  }

  void _handleOcrFailure(Object e) {
    if (!mounted) return;
    if (_waConvert != null) {
      BulkUploadScreen.onWaOrderPlaced = null;
      setState(() {
        _waConvert = null;
        _bulkLineItemMap = {};
        _rows = _kSampleRows;
        _step = _LoadStep.idle;
        _bulkOcrError = _friendlyError(e);
      });
      return;
    }
    if (!_pendingIsBinary && _pendingRawContent != null) {
      final fallback = _extractWithFallback(_pendingRawContent!);
      if (fallback.isNotEmpty) {
        setState(() {
          _step = _LoadStep.matching;
          _matchTotal = fallback.length;
          _matchProgress = 0;
        });
        _runMatchPipeline(fallback, _uploadedImageBytes, _uploadedImageSize,
            _uploadedMimeType ?? 'image/jpeg', _fileName ?? '');
        return;
      }
    }
    setState(() {
      _step = _LoadStep.idle;
      _isFromFile = false;
      _fileName = null;
      _bulkLineItemMap = {};
      _bulkOcrError = _friendlyError(e);
    });
    _clearSession();
  }

  // Fallback parser for structured files (CSV/TSV/XLSX/ODS) and typed-PDF text.
  // Detects name + qty columns by header keywords, then by type inference.
  List<Map<String, dynamic>> _extractWithFallback(String rawContent) {
    final lines =
        rawContent.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];

    final sep = lines.first.contains('\t') ? '\t' : ',';
    final rows = lines
        .map((l) => l
            .split(sep)
            .map((c) => c.trim().replaceAll(RegExp(r'''^["']+|["']+$'''), ''))
            .toList())
        .toList();
    if (rows.isEmpty) return [];

    // PDF-extracted text has no tab/comma delimiters — use line-oriented parser.
    if (!rawContent.contains('\t') && !rawContent.contains(',')) {
      return _extractFromPdfTextLines(lines);
    }

    const namePatterns = [
      'medicine', 'product', 'name', 'drug', 'item', 'description',
      'salt', 'brand', 'particular', 'detail', 'dawa',
    ];
    const qtyPatterns = [
      'qty', 'quantity', 'count', 'units', 'pcs', 'pack',
      'nos', 'pieces', 'strips', 'boxes', 'tablet', 'req', 'demand',
    ];
    // Columns with these headers hold prices, not quantities — exclude them.
    const pricePatterns = [
      'rate', 'price', 'mrp', 'amount', 'value', 'total', 'cost',
      'discount', 'disc', 'net', 'tax', 'gst',
    ];
    const skipWords = ['total', 'subtotal', 'grand', 's.no', 'sl.', 'serial'];

    int nameCol = -1;
    int qtyCol = -1;
    int headerRow = -1;
    final priceColIndices = <int>{};

    // Scan up to first 5 rows to find the header row.
    for (int r = 0; r < rows.length.clamp(0, 5); r++) {
      int foundName = -1, foundQty = -1;
      for (int c = 0; c < rows[r].length; c++) {
        final cell = rows[r][c].toLowerCase().trim();
        if (cell.isEmpty) continue;
        if (pricePatterns.any((p) => cell.contains(p))) priceColIndices.add(c);
        if (foundName == -1 && namePatterns.any((p) => cell.contains(p))) {
          foundName = c;
        }
        // Accept as qty only if not also a price-like header.
        if (foundQty == -1 &&
            qtyPatterns.any((p) => cell.contains(p)) &&
            !pricePatterns.any((p) => cell.contains(p))) {
          foundQty = c;
        }
      }
      if (foundName != -1) {
        nameCol = foundName;
        qtyCol = foundQty;
        headerRow = r;
        break;
      }
    }

    // No structured header — fall back to line-by-line plain-text parsing.
    if (headerRow == -1 || nameCol == -1) {
      return _extractFromPlainTextLines(lines);
    }

    // If no qty column found by header name, try type inference on data rows.
    if (qtyCol == -1) {
      final dataRows = rows.length > headerRow + 1
          ? rows.sublist(headerRow + 1)
          : <List<String>>[];
      qtyCol = _inferQtyColumn(dataRows, nameCol, priceColIndices);
    }

    final result = <Map<String, dynamic>>[];
    for (int r = headerRow + 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.length <= nameCol) continue;
      final name = row[nameCol].trim();
      if (name.isEmpty || name.length < 2) continue;
      final nameLower = name.toLowerCase();
      // Skip total/serial/header rows.
      if (skipWords.any((s) => nameLower.contains(s))) continue;
      if (namePatterns.any((p) => nameLower == p)) continue;
      if (qtyPatterns.any((p) => nameLower == p)) continue;
      if (RegExp(r'^\d+\.?\s*$').hasMatch(name)) continue;

      int qty = 1;
      if (qtyCol >= 0 && qtyCol < row.length) {
        final raw = row[qtyCol].trim();
        // Excel stores integers as "5.0" — parse as double then truncate.
        final dv = double.tryParse(raw.replaceAll(',', ''));
        if (dv != null && dv >= 1 && dv <= 99999) {
          qty = dv.truncate();
        } else {
          final digits = raw.replaceAll(RegExp(r'[^\d]'), '');
          qty = int.tryParse(digits) ?? 1;
        }
      }
      result.add({'name': name, 'qty': qty.clamp(1, 99999)});
    }
    return result;
  }

  /// Parses plain-text order lists and WhatsApp exports line-by-line.
  /// Handles formats like "Medicine - 5", "Medicine x5", "5 Medicine", and
  /// "[date time] Name: Medicine x 5" (WhatsApp).
  List<Map<String, dynamic>> _extractFromPlainTextLines(List<String> lines) {
    final result = <Map<String, dynamic>>[];

    // Matches WhatsApp timestamp prefixes in both bracket and dash styles
    final whatsAppPattern = RegExp(
      r'(?:\[\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4},?\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AP]M)?\s*\]'
      r'|\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4},?\s+\d{1,2}:\d{2}(?::\d{2})?\s*[-–])'
      r'\s*[^:]+:\s*(.+)',
    );

    // "Medicine Name - 5" / "Medicine x 10" / "Medicine : 3"
    final qtyAtEnd = RegExp(r'^(.+?)(?:\s+[-–x×:]\s*|\s+)(\d{1,4})\s*$', caseSensitive: false);

    const skipPrefixes = [
      'total', 'subtotal', 'grand', 'date:', 'time:', 'regards', 'thanks',
      'hello', 'hi,', 'dear ', 'note:', 's.no', 'serial', 'sr.', 'from:', 'to:',
    ];

    for (var line in lines) {
      line = line.trim();
      if (line.length < 3) continue;

      // Strip WhatsApp timestamp and sender prefix
      final waMatch = whatsAppPattern.firstMatch(line);
      String work = waMatch != null ? waMatch.group(1)!.trim() : line;
      if (work.length < 2) continue;

      // Skip system/metadata lines
      if (skipPrefixes.any((s) => work.toLowerCase().startsWith(s))) continue;
      if (work.contains('end-to-end encrypted')) continue;
      if (RegExp(r'^\d+\.?\s*$').hasMatch(work)) continue; // bare number
      // Skip header-like lines that contain 2+ column-header keywords
      if (_isColumnHeaderLine(work)) continue;

      String name = work;
      int qty = 1;

      final endMatch = qtyAtEnd.firstMatch(work);
      if (endMatch != null) {
        final potentialName = endMatch.group(1)!.trim();
        final potentialQty = int.tryParse(endMatch.group(2)!);
        if (potentialQty != null &&
            potentialQty >= 1 &&
            potentialQty <= 9999 &&
            potentialName.length >= 2) {
          name = potentialName;
          qty = potentialQty;
        }
      }

      name = name.replaceAll(RegExp(r'[.,;:]+$'), '').trim();
      if (name.length >= 2) {
        result.add({'name': name, 'qty': qty.clamp(1, 99999)});
      }
    }
    return result;
  }

  /// Returns true when a line looks like a column header row (≥2 header keywords).
  /// Used to prevent "Product Name  Qty  Rate  Amount" from being ingested as a product.
  static bool _isColumnHeaderLine(String line) {
    const keywords = [
      'product', 'medicine', 'item', 'drug', 'description',
      'qty', 'quantity', 'rate', 'mrp', 'price', 'amount',
      's.no', 'serial', 'sr.', 'units', 'pack', 'strips',
    ];
    final lower = line.toLowerCase();
    final hits = keywords.where((k) => lower.contains(k)).length;
    return hits >= 2;
  }

  /// Identifies the quantity column by type inference when header matching fails.
  /// Prefers columns of small integers (1–9999) that are not price/rate columns.
  int _inferQtyColumn(
      List<List<String>> dataRows, int nameCol, Set<int> priceColIndices) {
    if (dataRows.isEmpty) return -1;
    final maxCols =
        dataRows.fold(0, (m, r) => r.length > m ? r.length : m);

    final smallIntCount = List.filled(maxCols, 0);
    final decimalCount = List.filled(maxCols, 0);
    final largeCount = List.filled(maxCols, 0);

    for (final row in dataRows) {
      for (int c = 0; c < row.length; c++) {
        if (c == nameCol) continue;
        final cell = row[c].replaceAll(',', '').trim();
        if (cell.isEmpty) continue;
        final num = double.tryParse(cell);
        if (num == null) continue;
        final isWhole = num == num.truncateToDouble();
        if (isWhole && num >= 1 && num <= 9999) {
          smallIntCount[c]++;
        } else {
          if (!isWhole) decimalCount[c]++;
          if (num > 9999) largeCount[c]++;
        }
      }
    }

    int bestCol = -1;
    int bestScore = 0;
    for (int c = 0; c < maxCols; c++) {
      if (c == nameCol) continue;
      if (priceColIndices.contains(c)) continue;
      if (smallIntCount[c] == 0) continue;
      // Penalise columns with many decimals or very large numbers.
      final score = smallIntCount[c] - decimalCount[c] * 2 - largeCount[c];
      if (score > bestScore) {
        bestScore = score;
        bestCol = c;
      }
    }
    return bestCol;
  }

  /// Handles PDF-extracted text where columns appear as one-value-per-line
  /// (e.g. "product_name\nquantity\nAugmentin 625\n5\nPan 40\n10\n...")
  /// OR as space-aligned columns on the same line
  /// (e.g. "Augmentin 625                  5").
  List<Map<String, dynamic>> _extractFromPdfTextLines(List<String> lines) {
    const nameKw = [
      'medicine', 'product', 'name', 'drug', 'item', 'description',
      'salt', 'brand', 'particular',
    ];
    const qtyKw = [
      'qty', 'quantity', 'units', 'pcs', 'pack', 'nos', 'pieces',
    ];
    const skipKw = ['total', 'subtotal', 'grand', 's.no', 'sl.', 'serial'];

    int headerIdx = -1;
    bool spaceAligned = false;

    for (int i = 0; i < lines.length.clamp(0, 6); i++) {
      final lower = lines[i].toLowerCase();
      final hasName = nameKw.any((k) => lower.contains(k));
      final hasQty = qtyKw.any((k) => lower.contains(k));
      if (hasName && hasQty) {
        headerIdx = i;
        spaceAligned = true;
        break;
      }
      if (hasName) {
        headerIdx = i;
        break;
      }
    }

    if (headerIdx == -1) return _extractFromPlainTextLines(lines);

    if (spaceAligned) {
      // e.g. "Augmentin 625                  5"
      final result = <Map<String, dynamic>>[];
      final pattern = RegExp(r'^(.+?)\s{2,}(\d+(?:\.\d*)?)\s*$');
      for (int i = headerIdx + 1; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.isEmpty || line.length < 2) continue;
        final lower = line.toLowerCase();
        if (skipKw.any((s) => lower.contains(s))) continue;
        if (_isColumnHeaderLine(line)) continue;
        if (RegExp(r'^\d+\.?\s*$').hasMatch(line)) continue;
        final m = pattern.firstMatch(line);
        if (m != null) {
          final name = m.group(1)!.trim();
          final dv = double.tryParse(m.group(2)!) ?? 1.0;
          if (name.length >= 2) {
            result.add({'name': name, 'qty': dv.truncate().clamp(1, 99999)});
          }
        } else if (line.length >= 2) {
          result.add({'name': line, 'qty': 1});
        }
      }
      if (result.isNotEmpty) return result;
      return _extractFromPlainTextLines(lines);
    }

    // Skip standalone qty-header lines after the name header
    // (e.g., "quantity" on its own line before the data).
    int start = headerIdx + 1;
    while (start < lines.length &&
        qtyKw.any((k) => lines[start].trim().toLowerCase() == k)) {
      start++;
    }

    final dataLines = lines.sublist(start);
    if (dataLines.isEmpty) return _extractFromPlainTextLines(lines);

    // Count pure-number lines to detect alternating name/number format.
    final pureNumCount = dataLines
        .where((l) => RegExp(r'^\d+\.?\d*\s*$').hasMatch(l.trim()))
        .length;

    // < 30 % pure-number lines → plain text "Name - qty" format
    if (pureNumCount < dataLines.length * 0.3) {
      return _extractFromPlainTextLines(lines);
    }

    // Alternating: "Augmentin 625" then "5" then "Pan 40" then "10" ...
    final result = <Map<String, dynamic>>[];
    int i = start;
    while (i < lines.length) {
      final line = lines[i].trim();
      if (line.isEmpty || line.length < 2) {
        i++;
        continue;
      }
      final lower = line.toLowerCase();
      if (skipKw.any((s) => lower.contains(s))) {
        i++;
        continue;
      }
      if (_isColumnHeaderLine(line)) {
        i++;
        continue;
      }
      if (RegExp(r'^\d+\.?\s*$').hasMatch(line)) {
        i++;
        continue; // orphan number
      }
      // Medicine name — look ahead for the qty line.
      int qty = 1;
      if (i + 1 < lines.length) {
        final next = lines[i + 1].trim();
        final dv = double.tryParse(next.replaceAll(',', ''));
        if (dv != null && dv >= 1 && dv <= 9999) {
          qty = dv.truncate();
          i++;
        }
      }
      result.add({'name': line, 'qty': qty.clamp(1, 99999)});
      i++;
    }
    return result.isNotEmpty ? result : _extractFromPlainTextLines(lines);
  }

  static const _geminiPrompt =
      'You are an expert Indian pharmacy procurement assistant. '
      'Extract ALL medicine/product names and their quantities from this order document.\n'
      'Return ONLY a valid JSON array — no explanation, no markdown:\n'
      '[{"name": "medicine name exactly as written", "qty": 5}]\n\n'
      'CRITICAL RULES:\n'
      '- PRESERVE THE ORIGINAL ORDER: return medicines in the exact same top-to-bottom '
      'sequence they appear in the document. Do NOT sort or reorder them.\n'
      '- SKIP the header row: any row whose cells are column labels like '
      '"Product", "Medicine", "Item", "Name", "Qty", "Quantity", "Rate", '
      '"MRP", "Price", "Amount", "S.No", "Serial", "Units", "Pack". '
      'Never return a header keyword as a medicine name.\n'
      '- SKIP total, subtotal, and grand total rows.\n'
      '- SKIP serial-number-only rows.\n'
      '- The QTY column contains small integers (1–9999). '
      'Do NOT confuse it with the Rate/MRP/Price/Amount column (larger values or decimals). '
      'Read each row\'s actual quantity from the qty/quantity column.\n'
      '- Keep medicine names with dosage (e.g. "Paracetamol 500mg").\n'
      '- Use qty=1 only when no quantity column exists at all.\n'
      '- Return EVERY medicine found.';

  static const _geminiImagePrompt =
      'You are reading a HANDWRITTEN medicine order list photographed at a pharmacy. '
      'Extract EVERY medicine/drug name entry visible.\n\n'
      'IGNORE: page header, shop name, date, phone number, ruled lines, totals.\n\n'
      'For each handwritten medicine line return one JSON object inside "items":\n'
      '- "name": full medicine entry as written (brand + strength + form).\n'
      '- "qty": order quantity integer (use 1 if not visible).\n'
      '- "box_2d": [ymin, xmin, ymax, xmax] 0-1000. Full line extent.\n'
      '- "name_box_2d": [ymin, xmin, ymax, xmax] 0-1000. Same y as box_2d. '
      'xmin = first letter of the DRUG NAME — skip any leading serial number '
      '(e.g. "1.", "2.", "3.") before the drug name. '
      'xmax = last letter of the complete product name including all descriptive words '
      '(e.g. include "Disintegrating Strip" in "Endosure 25mg Disintegrating Strip", '
      '"Total Plus" in "Candid Total Plus"). '
      'Exclude only clear trailing abbreviation ("tab","cap","inj") or pack number ("10T","10s").\n\n'
      'Return ONLY valid JSON:\n'
      '{"items": [{"name": "Augmentin 625 tab", "qty": 5, '
      '"box_2d": [120, 50, 155, 380], "name_box_2d": [120, 53, 155, 260]}, ...]}';

  static String _geminiTextPrompt(String content) =>
      'You are an expert Indian pharmacy procurement assistant.\n'
      'Below is raw content from a medicine order file (PDF, text, or Word document).\n'
      'Extract ALL medicine/product names and their actual quantities.\n\n'
      'CRITICAL RULES — follow exactly:\n'
      '0. PRESERVE ORDER: Return medicines in the exact top-to-bottom sequence they appear '
      'in the document. Do NOT sort, group, or reorder them in any way.\n'
      '1. HEADER ROW: Any row whose cells are column labels such as "Product", '
      '"Medicine", "Item", "Name", "Description", "Qty", "Quantity", "Rate", '
      '"MRP", "Price", "Amount", "Sr", "S.No", "Serial", "Units", "Pack" is a '
      'HEADER ROW. Do NOT include it. Never return a header keyword as a medicine name.\n'
      '2. SKIP these rows entirely: header rows, blank rows, total / subtotal / '
      'grand total rows, and serial-number-only rows.\n'
      '3. QTY vs PRICE: The quantity column holds small integers (typically 1–500). '
      'The rate / MRP / price / amount column holds larger numbers or decimals. '
      'Read qty ONLY from the quantity column — never from rate, MRP, price, or '
      'amount columns. A medicine ordered "5 times" has qty=5 even if its MRP is ₹210.\n'
      '4. If a Qty column exists, read each row\'s actual value — do NOT return '
      'qty=1 for every row unless quantities are truly absent from the file.\n'
      '5. If the content shows alternating lines of medicine names and numbers '
      '(e.g. "Augmentin 625\\n5\\nPan 40\\n10"), each number is the quantity for '
      'the medicine name immediately above it.\n'
      '6. Keep medicine names with their dosage (e.g. "Paracetamol 500mg", '
      '"Augmentin 625 Duo").\n'
      '7. Decode common abbreviations: PCM=Paracetamol, Aug=Augmentin, MTF=Metformin.\n\n'
      'File content:\n\n$content\n\n'
      'Return ONLY a valid JSON array, no markdown fences:\n'
      '[{"name":"Augmentin 625 Duo","qty":5},{"name":"Pan 40mg","qty":10}]';

  // ── Supabase matching ──────────────────────────────────────────────────────

  _MatchRow _rowFromBulkResult(String name, int qty, Map<String, dynamic> item, Rect? bbox) {
    final status = item['status'] as String? ?? 'none';
    final candidatesRaw = (item['candidates'] as List<dynamic>?) ?? [];
    final candidates = candidatesRaw
        .map((c) => Product.fromBulkMatch(c as Map<String, dynamic>))
        .toList();
    // "matched" → green, "partial" → amber, "none" with weak candidates → amber
    // (never show a dead "No match found" when candidates exist).
    // "none" with zero candidates → blank OCR text → auto-retry path.
    final _MatchStatus matchStatus;
    if (status == 'matched') {
      matchStatus = _MatchStatus.matched;
    } else if (status == 'partial' || candidates.isNotEmpty) {
      matchStatus = _MatchStatus.partial;
    } else {
      matchStatus = _MatchStatus.unrecognized;
    }
    return _MatchRow(
      lineItem: name,
      qty: qty,
      status: matchStatus,
      candidates: candidates,
      bbox: bbox,
    );
  }

  // CHANGE #381 — matches in chunks of 4 so the "Matching medicines…" bar can
  // advance in real, visible steps (see _matchProgress updates below driving
  // _TwoStageProgressBar's eased fill). Every chunk RPC is time-bounded so a
  // hung network call throws instead of freezing the UI forever (root cause
  // of #376's production freeze).
  //
  // CORRECTNESS GUARANTEE: the chunked accumulation must be byte-identical to
  // a single full-list call (bulk_match_items scores a subset identically —
  // backend fact). If chunking comes back empty/partial/errors for ANY
  // reason, that's discarded and ONE full-list bulk_match_items call is made
  // instead — so results are never lost or partial. Only if that single call
  // also fails do we fall back further to the slow per-row _matchOne loop
  // (pre-existing last-resort resiliency path, unchanged).
  static const int _kBulkMatchChunkSize = 4;
  static const Duration _kBulkMatchChunkTimeout = Duration(seconds: 25);

  Future<List<_MatchRow>> _bulkMatchRpc(
    List<String> names,
    List<int> qtys,
    List<Rect?> nameBboxes,
    List<Rect?> lineBboxes,
  ) async {
    if (names.isEmpty) return [];
    final total = names.length;

    // ── Attempt 1: chunked calls, 4 at a time, for a smooth progress bar. ────
    final chunked = <_MatchRow>[];
    bool chunkedComplete = false;
    try {
      for (int start = 0; start < total; start += _kBulkMatchChunkSize) {
        final end = (start + _kBulkMatchChunkSize).clamp(0, total);
        final chunkNames = names.sublist(start, end);
        final chunkQtys = qtys.sublist(start, end);
        final payload = List.generate(chunkNames.length,
            (i) => {'name': chunkNames[i], 'qty': chunkQtys[i].toString()});
        try { RenderLog.write('c320_bulk_uses_rpc', 'count:${chunkNames.length}'); } catch (_) {}
        try { RenderLog.write('c321_bulk_rpc', 'count:${chunkNames.length}'); } catch (_) {}
        final resp = await Supabase.instance.client
            .rpc('bulk_match_items', params: {'p_items': payload})
            .timeout(_kBulkMatchChunkTimeout);
        if (resp is! Map || resp['status'] != 'ok') {
          throw Exception('unexpected response shape');
        }
        final ri = (resp['items'] as List<dynamic>?) ?? [];
        if (ri.length < chunkNames.length) {
          throw Exception('short response: ${ri.length}/${chunkNames.length}');
        }
        for (int i = 0; i < chunkNames.length; i++) {
          final globalIdx = start + i;
          final row = _rowFromBulkResult(chunkNames[i], chunkQtys[i],
              ri[i] as Map<String, dynamic>, nameBboxes[globalIdx]);
          row.lineBbox = lineBboxes[globalIdx];
          chunked.add(row);
        }
        if (!mounted) return chunked;
        try {
          RenderLog.write('bulk_rebuilt_381', 'chunk_matched:${chunked.length}/$total');
        } catch (_) {}
        setState(() => _matchProgress = chunked.length);
      }
      chunkedComplete = chunked.length == total;
    } catch (e) {
      debugPrint('[BulkMatch] Chunked RPC failed after ${chunked.length}/$total rows: $e');
      chunkedComplete = false;
    }
    if (chunkedComplete) return chunked;

    // ── Attempt 2: ONE full-list call — guarantees results identical to a
    // single-shot match, never partial/lost. ─────────────────────────────────
    debugPrint('[BulkMatch] Chunked path incomplete (${chunked.length}/$total) '
        '— falling back to single full-list call');
    try {
      final payload = List.generate(
          total, (i) => {'name': names[i], 'qty': qtys[i].toString()});
      try { RenderLog.write('c320_bulk_uses_rpc', 'count:$total'); } catch (_) {}
      try { RenderLog.write('c321_bulk_rpc', 'count:$total'); } catch (_) {}
      final resp = await Supabase.instance.client
          .rpc('bulk_match_items', params: {'p_items': payload});
      if (resp is Map && resp['status'] == 'ok') {
        final ri = (resp['items'] as List<dynamic>?) ?? [];
        final rows = List.generate(total, (i) {
          final itemData =
              i < ri.length ? ri[i] as Map<String, dynamic> : <String, dynamic>{};
          final row = _rowFromBulkResult(names[i], qtys[i], itemData, nameBboxes[i]);
          row.lineBbox = lineBboxes[i];
          return row;
        });
        if (mounted) setState(() => _matchProgress = rows.length);
        return rows;
      }
      throw Exception('unexpected response shape');
    } catch (e) {
      // ── Attempt 3: last-resort per-row matching (pre-existing path). ──────
      debugPrint('[BulkMatch] Single-call fallback failed: $e — falling back to _matchOne per row');
      final rows = <_MatchRow>[];
      for (int i = 0; i < total; i++) {
        if (!mounted) return rows;
        final row = await _matchOne(names[i], qtys[i], bbox: nameBboxes[i]);
        row.lineBbox = lineBboxes[i];
        rows.add(row);
      }
      return rows;
    }
  }

  Future<_MatchRow> _matchOne(String name, int qty, {Rect? bbox}) async {
    // Strip punctuation noise common in handwritten/OCR orders:
    // • ,()*%  → always noise
    // • trailing/mid-word periods ("Tab.", "B. Cream", "Cap.") → abbreviation markers
    //   but preserve decimal points in dosage numbers ("30.5mg" → keep "." before digit)
    final term = name
        .replaceAll(RegExp(r'[,()*%]'), ' ')
        // Join single-letter abbreviation dots before generic period-strip so
        // "L.S." → "LS" and "E.R." → "ER" instead of "L S" / "E R".
        // This prevents "s" in "L.S." from falsely matching products containing "S"
        // (e.g. "Endogain-S") while keeping real "LS" tokens for correct matching.
        .replaceAll(RegExp(r'(?<=[A-Za-z])\.(?=[A-Za-z])'), '')
        .replaceAll(RegExp(r'\.(?!\d)'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (term.isEmpty) {
      return _MatchRow(lineItem: name, qty: qty, status: _MatchStatus.unrecognized, candidates: [], bbox: bbox);
    }
    try {
      final rawMatches = await _searchMedicineTop5(term);
      if (rawMatches.isEmpty) {
        return _MatchRow(lineItem: name, qty: qty, status: _MatchStatus.unrecognized, candidates: [], bbox: bbox);
      }
      final products = rawMatches.map((m) => Product.fromMap(m)).toList();
      final form = _detectDosageForm(term);
      double topScore = _stage2Score(term, products[0].name);
      if (form != null && _formMatches(products[0].name, form)) topScore += 0.02;
      // Substring promotion: normalized OCR term inside candidate name (or vice-versa)
      // catches exact-prefix matches like "renostrong" ⊂ "renostrong tablet".
      final qNorm = _normStr(term);
      final cNorm = _normStr(products[0].name);
      final isSubstring = qNorm.isNotEmpty && cNorm.isNotEmpty &&
          (cNorm.contains(qNorm) || qNorm.contains(cNorm));
      final _MatchStatus decidedStatus;
      if (isSubstring || topScore >= 0.72) {
        decidedStatus = _MatchStatus.matched;
      } else if (topScore >= 0.45) {
        decidedStatus = _MatchStatus.partial;
      } else {
        decidedStatus = _MatchStatus.unrecognized;
      }
      try { RenderLog.write('c315_match_decided', '${decidedStatus.name}:${topScore.toStringAsFixed(2)}'); } catch (_) {}
      return _MatchRow(
        lineItem: name,
        qty: qty,
        status: decidedStatus,
        candidates: products,
        bbox: bbox,
      );
    } catch (_) {
      return _MatchRow(lineItem: name, qty: qty, status: _MatchStatus.unrecognized, candidates: [], bbox: bbox);
    }
  }

  Future<List<Map<String, dynamic>>> _searchMedicineTop5(String name) async {
    final client = Supabase.instance.client;
    List<Map<String, dynamic>> list = [];

    // ── 1. Fetch up to 20 candidates ────────────────────────────────────────
    try {
      final rows = await client.rpc('search_medicines_priority', params: {
        'search_term': name,
        'category_filter': 'All',
        'page_offset': 0,
        'page_limit': 20,
      });
      list = List<Map<String, dynamic>>.from(rows as List);
      try { RenderLog.write('c315_automatch_rpc', list.length.toString()); } catch (_) {}
    } catch (e) {
      debugPrint('[FuzzyMatch] RPC failed for "$name": $e — falling back to ILIKE');
    }

    if (list.isEmpty) {
      try {
        final results = await client
            .from('MEDICINE')
            .select()
            .or('product_name.ilike.%$name%,salt_composition.ilike.%$name%,marketer.ilike.%$name%')
            .eq('status', 'Available')
            .order('sales_count', ascending: false)
            .limit(20);
        list = List<Map<String, dynamic>>.from(results);
      } catch (e) {
        debugPrint('[FuzzyMatch] ILIKE failed for "$name": $e');
      }
    }

    // ── 2. Filter to available/active products only ──────────────────────────
    // RPC may not return the status column; if absent treat the row as active.
    // No status filter: recognition matches any catalogued medicine regardless of
    // availability. SOLD OUT / inactive items still need to be identified so the
    // buyer knows what was on the order. Cart/fulfillment layers enforce stock.

    if (list.isEmpty) {
      debugPrint('[FuzzyMatch] 0 active candidates for "$name"');
      return list;
    }

    // ── 3. Detect dosage form for Stage-2 soft bonus ─────────────────────────
    final form = _detectDosageForm(name);
    debugPrint('[FuzzyMatch] query="$name" form=$form active=${list.length}');

    // ── 4. Stage 1 — fuzzy shortlist top-20 by trigram + edit-distance ─────────
    // _stage1Score = 55% trigram Jaccard + 45% edit-distance ratio (no chunk
    // weighting) so a single misread leading letter does not knock the correct
    // product out of the pool before Stage 2 can re-rank it.
    list.sort((a, b) {
      final na = (a['product_name'] as String?) ?? '';
      final nb = (b['product_name'] as String?) ?? '';
      return _stage1Score(name, nb).compareTo(_stage1Score(name, na));
    });
    final shortlist = list.take(20).toList();

    // ── 5. Stage 2 — rank shortlist by full-name similarity + form tiebreaker ──
    // Form bonus is capped at 0.02 so name similarity always dominates.
    shortlist.sort((a, b) {
      final na = (a['product_name'] as String?) ?? '';
      final nb = (b['product_name'] as String?) ?? '';
      double sa = _stage2Score(name, na);
      double sb = _stage2Score(name, nb);
      if (form != null) {
        if (_formMatches(na, form)) sa += 0.02;
        if (_formMatches(nb, form)) sb += 0.02;
      }
      return sb.compareTo(sa);
    });

    // Narrow to final top-5 (1 selected + 4 alternates shown in UI).
    final top5 = shortlist.take(5).toList();

    // ── 6. Debug — component breakdown matches _stage2Score formula exactly ───
    for (int i = 0; i < top5.length; i++) {
      final pName = (top5[i]['product_name'] as String?) ?? '?';
      final s1 = _stage1Score(name, pName);
      final dbQ = _normStr(name);
      final dbC = _normStr(pName);
      final dbML = dbQ.length > dbC.length ? dbQ.length : dbC.length;
      final dbEr = dbML == 0 ? 0.0 : 1.0 - _dlEditDistance(dbQ, dbC) / dbML;
      final dbQW = dbQ.split(' ').where((t) => t.isNotEmpty).toSet();
      final dbCW = dbC.split(' ').where((t) => t.isNotEmpty).toSet();
      final dbTj = dbQW.union(dbCW).isEmpty ? 0.0 : dbQW.intersection(dbCW).length / dbQW.union(dbCW).length;
      final dbTr = dbQW.isEmpty ? 0.0 : dbQW.where((t) => dbCW.contains(t)).length / dbQW.length;
      final dbQL = dbQ.split(' ').where((t) => t.isNotEmpty).toList();
      final dbCL = dbC.split(' ').where((t) => t.isNotEmpty).toList();
      final dbQF = dbQL.isEmpty ? '' : dbQL[0];
      final dbCF = dbCL.isEmpty ? '' : dbCL[0];
      final dbFML = dbQF.length > dbCF.length ? dbQF.length : dbCF.length;
      final dbPfx = dbFML == 0 ? 0.0 : 1.0 - _dlEditDistance(dbQF, dbCF) / dbFML;
      final dbQFT = _trigrams(dbQF);
      final dbCFT = _trigrams(dbCF);
      final dbFWU = dbQFT.union(dbCFT).length.toDouble();
      final dbFwt = dbFWU == 0 ? 0.0 : dbQFT.intersection(dbCFT).length / dbFWU;
      double s2 = 0.50 * dbEr + 0.12 * dbTj + 0.13 * dbTr + 0.20 * dbPfx + 0.05 * dbFwt;
      if (form != null && _formMatches(pName, form)) s2 += 0.02;
      debugPrint('[FuzzyMatch]  #${i + 1}'
          ' s1=${s1.toStringAsFixed(3)}'
          ' edit=${(0.50 * dbEr).toStringAsFixed(3)}'
          ' tok=${(0.12 * dbTj + 0.13 * dbTr).toStringAsFixed(3)}'
          ' pfx=${(0.20 * dbPfx).toStringAsFixed(3)}'
          ' fwt=${(0.05 * dbFwt).toStringAsFixed(3)}'
          ' final=${s2.toStringAsFixed(3)}'
          '  "$pName"');
    }

    return top5;
  }

  // ── Error messages ─────────────────────────────────────────────────────────

  String _friendlyError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('no medicine rows')) {
      return 'No medicine rows found in the file. Make sure the file contains medicine names.';
    }
    if (msg.contains('empty file')) return 'The file appears to be empty.';
    if (msg.contains('not configured') || msg.contains('no_api_key')) {
      return 'AI image processing is not configured. Please upload a CSV or Excel file instead.';
    }
    if (msg.contains('could not read medicines') || msg.contains('image unclear') ||
        msg.contains('no medicines detected')) {
      return e.toString().replaceFirst('Exception: ', '');
    }
    if (msg.contains('api error') || msg.contains('quota')) {
      return 'Something went wrong communicating with the AI service. Please try again in a moment.';
    }
    if (msg.contains('timeout') || msg.contains('socket') || msg.contains('network')) {
      return 'Network error — check your connection and try again.';
    }
    // All other throw sites use clear messages — pass them through directly
    final clean = e.toString().replaceFirst('Exception: ', '');
    if (clean.isNotEmpty) return clean;
    return 'Failed to process the file. Please try a different format (CSV, Excel, or text).';
  }

  // ── Cart ───────────────────────────────────────────────────────────────────

  Future<void> _addMatchedToCart() async {
    final cart = AppState.of(context);

    if (!_isFromFile) {
      // Sample demo flow — unchanged.
      setState(() => _addingToCart = true);
      try {
        final matchedRows = await Future.wait(
          _kSampleRows.map((row) => _matchOne(row.lineItem, row.qty)),
        );
        final entries = matchedRows
            .where((r) => r.selectedProduct != null)
            .map((r) => MapEntry(r.selectedProduct!, r.qty))
            .toList();
        if (!mounted) return;
        cart.addSampleItems(entries);
        showToast(context, '${entries.length} sample items added · auto-removed in 15s');
      } finally {
        if (mounted) setState(() => _addingToCart = false);
      }
      return;
    }

    // ── Real-file re-sync (per-row ownership) ─────────────────────────────
    // Each row owns the product it added. Compare old ownership → new ownership
    // to know exactly which old product to remove when a row changes its match.
    int addedCount = 0;
    int removedCount = 0;
    final newLineItemMap = <String, String>{};

    for (int i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      final key = i.toString();
      final oldProductId = _bulkLineItemMap[key];
      // Hidden rows: excluded from cart; remove if previously added.
      if (row.isHidden) {
        if (oldProductId != null) {
          cart.removeById(oldProductId);
          removedCount++;
        }
        continue;
      }

      final isMatched = (row.status == _MatchStatus.matched ||
              row.status == _MatchStatus.manuallyMatched) &&
          row.selectedProduct != null &&
          row.selectedProduct!.isBuyable; // Part D: hard-exclude NA (buyable=false) from cart

      if (isMatched) {
        final product = row.selectedProduct!;
        final newProductId = product.id;

        // Row changed its product: remove the old one first.
        if (oldProductId != null && oldProductId != newProductId) {
          cart.removeById(oldProductId);
          removedCount++;
        }

        // Always call setBulkQuantity for every matched row so the item is
        // guaranteed in the cart regardless of any stale-reload or race.
        // Count as "added" only when the product was genuinely absent (qty==0).
        // Uses row index so bulk ordering is preserved on re-add.
        // CHANGE #413: awaited so each row's write completes (and gets its
        // cart_items.id assigned) before the next row starts — sequential,
        // not parallel, so id order == bulk-upload list order.
        final priorQty = cart.quantityOf(newProductId);
        await cart.setBulkQuantity(product, row.qty, i);
        if (priorQty == 0) addedCount++;
        newLineItemMap[key] = newProductId;

      } else if (oldProductId != null) {
        // Row was previously synced but is now unmatched/partial — remove it.
        cart.removeById(oldProductId);
        removedCount++;
      }
    }

    setState(() => _bulkLineItemMap = newLineItemMap);
    _saveSession();

    if (mounted) {
      final String msg;
      if (addedCount > 0 && removedCount > 0) {
        msg = '$addedCount added, $removedCount removed from cart';
      } else if (addedCount > 0) {
        msg = '$addedCount medicines added to cart';
      } else if (removedCount > 0) {
        msg = '$removedCount medicines removed from cart';
      } else {
        msg = 'Cart is already up to date';
      }
      showToast(context, msg);
    }
  }

  void _onRowHideToggle(int rowIndex) {
    final row = _rows[rowIndex];
    if (row.isHidden) {
      // Row was just hidden — remove from cart if it was added.
      final productId = _bulkLineItemMap[rowIndex.toString()];
      if (productId != null) {
        AppState.of(context).removeById(productId);
        setState(() => _bulkLineItemMap.remove(rowIndex.toString()));
      }
    }
    _saveSession();
  }

  // ── Auto-retry unrecognized rows (CHANGE #316 item 4b) ───────────────────
  Future<void> _autoRetryUnrecognized() async {
    try { RenderLog.write('c316_autoretry_ran', '1'); } catch (_) {}
    try { RenderLog.write('c320_autoretry', '1'); } catch (_) {}
    for (int i = 0; i < _rows.length; i++) {
      if (!mounted) return;
      if (_rows[i].status != _MatchStatus.unrecognized) continue;
      for (int attempt = 0; attempt < 3; attempt++) {
        if (!mounted) return;
        if (_rows[i].status != _MatchStatus.unrecognized) break;
        if (mounted) setState(() => _rows[i].isRetrying = true);
        try { RenderLog.write('c321_autoretry_fired', 'row:$i'); } catch (_) {}
        await _retryOneRow(i, (_) {});
        if (!mounted) return;
      }
    }
  }

  // ── Retry matching ─────────────────────────────────────────────────────────
  // Re-runs stage1+stage2 on every non-manuallyMatched row using its stored
  // OCR text, without re-uploading the file.  Never downgrades a row's status
  // (matched stays matched; partial stays at least partial).
  Future<void> _retryMatch() async {
    if (_isRetrying || !_isFromFile) return;
    // Count rows that will actually be processed (skip manuallyMatched).
    final toProcess =
        _rows.where((r) => r.status != _MatchStatus.manuallyMatched).length;
    if (toProcess == 0) return;
    setState(() {
      _isRetrying = true;
      _retryProgress = 0.0;
    });
    int processed = 0;
    try {
      for (int i = 0; i < _rows.length; i++) {
        if (!mounted) break;
        final old = _rows[i];
        if (old.status == _MatchStatus.manuallyMatched) continue;

        String name = old.lineItem.trim();
        // Edge case: no OCR text but have image bbox — re-OCR the crop.
        if (name.isEmpty && old.bbox != null && _uploadedImageBytes != null) {
          name = await _reOcrOneLine(old.bbox!) ?? '';
        }

        if (name.isNotEmpty) {
          final fresh = await _matchOne(name, old.qty, bbox: old.bbox);

          // Determine best status — never downgrade.
          final _MatchStatus best;
          if (old.status == _MatchStatus.matched &&
              fresh.status != _MatchStatus.matched) {
            best = _MatchStatus.matched;
          } else if (old.status == _MatchStatus.partial &&
              fresh.status == _MatchStatus.unrecognized) {
            best = _MatchStatus.partial;
          } else {
            best = fresh.status;
          }

          final updated = _MatchRow(
            lineItem: name,
            qty: old.qty,
            status: best,
            candidates:
                fresh.candidates.isNotEmpty ? fresh.candidates : old.candidates,
            selectedIndex: 0,
            isHidden: old.isHidden,
            preHideStatus: old._preHideStatus,
            bbox: old.bbox,
          );
          updated.processedCrop = old.processedCrop;
          if (mounted) setState(() => _rows[i] = updated);
        }

        processed++;
        if (mounted) setState(() => _retryProgress = processed / toProcess);
      }
      // Hold the full ring briefly so the user sees 100% completion.
      if (mounted) await Future.delayed(const Duration(milliseconds: 500));
    } finally {
      if (mounted) setState(() => _isRetrying = false);
    }
    _saveSession();
  }

  // Crops a single bbox from the cached image and calls Gemini to read one line.
  // Only used when a row has an empty lineItem (network failure during OCR).
  Future<String?> _reOcrOneLine(Rect bbox) async {
    final bytes = _uploadedImageBytes;
    if (bytes == null) return null;
    try {
      final imgEl = await _loadImageForProcessing(
          bytes, _uploadedMimeType ?? 'image/jpeg');
      if (imgEl == null) return null;
      final srcW = imgEl.naturalWidth.toDouble();
      final srcH = imgEl.naturalHeight.toDouble();

      // Expand bbox slightly for OCR context.
      final left   = ((bbox.left   - bbox.width  * 0.05) * srcW).clamp(0.0, srcW);
      final top    = ((bbox.top    - bbox.height * 0.20) * srcH).clamp(0.0, srcH);
      final width  = ((bbox.width  * 1.10) * srcW).clamp(4.0, srcW - left);
      final height = ((bbox.height * 1.40) * srcH).clamp(4.0, srcH - top);

      final outW = width.round().clamp(10, 800);
      final outH = height.round().clamp(4, 200);
      final canvas = html.CanvasElement(width: outW, height: outH);
      final ctx = canvas.context2D;
      ctx.fillStyle = '#FFFFFF';
      ctx.fillRect(0, 0, outW.toDouble(), outH.toDouble());
      ctx.drawImageScaledFromSource(
          imgEl, left, top, width, height, 0, 0, outW.toDouble(), outH.toDouble());
      final base64Data = canvas.toDataUrl('image/jpeg', 0.9).split(',').last;

      final response = await http.post(
        Uri.parse(_ocrEdgeFn),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'image_base64': base64Data,
          'mime_type': 'image/jpeg',
          'prompt': 'This is a crop of ONE handwritten medicine name from a pharmacy '
              'order list. Read and return ONLY the medicine name as plain text. '
              'Best guess if unclear. No JSON, no explanation.',
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final text = data['text'] as String? ?? '';
      return text.trim().isNotEmpty ? text.trim() : null;
    } catch (e) {
      debugPrint('[RetryOCR] Failed: $e');
      return null;
    }
  }

  // Per-row retry: re-runs OCR (if needed) + stage1+stage2 for one row only.
  // Reports 0.0→1.0 progress via onProgress: 0.5 after OCR step, 1.0 at end.
  Future<void> _retryOneRow(
      int rowIndex, void Function(double) onProgress) async {
    if (rowIndex < 0 || rowIndex >= _rows.length) return;
    final old = _rows[rowIndex];
    String name = old.lineItem.trim();

    final needsOcr = name.isEmpty && old.bbox != null && _uploadedImageBytes != null;
    if (needsOcr) {
      name = await _reOcrOneLine(old.bbox!) ?? '';
      onProgress(0.5);
    }

    if (name.isEmpty) {
      onProgress(1.0);
      return;
    }

    _MatchRow fresh;
    try {
      try { RenderLog.write('c320_bulk_uses_rpc', 'retry'); } catch (_) {}
      try { RenderLog.write('c321_bulk_rpc', 'retry'); } catch (_) {}
      final payload = [{'name': name, 'qty': old.qty.toString()}];
      final resp = await Supabase.instance.client
          .rpc('bulk_match_items', params: {'p_items': payload});
      if (resp is Map && resp['status'] == 'ok') {
        final ri = (resp['items'] as List<dynamic>?) ?? [];
        final itemData = ri.isNotEmpty ? ri[0] as Map<String, dynamic> : <String, dynamic>{};
        fresh = _rowFromBulkResult(name, old.qty, itemData, old.bbox);
      } else {
        throw Exception('bad shape');
      }
    } catch (_) {
      fresh = await _matchOne(name, old.qty, bbox: old.bbox);
    }

    final _MatchStatus best;
    if (old.status == _MatchStatus.matched &&
        fresh.status != _MatchStatus.matched) {
      best = _MatchStatus.matched;
    } else if (old.status == _MatchStatus.partial &&
        fresh.status == _MatchStatus.unrecognized) {
      best = _MatchStatus.partial;
    } else {
      best = fresh.status;
    }

    final updated = _MatchRow(
      lineItem: name,
      qty: old.qty,
      status: best,
      candidates:
          fresh.candidates.isNotEmpty ? fresh.candidates : old.candidates,
      selectedIndex: 0,
      isHidden: old.isHidden,
      preHideStatus: old._preHideStatus,
      bbox: old.bbox,
    );
    updated.processedCrop = old.processedCrop;

    if (mounted) setState(() => _rows[rowIndex] = updated);
    onProgress(1.0);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scrollCtrl,
      child: Container(
        color: const Color(0xFFF9FAFB),
        width: double.infinity,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _PageHeader(),
                  if (_bulkOcrError != null) ...[
                    const SizedBox(height: 16),
                    _BulkOcrErrorBanner(
                      message: _bulkOcrError!,
                      onDismiss: () => setState(() => _bulkOcrError = null),
                    ),
                  ],
                  const SizedBox(height: 28),
                  _MainLayout(
                    rows: _rows,
                    isLoading: _isLoading,
                    loadingMessage: _loadingMessage,
                    matchProgress: _matchProgress,
                    matchTotal: _matchTotal,
                    isFromFile: _isFromFile,
                    fileName: _fileName,
                    addingToCart: _addingToCart,
                    onPickFile: _pickAndProcess,
                    onCamera: _onCameraTap,
                    onAddToCart: _addMatchedToCart,
                    onHideToggle: _onRowHideToggle,
                    uploadedImageSize: _uploadedImageSize,
                    onRetry: _retryMatch,
                    isRetrying: _isRetrying,
                    retryProgress: _retryProgress,
                    onRowRetry: _isFromFile ? _retryOneRow : null,
                  ),
                  // CHANGE #324: c324_wa_box_gone — WA convert box removed;
                  // cart drawer checkboxes now handle item selection + ordering.
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Inline OCR error banner (CHANGE #419 — replaces the old global toast) ───

class _BulkOcrErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;
  const _BulkOcrErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFCA5A5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: Color(0xFF991B1B), fontSize: 14),
            ),
          ),
          InkWell(
            onTap: onDismiss,
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.close, color: Color(0xFF991B1B), size: 18),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Page header ─────────────────────────────────────────────────────────────

class _PageHeader extends StatelessWidget {
  const _PageHeader();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final titleSize = constraints.maxWidth < 360
            ? 22.0
            : constraints.maxWidth < 600
                ? 26.0
                : 30.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Place Bulk Order',
              style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF111827)),
            ),
            const SizedBox(height: 6),
            const Text(
              "Choose how you'd like to send your order — WhatsApp for quick photo orders, or upload a file for smart SKU matching.",
              style: TextStyle(fontSize: 14, color: Color(0xFF6B7280), height: 1.5),
            ),
          ],
        );
      },
    );
  }
}

// ─── Main layout ─────────────────────────────────────────────────────────────

class _MainLayout extends StatelessWidget {
  final List<_MatchRow> rows;
  final bool isLoading;
  final String loadingMessage;
  final int matchProgress;
  final int matchTotal;
  final bool isFromFile;
  final String? fileName;
  final bool addingToCart;
  final VoidCallback onPickFile;
  final VoidCallback onCamera;
  final Future<void> Function() onAddToCart;
  final void Function(int rowIndex) onHideToggle;
  final Size? uploadedImageSize;
  final VoidCallback onRetry;
  final bool isRetrying;
  final double retryProgress;
  final Future<void> Function(int, void Function(double))? onRowRetry;

  const _MainLayout({
    required this.rows,
    required this.isLoading,
    required this.loadingMessage,
    required this.matchProgress,
    required this.matchTotal,
    required this.isFromFile,
    this.fileName,
    required this.addingToCart,
    required this.onPickFile,
    required this.onCamera,
    required this.onAddToCart,
    required this.onHideToggle,
    this.uploadedImageSize,
    required this.onRetry,
    required this.isRetrying,
    required this.retryProgress,
    this.onRowRetry,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 720) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Expanded(flex: 35, child: _WhatsAppCard(showGateNote: false)),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 35,
                    child: _UploadCard(
                      onPickFile: onPickFile,
                      onCamera: onCamera,
                      fileName: fileName,
                      isLoading: isLoading,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(flex: 30, child: _HowItWorksCard()),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SmartMatchSection(
              rows: rows,
              isLoading: isLoading,
              loadingMessage: loadingMessage,
              matchProgress: matchProgress,
              matchTotal: matchTotal,
              isFromFile: isFromFile,
              fileName: fileName,
              addingToCart: addingToCart,
              onAddToCart: onAddToCart,
              onHideToggle: onHideToggle,
              uploadedImageSize: uploadedImageSize,
              onRetry: onRetry,
              isRetrying: isRetrying,
              retryProgress: retryProgress,
              onRowRetry: onRowRetry,
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WhatsAppCard(),
          const SizedBox(height: 16),
          _UploadCard(onPickFile: onPickFile, onCamera: onCamera, fileName: fileName, isLoading: isLoading),
          const SizedBox(height: 16),
          const _HowItWorksCard(),
          const SizedBox(height: 16),
          _SmartMatchSection(
            rows: rows,
            isLoading: isLoading,
            loadingMessage: loadingMessage,
            matchProgress: matchProgress,
            matchTotal: matchTotal,
            isFromFile: isFromFile,
            fileName: fileName,
            addingToCart: addingToCart,
            onAddToCart: onAddToCart,
            onHideToggle: onHideToggle,
            uploadedImageSize: uploadedImageSize,
            onRetry: onRetry,
            isRetrying: isRetrying,
            retryProgress: retryProgress,
            onRowRetry: onRowRetry,
          ),
        ],
      );
    });
  }
}

// ─── WhatsApp card ────────────────────────────────────────────────────────────

class _WhatsAppCard extends StatelessWidget {
  final bool showGateNote;
  const _WhatsAppCard({this.showGateNote = true});

  void _openWhatsApp() {
    // CHANGE #400: mediBO's business number, short fixed message — no customer details.
    final msg = Uri.encodeComponent("Hello mediBO, I'm placing a new order. ✨");
    try { RenderLog.write('c400_wa_order_fixed', 'true'); } catch (_) {} // CHANGE #400
    html.window.open(
      'https://wa.me/919329252090?text=$msg',
      '_blank',
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    final canOrder = auth.canOrder;
    final isAuthenticated = auth.isAuthenticated;
    final isRegistered = auth.isRegistered;

    // Determine button label and gate message.
    final String btnLabel;
    final String? gateNote;
    final VoidCallback? onTap;
    if (canOrder) {
      btnLabel = 'Send Order on WhatsApp';
      gateNote = null;
      onTap = () => _openWhatsApp();
    } else if (!isAuthenticated) {
      btnLabel = 'Login to Send Order';
      gateNote = 'Login required to place orders';
      onTap = () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const LoginScreen()),
          );
    } else if (!isRegistered) {
      btnLabel = 'Complete Registration to Order';
      gateNote = 'Register your pharmacy to place orders';
      onTap = null;
    } else {
      btnLabel = 'Pending Approval';
      gateNote = 'Your account is pending admin approval';
      onTap = null;
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.withValues(alpha: 0.15), width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF16a34a), Color(0xFF15803d)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.20),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: SvgPicture.asset('assets/whatsapp.svg', fit: BoxFit.contain),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Send on WhatsApp',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Take a photo of your order list and send directly',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                color: Colors.white,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _Checklist(
                      items: const [
                        'Send photo of handwritten list',
                        'Your details sent automatically',
                        'Fastest way to order',
                      ],
                      iconColor: const Color(0xFF16A34A),
                      textColor: const Color(0xFF374151),
                    ),
                    const SizedBox(height: 48),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 52,
                          child: FilledButton(
                            onPressed: onTap,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF25D366),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xFF25D366),
                              disabledForegroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (canOrder) ...[
                                  SvgPicture.asset('assets/whatsapp.svg',
                                      width: 20, height: 20),
                                  const SizedBox(width: 8),
                                ] else
                                  const SizedBox(width: 0),
                                Flexible(
                                  child: Text(
                                    btnLabel,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (showGateNote && gateNote != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            gateNote,
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF9CA3AF)),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Upload card ─────────────────────────────────────────────────────────────

class _UploadCard extends StatelessWidget {
  final VoidCallback onPickFile;
  final VoidCallback onCamera;
  final String? fileName;
  final bool isLoading;

  const _UploadCard({
    required this.onPickFile,
    required this.onCamera,
    this.fileName,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    try { RenderLog.write('c312_bulk_built', '1'); } catch (_) {}
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.withValues(alpha: 0.15), width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1e2a3a), Color(0xFF253444)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    child: const Icon(Icons.cloud_upload_outlined, color: Colors.white, size: 26),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Upload Order File',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Upload any file — AI detects medicines automatically',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                color: Colors.white,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _Checklist(
                      items: const [
                        'Any format, any template supported',
                        'AI detects medicine names automatically',
                        'Review & add to cart in one click',
                      ],
                      iconColor: const Color(0xFF16A34A),
                      textColor: const Color(0xFF374151),
                    ),
                    const SizedBox(height: 48),
                    // CHANGE #312: split into Camera | Upload File buttons.
                    if (fileName != null && !isLoading)
                      SizedBox(
                        height: 52,
                        child: OutlinedButton.icon(
                          onPressed: onPickFile,
                          icon: const Icon(Icons.check_circle_outline,
                              size: 18, color: Color(0xFF16A34A)),
                          label: Text(
                            fileName!.length > 22
                                ? '${fileName!.substring(0, 19)}...'
                                : fileName!,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: Color(0xFF16A34A),
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFF16A34A)),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      )
                    else if (isLoading)
                      SizedBox(
                        height: 52,
                        child: FilledButton.icon(
                          onPressed: onPickFile,
                          icon: const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          ),
                          label: const Text('Processing…',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1e2a3a),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            elevation: 0,
                          ),
                        ),
                      )
                    else
                      Builder(
                        builder: (ctx) {
                          try { RenderLog.write('c312_split_wired', '1'); } catch (_) {}
                          return Row(
                            children: [
                              Expanded(
                                child: SizedBox(
                                  height: 52,
                                  child: FilledButton.icon(
                                    onPressed: onCamera,
                                    icon: const Icon(Icons.camera_alt_outlined, size: 18),
                                    label: const Text('Camera',
                                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFF1e2a3a),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(10)),
                                      elevation: 0,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: SizedBox(
                                  height: 52,
                                  child: FilledButton.icon(
                                    onPressed: onPickFile,
                                    icon: const Icon(Icons.upload_file_outlined, size: 18),
                                    label: const Text('Upload File',
                                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                                    style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFF1e2a3a),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(10)),
                                      elevation: 0,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── How It Works card ────────────────────────────────────────────────────────

class _HowItWorksCard extends StatelessWidget {
  const _HowItWorksCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1e2a3a),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.withValues(alpha: 0.15), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'HOW IT WORKS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Color(0xFF4ade80),
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Three steps to a packed cart.',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 24),
          const _Step(1, 'Drop your file.', 'AI detects columns & extracts medicines from any format.'),
          const _Step(2, 'Smart matcher pairs each line', 'to the best in-stock SKU.'),
          const _Step(3, 'Review, edit, and push to cart', 'in one click.'),
          Container(
            height: 1,
            margin: const EdgeInsets.symmetric(vertical: 14),
            color: Colors.white.withValues(alpha: 0.10),
          ),
          Text(
            'New here? Try a sample:',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 10),
          const _DemoDownloadRow(),
        ],
      ),
    );
  }
}

class _DemoDownloadRow extends StatelessWidget {
  const _DemoDownloadRow();

  // CHANGE #312: same-origin static files — instant download on all platforms.
  void _downloadDemoImage() {
    try { RenderLog.write('c312_demo_img_tap', '1'); } catch (_) {}
    final a = html.AnchorElement(href: '/demo/demo-order.jpg')
      ..download = 'demo-order.jpg'
      ..target = '_self';
    html.document.body!.append(a);
    a.click();
    a.remove();
  }

  void _downloadDemoExcel() {
    try { RenderLog.write('c312_demo_xls_tap', '1'); } catch (_) {}
    final a = html.AnchorElement(href: '/demo/demo-order.xlsx')
      ..download = 'demo-order.xlsx'
      ..target = '_self';
    html.document.body!.append(a);
    a.click();
    a.remove();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _DemoBtn(
            label: 'Demo image',
            icon: Icons.image_outlined,
            onTap: _downloadDemoImage,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _DemoBtn(
            label: 'Demo file (Excel)',
            icon: Icons.table_chart_outlined,
            onTap: _downloadDemoExcel,
          ),
        ),
      ],
    );
  }
}

class _DemoBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _DemoBtn({required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: Colors.white.withValues(alpha: 0.65)),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Colors.white.withValues(alpha: 0.80),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final String title;
  final String subtitle;
  const _Step(this.number, this.title, this.subtitle);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFF16A34A),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.55),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Template section ─────────────────────────────────────────────────────────

class _TemplateSection extends StatelessWidget {
  const _TemplateSection();

  void _downloadTemplate() {
    const csvContent = 'product_name,quantity\n'
        'Augmentin 625,5\n'
        'Pan 40,10\n'
        'Dolo 650,20\n'
        'Metformin 500 SR,8\n'
        'Atorva 10,6\n';
    final encoded = Uri.encodeComponent(csvContent);
    final anchor = html.AnchorElement()
      ..href = 'data:text/csv;charset=utf-8,$encoded'
      ..setAttribute('download', 'medibo_order_template.csv')
      ..click();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Need a sample?',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
          ),
          const SizedBox(height: 5),
          const Text(
            'Download our sample CSV to see example formatting. Any variation is accepted.',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280), height: 1.5),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _downloadTemplate,
              icon: const Icon(Icons.download_outlined, size: 15),
              label: const Text('Download sample .csv'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF374151),
                side: const BorderSide(color: Color(0xFFD1D5DB)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFDCFCE7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.auto_awesome, color: Color(0xFF16A34A), size: 16),
                const SizedBox(width: 8),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI-powered parsing',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF15803D),
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Works with any column order, any header name, any language. No fixed template required.',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFF166534), height: 1.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Two-stage animated progress bar (CHANGE #316 item 5) ────────────────────

class _TwoStageProgressBar extends StatefulWidget {
  final bool isOcrStage;
  final int matchProgress;
  final int matchTotal;

  const _TwoStageProgressBar({
    required this.isOcrStage,
    required this.matchProgress,
    required this.matchTotal,
  });

  @override
  State<_TwoStageProgressBar> createState() => _TwoStageProgressBarState();
}

// CHANGE #381 — the matching-stage bar eases toward each real
// matchProgress/matchTotal update (one per chunk, see _bulkMatchRpc) instead
// of jumping straight to the raw ratio, so a handful of chunk-sized steps
// reads as a smooth, continuous fill. The OCR stage keeps its original
// indeterminate animation (unaffected — matching only).
class _TwoStageProgressBarState extends State<_TwoStageProgressBar>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;
  bool _stage1Logged = false;
  bool _stage2Logged = false;
  // Last eased value shown for the matching-stage bar, so each new
  // matchProgress update eases FROM here rather than snapping.
  double _lastShownMatch = 0.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 7));
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.animateTo(0.88);
    _logStage();
  }

  void _logStage() {
    if (widget.isOcrStage && !_stage1Logged) {
      try { RenderLog.write('c316_progress_stage1', '1'); } catch (_) {}
      _stage1Logged = true;
    } else if (!widget.isOcrStage && !_stage2Logged) {
      try { RenderLog.write('c316_progress_stage2', '1'); } catch (_) {}
      _stage2Logged = true;
    }
  }

  @override
  void didUpdateWidget(_TwoStageProgressBar old) {
    super.didUpdateWidget(old);
    if (old.isOcrStage && !widget.isOcrStage) {
      _ctrl.value = 0;
      _ctrl.animateTo(0.88);
      _lastShownMatch = 0.0;
    }
    _logStage();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Widget _bar(double value) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: LinearProgressIndicator(
          value: value,
          backgroundColor: const Color(0xFFE5E7EB),
          valueColor: const AlwaysStoppedAnimation(Color(0xFF16A34A)),
          minHeight: 6,
        ),
      );

  Widget _label() => Text(
        widget.isOcrStage
            ? 'AI is identifying items…'
            : 'Matching medicines with database…',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
      );

  @override
  Widget build(BuildContext context) {
    if (!widget.isOcrStage && widget.matchTotal > 0) {
      final target = widget.matchProgress / widget.matchTotal;
      return TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: _lastShownMatch, end: target),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        builder: (ctx, v, child) {
          _lastShownMatch = v;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [_bar(v), const SizedBox(height: 10), _label()],
          );
        },
      );
    }
    return AnimatedBuilder(
      animation: _anim,
      builder: (ctx, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [_bar(_anim.value), const SizedBox(height: 10), _label()],
      ),
    );
  }
}

// ─── Smart match section ─────────────────────────────────────────────────────

class _SmartMatchSection extends StatefulWidget {
  final List<_MatchRow> rows;
  final bool isLoading;
  final String loadingMessage;
  final int matchProgress;
  final int matchTotal;
  final bool isFromFile;
  final String? fileName;
  final bool addingToCart;
  final Future<void> Function() onAddToCart;
  final void Function(int rowIndex) onHideToggle;
  final Size? uploadedImageSize;
  final VoidCallback onRetry;
  final bool isRetrying;
  final double retryProgress;
  final Future<void> Function(int, void Function(double))? onRowRetry;

  const _SmartMatchSection({
    required this.rows,
    required this.isLoading,
    required this.loadingMessage,
    required this.matchProgress,
    required this.matchTotal,
    required this.isFromFile,
    this.fileName,
    required this.addingToCart,
    required this.onAddToCart,
    required this.onHideToggle,
    this.uploadedImageSize,
    required this.onRetry,
    required this.isRetrying,
    required this.retryProgress,
    this.onRowRetry,
  });

  @override
  State<_SmartMatchSection> createState() => _SmartMatchSectionState();
}

class _SmartMatchSectionState extends State<_SmartMatchSection> {
  int? _expandedIndex;

  void _toggleRow(int index) {
    setState(() => _expandedIndex = _expandedIndex == index ? null : index);
  }

  void _onRowChanged() => setState(() {});

  void _onHideToggle(int index) {
    final row = widget.rows[index];
    if (row.isHidden) {
      row.unhide();
    } else {
      row.hide();
      // Collapse alternatives when hiding.
      if (_expandedIndex == index) _expandedIndex = null;
    }
    setState(() {});
    widget.onHideToggle(index);
  }

  @override
  Widget build(BuildContext context) {
    final matched = widget.rows.where((r) => r.status == _MatchStatus.matched).length;
    final manuallyMatched = widget.rows.where((r) => r.status == _MatchStatus.manuallyMatched).length;
    final partial = widget.rows.where((r) => r.status == _MatchStatus.partial).length;
    final unrecognized = widget.rows.where((r) => r.status == _MatchStatus.unrecognized).length;
    final canAdd = (matched + manuallyMatched) > 0 && !widget.addingToCart && !widget.isLoading;

    return LayoutBuilder(builder: (ctx, lc) {
      if (lc.maxWidth < 600) return _buildMobile(matched, manuallyMatched, partial, unrecognized, canAdd);
      return _buildWeb(matched, manuallyMatched, partial, unrecognized, canAdd);
    });
  }

  Widget _buildMobile(int matched, int manuallyMatched, int partial, int unrecognized, bool canAdd) {
    try { RenderLog.write('c314_preview_built', '1'); } catch (_) {}
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text('Smart match preview',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                    ),
                    if (widget.isFromFile)
                      _RetryIconButton(
                        isRetrying: widget.isRetrying,
                        retryProgress: widget.retryProgress,
                        enabled: !widget.isLoading && !widget.isRetrying,
                        onRetry: widget.onRetry,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Builder(builder: (_bCtx) {
                  try { RenderLog.write('c316_preview_built', '1'); } catch (_) {}
                  try { RenderLog.write('c316_badges_built', '1'); } catch (_) {}
                  int available = 0, needAttention = 0, unavailable = 0;
                  for (final r in widget.rows) {
                    if (r.isHidden) continue;
                    final ticked = r.status == _MatchStatus.matched || r.status == _MatchStatus.manuallyMatched;
                    if (ticked) {
                      available++;
                    } else if (r.status == _MatchStatus.partial) {
                      needAttention++;
                    } else {
                      unavailable++;
                    }
                  }
                  return Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _StatusPillBadge(
                        label: 'Available • $available item${available == 1 ? '' : 's'}',
                        bg: const Color(0xFFDCFCE7),
                        fg: const Color(0xFF15803D),
                      ),
                      if (needAttention > 0)
                        _StatusPillBadge(
                          label: 'Need attention • $needAttention item${needAttention == 1 ? '' : 's'}',
                          bg: const Color(0xFFFEF3C7),
                          fg: const Color(0xFF92400E),
                        ),
                      if (unavailable > 0)
                        _StatusPillBadge(
                          label: 'Unavailable • $unavailable item${unavailable == 1 ? '' : 's'}',
                          bg: const Color(0xFFFEE2E2),
                          fg: const Color(0xFFDC2626),
                        ),
                    ],
                  );
                }),
                const SizedBox(height: 10),
              ],
            ),
          ),
          if (widget.isLoading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: _TwoStageProgressBar(
                isOcrStage: widget.matchTotal == 0,
                matchProgress: widget.matchProgress,
                matchTotal: widget.matchTotal,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < widget.rows.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _MobileExpandableRow(
                        key: ValueKey('mob-$i'),
                        row: widget.rows[i],
                        index: i,
                        isExpanded: _expandedIndex == i,
                        onToggle: () => _toggleRow(i),
                        onRowChanged: _onRowChanged,
                        onHideToggle: () => _onHideToggle(i),
                        uploadedImageSize: widget.uploadedImageSize,
                        onRowRetry: widget.onRowRetry != null
                            ? (onProgress) => widget.onRowRetry!(i, onProgress)
                            : null,
                      ),
                    ),
                  const SizedBox(height: 4),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: FilledButton(
                      onPressed: canAdd ? () => widget.onAddToCart() : null,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: widget.addingToCart
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Add matched to cart', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWeb(int matched, int manuallyMatched, int partial, int unrecognized, bool canAdd) {
    // #403: desktop table STATUS+HIDE columns removed, grid aligned to shared
    // flex widths. Mobile path (_buildMobile) is untouched.
    try { RenderLog.write('c403_bulk_table_web_cleaned', 'true'); } catch (_) {}
    try { RenderLog.write('c404_bulk_headers_centered', 'true'); } catch (_) {}
    try { RenderLog.write('c405_bulk_mrp_status_cols', 'true'); } catch (_) {}
    try { RenderLog.write('c406_lineitem_widened', 'true'); } catch (_) {}
    final badge = widget.isFromFile
        ? (widget.fileName != null && widget.fileName!.length > 20
            ? '${widget.fileName!.substring(0, 17)}…'
            : widget.fileName ?? 'file')
        : 'sample';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: LayoutBuilder(
              builder: (_, lc) {
                final narrow = lc.maxWidth < 460;
                final badgeWidget = Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(4)),
                  child: Text(badge, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                );
                final addButton = FilledButton(
                  onPressed: canAdd ? () => widget.onAddToCart() : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 18, vertical: 10),
                    textStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: narrow ? 12 : 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  child: Text(narrow ? 'Add to cart' : 'Add matched to cart'),
                );
                final spinner = const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
                final statsText = Text(
                  widget.isLoading
                      ? widget.loadingMessage
                      : '$matched matched · $manuallyMatched manually matched · $partial partial · $unrecognized unrecognized',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                );
                // CHANGE #316 item 6: live availability badges.
                int availableCount = 0, needAttentionCount = 0, unavailableCount = 0;
                for (final r in widget.rows) {
                  if (r.isHidden) continue;
                  final ticked = r.status == _MatchStatus.matched || r.status == _MatchStatus.manuallyMatched;
                  if (ticked) {
                    availableCount++;
                  } else if (r.status == _MatchStatus.partial) {
                    needAttentionCount++;
                  } else {
                    unavailableCount++;
                  }
                }
                final liveBadges = Builder(builder: (_lb) {
                  try { RenderLog.write('c316_preview_built', '1'); } catch (_) {}
                  try { RenderLog.write('c316_badges_built', '1'); } catch (_) {}
                  return Wrap(spacing: 6, runSpacing: 4, children: [
                    _StatusPillBadge(
                      label: 'Available • $availableCount item${availableCount == 1 ? '' : 's'}',
                      bg: const Color(0xFFDCFCE7), fg: const Color(0xFF15803D),
                    ),
                    if (needAttentionCount > 0)
                      _StatusPillBadge(
                        label: 'Need attention • $needAttentionCount item${needAttentionCount == 1 ? '' : 's'}',
                        bg: const Color(0xFFFEF3C7), fg: const Color(0xFF92400E),
                      ),
                    if (unavailableCount > 0)
                      _StatusPillBadge(
                        label: 'Unavailable • $unavailableCount item${unavailableCount == 1 ? '' : 's'}',
                        bg: const Color(0xFFFEE2E2), fg: const Color(0xFFDC2626),
                      ),
                  ]);
                });
                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Flexible(
                          child: Text('Smart match preview',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 8),
                        badgeWidget,
                      ]),
                      const SizedBox(height: 8),
                      liveBadges,
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(child: statsText),
                        if (widget.isFromFile) ...[
                          const SizedBox(width: 4),
                          _RetryIconButton(
                            isRetrying: widget.isRetrying,
                            retryProgress: widget.retryProgress,
                            enabled: !widget.isLoading && !widget.isRetrying,
                            onRetry: widget.onRetry,
                          ),
                        ],
                        const SizedBox(width: 4),
                        widget.addingToCart ? spinner : addButton,
                      ]),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      const Text('Smart match preview',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                      const SizedBox(width: 8),
                      badgeWidget,
                      const Spacer(),
                      if (widget.isFromFile) ...[
                        _RetryIconButton(
                          isRetrying: widget.isRetrying,
                          retryProgress: widget.retryProgress,
                          enabled: !widget.isLoading && !widget.isRetrying,
                          onRetry: widget.onRetry,
                        ),
                        const SizedBox(width: 4),
                      ],
                      widget.addingToCart ? spinner : addButton,
                    ]),
                    const SizedBox(height: 4),
                    liveBadges,
                    const SizedBox(height: 4),
                    statsText,
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          if (widget.isLoading)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: _TwoStageProgressBar(
                    isOcrStage: widget.matchTotal == 0,
                    matchProgress: widget.matchProgress,
                    matchTotal: widget.matchTotal,
                  ),
                ),
              ),
            )
          else
            // #406: header + rows share one column-width set; wrapped in a
            // LayoutBuilder so a very narrow desktop window falls back to
            // horizontal scroll (min content width) instead of squeezing
            // cells illegibly. Mobile never reaches this (_buildMobile only).
            LayoutBuilder(builder: (context, tableLc) {
              const minTableWidth = 1000.0;
              final table = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    decoration: const BoxDecoration(
                      color: Color(0xFFF9FAFB),
                      border: Border(
                        top: BorderSide(color: Color(0xFFE5E7EB)),
                        bottom: BorderSide(color: Color(0xFFE5E7EB)),
                      ),
                    ),
                    // #406: LINE ITEM widened to be the dominant column
                    // (handwriting thumbnail legibility) with tighter
                    // inter-column gaps freeing up the room. Ratios shared
                    // verbatim with _ExpandableMatchRow's data row AND the
                    // alternative-row widgets so header and every row line
                    // up: LINE ITEM 50 : MATCHED SKU 30 : PACK 12 :
                    // COMPANY 22 : QTY 8 : MRP 13 : STATUS 20 : APPROVE 9.
                    // LINE ITEM/MATCHED SKU/COMPANY stay left (their values
                    // are left-aligned text/images); PACK/QTY/MRP/STATUS/
                    // APPROVE are centered to sit over their values.
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(flex: 50, child: Text('LINE ITEM', style: _kTh)),
                        SizedBox(width: 6),
                        Expanded(flex: 30, child: Text('MATCHED SKU', style: _kTh)),
                        SizedBox(width: 6),
                        Expanded(flex: 12, child: Text('PACK', textAlign: TextAlign.center, style: _kTh)),
                        SizedBox(width: 6),
                        Expanded(flex: 22, child: Text('COMPANY', style: _kTh)),
                        SizedBox(width: 6),
                        Expanded(flex: 8, child: Text('QTY', textAlign: TextAlign.center, style: _kTh)),
                        SizedBox(width: 6),
                        Expanded(flex: 13, child: Text('MRP', textAlign: TextAlign.center, style: _kTh)),
                        SizedBox(width: 6),
                        Expanded(flex: 20, child: Text('STATUS', textAlign: TextAlign.center, style: _kTh)),
                        SizedBox(width: 6),
                        Expanded(flex: 9, child: Text('APPROVE', textAlign: TextAlign.center, style: _kTh)),
                      ],
                    ),
                  ),
                  for (int i = 0; i < widget.rows.length; i++)
                    _ExpandableMatchRow(
                      key: ValueKey(i),
                      row: widget.rows[i],
                      index: i,
                      last: i == widget.rows.length - 1,
                      isExpanded: _expandedIndex == i,
                      onToggle: () => _toggleRow(i),
                      onRowChanged: _onRowChanged,
                      onHideToggle: () => _onHideToggle(i),
                      uploadedImageSize: widget.uploadedImageSize,
                      onRowRetry: widget.onRowRetry != null
                          ? (onProgress) => widget.onRowRetry!(i, onProgress)
                          : null,
                    ),
                ],
              );
              if (tableLc.maxWidth >= minTableWidth) return table;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: minTableWidth, child: table),
              );
            }),
        ],
      ),
    );
  }
}


/// Standard LINE ITEM renderer: shows the handwriting crop (constant height,
/// proportional width, smooth black strokes, transparent background, no caption).
/// Falls back to the digital parsed name only when no crop is available.
Widget _lineItemCrop(_MatchRow row, Size? imageSize,
    {TextStyle? fallbackStyle, BoxFit fit = BoxFit.scaleDown}) {
  // CHANGE #372 — appearance-only visibility fix for the original scanned
  // line (this element only). No OCR/matching/quantity/logic touched.
  try { RenderLog.write('bulk_lineitem_visible_372', row.processedCrop != null ? 'image' : 'text'); } catch (_) {}
  if (row.processedCrop != null) {
    try { RenderLog.write('bulk_rebuilt_381', 'crop_rendered'); } catch (_) {}
    final crop = row.processedCrop!;
    return Tooltip(
      message: row.lineItem,
      waitDuration: const Duration(milliseconds: 400),
      child: Builder(builder: (ctx) {
        try { RenderLog.write('c316_img_contain', '1'); } catch (_) {}
        // CHANGE #373 — no colour/threshold filter on the crop: render the
        // line-region crop in its true photographed colour (a prior change's
        // ColorFiltered contrast boost, #372, is removed here; the crop itself
        // is no longer binarized either — see _processOneCrop).
        try { RenderLog.write('crop_original_color_373', '1'); } catch (_) {}
        return FittedBox(
          fit: fit,
          alignment: Alignment.centerLeft,
          child: Image.memory(
            crop,
            filterQuality: FilterQuality.high,
            gaplessPlayback: true,
          ),
        );
      }),
    );
  }

  // Fallback: show digital parsed name so no row is ever blank.
  debugPrint('[CropFallback] "${row.lineItem}": no processedCrop '
      '(bbox=${row.bbox != null ? "ok" : "NULL"})');
  // CHANGE #372 — dark, high-contrast, larger/bolder default fallback style
  // (was light-grey 0xFF9CA3AF @ 13px); maxLines bumped 1 → 2 so a long
  // scanned line never clips to nothing.
  return Text(row.lineItem,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: fallbackStyle ??
          const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.black87));
}

const _kTh = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w600,
  color: Color(0xFF9CA3AF),
  letterSpacing: 0.5,
);

/// #404: shared availability pill (desktop) — used by the main match row's
/// AVAIL column and by every fuzzy-match/search alternative row, so a
/// candidate's `buyable` status is visible everywhere it's rendered.
class _AvailChip extends StatelessWidget {
  final bool available;
  const _AvailChip({required this.available});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: available ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(12),
      ),
      // #405: STATUS column must never clip "Not available" — no overflow
      // ellipsis; the column is sized wide enough for the full label.
      child: Text(
        available ? 'Available' : 'Not available',
        textAlign: TextAlign.center,
        maxLines: 1,
        softWrap: false,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: available ? const Color(0xFF15803D) : const Color(0xFFDC2626),
        ),
      ),
    );
  }
}

class _ExpandableMatchRow extends StatefulWidget {
  final _MatchRow row;
  final int index;
  final bool last;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onRowChanged;
  final VoidCallback onHideToggle;
  final Size? uploadedImageSize;
  final Future<void> Function(void Function(double))? onRowRetry;

  const _ExpandableMatchRow({
    super.key,
    required this.row,
    required this.index,
    required this.last,
    required this.isExpanded,
    required this.onToggle,
    required this.onRowChanged,
    required this.onHideToggle,
    this.uploadedImageSize,
    this.onRowRetry,
  });

  @override
  State<_ExpandableMatchRow> createState() => _ExpandableMatchRowState();
}

class _ExpandableMatchRowState extends State<_ExpandableMatchRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;
  bool _isRowRetrying = false;
  double _rowRetryProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: widget.isExpanded ? 1.0 : 0.0,
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void didUpdateWidget(_ExpandableMatchRow old) {
    super.didUpdateWidget(old);
    if (widget.isExpanded != old.isExpanded) {
      if (widget.isExpanded) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _doRowRetry() async {
    try { RenderLog.write('c316_rowretry_tap', '1'); } catch (_) {}
    if (_isRowRetrying || widget.onRowRetry == null) return;
    setState(() { _isRowRetrying = true; _rowRetryProgress = 0.0; });
    try {
      await widget.onRowRetry!((p) {
        if (mounted) setState(() => _rowRetryProgress = p);
      });
      if (mounted) await Future.delayed(const Duration(milliseconds: 500));
    } finally {
      if (mounted) setState(() => _isRowRetrying = false);
    }
    widget.onRowChanged();
  }

  void _toggleApproval() {
    final row = widget.row;
    if (row.status == _MatchStatus.unrecognized) return;
    if (row.selectedProduct?.isBuyable == false) return; // NA items cannot be ticked
    setState(() {
      if (row.status == _MatchStatus.matched) {
        // Untick a Matched row → Partial (unticked)
        row.status = _MatchStatus.partial;
      } else if (row.status == _MatchStatus.partial) {
        // Tick a Partial row → Manually Matched (ticked)
        row.status = _MatchStatus.manuallyMatched;
      } else if (row.status == _MatchStatus.manuallyMatched) {
        // Untick a Manually Matched row → Partial (unticked)
        row.status = _MatchStatus.partial;
      }
    });
    widget.onRowChanged();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final isEven = widget.index % 2 == 0;

    // #403: desktop STATUS chip removed — only the left border stripe color
    // (still keyed off match status/hidden) survives from this switch.
    final Color leftBorderColor;
    if (row.isHidden) {
      leftBorderColor = const Color(0xFFD1D5DB);
    } else {
      leftBorderColor = switch (row.status) {
        _MatchStatus.matched => const Color(0xFF15803D),
        _MatchStatus.manuallyMatched => const Color(0xFF3730A3),
        _MatchStatus.partial => const Color(0xFFEA580C),
        _MatchStatus.unrecognized => const Color(0xFFDC2626),
      };
    }

    final bottomBorder = (!widget.last || widget.isExpanded)
        ? const BorderSide(color: Color(0xFFEEEEEE))
        : BorderSide.none;

    // Ticked when Matched/ManuallyMatched AND product is available (AV).
    // NA (buyable=false) items are always unchecked+disabled regardless of match status.
    final selectedProd = row.selectedProduct;
    final isNa = selectedProd != null && !selectedProd.isBuyable;
    final isApproved = !isNa && (row.status == _MatchStatus.matched ||
        row.status == _MatchStatus.manuallyMatched);

    return Opacity(
      opacity: row.isHidden ? 0.45 : 1.0,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: !row.isHidden ? widget.onToggle : null,
          child: Container(
            decoration: BoxDecoration(
              color: isEven ? Colors.white : const Color(0xFFFAFAFA),
              border: Border(
                left: BorderSide(color: leftBorderColor, width: 3),
                bottom: bottomBorder,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(17, 12, 12, 12),
            // #406: LINE ITEM widened to be the dominant column (flex 50)
            // with tighter 6px gaps between the rest — ratios match the
            // header exactly (LINE ITEM 50 : MATCHED SKU 30 : PACK 12 :
            // COMPANY 22 : QTY 8 : MRP 13 : STATUS 20 : APPROVE 9).
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: 50,
                  child: SizedBox(
                    height: 76,
                    // #406: BoxFit.contain (vs scaleDown) lets the crop scale
                    // UP to fill the now-much-wider column, not just shrink.
                    child: _lineItemCrop(row, widget.uploadedImageSize, fit: BoxFit.contain),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 30,
                  child: Text(
                    row.selectedProduct?.name ??
                        (row.status != _MatchStatus.unrecognized ? row.matchedSku : '—'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: row.status != _MatchStatus.unrecognized
                          ? FontWeight.w600
                          : FontWeight.normal,
                      color: row.status != _MatchStatus.unrecognized
                          ? const Color(0xFF111827)
                          : const Color(0xFF9CA3AF),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 12,
                  child: Text(
                    row.selectedProduct != null ? _packShort(row.selectedProduct!) : '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF374151)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 22,
                  child: Text(
                    row.selectedProduct?.manufacturer ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 8,
                  child: Text('${row.qty}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
                ),
                const SizedBox(width: 6),
                // #405: MRP column — sits between QTY and STATUS.
                Expanded(
                  flex: 13,
                  child: Center(
                    child: Text(
                      row.selectedProduct != null && row.selectedProduct!.hasMrp
                          ? rupees(row.selectedProduct!.mrp)
                          : '—',
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF374151)),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 20,
                  // #404: centered under the STATUS header (was left-hugging the column).
                  child: Center(
                    child: Builder(builder: (_avCtx) {
                      try { RenderLog.write('c316_detail_avna', '1'); } catch (_) {}
                      final p = row.selectedProduct;
                      if (p == null) return const SizedBox.shrink();
                      return _AvailChip(available: p.isBuyable);
                    }),
                  ),
                ),
                const SizedBox(width: 6),
                // APPROVE column — per-row retry for unrecognized; checkbox for others
                Expanded(
                  flex: 9,
                  child: Center(
                    child: (row.status == _MatchStatus.unrecognized && !row.isHidden)
                        ? _isRowRetrying
                            ? SizedBox(
                                width: 18, height: 18,
                                child: CircularProgressIndicator(
                                  value: _rowRetryProgress,
                                  strokeWidth: 2,
                                  color: const Color(0xFFDC2626),
                                  backgroundColor: const Color(0xFFFEE2E2),
                                ),
                              )
                            : SizedBox(
                                width: 40, height: 40,
                                child: InkWell(
                                  onTap: widget.onRowRetry != null ? _doRowRetry : null,
                                  borderRadius: BorderRadius.circular(20),
                                  child: Icon(Icons.refresh, size: 16,
                                      color: widget.onRowRetry != null
                                          ? const Color(0xFFDC2626)
                                          : const Color(0xFF9CA3AF)),
                                ),
                              )
                        : GestureDetector(
                            onTap: (row.isHidden || isNa) ? null : _toggleApproval,
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: isApproved
                                  ? Container(
                                      width: 18, height: 18,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF16A34A),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Icon(Icons.check,
                                          size: 13, color: Colors.white),
                                    )
                                  : Builder(builder: (cbCtx) {
                                      if (isNa) try { RenderLog.write('c321_na_lock', 'desktop'); } catch (_) {}
                                      return Container(
                                        width: 18, height: 18,
                                        decoration: BoxDecoration(
                                          color: isNa ? const Color(0xFFF3F4F6) : Colors.white,
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(
                                              color: isNa ? const Color(0xFFD1D5DB) : const Color(0xFF9CA3AF),
                                              width: 1.5),
                                        ),
                                        child: isNa
                                          ? null
                                          : const Icon(Icons.check, size: 13, color: Color(0xFFD1D5DB)),
                                      );
                                    }),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SizeTransition(
          sizeFactor: _anim,
          child: Container(
            decoration: const BoxDecoration(
              border: Border(left: BorderSide(color: Color(0xFFE5E7EB), width: 3)),
            ),
            child: _MatchPanel(
              row: row,
              onRowChanged: () {
                widget.onToggle(); // collapse after pick
                widget.onRowChanged();
              },
            ),
          ),
        ),
      ],
    ),
    );
  }
}

// ─── Retry icon button ────────────────────────────────────────────────────────

class _RetryIconButton extends StatelessWidget {
  final bool isRetrying;
  final double retryProgress;
  final bool enabled;
  final VoidCallback onRetry;

  const _RetryIconButton({
    required this.isRetrying,
    required this.retryProgress,
    required this.enabled,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (isRetrying) {
      // Determinate ring: arc fills proportionally to rows processed.
      // value drives 0.0→1.0 arc; no text, no animation, pure fill.
      return SizedBox(
        width: 36,
        height: 36,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: CircularProgressIndicator(
            value: retryProgress,
            strokeWidth: 2.5,
            color: const Color(0xFF6B7280),
            backgroundColor: const Color(0xFFE5E7EB),
          ),
        ),
      );
    }
    return IconButton(
      icon: const Icon(Icons.refresh),
      onPressed: enabled ? onRetry : null,
      tooltip: 'Re-run matching',
      iconSize: 20,
      visualDensity: VisualDensity.compact,
      color: const Color(0xFF6B7280),
    );
  }
}

// ─── Status pill badge (mobile header) ───────────────────────────────────────

class _StatusPillBadge extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const _StatusPillBadge({required this.label, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

// ─── Mobile match card ────────────────────────────────────────────────────────

class _MobileExpandableRow extends StatefulWidget {
  final _MatchRow row;
  final int index;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onRowChanged;
  final VoidCallback onHideToggle;
  final Size? uploadedImageSize;
  final Future<void> Function(void Function(double))? onRowRetry;

  const _MobileExpandableRow({
    super.key,
    required this.row,
    required this.index,
    required this.isExpanded,
    required this.onToggle,
    required this.onRowChanged,
    required this.onHideToggle,
    this.uploadedImageSize,
    this.onRowRetry,
  });

  @override
  State<_MobileExpandableRow> createState() => _MobileExpandableRowState();
}

class _MobileExpandableRowState extends State<_MobileExpandableRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;
  bool _isRowRetrying = false;
  double _rowRetryProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: widget.isExpanded ? 1.0 : 0.0,
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void didUpdateWidget(_MobileExpandableRow old) {
    super.didUpdateWidget(old);
    if (widget.isExpanded != old.isExpanded) {
      widget.isExpanded ? _ctrl.forward() : _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _doRowRetry() async {
    try { RenderLog.write('c316_rowretry_tap', '1'); } catch (_) {}
    if (_isRowRetrying || widget.onRowRetry == null) return;
    setState(() { _isRowRetrying = true; _rowRetryProgress = 0.0; });
    try {
      await widget.onRowRetry!((p) {
        if (mounted) setState(() => _rowRetryProgress = p);
      });
      if (mounted) await Future.delayed(const Duration(milliseconds: 500));
    } finally {
      if (mounted) setState(() => _isRowRetrying = false);
    }
    widget.onRowChanged();
  }

  void _toggleApproval() {
    final row = widget.row;
    if (row.status == _MatchStatus.unrecognized) return;
    if (row.selectedProduct?.isBuyable == false) return; // NA items cannot be ticked
    setState(() {
      if (row.status == _MatchStatus.matched) {
        // Untick a Matched row → Partial (unticked)
        row.status = _MatchStatus.partial;
      } else if (row.status == _MatchStatus.partial) {
        // Tick a Partial row → Manually Matched (ticked)
        row.status = _MatchStatus.manuallyMatched;
      } else if (row.status == _MatchStatus.manuallyMatched) {
        // Untick a Manually Matched row → Partial (unticked)
        row.status = _MatchStatus.partial;
      }
    });
    widget.onRowChanged();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;

    // ignore: unused_local_variable
    Color badgeColor, badgeText, accentColor; // badgeColor/badgeText/label unused on mobile (#314 removed pill from mobile header)
    // ignore: unused_local_variable
    String label;
    if (row.isHidden) {
      badgeColor = const Color(0xFFF3F4F6);
      badgeText = const Color(0xFF9CA3AF);
      accentColor = const Color(0xFFD1D5DB);
      label = 'Hidden';
    } else {
      switch (row.status) {
        case _MatchStatus.matched:
          badgeColor = const Color(0xFFDCFCE7);
          badgeText = const Color(0xFF15803D);
          accentColor = const Color(0xFF15803D);
          label = 'Matched';
        case _MatchStatus.manuallyMatched:
          badgeColor = const Color(0xFFE0E7FF);
          badgeText = const Color(0xFF3730A3);
          accentColor = const Color(0xFF3730A3);
          label = 'Manually Matched';
        case _MatchStatus.partial:
          badgeColor = const Color(0xFFFEF3C7);
          badgeText = const Color(0xFF92400E);
          accentColor = const Color(0xFFEA580C);
          label = 'Partial';
        case _MatchStatus.unrecognized:
          badgeColor = const Color(0xFFFEE2E2);
          badgeText = const Color(0xFFDC2626);
          accentColor = const Color(0xFFDC2626);
          label = 'Unrecognized';
      }
    }

    final p = row.selectedProduct;
    final pack = p != null ? _packShort(p) : '';
    // Ticked when Matched/ManuallyMatched AND product is available (AV).
    // NA (buyable=false) items are always unchecked+disabled.
    final isNa = p != null && !p.isBuyable;
    final isApproved = !isNa && (row.status == _MatchStatus.matched ||
        row.status == _MatchStatus.manuallyMatched);

    return LayoutBuilder(builder: (context, _) {
      return Opacity(
        opacity: row.isHidden ? 0.45 : 1.0,
        child: GestureDetector(
          onTap: !row.isHidden ? widget.onToggle : null,
          child: Container(
            // Fill the full available width so controls are always at the right edge.
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE5E7EB)),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 1)),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: accentColor, width: 3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // ── Header row — CHANGE #314: slim layout [image|qty|checkbox] ──
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // Handwritten-crop image expands to fill all remaining width.
                              // CHANGE #372 — height bumped 24 → 48px (readable range for
                              // the scanned-line crop image; text/appearance only).
                              Expanded(
                                child: SizedBox(
                                  height: 48,
                                  child: _lineItemCrop(
                                      row,
                                      widget.uploadedImageSize,
                                      fallbackStyle: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF111827))),
                                ),
                              ),
                              // Controls cluster — qty then approve/refresh, no eye or pill.
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // c314_mobile_header_slim: ONLY in the mobile slimmed header build.
                                  Builder(builder: (ctx) {
                                    try { RenderLog.write('c314_mobile_header_slim', '1'); } catch (_) {}
                                    return const SizedBox.shrink();
                                  }),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 36,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF3F4F6),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: const Color(0xFFD1D5DB)),
                                      ),
                                      child: Text('${row.qty}',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w500,
                                              color: Color(0xFF374151))),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  // Approve cell: per-row retry for unrecognized rows,
                                  // normal checkbox for all other statuses.
                                  (row.status == _MatchStatus.unrecognized && !row.isHidden)
                                      ? (_isRowRetrying || row.isRetrying)
                                          ? SizedBox(
                                              width: 20, height: 20,
                                              child: CircularProgressIndicator(
                                                value: _rowRetryProgress,
                                                strokeWidth: 2,
                                                color: const Color(0xFFDC2626),
                                                backgroundColor: const Color(0xFFFEE2E2),
                                              ),
                                            )
                                          : SizedBox(
                                              width: 40, height: 40,
                                              child: InkWell(
                                                onTap: widget.onRowRetry != null ? _doRowRetry : null,
                                                borderRadius: BorderRadius.circular(20),
                                                child: Icon(Icons.refresh, size: 18,
                                                    color: widget.onRowRetry != null
                                                        ? const Color(0xFFDC2626)
                                                        : const Color(0xFF9CA3AF)),
                                              ),
                                            )
                                      : GestureDetector(
                                          onTap: (row.isHidden || isNa) ? null : _toggleApproval,
                                          behavior: HitTestBehavior.opaque,
                                          child: Padding(
                                            padding: const EdgeInsets.all(3),
                                            child: isApproved
                                                ? Container(
                                                    width: 20, height: 20,
                                                    decoration: BoxDecoration(
                                                      color: const Color(0xFF16A34A),
                                                      borderRadius: BorderRadius.circular(4),
                                                    ),
                                                    child: const Icon(Icons.check,
                                                        size: 14, color: Colors.white),
                                                  )
                                                : Builder(builder: (mcbCtx) {
                                                    if (isNa) try { RenderLog.write('c321_na_lock', 'mobile'); } catch (_) {}
                                                    return Container(
                                                      width: 20, height: 20,
                                                      decoration: BoxDecoration(
                                                        color: isNa ? const Color(0xFFF3F4F6) : Colors.white,
                                                        borderRadius: BorderRadius.circular(4),
                                                        border: Border.all(
                                                            color: isNa ? const Color(0xFFD1D5DB) : const Color(0xFF9CA3AF),
                                                            width: 1.5),
                                                      ),
                                                      child: isNa
                                                          ? null
                                                          : const Icon(Icons.check, size: 14, color: Color(0xFFD1D5DB)),
                                                    );
                                                  }),
                                          ),
                                        ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const Divider(height: 1, thickness: 1, color: Color(0xFFE5E7EB)),
                        // ── Selected matched product ─────────────────────────
                        Padding(
                          padding: const EdgeInsets.fromLTRB(
                              _kMobPanelLeftPad, 17, _kMobPanelRightPad, 17),
                          child: p != null
                              ? _buildMobPackRow(
                                  name: Text(p.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Color(0xFF111827))),
                                  pack: Text(pack,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 11, color: Color(0xFF374151))),
                                  company: Text(p.manufacturer,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 11, color: Color(0xFF6B7280))),
                                  mrp: Builder(builder: (_avCtx) {
                                    try { RenderLog.write('c316_detail_avna', '1'); } catch (_) {}
                                    try { RenderLog.write('c320_avna_mobile', '1'); } catch (_) {}
                                    final avail = p.isBuyable;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: avail ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        avail ? 'AV' : 'NA',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: avail ? const Color(0xFF15803D) : const Color(0xFFDC2626),
                                        ),
                                      ),
                                    );
                                  }),
                                )
                              : Text(
                                  row.status != _MatchStatus.unrecognized
                                      ? row.matchedSku
                                      : 'No match found',
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF9CA3AF))),
                        ),
                        // ── Expandable section: fixed 6-line match panel ────
                        SizeTransition(
                          sizeFactor: _anim,
                          child: _MatchPanel(
                            row: row,
                            isMobile: true,
                            onRowChanged: () {
                              widget.onToggle(); // collapse after pick
                              widget.onRowChanged();
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

/// Converts a product's packSize (sourced from pack_qty) into a short code.
/// "10 tablets in 1 strip" → "10'T", "10 tab sr in 1 strip" → "10'T-SR",
/// "10 ml in 1 bottle" → "10ml", "30 gm in 1 tube" → "30'G".
/// Falls back to raw packSize on parse failure.
String _packShort(Product p) {
  final raw = p.packSize.trim();
  if (raw.isEmpty) return '';
  final inIdx = raw.toLowerCase().indexOf(' in ');
  final leading = (inIdx >= 0 ? raw.substring(0, inIdx) : raw).trim();
  final parts = leading.split(RegExp(r'\s+'));
  if (parts.length < 2 || double.tryParse(parts[0]) == null || parts[1].isEmpty) return raw;

  final num = parts[0];
  final unit = parts[1].toLowerCase();

  // Liquid forms: concatenate number + unit directly, no apostrophe.
  if (unit == 'ml') return '${num}ml';
  if (unit == 'l' || unit == 'litre' || unit == 'liter' ||
      unit == 'litres' || unit == 'liters') return '${num}L';

  // Solid/semi-solid: apostrophe notation with optional SR/XR/ER modifier.
  final String typeCode;
  switch (unit) {
    case 'tablet':
    case 'tablets':
    case 'tab':
    case 'tabs':
      typeCode = 'T';
    case 'capsule':
    case 'capsules':
    case 'cap':
    case 'caps':
      typeCode = 'C';
    case 'gm':
    case 'g':
    case 'gram':
    case 'grams':
      typeCode = 'G';
    default:
      typeCode = parts[1][0].toUpperCase();
  }

  if (parts.length >= 3) {
    final mod = parts[2].toUpperCase();
    if (mod == 'SR' || mod == 'XR' || mod == 'ER' || mod == 'CR' || mod == 'MR') {
      return "$num'$typeCode-$mod";
    }
  }
  return "$num'$typeCode";
}

// ── Fuzzy-match helpers (client-side re-ranking) ──────────────────────────────

/// Normalize a string for fuzzy comparison: lowercase, strip punctuation, collapse spaces.
String _normStr(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r"[^a-z0-9\s]"), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

/// Returns the set of all overlapping 3-grams (substrings of length 3) from [s].
Set<String> _trigrams(String s) {
  if (s.length < 3) return {};
  final t = <String>{};
  for (int i = 0; i + 3 <= s.length; i++) t.add(s.substring(i, i + 3));
  return t;
}

/// Stage 1 — Typo-tolerant shortlist score.
/// Pure character-level: trigram-set Jaccard (55%) + normalised edit-distance
/// ratio (45%), both on space-stripped strings. No first-chunk weighting so a
/// single misread leading letter (OCR "fulim"→"lulim") does not gate out the
/// correct candidate. The positional chunk bonus is kept for completeness but
/// excluded from this score — it's still used by the debug output.
double _stage1Score(String query, String candidate) {
  final q = _normStr(query).replaceAll(' ', '');
  final c = _normStr(candidate).replaceAll(' ', '');
  if (q.isEmpty || c.isEmpty) return 0.0;

  // 1. Trigram Jaccard — insensitive to transpositions and 1-char substitutions.
  final qTri = _trigrams(q);
  final cTri = _trigrams(c);
  final inter = qTri.intersection(cTri).length.toDouble();
  final union = qTri.union(cTri).length.toDouble();
  final trigramScore = union == 0 ? 0.0 : inter / union;

  // 2. Edit-distance ratio (space-stripped, full string).
  final maxLen = q.length > c.length ? q.length : c.length;
  final editRatio = 1.0 - _editDistance(q, c) / maxLen;

  return 0.55 * trigramScore + 0.45 * editRatio;
}

/// Stage 1 — Positional 3-letter chunk score.
/// Query is split into sequential 3-char chunks (spaces stripped). Each chunk
/// that appears in the candidate earns weight 0.5^i (i = chunk index), so
/// chunk 0 always dominates any combination of later chunks.
/// A small positional bonus (+10 % of the chunk weight) is added when the chunk
/// appears within 4 chars of its expected offset in the candidate.
double _positionalChunkScore(String query, String candidate) {
  final q = _normStr(query).replaceAll(' ', '');
  final c = _normStr(candidate).replaceAll(' ', '');
  if (q.isEmpty || c.isEmpty) return 0.0;
  double score = 0.0;
  double weight = 1.0;
  for (int start = 0; start < q.length; start += 3) {
    final end = start + 3 < q.length ? start + 3 : q.length;
    final chunk = q.substring(start, end);
    if (chunk.isNotEmpty && c.contains(chunk)) {
      score += weight;
      final pos = c.indexOf(chunk);
      if ((pos - start).abs() <= 4) score += weight * 0.1;
    }
    weight *= 0.5;
  }
  return score;
}

/// Levenshtein edit distance.
int _editDistance(String s, String t) {
  final m = s.length, n = t.length;
  if (m == 0) return n;
  if (n == 0) return m;
  final dp = List.generate(m + 1, (i) => List.filled(n + 1, 0));
  for (int i = 0; i <= m; i++) dp[i][0] = i;
  for (int j = 0; j <= n; j++) dp[0][j] = j;
  for (int i = 1; i <= m; i++) {
    for (int j = 1; j <= n; j++) {
      if (s[i - 1] == t[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1];
      } else {
        final a = dp[i - 1][j];
        final b = dp[i][j - 1];
        final cc = dp[i - 1][j - 1];
        dp[i][j] = 1 + (a < b ? (a < cc ? a : cc) : (b < cc ? b : cc));
      }
    }
  }
  return dp[m][n];
}

/// Damerau-Levenshtein distance (OSA variant).
/// Like Levenshtein but counts an adjacent-character transposition as cost 1
/// instead of 2, so OCR swaps like "ar"↔"ra" or "eh"↔"he" score closer.
int _dlEditDistance(String s, String t) {
  final m = s.length, n = t.length;
  if (m == 0) return n;
  if (n == 0) return m;
  final dp = List.generate(m + 1, (i) => List.filled(n + 1, 0));
  for (int i = 0; i <= m; i++) dp[i][0] = i;
  for (int j = 0; j <= n; j++) dp[0][j] = j;
  for (int i = 1; i <= m; i++) {
    for (int j = 1; j <= n; j++) {
      if (s[i - 1] == t[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1];
      } else {
        final a = dp[i - 1][j];
        final b = dp[i][j - 1];
        final cc = dp[i - 1][j - 1];
        dp[i][j] = 1 + (a < b ? (a < cc ? a : cc) : (b < cc ? b : cc));
      }
      // Transposition: s[i-1]==t[j-2] and s[i-2]==t[j-1]
      if (i > 1 && j > 1 && s[i - 1] == t[j - 2] && s[i - 2] == t[j - 1]) {
        final trans = dp[i - 2][j - 2] + 1;
        if (trans < dp[i][j]) dp[i][j] = trans;
      }
    }
  }
  return dp[m][n];
}

/// Stage 2 — Full-name accuracy score.
/// Five-component weighted score (max 1.0):
///   50% DL edit ratio          — char-level accuracy; DL transpositions cost 1 so
///                                 OCR "ar"↔"ra" swaps don't inflate distance.
///   12% token-set Jaccard      — symmetric token overlap.
///   13% query-token recall     — fraction of query tokens present in candidate;
///                                 directly catches a missing short token like "B".
///   20% first-word DL ratio    — prefix similarity, full weight (no hard cap).
///    5% first-word trigram     — letter-group overlap at drug-name level.
///                                 "paraxin" shares {rax,axi} with "praxium" (J=0.25)
///                                 but only {par} with "paroxep" (J=0.11) and nothing
///                                 with "pazotin" (J=0.0), resolving the DL tie that
///                                 the prefix component alone cannot break. The cap
///                                 (formerly 0.10) is removed; this component now
///                                 guards against prefix-sharing impostors overtaking
///                                 the correct transposition-related match.
///
/// Short tokens (B, D, SR, LS, XT, ER, …) are preserved by _normStr and
/// included in both Jaccard and recall — they are never stripped.
double _stage2Score(String query, String candidate) {
  final q = _normStr(query);
  final c = _normStr(candidate);
  if (q.isEmpty || c.isEmpty) return 0.0;

  // 1. Normalised DL edit-distance ratio (full string, spaces included).
  final maxLen = q.length > c.length ? q.length : c.length;
  final editRatio = 1.0 - _dlEditDistance(q, c) / maxLen;

  // 2. Token-set Jaccard — short tokens (B, LS, SR, XT…) are included, not stripped.
  final qWords = q.split(' ').where((t) => t.isNotEmpty).toSet();
  final cWords = c.split(' ').where((t) => t.isNotEmpty).toSet();
  final intersection = qWords.intersection(cWords).length;
  final union = qWords.union(cWords).length;
  final tokenJaccard = union == 0 ? 0.0 : intersection / union;

  // 3. Query-token recall — fraction of query tokens found in candidate.
  // A candidate missing any query token (even a single-letter "B") is penalised
  // here regardless of how small that token is.
  final tokenRecall = qWords.isEmpty
      ? 0.0
      : qWords.where((t) => cWords.contains(t)).length / qWords.length;

  // 4. First-word DL ratio — full 0.20 weight, no hard cap.
  // The former 0.10 hard cap lowered the winning candidate's absolute contribution
  // without preventing ties; the first-word trigram (component 5) now provides the
  // ordering guard so the cap is no longer needed.
  final qList = q.split(' ').where((t) => t.isNotEmpty).toList();
  final cList = c.split(' ').where((t) => t.isNotEmpty).toList();
  final qFirst = qList.isEmpty ? '' : qList[0];
  final cFirst = cList.isEmpty ? '' : cList[0];
  final firstMaxLen = qFirst.length > cFirst.length ? qFirst.length : cFirst.length;
  final prefixRaw = firstMaxLen == 0
      ? 0.0
      : 1.0 - _dlEditDistance(qFirst, cFirst) / firstMaxLen;

  // 5. First-word trigram Jaccard — letter-group overlap at drug-name level.
  // When the DL transposition fires (e.g. "ar"↔"ra" in "paraxin"↔"praxium"),
  // the shared trigrams {rax,axi} provide a measurable signal (J=0.25) that
  // differentiates Praxium from Paroxep (J=0.11) and Pazotin (J=0.0) even
  // though all three have the same first-word DL distance from "paraxin".
  final qFirstTri = _trigrams(qFirst);
  final cFirstTri = _trigrams(cFirst);
  final fwUnion = qFirstTri.union(cFirstTri).length.toDouble();
  final firstWordTrigram = fwUnion == 0 ? 0.0 : qFirstTri.intersection(cFirstTri).length / fwUnion;

  return 0.50 * editRatio
       + 0.12 * tokenJaccard
       + 0.13 * tokenRecall
       + 0.20 * prefixRaw
       + 0.05 * firstWordTrigram;
}

/// Detect dosage form keyword in a query string.
/// Returns one of: 'tablet' | 'syrup' | 'capsule' | 'injection' | 'drops' | 'topical' | 'sachet' | null.
String? _detectDosageForm(String query) {
  final q = query.toLowerCase();
  if (RegExp(r'\btab(let|s)?\b').hasMatch(q) || RegExp(r"\d+'t\b").hasMatch(q)) return 'tablet';
  if (q.contains('syrup') || RegExp(r'\bsyp\b').hasMatch(q) ||
      q.contains('susp') || q.contains('suspension')) return 'syrup';
  if (RegExp(r'\bcaps?(ule(s)?)?\b').hasMatch(q) || q.contains('softgel')) return 'capsule';
  if (q.contains('inj') || q.contains('injection') || q.contains('vial') ||
      q.contains('ampoule') || RegExp(r'\bamp\b').hasMatch(q)) return 'injection';
  if (q.contains('drop')) return 'drops';
  if (q.contains('cream') || q.contains('ointment') || q.contains('gel') ||
      q.contains('lotion') || q.contains('spray')) return 'topical';
  if (q.contains('sachet') || q.contains('powder') || q.contains('granule')) return 'sachet';
  return null;
}

/// True when a product name contains form-matching keywords (for soft bonus).
bool _formMatches(String productName, String form) {
  final n = productName.toLowerCase();
  switch (form) {
    case 'tablet':    return RegExp(r'\btab(let)?\b').hasMatch(n) || n.contains("'t");
    case 'syrup':     return n.contains('syrup') || RegExp(r'\bsyp\b').hasMatch(n) || n.contains('susp');
    case 'capsule':   return RegExp(r'\bcap(sule)?\b').hasMatch(n) || n.contains('softgel');
    case 'injection': return n.contains('inj') || n.contains('vial') || n.contains('ampoule') || RegExp(r'\bamp\b').hasMatch(n);
    case 'drops':     return n.contains('drop');
    case 'topical':   return n.contains('cream') || n.contains('oint') || n.contains('gel') || n.contains('lotion') || n.contains('spray');
    case 'sachet':    return n.contains('sachet') || n.contains('powder') || n.contains('granule');
    default:          return false;
  }
}

// ─── Manual search helpers ────────────────────────────────────────────────────

/// Queries MEDICINE via the priority RPC (falls back to ILIKE).
/// Returns up to [limit] candidates.
Future<List<Product>> _manualSearchProducts(String query, {int limit = 3}) async {
  final q = query.trim();
  if (q.isEmpty) return [];
  try {
    final rows = await Supabase.instance.client.rpc('search_medicines_priority', params: {
      'search_term': q,
      'category_filter': 'All',
      'page_offset': 0,
      'page_limit': limit,
    });
    return List<Map<String, dynamic>>.from(rows as List)
        .map((m) => Product.fromMap(m))
        .toList();
  } catch (_) {
    try {
      final results = await Supabase.instance.client
          .from('MEDICINE')
          .select()
          .ilike('product_name', '%$q%')
          .eq('status', 'Available')
          .order('sales_count', ascending: false)
          .limit(limit);
      return List<Map<String, dynamic>>.from(results)
          .map((m) => Product.fromMap(m))
          .toList();
    } catch (_) {
      return [];
    }
  }
}

// ─── Fixed 6-line match panel ─────────────────────────────────────────────────
// Layout:
//   Line 1        : current selected match (green bg, tick, not tappable).
//   Lines 2–5     : up to 4 fuzzy candidates excl. line-1 (normal styling, tappable).
//   After a pick  : line-1 = new pick, line-2 = demoted old match, lines 3–5 = 3 fuzzy.
//   Line 6 (last) : search row — prefilled with raw OCR text, fires on icon-tap / Enter.
//   Below search  : top-3 search results (panel expands); candidate rows stay visible.

// Row height shared by every panel row (shimmer, fuzzy, result, empty filler).
// Constant ensures rows 2–5 always occupy exactly 4 × _kMatchRowH regardless of state.
const double _kMatchRowH = 36.0;

// Mobile match-panel shared column widths — every mobile row type
// (selected product, fuzzy candidate, search result, shimmer skeleton)
// MUST use these constants so every column sits on one vertical line.
const double _kMobPanelLeftPad  = 12.0;
const double _kMobPanelRightPad =  8.0;
const double _kMobPanelGap      =  6.0;
const double _kMobPanelPackW    = 38.0;
const double _kMobPanelMrpW     = 34.0;

/// Shared mobile Row layout: [name Expanded(flex:3)] | [gap] |
/// [Pack _kMobPanelPackW] | [gap] | [Company Expanded(flex:1)+ellipsis] | [gap] | [MRP _kMobPanelMrpW]
///
/// Name gets 3/4 of flexible space so long medicine names show without early truncation.
/// Company gets 1/4, fills to MRP then ellipsis.
/// All mobile row types call this so Pack aligns across every row at every card width.
Widget _buildMobPackRow({
  required Widget name,
  required Widget pack,
  required Widget company,
  required Widget mrp,
}) {
  return Row(children: [
    Expanded(flex: 3, child: name),
    const SizedBox(width: _kMobPanelGap),
    SizedBox(width: _kMobPanelPackW, child: pack),
    const SizedBox(width: _kMobPanelGap),
    Expanded(child: company),
    const SizedBox(width: _kMobPanelGap),
    SizedBox(width: _kMobPanelMrpW, child: mrp),
  ]);
}

class _MatchPanel extends StatefulWidget {
  final _MatchRow row;
  final VoidCallback onRowChanged; // called after pick — parent handles close + refresh
  final bool isMobile;

  const _MatchPanel({
    required this.row,
    required this.onRowChanged,
    this.isMobile = false,
  });

  @override
  State<_MatchPanel> createState() => _MatchPanelState();
}

class _MatchPanelState extends State<_MatchPanel> {
  late final TextEditingController _ctrl;
  final FocusNode _focusNode = FocusNode();
  List<Product> _searchResults = [];
  bool _searching = false;
  bool _hasSearched = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.row.lineItem);
    _ctrl.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(_MatchPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.row, widget.row)) {
      _debounce?.cancel();
      _ctrl.text = widget.row.lineItem;
      _searchResults = [];
      _hasSearched = false;
      _searching = false;
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _fireSearch() async {
    _debounce?.cancel();
    final q = _ctrl.text.trim();
    if (q.isEmpty) { setState(() { _searchResults = []; }); return; }
    setState(() { _searching = true; _hasSearched = true; });
    final all = await _manualSearchProducts(q, limit: 4);
    if (mounted) setState(() { _searchResults = all; _searching = false; });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _ctrl.clear();
    setState(() { _searchResults = []; _hasSearched = false; _searching = false; });
  }

  void _liveSearch(String q) {
    if (!_hasSearched) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () async {
      final trimmed = q.trim();
      if (trimmed.isEmpty) {
        if (mounted) setState(() => _searchResults = []);
        return;
      }
      if (mounted) setState(() => _searching = true);
      final all = await _manualSearchProducts(trimmed, limit: 4);
      if (mounted) setState(() { _searchResults = all; _searching = false; });
    });
  }

  void _pick(Product p) {
    _debounce?.cancel();
    final row = widget.row;
    row._previousLine1 = row.selectedProduct;
    row._manualProduct = p;
    row.status = _MatchStatus.manuallyMatched;
    setState(() { _searchResults = []; _hasSearched = false; _searching = false; });
    widget.onRowChanged();
  }

  // Web: candidates excluding the active selected SKU, max 4 rows
  List<Product> _webCandidates() {
    final row = widget.row;
    final active = row.selectedProduct;
    final prev = row._previousLine1;
    final activeId = active?.id;
    final prevId = (prev != null && prev.id != activeId) ? prev.id : null;

    final out = <Product>[];
    if (prevId != null) out.add(prev!);
    for (final c in row.candidates) {
      if (out.length >= 4) break;
      if (c.id == activeId || c.id == prevId) continue;
      out.add(c);
    }
    return out;
  }

  // Mobile: original candidates with isSelected, unchanged
  List<({Product product, bool isSelected})> _mobileCandidates() {
    final row = widget.row;
    final active = row.selectedProduct;
    final prev = row._previousLine1;
    final activeId = active?.id;
    final prevId = (prev != null && prev.id != activeId) ? prev.id : null;

    final out = <({Product product, bool isSelected})>[];
    if (active != null) out.add((product: active, isSelected: true));
    if (prevId != null) out.add((product: prev!, isSelected: false));

    final maxFuzzy = prevId != null ? 3 : 4;
    int n = 0;
    for (final c in row.candidates) {
      if (n >= maxFuzzy) break;
      if (c.id == activeId || c.id == prevId) continue;
      out.add((product: c, isSelected: false));
      n++;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) =>
      widget.isMobile ? _buildMobilePanel() : _buildWebPanel();

  // ── WEB panel: no selected row, results above search box, merged icon ────────
  Widget _buildWebPanel() {
    final rows = _hasSearched ? _searchResults : _webCandidates();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Lines 2–5: always exactly 4 × _kMatchRowH — pixel-stable height in all states.
        // _searching → 4 shimmer skeletons; loaded → up to 4 rows + empty fillers; idle → fuzzy candidates.
        ...List.generate(4, (i) {
          if (_searching) {
            return const SizedBox(height: _kMatchRowH, child: _WebPanelSkeletonRow());
          }
          if (i < rows.length) {
            final p = rows[i];
            return SizedBox(
              height: _kMatchRowH,
              child: _SearchResultRow(product: p, onTap: () => _pick(p), isMobile: false),
            );
          }
          return const _WebPanelEmptyRow();
        }),

        // Line 6: search box — CHANGE #316 item 7: right 1/4 is a wide tap zone.
        Container(
          color: const Color(0xFFF3F4F6),
          padding: const EdgeInsets.fromLTRB(17, 7, 12, 7),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          child: Builder(builder: (_szCtx) {
            try { RenderLog.write('c316_search_hitzone', '1'); } catch (_) {}
            return Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focusNode,
                  onSubmitted: (_) => _fireSearch(),
                  onChanged: _hasSearched ? _liveSearch : null,
                  decoration: InputDecoration(
                    hintText: 'Search / change match…',
                    hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFF16A34A), width: 1.5),
                    ),
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              Expanded(
                flex: 1,
                child: InkWell(
                  onTap: _hasSearched ? _clearSearch : (_searching ? null : _fireSearch),
                  borderRadius: BorderRadius.circular(6),
                  child: Center(
                    child: _hasSearched
                        ? const Icon(Icons.close_rounded, size: 16, color: Color(0xFF9CA3AF))
                        : _searching
                            ? const SizedBox(
                                width: 16, height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF16A34A)),
                                ),
                              )
                            : const Icon(Icons.search_rounded, size: 18, color: Color(0xFF6B7280)),
                  ),
                ),
              ),
            ]);
          }),
        ),
      ],
    );
  }

  // ── MOBILE panel: parity with web — fixed 4-row area + pinned search box ──────
  Widget _buildMobilePanel() {
    final rows = _hasSearched ? _searchResults : _webCandidates();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Lines 2–5: always exactly 4 × _kMatchRowH — pixel-stable height in all states
        ...List.generate(4, (i) {
          if (_searching) {
            return const SizedBox(height: _kMatchRowH, child: _MobilePanelSkeletonRow());
          }
          if (i < rows.length) {
            final p = rows[i];
            return SizedBox(
              height: _kMatchRowH,
              child: _SearchResultRow(product: p, onTap: () => _pick(p), isMobile: true),
            );
          }
          return const _MobilePanelEmptyRow();
        }),

        // Line 6: search box — CHANGE #316 item 7: right 1/4 is a wide tap zone.
        Container(
          color: const Color(0xFFF3F4F6),
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          child: Builder(builder: (_szCtx) {
            try { RenderLog.write('c316_search_hitzone', '1'); } catch (_) {}
            return Row(children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _ctrl,
                  focusNode: _focusNode,
                  onSubmitted: (_) => _fireSearch(),
                  onChanged: _hasSearched ? _liveSearch : null,
                  decoration: InputDecoration(
                    hintText: 'Search / change match…',
                    hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    filled: true,
                    fillColor: Colors.white,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: Color(0xFF16A34A), width: 1.5),
                    ),
                  ),
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              Expanded(
                flex: 1,
                child: InkWell(
                  onTap: _hasSearched ? _clearSearch : (_searching ? null : _fireSearch),
                  borderRadius: BorderRadius.circular(6),
                  child: Center(
                    child: _hasSearched
                        ? const Icon(Icons.close_rounded, size: 16, color: Color(0xFF9CA3AF))
                        : _searching
                            ? const SizedBox(
                                width: 16, height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF16A34A)),
                                ),
                              )
                            : const Icon(Icons.search_rounded, size: 18, color: Color(0xFF6B7280)),
                  ),
                ),
              ),
            ]);
          }),
        ),
      ],
    );
  }
}

/// A search-result row shown below the search field after an explicit search.
/// Shows name + pack + company + MRP + (+) icon; tapping triggers a pick.
class _SearchResultRow extends StatelessWidget {
  final Product product;
  final VoidCallback onTap;
  final bool isMobile;

  const _SearchResultRow({required this.product, required this.onTap, this.isMobile = false});

  @override
  Widget build(BuildContext context) =>
      isMobile ? _buildMobile() : _buildWeb();

  // Mobile: delegates to _buildMobPackRow so column x-positions are identical
  // to the selected-product row (Line 2) and shimmer skeleton.
  Widget _buildMobile() {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: _kMatchRowH,
        padding: const EdgeInsets.fromLTRB(
            _kMobPanelLeftPad, 0, _kMobPanelRightPad, 0),
        alignment: Alignment.centerLeft,
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: _buildMobPackRow(
          name: Text(product.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500,
                  color: Color(0xFF374151))),
          pack: Text(_packShort(product),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
          company: Text(product.manufacturer,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
          mrp: Builder(builder: (_srCtx) {
            try { RenderLog.write('c320_avna_mobile', '1'); } catch (_) {}
            final av = product.isBuyable;
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: av ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(av ? 'AV' : 'NA',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w600,
                      color: av ? const Color(0xFF15803D) : const Color(0xFFDC2626))),
            );
          }),
        ),
      ),
    );
  }

  // Web: flex layout aligned to the main table columns — same x per column as _AlternativeRow._buildWeb()
  Widget _buildWeb() {
    try { RenderLog.write('c404_alt_availability_shown', 'true'); } catch (_) {}
    try { RenderLog.write('c405_bulk_mrp_status_cols', 'true'); } catch (_) {}
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(17, 8, 12, 8),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // #406: flex ratios match _ExpandableMatchRow's desktop grid
            // (LINE ITEM 50 : MATCHED SKU 30 : PACK 12 : COMPANY 22 : QTY 8 :
            // MRP 13 : STATUS 20 : APPROVE 9), tighter 6px gaps.
            const Expanded(flex: 50, child: SizedBox()),
            const SizedBox(width: 6),
            // MATCHED SKU column — product name
            Expanded(
              flex: 30,
              child: Text(product.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500,
                      color: Color(0xFF374151))),
            ),
            const SizedBox(width: 6),
            // PACK column
            Expanded(
              flex: 12,
              child: Text(_packShort(product),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            ),
            const SizedBox(width: 6),
            // COMPANY column
            Expanded(
              flex: 22,
              child: Text(product.manufacturer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            ),
            const SizedBox(width: 6),
            // QTY column — blank spacer (alternatives have no order qty)
            const Expanded(flex: 8, child: SizedBox()),
            const SizedBox(width: 6),
            // #405: MRP column
            Expanded(
              flex: 13,
              child: Center(
                child: Text(
                  product.hasMrp ? rupees(product.mrp) : '—',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w500,
                      color: Color(0xFF374151)),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // #405: STATUS column (renamed from AVAIL) — this alternative's
            // own availability chip, not just the selected row's.
            Expanded(flex: 20, child: Center(child: _AvailChip(available: product.isBuyable))),
            const SizedBox(width: 6),
            // APPROVE column — blank spacer
            const Expanded(flex: 9, child: SizedBox()),
          ],
        ),
      ),
    );
  }
}

// ─── Web panel skeleton row (shown during search loading, maintains panel height) ──

class _WebPanelSkeletonRow extends StatelessWidget {
  const _WebPanelSkeletonRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(17, 8, 12, 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF0FDF4),
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // #406: flex ratios match _ExpandableMatchRow's desktop grid.
          const Expanded(flex: 50, child: SizedBox()),
          const SizedBox(width: 6),
          Expanded(
            flex: 30,
            child: Container(
              height: 10,
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFBBF7D0),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 12,
            child: Container(
              height: 10,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFBBF7D0),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 22,
            child: Container(
              height: 10,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFBBF7D0),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // QTY column — blank spacer
          const Expanded(flex: 8, child: SizedBox()),
          const SizedBox(width: 6),
          // #405: MRP shimmer (new column)
          Expanded(
            flex: 13,
            child: Container(
              height: 10,
              margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFBBF7D0),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // #405: STATUS shimmer (renamed from AVAIL)
          Expanded(
            flex: 20,
            child: Container(
              height: 10,
              decoration: BoxDecoration(
                color: const Color(0xFFBBF7D0),
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          const SizedBox(width: 6),
          const Expanded(flex: 9, child: SizedBox()),
        ],
      ),
    );
  }
}

// ─── Web panel empty filler row (maintains 4-row height when fewer results) ───

class _WebPanelEmptyRow extends StatelessWidget {
  const _WebPanelEmptyRow();

  @override
  Widget build(BuildContext context) => Container(
        height: _kMatchRowH,
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
        ),
      );
}

// ─── Mobile panel skeleton row (green shimmer during search loading) ──────────
// Column widths mirror the selected-product row and _SearchResultRow._buildMobile()
// so the shimmer bars sit on the same vertical grid as real content.

class _MobilePanelSkeletonRow extends StatelessWidget {
  const _MobilePanelSkeletonRow();

  @override
  Widget build(BuildContext context) {
    const shimmer = BoxDecoration(
      color: Color(0xFFBBF7D0),
      borderRadius: BorderRadius.all(Radius.circular(4)),
    );
    return Container(
      height: _kMatchRowH,
      padding: const EdgeInsets.fromLTRB(
          _kMobPanelLeftPad, 0, _kMobPanelRightPad, 0),
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        color: Color(0xFFF0FDF4),
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: _buildMobPackRow(
        name: Container(height: 10, decoration: shimmer),
        pack: Container(height: 10, decoration: shimmer),
        company: Container(height: 10, decoration: shimmer),
        mrp: Container(height: 10, decoration: shimmer),
      ),
    );
  }
}

// ─── Mobile panel empty filler row (constant height when fewer than 4 results) ─

class _MobilePanelEmptyRow extends StatelessWidget {
  const _MobilePanelEmptyRow();

  @override
  Widget build(BuildContext context) => Container(
        height: _kMatchRowH,
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
        ),
      );
}

class _AlternativeRow extends StatelessWidget {
  final Product product;
  final bool isSelected;
  final bool isLast;
  final bool isMobile;
  final VoidCallback onTap;

  const _AlternativeRow({
    required this.product,
    required this.isSelected,
    required this.isLast,
    required this.onTap,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context) => isMobile ? _buildMobile() : _buildWeb();

  Widget _buildWeb() {
    try { RenderLog.write('c404_alt_availability_shown', 'true'); } catch (_) {}
    try { RenderLog.write('c405_bulk_mrp_status_cols', 'true'); } catch (_) {}
    final nameColor = isSelected ? const Color(0xFF16A34A) : const Color(0xFF374151);
    final priceColor = isSelected ? const Color(0xFF16A34A) : const Color(0xFF6B7280);
    final packShort = _packShort(product);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(17, 8, 12, 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFDCFCE7) : const Color(0xFFF3F4F6),
          border: isLast
              ? null
              : const Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // #406: flex ratios match _ExpandableMatchRow's desktop grid.
            // LINE ITEM column — blank spacer
            const Expanded(flex: 50, child: SizedBox()),
            const SizedBox(width: 6),
            // MATCHED SKU column — product name only (company goes to COMPANY column)
            Expanded(
              flex: 30,
              child: Text(
                product.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: nameColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // PACK column
            Expanded(
              flex: 12,
              child: Text(
                packShort,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              ),
            ),
            const SizedBox(width: 6),
            // COMPANY column — aligned under main row's company cell, ellipsis if long
            Expanded(
              flex: 22,
              child: Text(
                product.manufacturer,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
            ),
            const SizedBox(width: 6),
            // QTY column — blank spacer (alternatives have no order qty)
            const Expanded(flex: 8, child: SizedBox()),
            const SizedBox(width: 6),
            // #405: MRP column — aligned under main row's cell
            Expanded(
              flex: 13,
              child: Center(
                child: Text(
                  product.hasMrp ? rupees(product.mrp) : '—',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: priceColor),
                ),
              ),
            ),
            const SizedBox(width: 6),
            // #405: STATUS column (renamed from AVAIL) — this alternative's
            // own availability chip, not just the selected row's.
            Expanded(flex: 20, child: Center(child: _AvailChip(available: product.isBuyable))),
            const SizedBox(width: 6),
            // APPROVE column — blank spacer
            const Expanded(flex: 9, child: SizedBox()),
          ],
        ),
      ),
    );
  }

  Widget _buildMobile() {
    // Mobile-only layout: no 100px blank indent, Expanded name prevents overflow.
    // Fixed 18px leading slot (check icon on selected, empty on others) keeps
    // every row's name text at the identical left x regardless of selection state.
    final nameColor = isSelected ? const Color(0xFF16A34A) : const Color(0xFF374151);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFDCFCE7) : const Color(0xFFF3F4F6),
          border: isLast
              ? null
              : const Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: Row(
          children: [
            // Leading indicator — identical width for selected AND unselected so
            // product names share the same vertical line on every row.
            SizedBox(
              width: 18,
              child: isSelected
                  ? const Icon(Icons.check_circle_rounded,
                      size: 14, color: Color(0xFF16A34A))
                  : null,
            ),
            const SizedBox(width: 4),
            // Name — Expanded avoids any overflow on narrow screens
            Expanded(
              child: Text(
                product.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: nameColor,
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 40,
              child: Text(_packShort(product),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 34,
              child: Builder(builder: (_altCtx) {
                try { RenderLog.write('c320_avna_mobile', '1'); } catch (_) {}
                final av = product.isBuyable;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: av ? const Color(0xFFDCFCE7) : const Color(0xFFFEE2E2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(av ? 'AV' : 'NA',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w600,
                          color: av ? const Color(0xFF15803D) : const Color(0xFFDC2626))),
                );
              }),
            ),
            // Blank trailing slot (same width as search-result's + icon row)
            // so AV/NA column ends at the same right edge across all panel rows.
            const SizedBox(width: 6),
            const SizedBox(width: 14),
          ],
        ),
      ),
    );
  }
}

// ─── Checklist widget ─────────────────────────────────────────────────────────

class _Checklist extends StatelessWidget {
  final List<String> items;
  final Color iconColor;
  final Color textColor;

  const _Checklist({
    required this.items,
    required this.iconColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.check, color: iconColor, size: 17),
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  items[i],
                  style: TextStyle(color: textColor, fontSize: 13, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
