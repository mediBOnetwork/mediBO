import 'dart:convert';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:pharma_b2b/utils/toast.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../util.dart';
import '../utils/download_bytes.dart';
import '../utils/order_code.dart';
import '../utils/render_log.dart';
import '../widgets/animations.dart';

// ─── Data models ─────────────────────────────────────────────────────────────

class _DbOrder {
  final String id;
  final String number;  // payment_id (PO-YYMMDD-XXXX); falls back to '—'
  final DateTime placedAt;
  final List<_DbLine> lines;
  final double total;
  final String status; // DB value capitalized: Pending / Confirmed / etc.
  final bool placedByAdmin;

  _DbOrder({
    required this.id,
    required this.number,
    required this.placedAt,
    required this.lines,
    required this.total,
    required this.status,
    this.placedByAdmin = false,
  });

  factory _DbOrder.fromRow(Map<String, dynamic> row) {
    final id = row['id'] as String;
    final items = (row['items'] as List<dynamic>?) ?? [];
    final rawStatus = ((row['status'] as String?) ?? 'pending').trim();
    final status = rawStatus.isNotEmpty
        ? rawStatus[0].toUpperCase() + rawStatus.substring(1)
        : 'Pending';
    return _DbOrder(
      id: id,
      number: orderDisplayId(row),
      placedAt: DateTime.parse(row['created_at'] as String).toLocal(),
      lines: items
          .map((item) => _DbLine.fromJson(item as Map<String, dynamic>))
          .toList(),
      total: (row['total_amount'] as num?)?.toDouble() ?? 0.0,
      status: status,
      placedByAdmin: (row['placed_by_admin'] as bool?) ?? false,
    );
  }

  int get itemCount => lines.fold(0, (s, l) => s + l.quantity);
}

class _DbLine {
  final String name;
  final double price;
  final int quantity;
  final double lineTotal;

  const _DbLine({
    required this.name,
    required this.price,
    required this.quantity,
    required this.lineTotal,
  });

  factory _DbLine.fromJson(Map<String, dynamic> j) {
    final price = (j['price'] as num?)?.toDouble() ?? 0.0;
    final qty = (j['quantity'] as num?)?.toInt() ?? 1;
    return _DbLine(
      name: (j['product_name'] as String?) ?? '',
      price: price,
      quantity: qty,
      lineTotal: (j['line_total'] as num?)?.toDouble() ?? price * qty,
    );
  }
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class OrdersScreen extends StatefulWidget {
  // When set (View As Customer), fetch orders for this user_id instead of currentUser.
  final String? viewAsUserId;
  // Increment to force a re-fetch (used after write-as order placement).
  final int refreshSignal;
  const OrdersScreen({super.key, this.viewAsUserId, this.refreshSignal = 0});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<_DbOrder> _orders = [];
  bool _loading = true;
  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _fetch();
    _subscribeRealtime();
  }

  @override
  void didUpdateWidget(OrdersScreen old) {
    super.didUpdateWidget(old);
    if (widget.refreshSignal != old.refreshSignal ||
        widget.viewAsUserId != old.viewAsUserId) {
      _fetch();
    }
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      // viewAsUserId is set when super-admin is previewing a customer's orders.
      final uid = widget.viewAsUserId
          ?? Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final rows = await Supabase.instance.client
          .from('orders')
          .select()
          .eq('user_id', uid)
          .order('created_at', ascending: false);
      if (!mounted) return;
      final parsed = rows.map((r) => _DbOrder.fromRow(r)).toList();
      RenderLog.write('orders_fetched',
          'count:${parsed.length}${widget.viewAsUserId != null ? ':viewas' : ''}');
      setState(() {
        _orders = parsed;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _subscribeRealtime() {
    if (widget.viewAsUserId != null) return; // no realtime in view-as mode
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    _channel = Supabase.instance.client
        .channel('customer_orders_$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'user_id',
            value: uid,
          ),
          callback: (_) => _fetch(),
        )
        .subscribe();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_orders.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.receipt_long_outlined,
                size: 64, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            const Text('No purchase orders yet'),
            const SizedBox(height: 4),
            Text('Placed orders will appear here.',
                style: TextStyle(color: Theme.of(context).hintColor)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        physics: platformScrollPhysics(),
        itemCount: _orders.length,
        itemBuilder: (context, i) => _OrderCard(order: _orders[i]),
      ),
    );
  }
}

// ─── Order card ───────────────────────────────────────────────────────────────
// CHANGE #446 — expands into an Items / Bill / Payment accordion, backed by
// ONE call to cust_order_panel(order_id). The frontend only displays strings
// the RPC returns and sends user input to RPCs — no currency/date/percent formatting here.

class _OrderCard extends StatefulWidget {
  final _DbOrder order;
  const _OrderCard({required this.order});

