import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../bulk_upload_screen.dart';

// ── Models ─────────────────────────────────────────────────────────────────────

class _ItemLine {
  final String name;
  final int qty;
  final double? price;
  const _ItemLine({required this.name, required this.qty, this.price});
}

class _CustRow {
  final String userId;
  final String name;
  final String pharmacy;
  final String phone;
  // 'website' | 'whatsapp' | 'cart_only'
  // Derived from orders.source when that column exists; defaults to 'website'.
  final String source;
  final String? orderId;
  final String orderStatus; // 'paid'|'confirmed'|'rejected'|'pending'|'cart_only'
  final List<_ItemLine> items;
  final double? total;

  const _CustRow({
    required this.userId,
    required this.name,
    required this.pharmacy,
    required this.phone,
    required this.source,
    this.orderId,
    required this.orderStatus,
    required this.items,
    this.total,
  });

  bool get isOrder => source == 'website' || source == 'whatsapp';
  bool get isCartOnly => source == 'cart_only';
}

// Two views only
enum _CustFilter { customerOrders, cartNotOrdered }

// ── Screen ────────────────────────────────────────────────────────────────────

class AdminCustomerScreen extends StatefulWidget {
  const AdminCustomerScreen({super.key});

  @override
  State<AdminCustomerScreen> createState() => _AdminCustomerScreenState();
}

class _AdminCustomerScreenState extends State<AdminCustomerScreen> {
  // All rows in memory; filtered on render
  List<_CustRow> _orderRows = [];
  List<_CustRow> _cartRows = [];
  bool _loading = true;
  _CustFilter _filter = _CustFilter.customerOrders;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── Data ──────────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait<dynamic>([
        client.from('user_profiles').select(),
        client.from('pharmacy_profiles').select(),
        client.from('orders').select().order('created_at', ascending: false),
        client.from('cart_items').select('user_id, product_name, quantity, price'),
      ]);

      final upRows        = results[0] as List;
      final ppRows        = results[1] as List;
      final orderRows     = results[2] as List;
      final cartRows      = results[3] as List;

      // Build lookups keyed by user_id / auth uid
      final upMap  = <String, Map<String, dynamic>>{};
      for (final p in upRows) {
        final m = Map<String, dynamic>.from(p as Map);
        upMap[m['id'] as String] = m;
      }
      final ppMap  = <String, Map<String, dynamic>>{};
      for (final p in ppRows) {
        final m = Map<String, dynamic>.from(p as Map);
        ppMap[m['user_id'] as String] = m;
      }

      // cart_items grouped by user_id
      final cartByUser = <String, List<Map<String, dynamic>>>{};
      for (final ci in cartRows) {
        final m = Map<String, dynamic>.from(ci as Map);
        (cartByUser[m['user_id'] as String] ??= []).add(m);
      }

      final orders = <_CustRow>[];
      for (final o in orderRows) {
        final mo  = Map<String, dynamic>.from(o as Map);
        final uid = mo['user_id'] as String? ?? '';
        final up  = upMap[uid];
        final pp  = ppMap[uid];
        // Read source column when it exists; fall back to 'website'
        final src = mo['source'] as String? ?? 'website';
        orders.add(_CustRow(
          userId:      uid,
          name:        _name(up, pp, mo),
          pharmacy:    _pharmacy(up, pp, mo),
          phone:       _phone(up, pp, mo),
          source:      src,
          orderId:     mo['id'] as String?,
          orderStatus: mo['status'] as String? ?? 'unknown',
          items:       _parseItems(mo['items']),
          total:       (mo['total_amount'] as num?)?.toDouble(),
        ));
      }

