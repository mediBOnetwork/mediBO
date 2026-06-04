import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../bulk_upload_screen.dart';

// ── Order-row models ───────────────────────────────────────────────────────────

class _ItemLine {
  final int? id;
  final String? productId;
  final String name;
  final int qty;
  final double? price;
  final String addedBy;
  final bool removedByAdmin;
  const _ItemLine({
    this.id,
    this.productId,
    required this.name,
    required this.qty,
    this.price,
    this.addedBy = 'customer',
    this.removedByAdmin = false,
  });
}

class _CustRow {
  final String userId;
  final String name;
  final String pharmacy;
  final String phone;
  final String source; // 'website' | 'whatsapp' | 'cart_only'
  final String? orderId;
  final String orderStatus;
  final List<_ItemLine> items;
  final List<_ItemLine> removedItems;
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
    this.removedItems = const [],
    this.total,
  });

  bool get isOrder    => source == 'website' || source == 'whatsapp';
  bool get isCartOnly => source == 'cart_only';
}

// ── Registration-row model ─────────────────────────────────────────────────────

class _RegRow {
  final String id;           // user_profiles.id  (= auth user UUID)
  final String fullName;     // full_name
  final String businessName; // business_name
  final String phone;        // phone
  final String? customerId;  // customer_id  ("3-letter + 3-digit code")
  final String? paymentTerm; // payment_term  (Advance / COD / etc.)
  final String? storeType;   // store_type
  final String? range;       // range
  final String? addressLine; // address_line
  final String? city;        // city
  final String? state;       // state
  final String? pincode;     // pincode
  final String? whatsappNumber; // whatsapp_number
  final String? otherContact;   // other_contact
  final String? dl1;            // dl1
  final String? dl2;            // dl2
  final String? gstin;          // gstin
  final String? googleMapLink;  // google_map_link
  final DateTime? createdAt;    // created_at

  const _RegRow({
    required this.id,
    required this.fullName,
    required this.businessName,
    required this.phone,
    this.customerId,
    this.paymentTerm,
    this.storeType,
    this.range,
    this.addressLine,
    this.city,
    this.state,
    this.pincode,
    this.whatsappNumber,
    this.otherContact,
    this.dl1,
    this.dl2,
    this.gstin,
    this.googleMapLink,
    this.createdAt,
  });

  factory _RegRow.fromMap(Map<String, dynamic> m) => _RegRow(
        id:            m['id'] as String,
        fullName:      m['full_name'] as String? ?? '',
        businessName:  m['business_name'] as String? ?? '',
        phone:         m['phone'] as String? ?? '',
        customerId:    m['customer_id'] as String?,
        paymentTerm:   m['payment_term'] as String?,
        storeType:     m['store_type'] as String?,
        range:         m['range'] as String?,
        addressLine:   m['address_line'] as String?,
        city:          m['city'] as String?,
        state:         m['state'] as String?,
        pincode:       m['pincode'] as String?,
        whatsappNumber: m['whatsapp_number'] as String?,
        otherContact:  m['other_contact'] as String?,
        dl1:           m['dl1'] as String?,
        dl2:           m['dl2'] as String?,
        gstin:         m['gstin'] as String?,
        googleMapLink: m['google_map_link'] as String?,
        createdAt:     m['created_at'] != null
            ? DateTime.tryParse(m['created_at'] as String)
            : null,
      );
}

// ── Filter ─────────────────────────────────────────────────────────────────────

enum _CustFilter { customerOrders, cartNotOrdered, pendingRegistrations }

// ── Screen ────────────────────────────────────────────────────────────────────

class AdminCustomerScreen extends StatefulWidget {
  const AdminCustomerScreen({super.key});

  @override
  State<AdminCustomerScreen> createState() => _AdminCustomerScreenState();
}

class _AdminCustomerScreenState extends State<AdminCustomerScreen> {
  List<_CustRow> _orderRows = [];
  List<_CustRow> _cartRows  = [];
  List<_RegRow>  _regRows   = [];
  bool _loading = true;
  _CustFilter _filter = _CustFilter.customerOrders;
  final Set<String> _expanded = {};
  final ScrollController _scrollCtrl = ScrollController();

