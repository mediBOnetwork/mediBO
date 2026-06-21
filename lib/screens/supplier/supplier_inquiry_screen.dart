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
  bool _loading = true;
  bool _firstLoad = true;

  // One open group at a time; null = all collapsed
  String? _openGroup; // 'pending' | 'inquired' | 'expired'

  final Set<int> _answering = {};
  RealtimeChannel? _rt;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetch(source: 'init');
    // Realtime only for real (non-View-As) suppliers
    if (widget.viewAsSupplierId == null) _subscribeRealtime();
    _startPoll();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _rt?.unsubscribe();
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetch(source: 'lifecycle_resume', silent: true);
    }
  }

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 20), (_) {
      _fetch(source: 'poll_20s', silent: true);
    });
  }

  void _subscribeRealtime() {
    _rt = Supabase.instance.client
        .channel('sup_inq_rt_${DateTime.now().millisecondsSinceEpoch}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'inquiry',
          callback: (_) => _fetch(source: 'realtime', silent: true),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'inquiry_forms',
          callback: (_) => _fetch(source: 'realtime', silent: true),
        )
        .subscribe();
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
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
            color: Color(0xFF1B7A43), strokeWidth: 2.5),
      );
    }

    final total = _pending.length + _inquired.length + _expired.length;

    if (total == 0) {
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
        if (_pending.isNotEmpty)
          _InquiryGroup(
            label: 'Pending',
            count: _pending.length,
            bgColor: _kPendingBg,
            textColor: _kPendingText,
            isOpen: _openGroup == 'pending',
            onToggle: () => _toggleGroup('pending'),
            items: _pending,
            answeringIds: _answering,
            onAnswer: _answer,
            onBulkCompanyCategory: _bulkDontStockCompanyCategory,
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
            answeringIds: _answering,
            onAnswer: _answer,
            onBulkCompanyCategory: _bulkDontStockCompanyCategory,
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
            answeringIds: _answering,
            onAnswer: _answer,
            onBulkCompanyCategory: _bulkDontStockCompanyCategory,
            readOnly: true,
          ),
        ],
      ],
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
  final Future<void> Function(int, String) onAnswer;
  final Future<int?> Function(String, String) onBulkCompanyCategory;
  final bool readOnly;

  const _InquiryGroup({
    required this.label,
    required this.count,
    required this.bgColor,
    required this.textColor,
    required this.isOpen,
    required this.onToggle,
    required this.items,
    required this.answeringIds,
    required this.onAnswer,
    required this.onBulkCompanyCategory,
    this.readOnly = false,
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
              child: InquiryAnswerList(
                key: ValueKey('grp_${label}_${items.length}'),
                items: items,
                answeringIds: answeringIds,
                onAnswer: onAnswer,
                onBulkCompanyCategory: onBulkCompanyCategory,
                readOnly: readOnly,
                surface: 'supplier',
              ),
            ),
          ],
        ],
      ),
    );
  }
}
