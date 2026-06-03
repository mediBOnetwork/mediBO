import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../bulk_upload_screen.dart';

// ── Data models ────────────────────────────────────────────────────────────────

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
  final String source; // 'website' | 'cart_only'
  final bool? approved;
  final String? orderId;
  final String orderStatus; // 'paid'|'confirmed'|'rejected'|'pending'|'cart_only'
  final List<_ItemLine> items;
  final DateTime? date;
  final double? total;
  final int cartCount;

  const _CustRow({
    required this.userId,
    required this.name,
    required this.pharmacy,
    required this.phone,
    required this.source,
    this.approved,
    this.orderId,
    required this.orderStatus,
    required this.items,
    this.date,
    this.total,
    required this.cartCount,
  });
}

enum _CustFilter { all, websiteOrders, whatsappOrders, cartOnly }

const _kFilterLabels = {
  _CustFilter.all: 'All Customers',
  _CustFilter.websiteOrders: 'Website Orders',
  _CustFilter.whatsappOrders: 'WhatsApp Orders',
  _CustFilter.cartOnly: 'Cart Not Ordered',
};

// ── Screen ────────────────────────────────────────────────────────────────────

class AdminCustomerScreen extends StatefulWidget {
  const AdminCustomerScreen({super.key});

  @override
  State<AdminCustomerScreen> createState() => _AdminCustomerScreenState();
}

class _AdminCustomerScreenState extends State<AdminCustomerScreen> {
  List<_CustRow> _rows = [];
  bool _loading = true;
  _CustFilter _filter = _CustFilter.all;
  final Set<String> _expanded = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  // ── Data loading ─────────────────────────────────────────────────────────────

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait<dynamic>([
        client.from('user_profiles').select(),
        client.from('orders').select().order('created_at', ascending: false),
        client.from('cart_items').select('user_id, product_name, quantity, price'),
      ]);

      final profileRows = results[0] as List;
      final orderRows = results[1] as List;
      final cartRows = results[2] as List;

      final profileMap = <String, Map<String, dynamic>>{};
      for (final p in profileRows) {
        final mp = Map<String, dynamic>.from(p as Map);
        profileMap[mp['id'] as String] = mp;
      }

      final cartByUser = <String, List<Map<String, dynamic>>>{};
      for (final ci in cartRows) {
        final mc = Map<String, dynamic>.from(ci as Map);
        final uid = mc['user_id'] as String;
        (cartByUser[uid] ??= []).add(mc);
      }

      final rows = <_CustRow>[];

      // One row per order
      for (final o in orderRows) {
        final mo = Map<String, dynamic>.from(o as Map);
        final uid = mo['user_id'] as String? ?? '';
        final profile = profileMap[uid];
        rows.add(_CustRow(
          userId: uid,
          name: _resolveName(profile, mo),
          pharmacy: _resolvePharmacy(profile, mo),
          phone: _resolvePhone(profile, mo),
          source: 'website',
          approved: profile?['approved'] as bool?,
          orderId: mo['id'] as String?,
          orderStatus: mo['status'] as String? ?? 'unknown',
          items: _parseOrderItems(mo['items']),
          date: DateTime.tryParse(mo['created_at'] as String? ?? ''),
          total: (mo['total_amount'] as num?)?.toDouble(),
          cartCount: cartByUser[uid]?.length ?? 0,
        ));
      }

      // Cart-only: users with cart items but no orders
      final usersWithOrders = {
        for (final o in orderRows) (o as Map)['user_id'] as String? ?? ''
      };
      for (final entry in cartByUser.entries) {
        if (usersWithOrders.contains(entry.key)) continue;
        final uid = entry.key;
        final profile = profileMap[uid];
        rows.add(_CustRow(
          userId: uid,
          name: (profile?['full_name'] as String?)?.trim().isNotEmpty == true
              ? profile!['full_name'] as String
              : 'Unknown Customer',
          pharmacy: profile?['business_name'] as String? ?? '',
          phone: profile?['phone'] as String? ?? '',
          source: 'cart_only',
          approved: profile?['approved'] as bool?,
          orderId: null,
          orderStatus: 'cart_only',
          items: entry.value
              .map((ci) => _ItemLine(
                    name: ci['product_name'] as String? ?? '',
                    qty: (ci['quantity'] as num?)?.toInt() ?? 1,
                    price: (ci['price'] as num?)?.toDouble(),
                  ))
              .where((i) => i.name.isNotEmpty)
              .toList(),
          date: null,
          total: null,
          cartCount: entry.value.length,
        ));
      }

