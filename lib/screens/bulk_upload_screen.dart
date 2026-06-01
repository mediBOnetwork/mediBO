// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart' as xmlp;

import '../app_state.dart';
import '../config/api_keys.dart';
import '../models/product.dart';
import '../util.dart';

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
  _MatchStatus? _preHideStatus; // saved on hide, restored on unhide
  final String _displaySku;
  final String _displayPrice;
  final Rect? bbox;
  // Pre-processed crop: binarized, dilated, deskewed PNG bytes. Set after canvas
  // processing in _pickAndProcess; never serialized (derived, not source data).
  Uint8List? processedCrop;

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

  Product? get selectedProduct =>
      candidates.isEmpty ? null : candidates[selectedIndex];

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
        if (bbox != null) 'bbox': {'x': bbox!.left, 'y': bbox!.top, 'w': bbox!.width, 'h': bbox!.height},
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
    return _MatchRow(
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

// ─── Screen ───────────────────────────────────────────────────────────────────

class BulkUploadScreen extends StatefulWidget {
  const BulkUploadScreen({super.key});

  @override
  State<BulkUploadScreen> createState() => _BulkUploadScreenState();
}

class _BulkUploadScreenState extends State<BulkUploadScreen> {
  List<_MatchRow> _rows = _kSampleRows;
  _LoadStep _step = _LoadStep.idle;
  int _matchProgress = 0;
  int _matchTotal = 0;
  bool _isFromFile = false;
  String? _fileName;
  bool _addingToCart = false;
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
  void initState() {
    super.initState();
    _loadSession();
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
      if (rows.isNotEmpty && mounted) {
        setState(() {
          _rows = rows;
          _fileName = fileName;
          _isFromFile = true;
          _bulkLineItemMap = lineItemMap;
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
    bool anyUpdated = false;
    for (final row in _rows) {
      if (row.processedCrop == null && row.bbox != null) {
        row.processedCrop = _processOneCrop(imgEl, srcW, srcH, row.bbox!);
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

  Future<void> _pickAndProcess() async {
    final input = html.FileUploadInputElement()
      ..accept = '.csv,.xlsx,.xls,.pdf,.ods,.tsv,.txt,.docx,.doc,.html,.htm,.jpg,.jpeg,.png,.webp,.heic,.heif,.gif'
      ..multiple = false;
    input.click();

    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty) return;

    final file = files.first;
    setState(() {
      _step = _LoadStep.readingFile;
      _fileName = file.name;
      _matchProgress = 0;
      _matchTotal = 0;
    });

    try {
      // Step 1: extract raw text / bytes from file
      final rawContent = await _getRawFileContent(file);

      // Step 2: Try AI; silently fall back to header-column matching on failure
      setState(() => _step = _LoadStep.aiAnalyzing);
      final isBinary = rawContent.startsWith('PDF_BYTES:') ||
          rawContent.startsWith('IMAGE_BYTES:');
      // Structured spreadsheets have unambiguous column layout; parse locally
      // to avoid Gemini misidentifying the qty column as rate/amount/mrp.
      final fileExt = file.name.toLowerCase().split('.').last;
      final isStructuredSheet =
          const {'xlsx', 'xls', 'ods', 'csv', 'tsv'}.contains(fileExt);
      List<Map<String, dynamic>> extracted;
      if (isStructuredSheet) {
        extracted = _extractWithFallback(rawContent);
      } else {
        try {
          extracted = await _extractWithGeminiAI(rawContent, file.name);
        } catch (e) {
          debugPrint('[BulkUpload] Extraction error (isBinary=$isBinary): $e');
          if (isBinary) rethrow;
          extracted = _extractWithFallback(rawContent);
        }
      }

      if (extracted.isEmpty) throw Exception('No medicine rows found in file');

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

      // Step 3: fuzzy-match each extracted medicine against Supabase.
      // IMPORTANT: rows are processed sequentially (await) and appended in
      // input order. _rows must never be sorted — display preserves this order.
      setState(() {
        _step = _LoadStep.matching;
        _matchTotal = extracted.length;
        _matchProgress = 0;
      });

      final rows = <_MatchRow>[];
      for (final item in extracted) {
        final name = item['name']?.toString().trim() ?? '';
        final qty = (int.tryParse(item['qty']?.toString() ?? '') ?? 1).clamp(1, 99999);
        if (name.isNotEmpty) {
          Rect? bbox;
          final bboxMap = item['bbox'] as Map<String, dynamic>?;
          if (bboxMap != null && origImageSize != null) {
            final bx = (bboxMap['x'] as num?)?.toDouble() ?? 0;
            final by = (bboxMap['y'] as num?)?.toDouble() ?? 0;
            final bw = (bboxMap['w'] as num?)?.toDouble() ?? 0;
            final bh = (bboxMap['h'] as num?)?.toDouble() ?? 0;
            if (bw > 0 && bh > 0) bbox = Rect.fromLTWH(bx, by, bw, bh);
            debugPrint('[BBox] "$name" → x=$bx y=$by w=$bw h=$bh');
          }
          rows.add(await _matchOne(name, qty, bbox: bbox));
        }
        if (!mounted) return;
        setState(() => _matchProgress = rows.length);
      }

      // Process handwriting crops: binarize + deskew + thicken each row's name region.
      if (origImageBytes != null && origImageSize != null) {
        final imgEl = await _loadImageForProcessing(origImageBytes, origMimeType);
        if (imgEl != null) {
          final srcW = imgEl.naturalWidth;
          final srcH = imgEl.naturalHeight;
          for (final row in rows) {
            if (row.bbox != null) {
              row.processedCrop = _processOneCrop(imgEl, srcW, srcH, row.bbox!);
              debugPrint('[Crop] "${row.lineItem}" → ${row.processedCrop?.length ?? 0} B');
            }
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _LoadStep.idle;
        _isFromFile = false;
        _fileName = null;
        _bulkLineItemMap = {};
      });
      _clearSession();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyError(e)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
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

  // Crops a name-only region from the image, converts to black transparent ink.
  // No binarization, no dilation, no deskew — natural smooth anti-aliased strokes.
  Uint8List? _processOneCrop(html.ImageElement img, int srcW, int srcH, Rect bbox) {
    try {
      // Tighten bbox: vTrim=0.18 excludes ruled underline; rTrim=0.06 removes qty bleed.
      const vTrim = 0.18;
      const rTrim = 0.06;
      final tLeft   = bbox.left * srcW;
      final tTop    = (bbox.top + bbox.height * vTrim) * srcH;
      final tWidth  = bbox.width * (1.0 - rTrim) * srcW;
      final tHeight = bbox.height * (1.0 - 2 * vTrim) * srcH;
      if (tWidth < 6 || tHeight < 4) return null;

      // Natural source resolution — no upscaling or fixed-height normalization.
      final outW = tWidth.round().clamp(10, 800);
      final outH = tHeight.round().clamp(4, 200);

      // Canvas starts transparent (no fillRect white).
      final canvas = html.CanvasElement(width: outW, height: outH);
      final ctx = canvas.context2D;
      ctx.drawImageScaledFromSource(img, tLeft, tTop, tWidth, tHeight, 0, 0,
          outW.toDouble(), outH.toDouble());

      // Grayscale → alpha: dark ink → opaque black, light paper → transparent.
      final imgData = ctx.getImageData(0, 0, outW, outH);
      final data = imgData.data;
      for (int i = 0; i < data.length; i += 4) {
        final luma =
            (0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]).round();
        final alpha = (255 - luma).clamp(0, 255);
        data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = alpha;
      }
      ctx.putImageData(imgData, 0, 0);

      final dataUrl = canvas.toDataUrl('image/png');
      return base64Decode(dataUrl.split(',').last);
    } catch (e) {
      debugPrint('[CropProcess] Failed: $e');
      return null;
    }
  }

  static bool _isNetworkOrApiError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('http') ||
        msg.contains('network') ||
        msg.contains('socket') ||
        msg.contains('timeout') ||
        msg.contains('api error') ||
        msg.contains('quota');
  }

  // Retries up to 3 times; images are preprocessed once then retried with
  // progressively broader prompts. Network/API errors abort immediately.
  Future<List<Map<String, dynamic>>> _extractWithGeminiAI(
      String rawContent, String fileName) async {
    if (geminiApiKey.isEmpty || geminiApiKey.startsWith('YOUR_')) {
      debugPrint('[Gemini] API key not configured');
      throw Exception(
          'Gemini API key is not configured. Contact support to enable AI image processing.');
    }
    debugPrint('[Gemini] Key prefix: ${geminiApiKey.substring(0, geminiApiKey.length.clamp(0, 10))}…');

    final isImage = rawContent.startsWith('IMAGE_BYTES:');

    // Preprocess image once before all attempts.
    final content = isImage ? await _enhanceImageForOCR(rawContent) : rawContent;

    Object? lastError;

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final result = await _callGeminiOnce(content, attempt: attempt);
        if (result.isNotEmpty) return result;
        // Empty result — retry with next prompt variant.
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 800 * (attempt + 1)));
          continue;
        }
        // All 3 attempts returned empty.
        if (isImage) {
          throw Exception(
              'Could not read medicines from the photo. Try better lighting or a clearer shot of the list.');
        }
        throw Exception('empty_response');
      } catch (e) {
        lastError = e;
        // Network/API errors — no point retrying.
        if (_isNetworkOrApiError(e)) {
          debugPrint('[Gemini] Network/API error on attempt $attempt — aborting: $e');
          rethrow;
        }
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 600 * (attempt + 1)));
        }
      }
    }

    throw lastError!;
  }

  Future<List<Map<String, dynamic>>> _callGeminiOnce(
      String rawContent, {int attempt = 0}) async {
    final isPdf = rawContent.startsWith('PDF_BYTES:');
    final isImage = rawContent.startsWith('IMAGE_BYTES:');

    final List<Map<String, dynamic>> parts;
    if (isImage) {
      final withoutPrefix = rawContent.substring('IMAGE_BYTES:'.length);
      final colonIdx = withoutPrefix.indexOf(':');
      final mimeType = withoutPrefix.substring(0, colonIdx);
      final base64Data = withoutPrefix.substring(colonIdx + 1);
      debugPrint('[Gemini] Image upload — mime=$mimeType payload=${base64Data.length} chars attempt=$attempt');
      // Attempts 0–1 use the detailed prompt; attempt 2 uses the broader fallback.
      final imagePromptText =
          attempt < 2 ? _geminiImagePrompt : _geminiImageFallbackPrompt;
      parts = [
        {'inline_data': {'mime_type': mimeType, 'data': base64Data}},
        {'text': imagePromptText},
      ];
    } else if (isPdf) {
      final base64Pdf = rawContent.substring('PDF_BYTES:'.length);
      debugPrint('[Gemini] PDF upload — payload=${base64Pdf.length} chars attempt=$attempt');
      parts = [
        {'inline_data': {'mime_type': 'application/pdf', 'data': base64Pdf}},
        {'text': _geminiPrompt},
      ];
    } else {
      debugPrint('[Gemini] Text upload — length=${rawContent.length} chars attempt=$attempt');
      parts = [{'text': _geminiTextPrompt(rawContent)}];
    }

    final response = await http.post(
      Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent?key=$geminiApiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {'parts': parts}
        ],
        'generationConfig': {
          'temperature': isImage ? 0.2 : 0.1,
          'maxOutputTokens': isImage ? 4096 : 3000,
        },
      }),
    ).timeout(const Duration(seconds: 60));

    debugPrint('[Gemini] HTTP ${response.statusCode} — body(200)=${response.statusCode == 200 ? response.body.substring(0, response.body.length.clamp(0, 400)) : response.body}');
    if (response.statusCode != 200) {
      throw Exception('Gemini API error (HTTP ${response.statusCode}). Check API key or quota.');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final candidates = data['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      // Safety block or empty response from the model.
      debugPrint('[Gemini] No candidates in response (safety block or empty)');
      return [];
    }
    final content = (candidates[0] as Map<String, dynamic>)['content'] as Map<String, dynamic>?;
    final textParts = content?['parts'] as List<dynamic>?;
    // Filter out thinking parts (thought=true) — keep only the actual output.
    final outputParts = textParts
        ?.where((p) => (p as Map<String, dynamic>)['thought'] != true)
        .toList();
    final text = outputParts?.isNotEmpty == true
        ? (outputParts![0] as Map<String, dynamic>)['text'] as String? ?? ''
        : '';
    if (text.isEmpty) return [];
    final match = RegExp(r'\[[\s\S]*\]').firstMatch(text);
    if (match == null) throw Exception('no_json_in_response');

    return (jsonDecode(match.group(0)!) as List).cast<Map<String, dynamic>>();
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
      'The photo may have faint ink, slight blur, glare, shadows, or an angled perspective — '
      'this is normal. Your job is to extract EVERY medicine entry visible.\n\n'
      'WHAT EACH LINE LOOKS LIKE:\n'
      '- A medicine/brand name (e.g. "Augmentin 625", "Pan 40", "Dolo 650", "Metformin 500mg")\n'
      '- Followed by a small quantity number (how many strips/boxes to order)\n'
      '- Dosage forms: Tab, Cap, Syr, Inj, Drops, Gel, Cream\n'
      '- Units: Box/B/box, Strip/S/strip, Pcs/P, Vial\n\n'
      'IGNORE: page header, shop name, date, phone number, calendar text, ruled lines, '
      'column headers (Name/Qty/Rate/MRP), totals.\n\n'
      'STRICT RULES:\n'
      '1. READ EVERY LINE that could be a medicine, even if messy/faint/smudged/unclear. '
      'Make your best guess — DO NOT SKIP a line just because you are not 100% certain.\n'
      '2. Partial reads are fine: write what you can see; mark unclear parts with "?".\n'
      '3. If quantity not visible, use qty=1.\n'
      '4. NEVER return an empty JSON array [] unless image is genuinely blank/selfie/landscape.\n'
      '5. Return items in top-to-bottom order.\n\n'
      'Return ONLY a valid JSON array. For each entry include a TIGHT bbox around ONLY '
      'the handwritten medicine/brand NAME for that line — nothing else:\n'
      '[{"name": "medicine name as written", "qty": 5, "bbox": {"x": 0.05, "y": 0.12, "w": 0.38, "h": 0.04}}]\n'
      'BBOX RULES (all values 0.0–1.0 fraction of image width/height):\n'
      '  x = left edge of first letter of the name\n'
      '  y = TOP of the tallest letter glyph in this name (NOT the ruled line above)\n'
      '  w = width ending at the RIGHT edge of the LAST letter of the name — '
      'STOP BEFORE any quantity digit, slash, dash, or number column\n'
      '  h = distance from top of tallest glyph to BOTTOM of lowest glyph ONLY — '
      'STOP BEFORE any ruled line or underline below the text. '
      'The ruled line is OUTSIDE the bbox. Make h as tight as possible '
      'so only ink strokes are inside; a ruled underline must be fully below bbox.bottom.';

  static const _geminiImageFallbackPrompt =
      'This is a photo of a handwritten list of medicines from a pharmacy. '
      'Some lines may be hard to read because of faint ink, blur, or angle.\n\n'
      'For EVERY line that has a word that could be a medicine or drug name:\n'
      '- Write down the word(s) as best you can read them (even if uncertain).\n'
      '- Write the number next to it if there is one; otherwise use 1.\n\n'
      'Do NOT leave out any line just because it is unclear — include it with your best guess.\n'
      'Do NOT return [] (empty). If you can see any words at all in the list, include them.\n\n'
      'Respond with ONLY this JSON. Include a TIGHT bbox around ONLY the name ink strokes '
      '(not the quantity, not ruled lines — stop the bbox BEFORE any ruled underline):\n'
      '[{"name": "what you can read", "qty": 1, "bbox": {"x": 0.05, "y": 0.12, "w": 0.38, "h": 0.04}}]';

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

  Future<_MatchRow> _matchOne(String name, int qty, {Rect? bbox}) async {
    // Strip punctuation noise common in handwritten/OCR orders:
    // • ,()*%  → always noise
    // • trailing/mid-word periods ("Tab.", "B. Cream", "Cap.") → abbreviation markers
    //   but preserve decimal points in dosage numbers ("30.5mg" → keep "." before digit)
    final term = name
        .replaceAll(RegExp(r'[,()*%]'), ' ')
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
      return _MatchRow(
        lineItem: name,
        qty: qty,
        status: topScore >= 0.40 ? _MatchStatus.matched : _MatchStatus.partial,
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
    list = list.where((row) {
      if (!row.containsKey('status')) return true;
      final s = (row['status'] as String? ?? '').toLowerCase();
      return s == 'available' || s == 'active' || s == '1' || s == 'true';
    }).toList();

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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${entries.length} sample items added · auto-removed in 15s'),
          behavior: SnackBarBehavior.floating,
        ));
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
          row.selectedProduct != null;

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
        final priorQty = cart.quantityOf(newProductId);
        cart.setBulkQuantity(product, row.qty, i);
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xFF16A34A),
        behavior: SnackBarBehavior.floating,
      ));
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

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
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
                    onAddToCart: _addMatchedToCart,
                    onHideToggle: _onRowHideToggle,
                    uploadedImageBytes: _uploadedImageBytes,
                    uploadedImageSize: _uploadedImageSize,
                  ),
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
  final Future<void> Function() onAddToCart;
  final void Function(int rowIndex) onHideToggle;
  final Uint8List? uploadedImageBytes;
  final Size? uploadedImageSize;

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
    required this.onAddToCart,
    required this.onHideToggle,
    this.uploadedImageBytes,
    this.uploadedImageSize,
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
                  const Expanded(flex: 35, child: _WhatsAppCard()),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 35,
                    child: _UploadCard(
                      onPickFile: onPickFile,
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
              uploadedImageBytes: uploadedImageBytes,
              uploadedImageSize: uploadedImageSize,
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WhatsAppCard(),
          const SizedBox(height: 16),
          _UploadCard(onPickFile: onPickFile, fileName: fileName, isLoading: isLoading),
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
            uploadedImageBytes: uploadedImageBytes,
            uploadedImageSize: uploadedImageSize,
          ),
        ],
      );
    });
  }
}

