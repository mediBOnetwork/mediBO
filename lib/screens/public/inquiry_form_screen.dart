import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';
import '../../widgets/inquiry_v12.dart';

const _kGreen = Color(0xFF1B7A43);

class InquiryFormScreen extends StatefulWidget {
  final String token;
  const InquiryFormScreen({super.key, required this.token});

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
          .rpc('get_inquiry_form', params: {'p_token': widget.token});

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
        _items = items;
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

  Future<void> _submit() async {
    final unanswered = _items.where((i) => i['locked'] == false).toList();
    final toSubmit = unanswered
        .map((i) {
          final id = (i['inquiry_id'] as num).toInt();
          return {'inquiry_id': id, 'answer': _selections[id] ?? ''};
        })
        .where((a) => (a['answer'] as String).isNotEmpty)
        .toList();

    if (toSubmit.isEmpty) return;

    setState(() => _submitting = true);
    try {
      await Supabase.instance.client.rpc('submit_inquiry_form', params: {
        'p_token': widget.token,
        'p_answers': toSubmit,
      });
      RenderLog.write('inquiry_form_submitted', '${toSubmit.length}_answers');
      await _load();
    } catch (e) {
      RenderLog.write(
          'inquiry_form_submit_error', e.toString().substring(0, 40));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Submission failed. Please try again.'),
            backgroundColor: Color(0xFFDC2626),
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
    return unanswered.every(
        (i) => _selections.containsKey((i['inquiry_id'] as num).toInt()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: _kGreen, strokeWidth: 2.5))
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
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                isExpired
                    ? Icons.timer_off_outlined
                    : Icons.link_off_outlined,
                size: 36,
                color: const Color(0xFF9CA3AF),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              isExpired
                  ? 'This inquiry link has expired'
                  : 'This link is no longer valid',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              isExpired
                  ? 'Please contact mediBO for a new link.'
                  : 'Please contact mediBO for assistance.',
              style: const TextStyle(
                  fontSize: 14, color: Color(0xFF6B7280)),
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
        ..._submittedItems.map(_buildReceiptCard),
        const SizedBox(height: 16),
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

  Widget _buildForm() {
    final locked = _items.where((i) => i['locked'] == true).toList();
    final unanswered = _items.where((i) => i['locked'] == false).toList();
    final allDone = unanswered.isEmpty && _items.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header card ──────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _kGreen,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.medication_outlined,
                    color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'mediBO · Stock Check',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _supplierName ?? '',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          // ── Receipt (CHANGE #464): read-only summary of what was already
          // submitted this cycle. Purely additive — does not replace the
          // existing "Already Responded" accordion below, which reflects a
          // different, longer-lived source (the inquiry table's PS/AS slots).
          if (_submitted && _submittedItems.isNotEmpty) _buildReceiptSection(),

          // ── New items banner ─────────────────────────────────────────────
          if (_newItemsAdded) ...[
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFCD34D)),
              ),
              child: const Row(children: [
                Icon(Icons.info_outline,
                    size: 16, color: Color(0xFFD97706)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'New items added — please respond below',
                    style: TextStyle(
                        fontSize: 13, color: Color(0xFF92400E)),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),
          ],

          // ── All done banner ──────────────────────────────────────────────
          if (allDone) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF6EE7B7)),
              ),
              child: const Row(children: [
                Icon(Icons.check_circle_outline,
                    color: _kGreen, size: 22),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'All responses submitted. Thank you!',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _kGreen),
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
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF9FAFB),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: Row(children: [
                  const Icon(Icons.check_circle_outline,
                      size: 16, color: Color(0xFF6B7280)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Already Responded (${locked.length})',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                  Icon(
                    _respondedExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 20,
                    color: const Color(0xFF9CA3AF),
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
            const Text(
              'PENDING RESPONSE — REQUIRED',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151),
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
              surface: 'link',
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: (_canSubmit && !_submitting) ? _submit : null,
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  disabledBackgroundColor: const Color(0xFFD1FAE5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text(
                        'Submit Responses',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.white),
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: Text(
                'All fields are required before submitting',
                style: TextStyle(
                    fontSize: 12,
                    color: _canSubmit
                        ? const Color(0xFF9CA3AF)
                        : const Color(0xFFDC2626)),
              ),
            ),
          ],

          const SizedBox(height: 32),
          Center(
            child: Text(
              'mediBO · Powered by mediBO B2B Pharmacy',
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFF9CA3AF)),
            ),
          ),
        ],
      ),
    );
  }
}
