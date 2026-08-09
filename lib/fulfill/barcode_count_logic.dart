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

  // COUNT MODE: GS1 extras, read verbatim from barcode_lookup's `gs1` block.
  // Empty string when the code was a plain EAN — absence is explicit, and the
  // backend's expiry_warning.show (not these) decides whether a chip renders.
  final String batch;
  final String expiryLabel;

  /// barcode_lookup's expiry_warning block, verbatim: {show, level, label,
  /// colors:{bg,fg,border}}. The app only reads `show` to decide visibility;
  /// label and every colour are the backend's.
  final Map<String, dynamic> expiryWarning;

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
    this.batch = '',
    this.expiryLabel = '',
    this.expiryWarning = const {},
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

  // COUNT MODE — the last commit's outcome, for the screen to toast/haptic on.
  // 'committed' | 'skipped' | 'refused' | 'error' | 'zero' | ''.
  // commitSeq bumps once per outcome so the screen never toasts the same
  // event twice (handleCode's auto-commit and an explicit swipe share this).
  String lastCommitEvent = '';
  int commitSeq = 0;

  /// The backend's skipped code (duplicate_serial | duplicate_scan |
  /// voice_merged | zero_qty) and its message, VERBATIM. A skipped commit wrote
  /// nothing — anyCommitted is untouched and progressLabel keeps its last value.
  String skipped = '';
  String skippedMessage = '';

  /// The commit response's expiry_warning block, verbatim (chip after commit).
  Map<String, dynamic> commitExpiry = const {};

  // TEACH — set only by an unknown_barcode lookup whose payload said
  // can_teach:true. teachBarcode is the backend's own normalised code (GTIN for
  // GS1); _teachRaw is the raw scan we re-run the lookup with after saving.
  bool canTeach = false;
  String teachBarcode = '';
  String teachHint = '';
  String _teachRaw = '';

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
        // TEACH: unknown_barcode + can_teach opens the one-tap teach flow. The
        // backend decided teachability and supplied the code to save; the app
        // only remembers the raw scan to re-run the lookup with afterwards.
        canTeach = res['error']?.toString() == 'unknown_barcode' &&
            res['can_teach'] == true;
        teachBarcode = canTeach ? (res['teach_barcode']?.toString() ?? '') : '';
        teachHint = canTeach ? (res['teach_hint']?.toString() ?? '') : '';
        _teachRaw = canTeach ? code : '';
        return;
      }

      final gs1 = _asMap(res['gs1']);
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
        batch: gs1['batch']?.toString() ?? '',
        expiryLabel: gs1['expiry_label']?.toString() ?? '',
        expiryWarning: _asMap(res['expiry_warning']),
      );
      errTitle = '';
      errMessage = '';
      canTeach = false;
      teachBarcode = '';
      teachHint = '';
      _teachRaw = '';
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
      lastCommitEvent = 'zero';
      commitSeq++;
      _changed();
      return;
    }

    busy = true;
    skipped = '';
    skippedMessage = '';
    _changed();
    try {
      // CHANGE #627: Pack commits through pack_barcode_submit_scan, which writes
      // to pack_clip_mentions and applies via pack_set_counted — the SAME function
      // Pack's voice count uses.
      //
      // COUNT MODE: p_raw is the code's raw string EXACTLY as the camera decoded
      // it. gs1_parse in the backend owns all decoding — GTIN, batch, expiry,
      // serial — so nothing is parsed or stripped here.
      final raw = isPack
          ? await rpc('pack_barcode_submit_scan', {
              'p_order_id': orderId,
              'p_product_id': s.productId,
              'p_qty': s.qty,
              'p_session_key': sessionKey,
              'p_raw': s.barcode,
            })
          : await rpc('barcode_submit_scan', {
              'p_supplier': supplierName,
              'p_product_id': s.productId,
              'p_qty': s.qty,
              'p_stage': stage,
              'p_date': dateYmd(),
              'p_session_key': sessionKey,
              'p_raw': s.barcode,
            });
      final res = _asMap(raw);

      if (res['ok'] != true) {
        // no_active_bag and every other refusal: title + message verbatim, and
        // the count stays untouched — the backend wrote nothing.
        errTitle = res['title']?.toString() ?? '';
        errMessage = res['message']?.toString() ??
            messageForCode(res['error']?.toString() ?? '');
        staged = null;
        lastCommitEvent = 'refused';
        commitSeq++;
        return;
      }

      // SKIPPED (duplicate_serial | duplicate_scan | voice_merged): the backend
      // wrote nothing and said why. Show its message verbatim; counted_qty is
      // the payload's (unchanged) total; progressLabel keeps its last value
      // because a skip carries none.
      final skip = res['skipped']?.toString() ?? '';
      if (skip.isNotEmpty) {
        skipped = skip;
        skippedMessage = res['message']?.toString() ?? '';
        countedQty = (res['counted_qty'] as num?)?.toInt() ?? countedQty;
        staged = null;
        errTitle = '';
        errMessage = '';
        lastCommitEvent = 'skipped';
        commitSeq++;
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
      commitExpiry = _asMap(res['expiry_warning']);
      lastCommitEvent = 'committed';
      commitSeq++;
    } catch (e) {
      errTitle = '';
      errMessage = errorText(e);
      staged = null;
      lastCommitEvent = 'error';
      commitSeq++;
    } finally {
      busy = false;
      _changed();
    }
  }

  /// TEACH — one tap, saved forever. Attaches the unknown code to [productId]
  /// via medicine_set_barcode, then re-runs the SAME raw lookup so the staged
  /// card appears immediately. A refusal (barcode_taken) renders the backend's
  /// message verbatim and leaves the teach state open for another pick.
  Future<void> teach(int productId) async {
    if (!canTeach || teachBarcode.isEmpty || busy) return;
    busy = true;
    _changed();
    final rawCode = _teachRaw;
    try {
      final res = _asMap(await rpc('medicine_set_barcode', {
        'p_product_id': productId,
        'p_barcode': teachBarcode,
      }));
      if (res['ok'] != true) {
        errMessage = res['message']?.toString() ??
            messageForCode(res['error']?.toString() ?? '');
        return;
      }
    } catch (e) {
      errMessage = errorText(e);
      return;
    } finally {
      busy = false;
      _changed();
    }
    await lookup(rawCode);
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