  final List<RealtimeChannel> _realtimeChannels = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final ch in _realtimeChannels) {
      ch.unsubscribe();
    }
    _realtimeChannels.clear();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _subscribeRealtime() {
    final client = Supabase.instance.client;
    final ts = DateTime.now().millisecondsSinceEpoch;
    for (final table in ['cart_items', 'orders', 'user_profiles']) {
      final ch = client
          .channel('admin_${table}_$ts')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            callback: (_) => _debouncedLoad(),
          )
          .subscribe();
      _realtimeChannels.add(ch);
    }
  }

  void _debouncedLoad() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => _load(showSpinner: false));
  }

  // ── Data ──────────────────────────────────────────────────────────────────────

  Future<void> _load({bool showSpinner = true}) async {
    if (!mounted) return;
    if (showSpinner) setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait<dynamic>([
        client.from('user_profiles').select(),
        client.from('pharmacy_profiles').select(),
        client.from('orders').select().order('created_at', ascending: false),
        client.from('cart_items').select(),
      ]);

      final upRows    = results[0] as List;
      final ppRows    = results[1] as List;
      final orderRows = results[2] as List;
      final cartRows  = results[3] as List;

      // Profile lookups
      final upMap = <String, Map<String, dynamic>>{};
      for (final p in upRows) {
        final m = Map<String, dynamic>.from(p as Map);
        upMap[m['id'] as String] = m;
      }
      final ppMap = <String, Map<String, dynamic>>{};
      for (final p in ppRows) {
        final m = Map<String, dynamic>.from(p as Map);
        ppMap[m['user_id'] as String] = m;
      }

      // Cart items grouped by user
      final cartByUser = <String, List<Map<String, dynamic>>>{};
      for (final ci in cartRows) {
        final m = Map<String, dynamic>.from(ci as Map);
        (cartByUser[m['user_id'] as String] ??= []).add(m);
      }

      // Order rows
      final orders = <_CustRow>[];
      for (final o in orderRows) {
        final mo  = Map<String, dynamic>.from(o as Map);
        final uid = mo['user_id'] as String? ?? '';
        final up  = upMap[uid];
        final pp  = ppMap[uid];
        orders.add(_CustRow(
          userId:      uid,
          name:        _name(up, pp, mo),
          pharmacy:    _pharmacy(up, pp, mo),
          phone:       _phone(up, pp, mo),
          source:      mo['source'] as String? ?? 'website',
          orderId:     mo['id'] as String?,
          orderStatus: mo['status'] as String? ?? 'unknown',
          items:       _parseItems(mo['items']),
          total:       (mo['total_amount'] as num?)?.toDouble(),
        ));
      }

      // Cart-only rows
      final orderedUids = {
        for (final o in orderRows) (o as Map)['user_id'] as String? ?? ''
      };
      final carts = <_CustRow>[];
      for (final entry in cartByUser.entries) {
        if (orderedUids.contains(entry.key)) continue;
        final uid = entry.key;
        final up  = upMap[uid];
        final pp  = ppMap[uid];
        final allItems = entry.value
            .map((ci) => _ItemLine(
                  id:             ci['id'] as int?,
                  productId:      ci['product_id'] as String?,
                  name:           ci['product_name'] as String? ?? '',
                  qty:            (ci['quantity'] as num?)?.toInt() ?? 1,
                  price:          (ci['price'] as num?)?.toDouble(),
                  addedBy:        ci['added_by'] as String? ?? 'customer',
                  removedByAdmin: (ci['removed_by_admin'] as bool?) ?? false,
                ))
            .where((i) => i.name.isNotEmpty)
            .toList();
        carts.add(_CustRow(
          userId:       uid,
          name:         _name(up, pp, null),
          pharmacy:     _pharmacy(up, pp, null),
          phone:        _phone(up, pp, null),
          source:       'cart_only',
          orderId:      null,
          orderStatus:  'cart_only',
          items:        allItems.where((i) => !i.removedByAdmin).toList(),
          removedItems: allItems.where((i) => i.removedByAdmin).toList(),
          total:        null,
        ));
      }

      // Pending registrations — user_profiles WHERE approved IS NULL
      final regs = <_RegRow>[];
      for (final p in upRows) {
        final m = Map<String, dynamic>.from(p as Map);
        if (m['approved'] == null) {
          regs.add(_RegRow.fromMap(m));
        }
      }
      // Sort newest first
      regs.sort((a, b) {
        if (a.createdAt == null && b.createdAt == null) return 0;
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      if (mounted) {
        setState(() {
          _orderRows = orders;
          _cartRows  = carts;
          _regRows   = regs;
          _loading   = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Failed to load: $e'),
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

  // For order / cart filters returns _CustRow list; reg filter is handled separately
  List<_CustRow> get _activeCust {
    switch (_filter) {
      case _CustFilter.customerOrders:  return _orderRows;
      case _CustFilter.cartNotOrdered:  return _cartRows;
      case _CustFilter.pendingRegistrations: return [];
    }
  }

  bool get _isRegView => _filter == _CustFilter.pendingRegistrations;

  // ── Approve / Reject registrations ───────────────────────────────────────────

  Future<void> _approveReg(String id) async {
    await Supabase.instance.client.from('user_profiles').update({
      'approved': true,
      'approved_at': DateTime.now().toUtc().toIso8601String(),
      'approved_by': 'admin',
    }).eq('id', id);
    _load();
  }

  Future<void> _rejectReg(String id) async {
    await Supabase.instance.client
        .from('user_profiles')
        .update({'approved': false})
        .eq('id', id);
    _load();
  }

  // ── Order status ──────────────────────────────────────────────────────────────

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

  Future<void> _adminSoftRemoveItem(int itemId) async {
    try {
      await Supabase.instance.client
          .from('cart_items')
          .update({'removed_by_admin': true})
          .eq('id', itemId);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Remove failed: $e'),
          backgroundColor: const Color(0xFFDC2626),
        ));
      }
    }
  }

  Future<void> _adminAddCartItem(String userId) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _AdminAddItemDialog(userId: userId),
    );
    if (result == true) _load(showSpinner: false);
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

      // Loading: fill the bounded parent space with a centred spinner.
      // No Column+Expanded here — just a single widget that fills its parent.
      if (_loading) {
        return const Center(
          child: CircularProgressIndicator(
              color: Color(0xFF1B5E20), strokeWidth: 2),
        );
      }

      // PrimaryScrollController lets AdminScrollBehavior's auto-injected
      // Scrollbar use _scrollCtrl (for thumb drag + programmatic jumpTo).
      // primary:true on SSV routes wheel/trackpad PointerScrollEvents here.
      return PrimaryScrollController(
        controller: _scrollCtrl,
        child: SingleChildScrollView(
          primary: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(isDesktop),
              _buildScrollContent(isDesktop),
            ],
          ),
        ),
      );
    });
  }

  // All non-loading content rendered as a single Column inside SingleChildScrollView.
  // No inner ListView — every row widget expands inline, so there is nothing to
  // intercept the parent scroll.
  Widget _buildScrollContent(bool isDesktop) {
    // ── Pending registrations ─────────────────────────────────────────────────
    if (_isRegView) {
      if (_regRows.isEmpty) {
        return _ssvEmptyState('0 pending registrations');
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isDesktop) _buildRegTableHeader(),
          ..._regRows.map(
            (r) => isDesktop ? _buildDesktopRegRow(r) : _buildMobileRegCard(r)),
          const SizedBox(height: 32),
        ],
      );
    }

    // ── Customer orders / cart ────────────────────────────────────────────────
    final rows = _activeCust;
    if (rows.isEmpty) {
      return _ssvEmptyState(
        _filter == _CustFilter.customerOrders
            ? '0 orders'
            : '0 customers with unpurchased cart items',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isDesktop) _buildCustTableHeader(),
        ...rows.map(
          (r) => isDesktop ? _buildDesktopCustRow(r) : _buildMobileCustCard(r)),
        const SizedBox(height: 32),
      ],
    );
  }

  // Empty state suitable for SingleChildScrollView child (unbounded height —
  // cannot use Center for vertical centering, so pad from top instead).
  Widget _ssvEmptyState(String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.people_outline, size: 56, color: Color(0xFFD1D5DB)),
          const SizedBox(height: 14),
          Text(message,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 14, color: Color(0xFF9CA3AF))),
        ],
      ),
    );
  }

  // ── Shared header with 3 tabs ─────────────────────────────────────────────────

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
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _tab(_CustFilter.customerOrders,
                'Customer Orders (${_orderRows.length})'),
            const SizedBox(width: 4),
            _tab(_CustFilter.cartNotOrdered,
                'Cart — Not Ordered (${_cartRows.length})'),
            const SizedBox(width: 4),
            _tab(_CustFilter.pendingRegistrations,
                'Pending Registrations (${_regRows.length})'),
          ]),
        ),
      ]),
    );
  }

  Widget _tab(_CustFilter f, String label) {
    final active = _filter == f;
    return GestureDetector(
      onTap: () {
        if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
        setState(() {
          _filter = f;
          _expanded.clear();
        });
      },
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
            color: active
                ? const Color(0xFF1B5E20)
                : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }

  Widget _emptyState(String message) => Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.people_outline, size: 56, color: Color(0xFFD1D5DB)),
          const SizedBox(height: 14),
          Text(message,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontSize: 14, color: Color(0xFF9CA3AF))),
        ]),
      );

  // ═══════════════════════════════════════════════════════════════════════════
  // CUSTOMER ORDERS / CART views
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildCustTableHeader() {
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

  Widget _buildDesktopCustRow(_CustRow row) {
    final key        = row.orderId ?? row.userId;
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
                  overflow: TextOverflow.ellipsis)),
          Expanded(
              flex: 3,
              child: Text(row.pharmacy.isNotEmpty ? row.pharmacy : '—',
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF374151)),
                  overflow: TextOverflow.ellipsis)),
          Expanded(
              flex: 2,
              child: Text(row.phone.isNotEmpty ? row.phone : '—',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280)))),
          Expanded(
            flex: 2,
            child: InkWell(
              onTap: row.items.isNotEmpty
                  ? () => _toggleExpand(key)
                  : null,
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
              )),
          if (showOrderCols) ...[
            Expanded(
                flex: 3,
                child: _ConfirmActions(
                    row: row, onUpdate: _updateStatus)),
            Expanded(
                flex: 2,
                child: _ActionCell(
                    row: row, onImport: () => _openImport(row))),
          ],
        ]),
      ),
      if (isExpanded) _buildExpandedItems(row, isDesktop: true),
    ]);
  }

  Widget _buildMobileCustCard(_CustRow row) {
    final key        = row.orderId ?? row.userId;
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
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Row(children: [
              Expanded(
                  child: Text(row.name,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827)),
                      overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              _SourceBadge(
                  source: row.source,
                  hasItems: false,
                  isExpanded: false),
            ]),
            if (row.pharmacy.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(row.pharmacy,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280)),
                  overflow: TextOverflow.ellipsis),
            ],
            if (row.phone.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(row.phone,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280))),
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
                        fontFamily: 'monospace')),
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

  Widget _buildExpandedItems(_CustRow row, {required bool isDesktop}) {
    final lpad = isDesktop ? 44.0 : 16.0;
    final rpad = isDesktop ? 28.0 : 16.0;

    if (row.source == 'whatsapp' && row.items.isEmpty) {
      return Container(
        color: const Color(0xFFF9FAFB),
        padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
        child: const Text(
          'WhatsApp order items unavailable — orders.source column and '
          'whatsapp_orders table do not yet exist.',
          style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
        ),
      );
    }

    if (row.isCartOnly) {
      return _buildCartExpandedItems(row, lpad: lpad, rpad: rpad);
    }

    if (row.items.isEmpty) {
      return Container(
        color: const Color(0xFFF9FAFB),
        padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
        child: const Text('No items recorded.',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
      );
    }
    final label = 'Order Items (${row.items.length})'
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
        const Row(children: [
          Expanded(
              flex: 5,
              child: Text('Product',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF)))),
          SizedBox(
              width: 50,
              child: Text('Qty',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF)))),
          SizedBox(
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

  Widget _buildCartExpandedItems(_CustRow row, {required double lpad, required double rpad}) {
    return Container(
      color: const Color(0xFFF9FAFB),
      padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header + Add button
        Row(children: [
          Text(
            'Cart Items (${row.items.length})',
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF374151)),
          ),
          const Spacer(),
          TextButton.icon(
            onPressed: () => _adminAddCartItem(row.userId),
            icon: const Icon(Icons.add, size: 14),
            label: const Text('Add Item', style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF1B5E20),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ]),
        const SizedBox(height: 6),

        // Active items
        if (row.items.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text('No active items.',
                style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
          )
        else ...[
          Row(children: const [
            Expanded(
                flex: 5,
                child: Text('Product',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9CA3AF)))),
            SizedBox(
                width: 44,
                child: Text('Qty',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9CA3AF)))),
            SizedBox(
                width: 80,
                child: Text('Price',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9CA3AF)))),
            SizedBox(width: 68),
          ]),
          const SizedBox(height: 4),
          ...row.items.map((item) => Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(
                      flex: 5,
                      child: Row(children: [
                        Flexible(
                          child: Text(item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF374151))),
                        ),
                        if (item.addedBy == 'admin') ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFEF08A),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('mediBO',
                                style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF92400E))),
                          ),
                        ],
                      ])),
                  SizedBox(
                      width: 44,
                      child: Text('×${item.qty}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6B7280)))),
                  SizedBox(
                      width: 80,
                      child: Text(
                          item.price != null
                              ? '₹${item.price!.toStringAsFixed(2)}'
                              : '—',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF374151)))),
                  SizedBox(
                    width: 68,
                    child: item.id != null
                        ? TextButton(
                            onPressed: () => _adminSoftRemoveItem(item.id!),
                            style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFFDC2626),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              minimumSize: Size.zero,
                            ),
                            child: const Text('Remove',
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                          )
                        : const SizedBox(),
                  ),
                ]),
              )),
        ],

        // Removed by admin section
        if (row.removedItems.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 8),
          Text(
            'Removed by admin (${row.removedItems.length})',
            style: const TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 4),
          ...row.removedItems.map((item) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  Expanded(
                      flex: 5,
                      child: Text(item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFD1D5DB),
                              decoration: TextDecoration.lineThrough,
                              decorationColor: Color(0xFFD1D5DB)))),
                  SizedBox(
                      width: 44,
                      child: Text('×${item.qty}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFD1D5DB)))),
                  SizedBox(
                      width: 80,
                      child: Text(
                          item.price != null
                              ? '₹${item.price!.toStringAsFixed(2)}'
                              : '—',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFD1D5DB)))),
                  const SizedBox(width: 68),
                ]),
              )),
        ],
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PENDING REGISTRATIONS view
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildRegTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      color: const Color(0xFFF3F4F6),
      child: Row(children: [
        _th('Customer Name', flex: 3),
        _th('Pharmacy', flex: 3),
        _th('Phone', flex: 2),
        _th('Code', flex: 2),
        _th('Payment', flex: 2),
        _th('City / State', flex: 2),
        _th('Approval', flex: 3),
        _th('Details', flex: 1),
      ]),
    );
  }

  Widget _buildDesktopRegRow(_RegRow row) {
    final isExpanded = _expanded.contains(row.id);
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
              child: Text(
                  row.fullName.isNotEmpty ? row.fullName : '—',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827)),
                  overflow: TextOverflow.ellipsis)),
          Expanded(
              flex: 3,
              child: Text(
                  row.businessName.isNotEmpty ? row.businessName : '—',
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF374151)),
                  overflow: TextOverflow.ellipsis)),
          Expanded(
              flex: 2,
              child: Text(row.phone.isNotEmpty ? row.phone : '—',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280)))),
          Expanded(
              flex: 2,
              child: Text(row.customerId?.isNotEmpty == true
                  ? row.customerId!
                  : '—',
                  style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF374151),
                      fontFamily: 'monospace'))),
          Expanded(
              flex: 2,
              child: row.paymentTerm?.isNotEmpty == true
                  ? _PaymentBadge(term: row.paymentTerm!)
                  : const Text('—',
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFF9CA3AF)))),
          Expanded(
              flex: 2,
              child: Text(
                  [row.city, row.state]
                      .where((s) => s != null && s.isNotEmpty)
                      .join(', ')
                      .let((s) => s.isNotEmpty ? s : '—'),
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280)),
                  overflow: TextOverflow.ellipsis)),
          Expanded(
              flex: 3,
              child: _RegApproveActions(
                  id: row.id,
                  onApprove: () => _approveReg(row.id),
                  onReject: () => _rejectReg(row.id))),
          Expanded(
            flex: 1,
            child: InkWell(
              onTap: () => _toggleExpand(row.id),
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                    isExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 18,
                    color: const Color(0xFF6B7280)),
              ),
            ),
          ),
        ]),
      ),
      if (isExpanded) _buildRegDetails(row, isDesktop: true),
    ]);
  }

  Widget _buildMobileRegCard(_RegRow row) {
    final isExpanded = _expanded.contains(row.id);
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
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            // Name + pending badge
            Row(children: [
              Expanded(
                  child: Text(
                      row.fullName.isNotEmpty ? row.fullName : 'Unknown',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827)),
                      overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              _pendingBadge(),
            ]),
            if (row.businessName.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(row.businessName,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280)),
                  overflow: TextOverflow.ellipsis),
            ],
            if (row.phone.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(row.phone,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280))),
            ],
            // Quick fields row
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 4, children: [
              if (row.customerId?.isNotEmpty == true)
                _mobileField('Code', row.customerId!),
              if (row.paymentTerm?.isNotEmpty == true)
                _mobileField('Payment', row.paymentTerm!),
              if (row.city?.isNotEmpty == true)
                _mobileField(
                    'City',
                    [row.city, row.state]
                        .where((s) => s != null && s.isNotEmpty)
                        .join(', ')),
              if (row.pincode?.isNotEmpty == true)
                _mobileField('PIN', row.pincode!),
            ]),
            // Approve / Reject
            const SizedBox(height: 12),
            _RegApproveActions(
                id: row.id,
                onApprove: () => _approveReg(row.id),
                onReject: () => _rejectReg(row.id)),
            // Expand details
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _toggleExpand(row.id),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(
                  isExpanded ? 'Hide details' : 'View full details',
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
          ]),
        ),
        if (isExpanded) ...[
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          _buildRegDetails(row, isDesktop: false),
        ],
      ]),
    );
  }

  // Expanded registration details panel — shows ALL remaining fields
  Widget _buildRegDetails(_RegRow row, {required bool isDesktop}) {
    final lpad = isDesktop ? 44.0 : 16.0;
    final rpad = isDesktop ? 28.0 : 16.0;

    final fields = <_FieldPair>[
      if (row.storeType?.isNotEmpty == true)
        _FieldPair('Store Type', row.storeType!),
      if (row.range?.isNotEmpty == true)
        _FieldPair('Range / Zone', row.range!),
      if (row.addressLine?.isNotEmpty == true)
        _FieldPair('Address', row.addressLine!),
      if (row.pincode?.isNotEmpty == true)
        _FieldPair('Pincode', row.pincode!),
      if (row.whatsappNumber?.isNotEmpty == true)
        _FieldPair('WhatsApp', row.whatsappNumber!),
      if (row.otherContact?.isNotEmpty == true)
        _FieldPair('Other Contact', row.otherContact!),
      if (row.dl1?.isNotEmpty == true)
        _FieldPair('Drug Licence 1', row.dl1!),
      if (row.dl2?.isNotEmpty == true)
        _FieldPair('Drug Licence 2', row.dl2!),
      if (row.gstin?.isNotEmpty == true)
        _FieldPair('GSTIN', row.gstin!),
      if (row.googleMapLink?.isNotEmpty == true)
        _FieldPair('Map Link', row.googleMapLink!),
      if (row.createdAt != null)
        _FieldPair(
            'Registered',
            '${row.createdAt!.day.toString().padLeft(2, '0')}/'
            '${row.createdAt!.month.toString().padLeft(2, '0')}/'
            '${row.createdAt!.year}'),
    ];

    if (fields.isEmpty) {
      return Container(
        color: const Color(0xFFF9FAFB),
        padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
        child: const Text('No additional details on record.',
            style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
      );
    }

    return Container(
      color: const Color(0xFFF9FAFB),
      padding: EdgeInsets.fromLTRB(lpad, 12, rpad, 16),
      child: Wrap(
        spacing: isDesktop ? 40 : 20,
        runSpacing: 10,
        children: fields
            .map((f) => SizedBox(
                  width: isDesktop ? 200 : double.infinity,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(f.label,
                        style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF9CA3AF),
                            letterSpacing: 0.4)),
                    const SizedBox(height: 2),
                    Text(f.value,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF374151))),
                  ]),
                ))
            .toList(),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  static Widget _th(String label, {int flex = 1}) => Expanded(
        flex: flex,
        child: Text(label,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6B7280))),
      );

  static Widget _pendingBadge() => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(20),
          border:
              Border.all(color: const Color(0xFFD97706).withValues(alpha: 0.4)),
        ),
        child: const Text('Pending',
            style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFFD97706))),
      );

  static Widget _mobileField(String label, String value) => RichText(
        text: TextSpan(
          children: [
            TextSpan(
                text: '$label: ',
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF9CA3AF))),
            TextSpan(
                text: value,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF374151))),
          ],
        ),
      );
}

