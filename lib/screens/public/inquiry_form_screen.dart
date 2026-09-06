import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../widgets/inquiry_v12.dart';
import '../../widgets/response_deadline.dart';

/// CHANGE #671 gap 51: the page's own green literal and its own hex parser are
/// gone. The brand colour is `Ds.c.brand` (a backend design token, recolourable
/// with `ui_design_set` and no deploy) and a badge hex from the payload is read
/// by `Ds.hex`, which is the same parser the token layer itself uses.

/// CHANGE #464 gap 46 — the answer badge on the read-only receipt.
///
/// `inquiry_answer_badge(answer)` has existed in the backend the whole time,
/// keyed on the `inquiry_answer_badges` app_settings map. This screen used to
/// re-derive label/bg/fg from the answer string in a Dart `switch` whose
/// default branch labelled anything unrecognised as a refusal — which is how
/// 'Short supplied' (cmd #464 gap 47) would have been mislabelled. Nothing is
/// decided here: an absent badge renders nothing.
class InquiryBadge {
  final String label;
  final Color bg;
  final Color fg;
  const InquiryBadge(
      {required this.label, required this.bg, required this.fg});

  bool get has => label.isNotEmpty;

  static Color get _fallbackBg => Ds.c.bg;
  static Color get _fallbackFg => Ds.c.textSecondary;

  static InquiryBadge from(Map<String, dynamic> item) {
    final badge = item['badge'] is Map
        ? Map<String, dynamic>.from(item['badge'] as Map)
        : const <String, dynamic>{};
    return InquiryBadge(
      label: (badge['label'] as String?) ?? '',
      bg: Ds.hex(badge['bg'] as String?, _fallbackBg),
      fg: Ds.hex(badge['fg'] as String?, _fallbackFg),
    );
  }
}


/// CHANGE #535 (#527 gap 60) — the part-quantity row on the public inquiry
/// form.
///
/// The supplier who can send 40 of the 100 asked for used to have exactly two
/// answers: "Available" (and the PO took all 100 from them) or "Not
/// available" (and the whole line went elsewhere). The backend already knows
/// better — `submit_inquiry_form` validates `offered_qty` against the asked
/// quantity, the PO takes the offered figure and `_inquiry_cascade_remainder`
/// sends only the remainder onwards. This is the input for it.
///
/// Every word is `item['partial_qty']`'s: label, hint and asked_label are
/// written by `_inquiry_partial_qty_items()` through `uic`/`uicf`, so the copy
/// changes with an UPDATE and never a deploy. A payload with no `partial_qty`
/// (an older backend) renders NOTHING — `maybe()` returns null and the caller
/// falls back to exactly the pre-#535 layout.
class InquiryPartialQtyField extends StatelessWidget {
  final Map<String, dynamic> partialQty;
  final TextEditingController controller;
  final VoidCallback? onChanged;

  const InquiryPartialQtyField({
    super.key,
    required this.partialQty,
    required this.controller,
    this.onChanged,
  });

  /// True only when the backend decorated this item AND turned the field on.
  static bool enabledFor(Map<String, dynamic> item) {
    final pq = item['partial_qty'];
    return pq is Map && pq['enabled'] == true;
  }

  /// The row for [item], or null when the payload never asked for one.
  static Widget? maybe(
    Map<String, dynamic> item,
    TextEditingController controller, {
    VoidCallback? onChanged,
  }) {
    if (!enabledFor(item)) return null;
    return InquiryPartialQtyField(
      partialQty: Map<String, dynamic>.from(item['partial_qty'] as Map),
      controller: controller,
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = (partialQty['label'] as String?) ?? '';
    final askedLabel = (partialQty['asked_label'] as String?) ?? '';
    final hint = (partialQty['hint'] as String?) ?? '';
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(
        flex: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: Ds.t.bodyStrong),
            if (askedLabel.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(askedLabel, style: Ds.t.caption),
            ],
          ],
        ),
      ),
      SizedBox(width: Ds.space.x12),
      // Proportional, never a hard-coded pixel width — the same share of the
      // row the rate field takes, at 360, 414 and 1280.
      Expanded(
        flex: 2,
        child: TextField(
          key: const Key('c535_qty_field'),
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.right,
          style: Ds.t.body,
          onChanged: (_) => onChanged?.call(),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle: Ds.t.caption,
            contentPadding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x12),
            filled: true,
            fillColor: Ds.c.bg,
            border: OutlineInputBorder(
                borderRadius: Ds.r.rButton,
                borderSide: BorderSide(color: Ds.c.divider)),
            enabledBorder: OutlineInputBorder(
                borderRadius: Ds.r.rButton,
                borderSide: BorderSide(color: Ds.c.divider)),
            focusedBorder: OutlineInputBorder(
                borderRadius: Ds.r.rButton,
                borderSide: BorderSide(color: Ds.c.brand)),
          ),
        ),
      ),
    ]);
  }
}

