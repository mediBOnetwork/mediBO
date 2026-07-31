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

/// The item currently STAGED (scanned but not yet committed). Every field is a
/// value barcode_lookup returned — none of it is derived here.
class _Staged {
  final String barcode;
  final int productId;
  final String name;
  final String imageUrl;
  final String packLabel;
  final String company;
  final String progressLabel;
  final String bagLabel;
  final bool bagWarning;
  /// Staged, not counted. Starts at 1 on the scan that created it (B2).
  int qty = 1;
  _Staged({
    required this.barcode,
    required this.productId,
    required this.name,
    required this.imageUrl,
    required this.packLabel,
    required this.company,
    required this.progressLabel,
    required this.bagLabel,
    required this.bagWarning,
  });
}

// CHANGE #625: the screen has two MODES, and which one it is in is decided by
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

  _Staged? _staged;

  // ok:false payload from barcode_lookup — backend title + message, verbatim.
  String _errTitle = '';
  String _errMessage = '';

  // Bottom bar — every field comes from an RPC response.
  int _countedQty = 0;
  String _progressLabel = '';
  bool _isOver = false;
  int _overQty = 0;

  bool _busy = false;
  bool _anyCommitted = false;

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
    _ctrl = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      detectionTimeoutMs: 700,
    );
    if (widget.isPack) {
      RenderLog.write('c625_pack_barcode',
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
    if (_busy) return;
    final staged = _staged;

    // B2: the SAME barcode again just increments the staged qty. No RPC.
    if (staged != null && staged.barcode == code) {
      setState(() => staged.qty += 1);
      RenderLog.write('c624_barcode_count', 'stage=increment;qty=${staged.qty}');
      return;
    }

    // C2: a DIFFERENT barcode auto-commits what is staged, then stages the new one.
    if (staged != null) {
      await _commit();
      if (!mounted) return;
    }
    await _lookup(code);
  }

  Future<void> _lookup(String code) async {
    setState(() => _busy = true);
    try {
      // CHANGE #625: Pack is order-scoped and has no supplier, stage, date or
      // bag. Supplier Shop / Warehouse keep calling barcode_lookup exactly as
      // they did in #624.
      final raw = widget.isPack
          ? await Supabase.instance.client.rpc('pack_barcode_lookup', params: {
              'p_order_id': widget.orderId,
              'p_barcode': code,
            })
          : await Supabase.instance.client.rpc('barcode_lookup', params: {
              'p_supplier': widget.supplierName,
              'p_barcode': code,
              'p_stage': widget.stage,
              'p_date': _dateYmd,
            });
      if (!mounted) return;
      final res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

      if (res['ok'] != true) {
        // B1: render the backend's own title + message. Nothing is staged.
        // In Pack this also covers `unfulfillable` — an item we could not source,
        // which is not being packed and so cannot be counted.
        if (widget.isPack) {
          RenderLog.write('c625_pack_barcode',
              'lookup=refused;error=${res['error'] ?? ''}');
        }
        RenderLog.write('c624_barcode_count',
            'lookup=refused;error=${res['error'] ?? ''}');
        setState(() {
          _staged = null;
          _errTitle = res['title']?.toString() ?? '';
          _errMessage = res['message']?.toString() ?? '';
        });
        return;
      }

      final s = _Staged(
        barcode: code,
        productId: (res['product_id'] as num?)?.toInt() ?? 0,
        name: res['product_name']?.toString() ?? '',
        imageUrl: res['image_url']?.toString() ?? '',
        packLabel: res['pack_label']?.toString() ?? '',
        company: res['company']?.toString() ?? '',
        progressLabel: res['progress_label']?.toString() ?? '',
        // A2: there is no bag in Pack. pack_barcode_lookup returns no bag
        // fields at all, and this guard makes that explicit rather than
        // relying on the key being absent.
        bagLabel: widget.isPack ? '' : (res['bag_label']?.toString() ?? ''),
        bagWarning: widget.isPack ? false : res['bag_warning'] == true,
      );
      if (widget.isPack) {
        RenderLog.write('c625_pack_barcode',
            'lookup=ok;product=${s.productId};progress=${s.progressLabel};bag=none');
      }
      RenderLog.write('c624_barcode_count',
          'lookup=ok;product=${s.productId};progress=${s.progressLabel};bag_warning=${s.bagWarning}');
      setState(() {
        _staged = s;
        _errTitle = '';
        _errMessage = '';
        _countedQty = (res['counted_qty'] as num?)?.toInt() ?? _countedQty;
        _progressLabel = s.progressLabel;
        _isOver = false;
        _overQty = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _staged = null;
        _errTitle = '';
        _errMessage = FulfillLookups.instance.errorText(e) ?? '';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── commit ────────────────────────────────────────────────────────────────

  /// C3. Returns without a round trip when the staged qty is 0 (C4).
  Future<void> _commit() async {
    final s = _staged;
    if (s == null || _busy) return;

    if (s.qty <= 0) {
      RenderLog.write('c624_barcode_count', 'commit=skipped_zero');
      setState(() => _staged = null);
      return;
    }

    setState(() => _busy = true);
    try {
      // CHANGE #625: Pack commits through pack_barcode_submit_scan, which writes
      // to pack_clip_mentions and applies via pack_set_counted — the SAME
      // function Pack's voice count uses. Supplier Shop / Warehouse are
      // untouched and still call barcode_submit_scan.
      final raw = widget.isPack
          ? await Supabase.instance.client
              .rpc('pack_barcode_submit_scan', params: {
              'p_order_id': widget.orderId,
              'p_product_id': s.productId,
              'p_qty': s.qty,
              'p_session_key': _sessionKey,
            })
          : await Supabase.instance.client.rpc('barcode_submit_scan', params: {
              'p_supplier': widget.supplierName,
              'p_product_id': s.productId,
              'p_qty': s.qty,
              'p_stage': widget.stage,
              'p_date': _dateYmd,
              'p_session_key': _sessionKey,
            });
      if (!mounted) return;
      final res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

      if (res['ok'] != true) {
        if (widget.isPack) {
          RenderLog.write('c625_pack_barcode',
              'commit=refused;error=${res['error'] ?? ''}');
        }
        RenderLog.write('c624_barcode_count',
            'commit=refused;error=${res['error'] ?? ''}');
        setState(() {
          _errTitle = '';
          _errMessage = res['message']?.toString() ??
              (FulfillLookups.instance.message(res['error']?.toString()) ?? '');
          _staged = null;
        });
        return;
      }

      // C5: bottom bar is whatever the commit response says it is.
      if (widget.isPack) {
        RenderLog.write('c625_pack_barcode',
            'commit=ok;qty=${s.qty};counted=${res['counted_qty']};over=${res['over_qty']}');
      }
      RenderLog.write('c624_barcode_count',
          'commit=ok;qty=${s.qty};counted=${res['counted_qty']};over=${res['over_qty']}');
      _anyCommitted = true;
      setState(() {
        _staged = null;
        _errTitle = '';
        _errMessage = '';
        _countedQty = (res['counted_qty'] as num?)?.toInt() ?? 0;
        _progressLabel = res['progress_label']?.toString() ?? '';
        _isOver = res['is_over'] == true;
        _overQty = (res['over_qty'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errTitle = '';
        _errMessage = FulfillLookups.instance.errorText(e) ?? '';
        _staged = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // B3/B4: image tap zones. Down to 0 but never below; at 0 the product stays
  // on screen so a mis-tap is undone by tapping right again.
  void _bump(int delta) {
    final s = _staged;
    if (s == null) return;
    final next = s.qty + delta;
    if (next < 0) return;
    setState(() => s.qty = next);
    RenderLog.write('c624_barcode_count', 'tap=$delta;qty=${s.qty}');
  }

  Future<void> _closeScreen() async {
    // A staged item is flushed on the way out, through the same zero-guarded
    // commit path — so nothing counted is silently lost, and a qty tapped down
    // to 0 still writes nothing.
    if (_staged != null) await _commit();
    if (!mounted) return;
    Navigator.of(context).pop(_anyCommitted);
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

  Widget _buildHeadline(FulfillLookups lk, _Staged? s) {
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

  Widget _buildImageArea(FulfillLookups lk, _Staged? s) {
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