      if (mounted) setState(() { _rows = rows; _loading = false; });
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

  static String _resolveName(Map? profile, Map order) {
    final n = profile?['full_name'] as String?;
    if (n != null && n.trim().isNotEmpty) return n.trim();
    return order['pharmacy_name'] as String? ?? 'Unknown';
  }

  static String _resolvePharmacy(Map? profile, Map order) {
    final biz = profile?['business_name'] as String?;
    if (biz != null && biz.trim().isNotEmpty) return biz.trim();
    return order['pharmacy_name'] as String? ?? '';
  }

  static String _resolvePhone(Map? profile, Map order) {
    final ph = profile?['phone'] as String?;
    if (ph != null && ph.trim().isNotEmpty) return ph.trim();
    return order['phone'] as String? ?? '';
  }

  static List<_ItemLine> _parseOrderItems(dynamic items) {
    if (items == null) return [];
    try {
      return (items as List)
          .map((item) {
            final m = Map<String, dynamic>.from(item as Map);
            return _ItemLine(
              name: m['product_name'] as String? ?? '',
              qty: (m['quantity'] as num?)?.toInt() ?? 1,
              price: (m['price'] as num?)?.toDouble(),
            );
          })
          .where((i) => i.name.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ── Filtering ─────────────────────────────────────────────────────────────────

  List<_CustRow> get _filtered {
    switch (_filter) {
      case _CustFilter.all:
        return _rows;
      case _CustFilter.websiteOrders:
        return _rows.where((r) => r.source == 'website').toList();
      case _CustFilter.whatsappOrders:
        return []; // No whatsapp_orders table yet
      case _CustFilter.cartOnly:
        return _rows.where((r) => r.source == 'cart_only').toList();
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────────

  Future<void> _updateOrderStatus(String orderId, String status) async {
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

  void _openBulkUpload(_CustRow row) {
    final preloadedItems = row.items.map((i) => (name: i.name, qty: i.qty)).toList();
    final title = row.pharmacy.isNotEmpty ? row.pharmacy : row.name;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => BulkUploadScreen(
          preloadedItems: preloadedItems,
          preloadedTitle: '$title — Order',
        ),
      ),
    );
  }

  void _toggleExpand(String key) =>
      setState(() => _expanded.contains(key) ? _expanded.remove(key) : _expanded.add(key));

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final isDesktop = box.maxWidth >= 900;
      final filtered = _filtered;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(isDesktop),
          if (isDesktop && !_loading && filtered.isNotEmpty) _buildTableHeader(),
          Expanded(child: _buildBody(filtered, isDesktop)),
        ],
      );
    });
  }

  Widget _buildHeader(bool isDesktop) {
    return Container(
      padding: EdgeInsets.fromLTRB(isDesktop ? 28 : 16, 18, isDesktop ? 28 : 16, 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        const Expanded(
          child: Text('Customer Dashboard',
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
        ),
        const SizedBox(width: 8),
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xFFE5E7EB)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<_CustFilter>(
              value: _filter,
              style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
              icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: Color(0xFF9CA3AF)),
              items: _CustFilter.values
                  .map((f) => DropdownMenuItem(
                        value: f,
                        child: Text(_kFilterLabels[f]!),
                      ))
                  .toList(),
              onChanged: (f) => setState(() => _filter = f ?? _CustFilter.all),
            ),
          ),
        ),
        const SizedBox(width: 4),
        IconButton(
          onPressed: _load,
          icon: const Icon(Icons.refresh_outlined, color: Color(0xFF6B7280), size: 20),
          tooltip: 'Refresh',
          visualDensity: VisualDensity.compact,
        ),
      ]),
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      color: const Color(0xFFF3F4F6),
      child: Row(children: [
        _th('Customer', flex: 3),
        _th('Pharmacy', flex: 3),
        _th('Phone', flex: 2),
        _th('Source', flex: 2),
        _th('Cart', flex: 1),
        _th('Order ID', flex: 2),
        _th('Confirmation', flex: 3),
        _th('Action', flex: 2),
      ]),
    );
  }

  Widget _buildBody(List<_CustRow> filtered, bool isDesktop) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF1B5E20), strokeWidth: 2),
      );
    }
    if (filtered.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.people_outline, size: 56, color: Color(0xFFD1D5DB)),
          const SizedBox(height: 14),
          Text(
            _filter == _CustFilter.whatsappOrders
                ? 'WhatsApp Orders unavailable\n(whatsapp_orders table not yet created)'
                : 'No customers found',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
          ),
        ]),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(top: 0, bottom: 24),
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final row = filtered[i];
        return isDesktop ? _buildDesktopRow(row) : _buildMobileCard(row);
      },
    );
  }

  // ── Desktop row ───────────────────────────────────────────────────────────────

  Widget _buildDesktopRow(_CustRow row) {
    final key = row.orderId ?? row.userId;
    final isExpanded = _expanded.contains(key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
                      fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
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
              flex: 1,
              child: Text('${row.cartCount}',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
            ),
            Expanded(
              flex: 2,
              child: Text(
                row.orderId != null
                    ? '#${row.orderId!.substring(0, row.orderId!.length.clamp(0, 8))}'
                    : '—',
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF6B7280), fontFamily: 'monospace'),
              ),
            ),
            Expanded(
              flex: 3,
              child: _ConfirmActions(row: row, onUpdate: _updateOrderStatus),
            ),
            Expanded(
              flex: 2,
              child: _ActionButton(
                  onTap: row.items.isNotEmpty ? () => _openBulkUpload(row) : null),
            ),
          ]),
        ),
        if (isExpanded) _buildExpandedItems(row, isDesktop: true),
      ],
    );
  }

  // ── Mobile card ───────────────────────────────────────────────────────────────

  Widget _buildMobileCard(_CustRow row) {
    final key = row.orderId ?? row.userId;
    final isExpanded = _expanded.contains(key);
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(row.name,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 8),
              _SourceBadge(source: row.source, hasItems: false, isExpanded: false),
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
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            ],
            const SizedBox(height: 8),
            Row(children: [
              Icon(
                row.orderId != null
                    ? Icons.receipt_outlined
                    : Icons.shopping_cart_outlined,
                size: 13,
                color: const Color(0xFF9CA3AF),
              ),
              const SizedBox(width: 4),
              Text(
                row.orderId != null
                    ? '#${row.orderId!.substring(0, row.orderId!.length.clamp(0, 8))}'
                    : '${row.cartCount} cart items',
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF6B7280), fontFamily: 'monospace'),
              ),
              const Spacer(),
              _ConfirmActions(row: row, onUpdate: _updateOrderStatus),
            ]),
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
                      isExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: const Color(0xFF2563EB),
                    ),
                  ]),
                ),
              const Spacer(),
              _ActionButton(
                  onTap: row.items.isNotEmpty ? () => _openBulkUpload(row) : null),
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

  // ── Expanded items panel ──────────────────────────────────────────────────────

  Widget _buildExpandedItems(_CustRow row, {required bool isDesktop}) {
    return Container(
      color: const Color(0xFFF9FAFB),
      padding: EdgeInsets.fromLTRB(
          isDesktop ? 44 : 16, 10, isDesktop ? 28 : 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          row.source == 'cart_only'
              ? 'Cart Items (${row.items.length})'
              : 'Order Items (${row.items.length})'
                  '${row.total != null ? ' · ₹${row.total!.toStringAsFixed(2)}' : ''}',
          style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF374151)),
        ),
        const SizedBox(height: 8),
        Row(children: [
          const Expanded(
              flex: 5,
              child: Text('Product',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF)))),
          SizedBox(
              width: 50,
              child: const Text('Qty',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF)))),
          SizedBox(
              width: 90,
              child: const Text('Price',
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
      {required this.source, required this.hasItems, required this.isExpanded});

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

// ── Order confirmation actions ─────────────────────────────────────────────────

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
      return const Text('—', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)));
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
    if (status == 'rejected') return _chip('Rejected', const Color(0xFFDC2626));

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

// ── Process action button ──────────────────────────────────────────────────────

class _ActionButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _ActionButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return const SizedBox();
    return InkWell(
      onTap: onTap,
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
          Icon(Icons.upload_file_outlined, size: 14, color: Color(0xFF1B5E20)),
          SizedBox(width: 4),
          Text('Process',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1B5E20))),
        ]),
      ),
    );
  }
}