/// CHANGE #535 — the answer map one item contributes to
/// `submit_inquiry_form(p_answers)`.
///
/// Pure on purpose: an untouched optional field is ABSENT from the map, never
/// sent as `0` or `''`. The backend reads a missing `offered_qty` as "the whole
/// quantity", so a Dart-side default of zero would silently turn every full
/// answer into a refusal.
Map<String, dynamic> buildInquiryAnswer({
  required int inquiryId,
  required String answer,
  String? rate,
  String? offeredQty,
}) {
  final r = rate?.trim() ?? '';
  final q = offeredQty?.trim() ?? '';
  return <String, dynamic>{
    'inquiry_id': inquiryId,
    'answer': answer,
    if (r.isNotEmpty) 'rate': r,
    if (q.isNotEmpty) 'offered_qty': q,
  };
}

class InquiryFormScreen extends StatefulWidget {
  final String token;

  /// CHANGE #687 — the link secret resolve_code() already verified.
  ///
  /// #612 made the secret a second path segment and #526 made
  /// inquiry_secret_required the default, but this screen kept calling
  /// get_inquiry_form with the token ALONE. _inquiry_form_gate refuses that
  /// ('forbidden'), and the screen renders a refusal as "This link is no
  /// longer valid" — so every secret-protected inquiry link, which is every
  /// link sent on WhatsApp, opened on a dead end. The resolver had the secret
  /// the whole time and simply did not pass it on.
  ///
  /// It is carried, never parsed: the app has no idea what a valid secret
  /// looks like and must not acquire one.
  final String? secret;

  const InquiryFormScreen({super.key, required this.token, this.secret});

  @override
  State<InquiryFormScreen> createState() => _InquiryFormScreenState();
}

class _InquiryFormScreenState extends State<InquiryFormScreen> {
  bool _loading = true;
  String? _error;
  String? _supplierName;
  List<Map<String, dynamic>> _items = [];
  // CHANGE #464: read-only receipt of what this supplier already answered
  // this cycle — separate from _items (which still mixes locked+pending).
  bool _submitted = false;
  List<Map<String, dynamic>> _submittedItems = [];
  final Map<int, String> _selections = {};
  // CHANGE #353 (#59) — the supplier's own trade rate per item. Availability
  // alone was never a quote: the PO had nothing to price with and fell back to
  // MRP (#29). Every label, hint and error below arrives from
  // inquiry_rate_capture(); nothing here is worded in Dart.
  final Map<int, TextEditingController> _rateCtl = {};
  // CHANGE #535 (#527 gap 60) — the part quantity the supplier can actually
  // send, one controller per item, kept and disposed exactly like _rateCtl.
  final Map<int, TextEditingController> _qtyCtl = {};
  Map<String, dynamic> _rateCapture = const {};
  // CHANGE #687 — get_inquiry_form().deadline, printed by ResponseDeadline.
  Map<String, dynamic> _deadline = const {};
  String? _submitError;
  bool _submitting = false;
  bool _newItemsAdded = false;
  Set<int> _prevUnlockedIds = {};
  bool _respondedExpanded = false;

  RealtimeChannel? _rt;
  Timer? _c458Debounce;
  int _c458Events = 0;
  int _c458Reloads = 0;

  @override
  void initState() {
    super.initState();
    RenderLog.write('inquiry_form_init', widget.token.substring(0, 8));
    try { RenderLog.write('c458_timers', 0); } catch (_) {}
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    if (_rt != null) {
      try { Supabase.instance.client.removeChannel(_rt!); } catch (_) {}
      _rt = null;
    }
    _c458Debounce?.cancel();
    for (final ctl in _rateCtl.values) {
      ctl.dispose();
    }
    _rateCtl.clear();
    for (final ctl in _qtyCtl.values) {
      ctl.dispose();
    }
    _qtyCtl.clear();
    super.dispose();
  }

