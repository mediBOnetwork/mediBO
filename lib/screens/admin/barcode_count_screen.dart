// CHANGE #624 → COUNT MODE — the unified counting session (camera + voice).
//
// One full-screen session per fulfillment tab: the camera scans continuously
// (all formats, zero restarts between commits) while the TAB's own voice
// engine keeps running in parallel underneath the pushed route. This screen
// calls exactly the counting RPCs and renders their payloads:
//   barcode_lookup / barcode_submit_scan            Supplier Shop / Warehouse
//   pack_barcode_lookup / pack_barcode_submit_scan  Pack
//   medicine_set_barcode                            teach an unknown code
//
// Nothing is decided here. Every user-facing string comes from the backend:
// the copy catalog (fw_ui_labels, via FulfillLookups) for the static chrome,
// and the RPC payloads themselves for product name, image, pack, company,
// progress_label, bag_label, batch, expiry_label, every expiry_warning colour,
// every skipped message and the ok:false title/message. The raw scan string is
// sent to the backend EXACTLY as decoded (p_raw) — gs1_parse owns all parsing.
//
// The voice pipeline is NOT duplicated here: CountVoiceHooks exposes the tab's
// existing engine (toggle + status) and CountVoiceBar renders it verbatim. The
// backend merges the two streams (a scan just after a voice mention comes back
// skipped:voice_merged, rendered like every other skip).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/barcode_count_logic.dart';
import '../../fulfill/count_voice_bar.dart';
import '../../fulfill/count_voice_hooks.dart';
import '../../fulfill/fulfill_lookups.dart';
import '../../services/admin_date_scope.dart';
import '../../utils/render_log.dart';

Color get _kGreen    => FulfillLookups.instance.color('c_ff1b7a43');
Color get _kBorder   => FulfillLookups.instance.color('c_ffe5e7eb');
Color get _kText     => FulfillLookups.instance.color('c_ff111827');
Color get _kSub      => FulfillLookups.instance.color('c_ff6b7280');
Color get _kWrongFg  => FulfillLookups.instance.color('c_ffb42318');
Color get _kBlack    => FulfillLookups.instance.color('c_ff000000', const Color(0xFF000000));
Color get _kTileBg   => FulfillLookups.instance.color('c_fff3f4f6');
Color get _kTileIcon => FulfillLookups.instance.color('c_ffd1d5db');

/// A backend '#RRGGBB' string → Color. Same parse as mention_hold_row.dart; the
/// VALUE is always the payload's, this only decodes the hex notation.
Color _payloadColor(dynamic raw, Color fallback) {
  final h = (raw?.toString() ?? '').replaceFirst('#', '');
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? fallback : Color(v);
}

// CHANGE #635: the staged item and the whole scan → stage → commit state machine
// live in fulfill/barcode_count_logic.dart (BarcodeStaged / BarcodeCountLogic),
// so test/protected/barcode_count_test.dart can drive them without a camera.
// This file is the renderer.

// CHANGE #627: the screen has two MODES, and which one it is in is decided by
// the constructor the caller uses — never inferred from an empty string.
//
//   BarcodeCountScreen.supplier(supplierName:, stage:)  Supplier Shop / Warehouse
//     → barcode_lookup / barcode_submit_scan            (supplier + stage scoped)
//
//   BarcodeCountScreen.pack(orderId:)                   Pack
//     → pack_barcode_lookup / pack_barcode_submit_scan  (order scoped, no bag)
//
// The two RPC families write to different tables and must never be crossed:
// a Pack scan sent to barcode_submit_scan would land in the shop receiving
// ledger. `isPack` is the single switch, and it is derived from orderId being
// non-null, which only the .pack constructor can produce.
class BarcodeCountScreen extends StatefulWidget {
  /// Supplier mode only. The supplier whose order is being counted.
  final String supplierName;

  /// Supplier mode only. 'shop' | 'warehouse' — passed straight through to both
  /// RPCs. The backend re-derives the effective stage (a forwarded supplier is
  /// always warehouse).
  final String stage;

  /// Pack mode only. The customer order being packed. Non-null IS pack mode.
  final String? orderId;

  /// COUNT MODE — the tab's voice engine, exposed to this screen. Null when the
  /// caller has no voice surface; the bar simply does not render then.
  final CountVoiceHooks? voice;

  /// Supplier Shop / Warehouse. Unchanged from #624.
  const BarcodeCountScreen.supplier({
    super.key,
    required this.supplierName,
    required this.stage,
    this.voice,
  }) : orderId = null;