  @override
  State<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<_OrderCard> {
  Map<String, dynamic>? _panel;
  bool _loading = false;
  String? _error;
  int _tab = 0; // 0=Items 1=Bill 2=Payment

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}  '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  Future<void> _loadPanel() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('cust_order_panel', params: {'p_order_id': widget.order.id});
      final panel = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      final items = (panel['items'] as List?) ?? [];
      final bill = Map<String, dynamic>.from(panel['bill'] as Map? ?? {});
      final payment = Map<String, dynamic>.from(panel['payment'] as Map? ?? {});
      final advance = Map<String, dynamic>.from(payment['advance'] as Map? ?? {});
      final upi = Map<String, dynamic>.from(payment['upi'] as Map? ?? {});
      RenderLog.write('c446_expanded', 1);
      RenderLog.write('c446_items', items.length);
      if (items.isNotEmpty) {
        final first = Map<String, dynamic>.from(items.first as Map);
        RenderLog.write('c446_first_item', first['name']?.toString() ?? '');
        RenderLog.write('c446_first_qty', first['qty_label']?.toString() ?? '');
      }
      RenderLog.write('c446_bill_ready', bill['ready'] == true);
      RenderLog.write('c446_bill_reason', bill['reason_label']?.toString() ?? '');
      RenderLog.write('c446_advance_label', advance['expected_label']?.toString() ?? '');
      RenderLog.write('c446_upi_present', (upi['vpa'] != null) ? 1 : 0);
      setState(() {
        _panel = panel;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not load order details.';
          _loading = false;
        });
      }
    }
  }

  void _onPanelUpdated(Map<String, dynamic> newPanel) {
    setState(() => _panel = newPanel);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final order = widget.order;
    return Card(
      child: ExpansionTile(
        onExpansionChanged: (expanded) {
          if (expanded && _panel == null && !_loading) _loadPanel();
        },
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.receipt_long,
              color: theme.colorScheme.onPrimaryContainer),
        ),
        // Primary label: human-readable PO number (payment_id)
        title: Text(order.number,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${_date(order.placedAt)} · ${order.itemCount} packs'),
            if (order.placedByAdmin) ...[
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('Placed by admin',
                    style: TextStyle(
                        fontSize: 10,
                        color: Color(0xFF92400E),
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(rupees(order.total),
                style: const TextStyle(fontWeight: FontWeight.bold)),
            _StatusChip(status: order.status),
          ],
        ),
        children: [_buildExpandedBody()],
      ),
    );
  }

  Widget _buildExpandedBody() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(_error!, style: const TextStyle(color: Colors.red)),
      );
    }
    final panel = _panel;
    if (panel == null) return const SizedBox.shrink();
    final header = Map<String, dynamic>.from(panel['header'] as Map? ?? {});
    final items = ((panel['items'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final bill = Map<String, dynamic>.from(panel['bill'] as Map? ?? {});
    final payment = Map<String, dynamic>.from(panel['payment'] as Map? ?? {});

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // B2 — header.* printed fresh from the response, not reused locals.
        Wrap(spacing: 12, runSpacing: 4, children: [
          if (header['date_label'] != null) Text(header['date_label'].toString()),
          if (header['packs_label'] != null) Text(header['packs_label'].toString()),
          if (header['amount_label'] != null)
            Text(header['amount_label'].toString(),
                style: const TextStyle(fontWeight: FontWeight.bold)),
          if (header['status_label'] != null) _StatusChip(status: header['status_label'].toString()),
        ]),
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _SegmentChip(label: 'Items', selected: _tab == 0, onTap: () => setState(() => _tab = 0)),
            const SizedBox(width: 6),
            _SegmentChip(label: 'Bill', selected: _tab == 1, onTap: () => setState(() => _tab = 1)),
            const SizedBox(width: 6),
            _SegmentChip(label: 'Payment', selected: _tab == 2, onTap: () => setState(() => _tab = 2)),
          ]),
        ),
        const SizedBox(height: 12),
        if (_tab == 0) _ItemsTab(items: items),
        if (_tab == 1)
          _BillTab(bill: bill, orderId: (header['order_id'] ?? widget.order.id).toString()),
        if (_tab == 2)
          _PaymentTab(
            orderId: (header['order_id'] ?? widget.order.id).toString(),
            payment: payment,
            onPanelUpdated: _onPanelUpdated,
          ),
      ]),
    );
  }
}