// ─── WhatsApp card ────────────────────────────────────────────────────────────

class _WhatsAppCard extends StatelessWidget {
  const _WhatsAppCard();

  void _openWhatsApp() {
    html.window.open(
      'https://wa.me/918357881873?text=Hi%2C%20I%20want%20to%20place%20a%20bulk%20medicine%20order',
      '_blank',
    );
  }

  @override
  Widget build(BuildContext context) {
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
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: _openWhatsApp,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF25D366),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SvgPicture.asset('assets/whatsapp.svg', width: 20, height: 20),
                            const SizedBox(width: 8),
                            const Text(
                              'Send Order on WhatsApp',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
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
  final String? fileName;
  final bool isLoading;

  const _UploadCard({
    required this.onPickFile,
    this.fileName,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
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
                    SizedBox(
                      height: 52,
                      child: fileName != null && !isLoading
                          ? OutlinedButton.icon(
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
                            )
                          : FilledButton.icon(
                              onPressed: isLoading ? null : onPickFile,
                              icon: isLoading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.upload_file_outlined, size: 18),
                              label: Text(
                                isLoading ? 'Processing...' : 'Choose File to Upload',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 12),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF1e2a3a),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                                elevation: 0,
                              ),
                            ),
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
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'HOW IT WORKS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Color(0xFF4ade80),
              letterSpacing: 1.2,
            ),
          ),
          SizedBox(height: 10),
          Text(
            'Three steps to a packed cart.',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.25,
            ),
          ),
          SizedBox(height: 24),
          _Step(1, 'Drop your file.', 'AI detects columns & extracts medicines from any format.'),
          _Step(2, 'Smart matcher pairs each line', 'to the best in-stock SKU.'),
          _Step(3, 'Review, edit, and push to cart', 'in one click.'),
        ],
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
  final Uint8List? uploadedImageBytes;
  final Size? uploadedImageSize;

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
    this.uploadedImageBytes,
    this.uploadedImageSize,
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
                const Text('Smart match preview',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (matched > 0)
                      _StatusPillBadge(label: '✓ $matched Matched', bg: const Color(0xFFDCFCE7), fg: const Color(0xFF15803D)),
                    if (partial > 0)
                      _StatusPillBadge(label: '~ $partial Partial', bg: const Color(0xFFFEF3C7), fg: const Color(0xFF92400E)),
                    if (unrecognized > 0)
                      _StatusPillBadge(label: '✗ $unrecognized Unrecognized', bg: const Color(0xFFFEE2E2), fg: const Color(0xFFDC2626)),
                    if (manuallyMatched > 0)
                      _StatusPillBadge(label: '● $manuallyMatched Manually Matched', bg: const Color(0xFFE0E7FF), fg: const Color(0xFF3730A3)),
                  ],
                ),
                const SizedBox(height: 12),
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
                const SizedBox(height: 12),
              ],
            ),
          ),
          if (widget.isLoading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.matchTotal > 0) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: widget.matchProgress / widget.matchTotal,
                        backgroundColor: const Color(0xFFE5E7EB),
                        valueColor: const AlwaysStoppedAnimation(Color(0xFF16A34A)),
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('${widget.matchProgress} of ${widget.matchTotal} medicines matched',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                  ] else
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      ),
                    ),
                ],
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
                        uploadedImageBytes: widget.uploadedImageBytes,
                        uploadedImageSize: widget.uploadedImageSize,
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
                      Row(children: [
                        Expanded(child: statsText),
                        const SizedBox(width: 8),
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
                      widget.addingToCart ? spinner : addButton,
                    ]),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.matchTotal > 0) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: widget.matchTotal > 0 ? widget.matchProgress / widget.matchTotal : null,
                        backgroundColor: const Color(0xFFE5E7EB),
                        valueColor: const AlwaysStoppedAnimation(Color(0xFF16A34A)),
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('${widget.matchProgress} of ${widget.matchTotal} medicines matched',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                  ] else
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      ),
                    ),
                ],
              ),
            )
          else ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: const BoxDecoration(
                color: Color(0xFFF9FAFB),
                border: Border(
                  top: BorderSide(color: Color(0xFFE5E7EB)),
                  bottom: BorderSide(color: Color(0xFFE5E7EB)),
                ),
              ),
              child: const Row(
                children: [
                  Expanded(flex: 18, child: Text('LINE ITEM', style: _kTh)),
                  Expanded(flex: 20, child: Text('MATCHED SKU', style: _kTh)),
                  Expanded(flex: 8, child: Text('PACK', style: _kTh)),
                  Expanded(flex: 12, child: Text('COMPANY', style: _kTh)),
                  Expanded(flex: 5, child: Text('QTY', style: _kTh)),
                  Expanded(flex: 9, child: Text('MRP', style: _kTh)),
                  Expanded(flex: 10, child: Text('STATUS', textAlign: TextAlign.center, style: _kTh)),
                  SizedBox(width: 12),
                  Expanded(flex: 3, child: Text('HIDE', textAlign: TextAlign.center, style: _kTh)),
                  SizedBox(width: 12),
                  Expanded(flex: 5, child: Text('APPROVE', textAlign: TextAlign.center, style: _kTh)),
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
                uploadedImageBytes: widget.uploadedImageBytes,
                uploadedImageSize: widget.uploadedImageSize,
              ),
          ],
        ],
      ),
    );
  }
}

