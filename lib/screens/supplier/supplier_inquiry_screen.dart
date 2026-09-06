import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../../widgets/backend_chip.dart';
import '../../widgets/inquiry_v12.dart';
import '../../widgets/response_deadline.dart';

// CHANGE #607 — the six group-header colour constants are DELETED.
//
// _kPendingBg/_kPendingText, _kInquiredBg/_kInquiredText and
// _kExpiredBg/_kExpiredText hardcoded this screen's accordion palette. #606
// left them because supplier_inquiry_screen() returned no colours for the
// group shells; it does now. Each entry in groups[] carries bg/fg/border from
// tone_colors(), keyed by app_settings.inquiry_group_tones, so recolouring a
// group is a config edit.

class SupplierInquiryScreen extends StatefulWidget {
  final String? viewAsSupplierId;
  final String? viewAsSupplierName;
  final void Function(int)? onPendingCount;

  const SupplierInquiryScreen({
    super.key,
    this.viewAsSupplierId,
    this.viewAsSupplierName,
    this.onPendingCount,
  });

  @override
  State<SupplierInquiryScreen> createState() => SupplierInquiryScreenState();
}

class SupplierInquiryScreenState extends State<SupplierInquiryScreen>
    with WidgetsBindingObserver {
  List<Map<String, dynamic>> _pending  = [];
  List<Map<String, dynamic>> _inquired = [];
  List<Map<String, dynamic>> _expired  = [];
  // CHANGE #465: read-only receipt of items already answered today.
  List<Map<String, dynamic>> _receipt  = [];
  bool _loading = true;
  bool _firstLoad = true;

  // One open group at a time; null = all collapsed
  String? _openGroup; // 'pending' | 'inquired' | 'expired'

  // Select-and-submit state (#109)
  final Map<int, String> _supplierSelections = {};
  bool _supplierSubmitting = false;
  int _submitCount = 0;

  /// CHANGE #606 — everything the screen used to work out for itself, as the
  /// backend returned it.
  ///
  /// `_labels` holds labels{pending,inquired,expired,empty,submitted,save_ok,
  /// submit_failed}; `_counts` holds counts{}; `_submit` holds
  /// submit{answerable,answered,selected,enabled,label}; `_dontStockAnswer` is
  /// the exact answer string the bulk control writes.
  Map<String, dynamic> _labels = const {};
  Map<String, dynamic> _counts = const {};
  Map<String, dynamic> _submit = const {};
  String _dontStockAnswer = '';
  bool _hasItems = false;

  /// CHANGE #607 — groups[]: the sections to draw, in the backend's display
  /// order, each with key/label/count/show/is_open and bg/fg/border.
  List<Map<String, dynamic>> _groups = const [];
  // CHANGE #687 — the whole countdown, rendered verbatim from
  // supplier_inquiry_screen().deadline. Empty map => nothing draws.
  Map<String, dynamic> _deadline = const {};

  /// True once the supplier has toggled a section themselves. Until then the
  /// accordion follows the backend's is_open; after that it follows the user.
  bool _userToggled = false;

  /// CHANGE #606 — the submit gate is decided backend-side from the CURRENT
  /// selection, so a selection change has to reach the backend. Debounced so a
  /// run of quick taps costs one round trip, not one each.
  Timer? _selectDebounce;

  String _label(String k) => (_labels[k] as String?) ?? '';

  final Set<int> _answering = {};
  RealtimeChannel? _rt;
  Timer? _c458Debounce;
  int _c458Events = 0;
  int _c458Reloads = 0;

  // CHANGE #472: belt-and-suspenders poll — realtime/lifecycle refetches
  // cover the common cases, but this guarantees draft⇄pending sync within
  // 8s even if a broadcast is missed. Only ticks while this tab is the one
  // actually on screen (_isActiveTab), never in the background.
  static const _kPollInterval = Duration(seconds: 8);
  Timer? _pollTimer;
  bool _isActiveTab = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try { RenderLog.write('c458_timers', 0); } catch (_) {}
    _fetch(source: 'init');
    // CHANGE #470: realtime also covers View-As — the admin caller's topic
    // (inquiry:admin) is pinged on every inquiry change for any supplier,
    // so a refetch while impersonating still lands on the right data because
    // the backend filters by p_supplier_id regardless of what triggered it.
    _subscribeRealtime();
  }

  // CHANGE #470: public so the tab host (SupplierShell) can force a fresh
  // fetch when the Inquiry tab is switched to — the tab lives inside an
  // IndexedStack, so initState only fires once and never again on tab focus.
  // CHANGE #472: also marks the tab active and (re)starts the poll timer.
  Future<void> refresh({String source = 'tab_focus'}) {
    _isActiveTab = true;
    _startPolling();
    return _fetch(source: source, silent: true);
  }

  // CHANGE #472: called by SupplierShell when navigating away from this tab,
  // so the 8s poll doesn't keep firing for a tab that isn't visible.
  void pause() {
    _isActiveTab = false;
    _stopPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_kPollInterval, (_) {
      if (!mounted || !_isActiveTab) return;
      _fetch(source: 'poll', silent: true);
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_rt != null) {
      try { Supabase.instance.client.removeChannel(_rt!); } catch (_) {}
      _rt = null;
    }
    _c458Debounce?.cancel();
    _selectDebounce?.cancel(); // CHANGE #606
    _stopPolling();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_isActiveTab) {
        _fetch(source: 'lifecycle_resume', silent: true);
        _startPolling();
      }
      // CHANGE #458: a backgrounded socket dies silently — re-subscribe.
      _subscribeRealtime();
    } else {
      // CHANGE #472: app backgrounded — stop polling, resumed above restarts it.
      _stopPolling();
    }
  }

  // CHANGE #458: broadcast-only realtime — no table replication, no polling.
  // The topic string comes from the backend (inquiry_realtime_topic); the
  // broadcast payload is data-free, so every event just triggers a re-fetch
  // via _fetch(), coalesced with a 250ms debounce.
  Future<void> _subscribeRealtime() async {
    try {
      final t = await Supabase.instance.client
          .rpc('inquiry_realtime_topic', params: {'p_token': null}) as Map;
      if (!mounted) return;
      final topic = t['topic'] as String?;
      final event = t['event'] as String? ?? 'inquiry_changed';
      if (t['error'] != null || topic == null) {
        try { RenderLog.write('c458_topic', 'error'); } catch (_) {}
        return;
      }
      try { RenderLog.write('c458_topic', topic); } catch (_) {}
      if (_rt != null) {
        try { Supabase.instance.client.removeChannel(_rt!); } catch (_) {}
        _rt = null;
      }
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
                _fetch(source: 'realtime', silent: true);
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

  Future<void> _fetch({String source = 'manual', bool silent = false}) async {
    if (!mounted) return;
    if (!silent) setState(() => _loading = true);
    try {
      final sid = widget.viewAsSupplierId;
      // CHANGE #574 — ONE RPC for this screen.
      //
      // This used to make TWO calls (supplier_inquiry_buckets +
      // supplier_my_inquiry_receipt / get_supplier_inquiry_receipt) and then
      // decide four things here:
      //   * grouped rows itself with three .where((r) => r['state'] == ...)
      //   * picked the auto-open group with a Pending > Inquired > Expired ladder
      //   * inferred status as `list.isEmpty ? 'draft' : 'pending'` — the old
      //     comment admitted outright that this was "inferred client-side"
      //   * chose which receipt RPC to call based on the identity in hand
      //
      // supplier_inquiry_screen() answers all of it in one payload that cannot
      // disagree with itself. Each row also carries its own `flags` block
      // (no_supplier / is_locked / answerable / badge), so nothing re-derives
      // state from slot_index and role.
      // CHANGE #606 — all THREE parameters, always, and p_selected carries the
      // live selection map. There is exactly one implementation of this
      // function backend-side, (uuid, boolean, jsonb); passing p_selected is
      // what lets the backend decide the submit button's enabled state and its
      // label instead of this screen counting answers itself.
      final raw = await Supabase.instance.client.rpc(
        'supplier_inquiry_screen',
        params: {
          'p_supplier_id': sid,
          'p_preview': false,
          'p_selected': {
            for (final e in _supplierSelections.entries)
              e.key.toString(): e.value,
          },
        },
      );
      if (!mounted) return;
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (map is! Map) {
        setState(() => _loading = false);
        return;
      }
      final payload = map.cast<String, dynamic>();

      List<Map<String, dynamic>> group(String key) =>
          ((payload[key] as List<dynamic>?) ?? const [])
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();

      final pending  = group('pending');
      final inquired = group('inquired');
      final expired  = group('expired');
      final receipt  = group('receipt');
      final autoOpen = (payload['auto_open'] ?? '').toString();
      final status   = (payload['status'] ?? '').toString();
      final badge    = (payload['badge'] as num?)?.toInt() ?? 0;

      setState(() {
        _pending  = pending;
        _inquired = inquired;
        _expired  = expired;
        _receipt  = receipt;
        // CHANGE #639 — a pre-ticked item (prestate) renders SELECTED, so it
        // has to be in the selection map too: p_selected is what the backend
        // reads to decide the submit button's state, and a chip shown ticked
        // that the server has never heard of is the screen disagreeing with
        // itself. An answer the supplier already tapped wins.
        for (final i in pending) {
          if (i['prestate'] == null) continue;
          final pre = i['prestate'].toString();
          if (pre.isEmpty) continue;
          _supplierSelections.putIfAbsent(
              (i['inquiry_id'] as num).toInt(), () => pre);
        }
        // CHANGE #606 — labels, counts, the submit gate and the don't-stock
        // answer string, all decided backend-side.
        _labels = (payload['labels'] as Map?)?.cast<String, dynamic>() ?? const {};
        _counts = (payload['counts'] as Map?)?.cast<String, dynamic>() ?? const {};
        _submit = (payload['submit'] as Map?)?.cast<String, dynamic>() ?? const {};
        _dontStockAnswer = (payload['dont_stock_answer'] as String?) ?? '';
        _hasItems = payload['has_items'] == true;
        // CHANGE #607 — groups[] replaces the auto_open string entirely: each
        // entry states its own is_open, so there is no ladder and no
        // first-load-only assignment to a single _openGroup here.
        _groups = ((payload['groups'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _deadline =
            (payload['deadline'] as Map?)?.cast<String, dynamic>() ?? const {};
        _firstLoad = false;
        _loading = false;
      });

      final mode = sid != null ? 'viewas' : 'supplier';
      final supplierLabel = sid != null ? (widget.viewAsSupplierName ?? sid) : 'self';
      final total = (payload['total'] as num?)?.toInt() ?? 0;
      RenderLog.write('c470_supplier_tab_refetch', '$supplierLabel:items=$total');
      RenderLog.write('c574_supplier_tab_sync', '$supplierLabel:$status:items=$total');
      RenderLog.write('inq.src.mode', mode);
      RenderLog.write('inq.counts',
          'p=${pending.length};i=${inquired.length};e=${expired.length}');
      RenderLog.write('inq.badge', badge);
      if (autoOpen.isNotEmpty) RenderLog.write('inq.autoopen', autoOpen);
      RenderLog.write('inq.refresh.source', source);

      widget.onPendingCount?.call(badge);
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      RenderLog.write('inq.fetch.err', e.toString().substring(0, 60));
    }
  }

  // Bulk don't-stock for pending group — updates local selections only.
  //
  // CHANGE #606 — matches on the backend's own normalised company_key /
  // category_key instead of re-normalising with .toLowerCase()/.toUpperCase()
  // here, and writes `dont_stock_answer` from the payload instead of the Dart
  // literal "We don't stock this product". This is selecting rows to act on,
  // not deciding what to display.
  Future<int?> _bulkDontStockLocalPending(String company, String category) async {
    final wantCompany = company.trim().toLowerCase();
    final wantCategory = category.trim().toUpperCase();
    final ids = _pending
        .where((r) =>
            (r['company_key'] as String? ?? '') == wantCompany &&
            (r['category_key'] as String? ?? '') == wantCategory)
        .map((r) => (r['inquiry_id'] as num).toInt())
        .toList();
    if (_dontStockAnswer.isEmpty) return null;
    if (mounted) {
      setState(() {
        for (final id in ids) {
          _supplierSelections[id] = _dontStockAnswer;
        }
      });
      _scheduleSelectionSync();
    }
    return ids.length;
  }

  /// CHANGE #606 — push the current selection to the backend so it can re-decide
  /// the submit gate. Debounced: a burst of taps costs one round trip.
  void _scheduleSelectionSync() {
    _selectDebounce?.cancel();
    _selectDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _fetch(source: 'selection', silent: true);
    });
  }

  Future<void> _supplierSubmit() async {
    if (_supplierSelections.isEmpty || _supplierSubmitting) return;
    final answers = _supplierSelections.entries
        .map((e) => {'inquiry_id': e.key, 'answer': e.value})
        .toList();
    if (mounted) setState(() => _supplierSubmitting = true);
    try {
      final sid = widget.viewAsSupplierId;
      final Map res;
      if (sid != null) {
        final supplierName = widget.viewAsSupplierName ?? sid;
        res = await Supabase.instance.client.rpc(
          'admin_submit_inquiry_answers',
          params: {'p_supplier_name': supplierName, 'p_answers': answers},
        ) as Map;
      } else {
        res = await Supabase.instance.client.rpc(
          'supplier_submit_inquiry_answers',
          params: {'p_answers': answers},
        ) as Map;
      }
      // CHANGE #606 — toast copy is labels.submit_failed / labels.save_ok.
      // Was 'Error: <raw pg error>', 'Saved N response(s)' pluralised in Dart,
      // and 'Submit failed: <exception>' — three strings this screen wrote
      // itself, one of which leaked a database error to a supplier.
      if (res['error'] != null) {
        if (mounted) _toast(_label('submit_failed'), isError: true);
        return;
      }
      final saved = (res['saved'] as num?)?.toInt() ?? 0;
      _submitCount++;
      RenderLog.write('inq_submit_called', _submitCount);
      RenderLog.write('inq_submit_last_saved', saved);
      if (mounted) {
        _toast(_label('save_ok'));
        setState(() => _supplierSelections.clear());
        await _fetch(source: 'post_submit', silent: true);
      }
    } catch (e) {
      RenderLog.write('inq.submit.err', e.toString());
      if (mounted) _toast(_label('submit_failed'), isError: true);
    } finally {
      if (mounted) setState(() => _supplierSubmitting = false);
    }
  }

  Widget _buildSupplierSubmitButton() {
    // CHANGE #606 — the whole gate is the backend's.
    //
    // This used to re-implement it here: filter _pending by `locked != true &&
    // answered != true` (two fields the payload no longer even carries at top
    // level — they live under flags{} — so this filter was already reading
    // nothing and counting every pending row as answerable), then compare that
    // count against how many ids were in _supplierSelections, then build the
    // label 'Submit response (N)' or 'Respond to all to submit' in Dart.
    // supplier_inquiry_screen() computes answerable/answered from flags.is_locked
    // against the p_selected map we send it, and returns both `enabled` and the
    // finished `label`.
    final enabled = _submit['enabled'] == true;
    final label = (_submit['label'] as String?) ?? '';
    if (label.isEmpty) return const SizedBox.shrink();
    // CHANGE #607 — submit.bg/fg/border, from tone_colors(): green when the
    // backend says the form is submittable, grey when it is not. The four
    // hardcoded hexes that used to sit in this button's style block
    // (#1B7A43 fill, #D1FAE5 disabled fill, #6B7280 disabled label, white
    // label) are gone — one palette, in app_settings.
    final sBg = backendHex(_submit['bg'] as String?, Ds.c.bg);
    final sFg = backendHex(_submit['fg'] as String?, Ds.c.textSecondary);
    final sBorder = backendHex(_submit['border'] as String?, Ds.c.divider);
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(
        onPressed: (enabled && !_supplierSubmitting) ? _supplierSubmit : null,
        style: FilledButton.styleFrom(
          backgroundColor: sBg,
          disabledBackgroundColor: sBg,
          foregroundColor: sFg,
          disabledForegroundColor: sFg,
          side: BorderSide(color: sBorder),
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
        ),
        child: _supplierSubmitting
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(color: sFg, strokeWidth: 2))
            : Text(
                label,
                style: Ds.t.body.copyWith(
                    fontWeight: FontWeight.w700, color: sFg),
              ),
      ),
    );
  }

  /// CHANGE #606 — a toast with a backend string, or no toast at all. An empty
  /// label means the backend has nothing to say; showing a Dart substitute in
  /// its place would be inventing copy.
  void _toast(String message, {bool isError = false}) {
    if (message.isEmpty) return;
    showToast(context, message, isError: isError);
  }

  Future<void> _answer(int inquiryId, String answer) async {
    if (!mounted) return;
    setState(() => _answering.add(inquiryId));
    try {
      final sid = widget.viewAsSupplierId;
      if (sid != null) {
        final res = await Supabase.instance.client.rpc(
          'admin_writeas_supplier_answer',
          params: {
            'p_supplier_id': sid,
            'p_inquiry_id': inquiryId,
            'p_answer': answer,
          },
        ) as Map;
        // CHANGE #606 — labels.submit_failed. The two branches here wrote
        // their own copy: 'Already answered: <answer>' (the backend already
        // returns that sentence as answered_note) and 'Error: <raw pg error>'.
        if (res['error'] != null) {
          RenderLog.write('inq.answer.rej', res['error'].toString());
          if (mounted) _toast(_label('submit_failed'), isError: true);
          return;
        }
      } else {
        final res = await Supabase.instance.client.rpc(
          'supplier_answer_inquiry',
          params: {'p_inquiry_id': inquiryId, 'p_answer': answer},
        ) as Map;
        // CHANGE #606 — labels.submit_failed. The two branches here wrote
        // their own copy: 'Already answered: <answer>' (the backend already
        // returns that sentence as answered_note) and 'Error: <raw pg error>'.
        if (res['error'] != null) {
          RenderLog.write('inq.answer.rej', res['error'].toString());
          if (mounted) _toast(_label('submit_failed'), isError: true);
          return;
        }
      }
      RenderLog.write('inq.answer',
          'id=$inquiryId;ans=$answer;path=${widget.viewAsSupplierId != null ? "writeas" : "supplier"}');
      if (mounted) _toast(_label('save_ok'));
      await _fetch(source: 'post_answer', silent: true);
    } catch (e) {
      if (mounted) _toast(_label('submit_failed'), isError: true);
      RenderLog.write('inq.answer.err', e.toString().substring(0, 60));
    } finally {
      if (mounted) setState(() => _answering.remove(inquiryId));
    }
  }

  Future<int?> _bulkDontStockCompanyCategory(
      String company, String category) async {
    try {
      final sid = widget.viewAsSupplierId;
      if (sid != null) {
        final supplierName = widget.viewAsSupplierName ?? sid;
        final res = await Supabase.instance.client.rpc(
          'admin_inquiry_dont_stock_company_category',
          params: {
            'p_supplier_name': supplierName,
            'p_company': company,
            'p_category': category,
          },
        ) as Map;
        if (res['error'] != null) return null;
        await _fetch(source: 'bulk_dont_stock', silent: true);
        return (res['marked'] as num?)?.toInt() ?? 0;
      } else {
        final res = await Supabase.instance.client.rpc(
          'supplier_inquiry_dont_stock_company_category',
          params: {'p_company': company, 'p_category': category},
        ) as Map;
        if (res['error'] != null) return null;
        await _fetch(source: 'bulk_dont_stock', silent: true);
        return (res['marked'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      return null;
    }
  }

  void _toggleGroup(String group) {
    // CHANGE #607 — from here on the accordion is the user's, not is_open's.
    setState(() {
      _userToggled = true;
      _openGroup = _openGroup == group ? null : group;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // #111: write ACTUAL measured width — Phase 10 uses this to prove narrow
      // layout without clicking into a group.
      // At 390px: 390-40=350<600 → narrow guaranteed; at 1280px: 1240>=600 → wide.
      RenderLog.write('inq_supplier_vp_w', constraints.maxWidth.toInt().toString());
      return _buildContent(context);
    });
  }

  Widget _buildContent(BuildContext context) {
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(
            color: Ds.c.brand, strokeWidth: 2.5),
      );
    }

    // CHANGE #465: a receipt-only state (everything answered, nothing else
    // pending) is valid — show the receipt instead of the empty state.
    //
    // CHANGE #606 — `has_items` replaces the Dart sum
    // `_pending.length + _inquired.length + _expired.length == 0`, and the copy
    // is labels.empty. The second line ("You're all caught up!") is DELETED:
    // the backend has one empty-state string and this screen does not get to
    // invent a second one.
    if (!_hasItems && _receipt.isEmpty) {
      final emptyLabel = _label('empty');
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.check_circle_outline,
                size: 56, color: Ds.c.successSoft),
            if (emptyLabel.isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              Text(emptyLabel, style: Ds.t.bodySecondary),
            ],
          ],
        ),
      );
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x12, Ds.space.x12, Ds.space.x12, Ds.space.x48),
      children: [
        // ── CHANGE #687 (#68) — how long this supplier has left to answer,
        // above everything he is being asked. The block is the backend's and
        // so is the poll rate; has:false (nothing outstanding) draws nothing.
        ResponseDeadline(
          block: _deadline,
          renderKey: 'c687_sup_tab_deadline',
          onRefresh: () async => _fetch(source: 'deadline', silent: true),
        ),
        if (_receipt.isNotEmpty) ...[
          _buildReceiptSection(),
          const SizedBox(height: 8),
        ],
        // ── CHANGE #607 — the three sections come from groups[] ───────────
        //
        // This was three copy-pasted blocks, each naming its own group key,
        // its own `_pending.isNotEmpty` visibility test, its own const colour
        // pair (_kPendingBg/_kPendingText and friends), and its own spacing
        // rule that had to know which of the other two blocks rendered before
        // it. supplier_inquiry_screen() returns groups[] in display order with
        // key, label, count, show, is_open and bg/fg/border from tone_colors().
        // Adding, reordering, renaming or recolouring a group is an
        // app_settings edit now.
        for (final g in _groups) ...[
          if (_groupIndexShown(g) > 0) const SizedBox(height: 8),
          _InquiryGroup(
            label: (g['label'] as String?) ?? '',
            count: (g['count'] as num?)?.toInt() ?? 0,
            bgColor: backendHex(g['bg'] as String?, Ds.c.bg),
            textColor: backendHex(g['fg'] as String?, Ds.c.textSecondary),
            borderColor: backendHex(g['border'] as String?, Ds.c.divider),
            isOpen: _isGroupOpen(g),
            onToggle: () => _toggleGroup((g['key'] as String?) ?? ''),
            items: _itemsFor((g['key'] as String?) ?? ''),
            answeringIds: const {},
            answerOverrides: _supplierSelections,
            // CHANGE #606 — record the tap, then push the selection map to the
            // backend so IT re-decides whether submit is enabled and what the
            // button says.
            onAnswer: (id, answer) {
              setState(() => _supplierSelections[id] = answer);
              _scheduleSelectionSync();
            },
            // Only the group the backend marks answerable takes input: an
            // entry with no answerable items renders read-only and carries no
            // submit button. `readOnly` is derived from the payload's own
            // submit block, not from the group's name.
            readOnly: !_groupTakesAnswers(g),
            onBulkCompanyCategory:
                _groupTakesAnswers(g) ? _bulkDontStockLocalPending : null,
            submitButton:
                _groupTakesAnswers(g) ? _buildSupplierSubmitButton() : null,
          ),
        ],
      ],
    );
  }

  /// CHANGE #607 — the items array whose name equals the group's `key`. The
  /// payload still ships pending[]/inquired[]/expired[] alongside groups[].
  List<Map<String, dynamic>> _itemsFor(String key) => switch (key) {
        'pending' => _pending,
        'inquired' => _inquired,
        'expired' => _expired,
        _ => const [],
      };

  /// Sections the backend says to show, in its order.
  List<Map<String, dynamic>> get _shownGroups =>
      _groups.where((g) => g['show'] == true).toList();

  /// Position of this group among the shown ones — used only to decide whether
  /// a spacer is needed above it, never what to render.
  int _groupIndexShown(Map<String, dynamic> g) => _shownGroups.indexOf(g);

  /// Open state: the user's own toggle once they have touched one, otherwise
  /// the backend's is_open. The Pending > Inquired > Expired ladder this screen
  /// used to run is long gone; #607 also retires the auto_open string it was
  /// replaced with, because each group now states its own is_open.
  bool _isGroupOpen(Map<String, dynamic> g) {
    final key = (g['key'] as String?) ?? '';
    if (_openGroup != null || _userToggled) return _openGroup == key;
    return g['is_open'] == true;
  }

  /// A group takes answers when it holds the items the backend counted as
  /// answerable. `submit.answerable` is computed from the pending bucket, so a
  /// group whose items are not that bucket is read-only.
  bool _groupTakesAnswers(Map<String, dynamic> g) =>
      (g['key'] as String?) == 'pending' &&
      ((_submit['answerable'] as num?)?.toInt() ?? 0) > 0;

  // CHANGE #465: read-only receipt — success banner + one card per item
  // already answered today. No buttons, not tappable. Matches CHANGE #464's
  // public-link receipt for visual consistency across surfaces.
  Widget _buildReceiptSection() {
    try { RenderLog.write('c465_inquiry_receipt_tabs', 'supplier_tab'); } catch (_) {}
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
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // CHANGE #606 — labels.submitted. The second line
                    // ("You've already answered. Here's what you submitted.")
                    // is DELETED: no backend field carries it, and inventing
                    // replacement copy in Dart is the thing being removed.
                    if (_label('submitted').isNotEmpty)
                      Text(
                        _label('submitted'),
                        style: Ds.t.body.copyWith(
                            fontWeight: FontWeight.w700,
                            color: Ds.c.success),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: Ds.space.x12),
        ..._receipt.map(_buildReceiptCard),
      ],
    );
  }

  Widget _buildReceiptCard(Map<String, dynamic> item) {
    final name = item['product_name'] as String? ?? '';
    final company = item['company'] as String?;
    final imageUrl = item['image_url'] as String?;

    // CHANGE #606 — answer_badge, painted verbatim.
    //
    // This was a `switch (answer)` holding a third copy of the answer
    // vocabulary: it matched the exact strings 'Available' and 'Out of Stock'
    // and silently fell through to "Don't stock" for anything else — so any
    // answer wording changed in app_settings would have been mislabelled here
    // as "Don't stock". inquiry_answer_badge() reads that same config and
    // returns {label,bg,fg}; BackendChip draws it and draws nothing when the
    // backend returns no badge.
    final badge = backendChipOf(item, 'answer_badge');

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
          SizedBox(width: Ds.space.x12),
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
                  SizedBox(height: Ds.space.x4),
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
          SizedBox(width: Ds.space.x8),
          BackendChip(
            chip: badge,
            fontSize: Ds.t.captionSize,
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x8, vertical: Ds.space.x4),
          ),
        ],
      ),
    );
  }
}

