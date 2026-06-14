// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';

import '../../config/api_keys.dart';
import '../../util.dart';
import '../../utils/render_log.dart';
import '../bulk_upload_screen.dart';

// ── Item model ────────────────────────────────────────────────────────────────

class _ItemLine {
  final int? id;
  final String? productId;
  final String name;
  final int qty;
  final double? price;
  final double? mrp;
  final int? gstPercent;
  final String? packSize;
  final String addedBy;
  final bool removedByAdmin;

  const _ItemLine({
    this.id,
    this.productId,
    required this.name,
    required this.qty,
    this.price,
    this.mrp,
    this.gstPercent,
    this.packSize,
    this.addedBy = 'customer',
    this.removedByAdmin = false,
  });
}

// ── Customer row model ────────────────────────────────────────────────────────

class _CustRow {
  final String userId;
  final String name;
  final String pharmacy;
  final String phone;
  final String source;
  final String? orderId;
  final String? orderNumber;
  final String orderStatus;
  final List<_ItemLine> items;
  final List<_ItemLine> removedItems;
  final double? total;
  final double netPayable;
  final bool placedByAdmin;

  const _CustRow({
    required this.userId,
    required this.name,
    required this.pharmacy,
    required this.phone,
    required this.source,
    this.orderId,
    this.orderNumber,
    required this.orderStatus,
    required this.items,
    this.removedItems = const [],
    this.total,
    this.netPayable = 0.0,
    this.placedByAdmin = false,
  });

  bool get isOrder    => source == 'website' || source == 'whatsapp';
  bool get isCartOnly => source == 'cart_only';
}

// ── Registration-row model ────────────────────────────────────────────────────

class _RegRow {
  final String id;
  final String fullName;
  final String businessName;
  final String phone;
  final String? customerId;
  final String? paymentTerm;
  final String? storeType;
  final String? range;
  final String? addressLine;
  final String? city;
  final String? state;
  final String? pincode;
  final String? whatsappNumber;
  final String? otherContact;
  final String? dl1;
  final String? dl2;
  final String? gstin;
  final String? googleMapLink;
  final String? email;
  final DateTime? createdAt;
  final Map<String, dynamic> rawData; // full row for dynamic display

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
    this.email,
    this.createdAt,
    required this.rawData,
  });

  factory _RegRow.fromMap(Map<String, dynamic> m) => _RegRow(
        id:             m['id'] as String,
        rawData:        Map<String, dynamic>.from(m),
        fullName:       m['customer_name'] as String? ?? m['owner_name'] as String? ?? '',
        businessName:   m['pharmacy_name'] as String? ?? '',
        phone:          m['whatsapp_no'] as String? ?? m['phone'] as String? ?? '',
        customerId:     m['customer_code'] as String?,
        paymentTerm:    m['payment_term'] as String?,
        storeType:      m['store_type'] as String?,
        range:          m['range_zone'] as String?,
        addressLine:    m['address_local'] as String? ?? m['address'] as String?,
        city:           m['city'] as String?,
        state:          m['state'] as String?,
        pincode:        m['pincode'] as String?,
        whatsappNumber: m['whatsapp_no'] as String? ?? m['phone'] as String?,
        otherContact:   m['other_contact_no'] as String?,
        dl1:            m['dl_20b'] as String? ?? m['drug_license'] as String?,
        dl2:            m['dl_21b'] as String?,
        gstin:          m['gst_no'] as String? ?? m['gstin'] as String?,
        googleMapLink:  m['store_location_link'] as String?,
        email:          m['email'] as String?,
        createdAt:      m['created_at'] != null
            ? DateTime.tryParse(m['created_at'] as String)
            : null,
      );
}

// ── Approved-customer row model ───────────────────────────────────────────────

class _ApprovedRow {
  final String id;
  final Map<String, dynamic> rawData;

  const _ApprovedRow({required this.id, required this.rawData});

  factory _ApprovedRow.fromMap(Map<String, dynamic> m) => _ApprovedRow(
        id:      m['id'] as String,
        rawData: Map<String, dynamic>.from(m),
      );

  String get pharmacyName {
    final n = rawData['pharmacy_name'] as String? ?? '';
    return n.trim();
  }

  String get customerName {
    final n = rawData['customer_name'] as String? ??
        rawData['owner_name'] as String? ?? '';
    return n.trim();
  }

  String get phone {
    final p = rawData['whatsapp_no'] as String? ??
        rawData['phone'] as String? ?? '';
    return p.trim();
  }

  String get customerCode => (rawData['customer_code'] as String? ?? '').trim();
  String get paymentTerm  => (rawData['payment_term']  as String? ?? '').trim();
  String get city         => (rawData['city']          as String? ?? '').trim();
  String get state        => (rawData['state']         as String? ?? '').trim();
  String get status       =>  rawData['status']        as String? ?? 'approved';
  bool   get isSuspended  => status == 'suspended';
}

// ── Lead item model ───────────────────────────────────────────────────────────

class _LeadItem {
  final String key;        // auth_uid for logged-in leads, leads.id for others
  String? leadsId;         // null until a leads row exists for this item
  final String? authUid;
  final String name;
  final String email;
  final String mobile;
  final String source;     // 'logged_in', 'manual', 'csv'
  String status;
  String? assignedTo;      // admin user id

  _LeadItem({
    required this.key,
    this.leadsId,
    this.authUid,
    required this.name,
    required this.email,
    required this.mobile,
    required this.source,
    this.status = 'New',
    this.assignedTo,
  });
}

// ── Admin entry (for assigned-to dropdown) ────────────────────────────────────

class _AdminEntry {
  final String id;
  final String email;
  const _AdminEntry({required this.id, required this.email});
}

// ── Filter ────────────────────────────────────────────────────────────────────

enum _CustFilter {
  approvedCustomers,
  customerOrders,
  cartNotOrdered,
  pendingRegistrations,
  leads,
}

// ── Screen ────────────────────────────────────────────────────────────────────

class AdminCustomerScreen extends StatefulWidget {
  const AdminCustomerScreen({super.key});

  @override
  State<AdminCustomerScreen> createState() => _AdminCustomerScreenState();
}

class _AdminCustomerScreenState extends State<AdminCustomerScreen> {
  List<_CustRow>     _orderRows    = [];
  List<_CustRow>     _cartRows     = [];
  List<_RegRow>      _regRows      = [];
  List<_ApprovedRow> _approvedRows = [];
  List<Map<String, dynamic>> _deletedRows = [];
  bool _deletedExpanded = false;
  List<_LeadItem> _loggedInLeads = [];
  List<_LeadItem> _otherLeads    = [];
  List<_AdminEntry> _admins      = [];
  final Set<String> _expandedLeads = {};
  bool _loading = true;
  _CustFilter _filter = _CustFilter.approvedCustomers;
  final Set<String> _expanded = {};
  // orderId → per-product inquiry status from get_order_item_inquiry_status
  final Map<String, List<Map<String, dynamic>>> _orderItemStatuses = {};
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
    for (final table in ['cart_items', 'orders', 'pharmacy_profiles']) {
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
    _debounce = Timer(
        const Duration(milliseconds: 500), () => _load(showSpinner: false));
  }

  // ── Data ─────────────────────────────────────────────────────────────────────

