import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';
import '../../utils/toast.dart';

class SupplierInquiryScreen extends StatefulWidget {
  final String? viewAsSupplierId;
  const SupplierInquiryScreen({super.key, this.viewAsSupplierId});

  @override
  State<SupplierInquiryScreen> createState() => SupplierInquiryScreenState();
}

class SupplierInquiryScreenState extends State<SupplierInquiryScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  final Set<int> _answering = {};

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final viewAsSupplierId = widget.viewAsSupplierId;
      final res = await Supabase.instance.client.rpc(
        viewAsSupplierId != null
            ? 'admin_preview_supplier_inquiries'
            : 'supplier_my_inquiry_items',
        params: viewAsSupplierId != null
            ? {'p_supplier_id': viewAsSupplierId}
            : null,
      ) as List;
      if (mounted) {
        setState(() {
          _items = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
        });
        RenderLog.write('supplier_inquiry_items', _items.length);
      }
    } catch (e) {
      RenderLog.write('supplier_inquiry_error', e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _answer(int inquiryId, String answer) async {
    setState(() => _answering.add(inquiryId));
    try {
      final rpcName = widget.viewAsSupplierId != null
          ? 'admin_writeas_supplier_answer'
          : 'supplier_answer_inquiry';
      final params = widget.viewAsSupplierId != null
          ? {'p_supplier_id': widget.viewAsSupplierId!, 'p_inquiry_id': inquiryId, 'p_answer': answer}
          : {'p_inquiry_id': inquiryId, 'p_answer': answer};
      final res = await Supabase.instance.client.rpc(rpcName, params: params) as Map;
      if (res['error'] != null) {
        final err = res['error'] as String;
        if (mounted) {
          showToast(context,
            err == 'already_answered' ? 'Already answered: ${res['answer']}' : 'Error: $err',
            isError: true,
          );
        }
      } else {
        RenderLog.write('supplier_inquiry_answered', '$inquiryId:$answer');
        if (mounted) showToast(context, 'Response saved');
        await _fetch(silent: true);
      }
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _answering.remove(inquiryId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43)));
    }

    if (_items.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.check_circle_outline, size: 56, color: Color(0xFFD1FAE5)),
          const SizedBox(height: 12),
          const Text('No pending inquiry items.',
            style: TextStyle(fontSize: 15, color: Color(0xFF6B7280))),
          const SizedBox(height: 6),
          const Text('You\'re all caught up!',
            style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _fetch(),
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('Refresh'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF1B7A43),
              side: const BorderSide(color: Color(0xFF1B7A43)),
            ),
          ),
        ]),
      );
    }

    return RefreshIndicator(
      color: const Color(0xFF1B7A43),
      onRefresh: () => _fetch(),
      child: ListView(
        padding: EdgeInsets.all(isDesktop ? 24 : 12),
        children: [
          // Header
          Row(children: [
            Text('${_items.length} item${_items.length == 1 ? '' : 's'}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _fetch(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
              style: TextButton.styleFrom(foregroundColor: const Color(0xFF1B7A43)),
            ),
          ]),
          const SizedBox(height: 8),
          ..._items.map((item) => _InquiryItemCard(
            item: item,
            isAnswering: _answering.contains((item['inquiry_id'] as num).toInt()),
            onAnswer: _answer,
          )),
        ],
      ),
    );
  }
}

// ── Item card ─────────────────────────────────────────────────────────────────

class _InquiryItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isAnswering;
  final Future<void> Function(int inquiryId, String answer) onAnswer;

  static const List<String> _answers = [
    'Available',
    'Out of Stock',
    "We don't stock this product",
  ];

  const _InquiryItemCard({
    required this.item,
    required this.isAnswering,
    required this.onAnswer,
  });

  @override
  Widget build(BuildContext context) {
    final role        = item['role']         as String? ?? 'current';
    final productName = item['product_name'] as String? ?? '';
    final qty         = item['quantity'];
    final mrp         = item['mrp'];
    final answer      = item['answer']       as String?;
    final answered    = item['answered']     as bool? ?? false;
    final inquiryId   = (item['inquiry_id']  as num).toInt();
    final isCurrent   = role == 'current';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent ? const Color(0xFFA7F3D0) : const Color(0xFFFDE68A),
        ),
        boxShadow: const [BoxShadow(
          color: Color(0x0A000000), blurRadius: 4, offset: Offset(0, 1),
        )],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          // Role badge
          _badge(
            isCurrent ? 'Current' : 'Next',
            isCurrent ? const Color(0xFFE6F4EA) : const Color(0xFFFFF8E1),
            isCurrent ? const Color(0xFF1B7F3B) : const Color(0xFF8A6D00),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(productName,
              style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        const SizedBox(height: 6),
        if (qty != null || mrp != null)
          Text(
            [if (qty != null) 'Qty: $qty', if (mrp != null) 'MRP ₹$mrp'].join('  ·  '),
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
        const SizedBox(height: 10),
        // Answer section
        if (answered && answer != null)
          _answeredChip(answer)
        else if (isAnswering)
          const SizedBox(
            height: 20, width: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)),
          )
        else
          _answerButtons(inquiryId),
      ]),
    );
  }

  Widget _badge(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  Widget _answeredChip(String answer) {
    final isAvailable = answer == 'Available';
    return Row(children: [
      Icon(
        isAvailable ? Icons.check_circle : Icons.cancel,
        size: 16,
        color: isAvailable ? const Color(0xFF065F46) : const Color(0xFF92400E),
      ),
      const SizedBox(width: 6),
      Text(answer,
        style: TextStyle(
          fontSize: 13, fontWeight: FontWeight.w500,
          color: isAvailable ? const Color(0xFF065F46) : const Color(0xFF92400E),
        ),
      ),
    ]);
  }

  Widget _answerButtons(int inquiryId) {
    return Wrap(spacing: 6, runSpacing: 6, children: _answers.map((ans) {
      Color bg, fg, border;
      if (ans == 'Available') {
        bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46); border = const Color(0xFF6EE7B7);
      } else if (ans == 'Out of Stock') {
        bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); border = const Color(0xFFFCD34D);
      } else {
        bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B); border = const Color(0xFFFCA5A5);
      }
      return InkWell(
        onTap: () => onAnswer(inquiryId, ans),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: border),
          ),
          child: Text(ans, style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, color: fg,
          )),
        ),
      );
    }).toList());
  }
}