class _InquiryGroup extends StatelessWidget {
  final String label;
  final int count;
  final Color bgColor;
  final Color textColor;
  /// CHANGE #607 — the backend's own border colour. The header used to derive
  /// one as `textColor.withValues(alpha: 0.25)`; groups[] supplies it.
  final Color borderColor;
  final bool isOpen;
  final VoidCallback onToggle;
  final List<Map<String, dynamic>> items;
  final Set<int> answeringIds;
  final Map<int, String> answerOverrides;
  final void Function(int, String) onAnswer;
  final Future<int?> Function(String, String)? onBulkCompanyCategory;
  final bool readOnly;
  final Widget? submitButton;

  const _InquiryGroup({
    required this.label,
    required this.count,
    required this.bgColor,
    required this.textColor,
    required this.borderColor,
    required this.isOpen,
    required this.onToggle,
    required this.items,
    required this.answeringIds,
    this.answerOverrides = const {},
    required this.onAnswer,
    this.onBulkCompanyCategory,
    this.readOnly = false,
    this.submitButton,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: Ds.r.rButton,
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(Ds.r.button)),
            onTap: onToggle,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x12),
              child: Row(children: [
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                    color: textColor.withValues(alpha: 0.12),
                    borderRadius: Ds.r.rButton,
                  ),
                  child: Text(
                    count.toString(),
                    style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                // CHANGE #606 — an empty backend label draws nothing; the
                // group itself still renders, because hiding it would hide the
                // supplier's items, not just a word.
                Expanded(
                  child: label.isEmpty
                      ? const SizedBox.shrink()
                      : Text(
                          label,
                          style: Ds.t.body.copyWith(
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                ),
                Icon(
                  isOpen
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  color: textColor,
                  size: 22,
                ),
              ]),
            ),
          ),
          if (isOpen) ...[
            Divider(
                height: 1, color: textColor.withValues(alpha: 0.2)),
            Padding(
              padding: EdgeInsets.all(Ds.space.x8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InquiryAnswerList(
                    key: ValueKey('grp_${label}_${items.length}'),
                    items: items,
                    answerOverrides: answerOverrides,
                    answeringIds: answeringIds,
                    onAnswer: onAnswer,
                    onBulkCompanyCategory: onBulkCompanyCategory,
                    readOnly: readOnly,
                    surface: 'supplier',
                  ),
                  if (submitButton != null) ...[
                    const SizedBox(height: 12),
                    submitButton!,
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