      // Cart-only: users with cart but no orders
      final orderedUids = {for (final o in orderRows) (o as Map)['user_id'] as String? ?? ''};
      final carts = <_CustRow>[];
      for (final entry in cartByUser.entries) {
        if (orderedUids.contains(entry.key)) continue;
        final uid = entry.key;
        final up  = upMap[uid];
        final pp  = ppMap[uid];
        carts.add(_CustRow(
          userId:      uid,
          name:        _name(up, pp, null),
          pharmacy:    _pharmacy(up, pp, null),
          phone:       _phone(up, pp, null),
          source:      'cart_only',
          orderId:     null,
          orderStatus: 'cart_only',
          items: entry.value
              .map((ci) => _ItemLine(
                    name:  ci['product_name'] as String? ?? '',
                    qty:   (ci['quantity'] as num?)?.toInt() ?? 1,
                    price: (ci['price'] as num?)?.toDouble(),
                  ))
              .where((i) => i.name.isNotEmpty)
              .toList(),
          total: null,
        ));
      }

      if (mounted) {
        setState(() {
          _orderRows = orders;
          _cartRows  = carts;
          _loading   = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to load customers: $e'),
          backgroundColor: const Color(0xFFDC2626),
        ));
      }
    }
  }

  static String _name(Map? up, Map? pp, Map? order) {
    final n = (up?['full_name'] ?? pp?['owner_name']) as String?;
    if (n != null && n.trim().isNotEmpty) return n.trim();
    return order?['pharmacy_name'] as String? ?? 'Unknown';
  }

  static String _pharmacy(Map? up, Map? pp, Map? order) {
    final biz = (up?['business_name'] ?? pp?['pharmacy_name']) as String?;
    if (biz != null && biz.trim().isNotEmpty) return biz.trim();
    return order?['pharmacy_name'] as String? ?? '';
  }

  static String _phone(Map? up, Map? pp, Map? order) {
    final ph = (up?['phone'] ?? pp?['phone']) as String?;
    if (ph != null && ph.trim().isNotEmpty) return ph.trim();
    return order?['phone'] as String? ?? '';
  }

  static List<_ItemLine> _parseItems(dynamic items) {
    if (items == null) return [];
    try {
      return (items as List)
          .map((e) {
            final m = Map<String, dynamic>.from(e as Map);
            return _ItemLine(
              name:  m['product_name'] as String? ?? '',
              qty:   (m['quantity'] as num?)?.toInt() ?? 1,
              price: (m['price'] as num?)?.toDouble(),
            );
          })
          .where((i) => i.name.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Active list ───────────────────────────────────────────────────────────────

  List<_CustRow> get _active =>
      _filter == _CustFilter.customerOrders ? _orderRows : _cartRows;

  // ── Actions ───────────────────────────────────────────────────────────────────

  Future<void> _updateStatus(String orderId, String status) async {
    try {
      await Supabase.instance.client
          .from('orders')
          .update({'status': status})
          .eq('id', orderId);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Update failed: $e'),
          backgroundColor: const Color(0xFFDC2626),
        ));
      }
    }
  }

  void _openImport(_CustRow row) {
    final items = row.items.map((i) => (name: i.name, qty: i.qty)).toList();
    final title = row.pharmacy.isNotEmpty ? row.pharmacy : row.name;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BulkUploadScreen(
          preloadedItems: items,
          preloadedTitle: '$title — Order',
        ),
      ),
    );
  }

  void _toggleExpand(String key) => setState(
      () => _expanded.contains(key) ? _expanded.remove(key) : _expanded.add(key));

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final isDesktop = box.maxWidth >= 900;
      final rows = _active;

      // Loading and empty states need the header + centred body.
      if (_loading || rows.isEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(isDesktop),
            Expanded(child: _buildBody(rows, isDesktop)),
          ],
        );
      }

      // When rows exist, wrap in SingleChildScrollView so accordion expansions
      // (which can be many items tall) are fully reachable by scrolling.
      // The header stays pinned above the scroll area; the table header and
      // all rows scroll together inside the SingleChildScrollView.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(isDesktop),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isDesktop) _buildTableHeader(),
                  ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 32),
                    itemCount: rows.length,
                    itemBuilder: (_, i) => isDesktop
                        ? _buildDesktopRow(rows[i])
                        : _buildMobileCard(rows[i]),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    });
  }

  // ── Header with filter tabs ───────────────────────────────────────────────────

  Widget _buildHeader(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    return Container(
      padding: EdgeInsets.fromLTRB(pad, 16, pad, 0),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('Customer Dashboard',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827))),
          ),
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_outlined,
                color: Color(0xFF6B7280), size: 20),
            tooltip: 'Refresh',
            visualDensity: VisualDensity.compact,
          ),
        ]),
        const SizedBox(height: 12),
        // Filter tabs
        Row(children: [
          _tab(_CustFilter.customerOrders,
              'Customer Orders (${_orderRows.length})'),
          const SizedBox(width: 4),
          _tab(_CustFilter.cartNotOrdered,
              'Cart — Not Ordered (${_cartRows.length})'),
        ]),
      ]),
    );
  }

  Widget _tab(_CustFilter f, String label) {
    final active = _filter == f;
    return GestureDetector(
      onTap: () => setState(() { _filter = f; _expanded.clear(); }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? const Color(0xFF1B5E20) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? const Color(0xFF1B5E20) : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }

  // ── Desktop table header ──────────────────────────────────────────────────────

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      color: const Color(0xFFF3F4F6),
      child: Row(children: [
        _th('Customer', flex: 3),
        _th('Pharmacy', flex: 3),
        _th('Phone', flex: 2),
        _th('Source', flex: 2),
        _th('Order ID', flex: 2),
        if (_filter == _CustFilter.customerOrders) ...[
          _th('Confirmation', flex: 3),
          _th('Action', flex: 2),
        ],
      ]),
    );
  }

  // ── Body (loading / empty only — list is handled in build) ───────────────────

  Widget _buildBody(List<_CustRow> rows, bool isDesktop) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(
              color: Color(0xFF1B5E20), strokeWidth: 2));
    }
    // rows.isEmpty guaranteed here — list path lives in build() so accordion
    // expansions of any height are fully scrollable via SingleChildScrollView.
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.people_outline, size: 56, color: Color(0xFFD1D5DB)),
        const SizedBox(height: 14),
        Text(
          _filter == _CustFilter.customerOrders
              ? '0 orders'
              : '0 customers with unpurchased cart items',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
        ),
      ]),
    );
  }

  // ── Desktop row ───────────────────────────────────────────────────────────────

  Widget _buildDesktopRow(_CustRow row) {
    final key = row.orderId ?? row.userId;
    final isExpanded = _expanded.contains(key);
    final showOrderCols = _filter == _CustFilter.customerOrders;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: Row(children: [
          Expanded(
            flex: 3,
            child: Text(row.name,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827)),
                overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 3,
            child: Text(row.pharmacy.isNotEmpty ? row.pharmacy : '—',
                style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
                overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 2,
            child: Text(row.phone.isNotEmpty ? row.phone : '—',
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          ),
          Expanded(
            flex: 2,
            child: InkWell(
              onTap: row.items.isNotEmpty ? () => _toggleExpand(key) : null,
              borderRadius: BorderRadius.circular(20),
              child: _SourceBadge(
                  source: row.source,
                  hasItems: row.items.isNotEmpty,
                  isExpanded: isExpanded),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              row.orderId != null
                  ? '#${row.orderId!.substring(0, row.orderId!.length.clamp(0, 8))}'
                  : '—',
              style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF6B7280),
                  fontFamily: 'monospace'),
            ),
          ),
          if (showOrderCols) ...[
            Expanded(
              flex: 3,
              child: _ConfirmActions(row: row, onUpdate: _updateStatus),
            ),
            Expanded(
              flex: 2,
              child: _ActionCell(row: row, onImport: () => _openImport(row)),
            ),
          ],
        ]),
      ),
      if (isExpanded) _buildExpandedItems(row, isDesktop: true),
    ]);
  }

  // ── Mobile card ───────────────────────────────────────────────────────────────

  Widget _buildMobileCard(_CustRow row) {
    final key = row.orderId ?? row.userId;
    final isExpanded = _expanded.contains(key);
    final showOrderCols = _filter == _CustFilter.customerOrders;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Name + source badge
            Row(children: [
              Expanded(
                child: Text(row.name,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827)),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              _SourceBadge(
                  source: row.source, hasItems: false, isExpanded: false),
            ]),
            if (row.pharmacy.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(row.pharmacy,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                  overflow: TextOverflow.ellipsis),
            ],
            if (row.phone.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(row.phone,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            ],
            if (row.orderId != null) ...[
              const SizedBox(height: 6),
              Row(children: [
                const Icon(Icons.receipt_outlined,
                    size: 13, color: Color(0xFF9CA3AF)),
                const SizedBox(width: 4),
                Text(
                  '#${row.orderId!.substring(0, row.orderId!.length.clamp(0, 8))}',
                  style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6B7280),
                      fontFamily: 'monospace'),
                ),
              ]),
            ],
            if (showOrderCols) ...[
              const SizedBox(height: 10),
              _ConfirmActions(row: row, onUpdate: _updateStatus),
            ],
            const SizedBox(height: 10),
            Row(children: [
              if (row.items.isNotEmpty)
                GestureDetector(
                  onTap: () => _toggleExpand(key),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                      isExpanded
                          ? 'Hide items'
                          : 'View ${row.items.length} items',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF2563EB)),
                    ),
                    Icon(
                        isExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 16,
                        color: const Color(0xFF2563EB)),
                  ]),
                ),
              const Spacer(),
              if (showOrderCols)
                _ActionCell(row: row, onImport: () => _openImport(row)),
            ]),
          ]),
        ),
        if (isExpanded) ...[
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          _buildExpandedItems(row, isDesktop: false),
        ],
      ]),
    );
  }

  // ── Expanded items ────────────────────────────────────────────────────────────

  Widget _buildExpandedItems(_CustRow row, {required bool isDesktop}) {
    final lpad = isDesktop ? 44.0 : 16.0;
    final rpad = isDesktop ? 28.0 : 16.0;

    // WhatsApp orders: no items yet (source column / table missing)
    if (row.source == 'whatsapp' && row.items.isEmpty) {
      return Container(
        color: const Color(0xFFF9FAFB),
        padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
        child: const Text(
          'WhatsApp order items unavailable — orders.source column and '
          'whatsapp_orders table do not yet exist in the database.',
          style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
        ),
      );
    }

    if (row.items.isEmpty) {
      return Container(
        color: const Color(0xFFF9FAFB),
        padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
        child: const Text('No items recorded.',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
      );
    }

    final label = row.isCartOnly
        ? 'Cart Items (${row.items.length})'
        : 'Order Items (${row.items.length})'
            '${row.total != null ? ' · ₹${row.total!.toStringAsFixed(2)}' : ''}';

    return Container(
      color: const Color(0xFFF9FAFB),
      padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151))),
        const SizedBox(height: 8),
        Row(children: [
          const Expanded(
              flex: 5,
              child: Text('Product',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF)))),
          const SizedBox(
              width: 50,
              child: Text('Qty',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF)))),
          const SizedBox(
              width: 90,
              child: Text('Price',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF)))),
        ]),
        const SizedBox(height: 4),
        ...row.items.map((item) => Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Row(children: [
                Expanded(
                    flex: 5,
                    child: Text(item.name,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF374151)))),
                SizedBox(
                    width: 50,
                    child: Text('×${item.qty}',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF6B7280)))),
                SizedBox(
                    width: 90,
                    child: Text(
                        item.price != null
                            ? '₹${item.price!.toStringAsFixed(2)}'
                            : '—',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF374151)))),
              ]),
            )),
      ]),
    );
  }

  static Widget _th(String label, {int flex = 1}) => Expanded(
        flex: flex,
        child: Text(label,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6B7280))),
      );
}