  Future<void> _load({bool showSpinner = true}) async {
    if (!mounted) return;
    if (showSpinner) setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait<dynamic>([
        client.from('user_profiles').select(),
        // Part A-2: always filter out deleted profiles from active list
        client.from('pharmacy_profiles').select().or('is_deleted.is.null,is_deleted.eq.false'),
        client.from('orders').select().order('created_at', ascending: false),
        client.from('cart_items').select().order('id', ascending: true),
        client.rpc('get_unregistered_users').catchError((_) => <dynamic>[]),
        // Fetch deleted profiles for "Recently Deleted" section
        client.from('pharmacy_profiles').select().eq('is_deleted', true)
            .order('deleted_at', ascending: false).catchError((_) => <dynamic>[]),
      ]);

      final upRows      = results[0] as List;
      final ppRows      = results[1] as List;
      final orderRows   = results[2] as List;
      final cartRows    = results[3] as List;
      final authRows    = results[4] as List;
      final deletedList = results[5] as List;

      // Auth users with no pharmacy_profile (logged-in but unregistered)
      final authMap = <String, Map<String, dynamic>>{};
      for (final r in authRows) {
        final m = Map<String, dynamic>.from(r as Map);
        final uid = m['auth_uid'] as String?;
        if (uid != null) authMap[uid] = m;
      }

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
          userId:        uid,
          name:          _name(up, pp, mo),
          pharmacy:      _pharmacy(up, pp, mo),
          phone:         _phone(up, pp, mo),
          source:        mo['source'] as String? ?? 'website',
          orderId:       mo['id'] as String?,
          orderNumber:   mo['payment_id'] as String?,
          orderStatus:   mo['status'] as String? ?? 'unknown',
          items:         _parseItems(mo['items']),
          total:         (mo['total_amount'] as num?)?.toDouble(),
          placedByAdmin: (mo['placed_by_admin'] as bool?) ?? false,
        ));
      }

      // Cart-only rows — any user with active cart items, regardless of order history.
      // Previously excluded users in orderedUids, which silently dropped authenticated
      // users who had placed any past order but still have unpurchased cart items.
      final carts = <_CustRow>[];
      for (final entry in cartByUser.entries) {
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
                  mrp:            (ci['mrp'] as num?)?.toDouble(),
                  gstPercent:     (ci['gst_percent'] as num?)?.toInt(),
                  packSize:       ci['pack_size'] as String?,
                  addedBy:        ci['added_by'] as String? ?? 'customer',
                  removedByAdmin: (ci['removed_by_admin'] as bool?) ?? false,
                ))
            .where((i) => i.name.isNotEmpty)
            .toList();

        final activeItems  = allItems.where((i) => !i.removedByAdmin).toList();
        final removedItems = allItems.where((i) =>  i.removedByAdmin).toList();
        if (activeItems.isEmpty) continue;

        carts.add(_CustRow(
          userId:       uid,
          name:         (up == null && pp == null)
              ? _nameFromAuth(authMap[uid])
              : _name(up, pp, null),
          pharmacy:     _pharmacy(up, pp, null),
          phone:        (up == null && pp == null)
              ? (authMap[uid]?['phone'] as String? ?? '')
              : _phone(up, pp, null),
          source:       'cart_only',
          orderId:      null,
          orderStatus:  'cart_only',
          items:        activeItems,
          removedItems: removedItems,
          total:        null,
          netPayable:   _computeNetPayable(activeItems),
        ));
      }

      // Pending registrations (approved != true)
      final regs = <_RegRow>[];
      // Approved customers (approved == true, includes suspended)
      final approved = <_ApprovedRow>[];

      for (final p in ppRows) {
        final m = Map<String, dynamic>.from(p as Map);
        if (m['approved'] == true) {
          approved.add(_ApprovedRow.fromMap(m));
        } else {
          regs.add(_RegRow.fromMap(m));
        }
      }

      regs.sort((a, b) {
        if (a.createdAt == null && b.createdAt == null) return 0;
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      approved.sort((a, b) {
        final aAt = a.rawData['approved_at'] as String?;
        final bAt = b.rawData['approved_at'] as String?;
        if (aAt == null && bAt == null) return 0;
        if (aAt == null) return 1;
        if (bAt == null) return -1;
        return bAt.compareTo(aAt);
      });

      final deleted = deletedList
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();

      if (mounted) {
        setState(() {
          _orderRows    = orders;
          _cartRows     = carts;
          _regRows      = regs;
          _approvedRows = approved;
          _deletedRows  = deleted;
          _loading      = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showToast(context, 'Failed to load: $e', isError: true);
      }
    }
    _loadLeads();
  }

  Future<void> _loadLeads() async {
    try {
      final client = Supabase.instance.client;

      // Fetch all leads rows
      final leadsRows = await client.from('leads').select();
      // Build a quick lookup: auth_uid or id → lead row
      final leadsByAuthUid = <String, Map<String, dynamic>>{};
      final otherLeadsRaw  = <Map<String, dynamic>>[];
      for (final r in leadsRows as List) {
        final m = Map<String, dynamic>.from(r as Map);
        final src = (m['source'] as String?) ?? 'manual';
        final uid = m['auth_uid'] as String?;
        if (src == 'logged_in' && uid != null) {
          leadsByAuthUid[uid] = m;
        } else {
          otherLeadsRaw.add(m);
        }
      }

      // Fetch admins list
      final adminsRows = await client.from('admins').select('id, email');
      final adminsList = (adminsRows as List).map((r) {
        final m = Map<String, dynamic>.from(r as Map);
        return _AdminEntry(
          id:    m['id'] as String,
          email: m['email'] as String,
        );
      }).toList();

      // Logged-in section: pharmacy_profiles with approved=false
      // + auth users with no profile (from RPC)
      final seen = <String>{};
      final loggedIn = <_LeadItem>[];

      // From pharmacy_profiles (unapproved)
      for (final reg in _regRows) {
        final uid = reg.rawData['user_id'] as String? ?? reg.id;
        if (seen.contains(uid)) continue;
        seen.add(uid);
        final lr = leadsByAuthUid[uid];
        loggedIn.add(_LeadItem(
          key:        uid,
          leadsId:    lr?['id'] as String?,
          authUid:    uid,
          name:       reg.fullName.isNotEmpty ? reg.fullName : reg.businessName,
          email:      reg.email ?? '',
          mobile:     reg.phone,
          source:     'logged_in',
          status:     (lr?['status'] as String?) ?? 'New',
          assignedTo: lr?['assigned_to'] as String?,
        ));
      }

      // From RPC: users with no pharmacy_profile
      try {
        final rpcRows = await client.rpc('get_unregistered_users');
        for (final r in rpcRows as List) {
          final m = Map<String, dynamic>.from(r as Map);
          final uid = m['auth_uid'] as String? ?? '';
          if (uid.isEmpty || seen.contains(uid)) continue;
          seen.add(uid);
          final lr = leadsByAuthUid[uid];
          loggedIn.add(_LeadItem(
            key:        uid,
            leadsId:    lr?['id'] as String?,
            authUid:    uid,
            name:       (m['full_name'] as String?) ?? '',
            email:      (m['email'] as String?) ?? '',
            mobile:     (m['phone'] as String?) ?? '',
            source:     'logged_in',
            status:     (lr?['status'] as String?) ?? 'New',
            assignedTo: lr?['assigned_to'] as String?,
          ));
        }
      } catch (_) {}

      // Other leads (manual + csv)
      final others = otherLeadsRaw.map((m) => _LeadItem(
        key:        m['id'] as String,
        leadsId:    m['id'] as String,
        name:       (m['name'] as String?) ?? '',
        email:      (m['email'] as String?) ?? '',
        mobile:     (m['mobile'] as String?) ?? '',
        source:     (m['source'] as String?) ?? 'manual',
        status:     (m['status'] as String?) ?? 'New',
        assignedTo: m['assigned_to'] as String?,
      )).toList();

      if (mounted) {
        setState(() {
          _loggedInLeads = loggedIn;
          _otherLeads    = others;
          _admins        = adminsList;
        });
      }
    } catch (_) {}
  }

  // ── Net payable helpers ────────────────────────────────────────────────────

  static double _computeNetPayable(List<_ItemLine> items) {
    if (items.isEmpty) return 0.0;
    final mrpSum = items.fold(0.0, (s, i) => s + (i.mrp ?? 0) * i.qty);
    final discPct = cartDiscountPercent(mrpSum);
    final groupMrp = <int, double>{};
    for (final item in items) {
      final rate = item.gstPercent ?? 12;
      groupMrp[rate] = (groupMrp[rate] ?? 0) + (item.mrp ?? 0) * item.qty;
    }
    double total = 0.0;
    for (final entry in groupMrp.entries) {
      final taxable = entry.value * (1 - discPct / 100);
      total += taxable * (1 + entry.key / 100);
    }
    return total + cartDeliveryFee(mrpSum);
  }

  // ── Profile helpers ────────────────────────────────────────────────────────

  static String _name(Map? up, Map? pp, Map? order) {
    final n = (up?['full_name'] ?? pp?['customer_name'] ?? pp?['owner_name']) as String?;
    if (n != null && n.trim().isNotEmpty) return n.trim();
    return order?['pharmacy_name'] as String? ?? 'Unknown';
  }

  static String _pharmacy(Map? up, Map? pp, Map? order) {
    final biz = (up?['business_name'] ?? pp?['pharmacy_name']) as String?;
    if (biz != null && biz.trim().isNotEmpty) return biz.trim();
    return order?['pharmacy_name'] as String? ?? '';
  }

  static String _phone(Map? up, Map? pp, Map? order) {
    final ph = (up?['phone'] ?? pp?['whatsapp_no'] ?? pp?['phone']) as String?;
    if (ph != null && ph.trim().isNotEmpty) return ph.trim();
    return order?['phone'] as String? ?? '';
  }

  static String _nameFromAuth(Map? auth) {
    if (auth == null) return 'Guest';
    final name = auth['full_name'] as String?;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    final email = auth['email'] as String?;
    if (email != null && email.trim().isNotEmpty) return email.trim();
    final phone = auth['phone'] as String?;
    if (phone != null && phone.trim().isNotEmpty) return phone.trim();
    return 'Guest';
  }

  static List<_ItemLine> _parseItems(dynamic items) {
    if (items == null) return [];
    try {
      return (items as List)
          .map((e) {
            final m = Map<String, dynamic>.from(e as Map);
            return _ItemLine(
              name:      m['product_name'] as String? ?? '',
              qty:       (m['quantity'] as num?)?.toInt() ?? 1,
              price:     (m['price'] as num?)?.toDouble(),
              productId: m['product_id']?.toString(),
            );
          })
          .where((i) => i.name.isNotEmpty)
          .toList();
    } catch (e) {
      RenderLog.write('parse_items_error', e.toString());
      return [];
    }
  }

  // ── Active list ────────────────────────────────────────────────────────────

  List<_CustRow> get _activeCust {
    switch (_filter) {
      case _CustFilter.customerOrders:       return _orderRows;
      case _CustFilter.cartNotOrdered:       return _cartRows;
      case _CustFilter.pendingRegistrations:
      case _CustFilter.approvedCustomers:
      case _CustFilter.leads:                return [];
    }
  }

  bool get _isRegView      => _filter == _CustFilter.pendingRegistrations;
  bool get _isApprovedView => _filter == _CustFilter.approvedCustomers;
  bool get _isLeadsView    => _filter == _CustFilter.leads;

  // ── Approve / Reject registrations ────────────────────────────────────────

  Future<void> _approveReg(_RegRow row) async {
    await Supabase.instance.client.from('pharmacy_profiles').update({
      'approved': true,
      'status': 'approved',
      'approved_at': DateTime.now().toUtc().toIso8601String(),
      'approved_by': 'admin',
    }).eq('id', row.id);
    _notifyRegistration(row, isApproved: true);
    _load();
  }

  Future<void> _rejectReg(_RegRow row) async {
    await Supabase.instance.client
        .from('pharmacy_profiles')
        .update({'approved': false, 'status': 'rejected'})
        .eq('id', row.id);
    _notifyRegistration(row, isApproved: false);
    _load();
  }

  void _notifyRegistration(_RegRow row, {required bool isApproved}) {
    Supabase.instance.client.functions
        .invoke(
          'notify-registration',
          body: {
            'action': isApproved ? 'approve' : 'reject',
            'pharmacyName': row.businessName,
            'email': row.email,
            'whatsappNo': row.whatsappNumber,
          },
        )
        .then((_) {})
        .catchError((_) {});
  }

  // ── Suspend / Reactivate approved customers ────────────────────────────────

  Future<void> _suspendCustomer(_ApprovedRow row) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Suspend Customer',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(
          'Suspend ${row.pharmacyName.isNotEmpty ? row.pharmacyName : row.customerName}? '
          'They will be blocked from placing orders until reactivated.',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('Suspend'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client
          .from('pharmacy_profiles')
          .update({'status': 'suspended'})
          .eq('id', row.id);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) {
        showToast(context, 'Suspend failed: $e', isError: true);
      }
    }
  }

  Future<void> _reactivateCustomer(_ApprovedRow row) async {
    try {
      await Supabase.instance.client
          .from('pharmacy_profiles')
          .update({'status': 'approved'})
          .eq('id', row.id);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) {
        showToast(context, 'Reactivate failed: $e', isError: true);
      }
    }
  }

  Future<void> _editCustomer(_ApprovedRow row) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CustomerEditDialog(row: row),
    );
    if (saved == true) _load(showSpinner: false);
  }

  // Part A-3 / Part C-1: delete customer
  Future<void> _deleteCustomer(_ApprovedRow row) async {
    final displayName = row.pharmacyName.isNotEmpty ? row.pharmacyName : row.customerName;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Delete $displayName?',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                color: Color(0xFF111827))),
        content: const Text(
          'This will remove their login access and all registration data. '
          'They must re-register to use mediBO.',
          style: TextStyle(fontSize: 13, color: Color(0xFF374151)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final client    = Supabase.instance.client;
      final adminEmail = client.auth.currentUser?.email ?? 'admin';
      // Part A-3: mark deleted with full snapshot
      await client.from('pharmacy_profiles').update({
        'is_deleted':       true,
        'deleted_at':       DateTime.now().toUtc().toIso8601String(),
        'deleted_by':       adminEmail,
        'deleted_snapshot': row.rawData,
      }).eq('id', row.id);
      // Supabase Admin API: DELETE /auth/v1/admin/users/{user_id}
      final uid = row.rawData['user_id'] as String?;
      if (uid != null) {
        try {
          await client.functions.invoke(
            'admin-user-actions',
            body: {'action': 'delete_user', 'user_id': uid},
          );
        } catch (_) {} // non-fatal — profile already marked deleted in DB
      }
      _load(showSpinner: false);
      if (mounted) {
        showToast(context, 'Customer deleted.', duration: const Duration(seconds: 3));
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Delete failed: $e', isError: true);
      }
    }
  }

  // Part A-4 / Part C-2: restore deleted customer
  Future<void> _restoreCustomer(Map<String, dynamic> deletedRow) async {
    final snap       = deletedRow['deleted_snapshot'] as Map<String, dynamic>? ?? deletedRow;
    final pharmacy   = snap['pharmacy_name'] as String? ?? '';
    final email      = snap['email'] as String? ?? deletedRow['email'] as String? ?? '';
    final displayName = pharmacy.isNotEmpty ? pharmacy
        : (snap['customer_name'] as String? ?? snap['owner_name'] as String? ?? 'this customer');

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Restore $displayName?',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                color: Color(0xFF111827))),
        content: Text(
          email.isNotEmpty
              ? 'This will restore their profile. A magic link will be sent to $email so they can log back in.'
              : 'This will restore their profile to the active customer list.',
          style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final client = Supabase.instance.client;
      // Part A-4: clear deleted flags
      await client.from('pharmacy_profiles').update({
        'is_deleted':       false,
        'deleted_at':       null,
        'deleted_by':       null,
        'deleted_snapshot': null,
      }).eq('id', deletedRow['id'] as String);
      // Supabase Admin API: POST /auth/v1/admin/generate-link { type: 'magiclink', email }
      if (email.isNotEmpty) {
        try {
          await client.functions.invoke(
            'admin-user-actions',
            body: {'action': 'send_magic_link', 'email': email},
          );
        } catch (_) {} // non-fatal — profile already restored in DB
      }
      _load(showSpinner: false);
      if (mounted) {
        showToast(context, email.isNotEmpty
            ? 'Customer restored. Magic link sent to $email.'
            : 'Customer restored.');
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Restore failed: $e', isError: true);
      }
    }
  }

  // ── Order status ───────────────────────────────────────────────────────────

  Future<void> _updateStatus(String orderId, String status) async {
    try {
      await Supabase.instance.client
          .from('orders')
          .update({'status': status})
          .eq('id', orderId);
      RenderLog.write('order_status_written', 'orderId:$orderId status:$status');
      _load();
    } catch (e) {
      if (mounted) {
        showToast(context, 'Update failed: $e', isError: true);
      }
    }
  }

  Future<void> _adminSoftRemoveItem(int itemId) async {
    try {
      await Supabase.instance.client
          .from('cart_items')
          .update({
            'removed_by_admin': true,
            'removed_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', itemId);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) {
        showToast(context, 'Remove failed: $e', isError: true);
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

  void _toggleExpand(String key, {VoidCallback? onExpand}) {
    setState(() {
      if (_expanded.contains(key)) {
        _expanded.remove(key);
      } else {
        _expanded.add(key);
        onExpand?.call();
      }
    });
  }

  Future<void> _fetchOrderItemStatus(String orderId) async {
    try {
      final rows = await Supabase.instance.client.rpc(
        'get_order_item_inquiry_status',
        params: {'p_order_id': orderId},
      ) as List;
      if (mounted) {
        setState(() {
          _orderItemStatuses[orderId] =
              rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
        });
        RenderLog.write('order_item_status', 'orderId:$orderId count:${rows.length}');
      }
    } catch (e) {
      RenderLog.write('order_item_status_error', 'orderId:$orderId err:$e');
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final isDesktop = box.maxWidth >= 900;

      if (_loading) {
        return const Center(
          child: CircularProgressIndicator(
              color: Color(0xFF1B7A43), strokeWidth: 2),
        );
      }

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

  Widget _buildScrollContent(bool isDesktop) {
    // Leads tab
    if (_isLeadsView) return _buildLeadsContent(isDesktop);
    // Approved customers view
    if (_isApprovedView) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_approvedRows.isEmpty)
            _ssvEmptyState('0 approved customers')
          else ...[
            if (isDesktop) _buildApprovedTableHeader(),
            ..._approvedRows.map((r) =>
                isDesktop ? _buildDesktopApprovedRow(r) : _buildMobileApprovedCard(r)),
          ],
          const SizedBox(height: 32),
          // Part C-2: collapsible Recently Deleted section
          _buildDeletedSection(isDesktop),
          const SizedBox(height: 32),
        ],
      );
    }

    // Pending registrations
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

    // Customer orders / cart
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
        if (_filter == _CustFilter.cartNotOrdered)
          _buildCartTotalsFooter(isDesktop),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _ssvEmptyState(String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: const Icon(Icons.inbox_outlined, size: 28, color: Color(0xFFD1D5DB)),
            ),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF9CA3AF))),
          ],
        ),
      ),
    );
  }

  // ── Header with 4 tabs ─────────────────────────────────────────────────────

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Customer Dashboard',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF111827))),
                SizedBox(height: 2),
                Text('Manage pharmacy accounts and registrations',
                    style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
              ],
            ),
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
            _tab(_CustFilter.approvedCustomers,
                'Customers (${_approvedRows.length})'),
            const SizedBox(width: 4),
            _tab(_CustFilter.customerOrders,
                'Customer Orders (${_orderRows.length})'),
            const SizedBox(width: 4),
            _tab(_CustFilter.cartNotOrdered,
                'Cart (${_cartRows.length})'),
            const SizedBox(width: 4),
            _tab(_CustFilter.pendingRegistrations,
                'Pending Approval (${_regRows.length})'),
            const SizedBox(width: 4),
            _tab(_CustFilter.leads,
                'Leads (${_loggedInLeads.length + _otherLeads.length})'),
          ]),
        ),
      ]),
    );
  }

  // Part D: MouseRegion for pointer cursor on all tabs
  // Part E: pill/chip style tabs — active = green fill, inactive = grey outline
  Widget _tab(_CustFilter f, String label) {
    final active = _filter == f;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
          setState(() {
            _filter = f;
            _expanded.clear();
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF1B7A43) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? Colors.white : const Color(0xFF6B7280),
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CUSTOMER ORDERS / CART views (unchanged)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildCustTableHeader() {
    final isCart = _filter == _CustFilter.cartNotOrdered;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        _th('CUSTOMER', flex: 4),
        _th('PHARMACY', flex: 3),
        _th('PHONE', flex: 2),
        _th('SOURCE', flex: 2),
        if (isCart) ...[
          _th('ITEMS', flex: 1),
          _th('VALUE', flex: 2),
          const SizedBox(width: 32),
        ] else ...[
          _th('ORDER ID', flex: 2),
          _th('CONFIRMATION', flex: 3),
          _th('ACTION', flex: 2),
          const SizedBox(width: 32),
        ],
      ]),
    );
  }

  Widget _buildDesktopCustRow(_CustRow row) {
    final key        = row.orderId ?? row.userId;
    final isExpanded = _expanded.contains(key);
    final isCart     = _filter == _CustFilter.cartNotOrdered;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => _toggleExpand(key,
            onExpand: row.orderId != null ? () => _fetchOrderItemStatus(row.orderId!) : null),
        mouseCursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          child: Row(children: [
            Expanded(
                flex: 4,
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
              child: _SourceBadge(source: row.source),
            ),
            if (isCart) ...[
              Expanded(
                flex: 1,
                child: Text('${row.items.length}',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF374151))),
              ),
              Expanded(
                flex: 2,
                child: Text('₹${row.netPayable.toStringAsFixed(0)}',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1B7A43))),
              ),
            ] else ...[
              Expanded(
                  flex: 2,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        row.orderNumber ?? '—',
                        style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF6B7280),
                            fontFamily: 'monospace'),
                      ),
                      if (row.placedByAdmin) ...[
                        const SizedBox(height: 2),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('by admin',
                              style: TextStyle(
                                  fontSize: 9,
                                  color: Color(0xFF92400E),
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ],
                  )),
              Expanded(
                  flex: 3,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {}, // absorb tap so Accept/Reject don't toggle row expand
                    child: _ConfirmActions(row: row, onUpdate: _updateStatus),
                  )),
              Expanded(
                  flex: 2,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: _ActionCell(row: row, onImport: () => _openImport(row)),
                  )),
            ],
            SizedBox(
              width: 32,
              child: AnimatedRotation(
                turns: isExpanded ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more,
                    size: 18, color: Color(0xFF6B7280)),
              ),
            ),
          ]),
        ),
      ),
      if (isExpanded) _buildExpandedItems(row, isDesktop: true),
    ]);
  }

  Widget _buildMobileCustCard(_CustRow row) {
    final key        = row.orderId ?? row.userId;
    final isExpanded = _expanded.contains(key);
    final isCart     = _filter == _CustFilter.cartNotOrdered;
    final showOrderCols = _filter == _CustFilter.customerOrders;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => _toggleExpand(key,
            onExpand: row.orderId != null ? () => _fetchOrderItemStatus(row.orderId!) : null),
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
                const SizedBox(width: 6),
                _SourceBadge(source: row.source),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more,
                      size: 18, color: Color(0xFF9CA3AF)),
                ),
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
              if (isCart && row.items.isNotEmpty) ...[
                const SizedBox(height: 5),
                Row(children: [
                  const Icon(Icons.shopping_cart_outlined,
                      size: 12, color: Color(0xFF9CA3AF)),
                  const SizedBox(width: 4),
                  Text(
                    '${row.items.length} item${row.items.length == 1 ? '' : 's'}'
                    '  ·  ₹${row.netPayable.toStringAsFixed(0)}',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1B7A43)),
                  ),
                ]),
              ],
              if (row.orderId != null || row.orderNumber != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.receipt_outlined,
                      size: 13, color: Color(0xFF9CA3AF)),
                  const SizedBox(width: 4),
                  Text(
                      row.orderNumber ?? '—',
                      style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF6B7280),
                          fontFamily: 'monospace')),
                ]),
              ],
              if (showOrderCols) ...[
                const SizedBox(height: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: _ConfirmActions(row: row, onUpdate: _updateStatus),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: _ActionCell(row: row, onImport: () => _openImport(row)),
                ),
              ],
            ]),
          ),
          if (isExpanded) ...[
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            _buildExpandedItems(row, isDesktop: false),
          ],
        ]),
      ),
    );
  }

  Widget _itemInquiryBadge(String? status, String? supplier) {
    if (status == null || status == 'Not in inquiry') {
      return const Text('—', style: TextStyle(fontSize: 10, color: Color(0xFF9CA3AF)));
    }
    final lower = status.toLowerCase();
    final Color bg;
    final Color fg;
    final String label;
    if (lower.contains('no supplier')) {
      bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B);
      label = 'No supplier available';
    } else if (lower == 'available') {
      bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46);
      label = supplier != null && supplier.isNotEmpty ? 'Supplier: $supplier' : 'Available';
    } else if (lower.contains('confirmation') || lower.contains('pending')) {
      bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E);
      label = supplier != null && supplier.isNotEmpty ? 'Awaiting $supplier' : 'Confirmation pending';
    } else if (lower.contains('out of stock')) {
      bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B);
      label = 'Out of stock';
    } else {
      bg = const Color(0xFFF3F4F6); fg = const Color(0xFF374151);
      label = status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  Widget _buildExpandedItems(_CustRow row, {required bool isDesktop}) {
    final lpad = isDesktop ? 28.0 : 16.0;
    final rpad = isDesktop ? 28.0 : 16.0;

    if (row.source == 'whatsapp' && row.items.isEmpty) {
      return Container(
        color: const Color(0xFFF9FAFB),
        padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
        child: const Text(
          'WhatsApp order items unavailable.',
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
    final statuses = row.orderId != null
        ? (_orderItemStatuses[row.orderId!] ?? <Map<String, dynamic>>[])
        : <Map<String, dynamic>>[];
    RenderLog.write('order_items_expanded',
        'orderId:${row.orderId ?? "?"}:items:${row.items.length}:statuses:${statuses.length}');
    // Log per-item resolved status for verification
    for (final item in row.items) {
      if (item.productId != null) {
        final pid = int.tryParse(item.productId!);
        final s = statuses.cast<Map<String, dynamic>?>().firstWhere(
          (s) => s != null && (s['product_id'] as num?)?.toInt() == pid,
          orElse: () => null,
        );
        RenderLog.write('order_item_resolved',
            '${item.name}:pid=${item.productId}:status=${s?['current_status'] ?? "no_match"}');
      } else {
        RenderLog.write('order_item_resolved', '${item.name}:pid=null');
      }
    }

    return Container(
      color: const Color(0xFFF9FAFB),
      padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Ordered-by header
        Row(children: [
          const Icon(Icons.person_outline, size: 12, color: Color(0xFF9CA3AF)),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'Ordered by: ${row.name}${row.pharmacy.isNotEmpty ? ' · ${row.pharmacy}' : ''}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        const SizedBox(height: 8),
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
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF9CA3AF)))),
          SizedBox(
              width: 44,
              child: Text('Qty',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF9CA3AF)))),
          SizedBox(
              width: 76,
              child: Text('Price',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF9CA3AF)))),
          Expanded(
              flex: 4,
              child: Text('Status',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF9CA3AF)))),
        ]),
        const SizedBox(height: 4),
        ...row.items.map((item) {
          Map<String, dynamic>? iqStatus;
          if (item.productId != null) {
            final pid = int.tryParse(item.productId!);
            iqStatus = statuses.cast<Map<String, dynamic>?>().firstWhere(
              (s) => s != null && (s['product_id'] as num?)?.toInt() == pid,
              orElse: () => null,
            );
          }
          final currentStatus   = iqStatus?['current_status'] as String?;
          final currentSupplier = iqStatus?['current_supplier'] as String?;
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(
                  flex: 5,
                  child: Text(item.name,
                      style: const TextStyle(fontSize: 12, color: Color(0xFF374151)))),
              SizedBox(
                  width: 44,
                  child: Text('×${item.qty}',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
              SizedBox(
                  width: 76,
                  child: Text(
                      item.price != null ? '₹${item.price!.toStringAsFixed(2)}' : '—',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF374151)))),
              Expanded(
                flex: 4,
                child: _itemInquiryBadge(currentStatus, currentSupplier),
              ),
            ]),
          );
        }),
      ]),
    );
  }

  Widget _buildCartExpandedItems(_CustRow row,
      {required double lpad, required double rpad}) {
    return Container(
      color: const Color(0xFFF9FAFB),
      padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
      child: LayoutBuilder(builder: (ctx, constraints) {
        final isWide = constraints.maxWidth > 560;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(
              'Cart Items (${row.items.length})',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF374151)),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _adminAddCartItem(row.userId),
              icon: const Icon(Icons.add, size: 14),
              label: const Text('Add Item', style: TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF1B7A43),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ]),
          const SizedBox(height: 6),
          if (row.items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text('No active items.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
            )
          else ...[
            if (isWide) ...[
              Row(children: const [
                Expanded(
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
                    width: 130,
                    child: Text('Pack size',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF9CA3AF)))),
                SizedBox(
                    width: 80,
                    child: Text('MRP',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF9CA3AF)))),
                SizedBox(
                    width: 120,
                    child: Text('Added/Removed by',
                        maxLines: 2,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF9CA3AF)))),
                SizedBox(width: 72),
              ]),
              const SizedBox(height: 4),
              ...row.items.map((item) => Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                      Expanded(
                          child: Text(item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF374151)))),
                      SizedBox(
                          width: 44,
                          child: Text('×${item.qty}',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF6B7280)))),
                      SizedBox(
                          width: 130,
                          child: Text(
                              (item.packSize?.isNotEmpty == true)
                                  ? item.packSize!
                                  : '—',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF6B7280)))),
                      SizedBox(
                          width: 80,
                          child: Text(
                              item.mrp != null
                                  ? '₹${item.mrp!.toStringAsFixed(0)}'
                                  : '—',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF374151)))),
                      SizedBox(
                          width: 120,
                          child: _addedByBadge(item.addedBy)),
                      SizedBox(
                        width: 72,
                        child: item.id != null
                            ? TextButton(
                                onPressed: () =>
                                    _adminSoftRemoveItem(item.id!),
                                style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFFDC2626),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  minimumSize: Size.zero,
                                ),
                                child: const Text('Remove',
                                    style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600)),
                              )
                            : const SizedBox(),
                      ),
                    ]),
                  )),
            ] else ...[
              ...row.items.map((item) => Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Row(children: [
                        Expanded(
                            child: Text(item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF374151)))),
                        if (item.id != null)
                          GestureDetector(
                            onTap: () => _adminSoftRemoveItem(item.id!),
                            child: const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Text('Remove',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFDC2626))),
                            ),
                          ),
                      ]),
                      const SizedBox(height: 2),
                      Row(children: [
                        Text('×${item.qty}',
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF6B7280))),
                        const Text('  ·  ',
                            style: TextStyle(
                                fontSize: 11, color: Color(0xFFD1D5DB))),
                        Text(
                            (item.packSize?.isNotEmpty == true)
                                ? item.packSize!
                                : '—',
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF6B7280))),
                        const Text('  ·  ',
                            style: TextStyle(
                                fontSize: 11, color: Color(0xFFD1D5DB))),
                        Text(
                            item.mrp != null
                                ? '₹${item.mrp!.toStringAsFixed(0)}'
                                : '—',
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFF374151))),
                        const SizedBox(width: 8),
                        _addedByBadge(item.addedBy),
                      ]),
                    ]),
                  )),
            ],
          ],
          if (row.removedItems.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            const SizedBox(height: 8),
            Text(
              'Removed by admin (${row.removedItems.length})',
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF9CA3AF)),
            ),
            const SizedBox(height: 4),
            if (isWide)
              ...row.removedItems.map((item) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      Expanded(
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
                          width: 130,
                          child: Text(
                              (item.packSize?.isNotEmpty == true)
                                  ? item.packSize!
                                  : '—',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFFD1D5DB)))),
                      SizedBox(
                          width: 80,
                          child: Text(
                              item.mrp != null
                                  ? '₹${item.mrp!.toStringAsFixed(0)}'
                                  : '—',
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFFD1D5DB)))),
                      const SizedBox(
                          width: 120,
                          child: _RemovedByBadge()),
                      const SizedBox(width: 72),
                    ]),
                  ))
            else
              ...row.removedItems.map((item) => Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      Expanded(
                          child: Text(item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFD1D5DB),
                                  decoration: TextDecoration.lineThrough,
                                  decorationColor: Color(0xFFD1D5DB)))),
                      const SizedBox(width: 8),
                      const _RemovedByBadge(),
                    ]),
                  )),
          ],
        ]);
      }),
    );
  }

  static Widget _addedByBadge(String addedBy) {
    if (addedBy == 'admin') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF08A),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFFFBBF24)),
        ),
        child: const Text('mediBO',
            style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: Color(0xFF92400E))),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFD1D5DB)),
      ),
      child: const Text('Self',
          style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: Color(0xFF6B7280))),
    );
  }

  Widget _buildCartTotalsFooter(bool isDesktop) {
    final totalItems = _cartRows.fold(0, (s, r) => s + r.items.length);
    final totalValue = _cartRows.fold(0.0, (s, r) => s + r.netPayable);

    if (isDesktop) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        decoration: const BoxDecoration(
          color: Color(0xFFF0FDF4),
          border: Border(
              top: BorderSide(color: Color(0xFFBBF7D0), width: 2)),
        ),
        child: Row(children: [
          Expanded(
              flex: 4,
              child: Text(
                  'Total (${_cartRows.length} cart${_cartRows.length == 1 ? '' : 's'})',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1B7A43)))),
          const Expanded(flex: 3, child: SizedBox()),
          const Expanded(flex: 2, child: SizedBox()),
          const Expanded(flex: 2, child: SizedBox()),
          Expanded(
              flex: 1,
              child: Text('$totalItems',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827)))),
          Expanded(
              flex: 2,
              child: Text('₹${totalValue.toStringAsFixed(0)}',
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1B7A43)))),
          const SizedBox(width: 32),
        ]),
      );
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBBF7D0), width: 1.5),
      ),
      child: Row(children: [
        Expanded(
          child: Text(
            'Total (${_cartRows.length} cart${_cartRows.length == 1 ? '' : 's'})',
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1B7A43)),
          ),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('$totalItems items',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827))),
          Text('₹${totalValue.toStringAsFixed(0)}',
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1B7A43))),
        ]),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PENDING REGISTRATIONS view  (Tasks 1 + 2)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildRegTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        _th('CUSTOMER NAME', flex: 3),
        _th('PHARMACY', flex: 3),
        _th('PHONE', flex: 2),
        _th('CODE', flex: 2),
        _th('PAYMENT', flex: 2),
        _th('CITY / STATE', flex: 2),
        _th('APPROVAL', flex: 3),
        const SizedBox(width: 32),
      ]),
    );
  }

  // Task 2: entire row is now an InkWell; Approve/Reject (inner InkWells) absorb tap naturally.
  Widget _buildDesktopRegRow(_RegRow row) {
    final isExpanded = _expanded.contains(row.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => _toggleExpand(row.id),
        mouseCursor: SystemMouseCursors.click,
        child: Container(
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
                child: Text(
                    row.customerId?.isNotEmpty == true ? row.customerId! : '—',
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
            // Approve/Reject buttons (inner InkWells — absorb tap, don't propagate to outer InkWell)
            Expanded(
                flex: 3,
                child: _RegApproveActions(
                    id: row.id,
                    onApprove: () => _approveReg(row),
                    onReject:  () => _rejectReg(row))),
            // Rotating chevron
            SizedBox(
              width: 32,
              child: AnimatedRotation(
                turns: isExpanded ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more,
                    size: 18, color: Color(0xFF6B7280)),
              ),
            ),
          ]),
        ),
      ),
      // Task 1: dynamic all-columns dropdown
      if (isExpanded) _buildDynamicDetails(row.rawData, lpad: 44, rpad: 28),
    ]);
  }

  // Task 2: entire card is tappable; chevron moved to header row.
  Widget _buildMobileRegCard(_RegRow row) {
    final isExpanded = _expanded.contains(row.id);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _toggleExpand(row.id),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                // Name + pending badge + rotating chevron
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
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more,
                        size: 18, color: Color(0xFF9CA3AF)),
                  ),
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
                const SizedBox(height: 12),
                // Approve/Reject (inner InkWells — stop propagation to outer InkWell)
                _RegApproveActions(
                    id: row.id,
                    onApprove: () => _approveReg(row),
                    onReject:  () => _rejectReg(row)),
              ]),
            ),
            // Task 1: dynamic all-columns dropdown
            if (isExpanded) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _buildDynamicDetails(row.rawData, lpad: 16, rpad: 16),
            ],
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // APPROVED CUSTOMERS view  (Tasks 3 + 4)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildApprovedTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        _th('PHARMACY', flex: 4),
        _th('CONTACT', flex: 3),
        _th('PHONE', flex: 2),
        _th('CODE', flex: 2),
        _th('CITY', flex: 2),
        _th('STATUS', flex: 2),
        const SizedBox(width: 230), // actions column (Edit + Suspend + Delete)
        const SizedBox(width: 32),  // chevron
      ]),
    );
  }

  Widget _buildDesktopApprovedRow(_ApprovedRow row) {
    final isExpanded = row.id.let((id) => _expanded.contains(id));
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => _toggleExpand(row.id),
        mouseCursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          child: Row(children: [
            Expanded(
                flex: 4,
                child: Text(
                    row.pharmacyName.isNotEmpty ? row.pharmacyName : '—',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827)),
                    overflow: TextOverflow.ellipsis)),
            Expanded(
                flex: 3,
                child: Text(
                    row.customerName.isNotEmpty ? row.customerName : '—',
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
                child: Text(
                    row.customerCode.isNotEmpty ? row.customerCode : '—',
                    style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF374151),
                        fontFamily: 'monospace'))),
            Expanded(
                flex: 2,
                child: Text(
                    [row.city, row.state]
                        .where((s) => s.isNotEmpty)
                        .join(', ')
                        .let((s) => s.isNotEmpty ? s : '—'),
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280)),
                    overflow: TextOverflow.ellipsis)),
            Expanded(
              flex: 2,
              child: _CustomerStatusBadge(status: row.status),
            ),
            // Edit + Suspend/Reactivate + Delete actions (inner InkWells — absorb tap)
            SizedBox(
              width: 230,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _actionBtn('Edit', const Color(0xFF1B7A43),
                    () => _editCustomer(row)),
                const SizedBox(width: 6),
                _actionBtn(
                  row.isSuspended ? 'Reactivate' : 'Suspend',
                  row.isSuspended
                      ? const Color(0xFF1B7A43)
                      : const Color(0xFFD97706),
                  () => row.isSuspended
                      ? _reactivateCustomer(row)
                      : _suspendCustomer(row),
                ),
                const SizedBox(width: 6),
                _actionBtn('Delete', const Color(0xFFDC2626),
                    () => _deleteCustomer(row)),
              ]),
            ),
            // Rotating chevron
            SizedBox(
              width: 32,
              child: AnimatedRotation(
                turns: isExpanded ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more,
                    size: 18, color: Color(0xFF6B7280)),
              ),
            ),
          ]),
        ),
      ),
      if (isExpanded) _buildDynamicDetails(row.rawData, lpad: 44, rpad: 28),
    ]);
  }

  Widget _buildMobileApprovedCard(_ApprovedRow row) {
    final isExpanded = _expanded.contains(row.id);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: row.isSuspended
              ? const Color(0xFFFECACA)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _toggleExpand(row.id),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                // Pharmacy name + status badge + chevron
                Row(children: [
                  Expanded(
                      child: Text(
                          row.pharmacyName.isNotEmpty
                              ? row.pharmacyName
                              : row.customerName.isNotEmpty
                                  ? row.customerName
                                  : 'Unknown',
                          style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF111827)),
                          overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  _CustomerStatusBadge(status: row.status),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more,
                        size: 18, color: Color(0xFF9CA3AF)),
                  ),
                ]),
                if (row.customerName.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(row.customerName,
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
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 4, children: [
                  if (row.customerCode.isNotEmpty)
                    _mobileField('Code', row.customerCode),
                  if (row.paymentTerm.isNotEmpty)
                    _mobileField('Payment', row.paymentTerm),
                  if (row.city.isNotEmpty)
                    _mobileField(
                        'City',
                        [row.city, row.state]
                            .where((s) => s.isNotEmpty)
                            .join(', ')),
                ]),
                const SizedBox(height: 12),
                // Action buttons (inner InkWells — absorb tap)
                Wrap(spacing: 8, runSpacing: 6, children: [
                  _actionBtn('Edit', const Color(0xFF1B7A43),
                      () => _editCustomer(row)),
                  _actionBtn(
                    row.isSuspended ? 'Reactivate' : 'Suspend',
                    row.isSuspended
                        ? const Color(0xFF1B7A43)
                        : const Color(0xFFD97706),
                    () => row.isSuspended
                        ? _reactivateCustomer(row)
                        : _suspendCustomer(row),
                  ),
                  _actionBtn('Delete', const Color(0xFFDC2626),
                      () => _deleteCustomer(row)),
                ]),
              ]),
            ),
            if (isExpanded) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _buildDynamicDetails(row.rawData, lpad: 16, rpad: 16),
            ],
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CUSTOMER DETAIL CARD  (deduplicated, explicit field list)
  // ═══════════════════════════════════════════════════════════════════════════

  // Stringify a rawData value; returns '' for null / empty / 'null'.
  static String _str(dynamic v) {
    if (v == null) return '';
    if (v is bool) return v ? 'Yes' : 'No';
    final s = v.toString().trim();
    return (s == 'null') ? '' : s;
  }

  // Format a DB timestamp value as DD/MM/YYYY HH:MM; returns '' on failure.
  static String _fmtTs(dynamic v) {
    final s = _str(v);
    if (s.isEmpty) return '';
    try {
      final dt = DateTime.parse(s).toLocal();
      return '${dt.day.toString().padLeft(2, '0')}/'
             '${dt.month.toString().padLeft(2, '0')}/'
             '${dt.year}  '
             '${dt.hour.toString().padLeft(2, '0')}:'
             '${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return s;
    }
  }

  // Part B + Part E-3: ALL fields always shown, empty = "—" grey italic.
  // Semantic duplicates collapsed: customer_name/owner_name → "Owner Name" etc.
  Widget _buildDynamicDetails(
    Map<String, dynamic> rawData, {
    required double lpad,
    required double rpad,
  }) {
    String val(dynamic v, {bool isTs = false}) {
      final s = isTs ? _fmtTs(v) : _str(v);
      return s.isEmpty ? '—' : s;
    }

    // Sections: (title, [(label, value), ...])
    final sections = <(String, List<(String, String)>)>[
      ('BASIC INFO', [
        ('Owner Name',    val(rawData['customer_name'] ?? rawData['owner_name'])),
        ('Pharmacy Name', val(rawData['pharmacy_name'])),
        ('Customer Code', val(rawData['customer_code'])),
      ]),
      ('CONTACT', [
        ('Email',         val(rawData['email'])),
        ('WhatsApp',      val(rawData['whatsapp_no'])),
        ('Phone',         val(rawData['phone'])),
        ('Other Contact', val(rawData['other_contact_no'])),
      ]),
      ('LOCATION', [
        ('Address',          val(rawData['address_local'] ?? rawData['address'])),
        ('City',             val(rawData['city'])),
        ('State',            val(rawData['state'])),
        ('PIN Code',         val(rawData['pincode'])),
        ('Range / Zone',     val(rawData['range_zone'])),
        ('Store Type',       val(rawData['store_type'])),
        ('Google Map Link',  val(rawData['store_location_link'])),
        ('',                 ''),
      ]),
      ('BUSINESS', [
        ('Payment Term',     val(rawData['payment_term'])),
        ('Drug Licence 20B', val(rawData['dl_20b'] ?? rawData['drug_license'])),
        ('Drug Licence 21B', val(rawData['dl_21b'])),
      ]),
      ('APPROVAL', [
        ('GSTIN',       val(rawData['gst_no'] ?? rawData['gstin'])),
        ('Status',      val(rawData['status'])),
        ('Approved By', val(rawData['approved_by'])),
        ('Approved At', val(rawData['approved_at'], isTs: true)),
        ('Registered',  val(rawData['created_at'],  isTs: true)),
        ('',            ''),  // placeholder to fill 3-col grid
      ]),
    ];

    return Container(
      color: const Color(0xFFF9FAFB),
      padding: EdgeInsets.fromLTRB(lpad, 16, rpad, 20),
      child: LayoutBuilder(builder: (ctx, constraints) {
        final w       = constraints.maxWidth;
        final cols    = w > 600 ? 3 : (w > 380 ? 2 : 1);
        const spacing = 20.0;
        final itemW   = ((w - spacing * (cols - 1)) / cols).clamp(80.0, 500.0);

        Widget fieldCell(String label, String value) {
          if (label.isEmpty) return SizedBox(width: itemW);
          final isEmpty = value == '—';
          return SizedBox(
            width: itemW,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF9CA3AF),
                        letterSpacing: 0.5)),
                const SizedBox(height: 3),
                Text(value,
                    style: TextStyle(
                        fontSize: 14,
                        color: isEmpty
                            ? const Color(0xFFD1D5DB)
                            : const Color(0xFF111827),
                        fontStyle: isEmpty ? FontStyle.italic : FontStyle.normal)),
              ],
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (int si = 0; si < sections.length; si++) ...[
              if (si > 0) ...[
                const SizedBox(height: 16),
                const Divider(height: 1, color: Color(0xFFE5E7EB)),
                const SizedBox(height: 12),
              ],
              Text(sections[si].$1,
                  style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF6B7280),
                      letterSpacing: 0.6)),
              const SizedBox(height: 10),
              Wrap(
                spacing: spacing,
                runSpacing: 14,
                children: sections[si].$2
                    .map((f) => fieldCell(f.$1, f.$2))
                    .toList(),
              ),
            ],
          ],
        );
      }),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static Widget _th(String label, {int flex = 1}) => Expanded(
        flex: flex,
        child: Text(label,
            style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Color(0xFF9CA3AF),
                letterSpacing: 0.5)),
      );

  static Widget _pendingBadge() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: const Color(0xFFD97706).withValues(alpha: 0.4)),
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

  // Small action button used for Edit/Suspend/Reactivate.
  // Using InkWell so it absorbs tap and prevents the parent row InkWell from firing.
  static Widget _actionBtn(String label, Color color, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
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

  // ═══════════════════════════════════════════════════════════════════════════
  // LEADS TAB
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildLeadsContent(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 16, pad, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section A: Logged-in users
          const Text('Logged in',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                  color: Color(0xFF111827))),
          const SizedBox(height: 2),
          const Text('Authenticated users who have not completed registration',
              style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          const SizedBox(height: 10),
          if (_loggedInLeads.isEmpty)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('No logged-in leads',
                  style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
            )
          else
            for (final lead in _loggedInLeads)
              _buildLeadRow(lead, isDesktop),

          const SizedBox(height: 24),

          // Section B: Other leads
          const Text('Other leads',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                  color: Color(0xFF111827))),
          const SizedBox(height: 2),
          const Text('Manually added and CSV-imported leads',
              style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          const SizedBox(height: 10),
          if (_otherLeads.isEmpty)
            const Text('No leads yet',
                style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
          else
            for (final lead in _otherLeads)
              _buildLeadRow(lead, isDesktop),

          const SizedBox(height: 32),

          // CSV upload
          _buildCsvUpload(),
        ],
      ),
    );
  }

  Widget _buildLeadRow(_LeadItem lead, bool isDesktop) {
    final isExpanded = _expandedLeads.contains(lead.key);
    final displayName = lead.name.isNotEmpty ? lead.name : lead.email;
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Whole-row header — clickable to expand
        InkWell(
          onTap: () => setState(() =>
              isExpanded ? _expandedLeads.remove(lead.key) : _expandedLeads.add(lead.key)),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(isExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: const Color(0xFF6B7280)),
              const SizedBox(width: 10),
              Expanded(
                child: isDesktop
                    ? Row(children: [
                        _leadCell(displayName, flex: 3, bold: true),
                        _leadCell(lead.email, flex: 3),
                        _leadCell(lead.mobile.isNotEmpty ? lead.mobile : '—', flex: 2),
                      ])
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(displayName,
                            style: const TextStyle(fontSize: 13,
                                fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                        if (lead.email.isNotEmpty)
                          Text(lead.email,
                              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                      ]),
              ),
              // Status chip preview
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _leadStatusColor(lead.status).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(lead.status,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: _leadStatusColor(lead.status))),
              ),
            ]),
          ),
        ),
        // Expanded details
        if (isExpanded)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 12),
              Wrap(spacing: 20, runSpacing: 12, children: [
                if (lead.name.isNotEmpty)
                  _detailChip('Name', lead.name),
                if (lead.email.isNotEmpty)
                  _detailChip('Email', lead.email),
                if (lead.mobile.isNotEmpty)
                  _detailChip('Mobile', lead.mobile),
              ]),
              const SizedBox(height: 16),
              // Dropdowns row
              Wrap(spacing: 16, runSpacing: 12, children: [
                // Status dropdown
                _leadDropdown<String>(
                  label: 'Status',
                  value: lead.status,
                  items: const ['New', 'Contacted', 'Interested', 'Converted', 'Dropped'],
                  display: (v) => v,
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => lead.status = v);
                    _persistLeadUpdate(lead, status: v);
                  },
                ),
                // Assigned-to dropdown
                _leadDropdown<String?>(
                  label: 'Assigned to',
                  value: lead.assignedTo,
                  items: [null, ..._admins.map((a) => a.id)],
                  display: (v) => v == null
                      ? 'Unassigned'
                      : (_admins.firstWhere((a) => a.id == v,
                              orElse: () => _AdminEntry(id: v.toString(), email: v.toString()))
                          .email),
                  onChanged: (v) {
                    setState(() => lead.assignedTo = v);
                    _persistLeadUpdate(lead, assignedTo: v);
                  },
                ),
              ]),
            ]),
          ),
      ]),
    );
  }

  Widget _leadCell(String text, {int flex = 1, bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
              color: bold ? const Color(0xFF111827) : const Color(0xFF374151))),
    );
  }

  Widget _detailChip(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF),
              fontWeight: FontWeight.w500)),
      const SizedBox(height: 2),
      Text(value,
          style: const TextStyle(fontSize: 13, color: Color(0xFF111827))),
    ]);
  }

  Widget _leadDropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) display,
    required ValueChanged<T?> onChanged,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280),
              fontWeight: FontWeight.w500)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFD1D5DB)),
          borderRadius: BorderRadius.circular(6),
          color: Colors.white,
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isDense: true,
            items: items.map((v) => DropdownMenuItem<T>(
              value: v,
              child: Text(display(v), style: const TextStyle(fontSize: 13)),
            )).toList(),
            onChanged: onChanged,
          ),
        ),
      ),
    ]);
  }

  Color _leadStatusColor(String status) {
    return switch (status) {
      'Converted' => const Color(0xFF1B7A43),
      'Dropped'   => const Color(0xFFDC2626),
      'Interested'=> const Color(0xFF2563EB),
      'Contacted' => const Color(0xFFD97706),
      _           => const Color(0xFF6B7280), // New
    };
  }

  Future<void> _persistLeadUpdate(_LeadItem lead, {String? status, String? assignedTo}) async {
    try {
      final client = Supabase.instance.client;
      if (lead.leadsId != null) {
        // Update existing leads row
        final update = <String, dynamic>{};
        if (status != null)     update['status']      = status;
        if (assignedTo != null) update['assigned_to'] = assignedTo;
        if (update.isNotEmpty) {
          await client.from('leads').update(update).eq('id', lead.leadsId!);
        }
      } else {
        // Insert new leads row (upsert for logged_in avoids duplicates)
        final insert = <String, dynamic>{
          'name':        lead.name,
          'email':       lead.email,
          'mobile':      lead.mobile,
          'source':      lead.source,
          'status':      lead.status,
          'assigned_to': lead.assignedTo,
        };
        if (lead.authUid != null) insert['auth_uid'] = lead.authUid;
        final res = await client.from('leads').upsert(
          insert,
          onConflict: lead.authUid != null ? 'auth_uid' : null,
        ).select('id').single();
        // Update local leadsId so subsequent changes update rather than insert
        final newId = res['id'] as String?;
        if (newId != null) lead.leadsId = newId;
      }
    } catch (_) {}
  }

  // ── CSV upload ───────────────────────────────────────────────────────────────

  Widget _buildCsvUpload() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(),
      const SizedBox(height: 8),
      const Text('Import CSV',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600,
              color: Color(0xFF111827))),
      const SizedBox(height: 4),
      const Text('Columns: name, email, mobile (header row required; order flexible)',
          style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      const SizedBox(height: 10),
      ElevatedButton.icon(
        onPressed: _pickAndImportCsv,
        icon: const Icon(Icons.upload_file_outlined, size: 16),
        label: const Text('Upload CSV'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1B7A43),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    ]);
  }

  Future<void> _pickAndImportCsv() async {
    final input = html.FileUploadInputElement()..accept = '.csv,text/csv';
    input.click();
    await input.onChange.first;
    final file = input.files?.first;
    if (file == null || !mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CsvImportDialog(
        file: file,
        onImported: () { if (mounted) _loadLeads(); },
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RECENTLY DELETED section  (Part C-2)
  // ═══════════════════════════════════════════════════════════════════════════

  // Returns true if a new active profile exists with the same email as the deleted row.
  bool _hasNewAccount(Map<String, dynamic> deletedRow) {
    final snap  = deletedRow['deleted_snapshot'] as Map<String, dynamic>? ?? {};
    final email = ((snap['email'] as String?) ??
            (deletedRow['email'] as String?) ?? '')
        .toLowerCase()
        .trim();
    if (email.isEmpty) return false;
    return _approvedRows.any(
          (r) => (r.rawData['email'] as String? ?? '').toLowerCase().trim() == email,
        ) ||
        _regRows.any(
          (r) => (r.email ?? '').toLowerCase().trim() == email,
        );
  }

  Widget _buildDeletedSection(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: isDesktop ? 0 : 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Collapsible header bar
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() => _deletedExpanded = !_deletedExpanded),
              child: Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(horizontal: pad, vertical: 11),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F4F6),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  borderRadius: _deletedExpanded
                      ? const BorderRadius.vertical(top: Radius.circular(8))
                      : BorderRadius.circular(8),
                ),
                child: Row(children: [
                  AnimatedRotation(
                    turns: _deletedExpanded ? 0.0 : -0.25,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more,
                        size: 18, color: Color(0xFF1B7A43)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Recently Deleted (${_deletedRows.length})',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF374151)),
                  ),
                ]),
              ),
            ),
          ),
          // Collapsible body
          if (_deletedExpanded) ...[
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFE5E7EB)),
                borderRadius:
                    const BorderRadius.vertical(bottom: Radius.circular(8)),
              ),
              child: _deletedRows.isEmpty
                  ? Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: pad, vertical: 20),
                      child: const Text('No deleted customers.',
                          style: TextStyle(
                              fontSize: 13, color: Color(0xFF9CA3AF))),
                    )
                  : Column(
                      children: _deletedRows
                          .map((r) => _buildDeletedRow(r, isDesktop))
                          .toList(),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDeletedRow(Map<String, dynamic> row, bool isDesktop) {
    final snap      = row['deleted_snapshot'] as Map<String, dynamic>? ?? row;
    final pharmacy  = snap['pharmacy_name'] as String? ?? '';
    final email     = snap['email'] as String? ?? row['email'] as String? ?? '';
    final deletedAt = _fmtTs(row['deleted_at']);
    final deletedBy = row['deleted_by'] as String? ?? '';
    final hasNew    = _hasNewAccount(row);
    final pad       = isDesktop ? 28.0 : 16.0;
    final isLast    = _deletedRows.last == row;

    return Opacity(
      opacity: 0.85,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          border: isLast
              ? null
              : const Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Pharmacy name + "New account exists" badge
                Row(children: [
                  Flexible(
                    child: Text(
                      pharmacy.isNotEmpty
                          ? pharmacy
                          : email.isNotEmpty
                              ? email
                              : 'Deleted Customer',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF374151)),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (hasNew) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3C7),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: const Color(0xFFF59E0B)),
                      ),
                      child: const Text('New account exists',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF92400E))),
                    ),
                  ],
                ]),
                const SizedBox(height: 3),
                // Email · Deleted At · Deleted By
                Text(
                  [
                    if (email.isNotEmpty) email,
                    if (deletedAt.isNotEmpty) 'Deleted: $deletedAt',
                    if (deletedBy.isNotEmpty) 'By: $deletedBy',
                  ].join('  ·  '),
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFF9CA3AF)),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Restore button (green outlined)
          InkWell(
            onTap: () => _restoreCustomer(row),
            borderRadius: BorderRadius.circular(6),
            mouseCursor: SystemMouseCursors.click,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF1B7A43)),
              ),
              child: const Text('Restore',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1B7A43))),
            ),
          ),
        ]),
      ),
    );
  }
}