  /// Pack. There is no supplier and no bag in this mode.
  const BarcodeCountScreen.pack({
    super.key,
    required String this.orderId,
    this.voice,
  })  : supplierName = '',
        stage = '';

  /// True when this screen must use the pack_* RPCs.
  bool get isPack => orderId != null;

  @override
  State<BarcodeCountScreen> createState() => _BarcodeCountScreenState();
}

class _BarcodeCountScreenState extends State<BarcodeCountScreen> {
  late final MobileScannerController _ctrl;

  /// C6: generated ONCE when the screen opens, reused for every scan.
  late final String _sessionKey;

  /// CHANGE #635 — all scan/stage/commit state and both RPC calls live here.
  late final BarcodeCountLogic _logic;

  BarcodeStaged? get _staged => _logic.staged;
  String get _errTitle => _logic.errTitle;
  String get _errMessage => _logic.errMessage;
  int get _countedQty => _logic.countedQty;
  String get _progressLabel => _logic.progressLabel;
  bool get _isOver => _logic.isOver;
  int get _overQty => _logic.overQty;
  bool get _busy => _logic.busy;

  // Dart-side scan throttle on top of the controller's own detectionTimeoutMs,
  // so one barcode held in front of the lens does not spam +1.
  String _lastCode = '';
  DateTime _lastCodeAt = DateTime.fromMillisecondsSinceEpoch(0);

  // COUNT MODE — last commit outcome already reacted to (toast/haptic). The
  // logic bumps commitSeq once per outcome, so auto-commit inside handleCode
  // and an explicit swipe can never double-toast.
  int _seenCommitSeq = 0;

  // COUNT MODE — the tab's voice state, polled while this route is on top.
  CountVoiceStatus _voiceStatus = const CountVoiceStatus();
  Timer? _voicePoll;

  String? get _dateYmd => AdminDateScope.instance.dateYmd;