// Small value holder used for the details panel
class _FieldPair {
  final String label;
  final String value;
  const _FieldPair(this.label, this.value);
}

// Extension used for String pipeline in build
extension _Let<T> on T {
  R let<R>(R Function(T) fn) => fn(this);
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
        padding:
            const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
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
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ]),
      ),
      if (hasItems) ...[
        const SizedBox(width: 2),
        Icon(
            isExpanded ? Icons.expand_less : Icons.expand_more,
            size: 14,
            color: const Color(0xFF9CA3AF)),
      ],
    ]);
  }
}

// ── Payment term badge ─────────────────────────────────────────────────────────

class _PaymentBadge extends StatelessWidget {
  final String term;
  const _PaymentBadge({required this.term});

  @override
  Widget build(BuildContext context) {
    final isAdvance =
        term.toLowerCase().contains('advance') || term.toLowerCase() == 'adv';
    final color = isAdvance
        ? const Color(0xFF7C3AED)
        : const Color(0xFF0891B2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(term,
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: color)),
    );
  }
}

// ── Order confirmation (Accept / Reject) ──────────────────────────────────────

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
    if (status == 'confirmed')
      return _chip('Confirmed', const Color(0xFF16A34A));
    if (status == 'rejected')
      return _chip('Rejected', const Color(0xFFDC2626));

    return Row(mainAxisSize: MainAxisSize.min, children: [
      _btn('Accept', const Color(0xFF16A34A), () => _act('confirmed')),
      const SizedBox(width: 4),
      _btn('Reject', const Color(0xFFDC2626), () => _act('rejected')),
    ]);
  }

  Widget _chip(String label, Color color) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20)),
        child: Text(label,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: color)),
      );

  Widget _btn(String label, Color color, VoidCallback onTap) =>
      InkWell(
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
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ),
      );
}