// ── Extension ─────────────────────────────────────────────────────────────────

extension _Let<T> on T {
  R let<R>(R Function(T) fn) => fn(this);
}

// ── Source badge ──────────────────────────────────────────────────────────────

class _SourceBadge extends StatelessWidget {
  final String source;
  const _SourceBadge({required this.source});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    final IconData icon;
    switch (source) {
      case 'website':
        color = const Color(0xFF2563EB);
        label = 'Website';
        icon  = Icons.language_outlined;
        break;
      case 'whatsapp':
        color = const Color(0xFF1B7A43);
        label = 'WhatsApp';
        icon  = Icons.chat_outlined;
        break;
      case 'cart_only':
        color = const Color(0xFFD97706);
        label = 'Cart';
        icon  = Icons.shopping_cart_outlined;
        break;
      default:
        color = const Color(0xFF6B7280);
        label = source;
        icon  = Icons.help_outline;
    }
    return Container(
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
    );
  }
}

// ── Payment term badge ────────────────────────────────────────────────────────

class _PaymentBadge extends StatelessWidget {
  final String term;
  const _PaymentBadge({required this.term});

  @override
  Widget build(BuildContext context) {
    final isAdvance =
        term.toLowerCase().contains('advance') || term.toLowerCase() == 'adv';
    final color =
        isAdvance ? const Color(0xFF1E40AF) : const Color(0xFF0891B2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(term,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

// ── Customer status badge ─────────────────────────────────────────────────────

class _CustomerStatusBadge extends StatelessWidget {
  final String status;
  const _CustomerStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    final IconData icon;
    switch (status) {
      case 'suspended':
        color = const Color(0xFFDC2626);
        label = 'Suspended';
        icon  = Icons.block_outlined;
        break;
      case 'approved':
        color = const Color(0xFF1B7A43);
        label = 'Active';
        icon  = Icons.verified_outlined;
        break;
      default:
        color = const Color(0xFFD97706);
        label = status.isNotEmpty ? status : 'Active';
        icon  = Icons.info_outline;
    }
    return Container(
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
    );
  }
}

// ── Order confirmation ────────────────────────────────────────────────────────

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
              strokeWidth: 2, color: Color(0xFF1B7A43)));
    }
    final status = widget.row.orderStatus.toLowerCase().trim();
    final orderId = widget.row.orderId ?? '';

    Widget resolved(String label, Color color) {
      RenderLog.write('order_confirm_cell', '$orderId:$status→$label');
      return _chip(label, color);
    }

    if (status == 'accepted' || status == 'confirmed') {
      return resolved('Accepted', const Color(0xFF1B7A43));
    }
    if (status == 'rejected') {
      return resolved('Rejected', const Color(0xFFDC2626));
    }
    if (status == 'cancelled') {
      return resolved('Cancelled', const Color(0xFF6B7280));
    }
    if (status != 'pending' && status.isNotEmpty) {
      return resolved(status[0].toUpperCase() + status.substring(1), const Color(0xFF6B7280));
    }

    RenderLog.write('order_confirm_cell', '$orderId:$status→buttons');
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _btn('Accept', const Color(0xFF1B7A43), () => _act('accepted')),
      const SizedBox(width: 4),
      _btn('Reject', const Color(0xFFDC2626), () => _act('rejected')),
    ]);
  }

  Widget _chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(20)),
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

