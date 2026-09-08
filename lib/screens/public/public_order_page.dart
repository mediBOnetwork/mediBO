import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/date_labels.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../widgets/order_item_card.dart';

// CHANGE #465 · register row 51 — the six hardcoded colours that used to live
// here are gone. ui_design_set() could not recolour this page; it can now.

class PublicOrderPage extends StatefulWidget {
  final String token;
  const PublicOrderPage({super.key, required this.token});

  @override
  State<PublicOrderPage> createState() => _PublicOrderPageState();
}

class _PublicOrderPageState extends State<PublicOrderPage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _order;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await Supabase.instance.client
          .rpc('get_supplier_order_by_token', params: {'p_token': widget.token}) as List;
      if (rows.isEmpty) {
        setState(() { _loading = false; _error = c('public_order.error_not_found'); });
        return;
      }
      final data = Map<String, dynamic>.from(rows.first as Map);
      final rawItems = data['items'];
      final parsedItems = rawItems is List
          ? rawItems.map((e) => Map<String, dynamic>.from(e as Map)).toList()
          : <Map<String, dynamic>>[];
      setState(() {
        _order = data;
        _items = parsedItems;
        _loading = false;
      });
      RenderLog.write('c188_order_page_loaded', 'true');
      RenderLog.write('c189_order_page_shared_card', 'true');
      RenderLog.write('c189_order_page_items', parsedItems.length);
    } catch (e) {
      setState(() { _loading = false; _error = cf('public_order.error_load_failed', {'error': '$e'}); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.brand,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text(c('public_order.page_title'),
            style: Ds.t.subtitle.copyWith(color: Ds.c.surface)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: Ds.c.brand))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(Ds.space.x24),
                    child: Text(_error!,
                        style: Ds.t.body.copyWith(color: Ds.c.danger)),
                  ),
                )
              : _buildContent(),
    );
  }

  Widget _buildContent() {
    final order = _order!;
    final supplierName = order['supplier_name'] as String? ?? '—';
    final orderNo      = order['order_no']?.toString() ?? '—';
    final createdAt    = order['created_at']    as String?;
    final dateStr = createdAt != null ? _formatDate(createdAt) : '—';

    return SingleChildScrollView(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: Ds.space.x8),
              _headerCard(supplierName, orderNo, dateStr),
              SizedBox(height: Ds.space.x16),
              Text(c('public_order.section_items'), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x8),
              if (_items.isEmpty)
                Text(c('public_order.empty_items'), style: Ds.t.caption)
              else
                ..._items.map((item) => OrderItemCard(item: item)),
              SizedBox(height: Ds.space.x32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerCard(String supplier, String orderNo, String date) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(supplier, style: Ds.t.subtitle)),
          _statusChip(),
        ]),
        SizedBox(height: Ds.space.x4),
        Text(cf('public_order.order_number', {'no': orderNo}),
            style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Text(date, style: Ds.t.caption),
      ]),
    );
  }

  /// CHANGE #465 · row 51 — the chip's WORD and its TONE are the backend's
  /// (`status_label`, `status_tone`). This used to branch on the status string
  /// in Dart and pick one of six hardcoded hexes, which is a display decision
  /// made client-side — the same bug as the literals, wearing a switch.
  Widget _statusChip() {
    final order = _order ?? const {};
    final label = (order['status_label'] ?? '').toString();
    if (label.isEmpty) return const SizedBox.shrink();
    final tone = (order['status_tone'] ?? '').toString();
    final fg = tone == 'success'
        ? Ds.c.success
        : tone == 'danger'
            ? Ds.c.danger
            : Ds.c.warning;
    final bg = tone == 'success'
        ? Ds.c.successSoft
        : tone == 'danger'
            ? Ds.c.dangerSoft
            : Ds.c.warningSoft;
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
      child: Text(label, style: Ds.t.caption.copyWith(color: fg)),
    );
  }

  // CHANGE #548: backend-formatted (ist_fmt 'dmy'); no Dart date math.
  String _formatDate(String iso) =>
      DateLabels.instance.label(iso, DateStyle.dmy) ?? '';
}