// ─── Segment chip (Items/Bill/Payment, and Payment's All/Advance/Balance) ──────

class _SegmentChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SegmentChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1B7A43) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : const Color(0xFF374151))),
      ),
    );
  }
}

// ─── Items tab ──────────────────────────────────────────────────────────────

class _ItemsTab extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  const _ItemsTab({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('No items.', style: TextStyle(color: Color(0xFF9CA3AF))),
      );
    }
    return Column(children: items.map((it) => _itemRow(it)).toList());
  }

  Widget _itemRow(Map<String, dynamic> it) {
    final imageUrl = it['image_url']?.toString();
    final name = it['name']?.toString() ?? '';
    final company = it['company']?.toString();
    final packLabel = it['pack_label']?.toString();
    final qtyLabel = it['qty_label']?.toString();
    final rateLabel = it['rate_label']?.toString();
    final lineLabel = it['line_label']?.toString();
    final statusLabel = it['status_label']?.toString();
    final statusOk = it['status_ok'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _itemPhoto(imageUrl),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            if (company != null && company.isNotEmpty)
              Text(company,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
            if (packLabel != null && packLabel.isNotEmpty)
              Text(packLabel,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
            const SizedBox(height: 6),
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 4, children: [
              if (qtyLabel != null && qtyLabel.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(6)),
                  child: Text(qtyLabel, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                ),
              if (rateLabel != null && rateLabel.isNotEmpty)
                Text(rateLabel, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              if (lineLabel != null && lineLabel.isNotEmpty)
                Text(lineLabel, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              if (statusLabel != null && statusLabel.isNotEmpty) _itemStatusChip(statusLabel, statusOk),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _itemPhoto(String? url) {
    const size = 56.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size, height: size,
        child: (url == null || url.isEmpty)
            ? Container(
                color: const Color(0xFFF3F4F6),
                alignment: Alignment.center,
                child: const Icon(Icons.medication_outlined, size: 24, color: Color(0xFFD1D5DB)),
              )
            : Image.network(
                url,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: 112,
                loadingBuilder: (_, child, prog) => prog == null
                    ? child
                    : Container(
                        color: const Color(0xFFF3F4F6),
                        alignment: Alignment.center,
                        child: const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD1D5DB))),
                      ),
                errorBuilder: (_, __, ___) => Container(
                  color: const Color(0xFFF3F4F6),
                  alignment: Alignment.center,
                  child: const Icon(Icons.medication_outlined, size: 24, color: Color(0xFFD1D5DB)),
                ),
              ),
      ),
    );
  }

  Widget _itemStatusChip(String label, bool ok) {
    final color = ok ? const Color(0xFF16A34A) : const Color(0xFFD97706);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

// ─── Bill tab ───────────────────────────────────────────────────────────────

// CHANGE #451 — schema-driven GST invoice table. Every string on screen comes
// straight from cust_order_panel().bill; nothing is formatted or computed here.
class _BillTab extends StatelessWidget {
  final Map<String, dynamic> bill;
  final String orderId;
  const _BillTab({required this.bill, required this.orderId});

  @override
  Widget build(BuildContext context) {
    final ready = bill['ready'] == true;
    RenderLog.write('c451_bill_ready', ready);

    if (!ready) {
      final message = bill['message']?.toString() ?? '';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(children: [
          const Icon(Icons.receipt_long_outlined, size: 48, color: Color(0xFFD1D5DB)),
          const SizedBox(height: 12),
          Text(message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        ]),
      );
    }

    final invoice = Map<String, dynamic>.from(bill['invoice'] as Map? ?? {});
    final columns = ((bill['columns'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final lines = ((bill['lines'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final totals = Map<String, dynamic>.from(bill['totals'] as Map? ?? {});
    final gstSummary = ((bill['gst_summary'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final seller = Map<String, dynamic>.from(invoice['seller'] as Map? ?? {});
    final buyer = Map<String, dynamic>.from(invoice['buyer'] as Map? ?? {});
    final sellerWarning = seller['warning']?.toString();

    RenderLog.write('c451_cols', columns.length);
    RenderLog.write('c451_rows', lines.length);
    RenderLog.write('c451_net', totals['net_payable_label']?.toString() ?? '');
    RenderLog.write('c451_remaining', totals['remaining_label']?.toString() ?? '');
    RenderLog.write('c451_seller_warning', (sellerWarning != null && sellerWarning.isNotEmpty) ? 1 : 0);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _invoiceHeader(invoice, seller, buyer, sellerWarning),
      const SizedBox(height: 14),
      _invoiceTable(columns, lines),
      const SizedBox(height: 16),
      _totalsBlock(totals),
      if (gstSummary.isNotEmpty) ...[
        const SizedBox(height: 16),
        _gstSummaryTable(gstSummary),
      ],
      const SizedBox(height: 16),
      _DownloadBillButton(orderId: orderId, invoiceNumber: invoice['number']?.toString()),
    ]);
  }

  // ── B2: invoice header ──────────────────────────────────────────────────

  Widget _invoiceHeader(
    Map<String, dynamic> invoice,
    Map<String, dynamic> seller,
    Map<String, dynamic> buyer,
    String? sellerWarning,
  ) {
    final sellerLine = [seller['address'], seller['state']]
        .where((e) => e != null && e.toString().isNotEmpty)
        .toList();
    final sellerMeta = <String>[
      if (seller['gstin'] != null && seller['gstin'].toString().isNotEmpty) 'GSTIN: ${seller['gstin']}',
      if (seller['dl'] != null && seller['dl'].toString().isNotEmpty) 'DL: ${seller['dl']}',
    ];
    final buyerLine = [buyer['address'], buyer['phone']]
        .where((e) => e != null && e.toString().isNotEmpty)
        .toList();
    final buyerMeta = <String>[
      if (buyer['gstin'] != null && buyer['gstin'].toString().isNotEmpty) 'GSTIN: ${buyer['gstin']}',
      if (buyer['dl'] != null && buyer['dl'].toString().isNotEmpty) 'DL: ${buyer['dl']}',
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('TAX INVOICE', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          ),
          if (invoice['number'] != null)
            Text(invoice['number'].toString(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(seller['name']?.toString() ?? '',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
          ),
          if (invoice['date'] != null)
            Text('Date: ${invoice['date']}', style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
        ]),
        if (sellerLine.isNotEmpty || sellerMeta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text([...sellerLine, ...sellerMeta].join(' | '),
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          ),
        if (sellerWarning != null && sellerWarning.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFFCA5A5))),
            child: Text(sellerWarning, style: const TextStyle(fontSize: 11.5, color: Color(0xFFB91C1C), fontWeight: FontWeight.w600)),
          ),
        ],
        const SizedBox(height: 10),
        if (buyer['name'] != null)
          Text('Billed to: ${buyer['name']}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
        if (buyerLine.isNotEmpty || buyerMeta.isNotEmpty)
          Text([...buyerLine, ...buyerMeta].join(' | '), style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
      ]),
    );
  }

  // ── B3: the table ────────────────────────────────────────────────────────

  Widget _invoiceTable(List<Map<String, dynamic>> columns, List<Map<String, dynamic>> lines) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        border: TableBorder.all(color: const Color(0xFFE5E7EB), width: 0.5),
        headingRowColor: const WidgetStatePropertyAll(Color(0xFFF3F4F6)),
        headingTextStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF374151)),
        dataTextStyle: const TextStyle(fontSize: 11.5, color: Color(0xFF374151)),
        columnSpacing: 18,
        horizontalMargin: 10,
        columns: columns
            .map((c) => DataColumn(
                  label: Text(c['label']?.toString() ?? ''),
                  numeric: c['align'] == 'right',
                ))
            .toList(),
        rows: List<DataRow>.generate(lines.length, (i) {
          final line = lines[i];
          return DataRow(
            color: WidgetStatePropertyAll(i.isOdd ? const Color(0xFFFAFAFA) : Colors.white),
            cells: columns.map((c) {
              final key = c['key']?.toString() ?? '';
              final value = line[key]?.toString() ?? '';
              if (key == 'product') {
                final company = line['company']?.toString();
                return DataCell(Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(value),
                    if (company != null && company.isNotEmpty)
                      Text(company, style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
                  ],
                ));
              }
              return DataCell(Text(value));
            }).toList(),
          );
        }),
      ),
    );
  }

  // ── B4: totals block ────────────────────────────────────────────────────

  Widget _totalsBlock(Map<String, dynamic> totals) {
    Widget row(String label, dynamic value, {bool bold = false, double size = 12.5}) {
      if (value == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          Text(label, style: TextStyle(fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.normal, color: const Color(0xFF6B7280))),
          const SizedBox(width: 16),
          SizedBox(
            width: 130,
            child: Text(value.toString(),
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w600, color: const Color(0xFF111827))),
          ),
        ]),
      );
    }

    final youSaveLabel = totals['you_save_label']?.toString();
    final inWords = totals['in_words']?.toString();

    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      row('PTR Total', totals['ptr_total_label']),
      row(totals['discount_label']?.toString() ?? 'Discount', totals['discount_amount_label']),
      row('Net Taxable', totals['taxable_label'], bold: true),
      row('CGST', totals['cgst_label']),
      row('SGST', totals['sgst_label']),
      row('Round Off', totals['round_off_label']),
      const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1)),
      row('NET PAYABLE', totals['net_payable_label'], bold: true, size: 15),
      row('Less: Advance paid', totals['paid_label']),
      row('BALANCE DUE', totals['remaining_label'], bold: true, size: 15),
      if (inWords != null && inWords.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Amount in words: $inWords',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Color(0xFF6B7280))),
      ],
      if (youSaveLabel != null && youSaveLabel.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(youSaveLabel, style: const TextStyle(fontSize: 11.5, color: Color(0xFF16A34A), fontWeight: FontWeight.w600)),
      ],
    ]);
  }

  // ── B5: GST summary ─────────────────────────────────────────────────────

  Widget _gstSummaryTable(List<Map<String, dynamic>> gstSummary) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        border: TableBorder.all(color: const Color(0xFFE5E7EB), width: 0.5),
        headingRowColor: const WidgetStatePropertyAll(Color(0xFFF3F4F6)),
        headingTextStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF374151)),
        dataTextStyle: const TextStyle(fontSize: 11.5, color: Color(0xFF374151)),
        columnSpacing: 18,
        horizontalMargin: 10,
        columns: const [
          DataColumn(label: Text('Rate')),
          DataColumn(label: Text('Taxable'), numeric: true),
          DataColumn(label: Text('CGST'), numeric: true),
          DataColumn(label: Text('SGST'), numeric: true),
          DataColumn(label: Text('Total'), numeric: true),
        ],
        rows: gstSummary
            .map((g) => DataRow(cells: [
                  DataCell(Text(g['rate']?.toString() ?? '')),
                  DataCell(Text(g['taxable']?.toString() ?? '')),
                  DataCell(Text(g['cgst']?.toString() ?? '')),
                  DataCell(Text(g['sgst']?.toString() ?? '')),
                  DataCell(Text(g['total']?.toString() ?? '')),
                ]))
            .toList(),
      ),
    );
  }
}