// ── Registration Approve / Reject ─────────────────────────────────────────────

class _RegApproveActions extends StatefulWidget {
  final String id;
  final Future<void> Function() onApprove;
  final Future<void> Function() onReject;
  const _RegApproveActions(
      {required this.id, required this.onApprove, required this.onReject});

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
        showToast(context, 'Action failed: $e', isError: true);
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
              strokeWidth: 2, color: Color(0xFF1B7A43)));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _btn('Approve', const Color(0xFF1B7A43), () => _act(widget.onApprove)),
      const SizedBox(width: 4),
      _btn('Reject',  const Color(0xFFDC2626), () => _act(widget.onReject)),
    ]);
  }

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

// ── Action cell ───────────────────────────────────────────────────────────────

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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF0FDF4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: const Color(0xFF1B7A43).withValues(alpha: 0.4)),
          ),
          child: const Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.upload_file_outlined,
                size: 14, color: Color(0xFF1B7A43)),
            SizedBox(width: 4),
            Text('Import',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF1B7A43))),
          ]),
        ),
      );
    }

    return InkWell(
      onTap: row.items.isNotEmpty ? onImport : null,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFECFDF5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: const Color(0xFF1B7A43).withValues(alpha: 0.3)),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_circle_outline, size: 14, color: Color(0xFF1B7A43)),
          SizedBox(width: 4),
          Text('Imported',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1B7A43))),
        ]),
      ),
    );
  }
}

