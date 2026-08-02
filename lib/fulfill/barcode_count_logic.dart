// CHANGE #635 — the barcode counting flow's state machine, lifted out of
// BarcodeCountScreen so it can be tested without a camera.
//
// The screen previously held the staging rules, the auto-commit-on-new-code
// rule, the zero-qty discard rule and both RPC calls inside a State class that
// also owned a MobileScannerController and reached for Supabase.instance.client.
// None of that is reachable from a test: constructing the widget starts a camera
// plugin, and the RPC calls have no seam.
//
// Nothing about the BEHAVIOUR changed in this extraction. Every branch below is
// the #624/#627 logic moved verbatim; the only additions are the [rpc] seam and
// the [onChanged] notification the screen turns into setState.
//
// The rules this file is the single home of:
//   B2  the same barcode again increments the staged qty — no RPC
//   C2  a different barcode auto-commits what is staged, then looks the new one up
//   B3  tapping right increments, tapping left decrements, never below 0
//   B4  at qty 0 the product STAYS on screen (a mis-tap is undone by tapping right)
//   C4  committing at qty 0 sends nothing and just clears the stage
//   C5  the bottom bar is whatever the commit response said it is
//
// Still true after the move: no user-facing string is composed here. Product
// name, progress_label, bag_label and every error title/message are read from
// the RPC payload verbatim.
library;

/// The one seam. Supplier mode calls barcode_lookup / barcode_submit_scan;
/// Pack calls pack_barcode_lookup / pack_barcode_submit_scan. A test supplies a
/// closure that returns fabricated payloads and records what was asked for.
typedef BarcodeRpc = Future<dynamic> Function(
    String fn, Map<String, dynamic> params);

/// The item currently STAGED (scanned but not yet committed). Every field is a
/// value barcode_lookup returned — none of it is derived here.
class BarcodeStaged {
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

