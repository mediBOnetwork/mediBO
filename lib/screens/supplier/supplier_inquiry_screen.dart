import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../../widgets/inquiry_v12.dart';

class SupplierInquiryScreen extends StatefulWidget {
  final String? viewAsSupplierId;
  final String? viewAsSupplierName;
  final VoidCallback? onRefreshBadge;
  const SupplierInquiryScreen({
    super.key,
    this.viewAsSupplierId,
    this.viewAsSupplierName,
    this.onRefreshBadge,
  });

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
      final isViewAs = viewAsSupplierId != null;
      final res = await Supabase.instance.client.rpc(
        isViewAs
            ? 'admin_preview_supplier_inquiries'
            : 'supplier_my_inquiry_items',
        params: isViewAs ? {'p_supplier_id': viewAsSupplierId} : null,
      ) as List;
      if (mounted) {
        List<Map<String, dynamic>> mapped;
        if (isViewAs) {
          // admin_preview_supplier_inquiries returns different column names:
          // id → inquiry_id, has_answer → answered; company/therapeutic_class absent.
          mapped = res.map((r) {
            final m = Map<String, dynamic>.from(r as Map);
            return <String, dynamic>{
              'inquiry_id':        m['id'],
              'product_name':      m['product_name'] ?? '',
              'quantity':          m['quantity'],
              'mrp':               m['mrp'],
              'role':              m['role'],
              'slot_index':        m['slot_index'],
              'answer':            m['answer'],
              'answered':          m['has_answer'] ?? false,
              'locked':            false,
              'company':           m['company'] ?? '',
              'therapeutic_class': m['therapeutic_class'] ?? '',
              'image_url':         null,
            };
          }).toList();
        } else {
          mapped = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
        }
        setState(() => _items = mapped);
        RenderLog.write('inq.read.mode', isViewAs
            ? 'viewas_supplier:$viewAsSupplierId'
            : 'real_supplier');
        RenderLog.write('inq.list.count', _items.length);
        RenderLog.write('supplier_inquiry_rows_${_items.length}', 'true');
        RenderLog.write('inquiry_v12_supplier_page', 'true');
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
          ? {
              'p_supplier_id': widget.viewAsSupplierId!,
              'p_inquiry_id': inquiryId,
              'p_answer': answer
            }
          : {'p_inquiry_id': inquiryId, 'p_answer': answer};
      final res =
          await Supabase.instance.client.rpc(rpcName, params: params) as Map;
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
      } else {
        RenderLog.write('supplier_inquiry_answered', '$inquiryId:$answer');
        RenderLog.write('inq.answer.path',
            widget.viewAsSupplierId != null ? 'admin_writeas' : 'supplier_rpc');
        if (mounted) showToast(context, 'Response saved');
        await _fetch(silent: true);
        widget.onRefreshBadge?.call();
        RenderLog.write('inq.refetch.ok', 1);
      }
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _answering.remove(inquiryId));
    }
  }

  Future<void> _bulkAnswer(List<int> ids, String answer) async {
    if (answer.isEmpty) return; // clear not supported for supplier (no RPC)
    for (final id in ids) {
      await _answer(id, answer);
    }
  }

  Future<int?> _bulkDontStockCompanyCategory(
      String company, String category) async {
    try {
      final rpcName = widget.viewAsSupplierId != null
          ? 'admin_inquiry_dont_stock_company_category'
          : 'supplier_inquiry_dont_stock_company_category';
      final params = widget.viewAsSupplierId != null
          ? {
              'p_supplier_name': widget.viewAsSupplierName ?? widget.viewAsSupplierId!,
              'p_company': company,
              'p_category': category,
            }
          : {'p_company': company, 'p_category': category};

      final res = await Supabase.instance.client.rpc(rpcName, params: params)
          as Map;
      if (res['error'] != null) return null;
      final marked = (res['marked'] as num?)?.toInt() ?? 0;
      RenderLog.write('supplier_bulk_dont_stock',
          '${company}_${category}_$marked');
      await _fetch(silent: true);
      return marked;
    } catch (e) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF1B7A43)));
    }

    if (_items.isEmpty) {
      RenderLog.write('supplier_inquiry_empty_state', 'true');
      return Center(
        child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
          const Icon(Icons.check_circle_outline,
              size: 56, color: Color(0xFFD1FAE5)),
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
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111827)),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _fetch(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
              style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF1B7A43)),
            ),
          ]),
          const SizedBox(height: 10),
          InquiryAnswerList(
            items: _items,
            onAnswer: _answer,
            onBulk: _bulkAnswer,
            onBulkCompanyCategory: _bulkDontStockCompanyCategory,
            answeringIds: _answering,
            surface: 'supplier',
          ),
        ],
      ),
    );
  }
}