  // CHANGE #458: broadcast-only realtime — no table replication, no polling.
  // Anon-safe: the topic comes from the backend (inquiry_realtime_topic,
  // token-scoped), the broadcast payload is data-free, and every event just
  // triggers a re-fetch via get_inquiry_form(token), coalesced 250ms.
  Future<void> _subscribeRealtime() async {
    try {
      final t = await Supabase.instance.client.rpc('inquiry_realtime_topic',
          params: {'p_token': widget.token}) as Map;
      if (!mounted) return;
      final topic = t['topic'] as String?;
      final event = t['event'] as String? ?? 'inquiry_changed';
      if (t['error'] != null || topic == null) {
        try { RenderLog.write('c458_topic', 'error'); } catch (_) {}
        return;
      }
      try { RenderLog.write('c458_topic', topic); } catch (_) {}
      _rt = Supabase.instance.client
          .channel(topic)
          .onBroadcast(
            event: event,
            callback: (payload) {
              _c458Events++;
              try { RenderLog.write('c458_events', _c458Events); } catch (_) {}
              _c458Debounce?.cancel();
              _c458Debounce = Timer(const Duration(milliseconds: 250), () {
                if (!mounted) return;
                _c458Reloads++;
                try { RenderLog.write('c458_reloads', _c458Reloads); } catch (_) {}
                _load(silent: true);
              });
            },
          )
          .subscribe((status, error) {
            if (status == RealtimeSubscribeStatus.subscribed) {
              try { RenderLog.write('c458_subscribed', 1); } catch (_) {}
            }
          });
    } catch (e) {
      try { RenderLog.write('c458_topic', 'exception'); } catch (_) {}
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (!mounted) return;
    setState(() {
      if (!silent) _loading = true;
      _error = null;
    });
    try {
      final result = await Supabase.instance.client
          .rpc('get_inquiry_form', params: {
        'p_token': widget.token,
        if (widget.secret != null) 'p_secret': widget.secret,
      });

      if (!mounted) return;
      final data = Map<String, dynamic>.from(result as Map);

      if (data['error'] != null) {
        final errCode = data['error'] as String;
        setState(() {
          _error = errCode;
          _loading = false;
        });
        RenderLog.write('inquiry_form_error', errCode);
        if (errCode == 'expired' && _rt != null) {
          // CHANGE #458 C3: expired link — stop listening, nothing left to sync.
          try { Supabase.instance.client.removeChannel(_rt!); } catch (_) {}
          _rt = null;
        }
        return;
      }

      final items = (data['items'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // CHANGE #353 (#59) — rate capture is a backend contract: enabled,
      // required, and every string. An older backend simply returns nothing
      // and the field is absent rather than half-worded in Dart.
      Map<String, dynamic> capture = const {};
      try {
        final cap = await Supabase.instance.client.rpc('inquiry_rate_capture');
        if (cap is Map) capture = Map<String, dynamic>.from(cap);
      } catch (_) {
        capture = const {};
      }

      final unlockedIds = items
          .where((i) => i['locked'] == false)
          .map((i) => (i['inquiry_id'] as num).toInt())
          .toSet();

      final hadItems = _items.isNotEmpty;
      final newlyAppeared =
          hadItems && unlockedIds.any((id) => !_prevUnlockedIds.contains(id));

      final submittedItems = (data['submitted_items'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      setState(() {
        _supplierName = data['supplier_name'] as String?;
        // CHANGE #687 — the deadline this link is under, verbatim.
        _deadline =
            (data['deadline'] as Map?)?.cast<String, dynamic>() ?? const {};
        _rateCapture = capture;
        _items = items;
        // CHANGE #639 — an item the backend pre-ticked (prestate) is shown
        // SELECTED, so it must also count as answered: it has to submit, and
        // it has to satisfy the "all fields are required" gate below.
        // Rendering it ticked but treating it as unanswered would be the
        // screen showing one thing and sending another. A tap the supplier
        // already made this session always wins (putIfAbsent).
        for (final i in items) {
          if (i['locked'] == true) continue;
          final pre = (i['prestate'] as String?) ?? '';
          if (pre.isEmpty) continue;
          _selections.putIfAbsent((i['inquiry_id'] as num).toInt(), () => pre);
        }
        _submitted = data['submitted'] == true;
        _submittedItems = submittedItems;
        _newItemsAdded = newlyAppeared;
        final nowLocked = items
            .where((i) => i['locked'] == true)
            .map((i) => (i['inquiry_id'] as num).toInt())
            .toSet();
        for (final id in nowLocked) {
          _selections.remove(id);
        }
        _prevUnlockedIds = unlockedIds;
        _loading = false;
        // Auto-expand locked section when all items are answered (complete form)
        if (unlockedIds.isEmpty && items.isNotEmpty) {
          _respondedExpanded = true;
        }
      });

      RenderLog.write('inquiry_form_loaded',
          '${items.length}_items_${widget.token.substring(0, 8)}');
      RenderLog.write('inquiry_v12_public_form', 'true');
      RenderLog.write('inq_surface_link_grouped', 1);
      final pendingCount = items.where((i) => i['locked'] != true).length;
      RenderLog.write('form.render.ok',
          'token=${widget.token.substring(0, 8)};pending=$pendingCount');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'load_failed';
        _loading = false;
      });
      RenderLog.write('inquiry_form_load_error',
          e.toString().substring(0, 40));
    }
  }

  Future<int?> _bulkDontStockCompanyCategory(
      String company, String category) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'submit_inquiry_dont_stock_company_category',
        params: {
          'p_token': widget.token,
          'p_company': company,
          'p_category': category,
        },
      );
      final data = Map<String, dynamic>.from(result as Map);
      if (data['error'] != null) return null;

      final items = (data['items'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      if (!mounted) return null;

      // Count items newly marked in this company+category
      final cLower = company.trim().toLowerCase();
      final cUpper = category.trim().toUpperCase();
      final marked = items.where((i) {
        final iComp =
            (i['company'] as String? ?? '').trim().toLowerCase();
        final iCat = (i['therapeutic_class'] as String? ?? '')
            .trim()
            .toUpperCase();
        return iComp == cLower &&
            iCat == cUpper &&
            i['locked'] == true;
      }).length;

      setState(() {
        _items = items;
        final nowLocked = items
            .where((i) => i['locked'] == true)
            .map((i) => (i['inquiry_id'] as num).toInt())
            .toSet();
        for (final id in nowLocked) {
          _selections.remove(id);
        }
        final unlockedIds = items
            .where((i) => i['locked'] == false)
            .map((i) => (i['inquiry_id'] as num).toInt())
            .toSet();
        _prevUnlockedIds = unlockedIds;
        if (unlockedIds.isEmpty && items.isNotEmpty) {
          _respondedExpanded = true;
        }
      });

      RenderLog.write('inq_link_bulk_done', '${company}_$category');
      return marked;
    } catch (e) {
      return null;
    }
  }

  // CHANGE #353 (#59) — the rate the supplier typed for one item, or null.
  // The widget carries the string; the backend validates and stores the number.
  String? _rateFor(int id) {
    final raw = _rateCtl[id]?.text.trim() ?? '';
    return raw.isEmpty ? null : raw;
  }

  // CHANGE #535 — the part quantity the supplier typed, or null when they left
  // the field alone. Blank means the whole quantity to the backend; it must
  // never arrive as 0.
  String? _qtyFor(int id) {
    final raw = _qtyCtl[id]?.text.trim() ?? '';
    return raw.isEmpty ? null : raw;
  }

  bool get _rateCaptureOn => _rateCapture['enabled'] == true;
  bool get _rateRequired => _rateCapture['required'] == true;
  String get _rateAnswer => (_rateCapture['answer'] as String?) ?? 'Available';

  /// The trailing block under an item the supplier has marked available: the
  /// rate row (#353) and, since CHANGE #535, the part-quantity row (#527 gap
  /// 60). Absent for every other answer — neither a rate nor a part quantity
  /// means anything without stock.
  ///
  /// Each row is gated by its OWN backend flag, so a build talking to an older
  /// backend (no `partial_qty` on the item) renders exactly what it rendered
  /// before, and a backend that turns rate capture off still gets the quantity
  /// field.
  Widget? _rateField(Map<String, dynamic> item) {
    final id = (item['inquiry_id'] as num).toInt();
    if (_selections[id] != _rateAnswer) return null;
    final rate = _rateCaptureOn ? _rateRow(id) : null;
    final qty = InquiryPartialQtyField.maybe(
      item,
      _qtyCtl.putIfAbsent(id, () => TextEditingController()),
      onChanged: () => setState(() {}),
    );
    if (rate == null) return qty;
    if (qty == null) return rate;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [rate, SizedBox(height: Ds.space.x12), qty],
    );
  }

  Widget _rateRow(int id) {
    final ctl = _rateCtl.putIfAbsent(id, () => TextEditingController());
    final prefix = (_rateCapture['prefix'] as String?) ?? '';
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Expanded(
        flex: 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text((_rateCapture['label'] as String?) ?? '',
                style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x4),
            Text((_rateCapture['mrp_caption'] as String?) ?? '',
                style: Ds.t.caption),
          ],
        ),
      ),
      SizedBox(width: Ds.space.x12),
      // Proportional, never a hard-coded pixel width: the field keeps its share
      // of the row at 360, 414 and 1280.
      Expanded(
        flex: 2,
        child: TextField(
          controller: ctl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.right,
          style: Ds.t.body,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            isDense: true,
            prefixText: prefix.isEmpty ? null : prefix,
            hintText: (_rateCapture['hint'] as String?) ?? '',
            hintStyle: Ds.t.caption,
            contentPadding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x12),
            filled: true,
            fillColor: Ds.c.bg,
            border: OutlineInputBorder(
                borderRadius: Ds.r.rButton,
                borderSide: BorderSide(color: Ds.c.divider)),
            enabledBorder: OutlineInputBorder(
                borderRadius: Ds.r.rButton,
                borderSide: BorderSide(color: Ds.c.divider)),
            focusedBorder: OutlineInputBorder(
                borderRadius: Ds.r.rButton,
                borderSide: BorderSide(color: Ds.c.brand)),
          ),
        ),
      ),
    ]);
  }

  Future<void> _submit() async {
    final unanswered = _items.where((i) => i['locked'] == false).toList();
    final toSubmit = unanswered
        .map((i) {
          final id = (i['inquiry_id'] as num).toInt();
          final answer = _selections[id] ?? '';
          final available = answer == _rateAnswer;
          return buildInquiryAnswer(
            inquiryId: id,
            answer: answer,
            rate: available ? _rateFor(id) : null,
            // CHANGE #535 — omitted when the field was never touched.
            offeredQty: available ? _qtyFor(id) : null,
          );
        })
        .where((a) => (a['answer'] as String).isNotEmpty)
        .toList();

    if (toSubmit.isEmpty) return;

    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final res = await Supabase.instance.client.rpc('submit_inquiry_form',
          params: {
            'p_token': widget.token,
            'p_answers': toSubmit,
            if (widget.secret != null) 'p_secret': widget.secret,
          });
      // A refusal is a payload, not an exception. Its wording is the
      // backend's — printed verbatim, never re-phrased here.
      if (res is Map && res['error'] != null && res['message'] != null) {
        if (mounted) {
          setState(() => _submitError = res['message'] as String);
          RenderLog.write('inquiry_rate_refused', '${res['error']}');
        }
        return;
      }
      RenderLog.write('inquiry_form_submitted', '${toSubmit.length}_answers');
      RenderLog.write('inquiry_rate_sent',
          '${toSubmit.where((a) => a.containsKey('rate')).length}');
      await _load();
    } catch (e) {
      RenderLog.write(
          'inquiry_form_submit_error', e.toString().substring(0, 40));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(c('inquiry_form_screen.submission_failed')),
            backgroundColor: Ds.c.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  bool get _canSubmit {
    final unanswered = _items.where((i) => i['locked'] == false).toList();
    if (unanswered.isEmpty) return false;
    return unanswered.every((i) {
      final id = (i['inquiry_id'] as num).toInt();
      if (!_selections.containsKey(id)) return false;
      // Whether a rate is mandatory is the BACKEND's call (inquiry_rate_
      // capture().required), not this screen's.
      if (_rateCaptureOn &&
          _rateRequired &&
          _selections[id] == _rateAnswer &&
          _rateFor(id) == null) {
        return false;
      }
      return true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(
                        color: Ds.c.brand, strokeWidth: 2.5))
                : _error != null
                    ? _buildError()
                    : _buildForm(),
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    final isExpired = _error == 'expired';
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Ds.c.bg,
                borderRadius: Ds.r.rChip,
              ),
              child: Icon(
                isExpired
                    ? Icons.timer_off_outlined
                    : Icons.link_off_outlined,
                size: 36,
                color: Ds.c.textSecondary,
              ),
            ),
            const SizedBox(height: 20),
            // CHANGE #464 gap 46: the expired/invalid page is ui_copy, not Dart
            // literals, and a raw Postgres string is never surfaced here — the
            // backend answers with 'expired' or 'invalid' and nothing else.
            Text(
              c(isExpired
                  ? 'inquiry_form_screen.expired_title'
                  : 'inquiry_form_screen.invalid_title'),
              style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              c(isExpired
                  ? 'inquiry_form_screen.expired_body'
                  : 'inquiry_form_screen.invalid_body'),
              style: Ds.t.bodySecondary,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Image.network(
              'https://medibo.in/icons/Icon-192.png',
              width: 48,
              height: 48,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  // CHANGE #464: read-only receipt — success banner + one card per already-
  // submitted item. No buttons, not tappable; purely a summary of what this
  // supplier already answered this cycle.
  Widget _buildReceiptSection() {
    try { RenderLog.write('c464_inquiry_receipt', _submittedItems.length); } catch (_) {}
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.successSoft,
            borderRadius: Ds.r.rButton,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.check_circle, color: Ds.c.success, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c('inquiry_form_screen.response_submitted'),
                      style: Ds.t.body.copyWith(
                          fontWeight: FontWeight.w700, color: Ds.c.success),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      c('inquiry_form_screen.already_answered_receipt'),
                      style: Ds.t.caption.copyWith(color: Ds.c.success),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ..._submittedItems.map(_buildReceiptCard),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildReceiptCard(Map<String, dynamic> item) {
    final name = item['product_name'] as String? ?? '';
    final company = item['company'] as String?;
    final imageUrl = item['image_url'] as String?;

    // CHANGE #464 gap 46: the badge is the BACKEND's, printed verbatim.
    final badge = InquiryBadge.from(item);

    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x8),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rButton,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Ds.c.bg,
              borderRadius: Ds.r.rButton,
              border: Border.all(color: Ds.c.divider, width: 0.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: imageUrl != null && imageUrl.isNotEmpty
                ? Image.network(imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(
                        Icons.medication_outlined,
                        size: 20,
                        color: Ds.c.divider))
                : Icon(Icons.medication_outlined,
                    size: 20, color: Ds.c.divider),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (company != null && company.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    company,
                    style: Ds.t.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          // No badge on the payload means no badge on the card — Dart does not
          // invent one.
          if (badge.has) ...[
            const SizedBox(width: 8),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration:
                  BoxDecoration(color: badge.bg, borderRadius: Ds.r.rChip),
              child: Text(
                badge.label,
                style: Ds.t.caption.copyWith(
                    fontWeight: FontWeight.w500, color: badge.fg),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildForm() {
    final locked = _items.where((i) => i['locked'] == true).toList();
    final unanswered = _items.where((i) => i['locked'] == false).toList();
    final allDone = unanswered.isEmpty && _items.isNotEmpty;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header card ──────────────────────────────────────────────────
          Container(
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: BoxDecoration(
              color: Ds.c.brand,
              borderRadius: Ds.r.rButton,
            ),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Ds.c.surface.withValues(alpha: 0.18),
                  borderRadius: Ds.r.rButton,
                ),
                child: Icon(Icons.medication_outlined,
                    color: Ds.c.surface, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      c('inquiry_form_screen.header_kicker'),
                      style: Ds.t.caption.copyWith(
                          color: Ds.c.surface,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _supplierName ?? '',
                      style: Ds.t.subtitle.copyWith(
                          color: Ds.c.surface, fontWeight: FontWeight.w800),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          // ── CHANGE #687 (#68) — the countdown this link is running against,
          // immediately under the header so it is the first thing read. Every
          // string, the tone and the poll interval come from the same
          // deadline_block() the supplier tab and the admin tab render.
          ResponseDeadline(
            block: _deadline,
            renderKey: 'c687_link_deadline',
            onRefresh: () async => _load(silent: true),
          ),

          // ── Receipt (CHANGE #464): read-only summary of what was already
          // submitted this cycle. Purely additive — does not replace the
          // existing "Already Responded" accordion below, which reflects a
          // different, longer-lived source (the inquiry table's PS/AS slots).
          if (_submitted && _submittedItems.isNotEmpty) _buildReceiptSection(),

          // ── New items banner ─────────────────────────────────────────────
          if (_newItemsAdded) ...[
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x8),
              decoration: BoxDecoration(
                color: Ds.c.warningSoft,
                borderRadius: Ds.r.rButton,
                border: Border.all(color: Ds.c.warning),
              ),
              child: Row(children: [
                Icon(Icons.info_outline, size: 16, color: Ds.c.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    c('inquiry_form_screen.new_items_added'),
                    style: Ds.t.caption.copyWith(color: Ds.c.warning),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),
          ],

          // ── All done banner ──────────────────────────────────────────────
          if (allDone) ...[
            Container(
              padding: EdgeInsets.all(Ds.space.x16),
              decoration: BoxDecoration(
                color: Ds.c.successSoft,
                borderRadius: Ds.r.rButton,
                border: Border.all(color: Ds.c.success),
              ),
              child: Row(children: [
                Icon(Icons.check_circle_outline,
                    color: Ds.c.brand, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    c('inquiry_form_screen.all_responses_submitted'),
                    style: Ds.t.body.copyWith(
                        fontWeight: FontWeight.w600, color: Ds.c.brand),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),
          ],

          // ── Already Responded (collapsed) ────────────────────────────────
          if (locked.isNotEmpty) ...[
            GestureDetector(
              onTap: () => setState(
                  () => _respondedExpanded = !_respondedExpanded),
              child: Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x12),
                decoration: BoxDecoration(
                  color: Ds.c.bg,
                  borderRadius: Ds.r.rButton,
                  border: Border.all(color: Ds.c.divider),
                ),
                child: Row(children: [
                  Icon(Icons.check_circle_outline,
                      size: 16, color: Ds.c.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      cf('inquiry_form_screen.already_responded', {'a': '${locked.length}'}),
                      style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(
                    _respondedExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: Ds.c.textSecondary,
                  ),
                ]),
              ),
            ),
            if (_respondedExpanded) ...[
              const SizedBox(height: 8),
              InquiryAnswerList(
                key: const ValueKey('locked_v12'),
                items: locked,
                readOnly: true,
                onAnswer: (_, __) {},
              ),
            ],
            const SizedBox(height: 16),
          ],

          // ── Pending items — v11 grouped cards ────────────────────────────
          if (unanswered.isNotEmpty) ...[
            Text(
              c('inquiry_form_screen.pending_response_required'),
              style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: Ds.c.text,
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 10),
            InquiryAnswerList(
              key: const ValueKey('pending_v12'),
              items: unanswered,
              answerOverrides: _selections,
              onAnswer: (id, ans) =>
                  setState(() => _selections[id] = ans),
              onBulkCompanyCategory: _bulkDontStockCompanyCategory,
              itemTrailingWidget: _rateField,
              surface: 'link',
            ),
            if (_submitError != null) ...[
              SizedBox(height: Ds.space.x8),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(Ds.space.x12),
                decoration: BoxDecoration(
                  color: Ds.c.dangerSoft,
                  borderRadius: Ds.r.rCard,
                ),
                child: Text(_submitError!, style: Ds.t.body),
              ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: (_canSubmit && !_submitting) ? _submit : null,
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  disabledBackgroundColor: Ds.c.successSoft,
                  shape: RoundedRectangleBorder(
                      borderRadius: Ds.r.rButton),
                ),
                child: _submitting
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Ds.c.surface, strokeWidth: 2))
                    : Text(
                        c('inquiry_form_screen.submit_responses'),
                        style: Ds.t.subtitle.copyWith(
                            fontWeight: FontWeight.w700, color: Ds.c.surface),
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                c('inquiry_form_screen.all_fields_required'),
                style: Ds.t.caption.copyWith(
                    color: _canSubmit ? Ds.c.textSecondary : Ds.c.danger),
              ),
            ),
          ],

          const SizedBox(height: 32),
          Center(
            child: Text(
              c('inquiry_form_screen.footer'),
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
