import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../../widgets/inquiry_v12.dart';

// Colour tokens for the three inquiry states
const _kPendingBg    = Color(0xFFFFF7E0);
const _kPendingText  = Color(0xFFB26A00);
const _kInquiredBg   = Color(0xFFE8F5E9);
const _kInquiredText = Color(0xFF2E7D32);
const _kExpiredBg    = Color(0xFFFDECEA);
const _kExpiredText  = Color(0xFFC62828);

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

  final Set<int> _answering = {};
  RealtimeChannel? _rt;
  Timer? _c458Debounce;
  int _c458Events = 0;
  int _c458Reloads = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try { RenderLog.write('c458_timers', 0); } catch (_) {}
    _fetch(source: 'init');
    // Realtime only for real (non-View-As) suppliers
    if (widget.viewAsSupplierId == null) _subscribeRealtime();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_rt != null) {
      try { Supabase.instance.client.removeChannel(_rt!); } catch (_) {}
      _rt = null;
    }
    _c458Debounce?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetch(source: 'lifecycle_resume', silent: true);
      // CHANGE #458: a backgrounded socket dies silently — re-subscribe.
      if (widget.viewAsSupplierId == null) _subscribeRealtime();
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
      final params = sid != null
          ? <String, dynamic>{'p_supplier_id': sid}
          : <String, dynamic>{};
      final rows = await Supabase.instance.client
          .rpc('supplier_inquiry_buckets', params: params);
      if (!mounted) return;

      // CHANGE #465: receipt of items already answered today. supplier_my_inquiry_receipt()
      // resolves identity from the caller's own JWT, so it only works for a real logged-in
      // supplier — View-As mode (admin browsing on behalf of a named supplier) has no
      // supplier JWT to resolve, so it uses the named-lookup RPC instead.
      List<Map<String, dynamic>> receipt = [];
      try {
        final receiptRows = sid != null
            ? await Supabase.instance.client.rpc('get_supplier_inquiry_receipt',
                params: {'p_supplier_name': widget.viewAsSupplierName ?? sid})
            : await Supabase.instance.client.rpc('supplier_my_inquiry_receipt');
        receipt = (receiptRows as List<dynamic>? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } catch (_) {}
      if (!mounted) return;

      final list = (rows as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final pending  = list.where((r) => r['state'] == 'pending').toList();
      final inquired = list.where((r) => r['state'] == 'inquired').toList();
      final expired  = list.where((r) => r['state'] == 'expired').toList();

      // Auto-open on first load: Pending > Inquired > Expired
      String? autoOpen;
      if (_firstLoad) {
        if (pending.isNotEmpty) {
          autoOpen = 'pending';
        } else if (inquired.isNotEmpty) {
          autoOpen = 'inquired';
        } else if (expired.isNotEmpty) {
          autoOpen = 'expired';
        }
      }

      setState(() {
        _pending  = pending;
        _inquired = inquired;
        _expired  = expired;
        _receipt  = receipt;
        if (_firstLoad && autoOpen != null) _openGroup = autoOpen;
        _firstLoad = false;
        _loading = false;
      });

      final mode = sid != null ? 'viewas' : 'supplier';
      RenderLog.write('inq.src.mode', mode);
      RenderLog.write('inq.counts',
          'p=${pending.length};i=${inquired.length};e=${expired.length}');
      RenderLog.write('inq.colours',
          'pending=yellow;inquired=green;expired=red');
      RenderLog.write('inq.badge', pending.length);
      if (autoOpen != null) RenderLog.write('inq.autoopen', autoOpen);
      RenderLog.write('inq.refresh.source', source);
      RenderLog.write('inq.norefreshbtn', 1);

      widget.onPendingCount?.call(pending.length);
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      RenderLog.write('inq.fetch.err', e.toString().substring(0, 60));
    }
  }

  // Bulk don't-stock for pending group — updates local selections only
  Future<int?> _bulkDontStockLocalPending(String company, String category) async {
    final matching = _pending.where((r) {
      final c = (r['company'] as String? ?? '').toLowerCase();
      final cat = (r['therapeutic_class'] as String? ?? '').toUpperCase();
      return c == company.toLowerCase() && cat == category.toUpperCase();
    }).toList();
    final ids = matching.map((r) => (r['inquiry_id'] as num).toInt()).toList();
    if (mounted) {
      setState(() {
        for (final id in ids) {
          _supplierSelections[id] = "We don't stock this product";
        }
      });
    }
    return ids.length;
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
      if (res['error'] != null) {
        if (mounted) showToast(context, 'Error: ${res['error']}', isError: true);
        return;
      }
      final saved = (res['saved'] as num?)?.toInt() ?? 0;
      _submitCount++;
      RenderLog.write('inq_submit_called', _submitCount);
      RenderLog.write('inq_submit_last_saved', saved);
      if (mounted) {
        showToast(context, 'Saved $saved response${saved == 1 ? '' : 's'}');
        setState(() => _supplierSelections.clear());
        await _fetch(source: 'post_submit', silent: true);
      }
    } catch (e) {
      if (mounted) showToast(context, 'Submit failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _supplierSubmitting = false);
    }
  }

  Widget _buildSupplierSubmitButton() {
    final answerableItems = _pending
        .where((item) => item['locked'] != true && item['answered'] != true)
        .toList();
    final answerableCount = answerableItems.length;
    final answeredCount = answerableItems
        .where((item) => _supplierSelections
            .containsKey((item['inquiry_id'] as num).toInt()))
        .length;
    final allAnswered =
        answerableCount > 0 && answeredCount >= answerableCount;
    final count = _supplierSelections.length;
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton(
        onPressed: (allAnswered && !_supplierSubmitting) ? _supplierSubmit : null,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF1B7A43),
          disabledBackgroundColor: const Color(0xFFD1FAE5),
          disabledForegroundColor: const Color(0xFF6B7280),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: _supplierSubmitting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
            : Text(
                allAnswered
                    ? 'Submit response ($count)'
                    : 'Respond to all to submit',
                style: const TextStyle(
                    fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
              ),
      ),
    );
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
        if (res['error'] != null) {
          final err = res['error'] as String;
          if (mounted) {
            showToast(
              context,
              err == 'already_answered'
                  ? 'Already answered: ${res['answer']}'
                  : 'Error: $err',
              isError: true,
            );
          }
          return;
        }
      } else {
        final res = await Supabase.instance.client.rpc(
          'supplier_answer_inquiry',
          params: {'p_inquiry_id': inquiryId, 'p_answer': answer},
        ) as Map;
        if (res['error'] != null) {
          final err = res['error'] as String;
          if (mounted) {
            showToast(
              context,
              err == 'already_answered'
                  ? 'Already answered: ${res['answer']}'
                  : 'Error: $err',
              isError: true,
            );
          }
          return;
        }
      }
      RenderLog.write('inq.answer',
          'id=$inquiryId;ans=$answer;path=${widget.viewAsSupplierId != null ? "writeas" : "supplier"}');
      if (mounted) showToast(context, 'Response saved');
      await _fetch(source: 'post_answer', silent: true);
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e', isError: true);
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
    setState(() => _openGroup = _openGroup == group ? null : group);
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
      return const Center(
        child: CircularProgressIndicator(
            color: Color(0xFF1B7A43), strokeWidth: 2.5),
      );
    }

    final total = _pending.length + _inquired.length + _expired.length;

    // CHANGE #465: a receipt-only state (everything answered, nothing else
    // pending) is valid — show the receipt instead of the empty state.
    if (total == 0 && _receipt.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle_outline,
                size: 56, color: Color(0xFFD1FAE5)),
            const SizedBox(height: 12),
            const Text(
              'No inquiries',
              style: TextStyle(fontSize: 15, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 6),
            const Text(
              "You're all caught up!",
              style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
      children: [
        if (_receipt.isNotEmpty) ...[
          _buildReceiptSection(),
          const SizedBox(height: 8),
        ],
        if (_pending.isNotEmpty)
          _InquiryGroup(
            label: 'Pending',
            count: _pending.length,
            bgColor: _kPendingBg,
            textColor: _kPendingText,
            isOpen: _openGroup == 'pending',
            onToggle: () => _toggleGroup('pending'),
            items: _pending,
            answeringIds: const {},
            answerOverrides: _supplierSelections,
            onAnswer: (id, answer) =>
                setState(() => _supplierSelections[id] = answer),
            onBulkCompanyCategory: _bulkDontStockLocalPending,
            submitButton: _buildSupplierSubmitButton(),
          ),
        if (_inquired.isNotEmpty) ...[
          if (_pending.isNotEmpty) const SizedBox(height: 8),
          _InquiryGroup(
            label: 'Inquired',
            count: _inquired.length,
            bgColor: _kInquiredBg,
            textColor: _kInquiredText,
            isOpen: _openGroup == 'inquired',
            onToggle: () => _toggleGroup('inquired'),
            items: _inquired,
            answeringIds: const {},
            onAnswer: (_, __) {},
            readOnly: true,
          ),
        ],
        if (_expired.isNotEmpty) ...[
          if (_pending.isNotEmpty || _inquired.isNotEmpty)
            const SizedBox(height: 8),
          _InquiryGroup(
            label: 'Expired',
            count: _expired.length,
            bgColor: _kExpiredBg,
            textColor: _kExpiredText,
            isOpen: _openGroup == 'expired',
            onToggle: () => _toggleGroup('expired'),
            items: _expired,
            answeringIds: const {},
            onAnswer: (_, __) {},
            readOnly: true,
          ),
        ],
      ],
    );
  }

  // CHANGE #465: read-only receipt — success banner + one card per item
  // already answered today. No buttons, not tappable. Matches CHANGE #464's
  // public-link receipt for visual consistency across surfaces.
  Widget _buildReceiptSection() {
    try { RenderLog.write('c465_inquiry_receipt_tabs', 'supplier_tab'); } catch (_) {}
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFD1FAE5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.check_circle,
                  color: Color(0xFF065F46), size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Response submitted ✓',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF065F46)),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      "You've already answered. Here's what you submitted.",
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFF065F46)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ..._receipt.map(_buildReceiptCard),
      ],
    );
  }

  Widget _buildReceiptCard(Map<String, dynamic> item) {
    final name = item['product_name'] as String? ?? '';
    final company = item['company'] as String?;
    final imageUrl = item['image_url'] as String?;
    final answer = item['answer'] as String? ?? '';

    Color badgeBg;
    Color badgeFg;
    String badgeLabel;
    switch (answer) {
      case 'Available':
        badgeBg = const Color(0xFFD1FAE5);
        badgeFg = const Color(0xFF065F46);
        badgeLabel = 'Available';
      case 'Out of Stock':
        badgeBg = const Color(0xFFFEE2E2);
        badgeFg = const Color(0xFF991B1B);
        badgeLabel = 'Out of Stock';
      default:
        badgeBg = const Color(0xFFF3F4F6);
        badgeFg = const Color(0xFF6B7280);
        badgeLabel = "Don't stock";
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
            ),
            clipBehavior: Clip.antiAlias,
            child: imageUrl != null && imageUrl.isNotEmpty
                ? Image.network(imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(
                        Icons.medication_outlined,
                        size: 20,
                        color: Color(0xFFD1D5DB)))
                : const Icon(Icons.medication_outlined,
                    size: 20, color: Color(0xFFD1D5DB)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (company != null && company.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    company,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
                color: badgeBg, borderRadius: BorderRadius.circular(20)),
            child: Text(
              badgeLabel,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500, color: badgeFg),
            ),
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
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: textColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
            onTap: onToggle,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: textColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    count.toString(),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
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
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
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