// ── B6: Download Bill (PDF) ──────────────────────────────────────────────────

class _DownloadBillButton extends StatefulWidget {
  final String orderId;
  final String? invoiceNumber;
  const _DownloadBillButton({required this.orderId, required this.invoiceNumber});

  @override
  State<_DownloadBillButton> createState() => _DownloadBillButtonState();
}

class _DownloadBillButtonState extends State<_DownloadBillButton> {
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c451_pdf_wired', 1);
  }

  String _filenameFrom(http.Response resp) {
    final cd = resp.headers['content-disposition'];
    if (cd != null) {
      final m = RegExp(r'filename="?([^";]+)"?').firstMatch(cd);
      if (m != null) return m.group(1)!;
    }
    return 'Invoice-${widget.invoiceNumber ?? widget.orderId}.pdf';
  }

  Future<void> _download() async {
    if (_downloading) return;
    setState(() => _downloading = true);
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken ?? '';
      final resp = await http.post(
        Uri.parse('https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-pdf'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'order_id': widget.orderId}),
      );
      if (!mounted) return;
      if (resp.statusCode == 200) {
        downloadBytes(resp.bodyBytes, _filenameFrom(resp), 'application/pdf');
      } else {
        String message = 'Could not download the bill.';
        try {
          final decoded = jsonDecode(resp.body);
          if (decoded is Map) {
            message = decoded['message']?.toString() ?? decoded['error']?.toString() ?? message;
          }
        } catch (_) {}
        showToast(context, message, isError: true);
      }
    } catch (_) {
      if (mounted) showToast(context, 'Could not download the bill.', isError: true);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _downloading ? null : _download,
        icon: _downloading
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.download_outlined, size: 16),
        label: Text(_downloading ? 'Downloading…' : 'Download Bill (PDF)'),
      ),
    );
  }
}