// ── Registration Approve / Reject ──────────────────────────────────────────────

class _RegApproveActions extends StatefulWidget {
  final String id;
  final Future<void> Function() onApprove;
  final Future<void> Function() onReject;
  const _RegApproveActions(
      {required this.id,
      required this.onApprove,
      required this.onReject});

  @override
  State<_RegApproveActions> createState() => _RegApproveActionsState();
}

class _RegApproveActionsState extends State<_RegApproveActions> {
  bool _busy = false;

  Future<void> _act(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Action failed: $e'),
          backgroundColor: const Color(0xFFDC2626),
        ));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: Color(0xFF1B5E20)));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _btn('Approve', const Color(0xFF16A34A),
          () => _act(widget.onApprove)),
      const SizedBox(width: 4),
      _btn('Reject', const Color(0xFFDC2626),
          () => _act(widget.onReject)),
    ]);
  }

  Widget _btn(String label, Color color, VoidCallback onTap) =>
      InkWell(
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
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: color)),
        ),
      );
}

// ── Action cell (website = Imported, whatsapp = Import button) ─────────────────

class _ActionCell extends StatelessWidget {
  final _CustRow row;
  final VoidCallback onImport;
  const _ActionCell({required this.row, required this.onImport});

  @override
  Widget build(BuildContext context) {
    if (row.isCartOnly) return const SizedBox();

    if (row.source == 'whatsapp') {
      return InkWell(
        onTap: onImport,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF0FDF4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: const Color(0xFF16A34A).withValues(alpha: 0.4)),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.upload_file_outlined,
                size: 14, color: Color(0xFF16A34A)),
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

    // Website order — items already in DB
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
          Icon(Icons.check_circle_outline,
              size: 14, color: Color(0xFF1B5E20)),
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
}

// ── Admin add-to-cart dialog ───────────────────────────────────────────────────

class _AdminAddItemDialog extends StatefulWidget {
  final String userId;
  const _AdminAddItemDialog({required this.userId});
  @override
  State<_AdminAddItemDialog> createState() => _AdminAddItemDialogState();
}

class _AdminAddItemDialogState extends State<_AdminAddItemDialog> {
  final _searchCtrl = TextEditingController();
  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  Map<String, dynamic>? _selected;
  int _qty = 1;
  bool _adding = false;

