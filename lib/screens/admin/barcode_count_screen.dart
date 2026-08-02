// CHANGE #624 — BARCODE COUNT (second counting method, alongside voice)
//
// This screen captures scans and calls exactly two RPCs:
//   barcode_lookup      — identify the scanned code against this supplier's order
//   barcode_submit_scan — commit a staged quantity into the SAME counting
//                         pipeline voice already writes to (voice_clip_mentions
//                         → set_voice_received / bag_count_set)
//
// Nothing is decided here. Every user-facing string comes from the backend:
// the copy catalog (fw_ui_labels, via FulfillLookups) for the static chrome,
// and the RPC payloads themselves for product name, image, pack, company,
// progress_label, bag_label and the ok:false title/message. No total, no
// fraction and no error sentence is composed in Dart.
//
// The voice counting path is NOT touched by this file.

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/barcode_count_logic.dart';
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

// CHANGE #635: the staged item and the whole scan → stage → commit state machine
// now live in fulfill/barcode_count_logic.dart (BarcodeStaged / BarcodeCountLogic),
// so test/protected/barcode_count_test.dart can drive them without a camera. This
// file is the renderer.

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

  /// Supplier Shop / Warehouse. Unchanged from #624.
  const BarcodeCountScreen.supplier({
    super.key,
    required this.supplierName,
    required this.stage,
  }) : orderId = null;

  /// Pack. There is no supplier and no bag in this mode.
  const BarcodeCountScreen.pack({
    super.key,
    required String this.orderId,
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
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    _ctrl = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 700,
    );
    if (widget.isPack) {
      RenderLog.write('c627_pack_barcode',
          'screen=open;mode=pack;order=${widget.orderId};session=$_sessionKey');
    }
    RenderLog.write('c624_barcode_count',
        'screen=open;mode=${widget.isPack ? 'pack' : 'supplier'};supplier=${widget.supplierName};stage=${widget.stage};session=$_sessionKey');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  // ── scan intake ───────────────────────────────────────────────────────────

  void _onDetect(BarcodeCapture capture) {
    final code = capture.barcodes.isNotEmpty
        ? (capture.barcodes.first.rawValue ?? '')
        : '';
    if (code.trim().isEmpty) return;
    final now = DateTime.now();
    if (code == _lastCode && now.difference(_lastCodeAt).inMilliseconds < 900) {
      return;
    }
    _lastCode = code;
    _lastCodeAt = now;
    _handleCode(code.trim());
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
      RenderLog.write('c624_barcode_count', 'lookup=refused');
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
            // 1. Viewfinder
            SizedBox(
              height: viewfinderH,
              child: Container(
                color: _kBlack,
                child: MobileScanner(
                  controller: _ctrl,
                  onDetect: _onDetect,
                  errorBuilder: (ctx, error, _) => Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.camera_alt_outlined, size: 40, color: _kTileIcon),
                      const SizedBox(height: 8),
                      Text(lk.ui('camera_unavailable'),
                          style: TextStyle(color: _kTileIcon, fontSize: 13)),
                      const SizedBox(height: 2),
                      Text(error.errorCode.name,
                          style: TextStyle(color: _kTileIcon, fontSize: 11)),
                    ]),
                  ),
                ),
              ),
            ),

            // 2. Product name + staged quantity
            _buildHeadline(lk, s),

            // 3. Large product image area with the three invisible tap zones
            Expanded(child: _buildImageArea(lk, s)),

            // 4. Bottom "Count N" bar
            _buildCountBar(lk),
          ],
        ),
      ),
    );
  }

  Widget _buildHeadline(FulfillLookups lk, BarcodeStaged? s) {
    if (s == null) {
      final hasError = _errTitle.isNotEmpty || _errMessage.isNotEmpty;
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
          ] else
            Text(lk.ui('barcode_idle'),
                style: TextStyle(fontSize: 14, color: _kSub)),
          const SizedBox(height: 4),
          Text(lk.ui('barcode_scan_hint'),
              style: TextStyle(fontSize: 12, color: _kSub)),
        ]),
      );
    }

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
          Text(_progressLabel,
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: _kSub)),
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