/// Renders the handwriting crop for a LINE ITEM cell.
/// Shows ONLY the crop image (transparent background, black ink) — no caption.
/// Falls back to raw bbox clip or plain text if processedCrop is unavailable.
Widget _lineItemCrop(_MatchRow row, Uint8List? imageBytes, Size? imageSize,
    {TextStyle? fallbackStyle}) {
  if (row.processedCrop != null) {
    return Tooltip(
      message: row.lineItem,
      waitDuration: const Duration(milliseconds: 400),
      child: Image.memory(
        row.processedCrop!,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        gaplessPlayback: true,
      ),
    );
  }

  final bbox = row.bbox;
  final bytes = imageBytes;
  final imgSize = imageSize;
  if (bbox == null || bytes == null || imgSize == null ||
      bbox.width <= 0 || bbox.height <= 0) {
    debugPrint('[CropFallback] "${row.lineItem}": using text — '
        'processedCrop=null '
        'bbox=${bbox != null ? "ok" : "NULL"} '
        'bytes=${bytes != null ? "ok" : "NULL"} '
        'imgSize=${imgSize != null ? "ok" : "NULL"}');
    return Text(row.lineItem,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: fallbackStyle ??
            const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)));
  }

  return Tooltip(
    message: row.lineItem,
    waitDuration: const Duration(milliseconds: 400),
    child: LayoutBuilder(builder: (context, constraints) {
      final availW = constraints.maxWidth.clamp(20.0, double.infinity);
      final availH =
          constraints.maxHeight.isFinite ? constraints.maxHeight : 22.0;
      final cropX = bbox.left * imgSize.width;
      final cropY = bbox.top * imgSize.height;
      final cropW = bbox.width * imgSize.width;
      final cropH = bbox.height * imgSize.height;
      if (cropW <= 0 || cropH <= 0) {
        return Text(row.lineItem,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: fallbackStyle ??
                const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)));
      }
      final scaleX = availW / cropW;
      final scaleY = availH / cropH;
      final scale = scaleX < scaleY ? scaleX : scaleY;
      return ClipRect(
        child: SizedBox(
          width: availW,
          height: availH,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: -cropX * scale,
                top: -cropY * scale,
                width: imgSize.width * scale,
                height: imgSize.height * scale,
                child:
                    Image.memory(bytes, fit: BoxFit.fill, gaplessPlayback: true),
              ),
            ],
          ),
        ),
      );
    }),
  );
}