  @override
  void initState() {
    super.initState();
    final ms = DateTime.now().millisecondsSinceEpoch;
    _sessionKey = widget.isPack
        ? 'packbc:${widget.orderId}|$ms'
        : 'barcode:${widget.supplierName}|${widget.stage}|$ms';
    _logic = BarcodeCountLogic(
      isPack: widget.isPack,
      supplierName: widget.supplierName,
      stage: widget.stage,
      orderId: widget.orderId,
      sessionKey: _sessionKey,
      rpc: (fn, params) =>
          Supabase.instance.client.rpc(fn, params: params),
      dateYmd: () => _dateYmd,
      errorText: (e) => FulfillLookups.instance.errorText(e) ?? '',
      messageForCode: (code) => FulfillLookups.instance.message(code) ?? '',
      onChanged: _onLogicChanged,
    );
    // COUNT MODE — every format the spec names, configured explicitly. The
    // camera starts once here and never restarts between commits.
    _ctrl = MobileScannerController(
      formats: const [
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.upcA,
        BarcodeFormat.code39,
        BarcodeFormat.code128,
        BarcodeFormat.dataMatrix,
        BarcodeFormat.qrCode,
        BarcodeFormat.pdf417,
      ],
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 700,
    );
    // COUNT MODE — Android volume-up = +1 on the staged item.
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    if (widget.voice != null) {
      _voiceStatus = widget.voice!.status();
      _voicePoll = Timer.periodic(
          const Duration(milliseconds: 300), (_) => _pollVoice());
    }
    if (widget.isPack) {
      RenderLog.write('c627_pack_barcode',
          'screen=open;mode=pack;order=${widget.orderId};session=$_sessionKey');
    }
    RenderLog.write('c624_barcode_count',
        'screen=open;mode=${widget.isPack ? 'pack' : 'supplier'};supplier=${widget.supplierName};stage=${widget.stage};session=$_sessionKey;voice=${widget.voice != null}');
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _voicePoll?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  // ── voice bridge ──────────────────────────────────────────────────────────

  void _pollVoice() {
    final hooks = widget.voice;
    if (hooks == null || !mounted) return;
    final next = hooks.status();
    final cur = _voiceStatus;
    if (next.supported != cur.supported ||
        next.listening != cur.listening ||
        next.processing != cur.processing ||
        next.caption != cur.caption ||
        next.hint != cur.hint ||
        next.error != cur.error ||
        next.bagLabel != cur.bagLabel) {
      setState(() => _voiceStatus = next);
    }
  }

  // ── outcome reactions (haptic + verbatim toast) ───────────────────────────

  void _onLogicChanged() {
    if (!mounted) return;
    if (_logic.commitSeq != _seenCommitSeq) {
      _seenCommitSeq = _logic.commitSeq;
      switch (_logic.lastCommitEvent) {
        case 'committed':
          // Haptic on every successful commit.
          HapticFeedback.mediumImpact();
          break;
        case 'skipped':
          // duplicate_serial / duplicate_scan / voice_merged / zero_qty —
          // the backend's own sentence, verbatim.
          if (_logic.skippedMessage.isNotEmpty) _toast(_logic.skippedMessage);
          RenderLog.write('c624_barcode_count',
              'commit=skipped;code=${_logic.skipped}');
          break;
      }
    }
    setState(() {});
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
  }

  // ── hardware keys ─────────────────────────────────────────────────────────

  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.audioVolumeUp) return false;
    if (_logic.staged == null) return false;
    _bump(1);
    return true;
  }

  // ── scan intake ───────────────────────────────────────────────────────────

  void _onDetect(BarcodeCapture capture) {
    final code = _pickCenterNearest(capture);
    if (code.trim().isEmpty) return;
    final now = DateTime.now();
    if (code == _lastCode && now.difference(_lastCodeAt).inMilliseconds < 900) {
      return;
    }
    _lastCode = code;
    _lastCodeAt = now;
    HapticFeedback.selectionClick();
    _handleCode(code.trim());
  }

  /// COUNT MODE — when several codes are in frame, take the one whose
  /// bounding-box centre is nearest the frame centre. Falls back to the first
  /// code when corner geometry is unavailable (web BarcodeDetector).
  String _pickCenterNearest(BarcodeCapture capture) {
    final codes = capture.barcodes;
    if (codes.isEmpty) return '';
    if (codes.length == 1) return codes.first.rawValue ?? '';
    final size = capture.size;
    if (size.isEmpty) return codes.first.rawValue ?? '';
    final center = Offset(size.width / 2, size.height / 2);
    String best = codes.first.rawValue ?? '';
    double bestD = double.infinity;
    for (final b in codes) {
      final raw = b.rawValue ?? '';
      if (raw.isEmpty || b.corners.isEmpty) continue;
      double cx = 0, cy = 0;
      for (final c in b.corners) {
        cx += c.dx;
        cy += c.dy;
      }
      cx /= b.corners.length;
      cy /= b.corners.length;
      final d = (cx - center.dx) * (cx - center.dx) +
          (cy - center.dy) * (cy - center.dy);
      if (d < bestD) {
        bestD = d;
        best = raw;
      }
    }
    return best;
  }

  Future<void> _handleCode(String code) async {
    // CHANGE #635 — every decision below (same-code increment, auto-commit of the
    // previous stage, the RPC calls themselves) lives in BarcodeCountLogic.
    final before = _logic.staged;
    final wasSameCode = before != null && before.barcode == code;
    await _logic.handleCode(code);
    if (wasSameCode) {
      RenderLog.write('c624_barcode_count',
          'stage=increment;qty=${_logic.staged?.qty}');
      return;
    }
    final s = _logic.staged;
    if (s == null) {
      if (widget.isPack) {
        RenderLog.write('c627_pack_barcode', 'lookup=refused');
      }
      RenderLog.write('c624_barcode_count',
          'lookup=refused;teach=${_logic.canTeach}');
    } else {
      if (widget.isPack) {
        RenderLog.write('c627_pack_barcode',
            'lookup=ok;product=${s.productId};progress=${s.progressLabel};bag=none');
      }
      RenderLog.write('c624_barcode_count',
          'lookup=ok;product=${s.productId};progress=${s.progressLabel};bag_warning=${s.bagWarning}');
    }
  }

  Future<void> _commit() async {
    final s = _logic.staged;
    if (s == null) return;
    final qty = s.qty;
    if (qty <= 0) {
      RenderLog.write('c624_barcode_count', 'commit=skipped_zero');
      await _logic.commit();
      return;
    }
    final committedBefore = _logic.anyCommitted;
    await _logic.commit();
    if (!_logic.anyCommitted && !committedBefore) {
      if (widget.isPack) {
        RenderLog.write('c627_pack_barcode', 'commit=refused');
      }
      RenderLog.write('c624_barcode_count', 'commit=refused');
      return;
    }
    if (widget.isPack) {
      RenderLog.write('c627_pack_barcode',
          'commit=ok;qty=$qty;counted=${_logic.countedQty};over=${_logic.overQty}');
    }
    RenderLog.write('c624_barcode_count',
        'commit=ok;qty=$qty;counted=${_logic.countedQty};over=${_logic.overQty}');
  }

  // B3/B4: image tap zones. Down to 0 but never below; at 0 the product stays
  // on screen so a mis-tap is undone by tapping right again.
  void _bump(int delta) {
    HapticFeedback.selectionClick();
    _logic.bump(delta);
    RenderLog.write('c624_barcode_count', 'tap=$delta;qty=${_logic.staged?.qty}');
  }

  Future<void> _closeScreen() async {
    // A staged item is flushed on the way out, through the same zero-guarded
    // commit path — so nothing counted is silently lost, and a qty tapped down
    // to 0 still writes nothing.
    if (_logic.staged != null) await _commit();
    if (!mounted) return;
    Navigator.of(context).pop(_logic.anyCommitted);
  }

  // ── teach flow ────────────────────────────────────────────────────────────

  Future<void> _openTeachSheet() async {
    final lk = FulfillLookups.instance;
    RenderLog.write('c624_barcode_count',
        'teach=open;code=${_logic.teachBarcode}');
    final pid = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _TeachSheet(
        hint: _logic.teachHint,
        searchHint: lk.ui('barcode_teach_search'),
      ),
    );
    if (pid == null || !mounted) return;
    await _logic.teach(pid);
    RenderLog.write('c624_barcode_count',
        'teach=saved;product=$pid;staged=${_logic.staged?.productId}');
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final lk = FulfillLookups.instance;
    final s = _staged;
    final screenH = MediaQuery.of(context).size.height;
    final viewfinderH = (screenH * 0.30).clamp(180.0, 300.0);

    RenderLog.write('c624_barcode_count',
        'build;stage=${widget.stage};staged=${s == null ? 'none' : s.productId};count=$_countedQty');

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeScreen();
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          foregroundColor: _kText,
          title: Text(lk.ui('barcode_count'),
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _closeScreen,
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 1. Viewfinder — continuous camera, reticle, torch.
            SizedBox(
              height: viewfinderH,
              child: Container(
                color: _kBlack,
                child: Stack(children: [
                  Positioned.fill(
                    child: MobileScanner(
                      controller: _ctrl,
                      onDetect: _onDetect,
                      errorBuilder: (ctx, error, _) => Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.camera_alt_outlined,
                              size: 40, color: _kTileIcon),
                          const SizedBox(height: 8),
                          Text(lk.ui('camera_unavailable'),
                              style:
                                  TextStyle(color: _kTileIcon, fontSize: 13)),
                          const SizedBox(height: 2),
                          Text(error.errorCode.name,
                              style:
                                  TextStyle(color: _kTileIcon, fontSize: 11)),
                        ]),
                      ),
                    ),
                  ),
                  // COUNT MODE — centre reticle. Pure chrome, never a decision.
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          width: 210,
                          height: 110,
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: Colors.white.withValues(alpha: 0.65),
                                width: 2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // COUNT MODE — torch toggle, hidden when unavailable.
                  Positioned(
                    top: 6,
                    right: 6,
                    child: ValueListenableBuilder<MobileScannerState>(
                      valueListenable: _ctrl,
                      builder: (_, st, __) {
                        if (st.torchState == TorchState.unavailable) {
                          return const SizedBox.shrink();
                        }
                        final on = st.torchState == TorchState.on;
                        return IconButton(
                          icon: Icon(
                            on
                                ? Icons.flash_on_rounded
                                : Icons.flash_off_rounded,
                            color: Colors.white,
                          ),
                          onPressed: () async {
                            try {
                              await _ctrl.toggleTorch();
                            } catch (_) {}
                          },
                        );
                      },
                    ),
                  ),
                ]),
              ),
            ),

            // 2. COUNT MODE — the tab's voice engine, running in parallel.
            if (widget.voice != null)
              CountVoiceBar(
                  status: _voiceStatus, onToggle: widget.voice!.toggle),

            // 3. Product name + staged quantity (or error / teach / idle)
            _buildHeadline(lk, s),

            // 4. Large product image area with the three invisible tap zones
            Expanded(child: _buildImageArea(lk, s)),

            // 5. Bottom "Count N" bar
            _buildCountBar(lk),
          ],
        ),
      ),
    );
  }

  /// The backend's expiry_warning block → chip. Label AND all three colours are
  /// the payload's own; `show` is the backend's visibility decision.
  Widget? _expiryChip(Map<String, dynamic> w) {
    if (w['show'] != true) return null;
    final label = w['label']?.toString() ?? '';
    if (label.isEmpty) return null;
    final colors =
        w['colors'] is Map ? Map<String, dynamic>.from(w['colors'] as Map) : const <String, dynamic>{};
    final bg = _payloadColor(colors['bg'], _kTileBg);
    final fg = _payloadColor(colors['fg'], _kText);
    final border = _payloadColor(colors['border'], _kBorder);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  Widget _buildHeadline(FulfillLookups lk, BarcodeStaged? s) {
    if (s == null) {
      final hasError = _errTitle.isNotEmpty || _errMessage.isNotEmpty;
      final commitChip = _expiryChip(_logic.commitExpiry);
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (hasError) ...[
            if (_errTitle.isNotEmpty)
              Text(_errTitle,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: _kWrongFg)),
            if (_errMessage.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(_errMessage,
                  style: TextStyle(fontSize: 13, color: _kSub)),
            ],
            // TEACH — unknown_barcode + can_teach:true. The button label is
            // catalog copy; the hint is the lookup payload's own.
            if (_logic.canTeach) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _openTeachSheet,
                  icon: Icon(Icons.add_link_rounded, size: 18, color: _kGreen),
                  label: Text(lk.ui('barcode_teach_open'),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: _kGreen)),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: _kGreen),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                  ),
                ),
              ),
            ],
          ] else ...[
            Text(lk.ui('barcode_idle'),
                style: TextStyle(fontSize: 14, color: _kSub)),
            // Commit response's expiry_warning, shown after the card clears.
            if (commitChip != null) ...[
              const SizedBox(height: 6),
              commitChip,
            ],
          ],
          const SizedBox(height: 4),
          Text(lk.ui('barcode_scan_hint'),
              style: TextStyle(fontSize: 12, color: _kSub)),
        ]),
      );
    }

    final stagedChip = _expiryChip(s.expiryWarning);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w700, color: _kText)),
            if (s.packLabel.isNotEmpty || s.company.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                [s.packLabel, s.company].where((v) => v.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: _kSub),
              ),
            ],
            // COUNT MODE — GS1 batch + expiry, verbatim from barcode_lookup.
            // The batch sentence is catalog copy with the payload value filled
            // into its {batch} slot; expiry_label is the payload's own string.
            if (s.batch.isNotEmpty || s.expiryLabel.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                [
                  if (s.batch.isNotEmpty)
                    lk.uiFill('barcode_batch_label', {'batch': s.batch}),
                  if (s.expiryLabel.isNotEmpty) s.expiryLabel,
                ].where((v) => v.isNotEmpty).join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: _kSub),
              ),
            ],
            if (s.progressLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(s.progressLabel,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: _kGreen)),
            ],
            // E1: warehouse bag, straight from barcode_lookup.
            if (s.bagLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(s.bagLabel,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: s.bagWarning ? _kWrongFg : _kSub)),
            ],
            if (stagedChip != null) ...[
              const SizedBox(height: 6),
              stagedChip,
            ],
          ]),
        ),
        const SizedBox(width: 12),
        // Staged quantity
        Container(
          constraints: const BoxConstraints(minWidth: 56),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _kGreen,
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Text('${s.qty}',
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
        ),
      ]),
    );
  }

  Widget _buildImageArea(FulfillLookups lk, BarcodeStaged? s) {
    final image = (s == null || s.imageUrl.isEmpty)
        ? Container(
            color: _kTileBg,
            alignment: Alignment.center,
            child: Icon(Icons.medication_outlined, size: 72, color: _kTileIcon),
          )
        : Image.network(
            s.imageUrl,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Container(
              color: _kTileBg,
              alignment: Alignment.center,
              child: Icon(Icons.medication_outlined, size: 72, color: _kTileIcon),
            ),
          );

    final body = Stack(children: [
      Positioned.fill(child: image),
      // B3: three invisible vertical zones — left −1, centre nothing, right +1.
      // Confined to the image area only.
      if (s != null)
        Positioned.fill(
          child: Row(children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _bump(-1),
                child: const SizedBox.expand(),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: const SizedBox.expand(),
              ),
            ),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _bump(1),
                child: const SizedBox.expand(),
              ),
            ),
          ]),
        ),
      if (s != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 6,
          child: IgnorePointer(
            child: Text(
              '${lk.ui('barcode_tap_hint')} · ${lk.ui('barcode_swipe_hint')}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: _kSub),
            ),
          ),
        ),
    ]);

    // C1: swipe right on the staged item commits it.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (d) {
        if (_staged == null) return;
        if ((d.primaryVelocity ?? 0) > 250) {
          RenderLog.write('c624_barcode_count', 'swipe=commit');
          _commit();
        }
      },
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        decoration: BoxDecoration(
          color: _kTileBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: body,
      ),
    );
  }

  Widget _buildCountBar(FulfillLookups lk) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: _kBorder)),
      ),
      child: Row(children: [
        Text(lk.uiCount('barcode_count_bar', _countedQty) ?? '',
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w800, color: _kText)),
        const SizedBox(width: 10),
        if (_progressLabel.isNotEmpty)
          // C5 / COUNT MODE: is_over from the commit response flips the
          // progress read-out red — the backend decided over-ness.
          Text(_progressLabel,
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _isOver ? _kWrongFg : _kSub)),
        const Spacer(),
        // C5: over-count in red, straight from the commit response.
        if (_isOver)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _kWrongFg.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _kWrongFg.withValues(alpha: 0.35)),
            ),
            child: Text(lk.uiCount('barcode_over_by', _overQty) ?? '',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: _kWrongFg)),
          ),
        if (_busy) ...[
          const SizedBox(width: 10),
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: _kGreen),
          ),
        ],
      ]),
    );
  }
}