// ── Source badge ───────────────────────────────────────────────────────────────

class _SourceBadge extends StatelessWidget {
  final String source;
  final bool hasItems;
  final bool isExpanded;
  const _SourceBadge(
      {required this.source,
      required this.hasItems,
      required this.isExpanded});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    final IconData icon;
    switch (source) {
      case 'website':
        color = const Color(0xFF2563EB);
        label = 'Website';
        icon = Icons.language_outlined;
        break;
      case 'whatsapp':
        color = const Color(0xFF16A34A);
        label = 'WhatsApp';
        icon = Icons.chat_outlined;
        break;
      case 'cart_only':
        color = const Color(0xFFD97706);
        label = 'Cart';
        icon = Icons.shopping_cart_outlined;
        break;
      default:
        color = const Color(0xFF6B7280);
        label = source;
        icon = Icons.help_outline;
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: color)),
        ]),
      ),
      if (hasItems) ...[
        const SizedBox(width: 2),
        Icon(
          isExpanded ? Icons.expand_less : Icons.expand_more,
          size: 14,
          color: const Color(0xFF9CA3AF),
        ),
      ],
    ]);
  }
}

// ── Confirmation (Accept / Reject) ────────────────────────────────────────────

class _ConfirmActions extends StatefulWidget {
  final _CustRow row;
  final Future<void> Function(String orderId, String status) onUpdate;
  const _ConfirmActions({required this.row, required this.onUpdate});