const _kTh = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w600,
  color: Color(0xFF9CA3AF),
  letterSpacing: 0.5,
);

class _ExpandableMatchRow extends StatefulWidget {
  final _MatchRow row;
  final int index;
  final bool last;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onRowChanged;
  final VoidCallback onHideToggle;
  final Uint8List? uploadedImageBytes;
  final Size? uploadedImageSize;

  const _ExpandableMatchRow({
    super.key,
    required this.row,
    required this.index,
    required this.last,
    required this.isExpanded,
    required this.onToggle,
    required this.onRowChanged,
    required this.onHideToggle,
    this.uploadedImageBytes,
    this.uploadedImageSize,
  });

  @override
  State<_ExpandableMatchRow> createState() => _ExpandableMatchRowState();
}

class _ExpandableMatchRowState extends State<_ExpandableMatchRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

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

  void _toggleApproval() {
    final row = widget.row;
    if (row.status == _MatchStatus.unrecognized) return;
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
    final hasCandidates = row.candidates.isNotEmpty;

    // Status badge styling
    Color badgeColor;
    Color badgeText;
    String label;
    Color leftBorderColor;
    if (row.isHidden) {
      badgeColor = const Color(0xFFF3F4F6);
      badgeText = const Color(0xFF9CA3AF);
      label = 'Hidden';
      leftBorderColor = const Color(0xFFD1D5DB);
    } else {
      switch (row.status) {
        case _MatchStatus.matched:
          badgeColor = const Color(0xFFDCFCE7);
          badgeText = const Color(0xFF15803D);
          label = 'Matched';
          leftBorderColor = const Color(0xFF15803D);
        case _MatchStatus.manuallyMatched:
          badgeColor = const Color(0xFFE0E7FF);
          badgeText = const Color(0xFF3730A3);
          label = 'Manually Matched';
          leftBorderColor = const Color(0xFF3730A3);
        case _MatchStatus.partial:
          badgeColor = const Color(0xFFFEF3C7);
          badgeText = const Color(0xFF92400E);
          label = 'Partial';
          leftBorderColor = const Color(0xFFEA580C);
        case _MatchStatus.unrecognized:
          badgeColor = const Color(0xFFFEE2E2);
          badgeText = const Color(0xFFDC2626);
          label = 'Unrecognized';
          leftBorderColor = const Color(0xFFDC2626);
      }
    }

    // Top 4 alternates excluding the currently selected candidate, in similarity order
    final alts = <(int, Product)>[];
    for (int i = 0; i < row.candidates.length && alts.length < 4; i++) {
      if (i != row.selectedIndex) alts.add((i, row.candidates[i]));
    }

    final bottomBorder = (!widget.last || widget.isExpanded)
        ? const BorderSide(color: Color(0xFFEEEEEE))
        : BorderSide.none;

    // Ticked when Matched (auto) or Manually Matched.  Partial and Unrecognized are unticked.
    final isApproved = row.status == _MatchStatus.matched ||
        row.status == _MatchStatus.manuallyMatched;

    return Opacity(
      opacity: row.isHidden ? 0.45 : 1.0,
      child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: hasCandidates && !row.isHidden ? widget.onToggle : null,
          child: Container(
            decoration: BoxDecoration(
              color: isEven ? Colors.white : const Color(0xFFFAFAFA),
              border: Border(
                left: BorderSide(color: leftBorderColor, width: 3),
                bottom: bottomBorder,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(17, 12, 12, 12),
            child: Row(
              children: [
                Expanded(
                  flex: 18,
                  child: SizedBox(
                    height: 22,
                    child: _lineItemCrop(
                        row, widget.uploadedImageBytes, widget.uploadedImageSize),
                  ),
                ),
                Expanded(
                  flex: 20,
                  child: Text(
                    row.selectedProduct?.name ??
                        (row.status != _MatchStatus.unrecognized ? row.matchedSku : '—'),
                    maxLines: 1,
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
                Expanded(
                  flex: 8,
                  child: Text(
                    row.selectedProduct != null ? _packShort(row.selectedProduct!) : '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF374151)),
                  ),
                ),
                Expanded(
                  flex: 12,
                  child: Text(
                    row.selectedProduct?.manufacturer ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                  ),
                ),
                Expanded(
                  flex: 5,
                  child: Text('${row.qty}',
                      style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
                ),
                Expanded(
                  flex: 9,
                  child: Text(row.price,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF374151))),
                ),
                // STATUS column — badge fills column
                Expanded(
                  flex: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      color: badgeColor,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(label,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: badgeText)),
                  ),
                ),
                // HIDE column — eye icon centered under its header
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: Center(
                    child: GestureDetector(
                      onTap: widget.onHideToggle,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: Icon(
                          row.isHidden
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 16,
                          color: const Color(0xFF6B7280),
                        ),
                      ),
                    ),
                  ),
                ),
                // APPROVE column — checkbox centered under its header
                const SizedBox(width: 12),
                Expanded(
                  flex: 5,
                  child: Center(
                    child: GestureDetector(
                      onTap: (row.isHidden || row.status == _MatchStatus.unrecognized) ? null : _toggleApproval,
                      behavior: HitTestBehavior.opaque,
                      child: Padding(
                        padding: const EdgeInsets.all(3),
                        child: isApproved
                            ? Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF16A34A),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Icon(Icons.check,
                                    size: 13, color: Colors.white),
                              )
                            : Container(
                                width: 18,
                                height: 18,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color: const Color(0xFF9CA3AF), width: 1.5),
                                ),
                                child: const Icon(Icons.check,
                                    size: 13, color: Color(0xFFD1D5DB)),
                              ),
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
              color: Color(0xFFF3F4F6),
              border: Border(left: BorderSide(color: Color(0xFFE5E7EB), width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int k = 0; k < alts.length; k++)
                  _AlternativeRow(
                    product: alts[k].$2,
                    isSelected: false,
                    isLast: k == alts.length - 1,
                    onTap: () {
                      setState(() {
                        row.selectedIndex = alts[k].$1;
                        row.status = _MatchStatus.manuallyMatched;
                      });
                      widget.onToggle();
                      widget.onRowChanged();
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
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
  final Uint8List? uploadedImageBytes;
  final Size? uploadedImageSize;

  const _MobileExpandableRow({
    super.key,
    required this.row,
    required this.index,
    required this.isExpanded,
    required this.onToggle,
    required this.onRowChanged,
    required this.onHideToggle,
    this.uploadedImageBytes,
    this.uploadedImageSize,
  });

  @override
  State<_MobileExpandableRow> createState() => _MobileExpandableRowState();
}

class _MobileExpandableRowState extends State<_MobileExpandableRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

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

  void _toggleApproval() {
    final row = widget.row;
    if (row.status == _MatchStatus.unrecognized) return;
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

  Widget _altRow(Product p, int origIndex, bool isLast, double nameColW) {
    final row = widget.row;
    final isSelected = row.selectedIndex == origIndex;
    final nameColor = isSelected ? const Color(0xFF16A34A) : const Color(0xFF374151);
    final pack = _packShort(p);
    return GestureDetector(
      onTap: () {
        setState(() {
          row.selectedIndex = origIndex;
          row.status = _MatchStatus.manuallyMatched;
        });
        widget.onToggle();
        widget.onRowChanged();
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFDCFCE7) : const Color(0xFFF3F4F6),
          border: const Border(top: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: Row(
          children: [
            SizedBox(
              width: nameColW,
              child: Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                    color: nameColor,
                  )),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 48,
              child: Text(pack,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF374151))),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(p.manufacturer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 52,
              child: Text(rupees(p.mrp),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: nameColor,
                  )),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final hasCandidates = row.candidates.isNotEmpty;

    Color badgeColor, badgeText, accentColor;
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

    final alts = <(int, Product)>[];
    for (int i = 0; i < row.candidates.length && alts.length < 4; i++) {
      if (i != row.selectedIndex) alts.add((i, row.candidates[i]));
    }

    final p = row.selectedProduct;
    final pack = p != null ? _packShort(p) : '';
    // Ticked when Matched (auto) or Manually Matched.  Partial and Unrecognized are unticked.
    final isApproved = row.status == _MatchStatus.matched ||
        row.status == _MatchStatus.manuallyMatched;

    return LayoutBuilder(builder: (context, constraints) {
      final nameColW = (constraints.maxWidth - 252.0).clamp(50.0, 220.0);
      return Opacity(
        opacity: row.isHidden ? 0.45 : 1.0,
        child: GestureDetector(
          onTap: hasCandidates && !row.isHidden ? widget.onToggle : null,
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
                        // ── Header row ──────────────────────────────────────
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
                          child: Row(
                            children: [
                              Expanded(
                                child: SizedBox(
                                  height: 24,
                                  child: _lineItemCrop(
                                      row,
                                      widget.uploadedImageBytes,
                                      widget.uploadedImageSize,
                                      fallbackStyle: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF111827))),
                                ),
                              ),
                              // Controls cluster — min-sized Row pinned to the right
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
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
                                  GestureDetector(
                                    onTap: widget.onHideToggle,
                                    behavior: HitTestBehavior.opaque,
                                    child: Padding(
                                      padding: const EdgeInsets.all(3),
                                      child: Icon(
                                        row.isHidden
                                            ? Icons.visibility_outlined
                                            : Icons.visibility_off_outlined,
                                        size: 16,
                                        color: const Color(0xFF6B7280),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 112,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                          color: badgeColor,
                                          borderRadius: BorderRadius.circular(8)),
                                      child: Text(label,
                                          textAlign: TextAlign.center,
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                          style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: badgeText)),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: (row.isHidden || row.status == _MatchStatus.unrecognized) ? null : _toggleApproval,
                                    behavior: HitTestBehavior.opaque,
                                    child: Padding(
                                      padding: const EdgeInsets.all(3),
                                      child: isApproved
                                          ? Container(
                                              width: 20,
                                              height: 20,
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF16A34A),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: const Icon(Icons.check,
                                                  size: 14, color: Colors.white),
                                            )
                                          : Container(
                                              width: 20,
                                              height: 20,
                                              decoration: BoxDecoration(
                                                color: Colors.white,
                                                borderRadius: BorderRadius.circular(4),
                                                border: Border.all(
                                                    color: const Color(0xFF9CA3AF), width: 1.5),
                                              ),
                                              child: const Icon(Icons.check,
                                                  size: 14, color: Color(0xFFD1D5DB)),
                                            ),
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
                          padding: const EdgeInsets.fromLTRB(12, 17, 12, 17),
                          child: p != null
                              ? Row(children: [
                                  SizedBox(
                                    width: nameColW,
                                    child: Text(p.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF111827))),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 48,
                                    child: Text(pack,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 11, color: Color(0xFF374151))),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(p.manufacturer,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 11, color: Color(0xFF6B7280))),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 52,
                                    child: Text(row.price,
                                        textAlign: TextAlign.right,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF111827))),
                                  ),
                                ])
                              : Text(
                                  row.status != _MatchStatus.unrecognized
                                      ? row.matchedSku
                                      : 'No match found',
                                  style: const TextStyle(
                                      fontSize: 12, color: Color(0xFF9CA3AF))),
                        ),
                        // ── Expandable alternates — same container = shared column grid ──
                        SizeTransition(
                          sizeFactor: _anim,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (int k = 0; k < alts.length; k++)
                                _altRow(alts[k].$2, alts[k].$1, k == alts.length - 1, nameColW),
                              const Divider(height: 1, thickness: 1, color: Color(0xFFE5E7EB)),
                            ],
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
            // LINE ITEM column — blank spacer
            const Expanded(flex: 18, child: SizedBox()),
            // MATCHED SKU column — product name only (company goes to COMPANY column)
            Expanded(
              flex: 20,
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
            // PACK column
            Expanded(
              flex: 8,
              child: Text(
                packShort,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              ),
            ),
            // COMPANY column — aligned under main row's company cell, ellipsis if long
            Expanded(
              flex: 12,
              child: Text(
                product.manufacturer,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
            ),
            // QTY column — blank spacer
            const Expanded(flex: 5, child: SizedBox()),
            // MRP column — aligned under main row's MRP cell
            Expanded(
              flex: 9,
              child: Text(
                rupees(product.mrp),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: priceColor),
              ),
            ),
            // STATUS / HIDE / APPROVE columns — blank for alternate rows
            const Expanded(flex: 10, child: SizedBox()),
            const SizedBox(width: 12),
            const Expanded(flex: 3, child: SizedBox()),
            const SizedBox(width: 12),
            const Expanded(flex: 5, child: SizedBox()),
          ],
        ),
      ),
    );
  }

  Widget _buildMobile() {
    final textColor = isSelected ? const Color(0xFF16A34A) : const Color(0xFF374151);
    final packShort = _packShort(product);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(9, 9, 4, 9),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFDCFCE7) : const Color(0xFFF3F4F6),
          border: isLast
              ? null
              : const Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: Row(
          children: [
            // LINE ITEM column — blank (indent under parent)
            const SizedBox(width: 100),
            SizedBox(
              width: 120,
              child: Text(
                product.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: textColor,
                ),
              ),
            ),
            SizedBox(
              width: 48,
              child: Text(packShort,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            ),
            SizedBox(
              width: 80,
              child: Text(product.manufacturer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
            ),
            // QTY column — blank
            const SizedBox(width: 34),
            SizedBox(
              width: 54,
              child: Text(rupees(product.mrp),
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w500, color: textColor)),
            ),
            SizedBox(
              width: 116,
              child: isSelected
                  ? const Icon(Icons.check_circle, size: 14, color: Color(0xFF16A34A))
                  : Text('Select',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            ),
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