// ─── Payment tab ──────────────────────────────────────────────────────────────

class _PaymentTab extends StatefulWidget {
  final String orderId;
  final Map<String, dynamic> payment;
  final ValueChanged<Map<String, dynamic>> onPanelUpdated;
  const _PaymentTab({required this.orderId, required this.payment, required this.onPanelUpdated});

  @override
  State<_PaymentTab> createState() => _PaymentTabState();
}

class _PaymentTabState extends State<_PaymentTab> {
  int _subTab = 0; // 0=All 1=Advance 2=Balance
  bool _advancePanelOpen = false;
  bool _restPanelOpen = false;

  Future<void> _openUploadSheet(num prefillAmount) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _PaymentUploadSheet(
        orderId: widget.orderId,
        prefillAmount: prefillAmount,
        onSuccess: (panel, message) {
          if (mounted) showToast(context, message);
          widget.onPanelUpdated(panel);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final payment = widget.payment;
    final totalLabel = payment['total_label']?.toString() ?? '';
    final paidLabel = payment['paid_label']?.toString() ?? '';
    final dueLabel = payment['due_label']?.toString() ?? '';
    final upi = Map<String, dynamic>.from(payment['upi'] as Map? ?? {});
    final payments = ((payment['payments'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Expanded(child: _statLine('Total', totalLabel)),
          Expanded(child: _statLine('Paid', paidLabel)),
          Expanded(child: _statLine('Due', dueLabel)),
        ]),
      ),
      const SizedBox(height: 12),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _SegmentChip(label: 'All', selected: _subTab == 0, onTap: () => setState(() => _subTab = 0)),
          const SizedBox(width: 6),
          _SegmentChip(label: 'Advance', selected: _subTab == 1, onTap: () => setState(() => _subTab = 1)),
          const SizedBox(width: 6),
          _SegmentChip(label: 'Balance', selected: _subTab == 2, onTap: () => setState(() => _subTab = 2)),
        ]),
      ),
      const SizedBox(height: 12),
      if (_subTab == 0) _buildAllTab(payments),
      if (_subTab == 1)
        _buildPaySection(
          Map<String, dynamic>.from(payment['advance'] as Map? ?? {}),
          'Advance',
          upi,
          upi['link_advance']?.toString(),
          _advancePanelOpen,
          () => setState(() => _advancePanelOpen = !_advancePanelOpen),
        ),
      if (_subTab == 2)
        _buildPaySection(
          Map<String, dynamic>.from(payment['rest'] as Map? ?? {}),
          'Balance',
          upi,
          upi['link_rest']?.toString(),
          _restPanelOpen,
          () => setState(() => _restPanelOpen = !_restPanelOpen),
        ),
    ]);
  }

  Widget _statLine(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10.5, color: Color(0xFF9CA3AF))),
      Text(value,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
    ]);
  }

  Widget _buildPaySection(
    Map<String, dynamic> section,
    String kind,
    Map<String, dynamic> upi,
    String? link,
    bool panelOpen,
    VoidCallback togglePanel,
  ) {
    final expectedLabel = section['expected_label']?.toString() ?? '';
    final receivedLabel = section['received_label']?.toString() ?? '';
    final remainingLabel = section['remaining_label']?.toString() ?? '';
    final fullyPaid = section['fully_paid'] == true;
    final payLabel = section['pay_label']?.toString() ?? 'Pay';
    final locked = section['locked'] == true;
    final lockedLabel = section['locked_label']?.toString();
    final remaining = section['remaining'];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _kvRow('Expected', expectedLabel),
      _kvRow('Received', receivedLabel),
      _kvRow('Remaining', remainingLabel),
      if (locked && lockedLabel != null && lockedLabel.isNotEmpty) ...[
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(8)),
          child: Text(lockedLabel, style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
        ),
      ],
      const SizedBox(height: 12),
      if (fullyPaid)
        Row(children: [
          const Icon(Icons.check_circle, size: 16, color: Color(0xFF16A34A)),
          const SizedBox(width: 6),
          Text('$kind paid in full', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF16A34A))),
        ])
      else ...[
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: togglePanel,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: Text(payLabel, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
          ),
        ),
        if (panelOpen) ...[
          const SizedBox(height: 14),
          if (upi['vpa'] == null)
            const Text('Payment is being set up. Please contact us.',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)))
          else ...[
            Center(
              child: link == null || link.isEmpty
                  ? const Text('QR unavailable.', style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)))
                  : Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE5E7EB)), borderRadius: BorderRadius.circular(12)),
                      child: QrImageView(
                        data: link,
                        version: QrVersions.auto,
                        size: 180,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                      ),
                    ),
            ),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(upi['vpa']?.toString() ?? '', style: const TextStyle(fontSize: 12.5, color: Color(0xFF374151))),
              IconButton(
                iconSize: 16,
                icon: const Icon(Icons.copy),
                onPressed: () => Clipboard.setData(ClipboardData(text: upi['vpa']?.toString() ?? '')),
              ),
            ]),
            if (upi['payee'] != null)
              Center(
                child: Text(upi['payee'].toString(),
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
              ),
            const SizedBox(height: 10),
            if (link != null && link.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.qr_code_2, size: 16),
                label: const Text('Pay in UPI app'),
              ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => _openUploadSheet((remaining as num?) ?? 0),
                child: const Text("I've paid — upload screenshot"),
              ),
            ),
          ],
        ],
      ],
    ]);
  }

  Widget _kvRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(children: [
        SizedBox(width: 80, child: Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)))),
      ]),
    );
  }

  Widget _buildAllTab(List<Map<String, dynamic>> payments) {
    if (payments.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('No payments yet.', style: TextStyle(color: Color(0xFF9CA3AF))),
      );
    }
    return Column(children: payments.map((p) => _paymentRow(p)).toList());
  }

  Widget _paymentRow(Map<String, dynamic> p) {
    final whenLabel = p['when_label']?.toString() ?? '';
    final amountLabel = p['amount_label']?.toString() ?? '';
    final methodLabel = p['method_label']?.toString() ?? '';
    final statusLabel = p['status_label']?.toString() ?? '';
    final utr = p['utr']?.toString();
    final reason = p['reason']?.toString();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: const Color(0xFFFAFAFA), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE5E7EB))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(amountLabel, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700))),
          _paymentStatusChip(statusLabel),
        ]),
        const SizedBox(height: 4),
        Wrap(spacing: 10, runSpacing: 4, children: [
          Text(whenLabel, style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          if (methodLabel.isNotEmpty) Text(methodLabel, style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          if (utr != null && utr.isNotEmpty) Text('UTR: $utr', style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
        ]),
        if (reason != null && reason.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(reason, style: const TextStyle(fontSize: 11.5, color: Color(0xFFDC2626))),
        ],
      ]),
    );
  }

  Widget _paymentStatusChip(String label) {
    final lower = label.toLowerCase();
    final color = switch (lower) {
      'approved' => const Color(0xFF16A34A),
      'under review' => const Color(0xFFD97706),
      'rejected' || 'duplicate' => const Color(0xFFDC2626),
      _ => const Color(0xFF6B7280),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

// ─── Upload screenshot sheet (Part E4) ─────────────────────────────────────────

class _PaymentUploadSheet extends StatefulWidget {
  final String orderId;
  final num prefillAmount;
  final void Function(Map<String, dynamic> panel, String message) onSuccess;
  const _PaymentUploadSheet({required this.orderId, required this.prefillAmount, required this.onSuccess});

  @override
  State<_PaymentUploadSheet> createState() => _PaymentUploadSheetState();
}

class _PaymentUploadSheetState extends State<_PaymentUploadSheet> {
  late final TextEditingController _amountCtrl =
      TextEditingController(text: widget.prefillAmount.toString());
  final TextEditingController _utrCtrl = TextEditingController();
  Uint8List? _pickedBytes;
  String? _pickedExt;
  String? _pickedFileName;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _utrCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp'],
        allowMultiple: false,
        withData: true,
      );
    } catch (_) {}
    if (picked == null || picked.files.isEmpty) return;
    final pf = picked.files.first;
    if (pf.bytes == null) return;
    setState(() {
      _pickedBytes = pf.bytes;
      _pickedExt = (pf.extension ?? 'jpg').toLowerCase();
      _pickedFileName = pf.name;
      _error = null;
    });
  }

  Future<void> _submit() async {
    final amount = num.tryParse(_amountCtrl.text.trim());
    if (amount == null) {
      setState(() => _error = 'Enter the amount you paid.');
      return;
    }
    if (_pickedBytes == null) {
      setState(() => _error = 'Upload the payment screenshot so we can verify it.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });

    final ext = _pickedExt ?? 'jpg';
    final token = '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(999999)}';
    final path = '${widget.orderId}/$token.$ext';
    final contentType = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
            ? 'image/webp'
            : 'image/jpeg';

    try {
      await Supabase.instance.client.storage.from('order-uploads').uploadBinary(
            path,
            _pickedBytes!,
            fileOptions: FileOptions(contentType: contentType),
          );
    } catch (_) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Screenshot upload failed. Try again.';
        });
      }
      return;
    }

    try {
      final res = await Supabase.instance.client.rpc('cust_submit_payment', params: {
        'p_order_id': widget.orderId,
        'p_amount': amount,
        'p_screenshot_path': path,
        'p_utr': _utrCtrl.text.trim().isEmpty ? null : _utrCtrl.text.trim(),
        'p_app': null,
        'p_ocr': null,
      });
      final result = Map<String, dynamic>.from(res as Map);
      if (result['ok'] == true) {
        final panel = Map<String, dynamic>.from(result['panel'] as Map);
        final message = result['message']?.toString() ?? 'Payment submitted.';
        if (mounted) Navigator.of(context).pop();
        widget.onSuccess(panel, message);
      } else {
        if (mounted) {
          setState(() {
            _submitting = false;
            _error = result['message']?.toString() ?? 'Could not submit payment.';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = 'Could not submit payment.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16, right: 16, top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Upload payment proof', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        TextField(
          controller: _amountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Amount paid', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _utrCtrl,
          decoration: const InputDecoration(labelText: 'UTR / reference (optional)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _pickFile,
          icon: const Icon(Icons.photo_camera_outlined, size: 16),
          label: Text(_pickedFileName == null ? 'Take photo / Choose screenshot' : 'Selected: $_pickedFileName'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _submitting ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: _submitting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Submit'),
          ),
        ),
      ]),
    );
  }
}

// ─── Status chip ──────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final lower = status.toLowerCase();
    final color = switch (lower) {
      'accepted' || 'confirmed' => Colors.green,
      'cancelled' || 'rejected' => Colors.red,
      _ => Colors.orange, // pending, processing, etc.
    };
    final label = switch (lower) {
      'accepted' || 'confirmed' => 'Accepted',
      'cancelled' => 'Cancelled',
      'rejected' => 'Rejected',
      'pending' => 'Pending',
      _ => status[0].toUpperCase() + status.substring(1),
    };
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