// ── Admin add-to-cart dialog ──────────────────────────────────────────────────

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

      final existingList = await Supabase.instance.client
          .from('cart_items')
          .select('id, quantity, removed_by_admin')
          .eq('user_id', widget.userId)
          .eq('product_id', productId);

      if (existingList.isNotEmpty) {
        final existing = Map<String, dynamic>.from(existingList.first as Map);
        final wasRemoved = (existing['removed_by_admin'] as bool?) ?? false;
        final newQty =
            wasRemoved ? _qty : (existing['quantity'] as int) + _qty;
        await Supabase.instance.client.from('cart_items').update({
          'quantity': newQty,
          'removed_by_admin': false,
          'updated_at': DateTime.now().toIso8601String(),
        }).eq('id', existing['id'] as int);
      } else {
        await Supabase.instance.client.from('cart_items').insert({
          'user_id':      widget.userId,
          'product_id':   productId,
          'product_name': item['product_name'] as String? ?? '',
          'price':        mrp,
          'mrp':          mrp,
          'quantity':     _qty,
          'image_url':    (item['image_url_1'] as String?) ?? '',
          'manufacturer': (item['marketer']    as String?) ?? '',
          'pack_size':    (item['pack_qty']    as String?) ??
              (item['pack_size'] as String?) ?? '',
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
        showToast(context, e.toString().contains('column')
            ? 'DB migration required — run the migration SQL in Supabase Studio first'
            : 'Failed to add item: $e', isError: true);
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
                          width: 18,
                          height: 18,
                          child: Padding(
                            padding: EdgeInsets.all(10),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ))
                      : null,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                  isDense: true,
                ),
                onChanged: _search,
              ),
              const SizedBox(height: 8),
              if (_selected != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF86EFAC)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(
                              _selected!['product_name'] as String? ?? '',
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        IconButton(
                          onPressed: () => setState(() => _selected = null),
                          icon: const Icon(Icons.close,
                              size: 14, color: Color(0xFF6B7280)),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                        ),
                      ]),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('Qty:',
                              style: TextStyle(
                                  fontSize: 13, color: Color(0xFF374151))),
                          const SizedBox(width: 12),
                          _StepperButton(
                            icon: Icons.remove,
                            onTap: _qty > 1
                                ? () => setState(() => _qty--)
                                : null,
                          ),
                          Container(
                            width: 52,
                            alignment: Alignment.center,
                            child: Text('$_qty',
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF111827))),
                          ),
                          _StepperButton(
                            icon: Icons.add,
                            onTap: () => setState(() => _qty++),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _adding ? null : _addItem,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1B7A43),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: _adding
                        ? const SizedBox(
                            width: 16,
                            height: 16,
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
                              _results  = [];
                              _qty      = 1;
                            }),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 8),
                              decoration: const BoxDecoration(
                                border: Border(
                                    bottom: BorderSide(
                                        color: Color(0xFFE5E7EB))),
                              ),
                              child: Row(children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          item['product_name'] as String? ?? '',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF111827)),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis),
                                      if ((item['marketer'] as String?)
                                              ?.isNotEmpty ==
                                          true)
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