  @override
  State<_ConfirmActions> createState() => _ConfirmActionsState();
}

class _ConfirmActionsState extends State<_ConfirmActions> {
  bool _busy = false;

  Future<void> _act(String status) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onUpdate(widget.row.orderId!, status);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.row.orderId == null) {
      return const Text('—',
          style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)));
    }
    if (_busy) {
      return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Color(0xFF1B5E20)));
    }
    final status = widget.row.orderStatus;
    if (status == 'confirmed') return _chip('Confirmed', const Color(0xFF16A34A));
    if (status == 'rejected')  return _chip('Rejected',  const Color(0xFFDC2626));

    return Row(mainAxisSize: MainAxisSize.min, children: [
      _btn('Accept', const Color(0xFF16A34A), () => _act('confirmed')),
      const SizedBox(width: 4),
      _btn('Reject', const Color(0xFFDC2626), () => _act('rejected')),
    ]);
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      );

  Widget _btn(String label, Color color, VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: color)),
        ),
      );
}

// ── Action cell (Imported label vs Import button) ─────────────────────────────

class _ActionCell extends StatelessWidget {
  final _CustRow row;
  final VoidCallback onImport;
  const _ActionCell({required this.row, required this.onImport});

  @override
  Widget build(BuildContext context) {
    if (row.isCartOnly) return const SizedBox();

    // WhatsApp orders: "Import" button → BulkUploadScreen preloaded
    if (row.source == 'whatsapp') {
      return _importBtn(onImport);
    }

    // Website orders: items already structured in the DB — show "Imported"
    // badge. Tapping it still opens BulkUploadScreen for review if needed.
    return InkWell(
      onTap: row.items.isNotEmpty ? onImport : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFECFDF5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: const Color(0xFF1B5E20).withValues(alpha: 0.3)),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF1B5E20)),
          SizedBox(width: 4),
          Text('Imported',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1B5E20))),
        ]),
      ),
    );
  }

  Widget _importBtn(VoidCallback onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF0FDF4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: const Color(0xFF16A34A).withValues(alpha: 0.4)),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.upload_file_outlined, size: 14, color: Color(0xFF16A34A)),
            SizedBox(width: 4),
            Text('Import',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF16A34A))),
          ]),
        ),
      );
}