  static double _parseMrp(Object? v) {
    if (v == null) return 0;
    final s = v.toString().replaceAll(RegExp(r'[₹,\s]'), '');
    return double.tryParse(s) ?? 0;
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() { _results = []; _searching = false; });
      return;
    }
    setState(() => _searching = true);
    try {
      final rows = await Supabase.instance.client
          .from('MEDICINE')
          .select('id, product_name, mrp, marketer, therapeutic_class, image_url_1, pack_qty, pack_size, gst_percent')
          .ilike('product_name', '%${query.trim()}%')
          .limit(30);
      if (mounted) {
        setState(() {
          _results = List<Map<String, dynamic>>.from(rows as List);
          _searching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _addItem() async {
    final item = _selected;
    if (item == null || _adding) return;
    setState(() => _adding = true);
    try {
      final productId = item['id'].toString();
      final mrp = _parseMrp(item['mrp']);

      // Check for existing row (active or removed)
      final existingList = await Supabase.instance.client
          .from('cart_items')
          .select('id, quantity, removed_by_admin')
          .eq('user_id', widget.userId)
          .eq('product_id', productId);

      if (existingList.isNotEmpty) {
        final existing = Map<String, dynamic>.from(existingList.first as Map);
        final wasRemoved = (existing['removed_by_admin'] as bool?) ?? false;
        final newQty = wasRemoved ? _qty : (existing['quantity'] as int) + _qty;
        await Supabase.instance.client
            .from('cart_items')
            .update({
              'quantity': newQty,
              'removed_by_admin': false,
              'updated_at': DateTime.now().toIso8601String(),
            })
            .eq('id', existing['id'] as int);
      } else {
        await Supabase.instance.client.from('cart_items').insert({
          'user_id':      widget.userId,
          'product_id':   productId,
          'product_name': item['product_name'] as String? ?? '',
          'price':        mrp,
          'mrp':          mrp,
          'quantity':     _qty,
          'image_url':    (item['image_url_1'] as String?) ?? '',
          'manufacturer': (item['marketer'] as String?) ?? '',
          'pack_size':    (item['pack_qty'] as String?) ?? (item['pack_size'] as String?) ?? '',
          'category':     (item['therapeutic_class'] as String?) ?? 'Other',
          'gst_percent':  (item['gst_percent'] as num?)?.toInt() ?? 12,
          'added_by':     'admin',
          'removed_by_admin': false,
          'updated_at':   DateTime.now().toIso8601String(),
        });
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _adding = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().contains('column')
              ? 'DB migration required — run the migration SQL in Supabase Studio first'
              : 'Failed to add item: $e'),
          backgroundColor: const Color(0xFFDC2626),
        ));
      }
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 580),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Expanded(
                  child: Text('Add Item to Cart',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827))),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(context),
                  visualDensity: VisualDensity.compact,
                ),
              ]),
              const SizedBox(height: 12),
              TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search medicine name…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  suffixIcon: _searching
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: Padding(
                            padding: EdgeInsets.all(10),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ))
                      : null,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  isDense: true,
                ),
                onChanged: _search,
              ),
              const SizedBox(height: 8),
              if (_selected != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF86EFAC)),
                  ),
                  child: Row(children: [
                    Expanded(
                      child: Text(_selected!['product_name'] as String? ?? '',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 8),
                    const Text('Qty:',
                        style: TextStyle(fontSize: 12, color: Color(0xFF374151))),
                    const SizedBox(width: 6),
                    SizedBox(
                      width: 52,
                      child: TextFormField(
                        initialValue: '1',
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) {
                          final n = int.tryParse(v);
                          if (n != null && n > 0) setState(() => _qty = n);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () => setState(() => _selected = null),
                      icon: const Icon(Icons.close, size: 14, color: Color(0xFF6B7280)),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                    ),
                  ]),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _adding ? null : _addItem,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1B5E20),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: _adding
                        ? const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('Add to Cart',
                            style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              Expanded(
                child: _results.isEmpty && !_searching
                    ? Center(
                        child: Text(
                          _searchCtrl.text.isEmpty
                              ? 'Search for a medicine above'
                              : 'No results found',
                          style: const TextStyle(
                              color: Color(0xFF9CA3AF), fontSize: 13),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (_, i) {
                          final item = _results[i];
                          return InkWell(
                            onTap: () => setState(() {
                              _selected = item;
                              _results = [];
                              _qty = 1;
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 8),
                              decoration: const BoxDecoration(
                                border: Border(
                                    bottom: BorderSide(color: Color(0xFFE5E7EB))),
                              ),
                              child: Row(children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(item['product_name'] as String? ?? '',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF111827)),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                      if ((item['marketer'] as String?)?.isNotEmpty == true)
                                        Text(item['marketer'] as String,
                                            style: const TextStyle(
                                                fontSize: 11,
                                                color: Color(0xFF6B7280)),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '₹${_parseMrp(item['mrp']).toStringAsFixed(0)}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF374151)),
                                ),
                              ]),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