// ── Removed-by-admin badge ────────────────────────────────────────────────────

class _RemovedByBadge extends StatelessWidget {
  const _RemovedByBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: const Text('Removed by\nmediBO',
          style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: Color(0xFFDC2626),
              height: 1.3)),
    );
  }
}

// ── Qty stepper button ────────────────────────────────────────────────────────

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _StepperButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: enabled
              ? const Color(0xFF1B7A43).withValues(alpha: 0.08)
              : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: enabled
                ? const Color(0xFF1B7A43).withValues(alpha: 0.3)
                : const Color(0xFFE5E7EB),
          ),
        ),
        child: Icon(icon,
            size: 18,
            color: enabled
                ? const Color(0xFF1B7A43)
                : const Color(0xFFD1D5DB)),
      ),
    );
  }
}

// ── Customer Edit Dialog  (Task 4) ────────────────────────────────────────────

// All editable fields in pharmacy_profiles (non-system columns).
const _kEditFields = [
  ('pharmacy_name',     'Pharmacy / Clinic Name', true),
  ('customer_name',     'Customer Name',          false),
  ('owner_name',        'Owner Name',             false),
  ('whatsapp_no',       'WhatsApp No.',           false),
  ('phone',             'Phone',                  false),
  ('email',             'Email',                  false),
  ('other_contact_no',  'Other Contact',          false),
  ('store_type',        'Store Type',             false),
  ('range_zone',        'Range / Zone',           false),
  ('address_local',     'Local Address',          false),
  ('address',           'Address',                false),
  ('city',              'City',                   false),
  ('state',             'State',                  false),
  ('pincode',           'Pincode',                false),
  ('store_location_link','Store Location Link',   false),
  ('dl_20b',            'Drug Licence 20B',       false),
  ('dl_21b',            'Drug Licence 21B',       false),
  ('gst_no',            'GST No.',                false),
  ('gstin',             'GSTIN',                  false),
  ('drug_license',      'Drug License',           false),
  ('payment_term',      'Payment Term',           false),
  ('customer_code',     'Customer Code',          false),
];