// ── teach sheet ─────────────────────────────────────────────────────────────

/// TEACH — pick the product the unknown code belongs to. Search runs through
/// search_medicines_priority (the same RPC every product search uses); each row
/// prints the payload's product_name / pack_qty / marketer verbatim. Picking a
/// row pops its product id; the caller does the medicine_set_barcode save and
/// the re-lookup. The sheet itself decides nothing.
class _TeachSheet extends StatefulWidget {
  /// The lookup payload's teach_hint, verbatim.
  final String hint;

  /// Catalog copy for the search field placeholder.
  final String searchHint;

  const _TeachSheet({required this.hint, required this.searchHint});

  @override
  State<_TeachSheet> createState() => _TeachSheetState();
}

class _TeachSheetState extends State<_TeachSheet> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  bool _busy = false;
  List<Map<String, dynamic>> _results = [];

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(v));
  }

  Future<void> _search(String q) async {
    if (q.trim().length < 2) {
      if (mounted) setState(() => _results = []);
      return;
    }
    setState(() => _busy = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('search_medicines_priority', params: {
        'search_term': q.trim(),
        'category_filter': 'All',
        'page_offset': 0,
        'page_limit': 8,
      });
      if (!mounted) return;
      setState(() => _results = List<Map<String, dynamic>>.from(rows as List));
    } catch (_) {
      if (mounted) setState(() => _results = []);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.hint.isNotEmpty) ...[
            Text(widget.hint,
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: _kText)),
            const SizedBox(height: 10),
          ],
          TextField(
            controller: _ctrl,
            autofocus: true,
            onChanged: _onChanged,
            decoration: InputDecoration(
              hintText: widget.searchHint,
              hintStyle: TextStyle(color: _kSub),
              prefixIcon: Icon(Icons.search, size: 20, color: _kSub),
              suffixIcon: _busy
                  ? Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: _kGreen)))
                  : null,
              isDense: true,
              filled: true,
              fillColor: _kTileBg,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: _kBorder)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: _kBorder)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: _kGreen)),
            ),
            style: TextStyle(fontSize: 15, color: _kText),
          ),
          for (final r in _results) ...[
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                final id = r['id'];
                final pid = id is int ? id : int.tryParse('$id');
                if (pid == null) return;
                Navigator.of(context).pop(pid);
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _kTileBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _kBorder),
                ),
                child: Row(children: [
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text((r['product_name'] ?? '').toString(),
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: _kText),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 2),
                        Text(
                          [
                            (r['pack_qty'] ?? '').toString(),
                            (r['marketer'] ?? '').toString()
                          ].where((v) => v.trim().isNotEmpty).join(' · '),
                          style: TextStyle(fontSize: 12, color: _kSub),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ])),
                  Icon(Icons.chevron_right, size: 20, color: _kTileIcon),
                ]),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