  BarcodeStaged({
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

class BarcodeCountLogic {
  /// True when this session must use the pack_* RPC family. A Pack scan sent to
  /// barcode_submit_scan would land in the shop receiving ledger, so this is the
  /// single switch and it never gets inferred from an empty string.
  final bool isPack;
  final String supplierName;
  final String stage;
  final String? orderId;

  /// Generated ONCE when the screen opens, reused for every scan (C6).
  final String sessionKey;

  final BarcodeRpc rpc;

  /// Read live per call — the admin can change the date scope under us.
  final String? Function() dateYmd;

  /// Backend-owned error copy for a thrown exception. Injected so this file
  /// never reaches for the FulfillLookups singleton.
  final String Function(Object error) errorText;

  /// Backend-owned copy for an `ok:false` that carried an error code but no
  /// message of its own.
  final String Function(String code) messageForCode;

  /// The screen's setState.
  final void Function()? onChanged;

  BarcodeCountLogic({
    required this.isPack,
    required this.supplierName,
    required this.stage,
    required this.orderId,
    required this.sessionKey,
    required this.rpc,
    required this.dateYmd,
    required this.errorText,
    required this.messageForCode,
    this.onChanged,
  });

  BarcodeStaged? staged;

  // ok:false payload from lookup — backend title + message, verbatim.
  String errTitle = '';
  String errMessage = '';

  // Bottom bar — every field comes from an RPC response.
  int countedQty = 0;
  String progressLabel = '';
  bool isOver = false;
  int overQty = 0;

  bool busy = false;
  bool anyCommitted = false;

  void _changed() => onChanged?.call();

  static Map<String, dynamic> _asMap(dynamic raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};

  /// Entry point for one accepted scan (already de-duplicated by the caller's
  /// hold-the-code throttle).
  Future<void> handleCode(String code) async {
    if (busy) return;
    final s = staged;

    // B2: the SAME barcode again just increments the staged qty. No RPC.
    if (s != null && s.barcode == code) {
      s.qty += 1;
      _changed();
      return;
    }

    // C2: a DIFFERENT barcode auto-commits what is staged, then stages the new one.
    if (s != null) await commit();
    await lookup(code);
  }

  Future<void> lookup(String code) async {
    busy = true;
    _changed();
    try {
      // CHANGE #627: Pack is order-scoped and has no supplier, stage, date or bag.
      final raw = isPack
          ? await rpc('pack_barcode_lookup', {
              'p_order_id': orderId,
              'p_barcode': code,
            })
          : await rpc('barcode_lookup', {
              'p_supplier': supplierName,
              'p_barcode': code,
              'p_stage': stage,
              'p_date': dateYmd(),
            });
      final res = _asMap(raw);

      if (res['ok'] != true) {
        // B1: render the backend's own title + message. Nothing is staged.
        staged = null;
        errTitle = res['title']?.toString() ?? '';
        errMessage = res['message']?.toString() ?? '';
        return;
      }

      staged = BarcodeStaged(
        barcode: code,
        productId: (res['product_id'] as num?)?.toInt() ?? 0,
        name: res['product_name']?.toString() ?? '',
        imageUrl: res['image_url']?.toString() ?? '',
        packLabel: res['pack_label']?.toString() ?? '',
        company: res['company']?.toString() ?? '',
        progressLabel: res['progress_label']?.toString() ?? '',
        // A2: there is no bag in Pack. pack_barcode_lookup returns no bag fields
        // at all, and this guard makes that explicit rather than relying on the
        // key being absent.
        bagLabel: isPack ? '' : (res['bag_label']?.toString() ?? ''),
        bagWarning: isPack ? false : res['bag_warning'] == true,
      );
      errTitle = '';
      errMessage = '';
      countedQty = (res['counted_qty'] as num?)?.toInt() ?? countedQty;
      progressLabel = staged!.progressLabel;
      isOver = false;
      overQty = 0;
    } catch (e) {
      staged = null;
      errTitle = '';
      errMessage = errorText(e);
    } finally {
      busy = false;
      _changed();
    }
  }

  /// C3. Returns without a round trip when the staged qty is 0 (C4).
  Future<void> commit() async {
    final s = staged;
    if (s == null || busy) return;

    if (s.qty <= 0) {
      staged = null;
      _changed();
      return;
    }

    busy = true;
    _changed();
    try {
      // CHANGE #627: Pack commits through pack_barcode_submit_scan, which writes
      // to pack_clip_mentions and applies via pack_set_counted — the SAME function
      // Pack's voice count uses.
      final raw = isPack
          ? await rpc('pack_barcode_submit_scan', {
              'p_order_id': orderId,
              'p_product_id': s.productId,
              'p_qty': s.qty,
              'p_session_key': sessionKey,
            })
          : await rpc('barcode_submit_scan', {
              'p_supplier': supplierName,
              'p_product_id': s.productId,
              'p_qty': s.qty,
              'p_stage': stage,
              'p_date': dateYmd(),
              'p_session_key': sessionKey,
            });
      final res = _asMap(raw);

      if (res['ok'] != true) {
        errTitle = '';
        errMessage = res['message']?.toString() ??
            messageForCode(res['error']?.toString() ?? '');
        staged = null;
        return;
      }

      // C5: bottom bar is whatever the commit response says it is.
      anyCommitted = true;
      staged = null;
      errTitle = '';
      errMessage = '';
      countedQty = (res['counted_qty'] as num?)?.toInt() ?? 0;
      progressLabel = res['progress_label']?.toString() ?? '';
      isOver = res['is_over'] == true;
      overQty = (res['over_qty'] as num?)?.toInt() ?? 0;
    } catch (e) {
      errTitle = '';
      errMessage = errorText(e);
      staged = null;
    } finally {
      busy = false;
      _changed();
    }
  }

  /// B3/B4: image tap zones. Down to 0 but never below; at 0 the product stays
  /// on screen so a mis-tap is undone by tapping right again.
  void bump(int delta) {
    final s = staged;
    if (s == null) return;
    final next = s.qty + delta;
    if (next < 0) return;
    s.qty = next;
    _changed();
  }

  /// A staged item is flushed on the way out, through the same zero-guarded
  /// commit path — so nothing counted is silently lost, and a qty tapped down to
  /// 0 still writes nothing.
  Future<void> flushOnClose() async {
    if (staged != null) await commit();
  }
}