class _CustomerEditDialog extends StatefulWidget {
  final _ApprovedRow row;
  const _CustomerEditDialog({required this.row});

  @override
  State<_CustomerEditDialog> createState() => _CustomerEditDialogState();
}

class _CustomerEditDialogState extends State<_CustomerEditDialog> {
  late final Map<String, TextEditingController> _ctrl;
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = {
      for (final (key, _, _) in _kEditFields)
        key: TextEditingController(
          text: widget.row.rawData[key]?.toString() ?? '',
        ),
    };
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final client = Supabase.instance.client;
      final updates = <String, dynamic>{
        for (final (key, _, _) in _kEditFields)
          key: _ctrl[key]!.text.trim().isEmpty ? null : _ctrl[key]!.text.trim(),
      };

      // Uniqueness check for customer_code
      final newCode  = updates['customer_code'] as String?;
      final oldCode  = widget.row.customerCode;
      if (newCode != null && newCode.isNotEmpty && newCode != oldCode) {
        final existing = await client
            .from('pharmacy_profiles')
            .select('id')
            .eq('customer_code', newCode)
            .neq('id', widget.row.id)
            .maybeSingle();
        if (existing != null) {
          throw Exception('Customer Code "$newCode" is already in use by another customer');
        }
      }

      await client.from('pharmacy_profiles').update(updates).eq('id', widget.row.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showToast(context, 'Save failed: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 680),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
            child: Row(children: [
              const Expanded(
                child: Text('Edit Customer',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF111827))),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: _saving ? null : () => Navigator.pop(context),
                visualDensity: VisualDensity.compact,
              ),
            ]),
          ),
          const Divider(height: 16, indent: 20, endIndent: 20),
          // Scrollable form
          Expanded(
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: LayoutBuilder(builder: (ctx, constraints) {
                  final wide = constraints.maxWidth > 460;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 14,
                    children: _kEditFields.map((rec) {
                      final (key, label, required) = rec;
                      return SizedBox(
                        width: wide
                            ? (constraints.maxWidth - 12) / 2
                            : constraints.maxWidth,
                        child: TextFormField(
                          controller: _ctrl[key],
                          decoration: InputDecoration(
                            labelText: label,
                            labelStyle: const TextStyle(
                                fontSize: 12, color: Color(0xFF6B7280)),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8)),
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 10),
                            isDense: true,
                          ),
                          style: const TextStyle(fontSize: 13),
                          validator: required
                              ? (v) => (v == null || v.trim().isEmpty)
                                  ? '$label is required'
                                  : null
                              : null,
                        ),
                      );
                    }).toList(),
                  );
                }),
              ),
            ),
          ),
          const Divider(height: 1, indent: 20, endIndent: 20),
          // Footer buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF374151),
                    side: const BorderSide(color: Color(0xFFD1D5DB)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  child: const Text('Cancel',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1B7A43),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Save Changes',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─── CSV Import Dialog ────────────────────────────────────────────────────────

class _CsvColMap {
  final int index;
  final String header;
  final List<String> samples;
  String mappedTo; // 'name' | 'email' | 'mobile' | 'ignore'
  _CsvColMap({required this.index, required this.header, required this.samples, required this.mappedTo});
}

enum _CsvStep { reading, mapping, importing }

class _CsvImportDialog extends StatefulWidget {
  final html.File file;
  final VoidCallback onImported;
  const _CsvImportDialog({required this.file, required this.onImported});

  @override
  State<_CsvImportDialog> createState() => _CsvImportDialogState();
}

class _CsvImportDialogState extends State<_CsvImportDialog> {
  _CsvStep _step = _CsvStep.reading;
  String _statusMsg = 'Reading file…';
  List<_CsvColMap> _cols = [];
  List<List<String>> _dataRows = [];
  String? _error;

  static const _leadFields = ['name', 'email', 'mobile', 'ignore'];

  @override
  void initState() {
    super.initState();
    _readAndMap();
  }

  Future<void> _readAndMap() async {
    try {
      final reader = html.FileReader();
      reader.readAsText(widget.file);
      await reader.onLoad.first;
      final csvText = reader.result as String;

      final lines = csvText.split(RegExp(r'\r?\n'));
      if (lines.isEmpty || lines.first.trim().isEmpty) {
        setState(() { _error = 'The CSV file is empty.'; });
        return;
      }

      final headers = lines.first.split(',').map((h) => h.trim()).toList();
      final dataRows = <List<String>>[];
      for (final line in lines.skip(1)) {
        if (line.trim().isEmpty) continue;
        dataRows.add(line.split(',').map((c) => c.trim()).toList());
      }

      if (dataRows.isEmpty) {
        setState(() { _error = 'No data rows found (only a header row).'; });
        return;
      }

      setState(() { _statusMsg = 'Mapping columns with Gemini…'; });

      // Build Gemini prompt
      final entries = <Map<String, dynamic>>[];
      for (int i = 0; i < headers.length; i++) {
        final samples = dataRows
            .map((r) => i < r.length ? r[i] : '')
            .where((v) => v.isNotEmpty)
            .take(5)
            .toList();
        entries.add({'index': i, 'header': headers[i], 'samples': samples});
      }
      final prompt =
          'Map each CSV column to the correct lead field.\n\n'
          'Lead fields:\n'
          '- name: full name of the lead\n'
          '- email: email address\n'
          '- mobile: phone/mobile number\n'
          '- ignore: skip this column\n\n'
          'Columns:\n${jsonEncode(entries)}\n\n'
          'Return ONLY a JSON array (no markdown): '
          '[{"index":0,"mapped_to":"name"},...]';

      final idxMap = <int, String>{};
      try {
        final resp = await http.post(
          Uri.parse('https://swojhmarmaijkshsbeih.supabase.co/functions/v1/gemini-ocr'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'image_base64': '', 'mime_type': 'text/plain', 'prompt': prompt}),
        ).timeout(const Duration(seconds: 20));
        if (resp.statusCode == 200) {
          final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
          final jm = RegExp(r'\[[\s\S]*\]').firstMatch(txt);
          if (jm != null) {
            final mappings = jsonDecode(jm.group(0)!) as List<dynamic>;
            for (final m in mappings) {
              final mm = m as Map<String, dynamic>;
              final idx = mm['index'] as int?;
              final mapped = mm['mapped_to'] as String? ?? 'ignore';
              if (idx != null) idxMap[idx] = _leadFields.contains(mapped) ? mapped : 'ignore';
            }
          }
        }
      } catch (_) {} // Gemini failure: fall back to heuristic

      // Heuristic fallback for any unmapped column
      for (int i = 0; i < headers.length; i++) {
        if (idxMap.containsKey(i)) continue;
        final h = headers[i].toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
        if (['name', 'fullname', 'customername', 'leadname'].contains(h)) {
          idxMap[i] = 'name';
        } else if (['email', 'emailaddress', 'mail'].contains(h)) {
          idxMap[i] = 'email';
        } else if (['mobile', 'phone', 'mobilenumber', 'phonenumber', 'contact', 'cell'].contains(h)) {
          idxMap[i] = 'mobile';
        } else {
          idxMap[i] = 'ignore';
        }
      }

      final cols = List.generate(headers.length, (i) {
        final samples = dataRows
            .map((r) => i < r.length ? r[i] : '')
            .where((v) => v.isNotEmpty)
            .take(3)
            .toList();
        return _CsvColMap(index: i, header: headers[i], samples: samples, mappedTo: idxMap[i] ?? 'ignore');
      });

      setState(() {
        _cols = cols;
        _dataRows = dataRows;
        _step = _CsvStep.mapping;
      });
    } catch (e) {
      setState(() { _error = 'Failed to read CSV: $e'; });
    }
  }

  Future<void> _doImport() async {
    setState(() { _step = _CsvStep.importing; });
    try {
      final nameCol   = _cols.firstWhereOrNull((c) => c.mappedTo == 'name');
      final emailCol  = _cols.firstWhereOrNull((c) => c.mappedTo == 'email');
      final mobileCol = _cols.firstWhereOrNull((c) => c.mappedTo == 'mobile');

      final toInsert = <Map<String, dynamic>>[];
      for (final row in _dataRows) {
        final name   = nameCol   != null && nameCol.index   < row.length ? row[nameCol.index]   : '';
        final email  = emailCol  != null && emailCol.index  < row.length ? row[emailCol.index]  : '';
        final mobile = mobileCol != null && mobileCol.index < row.length ? row[mobileCol.index] : '';
        if (name.isEmpty && email.isEmpty && mobile.isEmpty) continue;
        toInsert.add({'name': name, 'email': email, 'mobile': mobile, 'source': 'csv_import', 'status': 'new'});
      }

      if (toInsert.isNotEmpty) {
        await Supabase.instance.client.from('leads').insert(toInsert);
      }

      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        showToast(context, 'Imported ${toInsert.length} lead${toInsert.length == 1 ? '' : 's'}');
      }
    } catch (e) {
      if (mounted) {
        setState(() { _step = _CsvStep.mapping; });
        showToast(context, 'Import failed: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error != null ? _buildError() : _buildContent(),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 32),
      const SizedBox(height: 12),
      Text(_error!, textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, color: Color(0xFF111827))),
      const SizedBox(height: 16),
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
    ]);
  }

  Widget _buildContent() {
    if (_step == _CsvStep.reading || _step == _CsvStep.importing) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
        const SizedBox(height: 16),
        Text(_step == _CsvStep.reading ? _statusMsg : 'Importing…',
            style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
      ]);
    }

    // Mapping step
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header
      Row(children: [
        const Expanded(
          child: Text('Map CSV Columns',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          onPressed: () => Navigator.of(context).pop(),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ]),
      const SizedBox(height: 4),
      const Text('Gemini has auto-mapped your columns. Correct any mismatches before importing.',
          style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      const SizedBox(height: 16),

      // Column rows
      ...List.generate(_cols.length, (i) {
        final col = _cols[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Expanded(
              flex: 3,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(col.header.isNotEmpty ? col.header : 'Column ${i + 1}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                if (col.samples.isNotEmpty)
                  Text(col.samples.join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F6F8),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: col.mappedTo,
                    isExpanded: true,
                    style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                    items: const [
                      DropdownMenuItem(value: 'name',   child: Text('name')),
                      DropdownMenuItem(value: 'email',  child: Text('email')),
                      DropdownMenuItem(value: 'mobile', child: Text('mobile')),
                      DropdownMenuItem(value: 'ignore', child: Text('ignore')),
                    ],
                    onChanged: (v) => setState(() => col.mappedTo = v ?? 'ignore'),
                  ),
                ),
              ),
            ),
          ]),
        );
      }),

      const SizedBox(height: 8),
      Text('${_dataRows.length} row${_dataRows.length == 1 ? '' : 's'} will be imported',
          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      const SizedBox(height: 16),

      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280))),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _doImport,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1B7A43),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('Import', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ]),
    ]);
  }
}

extension _ListExt<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) { if (test(e)) return e; }
    return null;
  }
}
