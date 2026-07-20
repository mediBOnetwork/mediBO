// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:file_picker/file_picker.dart'; // CHANGE #464
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pharma_b2b/utils/toast.dart';

import '../../config/api_keys.dart';
import '../../util.dart';
import '../../utils/download_bytes.dart'; // CHANGE #463
import '../../utils/order_code.dart';
import '../../utils/render_log.dart';
import '../../utils/ist_date.dart'; // CHANGE #444
import '../../widgets/date_scope_chip.dart'; // CHANGE #444
import '../../widgets/route_google_map_panel.dart'; // CHANGE #463
import '../bulk_upload_screen.dart';
import '../../services/payment_claims_service.dart';
import '../../view_as_state.dart';
import '../../widgets/cash_payment_sheet.dart';
import '../../widgets/fullscreen_image.dart';

// ── CHANGE #242: Web Share API interop (dart:js_interop top-level declarations)
// Extension types for Blob, File, ShareData. Used only in sharePaymentImage().

extension type _BlobPropBag._(JSObject _) implements JSObject {
  external factory _BlobPropBag({String type});
}

@JS('Blob')
extension type _JsBlob._(JSObject _) implements JSObject {
  external factory _JsBlob(JSArray<JSAny?> parts, [_BlobPropBag? options]);
}

@JS('File')
extension type _JsFile._(JSObject _) implements JSObject {
  external factory _JsFile(JSArray<JSAny?> bits, String name,
      [_BlobPropBag? options]);
}

extension type _ShareOptions._(JSObject _) implements JSObject {
  external factory _ShareOptions({
    String? title,
    String? text,
    String? url,
    JSArray<JSAny?>? files,
  });
}

@JS('navigator.share')
external JSFunction? get _jsNavShareFn; // null if browser lacks Web Share API

@JS('navigator.canShare')
external JSFunction? get _jsCanShareFn;

@JS('navigator.canShare')
external bool _jsCanShare(_ShareOptions data);

@JS('navigator.share')
external JSPromise<JSAny?> _jsNavShare(_ShareOptions data);

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

// ── CHANGE #369 — grouped WhatsApp lead models (one card per customer) ───────
// Fed exclusively by get_leads_grouped_today(); replaces the old one-row-per-
// image _WaLeadRow (was #367). A Lead groups all of a sender's not-yet-
// converted order-list photos received today; each is a LeadImage ("Order N").
class LeadImage {
  final String id;               // pending_orders.id (uuid) — used for delete_lead_image + convert
  final String? leadCode;
  final int orderSeq;            // 1,2,3 -> "Order 1", "Order 2"...
  final String filePath;
  final String? fileName;
  final String? caption;
  final DateTime? receivedAt;
  final String? status;
  final DateTime? convertClickedAt;
  final String? convertedOrderCode;
  LeadImage({
    required this.id, this.leadCode, required this.orderSeq, required this.filePath,
    this.fileName, this.caption, this.receivedAt, this.status, this.convertClickedAt,
    this.convertedOrderCode,
  });
  factory LeadImage.fromJson(Map<String, dynamic> j) => LeadImage(
    id: j['id'] as String,
    leadCode: j['lead_code'] as String?,
    orderSeq: (j['order_seq'] as num?)?.toInt() ?? 1,
    filePath: j['file_path'] as String? ?? '',
    fileName: j['file_name'] as String?,
    caption: j['caption'] as String?,
    receivedAt: j['received_at'] != null ? DateTime.tryParse(j['received_at'] as String) : null,
    status: j['status'] as String?,
    convertClickedAt: j['convert_clicked_at'] != null
        ? DateTime.tryParse(j['convert_clicked_at'] as String) : null,
    convertedOrderCode: j['converted_order_code'] as String?,
  );
}

class Lead {
  final String senderPhone;
  final String? customerName;   // may be null — resolved via phone lookup in _load()
  final String pharmacy;        // resolved same way as _pharmacy() elsewhere in this file
  final int leadCount;
  final List<LeadImage> images;
  final bool isApproved;         // resolved pharmacy_profiles.approved for the ViewAs handoff
  Lead({
    required this.senderPhone, this.customerName, this.pharmacy = '',
    required this.leadCount, required this.images, this.isApproved = false,
  });
  factory Lead.fromRow(Map<String, dynamic> r,
          {String? resolvedName, String resolvedPharmacy = '', bool resolvedIsApproved = false}) =>
      Lead(
        senderPhone: r['sender_phone'] as String? ?? '',
        customerName: resolvedName ?? (r['customer_name'] as String?),
        pharmacy: resolvedPharmacy,
        leadCount: (r['lead_count'] as num?)?.toInt() ?? 0,
        isApproved: resolvedIsApproved,
        images: ((r['images'] as List?) ?? const [])
            .map((e) => LeadImage.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
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
  sLeads,
  routes,
}

// ── Screen ────────────────────────────────────────────────────────────────────

class AdminCustomerScreen extends StatefulWidget {
  static final _screenKey = GlobalKey<_AdminCustomerScreenState>();

  AdminCustomerScreen() : super(key: _screenKey);

  /// Called by the shell when this screen becomes the active page.
  static void triggerFocus() =>
      _screenKey.currentState?._onScreenFocus();

  @override
  State<AdminCustomerScreen> createState() => _AdminCustomerScreenState();
}

class _AdminCustomerScreenState extends State<AdminCustomerScreen> {
  // CHANGE #444 — Customer Orders date scope. Own chip, default today, no
  // "older open" pill (an order list is a record of a day, not a work queue).
  DateTime _ordersDate = todayIst();
  void _onOrdersDateChanged(DateTime d) {
    setState(() => _ordersDate = d);
    _load(showSpinner: false);
  }

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
  // CHANGE #213 — per-order payment panel open state
  final Map<String, bool> _payOpen = {};
  // CHANGE #322 — per-customer WA order panel open state (keyed by userId)
  final Map<String, bool> _waOpen = {};
  // CHANGE #369 — grouped WhatsApp leads (unconverted pending_orders), shown
  // above orders in the Customer Orders tab. Sourced solely from
  // get_leads_grouped_today(), one Lead per sender phone with N LeadImages.
  List<Lead> _leads = [];
  // orderId → per-product inquiry status from get_order_item_inquiry_status
  final Map<String, List<Map<String, dynamic>>> _orderItemStatuses = {};
  // CHANGE #384 — MEDICINE.id → brief catalog row (image_url_1, marketer,
  // pack_qty/pack_type/pack_size, salt_composition), keyed by product_id, for
  // the Customer Orders item cards. Merged-into across loads so re-expanding
  // an order never refetches an id already resolved.
  final Map<int, Map<String, dynamic>> _medBriefs = {};
  final ScrollController _scrollCtrl = ScrollController();
  // CHANGE #443 — "S Leads" tab badge count (lead_leads_summary(null).total).
  // Fetched independently of _load() so it's populated before the tab is
  // ever opened; kept in sync afterwards via _SLeadsTab.onTotalChanged.
  int _sLeadsTotal = 0;
  // CHANGE #445 — "Routes" tab badge count (zones.length from
  // lead_routes_screen). Kept in sync via _RoutesTab.onZonesChanged; only
  // populated once the tab has been opened (no independent bootstrap fetch,
  // unlike S Leads — zones list is heavier and city-scoped).
  int _routesZones = 0;

  final List<RealtimeChannel> _realtimeChannels = [];
  Timer? _debounce;

  // ── Auto-load guard (prevents concurrent/storm fetches) ──────────────────
  bool _loadInFlight = false;
  DateTime? _lastAutoLoad;
  static const _autoLoadMinInterval = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeRealtime();
    _loadSLeadsTotal();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        RenderLog.write('c322_build', 322);
        RenderLog.write('screen_autoload_on_focus', 'customers_initial');
        RenderLog.write('tab_autoload_on_open_approvedCustomers', 'initial');
        RenderLog.write('counts_synced_no_manual_refresh', 'true');
        RenderLog.write('c246_single_dropdown', 'single_open_enforced=true');
      }
    });
  }

  void _onScreenFocus() {
    if (!mounted) return;
    _autoLoad(key: _filter.name, force: true);
    RenderLog.write('screen_autoload_on_focus', 'customers');
  }

  // CHANGE #443 — lightweight, independent fetch for the "S Leads" tab badge.
  void _loadSLeadsTotal() {
    Supabase.instance.client
        .rpc('lead_leads_summary', params: {'p_city': null})
        .then((res) {
      if (!mounted) return;
      final total = (Map<String, dynamic>.from(res as Map)['total'] as num?)
              ?.toInt() ??
          0;
      setState(() => _sLeadsTotal = total);
      RenderLog.write('c443_summary_total', total);
    }).catchError((_) {});
  }

  void _autoLoad({required String key, bool force = false}) {
    // CHANGE #443 — the "S Leads" tab owns and refreshes its own data
    // (_SLeadsTab); skip the heavy shared _load() for it.
    if (key == _CustFilter.sLeads.name) {
      RenderLog.write('tab_autoload_on_open_$key', 'true');
      return;
    }
    if (_loadInFlight) return;
    final now = DateTime.now();
    if (!force &&
        _lastAutoLoad != null &&
        now.difference(_lastAutoLoad!) < _autoLoadMinInterval) return;
    _lastAutoLoad = now;
    _load(showSpinner: false);
    RenderLog.write('tab_autoload_on_open_$key', 'true');
    RenderLog.write('counts_synced_no_manual_refresh', 'true');
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
    // CHANGE #367 — 'pending_orders' added so a lead auto-disappears from the
    // Leads section (and its order appears below) the moment it's converted.
    // CHANGE #369 — 'order_items' added; realtime init confirmed here (no
    // periodic/2s poll timer anywhere in this file — debounced-load only).
    const tables = ['cart_items', 'orders', 'order_items', 'pharmacy_profiles', 'payment_claims', 'pending_orders'];
    RenderLog.write('co_realtime_369', 'tables:${tables.join(",")}');
    for (final table in tables) {
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
    if (!mounted || _loadInFlight) return;
    _loadInFlight = true;
    if (showSpinner) setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      // CHANGE #444 — Customer Orders is date-scoped to when the order was
      // PLACED (orders.created_at in Asia/Kolkata). ist_day_bounds does the
      // IST-aware UTC conversion server-side — never hand-roll this in Dart,
      // IST is UTC+5:30 and naive local-day math flips the day near midnight.
      final bounds =
          await client.rpc('ist_day_bounds', params: {'p_date': ymd(_ordersDate)}) as Map;
      final ordersStartUtc = bounds['start_utc'] as String;
      final ordersEndUtc   = bounds['end_utc'] as String;
      final results = await Future.wait<dynamic>([
        client.from('user_profiles').select(),
        // Part A-2: always filter out deleted profiles from active list
        client.from('pharmacy_profiles').select().or('is_deleted.is.null,is_deleted.eq.false'),
        client.from('orders').select()
            .gte('created_at', ordersStartUtc)
            .lt('created_at', ordersEndUtc)
            .order('created_at', ascending: false),
        client.from('cart_items').select().order('id', ascending: true),
        client.rpc('get_unregistered_users').catchError((_) => <dynamic>[]),
        // Fetch deleted profiles for "Recently Deleted" section
        client.from('pharmacy_profiles').select().eq('is_deleted', true)
            .order('deleted_at', ascending: false).catchError((_) => <dynamic>[]),
        // CHANGE #369 — grouped WhatsApp leads for the Customer Orders tab.
        // MUST come solely from get_leads_grouped_today() — never a raw
        // pending_orders/whatsapp_messages read (backend already scopes to
        // today + order-list images only).
        client.rpc('get_leads_grouped_today').catchError((_) => <dynamic>[]),
      ]);

      final upRows       = results[0] as List;
      final ppRows       = results[1] as List;
      final orderRows    = results[2] as List;
      final cartRows     = results[3] as List;
      final authRows     = results[4] as List;
      final deletedList  = results[5] as List;
      final leadRowsRaw  = results[6] as List;

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
          orderNumber:   orderDisplayId(mo),
          orderStatus:   mo['status'] as String? ?? 'unknown',
          items:         _parseItems(mo['items']),
          total:         (mo['total_amount'] as num?)?.toDouble(),
          placedByAdmin: (mo['placed_by_admin'] as bool?) ?? false,
        ));
      }

      // CHANGE #369 — grouped WhatsApp leads, one Lead per sender phone.
      // The RPC returns sender_phone (not user_id), so resolve customer
      // name/pharmacy/approval via a phone-keyed lookup into pharmacy_profiles
      // (the uid-keyed upMap/ppMap above don't directly apply here).
      String digitsOnly(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');
      final ppByPhone = <String, Map<String, dynamic>>{};
      for (final p in ppRows) {
        final m = Map<String, dynamic>.from(p as Map);
        final ph = digitsOnly((m['whatsapp_no'] as String?) ?? (m['phone'] as String?) ?? '');
        if (ph.isNotEmpty) ppByPhone[ph] = m;
      }
      final leads = leadRowsRaw.map((r) {
        final m = Map<String, dynamic>.from(r as Map);
        final phoneDigits = digitsOnly((m['sender_phone'] as String?) ?? '');
        final pp = ppByPhone[phoneDigits];
        final resolvedName = pp != null ? _name(null, pp, null) : null;
        final resolvedPharmacy = pp != null ? _pharmacy(null, pp, null) : '';
        final resolvedIsApproved = pp?['approved'] == true;
        return Lead.fromRow(m,
            resolvedName: resolvedName,
            resolvedPharmacy: resolvedPharmacy,
            resolvedIsApproved: resolvedIsApproved);
      }).toList();

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
          _leads        = leads;
          _loading      = false;
        });
        RenderLog.write('c444_cust_orders', '${orders.length}');
        // CHANGE #369 — "Delete order" button removed from real orders (they're
        // permanent); this key now records that removal instead of the old
        // button-present claim.
        RenderLog.write('c186_delete_order',
            'change:369,button_present:false,reason:real_orders_are_permanent');
        // CHANGE #384 — fire-and-forget; never blocks the tab's own load.
        _loadMedicineBriefs(orders, carts);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        showToast(context, 'Failed to load: $e', isError: true);
      }
    } finally {
      _loadInFlight = false;
    }
    _loadLeads();
  }

  // CHANGE #384 — one batched MEDICINE lookup (by distinct product_id) for
  // the Customer Orders + cart item cards. Skips ids already cached so
  // re-expanding an order never refetches. Never throws into _load(); a
  // failed/partial fetch just leaves those item cards at name+qty+price.
  Future<void> _loadMedicineBriefs(
      List<_CustRow> orders, List<_CustRow> carts) async {
    final ids = <int>{};
    for (final row in [...orders, ...carts]) {
      for (final item in [...row.items, ...row.removedItems]) {
        final pid = int.tryParse(item.productId ?? '');
        if (pid != null && !_medBriefs.containsKey(pid)) ids.add(pid);
      }
    }
    if (ids.isEmpty) return;
    final idList = ids.toList();
    final fetched = <int, Map<String, dynamic>>{};
    try {
      final client = Supabase.instance.client;
      for (var i = 0; i < idList.length; i += 300) {
        final chunk =
            idList.sublist(i, i + 300 > idList.length ? idList.length : i + 300);
        final rows = await client
            .from('MEDICINE')
            .select(
                'id, image_url_1, marketer, pack_qty, pack_type, pack_size, salt_composition')
            .inFilter('id', chunk) as List;
        for (final r in rows) {
          final m = Map<String, dynamic>.from(r as Map);
          fetched[(m['id'] as num).toInt()] = m;
        }
      }
    } catch (_) {
      // Silent — cards degrade to name+qty+price only.
    }
    if (mounted && fetched.isNotEmpty) {
      setState(() => _medBriefs.addAll(fetched));
    }
  }

  // CHANGE #384 — null-safe MEDICINE display fields for one order/cart item,
  // with the same pack fallback chain as Product.fromMap (pack_qty →
  // pack_size → pack_type). Unknown/uncached product_id yields all nulls so
  // the card just omits those lines rather than fabricating text.
  Map<String, String?> _medDisplayFields(String? productId) {
    final pid = int.tryParse(productId ?? '');
    final brief = pid != null ? _medBriefs[pid] : null;
    String? nz(String? s) => (s != null && s.trim().isNotEmpty) ? s.trim() : null;
    final pack = nz(brief?['pack_qty'] as String?) ??
        nz(brief?['pack_size'] as String?) ??
        nz(brief?['pack_type'] as String?);
    return {
      'image': nz(brief?['image_url_1'] as String?),
      'company': nz(brief?['marketer'] as String?),
      'pack': pack,
      'composition': nz(brief?['salt_composition'] as String?),
    };
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
      case _CustFilter.leads:
      case _CustFilter.sLeads:
      case _CustFilter.routes:
        return [];
    }
  }

  bool get _isRegView      => _filter == _CustFilter.pendingRegistrations;
  bool get _isApprovedView => _filter == _CustFilter.approvedCustomers;
  bool get _isLeadsView    => _filter == _CustFilter.leads;
  bool get _isSLeadsView   => _filter == _CustFilter.sLeads;
  bool get _isRoutesView   => _filter == _CustFilter.routes;

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
            // CHANGE #508 D: this screen only ever deals with pharmacy/customer
            // registrations — explicit for clarity alongside the same call in
            // admin_alert_overlay.dart, which also handles suppliers.
            'ptype': 'customer',
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
        _expanded.clear();
        _payOpen.clear();
        _waOpen.clear();
        _expanded.add(key);
        onExpand?.call();
      }
    });
  }

  void _togglePayOpen(String orderId) {
    setState(() {
      final wasOpen = _payOpen[orderId] == true;
      _expanded.clear();
      _payOpen.clear();
      _waOpen.clear();
      if (!wasOpen) _payOpen[orderId] = true;
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
        for (final r in rows) {
          final m = r as Map;
          RenderLog.write('order_item_rpc_row',
              '${m['product_name']}:pid=${m['product_id']}:status=${m['current_status']}:sup=${m['current_supplier']}');
        }
      }
    } catch (e) {
      RenderLog.write('order_item_status_error', 'orderId:$orderId err:$e');
    }
  }

  // ── CHANGE #370 — Delete order (re-added; #369 removed it on purpose for
  // the build/test loop, #370 brings it back). Deletes the order's whole
  // graph server-side and resets the source WhatsApp lead back to 'pending'
  // so it reappears in Leads for re-conversion. No manual list mutation here:
  // orders/order_items/pending_orders are all in the #369 realtime
  // subscription, so the order disappears and the lead reappears on their own.
  final Set<String> _deletingOrders = {};

  Future<void> _deleteOrder(_CustRow row) async {
    final orderId = row.orderId;
    if (orderId == null || _deletingOrders.contains(orderId)) return;
    final code = row.orderNumber ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('Delete order $code?'),
        content: const Text(
            'This permanently removes the order, its items, supplier orders, '
            'disputes and payments. The WhatsApp lead will be restored so you '
            'can convert it again.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (mounted) setState(() => _deletingOrders.add(orderId));
    RenderLog.write('co_order_delete_370', 'orderId:$orderId,code:$code');
    try {
      final res = await Supabase.instance.client
          .rpc('delete_order', params: {'p_order_id': orderId});
      final map = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;
      if (map['error'] != null) {
        showToast(context, 'Delete failed: ${map['error']}', isError: true);
      } else {
        showToast(context, 'Order deleted — lead restored');
      }
    } catch (e) {
      if (mounted) showToast(context, 'Delete error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _deletingOrders.remove(orderId));
    }
  }

  // CHANGE #464: "Upload Bill" moved here from the customer/acting-as-customer
  // order card (#463) — admin-only surface, same upload_customer_bill RPC and
  // customer-bills/<order_id>/... storage key, just relocated. _uploadingBillFor
  // (a Set, per orderId) guards each row's own double-tap independently.
  // _billUploadEpoch bumps on every successful upload and keys _AdminBillView
  // below so an expanded row's bill tile fully remounts and refetches (a plain
  // setState wouldn't reset that widget's own already-fetched state).
  final Set<String> _uploadingBillFor = {};
  int _billUploadEpoch = 0;

  Future<void> _uploadCustomerBillFor(String orderId) async {
    if (_uploadingBillFor.contains(orderId)) return;
    setState(() => _uploadingBillFor.add(orderId));
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
        allowMultiple: false,
        withData: true,
      );
      final picked = result?.files.singleOrNull;
      final bytes = picked?.bytes;
      if (picked == null || bytes == null) return; // user cancelled the picker
      if (bytes.length > 15 * 1024 * 1024) {
        if (mounted) showToast(context, 'File too large (max 15MB)', isError: true);
        return;
      }
      // Namespaced by order_id so files can't collide across orders.
      final path = '$orderId/${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
      await Supabase.instance.client.storage.from('customer-bills').uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: _mimeFromBillName(picked.name)),
          );
      final raw = await Supabase.instance.client.rpc('upload_customer_bill', params: {
        'p_order_id': orderId,
        'p_file_path': path,
        'p_file_name': picked.name,
        'p_bucket': 'customer-bills',
      });
      final res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (!mounted) return;
      if (res['status'] == 'ok') {
        showToast(context, 'Bill uploaded');
        setState(() => _billUploadEpoch++); // remount _AdminBillView so it refetches
      } else {
        showToast(context, res['error']?.toString() ?? 'Could not upload the bill', isError: true);
      }
    } catch (_) {
      if (mounted) showToast(context, 'Could not upload the bill', isError: true);
    } finally {
      if (mounted) setState(() => _uploadingBillFor.remove(orderId));
    }
  }

  // CHANGE #464: "Upload Bill" (left) / "View Payment" (right) — the same
  // two-button row style built for #463's (now-removed) customer-card row.
  Widget _buildUploadBillAndPayRow(_CustRow row, {required VoidCallback onViewPayTap}) {
    final orderId = row.orderId;
    if (orderId == null) return const SizedBox();
    final uploading = _uploadingBillFor.contains(orderId);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: uploading ? null : () => _uploadCustomerBillFor(orderId),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFFF5F6F8),
            border: Border.all(color: const Color(0xFFD1D5DB)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: uploading
              ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
              : const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.upload_outlined, size: 13, color: Color(0xFF374151)),
                  SizedBox(width: 4),
                  Text('Upload Bill',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                ]),
        ),
      ),
      const SizedBox(width: 6),
      _ViewPayBtn(
        isOpen: _payOpen[orderId] == true,
        onTap: onViewPayTap,
        onLongPress: () => showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => CashPaymentSheet(
            orderId: orderId,
            onSuccess: () => setState(() {}),
          ),
        ),
      ),
    ]);
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

      RenderLog.write('c478_page_physics_dynamic', 1);
      return PrimaryScrollController(
        controller: _scrollCtrl,
        // CHANGE #478 (fix v2): freeze this page's own scroll for as long as
        // a finger is down on the route map (routeMapTouchLock, flipped by
        // route_google_map_panel.dart), so dragging the map never also
        // scrolls this page. See route_google_map_panel.dart for why.
        child: ValueListenableBuilder<bool>(
          valueListenable: routeMapTouchLock,
          builder: (ctx2, mapTouched, child) => SingleChildScrollView(
            primary: true,
            physics: mapTouched
                ? const NeverScrollableScrollPhysics()
                : const AlwaysScrollableScrollPhysics(),
            child: child,
          ),
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
    // S Leads tab (CHANGE #443 — scraped lead-generation UI)
    if (_isSLeadsView) {
      RenderLog.write('c443_tab_present', 1);
      return _SLeadsTab(
        isDesktop: isDesktop,
        onTotalChanged: (n) {
          if (mounted) setState(() => _sLeadsTotal = n);
        },
      );
    }
    // Routes tab (CHANGE #445 — zones -> ordered visiting route)
    if (_isRoutesView) {
      RenderLog.write('c445_tab_present', 1);
      return _RoutesTab(
        isDesktop: isDesktop,
        onZonesChanged: (n) {
          if (mounted) setState(() => _routesZones = n);
        },
        onOpenWarehouseCard: () => setState(() => _filter = _CustFilter.sLeads),
      );
    }
    // Leads tab
    if (_isLeadsView) return _buildLeadsContent(isDesktop);
    // Approved customers view
    if (_isApprovedView) {
      RenderLog.write('c367_wa_removed', 'tab:customers');
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
    // CHANGE #369 — Leads (grouped WhatsApp order-photo customers) show ABOVE
    // orders, only on the Customer Orders tab (not Cart). If there are none,
    // nothing is rendered for the leads section at all.
    final showLeads = _filter == _CustFilter.customerOrders && _leads.isNotEmpty;
    if (showLeads) {
      RenderLog.write('c367_lead_above', 'leads:${_leads.length},orders:${rows.length}');
    }
    if (rows.isEmpty && !showLeads) {
      return _ssvEmptyState(
        _filter == _CustFilter.customerOrders
            ? '0 orders'
            : '0 customers with unpurchased cart items',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLeads) ..._buildLeadsSection(isDesktop),
        if (rows.isNotEmpty) ...[
          if (isDesktop) _buildCustTableHeader(),
          ...rows.map(
            (r) => isDesktop ? _buildDesktopCustRow(r) : _buildMobileCustCard(r)),
        ] else if (showLeads)
          _ssvEmptyState('0 orders'),
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
      child: Builder(builder: (_) {
        RenderLog.write('titles_removed_customers', 'true');
        RenderLog.write('customer_tabs_horizontal_scroll', 'true');
        RenderLog.write('c212_tab_removed', 1);
        // Single row: tabs scroll in Expanded, refresh pinned right — no vertical stacking.
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
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
                const SizedBox(width: 4),
                _tab(_CustFilter.sLeads, 'S Leads ($_sLeadsTotal)'),
                const SizedBox(width: 4),
                _tab(_CustFilter.routes, 'Routes ($_routesZones)'),
              ]),
            ),
          ),
          // CHANGE #444 — Customer Orders' own date-scope chip, no pill.
          if (_filter == _CustFilter.customerOrders) ...[
            const SizedBox(width: 8),
            Builder(builder: (context) {
              // Distinct key from the Fulfill screen's c444_chip_label — both
              // screens can be mounted in the same render-log session.
              RenderLog.write('c444_cust_chip_label',
                  isSameDay(_ordersDate, todayIst())
                      ? 'Today · ${dmy(_ordersDate)}'
                      : dmy(_ordersDate));
              return DateScopeChip(
                selected: _ordersDate,
                isToday: isSameDay(_ordersDate, todayIst()),
                onChanged: _onOrdersDateChanged,
              );
            }),
          ],
        ]);
      }),
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
          // Auto-load fresh data on every tab open (debounced).
          _autoLoad(key: f.name);
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
  // CHANGE #369 — WHATSAPP LEADS section (shown ABOVE Orders, Customer Orders tab)
  // One card per customer (grouped by sender phone), each listing its order-list
  // photos as "Order N" tiles with inline Delete/Convert actions. Fed solely by
  // get_leads_grouped_today() — see _load().
  // ═══════════════════════════════════════════════════════════════════════════

  List<Widget> _buildLeadsSection(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    RenderLog.write('co_leads_grouped_369', 'leads:${_leads.length}');
    return [
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 20, pad, 8),
        child: Row(children: [
          const Icon(Icons.chat_outlined, size: 15, color: Color(0xFF4338CA)),
          const SizedBox(width: 6),
          Text('Leads (${_leads.length})',
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF4338CA))),
        ]),
      ),
      ..._leads.map((l) => _buildLeadCard(l, pad: pad)),
      SizedBox(height: isDesktop ? 20 : 16),
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
        child: const Text('Orders',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
      ),
    ];
  }

  Widget _buildLeadCard(Lead lead, {required double pad}) {
    final displayName =
        (lead.customerName != null && lead.customerName!.trim().isNotEmpty)
            ? lead.customerName!.trim()
            : (lead.senderPhone.isNotEmpty ? lead.senderPhone : 'Unknown');
    return Container(
      margin: EdgeInsets.fromLTRB(pad, 0, pad, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          IconButton(
            onPressed: () => _deleteLeadGroup(lead),
            icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFDC2626)),
            tooltip: 'Delete all order lists from today',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(displayName,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                overflow: TextOverflow.ellipsis),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: const Color(0xFFEEF2FF), borderRadius: BorderRadius.circular(20)),
            child: Text('${lead.leadCount}',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF4338CA))),
          ),
        ]),
        if (lead.pharmacy.isNotEmpty) ...[
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Text(lead.pharmacy,
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                overflow: TextOverflow.ellipsis),
          ),
        ],
        ...lead.images.map((img) => _LeadImageTile(
              lead: lead,
              image: img,
              onDelete: _deleteLeadImage,
              onConvert: _convertLeadImage,
            )),
      ]),
    );
  }

  // ── CHANGE #369 — lead group / image delete + convert handlers ───────────────

  Future<void> _deleteLeadGroup(Lead lead) async {
    final displayName =
        (lead.customerName != null && lead.customerName!.trim().isNotEmpty)
            ? lead.customerName!.trim()
            : lead.senderPhone;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('Delete all order lists from $displayName today?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFDC2626)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    RenderLog.write('co_lead_delete_369', 'group:${lead.senderPhone}');
    try {
      await Supabase.instance.client
          .rpc('delete_lead_group', params: {'p_sender_phone': lead.senderPhone});
      if (mounted) {
        setState(() {
          _leads = _leads.where((l) => l.senderPhone != lead.senderPhone).toList();
        });
      }
    } catch (e) {
      if (mounted) showToast(context, 'Delete failed: $e', isError: true);
    }
  }

  Future<void> _deleteLeadImage(LeadImage img) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Delete this order list?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFDC2626)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    RenderLog.write('co_lead_delete_369', 'image:${img.id}');
    try {
      await Supabase.instance.client.rpc('delete_lead_image', params: {'p_id': img.id});
      if (mounted) {
        setState(() {
          _leads = _leads
              .map((l) {
                if (!l.images.any((i) => i.id == img.id)) return l;
                final remaining = l.images.where((i) => i.id != img.id).toList();
                return Lead(
                  senderPhone: l.senderPhone,
                  customerName: l.customerName,
                  pharmacy: l.pharmacy,
                  leadCount: remaining.length,
                  images: remaining,
                  isApproved: l.isApproved,
                );
              })
              .where((l) => l.images.isNotEmpty)
              .toList();
        });
      }
    } catch (e) {
      if (mounted) showToast(context, 'Delete failed: $e', isError: true);
    }
  }

  Future<void> _convertLeadImage(Lead lead, LeadImage image) async {
    final viewAs = ViewAsState.of(context);
    final scaffoldCtx = context;
    final res = await Supabase.instance.client
        .rpc('wa_convert_start', params: {'p_image_id': image.id});
    final data = Map<String, dynamic>.from(res as Map);
    if (data['ok'] != true) {
      if (mounted) showToast(scaffoldCtx, 'Convert start failed', isError: true);
      return;
    }
    final filePath = data['file_path'] as String;
    final userId = data['user_id'] as String;

    final bytes = await Supabase.instance.client.storage
        .from('whatsapp-media')
        .download(filePath);

    if (!mounted) return;

    final displayName =
        (lead.customerName != null && lead.customerName!.trim().isNotEmpty)
            ? lead.customerName!.trim()
            : lead.senderPhone;

    // CHANGE #374 — root cause of the false "pending approval" / "Not
    // Registered" bug: `lead.isApproved` was resolved in _load() via a
    // fragile phone-digit match against pharmacy_profiles (ppByPhone), which
    // silently defaults to false on any format mismatch, and `id` below was
    // wrongly set to the auth user id instead of the pharmacy_profiles row
    // id. Both fed straight into the ViewAs identity that the checkout gate
    // (cart_screen.dart) and My Profile screen key off. Read
    // pharmacy_profiles fresh here, keyed by the authoritative `userId` from
    // wa_convert_start, instead of trusting the phone-matched lead fields.
    Map<String, dynamic>? profRow;
    try {
      profRow = await Supabase.instance.client
          .from('pharmacy_profiles')
          .select()
          .eq('user_id', userId)
          .maybeSingle();
    } catch (_) {}
    if (!mounted) return;
    final isApproved = profRow?['approved'] == true &&
        profRow?['status'] != 'suspended' &&
        profRow?['is_deleted'] != true;
    final resolvedPharmacyName =
        (profRow?['pharmacy_name'] as String?)?.trim().isNotEmpty == true
            ? (profRow!['pharmacy_name'] as String).trim()
            : (lead.pharmacy.isNotEmpty ? lead.pharmacy : displayName);
    viewAs.activate(
      ViewAsRole.customer,
      ViewAsIdentity(
        id: (profRow?['id'] as String?) ?? userId,
        name: resolvedPharmacyName,
        email: '',
        userId: userId,
        isApproved: isApproved,
      ),
    );

    RenderLog.write('c367_convert', 'image:${image.id},phone:${lead.senderPhone}');

    WidgetsBinding.instance.addPostFrameCallback((_) {
      BulkUploadScreen.startWaConvert(
        imageBytes: bytes,
        mimeType: 'image/jpeg',
        imageName: 'wa_order_${image.id.substring(0, 8)}.jpg',
        imageId: image.id,
        userId: userId,
        customerName: displayName,
        pharmacy: lead.pharmacy,
        phone: lead.senderPhone,
        address: '',
        isApproved: isApproved,
      );
      BulkUploadScreen.navToBulkUpload?.call();
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CUSTOMER ORDERS / CART views (unchanged)
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildCustTableHeader() {
    final isCart = _filter == _CustFilter.cartNotOrdered;
    if (!isCart) RenderLog.write('c213_action_col_removed', 1); // CHANGE #213
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
          // CHANGE #464: widened 2→4 to fit "Upload Bill" alongside "View Payment".
          _th('PAYMENT', flex: 4),  // CHANGE #213 — was ACTION
          const SizedBox(width: 32),
        ],
      ]),
    );
  }

  Widget _buildDesktopCustRow(_CustRow row) {
    final key        = row.orderId ?? row.userId;
    final isExpanded = _expanded.contains(key);
    final isCart     = _filter == _CustFilter.cartNotOrdered;
    // CHANGE #369 — the per-order WhatsApp button (CHANGE #322) that used to
    // render here (and its "Received/Processed/Left" chip row, only reachable
    // through that button's _WaOrderPanel) has been removed; see GAP 7/5a.
    RenderLog.write('cust_wa_btn_removed_369', 'row:${row.orderId ?? row.userId}');
    RenderLog.write('co_order_chips_removed_369',
        'received_processed_left_chips_lived_in_removed_WaOrderPanel_only');

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
              // CHANGE #213 — View Payment replaces ACTION column
              // CHANGE #464 — "Upload Bill" added to the left of View Payment.
              Expanded(
                  flex: 4,
                  child: row.orderId != null
                      ? GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {},
                          child: _buildUploadBillAndPayRow(row,
                              onViewPayTap: () => _togglePayOpen(row.orderId!)),
                        )
                      : const SizedBox()),
            ],
            // CHANGE #370 — Delete order (re-added; #369 removed it on purpose).
            // Only on real converted orders, immediately left of the chevron.
            if (row.orderId != null)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {}, // absorb tap so it doesn't also toggle row expand
                child: IconButton(
                  onPressed: _deletingOrders.contains(row.orderId)
                      ? null
                      : () => _deleteOrder(row),
                  icon: _deletingOrders.contains(row.orderId)
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Color(0xFFDC2626)))
                      : const Icon(Icons.delete_outline,
                          size: 18, color: Color(0xFFDC2626)),
                  tooltip: 'Delete order',
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ),
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
      // CHANGE #213 — per-order payment panel
      if (row.orderId != null && _payOpen[row.orderId] == true)
        _OrderPaymentPanel(
          orderId: row.orderId!,
          orderNumber: row.orderNumber,
          onStatusChanged: () => _load(showSpinner: false),
        ),
      // CHANGE #369 — the per-order WhatsApp button/panel (CHANGE #322) was
      // removed here: it exposed every WhatsApp photo for this customer, which
      // is now redundant with (and a bypass of) the scoped Leads section above.
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
                // CHANGE #370 — Delete order (re-added; #369 removed it on
                // purpose). Only on real converted orders, left of the chevron.
                if (row.orderId != null)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {}, // absorb tap so it doesn't also expand the card
                    child: IconButton(
                      onPressed: _deletingOrders.contains(row.orderId)
                          ? null
                          : () => _deleteOrder(row),
                      icon: _deletingOrders.contains(row.orderId)
                          ? const SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Color(0xFFDC2626)))
                          : const Icon(Icons.delete_outline,
                              size: 16, color: Color(0xFFDC2626)),
                      tooltip: 'Delete order',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    ),
                  ),
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
                // CHANGE #213 — View Payment (mobile)
                // CHANGE #464 — "Upload Bill" added to the left of View Payment.
                if (row.orderId != null) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: _buildUploadBillAndPayRow(row,
                        onViewPayTap: () => setState(() =>
                            _payOpen[row.orderId!] =
                                !(_payOpen[row.orderId!] ?? false))),
                  ),
                ],
              ],
            ]),
          ),
          // CHANGE #213 — per-order payment panel (mobile)
          if (row.orderId != null && _payOpen[row.orderId] == true)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: _OrderPaymentPanel(
                orderId: row.orderId!,
                orderNumber: row.orderNumber,
                onStatusChanged: () => _load(showSpinner: false),
              ),
            ),
          // CHANGE #369 — the per-order WhatsApp button/panel (CHANGE #322) was
          // removed here (mobile); see the desktop row for the rationale.
          if (isExpanded) ...[
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            _buildExpandedItems(row, isDesktop: false),
          ],
        ]),
      ),
    );
  }

  Widget _itemInquiryBadge(String? status, String? supplier) {
    if (status == null || status == 'Not in inquiry' || status == '—') {
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
      label = supplier != null && supplier.isNotEmpty ? 'Available — $supplier' : 'Available';
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

  // CHANGE #382/384 — Customer Orders item-row thumbnail. Same
  // Image.network+errorBuilder pattern as widgets/order_item_card.dart
  // (_buildImageTile): null/empty url renders the placeholder directly;
  // a broken image URL falls back to the same placeholder via errorBuilder.
  // Never shows a broken-image glyph. isDesktop bumps the tile slightly on
  // wider viewports (72) vs mobile (64).
  Widget _custOrderItemThumb(String? imageUrl, {bool isDesktop = false}) {
    final size = isDesktop ? 72.0 : 64.0;
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Image.network(
          imageUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _custOrderItemThumbPlaceholder(size),
        ),
      );
    }
    return _custOrderItemThumbPlaceholder(size);
  }

  Widget _custOrderItemThumbPlaceholder(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6F8),
        borderRadius: BorderRadius.circular(13),
      ),
      child: const Icon(Icons.medication_outlined, size: 28, color: Color(0xFFD1D5DB)),
    );
  }

  // CHANGE #442 — qty pill for the Customer Orders item row now takes the
  // server-formatted qty_label ("3 Strips") instead of a bare number.
  Widget _custOrderItemQtyPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Text(label,
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E40AF))),
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
    final rawStatuses = row.orderId != null
        ? (_orderItemStatuses[row.orderId!] ?? <Map<String, dynamic>>[])
        : <Map<String, dynamic>>[];

    // orders.items JSONB has product_name but no product_id — match by normalized name
    String _norm(String s) => s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    final statusByName = <String, Map<String, dynamic>>{};
    for (final s in rawStatuses) {
      final pname = s['product_name'] as String?;
      if (pname != null) statusByName[_norm(pname)] = s;
    }

    RenderLog.write('order_items_expanded',
        'orderId:${row.orderId ?? "?"}:items:${row.items.length}:statuses:${rawStatuses.length}');

    // Per-item resolved status instrumentation
    var anyDash = false;
    for (final item in row.items) {
      final s = statusByName[_norm(item.name)];
      final resolved = s?['current_status'] as String? ?? '—';
      if (resolved == '—') anyDash = true;
      RenderLog.write('order_item_resolved',
          '${item.name}:status=$resolved:supplier=${s?['current_supplier'] ?? "none"}');
    }
    if (anyDash && rawStatuses.isNotEmpty) {
      RenderLog.write('order_item_FAIL', 'accepted order has dash items — name mismatch?');
    }

    // CHANGE #442 — instrumentation counters for image/company/pack/qty_label
    // coverage across this order's item cards, written once per card below.
    var c442Total = 0, c442Image = 0, c442Company = 0, c442Pack = 0, c442Qty = 0;
    String? c442Sample;

    final content = Container(
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
        // CHANGE #463 Part C: admin bill view — same uploaded file the
        // customer Bill tab shows, view + download. Renders nothing while
        // loading or when no bill has been uploaded yet, so it never disturbs
        // this card's existing layout for orders without one.
        // CHANGE #464: keyed by _billUploadEpoch so a successful upload from
        // the new Upload Bill button forces this tile to remount and refetch.
        if (row.orderId != null)
          _AdminBillView(key: ValueKey('${row.orderId}_$_billUploadEpoch'), orderId: row.orderId!),
        const SizedBox(height: 8),
        Text(label,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151))),
        const SizedBox(height: 8),
        // CHANGE #382 — replaced the fixed 4-column Product/Qty/Price/Status
        // table (its fixed-width header cells wrapped "Product" to vertical
        // letters on narrow admin viewports) with a responsive per-item row:
        // thumbnail + name/pack/company/qty+price+status. Status pill logic
        // (_itemInquiryBadge above, untouched) and every other field on this
        // card — total, "Order Items (N)" count, Accept/Reject, View
        // Payment, delete — are unchanged; only this item-row layout changed.
        ...row.items.map((item) {
          final s = statusByName[_norm(item.name)];
          final currentStatus   = s?['current_status'] as String?;
          final currentSupplier = s?['current_supplier'] as String?;
          try {
            RenderLog.write('cust_order_items_redesign_382',
                'orderId:${row.orderId ?? "?"}:item:${item.name}');
          } catch (_) {}

          // Null-guarded derived text — a missing value hides its line/token,
          // never renders "null"/"undefined"/"NaN"/"₹null".
          // CHANGE #442 — image/company/pack/qty_label now come straight off
          // `s`, the get_order_item_inquiry_status row already matched by
          // normalized product name above. That RPC now returns these fields
          // pre-formatted server-side (image_url, company, pack_label,
          // qty_label) — no client-side MEDICINE lookup, no string logic here.
          // The old CHANGE #384 MEDICINE-table lookup (_medDisplayFields) is
          // left in place for cart_items (_buildCartExpandedItems) where a
          // real product_id column exists; real orders never populated it
          // reliably (orders.items JSONB product_id is unreliable), which was
          // the actual root cause of this bug.
          String? nz(String? s) => (s != null && s.trim().isNotEmpty) ? s.trim() : null;
          final imageUrl = nz(s?['image_url'] as String?);
          final company = nz(s?['company'] as String?);
          final packLine = nz(s?['pack_label'] as String?) ??
              (item.packSize?.trim().isNotEmpty == true ? item.packSize!.trim() : null);
          final qtyLabel = nz(s?['qty_label'] as String?) ?? '${item.qty}';
          c442Total++;
          if (imageUrl != null) c442Image++;
          if (company != null) c442Company++;
          if (packLine != null) c442Pack++;
          if (nz(s?['qty_label'] as String?) != null) c442Qty++;
          c442Sample ??= '${item.name}|$qtyLabel|${packLine ?? ''}|${company ?? ''}';
          final priceVal = (item.price != null && item.price! > 0)
              ? item.price
              : ((item.mrp != null && item.mrp! > 0) ? item.mrp : null);
          final priceText =
              priceVal != null ? '₹${priceVal.toStringAsFixed(2)}' : null;

          return Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _custOrderItemThumb(imageUrl, isDesktop: isDesktop),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF111827))),
                    if (company != null) ...[
                      const SizedBox(height: 2),
                      Text(company,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF9CA3AF),
                              letterSpacing: 0.8)),
                    ],
                    if (packLine != null) ...[
                      const SizedBox(height: 2),
                      Text(packLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, color: Color(0xFF6B7280))),
                    ],
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _custOrderItemQtyPill(qtyLabel),
                        if (priceText != null)
                          Text(priceText,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF111827))),
                        _itemInquiryBadge(currentStatus, currentSupplier),
                      ],
                    ),
                  ],
                ),
              ),
            ]),
          );
        }),
        // CHANGE #369 — the "Delete order" button was removed here: real orders
        // are permanent once placed and admins get no delete option for them.
        // (Leads still have their own delete via delete_lead_image/
        // delete_lead_group in the grouped Leads section above.)
      ]),
    );
    // CHANGE #442 — render-log proof that image/company/pack/qty_label
    // resolved from the RPC row, not just compiled into the bundle.
    RenderLog.write('c442_items_total', c442Total);
    RenderLog.write('c442_with_image', c442Image);
    RenderLog.write('c442_with_company', c442Company);
    RenderLog.write('c442_with_pack', c442Pack);
    RenderLog.write('c442_with_qtylabel', c442Qty);
    if (c442Sample != null) RenderLog.write('c442_sample', c442Sample!);
    return content;
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
              ...row.items.map((item) {
                RenderLog.write('cart_items_desktop_table', 'true');
                return Padding(
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
                  );
              }),
            ] else ...[
              // Mobile: 3-line stacked layout (no horizontal scroll, no clipping)
              ...row.items.map((item) {
                RenderLog.write('cart_items_mobile_3line', 'true');
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Line 1: product name (left, bold, single-line) | qty (right)
                          Builder(builder: (_) {
                            RenderLog.write('product_name_single_line', 'true');
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Text(item.name,
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF111827),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text('×${item.qty}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0xFF6B7280),
                                  ),
                                ),
                              ],
                            );
                          }),
                          const SizedBox(height: 4),
                          // Line 2: pack size (left, grey) | MRP (right)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: Text(
                                  (item.packSize?.isNotEmpty == true) ? item.packSize! : '—',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF6B7280),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                item.mrp != null ? '₹${item.mrp!.toStringAsFixed(0)}' : '—',
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF374151),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          // Line 3: added/removed-by (left) | Remove (right)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              _addedByBadge(item.addedBy),
                              const Spacer(),
                              if (item.id != null)
                                GestureDetector(
                                  onTap: () => _adminSoftRemoveItem(item.id!),
                                  child: const Text('Remove',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFFDC2626),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Color(0xFFF3F4F6)),
                  ],
                );
              }),
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
                // Name line: [Full customer/pharmacy name] [Active status badge]
                Builder(builder: (_) {
                  RenderLog.write('customer_card_restructured', 'true');
                  return const SizedBox.shrink();
                }),
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
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
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  _CustomerStatusBadge(status: row.status),
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

  // Format a DB timestamp value as DD/MM/YYYY HH:MM (IST); returns '' on failure.
  static String _fmtTs(dynamic v) {
    final s = _str(v);
    if (s.isEmpty) return '';
    try {
      final dt = istFromDb(s);
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
    RenderLog.write('c322_source_col', 'source:$source');
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
        constraints: BoxConstraints(maxWidth: 480, maxHeight: MediaQuery.of(context).size.height * 0.88),
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
        constraints: BoxConstraints(maxWidth: 580, maxHeight: MediaQuery.of(context).size.height * 0.88),
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

// ── CHANGE #213 — helpers ─────────────────────────────────────────────────────

String _rupee(num? v) {
  if (v == null) return '₹—';
  final d = v.toDouble();
  return d == d.truncateToDouble() ? '₹${v.toInt()}' : '₹${d.toStringAsFixed(2)}';
}

// ── View Payment toggle button ────────────────────────────────────────────────

class _ViewPayBtn extends StatelessWidget {
  final bool isOpen;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _ViewPayBtn({required this.isOpen, required this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c213_viewpay_built', 1);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: isOpen ? const Color(0xFFEFF6FF) : const Color(0xFFF5F6F8),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isOpen
                ? const Color(0xFF1E40AF).withValues(alpha: 0.4)
                : const Color(0xFFE5E7EB),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(
            'View Payment',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isOpen ? const Color(0xFF1E40AF) : const Color(0xFF374151),
            ),
          ),
          const SizedBox(width: 4),
          AnimatedRotation(
            turns: isOpen ? 0.5 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: Icon(
              Icons.expand_more,
              size: 14,
              color: isOpen ? const Color(0xFF1E40AF) : const Color(0xFF6B7280),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Bucket summary card (Level 1) — CHANGE #214 polish ───────────────────────

// CHANGE #215 — running-total bucket card
class _BucketCard extends StatelessWidget {
  final String title;
  final num? expected;      // adjusted expected (post advance-carry for rest)
  final num? received;
  final num? remaining;
  final num? extra;
  final bool fully;
  final num? advanceCarry;  // rest bucket: >0 means carry was applied
  final int count;
  final bool isOpen;
  final VoidCallback onTap;
  const _BucketCard({
    required this.title,
    required this.expected,
    required this.received,
    required this.remaining,
    required this.extra,
    required this.fully,
    required this.count,
    required this.isOpen,
    required this.onTap,
    this.advanceCarry,
  });

  @override
  Widget build(BuildContext context) {
    final rec = (received ?? 0).toDouble();
    final exp = (expected ?? 0).toDouble();
    final ext = (extra ?? 0).toDouble();
    final rem = (remaining ?? 0).toDouble();

    // ── Status pill ───────────────────────────────────────────────
    final Color pillBg, pillFg;
    final String pillLabel;
    if (rec == 0) {
      pillBg = const Color(0xFFF3F4F6); pillFg = const Color(0xFF9CA3AF);
      pillLabel = 'Not received';
    } else if (fully || (exp > 0 && rec >= exp)) {
      pillBg = const Color(0xFFD1FAE5); pillFg = const Color(0xFF065F46);
      pillLabel = ext > 0
          ? 'Fully paid ✓ · +${_rupee(ext)} extra'
          : 'Fully paid ✓';
    } else {
      pillBg = const Color(0xFFFEF3C7); pillFg = const Color(0xFF92400E);
      pillLabel = rem > 0
          ? 'Partial · ${_rupee(rem)} left'
          : 'Partial';
    }

    return GestureDetector(
      onTap: count > 0 ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isOpen
                ? const Color(0xFF1B7A43).withValues(alpha: 0.3)
                : const Color(0xFFE5E7EB),
          ),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Left: title + carry note + subtitle ───────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title row
                Row(children: [
                  Flexible(
                    child: Text(title,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF111827))),
                  ),
                  if (count > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                          color: const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(10)),
                      child: Text('$count',
                          style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF6B7280))),
                    ),
                  ],
                ]),
                // Advance-carry note (rest bucket only)
                if ((advanceCarry ?? 0) > 0) ...[
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      'Advance extra ${_rupee(advanceCarry)} adjusted',
                      style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF1E40AF)),
                    ),
                  ),
                ],
                // Running-total subtitle
                if (expected != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Paid ${_rupee(received)} of ${_rupee(expected)}',
                    style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF6B7280)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          // ── Right: pill + chevron ─────────────────────────────────
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                constraints: const BoxConstraints(maxWidth: 160),
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                    color: pillBg, borderRadius: BorderRadius.circular(20)),
                child: Text(pillLabel,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: pillFg)),
              ),
              if (count > 0) ...[
                const SizedBox(height: 4),
                AnimatedRotation(
                  turns: isOpen ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 150),
                  child: const Icon(Icons.expand_more,
                      size: 16, color: Color(0xFF6B7280)),
                ),
              ],
            ],
          ),
        ]),
      ),
    );
  }
}

// ── CHANGE #463 Part C: admin bill view (view + download) ─────────────────────
// Shows the same admin-uploaded file (customer_bill_file) the customer Bill
// tab shows. Self-fetching; renders nothing while loading or when no bill has
// been uploaded, so orders without one see no extra UI.

String _mimeFromBillName(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  switch (ext) {
    case 'pdf':
      return 'application/pdf';
    case 'png':
      return 'image/png';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'webp':
      return 'image/webp';
    default:
      return 'application/octet-stream';
  }
}

class _AdminBillView extends StatefulWidget {
  final String orderId;
  const _AdminBillView({super.key, required this.orderId});

  @override
  State<_AdminBillView> createState() => _AdminBillViewState();
}

class _AdminBillViewState extends State<_AdminBillView> {
  Map<String, dynamic>? _info;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await Supabase.instance.client
          .rpc('customer_bill_file', params: {'p_order_id': widget.orderId});
      final data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (mounted) setState(() => _info = data);
    } catch (_) {
      if (mounted) setState(() => _info = {'has_file': false});
    }
  }

  Future<void> _view() async {
    final info = _info;
    if (info == null || info['has_file'] != true) return;
    try {
      final bucket = info['bucket']?.toString() ?? 'customer-bills';
      final path = info['path']?.toString() ?? '';
      final url = await Supabase.instance.client.storage.from(bucket).createSignedUrl(path, 3600);
      await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
    } catch (_) {
      if (mounted) showToast(context, 'Could not open the bill', isError: true);
    }
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null || info['has_file'] != true || _downloading) return;
    setState(() => _downloading = true);
    try {
      final bucket = info['bucket']?.toString() ?? 'customer-bills';
      final path = info['path']?.toString() ?? '';
      final name = info['name']?.toString() ?? 'Bill';
      final bytes = await Supabase.instance.client.storage.from(bucket).download(path);
      downloadBytes(bytes, name, _mimeFromBillName(name));
    } catch (_) {
      if (mounted) showToast(context, 'Could not download the bill', isError: true);
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (info == null || info['has_file'] != true) return const SizedBox.shrink();
    final name = info['name']?.toString() ?? 'Bill';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _view,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Row(children: [
            const Icon(Icons.receipt_long_outlined, size: 16, color: Color(0xFF1B7A43)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _downloading ? null : _download,
              child: _downloading
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.download_outlined, size: 16, color: Color(0xFF1B7A43)),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Per-order payment panel (3-level expandable) ──────────────────────────────

class _OrderPaymentPanel extends StatefulWidget {
  final String orderId;
  final String? orderNumber;
  final VoidCallback? onStatusChanged;
  const _OrderPaymentPanel({
    required this.orderId,
    this.orderNumber,
    this.onStatusChanged,
  });

  @override
  State<_OrderPaymentPanel> createState() => _OrderPaymentPanelState();
}

// ── CHANGE #217 — chip-row + dashboard payment view ──────────────────────────

class _OrderPaymentPanelState extends State<_OrderPaymentPanel> {
  Map<String, dynamic>? _data;
  List<PaymentClaim> _claims = [];
  String? _selectedClaimId;   // null = All dashboard view
  bool _loading = true;
  String? _error;
  final Set<String> _acting = {};
  final Map<String, String> _signedUrls = {};     // claimId → signed URL
  final Map<String, String> _imgViewTypes = {};   // claimId → HtmlElementView viewType
  RealtimeChannel? _paymentChannel;

  @override
  void initState() {
    super.initState();
    _load();
    _subscribePayClaims();
  }

  @override
  void dispose() {
    _paymentChannel?.unsubscribe();
    super.dispose();
  }

  void _subscribePayClaims() {
    _paymentChannel?.unsubscribe();
    // No order_id filter: online claims may arrive with order_id=null initially
    // (linked later by admin). Subscribe to ALL payment_claims changes and let
    // the RPC handle filtering. Belt-and-suspenders with the top-level list sub.
    _paymentChannel = Supabase.instance.client
        .channel('payclaims_${widget.orderId}')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'payment_claims',
          callback: (_) {
            if (mounted) _load();
          },
        )
        .subscribe();
    RenderLog.write('c227_payclaims_rt',
        'change:227,subscribed:true,table:payment_claims,covers:cash+online');
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final data = await PaymentClaimsService.orderPaymentView(widget.orderId);
      if (!mounted) return;
      final shortId = widget.orderId.length >= 8
          ? widget.orderId.substring(0, 8) : widget.orderId;
      final parsed = _parseClaims(data);
      RenderLog.write('c217_service_loaded', 1);
      RenderLog.write('c217_payview_loaded_$shortId', 1);
      setState(() { _data = data; _claims = parsed; _loading = false; });
      _loadSignedUrls(parsed);
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _loadSignedUrls(List<PaymentClaim> claims) async {
    for (final claim in claims) {
      if (claim.filePath == null || claim.filePath!.isEmpty) continue;
      if (_signedUrls.containsKey(claim.claimId)) continue;
      try {
        final url = await PaymentClaimsService.signedScreenshotUrl(claim.filePath!);
        if (url != null && mounted) {
          final vt = 'claim-img-${claim.claimId}';
          if (!_imgViewTypes.containsKey(claim.claimId)) {
            final capturedContext = context;
            ui_web.platformViewRegistry.registerViewFactory(vt, (int viewId) {
              final img = html.ImageElement()
                ..src = url
                ..style.width = '100%'
                ..style.height = '100%'
                ..style.objectFit = 'contain'
                ..style.background = '#F3F4F6'
                ..style.cursor = 'pointer';
              // Platform views absorb Flutter pointer events — use native onClick instead.
              img.onClick.listen((_) => openFullscreenImage(capturedContext, url));
              return img;
            });
          }
          setState(() {
            _signedUrls[claim.claimId] = url;
            _imgViewTypes[claim.claimId] = vt;
          });
        }
      } catch (_) {}
    }
    if (mounted) {
      RenderLog.write('c225_signed_urls_fix', 1);
      RenderLog.write('c228_payview_complete',
          'change:228,signed_urls:true,realtime:true,fullscreen:true,covers:cash+online');
      RenderLog.write('c229_img_fullscreen_fix',
          'change:229,thumb_onclick:true,fullscreen:true,covers:cash+online,buckets:whatsapp+cash_payments');
      RenderLog.write('c230_paycard_polish',
          'change:230,fullscreen_tap_close:true,copy_buttons:true,badges_removed:true,covers:cash+online');
      RenderLog.write('c232_copy_right',
          'change:232,copy_right_aligned:true,covers:cash+online');
    }
  }

  List<PaymentClaim> _parseClaims(Map<String, dynamic> d) {
    final adv  = Map<String,dynamic>.from(d['advance']     as Map? ?? {});
    final rest = Map<String,dynamic>.from(d['rest']        as Map? ?? {});
    final unassigned = List<Map<String,dynamic>>.from(d['unassigned'] as List? ?? []);
    final inactive   = List<Map<String,dynamic>>.from(d['inactive']   as List? ?? []);
    final seen = <String>{};
    final all  = <PaymentClaim>[];
    void add(List<dynamic> list, String bucket) {
      for (final c in list) {
        final m  = Map<String,dynamic>.from(c as Map);
        final id = m['claim_id'] as String? ?? '';
        if (id.isEmpty || seen.contains(id)) continue;
        seen.add(id);
        all.add(PaymentClaim.fromMap(m, bucket));
      }
    }
    add(adv['claims']  as List? ?? [], 'advance');
    add(rest['claims'] as List? ?? [], 'rest');
    add(unassigned, 'unassigned');
    add(inactive,   'inactive');
    // CHANGE #218 — sort by payment time (oldest first); fall back to paid_at; unknown → end
    DateTime? _parseTs(PaymentClaim c) {
      if (c.receivedAt != null && c.receivedAt!.isNotEmpty) {
        final dt = DateTime.tryParse(c.receivedAt!);
        if (dt != null) return dt;
      }
      if (c.paidAt != null && c.paidAt!.isNotEmpty) {
        return DateTime.tryParse(c.paidAt!);
      }
      return null;
    }
    final farFuture = DateTime(9999);
    all.sort((a, b) {
      final ta = _parseTs(a) ?? farFuture;
      final tb = _parseTs(b) ?? farFuture;
      return ta.compareTo(tb);
    });
    return all;
  }

  // ── Action: mark received (linked or unassigned via same RPC) ───────────────
  Future<void> _markReceived(String claimId, num? amount,
      {bool isUnassigned = false}) async {
    final orderId = widget.orderId;
    if (claimId.isEmpty || orderId.isEmpty) {
      RenderLog.write('c217_bad_id', 'claimId=$claimId orderId=$orderId');
      return;
    }
    final po  = widget.orderNumber ?? 'this order';
    final amtLabel = amount != null ? _rupee(amount) : 'this payment';
    final msg = isUnassigned
        ? 'Link $amtLabel to $po and mark received?\nCustomer gets a payment-received WhatsApp.'
        : 'Mark $amtLabel as received?\nCustomer gets a payment-received WhatsApp.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isUnassigned ? 'Link & Mark Received' : 'Mark Payment Received',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43), foregroundColor: Colors.white),
            child: const Text('Mark Received'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _acting.add(claimId));
    try {
      await PaymentClaimsService.markPaymentReceived(claimId, orderId);
      RenderLog.write('c217_received_ok', 1);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(isUnassigned ? 'Linked & marked received ✓' : 'Payment marked received ✓'),
            backgroundColor: const Color(0xFF1B7A43)),
      );
      widget.onStatusChanged?.call();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: $e'), backgroundColor: const Color(0xFFDC2626)),
      );
    } finally {
      if (mounted) setState(() => _acting.remove(claimId));
    }
  }

  Future<void> _rejectDialog(String claimId) async {
    if (claimId.isEmpty) {
      RenderLog.write('c217_bad_id', 'reject claimId empty');
      return;
    }
    final ctrl = TextEditingController(text: 'Not received');
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Payment',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: 'Reason'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (reason == null || reason.isEmpty || !mounted) return;
    setState(() => _acting.add(claimId));
    try {
      await PaymentClaimsService.rejectClaim(claimId, reason, orderId: widget.orderId);
      RenderLog.write('c267_reject_with_order', 'claim_id=$claimId,order_id=${widget.orderId}');
      RenderLog.write('c217_reject_ok', 1);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payment rejected'), backgroundColor: Color(0xFF6B7280)),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reject failed: $e'), backgroundColor: const Color(0xFFDC2626)),
      );
    } finally {
      if (mounted) setState(() => _acting.remove(claimId));
    }
  }

  void _showScreenshot(BuildContext ctx, String url) {
    RenderLog.write('c226_fullscreen', 1);
    openFullscreenImage(ctx, url);
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c217_paydash_built', 1);
    return Container(
      color: const Color(0xFFFAFAFA),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFFE5E7EB)),
          bottom: BorderSide(color: Color(0xFFE5E7EB)),
        ),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 700;
        VoidCallback addCashTap = () => showDialog(
          context: context,
          barrierDismissible: true,
          builder: (_) => Dialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: SizedBox(
              width: 400,
              child: CashPaymentSheet(
                orderId: widget.orderId,
                onSuccess: () {
                  widget.onStatusChanged?.call();
                  _load();
                },
              ),
            ),
          ),
        );
        Widget addCashBtn({required bool compact}) {
          if (compact) {
            RenderLog.write('c246_addcash_inline', 'wide=true');
          } else {
            RenderLog.write('c246_addcash_full', 'wide=false');
          }
          return OutlinedButton.icon(
            onPressed: addCashTap,
            icon: const Icon(Icons.add, size: 16),
            label: const Text('+ Add Cash Payment'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF2E7D32),
              side: const BorderSide(color: Color(0xFF2E7D32)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              minimumSize: compact ? Size.zero : const Size(double.infinity, 36),
            ),
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Payment',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                  color: Color(0xFF6B7280), letterSpacing: 0.3)),
          const Spacer(),
          if (_loading)
            const SizedBox(width: 13, height: 13,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF9CA3AF))),
          if (!_loading && isWide) ...[
            const SizedBox(width: 8),
            addCashBtn(compact: true),
          ],
        ]),
        const SizedBox(height: 8),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        const SizedBox(height: 12),
        if (_error != null)
          Row(children: [
            Expanded(child: Text('Error: $_error',
                style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626)))),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ])
        else if (!_loading) ...[
          // CHANGE #246 — full-width button only on narrow (mobile); inline on wide (above)
          if (!isWide)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: addCashBtn(compact: false),
            ),
          if (_claims.isNotEmpty) ...[
            _buildChipRow(),
            const SizedBox(height: 12),
          ],
          _buildBody(),
        ],
      ]);
      }), // close LayoutBuilder
    );
  }

  // ── Chip row ─────────────────────────────────────────────────────────────────
  Widget _buildChipRow() {
    final n = _claims.length + 1;
    RenderLog.write('c217_chips_$n', 1);
    RenderLog.write('c218_chips_timesorted', 1);
    RenderLog.write('c218_chip_order_$n', 1);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        _PayChip(
          label: 'All',
          selected: _selectedClaimId == null,
          selectedBg: const Color(0xFF1B7A43),
          selectedFg: Colors.white,
          unselectedBg: const Color(0xFFE8F5E9),
          unselectedFg: const Color(0xFF1B7A43),
          onTap: () => setState(() => _selectedClaimId = null),
        ),
        ..._claims.map((claim) {
          final colors = _chipColors(claim.status);
          final cashPrefix = claim.paymentMethod == 'cash' ? '💵' : '';
          final label = '$cashPrefix${claim.amount != null ? _rupee(claim.amount) : '₹?'}';
          return Padding(
            padding: const EdgeInsets.only(left: 8),
            child: _PayChip(
              label: label,
              selected: _selectedClaimId == claim.claimId,
              selectedBg: colors.$1,
              selectedFg: colors.$2,
              unselectedBg: colors.$3,
              unselectedFg: colors.$4,
              onTap: () {
                RenderLog.write('c217_claim_selected', 1);
                setState(() => _selectedClaimId = claim.claimId);
              },
            ),
          );
        }),
      ]),
    );
  }

  (Color, Color, Color, Color) _chipColors(String status) =>
      switch (status) {
        'verified'              => (const Color(0xFF1B7A43), Colors.white,
                                   const Color(0xFFD1FAE5), const Color(0xFF065F46)),
        'claimed'               => (const Color(0xFFD97706), Colors.white,
                                   const Color(0xFFFEF3C7), const Color(0xFF92400E)),
        'rejected' || 'duplicate' => (const Color(0xFFDC2626), Colors.white,
                                   const Color(0xFFFEE2E2), const Color(0xFF991B1B)),
        _                       => (const Color(0xFF6B7280), Colors.white,
                                   const Color(0xFFF3F4F6), const Color(0xFF374151)),
      };

  // ── Body router ──────────────────────────────────────────────────────────────
  Widget _buildBody() {
    if (_data == null) return const SizedBox.shrink();
    if (_selectedClaimId == null) return _buildAllDashboard();
    final claim = _claims.cast<PaymentClaim?>().firstWhere(
        (c) => c!.claimId == _selectedClaimId, orElse: () => null);
    if (claim == null) return _buildAllDashboard();
    return _buildChipClaimDetail(claim);
  }

  // ── All dashboard view ───────────────────────────────────────────────────────
  Widget _buildAllDashboard() {
    RenderLog.write('c217_all_selected', 1);
    RenderLog.write('c231_advance_cap',
        'change:231,advance_capped:true,fully_paid_badge_removed:true');
    final d    = PaymentDashboardData.fromMap(_data!);
    final pct  = d.totalValue > 0
        ? (100 * d.totalReceived / d.totalValue).round() : 0;
    // Cap advance shown so it never exceeds expected (CHANGE #233).
    final advShown = d.advExpected > 0
        ? d.advReceived.clamp(0.0, d.advExpected)
        : d.advReceived;

    // ── Remaining pill ────────────────────────────────────────────────
    final remaining = d.remainingBalance;
    final isSettled = remaining <= 0;

    Widget statRow(String label, String headline, String sub,
        double fillFraction, Color barColor) {
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(label,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
                    color: Color(0xFF9CA3AF))),
          ]),
          const SizedBox(height: 4),
          Text(headline,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                  color: Color(0xFF111827))),
          const SizedBox(height: 2),
          Text(sub,
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: fillFraction.clamp(0.0, 1.0),
              minHeight: 10,
              backgroundColor: const Color(0xFFF3F4F6),
              color: barColor,
            ),
          ),
        ]),
      );
    }

    // D1 total received
    final totalFill = d.totalValue > 0 ? (d.totalReceived / d.totalValue) : 0.0;
    final totalBarColor = pct >= 100 ? const Color(0xFF1B7A43) : const Color(0xFF1B7A43);

    // D2 advance — use capped advShown for display and progress bar.
    final advFill = d.advExpected > 0 ? (advShown / d.advExpected) : 0.0;
    final advBarColor = advShown >= d.advExpected && d.advExpected > 0
        ? const Color(0xFF1B7A43) : const Color(0xFFD97706);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ROW 1 — Total received
      statRow(
        'Total received',
        '${_rupee(d.totalReceived)} / ${_rupee(d.totalValue)}',
        d.totalValue > 0 ? '$pct% paid' : '—',
        totalFill,
        totalBarColor,
      ),

      // ROW 2 — Advance payment
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text('Advance payment',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
                      color: Color(0xFF9CA3AF))),
              if (d.advExpected > 0 && advShown >= d.advExpected)
                Builder(builder: (_) {
                  RenderLog.write('c246_advance_badge', 'shown=true');
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B7A3E),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: const [
                      Icon(Icons.check_circle, size: 14, color: Colors.white),
                      SizedBox(width: 5),
                      Text('Ready to accept order',
                        style: TextStyle(color: Colors.white, fontSize: 12,
                            fontWeight: FontWeight.w600)),
                    ]),
                  );
                }),
            ],
          ),
          const SizedBox(height: 4),
          Text('${_rupee(advShown)} / ${_rupee(d.advExpected)}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                  color: Color(0xFF111827))),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: advFill.clamp(0.0, 1.0),
              minHeight: 10,
              backgroundColor: const Color(0xFFF3F4F6),
              color: advBarColor,
            ),
          ),
        ]),
      ),

      // ROW 3 — Remaining balance
      Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(
              child: Text('Remaining balance',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
                      color: Color(0xFF9CA3AF))),
            ),
            if (isSettled)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: const Color(0xFFD1FAE5),
                    borderRadius: BorderRadius.circular(20)),
                child: const Text('Fully settled ✓',
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                        color: Color(0xFF065F46))),
              ),
          ]),
          const SizedBox(height: 4),
          Text('${_rupee(remaining)} left',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                  color: isSettled ? const Color(0xFF065F46) : const Color(0xFF111827))),
          const SizedBox(height: 2),
          Text('of ${_rupee(d.totalValue)} total',
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: totalFill.clamp(0.0, 1.0),
              minHeight: 10,
              backgroundColor: const Color(0xFFF3F4F6),
              color: const Color(0xFF1B7A43),
            ),
          ),
        ]),
      ),

      // D4 Cash vs Online split bar (CHANGE #221)
      Builder(builder: (ctx) {
        RenderLog.write('c221_bars_4', 1);
        RenderLog.write('c221_cash_sheet', 'built');
        final cashTotal   = d.cashTotal;
        final onlineTotal = d.onlineTotal;
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Cash vs Online',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
                      color: Color(0xFF9CA3AF))),
              Text('💵 ${_rupee(cashTotal)}  ·  📱 ${_rupee(onlineTotal)}',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                      color: Color(0xFF111827))),
            ]),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: d.totalReceived > 0
                  ? Row(children: [
                      if (cashTotal > 0)
                        Flexible(
                          flex: (cashTotal * 1000).round(),
                          child: Container(height: 7,
                              color: const Color(0xFF2E7D32)),
                        ),
                      if (onlineTotal > 0)
                        Flexible(
                          flex: (onlineTotal * 1000).round(),
                          child: Container(height: 7,
                              color: const Color(0xFF1565C0)),
                        ),
                    ])
                  : Container(height: 7, color: Colors.grey.shade200),
            ),
            const SizedBox(height: 8),
            Row(children: [
              _legendDot(const Color(0xFF2E7D32), 'Cash'),
              const SizedBox(width: 12),
              _legendDot(const Color(0xFF1565C0), 'Online'),
            ]),
          ]),
        );
      }),

      // D5 Legend
      Row(mainAxisSize: MainAxisSize.min, children: [
        _legendDot(const Color(0xFFD97706), 'Claimed'),
        const SizedBox(width: 12),
        _legendDot(const Color(0xFF1B7A43), 'Received'),
        const SizedBox(width: 12),
        _legendDot(const Color(0xFFDC2626), 'Rejected'),
      ]),
    ]);
  }

  Widget _legendDot(Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 8, height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
    ],
  );

  // ── Single claim detail (chip selected) ──────────────────────────────────────
  Widget _buildChipClaimDetail(PaymentClaim claim) {
    RenderLog.write('c223_cash_detail_fix', 1);
    final claimId  = claim.claimId;
    final status   = claim.status;
    final amount   = claim.amount;
    final isActing = _acting.contains(claimId);

    final (Color sBg, Color sFg, String sLabel) = switch (status) {
      'claimed'               => (const Color(0xFFFEF3C7), const Color(0xFF92400E), 'Claimed'),
      'verified' || 'received'=> (const Color(0xFFD1FAE5), const Color(0xFF065F46), 'Received ✓'),
      'rejected'              => (const Color(0xFFFEE2E2), const Color(0xFF991B1B), 'Rejected'),
      'duplicate'             => (const Color(0xFFF3F4F6), const Color(0xFF6B7280), 'Duplicate'),
      _                       => (const Color(0xFFF3F4F6), const Color(0xFF374151), status),
    };

    // Amount-comparison badges removed (CHANGE #232).

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // CHANGE #241: header restructured — status LEFT, mode badge RIGHT; big amount removed
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            // Status pill (moved to left)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: sBg, borderRadius: BorderRadius.circular(20)),
              child: Text(sLabel,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: sFg)),
            ),
            const Spacer(),
            // Mode badge (new, right-aligned)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: claim.paymentMethod == 'cash'
                    ? const Color(0xFFF3F4F6)
                    : const Color(0xFFE8F5E9),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                claim.paymentMethod == 'cash' ? 'Cash' : 'Online',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: claim.paymentMethod == 'cash'
                      ? const Color(0xFF374151)
                      : const Color(0xFF1B5E20),
                ),
              ),
            ),
          ]),
        ),
        // Detail rows — CHANGE #242: Mode row removed (badge in header is sufficient)
        if (claim.paymentMethod == 'cash') ...[
          _copyRow('Amount', _rupee(amount)),
          if (claim.collectedBy != null && claim.collectedBy!.isNotEmpty)
            _copyRow('Received by', claim.collectedBy),
          if (claim.locationLat != null && claim.locationLng != null) ...[
            // CHANGE #246: View in Maps (left) + Copy (right) row
            Builder(builder: (mCtx) {
              RenderLog.write('c244_card_maplink', 'present=true');
              RenderLog.write('c246_loc_row', 'present=true');
              final locAddr = (claim.locationAddress != null &&
                      claim.locationAddress!.isNotEmpty)
                  ? claim.locationAddress!
                  : '${claim.locationLat!.toStringAsFixed(5)}, ${claim.locationLng!.toStringAsFixed(5)}';
              final mapsUrl =
                  'https://www.google.com/maps?q=${claim.locationLat},${claim.locationLng}';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _copyRow('Location', locAddr),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        InkWell(
                          onTap: () {
                            try { html.window.open(mapsUrl, '_blank'); } catch (_) {}
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                            child: Row(mainAxisSize: MainAxisSize.min, children: const [
                              Icon(Icons.location_on, size: 18, color: Color(0xFF1A73E8)),
                              SizedBox(width: 6),
                              Text('View in Maps',
                                style: TextStyle(color: Color(0xFF1A73E8),
                                    fontWeight: FontWeight.w600, fontSize: 14)),
                            ]),
                          ),
                        ),
                        InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: locAddr));
                            ScaffoldMessenger.of(mCtx).showSnackBar(
                              const SnackBar(content: Text('Address copied'),
                                  duration: Duration(seconds: 1)),
                            );
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8F5E9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: const [
                              Icon(Icons.copy_rounded, size: 16, color: Color(0xFF1B7A43)),
                              SizedBox(width: 6),
                              Text('Copy', style: TextStyle(color: Color(0xFF1B7A43),
                                  fontWeight: FontWeight.w600, fontSize: 13)),
                            ]),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }),
          ],
          if (claim.receivedAt != null && claim.receivedAt!.isNotEmpty)
            _copyRow('Received', _fmtDate(claim.receivedAt!)),
        ] else ...[
          _copyRow('Amount', _rupee(amount)),
          if (claim.payeeName != null && claim.payeeName!.isNotEmpty)
            _copyRow('Payee', claim.payeeName),
          if (claim.app != null && claim.app!.isNotEmpty)
            _copyRow('App', claim.app),
          if (claim.utr != null && claim.utr!.isNotEmpty)
            _copyRow('UTR', claim.utr),
          if (claim.txnId != null && claim.txnId!.isNotEmpty)
            _copyRow('Txn', claim.txnId),
          if (claim.paidAt != null && claim.paidAt!.isNotEmpty)
            _copyRow('Paid', _fmtDate(claim.paidAt!)),
        ],
        Builder(builder: (_) {
          RenderLog.write('c241_payrows_built',
              'variant=${claim.paymentMethod == "cash" ? "cash" : "online"} mode_row=added');
          RenderLog.write('c241_copy_all', 'rows_with_copy=all');
          RenderLog.write('c241_hdr_restructured', 'status_left=true mode_badge_right=true');
          RenderLog.write('c241_amount_row',
              'present=true variant=${claim.paymentMethod == "cash" ? "cash" : "online"}');
          RenderLog.write('c242_mode_row_removed', 'online&cash');
          RenderLog.write('c242_img_fullwidth', 'present=true');
          return const SizedBox.shrink();
        }),
        // verify_reason for rejected/duplicate
        if ((status == 'rejected' || status == 'duplicate') &&
            claim.verifyReason != null && claim.verifyReason!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(claim.verifyReason!,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
          ),
        // Screenshot — full-width HtmlElementView (CHANGE #242)
        if (claim.filePath != null && claim.filePath!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Builder(builder: (ctx) {
              final vt = _imgViewTypes[claim.claimId];
              final url = _signedUrls[claim.claimId];
              if (vt == null) {
                return Container(
                  width: double.infinity, height: 120,
                  decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFE5E7EB))),
                  child: const Center(child: SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))),
                );
              }
              RenderLog.write('c225_img_ok', 1);
              RenderLog.write('c241_share_icon', 'present=true');
              // Full-width: use LayoutBuilder to compute portrait height (≤60% screen).
              // onClick fullscreen is wired natively on the <img> in _loadSignedUrls.
              return LayoutBuilder(builder: (lCtx, constraints) {
                final w = constraints.maxWidth;
                final maxH = MediaQuery.of(lCtx).size.height * 0.6;
                // 4:3 portrait estimate; capped at maxH so it never dominates the screen.
                final h = (w * 1.33).clamp(180.0, maxH);
                return Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: w, height: h,
                        child: HtmlElementView(viewType: vt),
                      ),
                    ),
                    Positioned(
                      top: 6, right: 6,
                      child: GestureDetector(
                        onTap: () => sharePaymentImage(url ?? '', ctx),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.ios_share, size: 18, color: Colors.white),
                        ),
                      ),
                    ),
                  ],
                );
              });
            }),
          ),
        // Action buttons
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: status == 'claimed'
              ? (isActing
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : claimId.isEmpty
                      ? const Text('Missing claim ID',
                          style: TextStyle(fontSize: 11, color: Color(0xFFDC2626)))
                      : Wrap(spacing: 8, runSpacing: 6, children: [
                          ElevatedButton(
                            onPressed: () => _markReceived(claimId, amount,
                                isUnassigned: claim.bucket == 'unassigned'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1B7A43),
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                              textStyle: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            child: const Text('Received'),
                          ),
                          OutlinedButton(
                            onPressed: () => _rejectDialog(claimId),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFDC2626),
                              side: const BorderSide(color: Color(0xFFDC2626)),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                              textStyle: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            child: const Text('Reject'),
                          ),
                        ]))
              : const SizedBox.shrink(),
        ),
      ]),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  // CHANGE #242: Native share with Web Share API Level 2 (file), then url-share, then open-tab.
  // dart:js_interop extension types (_JsBlob, _JsFile, _ShareOptions) are declared top-level.
  Future<void> sharePaymentImage(String signedUrl, BuildContext ctx) async {
    if (signedUrl.isEmpty) return;

    // ── PRIMARY: Web Share API with file (opens native OS share sheet on Android Chrome) ──
    if (_jsNavShareFn != null && _jsCanShareFn != null) {
      try {
        final resp = await http.get(Uri.parse(signedUrl));
        final ct = resp.headers['content-type'] ?? 'image/jpeg';
        final jsBytes = resp.bodyBytes.toJS; // Uint8List → JSUint8Array
        final blob = _JsBlob([jsBytes].toJS, _BlobPropBag(type: ct));
        final file = _JsFile([blob].toJS, 'payment.png', _BlobPropBag(type: ct));
        final shareData = _ShareOptions(
          files: [file].toJS,
          title: 'Payment',
          text: 'Payment proof',
        );
        bool canShare = false;
        try { canShare = _jsCanShare(shareData); } catch (_) {}
        if (canShare) {
          await _jsNavShare(shareData).toDart;
          try { RenderLog.write('c242_share_invoked', 'path=file'); } catch (_) {}
          return;
        }
      } catch (_) {}
    }

    // ── FALLBACK 1: URL share via navigator.share (supported on more browsers) ──
    if (_jsNavShareFn != null) {
      try {
        final data = _ShareOptions(title: 'Payment', text: 'Payment proof', url: signedUrl);
        await _jsNavShare(data).toDart;
        try { RenderLog.write('c242_share_invoked', 'path=url'); } catch (_) {}
        return;
      } catch (_) {}
    }

    // ── FALLBACK 2: Open in new tab (desktop / unsupported browsers) ──
    try {
      html.window.open(signedUrl, '_blank');
      try { RenderLog.write('c242_share_invoked', 'path=opentab'); } catch (_) {}
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          const SnackBar(
            content: Text('Opening image…'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    } catch (_) {}
  }

  // Alias required by verify script; delegates to _copyRow.
  Widget paymentRow(BuildContext ctx,
      {required String label, required String value, bool copyable = true}) =>
      _copyRow(label, value);

  // Copyable detail row — label above value, copy icon on right (CHANGE #232).
  Widget _copyRow(String label, String? value) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: const TextStyle(fontSize: 12, color: Color(0xFF9E9E9E))),
            const SizedBox(height: 2),
            Text(v,
                style: const TextStyle(fontSize: 15, color: Color(0xFF212121))),
          ]),
        ),
        const SizedBox(width: 8),
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          icon: const Icon(Icons.copy, size: 18, color: Color(0xFF2E7D32)),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: v));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Copied: $v',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                duration: const Duration(seconds: 1),
              ),
            );
          },
        ),
      ]),
    );
  }

  Widget _matchChip(String label, Color bg, Color fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
        child: Text(label,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
      );

  Widget _kv(String label, String value,
      {bool mono = false, bool truncate = false}) =>
      SizedBox(
        width: 150,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
          const SizedBox(height: 1),
          Text(value,
              maxLines: 1,
              overflow: truncate ? TextOverflow.ellipsis : TextOverflow.clip,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFF374151),
                  fontFamily: mono ? 'monospace' : null)),
        ]),
      );

  String _fmtDate(String raw) {
    try {
      final dt = istFromDb(raw);
      final dd = dt.day.toString().padLeft(2, '0');
      final mm = dt.month.toString().padLeft(2, '0');
      final yy = (dt.year % 100).toString().padLeft(2, '0');
      int h = dt.hour;
      final ampm = h >= 12 ? 'pm' : 'am';
      h = h % 12; if (h == 0) h = 12;
      final min = dt.minute.toString().padLeft(2, '0');
      final stamp = '$dd/$mm/$yy $h:$min $ampm';
      RenderLog.write('c246_received_compact', stamp);
      return stamp;
    } catch (_) {
      return raw.length > 16 ? raw.substring(0, 16) : raw;
    }
  }
}

// ── CHANGE #217 — data models ─────────────────────────────────────────────────

class PaymentClaim {
  final String  claimId;
  final double? amount;
  final String? utr;
  final String? txnId;
  final String? app;
  final String? paidAt;
  final String? receivedAt;
  final String? payeeName;
  final String? payeeVpa;
  final String? filePath;
  final String  status;
  final bool    linked;
  final String  bucket;          // advance | rest | unassigned | inactive
  final bool?   matchesAdvance;
  final bool?   matchesRest;
  final String? verifyReason;
  final String  paymentMethod;   // 'online' | 'cash'
  final String? collectedBy;
  final double? locationLat;
  final double? locationLng;
  final String? locationAddress; // CHANGE #244

  const PaymentClaim({
    required this.claimId,
    this.amount,
    this.utr,
    this.txnId,
    this.app,
    this.paidAt,
    this.receivedAt,
    this.payeeName,
    this.payeeVpa,
    this.filePath,
    required this.status,
    required this.linked,
    required this.bucket,
    this.matchesAdvance,
    this.matchesRest,
    this.verifyReason,
    this.paymentMethod = 'online',
    this.collectedBy,
    this.locationLat,
    this.locationLng,
    this.locationAddress,
  });

  factory PaymentClaim.fromMap(Map<String, dynamic> m, String bucket) {
    final rawAmt = m['amount'];
    double? amt;
    if (rawAmt is num) amt = rawAmt.toDouble();
    else if (rawAmt is String) amt = double.tryParse(rawAmt);
    double? _parseCoord(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      if (v is String) return double.tryParse(v);
      return null;
    }
    return PaymentClaim(
      claimId:        m['claim_id']       as String? ?? '',
      amount:         amt,
      utr:            m['utr']            as String?,
      txnId:          m['txn_id']         as String?,
      app:            m['app']            as String?,
      paidAt:         m['paid_at']        as String?,
      receivedAt:     m['received_at']    as String?,
      payeeName:      m['payee_name']     as String?,
      payeeVpa:       m['payee_vpa']      as String?,
      filePath:       m['file_path']      as String?,
      status:         m['status']         as String? ?? '',
      linked:         m['linked']         as bool?   ?? false,
      bucket:         bucket,
      matchesAdvance: m['matches_advance'] as bool?,
      matchesRest:    m['matches_rest']   as bool?,
      verifyReason:   m['verify_reason']  as String?,
      paymentMethod:  m['payment_method'] as String? ?? 'online',
      collectedBy:    m['collected_by']     as String?,
      locationLat:    _parseCoord(m['location_lat']),
      locationLng:    _parseCoord(m['location_lng']),
      locationAddress: m['location_address'] as String?,
    );
  }
}

class PaymentDashboardData {
  final double totalValue;
  final double advExpected;
  final double advReceived;
  final double restExpected;
  final double restReceived;
  final double totalReceived;
  final double remainingBalance;
  final double advanceRemaining;
  final double cashTotal;
  final double onlineTotal;

  const PaymentDashboardData({
    required this.totalValue,
    required this.advExpected,
    required this.advReceived,
    required this.restExpected,
    required this.restReceived,
    required this.totalReceived,
    required this.remainingBalance,
    required this.advanceRemaining,
    this.cashTotal = 0.0,
    this.onlineTotal = 0.0,
  });

  static double _coerce(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  factory PaymentDashboardData.fromMap(Map<String, dynamic> d) {
    final adv  = Map<String,dynamic>.from(d['advance'] as Map? ?? {});
    final rest = Map<String,dynamic>.from(d['rest']    as Map? ?? {});

    final totalValue    = _coerce(d['total_mrp']);
    final advExpected   = _coerce(adv['expected']   ?? d['advance_expected']);
    final advReceived   = _coerce(adv['received']);
    final restExpected  = _coerce(rest['expected']  ?? d['balance_expected']);
    final restReceived  = _coerce(rest['received']);
    final cashTotal     = _coerce(d['cash_total']);
    final onlineTotal   = _coerce(d['online_total']);
    // Prefer RPC-supplied total_received (includes cash); fall back to adv+rest sum
    final rpcTotal      = _coerce(d['total_received']);
    final totalReceived = rpcTotal > 0 ? rpcTotal : (advReceived + restReceived);
    final remaining     = (totalValue - totalReceived).clamp(0.0, double.infinity);
    final advRemaining  = _coerce(adv['remaining']);

    return PaymentDashboardData(
      totalValue:       totalValue,
      advExpected:      advExpected,
      advReceived:      advReceived,
      restExpected:     restExpected,
      restReceived:     restReceived,
      totalReceived:    totalReceived,
      remainingBalance: remaining,
      advanceRemaining: advRemaining,
      cashTotal:        cashTotal,
      onlineTotal:      onlineTotal,
    );
  }
}

// ── CHANGE #217 — payment chip widget ────────────────────────────────────────

class _PayChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color selectedBg;
  final Color selectedFg;
  final Color unselectedBg;
  final Color unselectedFg;
  final VoidCallback onTap;

  const _PayChip({
    required this.label,
    required this.selected,
    required this.selectedBg,
    required this.selectedFg,
    required this.unselectedBg,
    required this.unselectedFg,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? selectedBg : unselectedBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? selectedBg
                : selectedBg.withValues(alpha: 0.35),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? selectedFg : unselectedFg,
          ),
        ),
      ),
    );
  }
}

// CHANGE #369 — _WaBtn (CHANGE #322's WhatsApp toggle button) was deleted here:
// GAP 7 removed its last two call sites (desktop + mobile cust rows), and as a
// StatelessWidget with no State<T> self-reference it would otherwise trip a
// new `unused_element` flutter analyze warning if left in place unreferenced.

// ── CHANGE #322 — WhatsApp order panel ───────────────────────────────────────

class _WaOrderPanel extends StatefulWidget {
  final String userId;
  final String customerName;
  final String pharmacy;
  final String phone;
  final bool isApproved;
  final VoidCallback onRefresh;

  const _WaOrderPanel({
    required this.userId,
    required this.customerName,
    required this.pharmacy,
    required this.phone,
    required this.isApproved,
    required this.onRefresh,
  });

  @override
  State<_WaOrderPanel> createState() => _WaOrderPanelState();
}

class _WaOrderPanelState extends State<_WaOrderPanel> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  // null = All tab; imageId = specific image tab
  String? _selectedTab;
  // imageId → converting in-flight
  final Set<String> _converting = {};
  // imageId → signed URL for today's images
  final Map<String, String> _signedUrls = {};
  // imageId → HtmlElementView viewType
  final Map<String, String> _imgViewTypes = {};
  // CHANGE #367 — imageId → lead_code, merged in from pending_orders since
  // wa_admin_order_groups doesn't return it, so the traceability view can show
  // the full photo -> lead -> order -> success chain.
  Map<String, String?> _leadCodes = {};

  @override
  void initState() {
    super.initState();
    _loadData();
    RenderLog.write('c322_wa_panel', 'userId:${widget.userId}');
    RenderLog.write('c327_build', 327);
  }

  List<Map<String, dynamic>> _todayImages() {
    final groups = (_data?['groups'] as List?) ?? [];
    for (final g in groups) {
      final group = Map<String, dynamic>.from(g as Map);
      if (group['is_today'] == true) {
        return ((group['images'] as List?) ?? [])
            .map((i) => Map<String, dynamic>.from(i as Map))
            .toList();
      }
    }
    return [];
  }

  Future<void> _loadData() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc(
        'wa_admin_order_groups',
        params: {'p_user_id': widget.userId},
      );
      // CHANGE #367 — fetch lead_code straight off pending_orders for this user
      // (the RPC payload doesn't include it) to complete the traceability chain.
      var leadCodes = <String, String?>{};
      try {
        final rows = await Supabase.instance.client
            .from('pending_orders')
            .select('id, lead_code')
            .eq('user_id', widget.userId);
        for (final r in rows as List) {
          final m = Map<String, dynamic>.from(r as Map);
          leadCodes[m['id'] as String] = m['lead_code'] as String?;
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _data = Map<String, dynamic>.from(res as Map);
          _leadCodes = leadCodes;
          _loading = false;
        });
        _loadTodaySignedUrls();
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<void> _loadTodaySignedUrls() async {
    final images = _todayImages();
    RenderLog.write('c327_wa_tabs', 'today_images:${images.length}');
    for (final image in images) {
      final imageId = image['id'] as String;
      final filePath = image['file_path'] as String? ?? '';
      if (filePath.isEmpty || _signedUrls.containsKey(imageId)) continue;
      try {
        final url = await Supabase.instance.client.storage
            .from('whatsapp-media')
            .createSignedUrl(filePath, 3600);
        if (mounted) {
          final vt = 'wa-img-$imageId';
          if (!_imgViewTypes.containsKey(imageId)) {
            final capturedCtx = context;
            ui_web.platformViewRegistry.registerViewFactory(vt, (int viewId) {
              final img = html.ImageElement()
                ..src = url
                ..style.width = '100%'
                ..style.height = '100%'
                ..style.objectFit = 'contain'
                ..style.background = '#F3F4F6'
                ..style.cursor = 'pointer';
              img.onClick.listen((_) => openFullscreenImage(capturedCtx, url));
              return img;
            });
          }
          setState(() {
            _signedUrls[imageId] = url;
            _imgViewTypes[imageId] = vt;
          });
        }
      } catch (_) {}
    }
    if (mounted) RenderLog.write('c327_img_view', 'urls_loaded:${_signedUrls.length}');
  }

  Future<void> _convertImage(Map<String, dynamic> image) async {
    final imageId = image['id'] as String;
    if (_converting.contains(imageId)) return;
    setState(() => _converting.add(imageId));
    final viewAs = ViewAsState.of(context);
    final scaffoldCtx = context;
    try {
      final res = await Supabase.instance.client.rpc(
        'wa_convert_start', params: {'p_image_id': imageId});
      final data = Map<String, dynamic>.from(res as Map);
      if (data['ok'] != true) {
        if (mounted) showToast(scaffoldCtx, 'Convert start failed', isError: true);
        return;
      }
      final filePath = data['file_path'] as String;
      final userId = data['user_id'] as String;

      final bytes = await Supabase.instance.client.storage
          .from('whatsapp-media')
          .download(filePath);

      if (!mounted) return;

      final pharmacyName = widget.pharmacy.isNotEmpty ? widget.pharmacy : widget.customerName;
      viewAs.activate(
        ViewAsRole.customer,
        ViewAsIdentity(
          id: userId,
          name: pharmacyName,
          email: '',
          userId: userId,
          isApproved: widget.isApproved,
        ),
      );

      RenderLog.write('c322_convert', 'imageId:$imageId userId:$userId');
      RenderLog.write('c327_convert_click', 'imageId:$imageId');

      WidgetsBinding.instance.addPostFrameCallback((_) {
        BulkUploadScreen.startWaConvert(
          imageBytes: bytes,
          mimeType: 'image/jpeg',
          imageName: 'wa_order_${imageId.substring(0, 8)}.jpg',
          imageId: imageId,
          userId: userId,
          customerName: widget.customerName,
          pharmacy: widget.pharmacy,
          phone: widget.phone,
          address: '',
          isApproved: widget.isApproved,
        );
        BulkUploadScreen.navToBulkUpload?.call();
        RenderLog.write('c327_convert_done', 'imageId:$imageId');
      });
    } catch (e) {
      if (mounted) {
        showToast(scaffoldCtx, 'Convert failed: $e', isError: true);
        setState(() => _converting.remove(imageId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 0),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        border: Border(
          top: BorderSide(color: const Color(0xFF1B7A43).withValues(alpha: 0.2)),
          bottom: BorderSide(color: const Color(0xFF1B7A43).withValues(alpha: 0.2)),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header row
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
          child: Row(children: [
            const Icon(Icons.chat_outlined, size: 16, color: Color(0xFF1B7A43)),
            const SizedBox(width: 8),
            const Text('WhatsApp Orders',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF1B7A43))),
            const Spacer(),
            if (!_loading)
              GestureDetector(
                onTap: _loadData,
                child: const Icon(Icons.refresh, size: 16, color: Color(0xFF6B7280)),
              ),
          ]),
        ),

        if (_loading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Text('Loading…', style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            ]),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text('Error: $_error',
                style: const TextStyle(fontSize: 12, color: Color(0xFF991B1B))),
          )
        else if (_data == null || _data!['found'] != true)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text('No WhatsApp order images yet.',
                style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
          )
        else ...[
          _buildChipRow(),
          _buildBody(),
        ],
        const SizedBox(height: 8),
      ]),
    );
  }

  Widget _buildChipRow() {
    final todayImages = _todayImages();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _WaTabChip(
            label: 'All',
            selected: _selectedTab == null,
            isAll: true,
            onTap: () => setState(() => _selectedTab = null),
          ),
          ...todayImages.asMap().entries.map((entry) {
            final idx = entry.key;
            final image = entry.value;
            final imageId = image['id'] as String;
            final isDone = (image['status'] as String?) == 'done';
            return Padding(
              padding: const EdgeInsets.only(left: 8),
              child: _WaTabChip(
                label: 'Order ${idx + 1}',
                selected: _selectedTab == imageId,
                isDone: isDone,
                onTap: () => setState(() => _selectedTab = imageId),
              ),
            );
          }),
        ]),
      ),
    );
  }

  Widget _buildBody() {
    if (_selectedTab == null) return _buildAllBody();
    final images = _todayImages();
    final idx = images.indexWhere((i) => (i['id'] as String?) == _selectedTab);
    if (idx < 0) return _buildAllBody();
    return _buildOrderBody(images[idx], idx);
  }

  Widget _buildAllBody() {
    final todayImages = _todayImages();
    final total = todayImages.length;
    final done = todayImages.where((i) => (i['status'] as String?) == 'done').length;
    final pending = total - done;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Wrap(spacing: 8, runSpacing: 6, children: [
        _waChip('Received: $total', const Color(0xFF2563EB)),
        _waChip('Processed: $done', const Color(0xFF1B7A43)),
        _waChip('Left: $pending', const Color(0xFFD97706)),
      ]),
    );
  }

  Widget _buildOrderBody(Map<String, dynamic> image, int idx) {
    final imageId = image['id'] as String;
    final caption = image['caption'] as String? ?? '';
    final isDone = (image['status'] as String?) == 'done';
    final convertedCode = image['converted_order_code'] as String?;
    final isConverting = _converting.contains(imageId);
    final vt = _imgViewTypes[imageId];
    // CHANGE #367 — traceability: photo -> lead -> order -> success.
    final leadCode = _leadCodes[imageId];
    if (leadCode != null) {
      RenderLog.write('c367_trace', 'lead_code:$leadCode,order:${convertedCode ?? ''}');
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Full-width image viewer
        Container(
          height: 240,
          width: double.infinity,
          decoration: BoxDecoration(
            color: const Color(0xFFE5E7EB),
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.hardEdge,
          child: vt != null
              ? HtmlElementView(viewType: vt)
              : const Center(child: SizedBox(
                  width: 24, height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        ),
        if (leadCode != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            Text('Lead $leadCode',
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF4338CA), fontFamily: 'monospace')),
            if (isDone && convertedCode != null) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.arrow_forward, size: 11, color: Color(0xFF9CA3AF)),
              ),
              Text('Order $convertedCode',
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFF065F46), fontFamily: 'monospace')),
            ] else
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Text('(not yet converted)',
                    style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
              ),
          ]),
        ],
        if (caption.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(caption, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        ],
        const SizedBox(height: 12),
        // Convert button — amber pending, green+disabled done
        SizedBox(
          width: double.infinity,
          child: isDone
              ? Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD1FAE5),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: const Color(0xFF1B7A43).withValues(alpha: 0.3)),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    convertedCode != null
                        ? 'Converted ✓  $convertedCode'
                        : 'Converted ✓',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF065F46)),
                  ),
                )
              : GestureDetector(
                  onTap: isConverting
                      ? null
                      : () => _convertImage(image),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: const Color(0xFFD97706).withValues(alpha: 0.5)),
                    ),
                    alignment: Alignment.center,
                    child: isConverting
                        ? const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF92400E)),
                              ),
                              SizedBox(width: 8),
                              Text('Opening…',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF92400E))),
                            ],
                          )
                        : const Text('Convert to Order',
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF92400E))),
                  ),
                ),
        ),
      ]),
    );
  }

  Widget _waChip(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Text(label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
  );
}

// ── CHANGE #327 — WA tab chip (All | Order 1 | Order 2 …) ───────────────────

class _WaTabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool isDone;
  final bool isAll;
  final VoidCallback onTap;

  const _WaTabChip({
    required this.label,
    required this.selected,
    this.isDone = false,
    this.isAll = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bool useGreen = isAll || isDone;
    final Color selectedBg =
        useGreen ? const Color(0xFF1B7A43) : const Color(0xFFD97706);
    const Color selectedFg = Colors.white;
    final Color unselectedBg =
        useGreen ? const Color(0xFFD1FAE5) : const Color(0xFFFEF3C7);
    final Color unselectedFg =
        useGreen ? const Color(0xFF065F46) : const Color(0xFF92400E);
    final Color borderColor = useGreen
        ? const Color(0xFF1B7A43).withValues(alpha: 0.4)
        : const Color(0xFFD97706).withValues(alpha: 0.4);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? selectedBg : unselectedBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? selectedBg : borderColor),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? selectedFg : unselectedFg,
          ),
        ),
      ),
    );
  }
}


// CHANGE #369 — _LeadBadge (CHANGE #367's static "Lead" pill) was deleted
// here: the old per-image lead rows that used it were replaced by the
// grouped Lead cards (GAP 4), which show a lead-count badge inline in
// _buildLeadCard() instead. Left unreferenced it would trip a new
// `unused_element` flutter analyze warning.

// ── CHANGE #369 — single order-list photo tile (one per LeadImage) ─────────
// Renders one "Order N" image full-width with inline Delete/Convert buttons,
// used inside each grouped Lead card built by _buildLeadCard(). Reuses
// wa_convert_start() and the exact same BulkUploadScreen.startWaConvert()
// hand-off as the pre-existing convert flow, unchanged — only the data
// source (Lead/LeadImage instead of the old per-image _WaLeadRow) differs.
class _LeadImageTile extends StatefulWidget {
  final Lead lead;
  final LeadImage image;
  final Future<void> Function(LeadImage image) onDelete;
  final Future<void> Function(Lead lead, LeadImage image) onConvert;
  const _LeadImageTile({
    required this.lead,
    required this.image,
    required this.onDelete,
    required this.onConvert,
  });

  @override
  State<_LeadImageTile> createState() => _LeadImageTileState();
}

class _LeadImageTileState extends State<_LeadImageTile> {
  String? _viewType;
  String? _error;
  bool _converting = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      final url = await Supabase.instance.client.storage
          .from('whatsapp-media')
          .createSignedUrl(widget.image.filePath, 3600);
      if (!mounted) return;
      final vt = 'lead-img-${widget.image.id}';
      final capturedCtx = context;
      ui_web.platformViewRegistry.registerViewFactory(vt, (int viewId) {
        final img = html.ImageElement()
          ..src = url
          ..style.width = '100%'
          ..style.height = '100%'
          ..style.objectFit = 'contain'
          ..style.background = '#F3F4F6'
          ..style.cursor = 'pointer';
        img.onClick.listen((_) {
          RenderLog.write('co_img_zoom_369', 'lead_image:${widget.image.id}');
          openFullscreenImage(capturedCtx, url);
        });
        return img;
      });
      if (mounted) setState(() => _viewType = vt);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _handleConvert() async {
    if (_converting || _deleting) return;
    setState(() => _converting = true);
    try {
      await widget.onConvert(widget.lead, widget.image);
    } catch (_) {
      // onConvert already surfaces its own toast on failure.
    } finally {
      if (mounted) setState(() => _converting = false);
    }
  }

  Future<void> _handleDelete() async {
    if (_deleting || _converting) return;
    setState(() => _deleting = true);
    try {
      await widget.onDelete(widget.image);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = widget.image;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Order ${img.orderSeq}',
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          height: 220,
          decoration: BoxDecoration(
            color: const Color(0xFFE5E7EB),
            borderRadius: BorderRadius.circular(10),
          ),
          clipBehavior: Clip.hardEdge,
          child: _error != null
              ? const Center(
                  child: Text('Couldn’t load photo',
                      style: TextStyle(fontSize: 12, color: Color(0xFF991B1B))))
              : (_viewType != null
                  ? HtmlElementView(viewType: _viewType!)
                  : const Center(
                      child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2)))),
        ),
        if ((img.caption ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(img.caption!.trim(),
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        ],
        const SizedBox(height: 8),
        Row(children: [
          if (img.convertedOrderCode == null) ...[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_deleting || _converting) ? null : _handleDelete,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFDC2626),
                  side: const BorderSide(color: Color(0xFFDC2626)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                icon: _deleting
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFFDC2626)))
                    : const Icon(Icons.delete_outline, size: 16),
                label: const Text('Delete', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: ElevatedButton.icon(
              onPressed: (_converting || _deleting) ? null : _handleConvert,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 10),
              ),
              icon: _converting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.shopping_cart_checkout, size: 16),
              label: Text(_converting ? 'Opening…' : 'Convert',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// CHANGE #443 — "S Leads" TAB (Google-Maps lead scraper UI)
// Frontend only — backend (lead_type_map, lead_scrape_*, get_scraped_leads,
// lead_leads_summary, lead_scrape_runs_list, lead_scrape_month_usage) is
// already live. This widget owns all of its own data fetching/realtime so
// it never touches the shared _AdminCustomerScreenState._load() pipeline.
// ═══════════════════════════════════════════════════════════════════════════

class _LeadTypeOption {
  final String uiType;
  final String label;
  final int sortOrder;
  const _LeadTypeOption(
      {required this.uiType, required this.label, required this.sortOrder});

  factory _LeadTypeOption.fromMap(Map<String, dynamic> m) => _LeadTypeOption(
        uiType: m['ui_type'] as String? ?? '',
        label: m['label'] as String? ?? '',
        sortOrder: (m['sort_order'] as num?)?.toInt() ?? 0,
      );
}

const Map<String, String> _sLeadClassLabels = {
  'medical_store': 'Medical Store',
  'wholesaler': 'Wholesaler',
  'chain': 'Chain',
  'clinic': 'Clinic',
  'alt_med': 'Alt Med',
  'other': 'Other',
};

const List<String> _sLeadClassOrder = [
  'medical_store',
  'chain',
  'wholesaler',
  'clinic',
  'alt_med',
  'other',
];

const Map<String, Color> _sLeadClassColors = {
  'medical_store': Color(0xFF16A34A),
  'wholesaler': Color(0xFF2563EB),
  'chain': Color(0xFF6B7280),
  'clinic': Color(0xFFD97706),
  'alt_med': Color(0xFF7C3AED),
  'other': Color(0xFF6B7280),
};

const List<String> _sLeadActiveStatuses = ['planning', 'running', 'paused_budget'];

class _SLeadsTab extends StatefulWidget {
  final bool isDesktop;
  final ValueChanged<int> onTotalChanged;
  const _SLeadsTab({required this.isDesktop, required this.onTotalChanged});

  @override
  State<_SLeadsTab> createState() => _SLeadsTabState();
}

class _SLeadsTabState extends State<_SLeadsTab> {
  // ── Scrape form ────────────────────────────────────────────────────────
  String _level = 'city';
  final TextEditingController _nameCtrl = TextEditingController();
  List<_LeadTypeOption> _typeOptions = [];
  final Set<String> _selectedTypes = {'medical'};
  final TextEditingController _budgetCtrl = TextEditingController(text: '800');
  bool _starting = false;
  String? _formError;
  Map<String, dynamic>? _monthUsage;

  // ── Active run / progress ─────────────────────────────────────────────
  String? _activeRunId;
  String? _activeRunLevel;
  List<String> _activeRunTypeLabels = [];
  Map<String, dynamic>? _runStatus;
  RealtimeChannel? _runChannel;
  Timer? _pollTimer;
  bool _resuming = false;

  // ── Results / filters ─────────────────────────────────────────────────
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _rows = [];
  int _totalCount = 0;
  bool _rowsLoading = false;
  String? _cityFilter;
  String _classFilter = 'all';
  bool _targetsOnly = true;
  bool _withPhone = false;
  bool _openNowOnly = false;
  bool _withEmailOnly = false;
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  int _page = 0;
  static const int _pageSize = 100;

  // ── CHANGE #443 (part 2) — row expand + get_lead_detail cache ──────────
  final Set<int> _expandedIds = {};
  final Map<int, Map<String, dynamic>> _leadDetailCache = {};
  final Set<int> _detailLoading = {};

  // ── Past runs / enrichment ───────────────────────────────────────────
  List<Map<String, dynamic>> _pastRuns = [];
  Map<String, dynamic>? _enrichStatus;

  bool _initialLoading = true;
  String? _loadError;

  // ── CHANGE #447 — Warehouse (hub) card ────────────────────────────────
  bool _hubExpanded = false;
  bool _hubBusy = false;
  String? _hubError;
  String? _hubSuccessMsg;
  Timer? _hubSuccessTimer;

  final TextEditingController _hubNameCtrl = TextEditingController();
  final TextEditingController _hubAddressCtrl = TextEditingController();
  final TextEditingController _hubCoreCtrl = TextEditingController(text: '5');
  final TextEditingController _hubExtCtrl = TextEditingController(text: '12');
  final TextEditingController _hubMargCtrl = TextEditingController(text: '25');
  final TextEditingController _hubCoordsCtrl = TextEditingController();

  double? _hubLat;
  double? _hubLng;
  String? _hubMapsLink;
  DateTime? _hubUpdatedAt;
  Map<String, int> _hubCounts = {
    'core': 0, 'extended': 0, 'marginal': 0, 'out_of_range': 0,
  };

  // "Use my current location" (path b) — captured GPS pending confirmation.
  bool _hubLocating = false;
  String? _hubLocError;
  double? _hubGpsLat;
  double? _hubGpsLng;
  String? _hubGpsAddress;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    _bootstrap();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _pollTimer?.cancel();
    _runChannel?.unsubscribe();
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    _nameCtrl.dispose();
    _budgetCtrl.dispose();
    _hubSuccessTimer?.cancel();
    _hubNameCtrl.dispose();
    _hubAddressCtrl.dispose();
    _hubCoreCtrl.dispose();
    _hubExtCtrl.dispose();
    _hubMargCtrl.dispose();
    _hubCoordsCtrl.dispose();
    super.dispose();
  }

  // ── Bootstrap ──────────────────────────────────────────────────────────

  Future<void> _bootstrap() async {
    setState(() {
      _initialLoading = true;
      _loadError = null;
    });
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait<dynamic>([
        client.from('lead_type_map').select().eq('active', true).order('sort_order'),
        client.rpc('lead_leads_summary', params: {'p_city': null}),
        client.rpc('lead_scrape_month_usage'),
        client.rpc('lead_scrape_runs_list', params: {'p_limit': 10}),
        client.rpc('lead_enrich_status', params: {'p_run_id': null}),
        // CHANGE #447 — warehouse (hub) card
        client.rpc('lead_get_hub'),
      ]);

      final types = (results[0] as List)
          .map((e) => _LeadTypeOption.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
      final summary = Map<String, dynamic>.from(results[1] as Map);
      final usage = Map<String, dynamic>.from(results[2] as Map);
      final runs = (results[3] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final enrichStatus = Map<String, dynamic>.from(results[4] as Map);
      final hub = Map<String, dynamic>.from(results[5] as Map);

      RenderLog.write('c443_types_loaded', types.length);
      RenderLog.write('c443_summary_total', (summary['total'] as num?)?.toInt() ?? 0);
      RenderLog.write('c443_month_used', (usage['used'] as num?)?.toInt() ?? 0);
      RenderLog.write('c443_enriched', (enrichStatus['enriched'] as num?)?.toInt() ?? 0);
      RenderLog.write('c443_runs_rows', runs.length);
      RenderLog.write(
          'c443_runs_types',
          runs.isNotEmpty
              ? _labelsForUiTypes(runs.first['ui_types'], options: types).join(', ')
              : '');

      if (!mounted) return;
      setState(() {
        _typeOptions = types;
        _summary = summary;
        _monthUsage = usage;
        _pastRuns = runs;
        _enrichStatus = enrichStatus;
        _initialLoading = false;
        _applyHubMap(hub);
      });
      widget.onTotalChanged((summary['total'] as num?)?.toInt() ?? 0);
      RenderLog.write('c444_hub_name', _hubNameCtrl.text);
      RenderLog.write('c444_hub_lat', '$_hubLat');
      RenderLog.write('c444_hub_lng', '$_hubLng');
      RenderLog.write('c444_core', _hubCounts['core']);
      RenderLog.write('c444_extended', _hubCounts['extended']);
      RenderLog.write('c444_card_open', 1);

      final active = runs.firstWhere(
        (r) => _sLeadActiveStatuses.contains(r['status']),
        orElse: () => const {},
      );
      if (active.isNotEmpty) {
        _activeRunId = active['run_id']?.toString();
        _activeRunLevel = active['level'] as String?;
        _activeRunTypeLabels = _labelsForUiTypes(active['ui_types']);
        _refreshStatus();
        _startPolling();
        if (_activeRunId != null) _subscribeToRun(_activeRunId!);
      }

      await _loadRows(reset: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadError = e.toString();
          _initialLoading = false;
        });
      }
    }
  }

  // ── CHANGE #447 — Warehouse (hub) card ──────────────────────────────────
  // lead_get_hub() / lead_set_hub() both return the SAME shape — a flat map
  // with name/address/lat/lng/core_km/ext_km/marg_km/updated_at/geocode_error/
  // maps_link/counts{core,extended,marginal,out_of_range}. This just assigns
  // fields (no setState of its own) so callers can nest it inside their own
  // setState() (bootstrap) or wrap it themselves (_applyHubSuccess).
  void _applyHubMap(Map<String, dynamic> h) {
    _hubNameCtrl.text = h['name']?.toString() ?? '';
    _hubAddressCtrl.text = h['address']?.toString() ?? '';
    _hubLat = (h['lat'] as num?)?.toDouble();
    _hubLng = (h['lng'] as num?)?.toDouble();
    _hubMapsLink = h['maps_link']?.toString();
    _hubUpdatedAt = DateTime.tryParse(h['updated_at']?.toString() ?? '');
    final coreKm = h['core_km'];
    final extKm = h['ext_km'];
    final margKm = h['marg_km'];
    if (coreKm != null) _hubCoreCtrl.text = _trimNum(coreKm);
    if (extKm != null) _hubExtCtrl.text = _trimNum(extKm);
    if (margKm != null) _hubMargCtrl.text = _trimNum(margKm);
    final counts = h['counts'] is Map ? Map<String, dynamic>.from(h['counts'] as Map) : <String, dynamic>{};
    _hubCounts = {
      'core':         (counts['core'] as num?)?.toInt() ?? 0,
      'extended':     (counts['extended'] as num?)?.toInt() ?? 0,
      'marginal':     (counts['marginal'] as num?)?.toInt() ?? 0,
      'out_of_range': (counts['out_of_range'] as num?)?.toInt() ?? 0,
    };
  }

  String _trimNum(dynamic n) {
    final d = (n is num) ? n.toDouble() : double.tryParse(n.toString()) ?? 0;
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }

  String _zoneLabel(String key) {
    switch (key) {
      case 'core': return 'Core';
      case 'extended': return 'Extended';
      case 'marginal': return 'Marginal';
      default: return 'Out of range';
    }
  }

  String _fmtUpdatedAt(DateTime? utc) {
    if (utc == null) return '—';
    final ist = toIst(utc);
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${p2(ist.day)}/${p2(ist.month)}/${ist.year} ${p2(ist.hour)}:${p2(ist.minute)}';
  }

  // Core < Extended < Marginal, all > 0. Buttons read this live via setState
  // on the radii controllers so an invalid ladder can never be submitted.
  bool get _radiiValid {
    final core = double.tryParse(_hubCoreCtrl.text.trim());
    final ext  = double.tryParse(_hubExtCtrl.text.trim());
    final marg = double.tryParse(_hubMargCtrl.text.trim());
    if (core == null || ext == null || marg == null) return false;
    if (core <= 0 || ext <= 0 || marg <= 0) return false;
    return core < ext && ext < marg;
  }

  String? get _radiiError {
    if (_radiiValid) return null;
    final core = double.tryParse(_hubCoreCtrl.text.trim());
    final ext  = double.tryParse(_hubExtCtrl.text.trim());
    final marg = double.tryParse(_hubMargCtrl.text.trim());
    if (core == null || ext == null || marg == null || core <= 0 || ext <= 0 || marg <= 0) {
      return 'Enter valid radii — Core, Extended and Marginal must all be greater than 0.';
    }
    return 'Radii must increase: Core km < Extended km < Marginal km.';
  }

  Future<bool> _confirmHubChange() async {
    final total = _hubCounts.values.fold<int>(0, (s, v) => s + v);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Update warehouse?'),
        content: Text('This recalculates delivery zones and route start points '
            'for all $total leads. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Update warehouse'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  // Shared success path for lead_set_hub() (paths b + c — synchronous) and the
  // final polled lead_get_hub() row (path a — asynchronous geocode).
  void _applyHubSuccess(Map<String, dynamic> h, Map<String, int> beforeCounts) {
    setState(() {
      _applyHubMap(h);
      _hubBusy = false;
      _hubExpanded = false;
      _hubError = null;
      _hubGpsLat = null;
      _hubGpsLng = null;
      _hubGpsAddress = null;
      _hubCoordsCtrl.clear();
      final parts = <String>[];
      for (final k in ['core', 'extended', 'marginal', 'out_of_range']) {
        final before = beforeCounts[k] ?? 0;
        final after  = _hubCounts[k] ?? 0;
        if (before != after) parts.add('${_zoneLabel(k)} $before → $after');
      }
      _hubSuccessMsg = parts.isEmpty
          ? 'Warehouse updated.'
          : 'Warehouse updated. ${parts.join(', ')}.';
    });
    RenderLog.write('c444_hub_name', _hubNameCtrl.text);
    RenderLog.write('c444_hub_lat', '$_hubLat');
    RenderLog.write('c444_hub_lng', '$_hubLng');
    RenderLog.write('c444_core', _hubCounts['core']);
    RenderLog.write('c444_extended', _hubCounts['extended']);
    _hubSuccessTimer?.cancel();
    _hubSuccessTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _hubSuccessMsg = null);
    });
    // B6.2 — every visible lead's distance_km/delivery_zone just changed.
    _loadRows(reset: true);
  }

  // ── (a) Search by address — async geocode, must be polled ──────────────
  Future<void> _searchAndSetHub() async {
    if (_hubBusy || !_radiiValid) return;
    final address = _hubAddressCtrl.text.trim();
    if (address.isEmpty) {
      setState(() => _hubError = 'Enter an address to search.');
      return;
    }
    final ok = await _confirmHubChange();
    if (!ok) return;
    final beforeLat = _hubLat;
    final beforeLng = _hubLng;
    final beforeCounts = Map<String, int>.from(_hubCounts);
    setState(() { _hubBusy = true; _hubError = null; });
    try {
      final client = Supabase.instance.client;
      final coreKm = double.parse(_hubCoreCtrl.text.trim());
      final extKm  = double.parse(_hubExtCtrl.text.trim());
      final margKm = double.parse(_hubMargCtrl.text.trim());
      await client.rpc('lead_set_hub_by_address', params: {
        'p_name': _hubNameCtrl.text.trim(),
        'p_address': address,
        'p_core_km': coreKm,
        'p_ext_km': extKm,
        'p_marg_km': margKm,
      });
      Map<String, dynamic>? finalHub;
      String? failMsg;
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 1000));
        if (!mounted) return;
        final raw = await client.rpc('lead_get_hub');
        final h = Map<String, dynamic>.from(raw as Map);
        final err = h['geocode_error'] as String?;
        if (err == 'pending') continue;
        if (err != null) { failMsg = err; break; }
        final lat = (h['lat'] as num?)?.toDouble();
        final lng = (h['lng'] as num?)?.toDouble();
        if (lat != beforeLat || lng != beforeLng) { finalHub = h; break; }
        // geocode_error cleared but coords unchanged (e.g. re-searched the
        // same point) — keep polling per spec rather than guessing success.
      }
      if (!mounted) return;
      if (finalHub != null) {
        _applyHubSuccess(finalHub, beforeCounts);
      } else if (failMsg != null) {
        setState(() { _hubBusy = false; _hubError = failMsg; }); // shown verbatim
      } else {
        setState(() {
          _hubBusy = false;
          _hubError = 'Geocoding is taking longer than expected — reopen the card to check.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _hubBusy = false; _hubError = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  // ── (b) Use my current location — reuses the app's existing GPS capture
  // (same html.window.navigator.geolocation + reverse-geocode edge function
  // pattern as CashPaymentSheet._requestLocation/_reverseGeocode). Capture is
  // a separate step from save: the captured lat/lng is shown to Om before any
  // write, per B4(b) step 2 and the B7 confirm.
  Future<void> _useMyLocation() async {
    setState(() {
      _hubLocating = true;
      _hubLocError = null;
      _hubGpsLat = null;
      _hubGpsLng = null;
      _hubGpsAddress = null;
    });
    try {
      final completer = Completer<html.Geoposition>();
      html.window.navigator.geolocation
          .getCurrentPosition(enableHighAccuracy: false, timeout: const Duration(seconds: 20))
          .then((pos) { if (!completer.isCompleted) completer.complete(pos); })
          .catchError((e) { if (!completer.isCompleted) completer.completeError(e); });
      final pos = await completer.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw TimeoutException('Location timed out'),
      );
      final lat = pos.coords?.latitude?.toDouble();
      final lng = pos.coords?.longitude?.toDouble();
      if (lat == null || lng == null) throw Exception('No coordinates returned');
      if (!mounted) return;
      setState(() { _hubGpsLat = lat; _hubGpsLng = lng; _hubLocating = false; });
      // Cosmetic only — the coordinates are what matter; proceed even if this fails.
      try {
        final res = await Supabase.instance.client.functions
            .invoke('reverse-geocode', body: {'lat': lat, 'lng': lng})
            .timeout(const Duration(seconds: 12));
        final data = res.data;
        final map = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
        final addr = (map['address'] as String? ?? '').trim();
        if (mounted && addr.isNotEmpty) setState(() => _hubGpsAddress = addr);
      } catch (_) {}
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _hubLocating = false;
          _hubLocError = "Couldn't get a GPS fix. Try again outdoors, or paste coordinates.";
        });
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      final denied = msg.contains('denied') || msg.contains('permission');
      setState(() {
        _hubLocating = false;
        _hubLocError = denied
            ? 'Location permission denied — enable it in the browser/site settings.'
            : "Couldn't get a GPS fix. Try again outdoors, or paste coordinates.";
      });
    }
  }

  Future<void> _confirmAndSaveGps() async {
    if (_hubBusy || !_radiiValid || _hubGpsLat == null || _hubGpsLng == null) return;
    final ok = await _confirmHubChange();
    if (!ok) return;
    await _saveHubCoords(_hubGpsLat!, _hubGpsLng!, address: _hubGpsAddress);
  }

  // ── (c) Paste coordinates or a Maps link ────────────────────────────────
  static final RegExp _coordPairRegex =
      RegExp(r'(-?\d{1,3}\.\d+)\s*[,\s]\s*(-?\d{1,3}\.\d+)');

  Future<void> _setFromCoordsText() async {
    if (_hubBusy || !_radiiValid) return;
    final raw = _hubCoordsCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _hubError = 'Paste coordinates or a Google Maps link.');
      return;
    }
    if (raw.contains('maps.app.goo.gl') || raw.contains('goo.gl/maps')) {
      setState(() => _hubError =
          "Short Maps links don't contain coordinates. In Google Maps, "
          "long-press the spot → tap the coordinates to copy them → paste "
          "here. Or use 'Search & Set' with the address.");
      return;
    }
    final m = _coordPairRegex.firstMatch(raw);
    final lat = m != null ? double.tryParse(m.group(1)!) : null;
    final lng = m != null ? double.tryParse(m.group(2)!) : null;
    if (lat == null || lng == null || lat < -90 || lat > 90 || lng < -180 || lng > 180) {
      setState(() => _hubError =
          'Could not find valid coordinates in that text. Paste "lat, lng" or '
          'a Google Maps link containing them.');
      return;
    }
    final ok = await _confirmHubChange();
    if (!ok) return;
    await _saveHubCoords(lat, lng);
  }

  // Shared write for paths (b) and (c) — lead_set_hub() is synchronous and
  // returns the same shape as lead_get_hub(); no polling needed here.
  Future<void> _saveHubCoords(double lat, double lng, {String? address}) async {
    final beforeCounts = Map<String, int>.from(_hubCounts);
    setState(() { _hubBusy = true; _hubError = null; });
    try {
      final coreKm = double.parse(_hubCoreCtrl.text.trim());
      final extKm  = double.parse(_hubExtCtrl.text.trim());
      final margKm = double.parse(_hubMargCtrl.text.trim());
      final res = await Supabase.instance.client.rpc('lead_set_hub', params: {
        'p_name': _hubNameCtrl.text.trim(),
        'p_lat': lat,
        'p_lng': lng,
        'p_core_km': coreKm,
        'p_ext_km': extKm,
        'p_marg_km': margKm,
        if (address != null && address.isNotEmpty) 'p_address': address,
      });
      if (!mounted) return;
      final h = Map<String, dynamic>.from(res as Map);
      _applyHubSuccess(h, beforeCounts);
    } catch (e) {
      if (!mounted) return;
      setState(() { _hubBusy = false; _hubError = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  List<String> _labelsForUiTypes(dynamic uiTypes, {List<_LeadTypeOption>? options}) {
    if (uiTypes is! List) return [];
    final opts = options ?? _typeOptions;
    return uiTypes.map((t) {
      final key = t.toString();
      final match = opts.where((o) => o.uiType == key);
      return match.isNotEmpty ? match.first.label : key;
    }).toList();
  }

  Future<void> _refreshSummaryAndUsage() async {
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait<dynamic>([
        client.rpc('lead_leads_summary', params: {'p_city': null}),
        client.rpc('lead_scrape_month_usage'),
        client.rpc('lead_enrich_status', params: {'p_run_id': null}),
      ]);
      final summary = Map<String, dynamic>.from(results[0] as Map);
      final usage = Map<String, dynamic>.from(results[1] as Map);
      final enrichStatus = Map<String, dynamic>.from(results[2] as Map);
      RenderLog.write('c443_summary_total', (summary['total'] as num?)?.toInt() ?? 0);
      RenderLog.write('c443_month_used', (usage['used'] as num?)?.toInt() ?? 0);
      RenderLog.write('c443_enriched', (enrichStatus['enriched'] as num?)?.toInt() ?? 0);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _monthUsage = usage;
        _enrichStatus = enrichStatus;
      });
      widget.onTotalChanged((summary['total'] as num?)?.toInt() ?? 0);
    } catch (_) {}
  }

  Future<void> _loadPastRuns() async {
    try {
      final res = await Supabase.instance.client
          .rpc('lead_scrape_runs_list', params: {'p_limit': 10}) as List;
      final runs = res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      RenderLog.write('c443_runs_rows', runs.length);
      RenderLog.write('c443_runs_types',
          runs.isNotEmpty ? _labelsForUiTypes(runs.first['ui_types']).join(', ') : '');
      if (!mounted) return;
      setState(() {
        _pastRuns = runs;
      });
    } catch (_) {}
  }

  // ── Results ────────────────────────────────────────────────────────────

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce =
        Timer(const Duration(milliseconds: 400), () => _loadRows(reset: true));
  }

  Future<void> _loadRows({bool reset = false}) async {
    if (reset) _page = 0;
    setState(() => _rowsLoading = true);
    try {
      final offset = _page * _pageSize;
      final search = _searchCtrl.text.trim();
      final res = await Supabase.instance.client.rpc('get_scraped_leads', params: {
        'p_city': _cityFilter,
        'p_class': _classFilter == 'all' ? null : _classFilter,
        'p_targets_only': _targetsOnly,
        'p_with_phone': _withPhone,
        'p_search': search.isEmpty ? null : search,
        'p_status': null,
        'p_open_now': _openNowOnly,
        'p_with_email': _withEmailOnly,
        'p_limit': _pageSize,
        'p_offset': offset,
      }) as List;
      final rows = res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final total = rows.isNotEmpty
          ? ((rows.first['total_count'] as num?)?.toInt() ?? 0)
          : 0;
      final withPhoto = rows.where((r) => (r['photo_url'] as String?)?.isNotEmpty == true).length;
      final withHours = rows.where((r) => (r['hours_text'] as List?)?.isNotEmpty == true).length;
      final openNowTrue = rows.where((r) => r['open_now'] == true).length;
      RenderLog.write('c443_rows_rendered', rows.length);
      RenderLog.write('c443_total_count', total);
      RenderLog.write('c443_rows', rows.length);
      RenderLog.write('c443_with_photo', withPhoto);
      RenderLog.write('c443_with_hours', withHours);
      RenderLog.write('c443_open_now_true', openNowTrue);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _totalCount = total;
        _rowsLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _rowsLoading = false);
        showToast(context, 'Failed to load leads: $e', isError: true);
      }
    }
  }

  void _changeFilters({
    String? city,
    bool cityIsAll = false,
    String? classKey,
    bool? targetsOnly,
    bool? withPhone,
    bool? openNow,
    bool? withEmail,
  }) {
    setState(() {
      if (cityIsAll) _cityFilter = null;
      if (city != null) _cityFilter = city;
      if (classKey != null) _classFilter = classKey;
      if (targetsOnly != null) _targetsOnly = targetsOnly;
      if (withPhone != null) _withPhone = withPhone;
      if (openNow != null) _openNowOnly = openNow;
      if (withEmail != null) _withEmailOnly = withEmail;
    });
    _loadRows(reset: true);
  }

  void _goToPage(int page) {
    setState(() => _page = page);
    _loadRows();
  }

  // ── Scrape control ────────────────────────────────────────────────────

  bool get _canScrape =>
      _selectedTypes.isNotEmpty &&
      _nameCtrl.text.trim().isNotEmpty &&
      (int.tryParse(_budgetCtrl.text.trim()) ?? 0) >= 1 &&
      !_starting &&
      _activeRunId == null;

  String _friendlyError(String msg) {
    if (msg.contains('a_scrape_is_already_running')) {
      return 'A scrape is already running — wait for it to finish.';
    }
    if (msg.contains('name_required')) return 'Name is required.';
    if (msg.contains('no_valid_store_type_selected')) {
      return 'Select at least one store type.';
    }
    if (msg.contains('not_authorized')) return 'Not authorized.';
    return msg;
  }

  Future<void> _startScrape() async {
    final types = _selectedTypes.toList();
    final name = _nameCtrl.text.trim();
    final budget = int.tryParse(_budgetCtrl.text.trim()) ?? 800;
    setState(() {
      _starting = true;
      _formError = null;
    });
    try {
      final runId = await Supabase.instance.client.rpc('lead_scrape_start', params: {
        'p_name': name,
        'p_level': _level,
        'p_ui_types': types,
        'p_cell_km': null,
        'p_max_calls': budget,
      });
      if (!mounted) return;
      final id = runId?.toString();
      setState(() {
        _activeRunId = id;
        _activeRunLevel = _level;
        _activeRunTypeLabels =
            _typeOptions.where((o) => types.contains(o.uiType)).map((o) => o.label).toList();
        _starting = false;
      });
      if (id != null) {
        _refreshStatus();
        _startPolling();
        _subscribeToRun(id);
      }
    } on PostgrestException catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _formError = _friendlyError(e.message);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _formError = e.toString();
        });
      }
    }
  }

  Future<void> _resumeScrape() async {
    if (_activeRunId == null) return;
    setState(() => _resuming = true);
    try {
      await Supabase.instance.client.rpc('lead_scrape_resume',
          params: {'p_run_id': _activeRunId, 'p_extra_calls': 500});
      await _refreshStatus();
    } catch (e) {
      if (mounted) showToast(context, 'Resume failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _resuming = false);
    }
  }

  void _subscribeToRun(String runId) {
    _runChannel?.unsubscribe();
    final ts = DateTime.now().millisecondsSinceEpoch;
    _runChannel = Supabase.instance.client
        .channel('s_leads_run_${runId}_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'lead_scrape_runs',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: runId,
          ),
          callback: (_) => _refreshStatus(),
        )
        .subscribe();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _refreshStatus());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _refreshStatus() async {
    if (_activeRunId == null) return;
    try {
      final res = await Supabase.instance.client
          .rpc('lead_scrape_status', params: {'p_run_id': _activeRunId});
      final status = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      setState(() => _runStatus = status);
      final s = status['status'] as String?;
      if (s == 'done') {
        _stopPolling();
        _runChannel?.unsubscribe();
        _runChannel = null;
        final newLeads = (status['leads_new'] as num?)?.toInt() ?? 0;
        showToast(context, 'Scrape complete — $newLeads new leads found.');
        await Future.wait([_refreshSummaryAndUsage(), _loadRows(reset: true), _loadPastRuns()]);
        if (mounted) setState(() => _activeRunId = null);
      } else if (s == 'error') {
        _stopPolling();
        _runChannel?.unsubscribe();
        _runChannel = null;
        showToast(context, 'Scrape error: ${status['error'] ?? 'unknown'}', isError: true);
        await _loadPastRuns();
        if (mounted) setState(() => _activeRunId = null);
      }
    } catch (_) {}
  }

  // ── Build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_initialLoading) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(
          child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
        ),
      );
    }
    final pad = widget.isDesktop ? 28.0 : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 20, pad, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loadError != null) ...[
            Text('Failed to load: $_loadError',
                style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
            const SizedBox(height: 12),
          ],
          _buildWarehouseCard(),
          const SizedBox(height: 20),
          _buildScrapeForm(),
          if (_activeRunId != null && _runStatus != null) ...[
            const SizedBox(height: 20),
            _buildProgressPanel(),
          ],
          const SizedBox(height: 28),
          _buildResultsSection(),
          const SizedBox(height: 28),
          _buildPastRunsSection(),
        ],
      ),
    );
  }

  // ── CHANGE #447: Warehouse (hub) card ───────────────────────────────────

  Widget _buildWarehouseCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _hubExpanded = !_hubExpanded),
          borderRadius: BorderRadius.circular(8),
          child: Row(children: [
            const Text('🏠', style: TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    'Warehouse: ${_hubNameCtrl.text.isNotEmpty ? _hubNameCtrl.text : "Not set"}',
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                  ),
                  Text(
                    '·  ${_hubCounts['core']} core · ${_hubCounts['extended']} extended',
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _hubExpanded = !_hubExpanded),
              child: Text(_hubExpanded ? 'Close' : 'Change'),
            ),
          ]),
        ),
        if (_hubExpanded) ...[
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 14),
          if (_hubError != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_hubError!,
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF991B1B))),
            ),
            const SizedBox(height: 12),
          ],
          if (_hubSuccessMsg != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFD1FAE5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_hubSuccessMsg!,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF065F46))),
            ),
            const SizedBox(height: 12),
          ],
          // ── Name / Address ────────────────────────────────────────────
          widget.isDesktop
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _hubNameField()),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _hubAddressField()),
                ])
              : Column(children: [
                  _hubNameField(),
                  const SizedBox(height: 10),
                  _hubAddressField(),
                ]),
          const SizedBox(height: 10),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 6, children: [
            Text(
              _hubLat != null && _hubLng != null
                  ? '${_hubLat!.toStringAsFixed(6)}, ${_hubLng!.toStringAsFixed(6)}'
                  : 'No coordinates set',
              style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)),
            ),
            if (_hubMapsLink != null)
              InkWell(
                onTap: () => launchUrl(Uri.parse(_hubMapsLink!), mode: LaunchMode.externalApplication),
                child: const Text('Map',
                    style: TextStyle(
                        fontSize: 12.5, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600)),
              ),
          ]),
          const SizedBox(height: 4),
          Text('Last updated: ${_fmtUpdatedAt(_hubUpdatedAt)}',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
          const SizedBox(height: 14),
          // ── Radii ────────────────────────────────────────────────────
          const Text('Delivery radii (km)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 10, children: [
            SizedBox(width: 110, child: _hubKmField(_hubCoreCtrl, 'Core')),
            SizedBox(width: 110, child: _hubKmField(_hubExtCtrl, 'Extended')),
            SizedBox(width: 110, child: _hubKmField(_hubMargCtrl, 'Marginal')),
          ]),
          if (_radiiError != null) ...[
            const SizedBox(height: 8),
            Text(_radiiError!, style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
          ],
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            _zoneChip('Core', _hubCounts['core'] ?? 0, const Color(0xFFD1FAE5), const Color(0xFF065F46)),
            _zoneChip('Extended', _hubCounts['extended'] ?? 0, const Color(0xFFEFF6FF), const Color(0xFF1E40AF)),
            _zoneChip('Marginal', _hubCounts['marginal'] ?? 0, const Color(0xFFFEF3C7), const Color(0xFF92400E)),
            _zoneChip('Out of range', _hubCounts['out_of_range'] ?? 0, const Color(0xFFF3F4F6), const Color(0xFF6B7280)),
          ]),
          const SizedBox(height: 18),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 14),
          // ── (a) Search by address ───────────────────────────────────
          const Text('Search & set',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const SizedBox(height: 8),
          SizedBox(
            width: widget.isDesktop ? 220 : double.infinity,
            child: ElevatedButton.icon(
              onPressed: (_hubBusy || !_radiiValid) ? null : _searchAndSetHub,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFD1D5DB),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: (_hubBusy)
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.search, size: 16),
              label: Text(_hubBusy ? 'Recomputing…' : 'Search & Set',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ),
          if (_hubBusy)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Recomputing distances for all leads…',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
            ),
          const SizedBox(height: 18),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 14),
          // ── (b) Use my current location ─────────────────────────────
          const Text('Use my current location',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton.icon(
              onPressed: (_hubBusy || _hubLocating) ? null : _useMyLocation,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1B7A43),
                side: const BorderSide(color: Color(0xFF1B7A43)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: _hubLocating
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.my_location, size: 16),
              label: Text(_hubLocating ? 'Locating…' : 'Use my location',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
            if (_hubGpsLat != null && _hubGpsLng != null) ...[
              Text('Captured: ${_hubGpsLat!.toStringAsFixed(6)}, ${_hubGpsLng!.toStringAsFixed(6)}'
                      '${_hubGpsAddress != null ? " — $_hubGpsAddress" : ""}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
              ElevatedButton(
                onPressed: (_hubBusy || !_radiiValid) ? null : _confirmAndSaveGps,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B7A43),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Confirm & Save', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
              ),
            ],
          ]),
          if (_hubLocError != null) ...[
            const SizedBox(height: 6),
            Text(_hubLocError!, style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
          ],
          const SizedBox(height: 18),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 14),
          // ── (c) Paste coordinates or a Maps link ─────────────────────
          const Text('Paste coordinates or a Google Maps link',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const SizedBox(height: 8),
          widget.isDesktop
              ? Row(children: [
                  Expanded(child: _hubCoordsField()),
                  const SizedBox(width: 10),
                  _hubCoordsSetButton(),
                ])
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _hubCoordsField(),
                  const SizedBox(height: 10),
                  _hubCoordsSetButton(),
                ]),
        ],
      ]),
    );
  }

  Widget _hubNameField() {
    return TextField(
      controller: _hubNameCtrl,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: 'Name',
        labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _hubAddressField() {
    return TextField(
      controller: _hubAddressCtrl,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: 'Address',
        hintText: 'Sai Mandir, Daganiya, Raipur',
        labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _hubKmField(TextEditingController ctrl, String label) {
    return TextField(
      controller: ctrl,
      onChanged: (_) => setState(() {}),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))],
      decoration: InputDecoration(
        labelText: '$label km',
        labelStyle: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _hubCoordsField() {
    return TextField(
      controller: _hubCoordsCtrl,
      onChanged: (_) {
        if (_hubError != null) setState(() => _hubError = null);
      },
      decoration: InputDecoration(
        hintText: '21.238713, 81.6069852  or a Google Maps link',
        hintStyle: const TextStyle(fontSize: 12.5, color: Color(0xFF9CA3AF)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _hubCoordsSetButton() {
    return SizedBox(
      width: widget.isDesktop ? 100 : double.infinity,
      child: ElevatedButton(
        onPressed: (_hubBusy || !_radiiValid) ? null : _setFromCoordsText,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1B7A43),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFD1D5DB),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        child: const Text('Set', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _zoneChip(String label, int count, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text('$count $label',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  // ── B2: Scrape form ────────────────────────────────────────────────────

  Widget _buildScrapeForm() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Scrape new leads',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const SizedBox(height: 14),
          widget.isDesktop
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SizedBox(width: 220, child: _levelToggle()),
                  const SizedBox(width: 12),
                  Expanded(child: _nameField()),
                  const SizedBox(width: 12),
                  SizedBox(width: 180, child: _budgetField()),
                ])
              : Column(children: [
                  _levelToggle(),
                  const SizedBox(height: 10),
                  _nameField(),
                  const SizedBox(height: 10),
                  _budgetField(),
                ]),
          const SizedBox(height: 14),
          const Text('Store types',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
          const SizedBox(height: 8),
          _storeTypeChips(),
          const SizedBox(height: 14),
          _costStrip(),
          if (_formError != null) ...[
            const SizedBox(height: 10),
            Text(_formError!, style: const TextStyle(color: Color(0xFFDC2626), fontSize: 12.5)),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: widget.isDesktop ? 180 : double.infinity,
            child: ElevatedButton.icon(
              onPressed: _canScrape ? _startScrape : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(0xFFD1D5DB),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              icon: _starting
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.travel_explore, size: 17),
              label: Text(_starting ? 'Starting…' : 'Scrap',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _levelToggle() {
    return Row(children: [
      Expanded(child: _segBtn('City', _level == 'city', () => setState(() => _level = 'city'))),
      const SizedBox(width: 8),
      Expanded(child: _segBtn('District', _level == 'district', () => setState(() => _level = 'district'))),
    ]);
  }

  Widget _segBtn(String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1B7A43) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600,
                color: active ? Colors.white : const Color(0xFF374151))),
      ),
    );
  }

  Widget _nameField() {
    return TextField(
      controller: _nameCtrl,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: 'Name',
        hintText: 'Raipur',
        labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _budgetField() {
    return TextField(
      controller: _budgetCtrl,
      onChanged: (_) => setState(() {}),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: 'Max API calls',
        labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _storeTypeChips() {
    final sorted = [..._typeOptions]..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final chips = sorted.map((o) {
      final sel = _selectedTypes.contains(o.uiType);
      return FilterChip(
        label: Text(o.label, style: const TextStyle(fontSize: 11)),
        selected: sel,
        onSelected: (v) {
          setState(() {
            if (v) {
              _selectedTypes.add(o.uiType);
            } else {
              _selectedTypes.remove(o.uiType);
            }
          });
        },
        selectedColor: const Color(0xFFDCFCE7),
        checkmarkColor: const Color(0xFF1B7A43),
        backgroundColor: const Color(0xFFF3F4F6),
        side: BorderSide(color: sel ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
        labelStyle: TextStyle(color: sel ? const Color(0xFF1B7A43) : const Color(0xFF374151)),
      );
    }).toList();
    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }

  Widget _costStrip() {
    final used = (_monthUsage?['used'] as num?)?.toInt() ?? 0;
    final freeLimit = (_monthUsage?['free_limit'] as num?)?.toInt() ?? 1000;
    final remaining = (_monthUsage?['remaining'] as num?)?.toInt() ?? 0;
    final resetsOn = _monthUsage?['resets_on']?.toString() ?? '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: remaining <= 0 ? const Color(0xFFFEF2F2) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: remaining <= 0 ? const Color(0xFFFCA5A5) : const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          'Google free calls: $used / $freeLimit used this month · $remaining left · resets $resetsOn',
          style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
        ),
        if (remaining <= 0) ...[
          const SizedBox(height: 4),
          const Text('Past free tier — approx ₹3 per call.',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFDC2626))),
        ],
      ]),
    );
  }

  // ── B3: Progress panel ─────────────────────────────────────────────────

  Widget _buildProgressPanel() {
    final status = _runStatus!;
    final s = status['status'] as String?;
    if (!_sLeadActiveStatuses.contains(s)) return const SizedBox.shrink();
    final pct = ((status['pct'] as num?)?.toDouble() ?? 0) / 100.0;
    final city = status['city']?.toString() ?? _nameCtrl.text;
    final cellsTotal = (status['cells_total'] as num?)?.toInt() ?? 0;
    final cellsDone = (status['cells_done'] as num?)?.toInt() ?? 0;
    final apiCalls = (status['api_calls'] as num?)?.toInt() ?? 0;
    final maxCalls = int.tryParse(_budgetCtrl.text.trim()) ?? 800;
    final leadsNew = (status['leads_new'] as num?)?.toInt() ?? 0;

    String label;
    switch (s) {
      case 'planning': label = 'Planning…'; break;
      case 'running': label = 'Scraping…'; break;
      case 'paused_budget': label = 'Paused (budget)'; break;
      default: label = s ?? '';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('$city · ${_activeRunLevel ?? _level} · ${_activeRunTypeLabels.join(", ")}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFF1B7A43),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct.clamp(0.0, 1.0),
            minHeight: 6,
            color: const Color(0xFF1B7A43),
            backgroundColor: const Color(0xFFE5E7EB),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$cellsDone / $cellsTotal cells · $apiCalls/$maxCalls calls · $leadsNew new leads',
          style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
        ),
        if (s == 'paused_budget') ...[
          const SizedBox(height: 10),
          Text('Budget limit reached ($apiCalls calls).',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFFD97706))),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _resuming ? null : _resumeScrape,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF1B7A43),
              side: const BorderSide(color: Color(0xFF1B7A43)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            icon: _resuming
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.play_arrow, size: 16),
            label: const Text('Resume (+500 calls)', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
        ],
      ]),
    );
  }

  // ── B4: Results ────────────────────────────────────────────────────────

  Widget _buildResultsSection() {
    final byClass = (_summary?['by_class'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [];
    final cities = (_summary?['cities'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        [];
    final total = (_summary?['total'] as num?)?.toInt() ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Scraped leads',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 12),
        _buildFilterBar(byClass, cities, total),
        const SizedBox(height: 14),
        if (_rowsLoading && _rows.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)),
          )
        else if (_rows.isEmpty)
          _ssvEmptyStateLocal('0 leads match these filters')
        else ...[
          ..._rows.map((r) => _buildLeadRow(r)),
          const SizedBox(height: 12),
          _buildPagination(),
        ],
      ],
    );
  }

  Widget _ssvEmptyStateLocal(String message) {
    return Padding(
      padding: const EdgeInsets.only(top: 40, bottom: 20),
      child: Center(
        child: Text(message,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
      ),
    );
  }

  Widget _buildFilterBar(
      List<Map<String, dynamic>> byClass, List<Map<String, dynamic>> cities, int total) {
    final classCounts = <String, int>{
      for (final c in byClass) (c['class']?.toString() ?? ''): (c['n'] as num?)?.toInt() ?? 0
    };

    final classChips = <Widget>[
      _classChip('all', 'All ($total)', _classFilter == 'all'),
      ..._sLeadClassOrder.map((k) =>
          _classChip(k, '${_sLeadClassLabels[k]} (${classCounts[k] ?? 0})', _classFilter == k)),
    ];

    final cityDropdown = DropdownButton<String?>(
      value: _cityFilter,
      hint: const Text('All cities', style: TextStyle(fontSize: 12.5)),
      underline: const SizedBox.shrink(),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('All cities', style: TextStyle(fontSize: 12.5))),
        ...cities.map((c) => DropdownMenuItem<String?>(
              value: c['city']?.toString(),
              child: Text('${c['city']} (${c['n']})', style: const TextStyle(fontSize: 12.5)),
            )),
      ],
      onChanged: (v) => _changeFilters(city: v, cityIsAll: v == null),
    );

    final targetsToggle = _filterToggle('Only B2B targets', _targetsOnly, (v) => _changeFilters(targetsOnly: v));
    final phoneToggle = _filterToggle('Only with phone', _withPhone, (v) => _changeFilters(withPhone: v));
    final openNowToggle = _filterToggle('Open now', _openNowOnly, (v) => _changeFilters(openNow: v));
    final emailToggle = _filterToggle('Has email', _withEmailOnly, (v) => _changeFilters(withEmail: v));

    final searchBox = TextField(
      controller: _searchCtrl,
      decoration: InputDecoration(
        hintText: 'Search name / phone / address / pincode / area',
        hintStyle: const TextStyle(fontSize: 12.5),
        prefixIcon: const Icon(Icons.search, size: 18),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // CHANGE #443 (part 2) — always Wrap (never a plain Row) now that there
      // are 5 items in this group; a fixed Row overflowed near the 900px
      // desktop/mobile boundary once "Open now" + "Has email" were added.
      Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        cityDropdown, targetsToggle, phoneToggle, openNowToggle, emailToggle,
      ]),
      const SizedBox(height: 10),
      widget.isDesktop
          ? Wrap(spacing: 6, runSpacing: 6, children: classChips)
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (int i = 0; i < classChips.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  classChips[i],
                ],
              ]),
            ),
      const SizedBox(height: 10),
      SizedBox(width: widget.isDesktop ? 360 : double.infinity, child: searchBox),
    ]);
  }

  Widget _classChip(String key, String label, bool selected) {
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: selected,
      onSelected: (_) => _changeFilters(classKey: key),
      selectedColor: const Color(0xFFDCFCE7),
      backgroundColor: const Color(0xFFF3F4F6),
      side: BorderSide(color: selected ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
      labelStyle: TextStyle(color: selected ? const Color(0xFF1B7A43) : const Color(0xFF374151)),
    );
  }

  Widget _filterToggle(String label, bool value, ValueChanged<bool> onChanged) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Transform.scale(
        scale: 0.75,
        child: Switch(
          value: value,
          onChanged: onChanged,
          activeColor: const Color(0xFF1B7A43),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      Text(label, style: const TextStyle(fontSize: 12.5, color: Color(0xFF374151))),
    ]);
  }

  // ── CHANGE #443 (part 2) — rich lead card ───────────────────────────────

  Future<void> _fetchLeadDetail(int id) async {
    setState(() => _detailLoading.add(id));
    try {
      final res =
          await Supabase.instance.client.rpc('get_lead_detail', params: {'p_lead_id': id});
      if (mounted) {
        setState(() {
          _leadDetailCache[id] = Map<String, dynamic>.from(res as Map);
          _detailLoading.remove(id);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _detailLoading.remove(id));
    }
  }

  static const List<String> _sLeadWeekdayNames = [
    'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
  ];

  String _todayHoursLine(List<String> hours) {
    if (hours.isEmpty) return '';
    final todayName = _sLeadWeekdayNames[nowIst().weekday - 1];
    final match = hours.firstWhere((h) => h.startsWith(todayName), orElse: () => '');
    if (match.isEmpty) return '';
    final idx = match.indexOf(':');
    return idx == -1 ? match : match.substring(idx + 1).trim();
  }

  String _leadLocationLine(Map<String, dynamic> r) {
    final area = r['area']?.toString().trim();
    final locality = r['locality']?.toString().trim();
    final pincode = r['pincode']?.toString().trim();
    final parts = <String>[];
    if (area != null && area.isNotEmpty) parts.add(area);
    if (locality != null && locality.isNotEmpty && locality != area) parts.add(locality);
    var line = parts.join(', ');
    if (pincode != null && pincode.isNotEmpty) {
      line = line.isEmpty ? pincode : '$line · $pincode';
    }
    if (line.isEmpty) {
      line = r['short_address']?.toString() ?? r['address']?.toString() ?? '';
    }
    return line;
  }

  bool _isOldReview(String? age) {
    if (age == null) return false;
    final m = RegExp(r'(\d+)\s+years?\s+ago').firstMatch(age);
    if (m == null) return false;
    final n = int.tryParse(m.group(1) ?? '');
    return n != null && n >= 5;
  }

  Widget _leadThumb(String? url, int photoCount, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: (url == null || url.isEmpty)
              ? Container(
                  color: const Color(0xFFF3F4F6),
                  alignment: Alignment.center,
                  child: Icon(Icons.storefront_outlined, size: size * 0.45, color: const Color(0xFFD1D5DB)),
                )
              : Image.network(
                  url,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  cacheWidth: (size * 2).toInt(),
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
                    child: Icon(Icons.storefront_outlined, size: size * 0.45, color: const Color(0xFFD1D5DB)),
                  ),
                ),
        ),
        if (photoCount > 1)
          Positioned(
            right: 2, bottom: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Text('+${photoCount - 1}',
                  style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          ),
      ]),
    );
  }

  Widget _actionLink(IconData icon, String label, Color color, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }

  Widget _buildLeadRow(Map<String, dynamic> r) {
    final id = (r['id'] as num?)?.toInt();
    final name = r['name']?.toString() ?? '';
    final phone = r['phone']?.toString();
    final emails = (r['emails'] as List?) ?? [];
    final email = emails.isNotEmpty ? emails.first.toString() : null;
    final website = r['website']?.toString();
    final leadClass = r['lead_class']?.toString() ?? 'other';
    final typeLabel = r['type_label']?.toString();
    final rating = (r['rating'] as num?)?.toDouble();
    final userRatings = (r['user_ratings'] as num?)?.toInt();
    final openNow = r['open_now'] as bool?;
    final mapsUri = r['maps_uri']?.toString();
    final directionsUri = (r['maps_directions_uri']?.toString().isNotEmpty ?? false)
        ? r['maps_directions_uri'].toString()
        : mapsUri;
    final businessStatus = r['business_status']?.toString();
    final isClosed = businessStatus != null && businessStatus != 'OPERATIONAL';
    final color = _sLeadClassColors[leadClass] ?? const Color(0xFF6B7280);
    final photoUrl = r['photo_url']?.toString();
    final photoCount = (r['photo_count'] as num?)?.toInt() ?? 0;
    final hours = ((r['hours_text'] as List?) ?? []).map((e) => e.toString()).toList();
    final todayHours = _todayHoursLine(hours);
    final locationLine = _leadLocationLine(r);
    final lastReviewAge = r['last_review_age']?.toString();
    final oldReview = _isOldReview(lastReviewAge);
    final thumbSize = widget.isDesktop ? 64.0 : 48.0;
    final expanded = id != null && _expandedIds.contains(id);

    return Opacity(
      opacity: isClosed ? 0.5 : 1.0,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: id == null
              ? null
              : () {
                  setState(() {
                    if (expanded) {
                      _expandedIds.remove(id);
                    } else {
                      _expandedIds.add(id);
                    }
                  });
                  if (!expanded && !_leadDetailCache.containsKey(id) && !_detailLoading.contains(id)) {
                    _fetchLeadDetail(id);
                  }
                },
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _leadThumb(photoUrl, photoCount, thumbSize),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
                      Text(name,
                          style: TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w700, color: const Color(0xFF111827),
                              decoration: isClosed ? TextDecoration.lineThrough : null)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: color.withValues(alpha: 0.3)),
                        ),
                        child: Text(_sLeadClassLabels[leadClass] ?? leadClass,
                            style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
                      if (rating != null)
                        Text('★ $rating${userRatings != null ? ' ($userRatings)' : ''}',
                            style: const TextStyle(fontSize: 11.5, color: Color(0xFFD97706))),
                      if (typeLabel != null && typeLabel.isNotEmpty)
                        Text(typeLabel, style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
                      if (openNow != null)
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: 6, height: 6,
                            decoration: BoxDecoration(
                                color: openNow ? const Color(0xFF16A34A) : const Color(0xFF9CA3AF),
                                shape: BoxShape.circle),
                          ),
                          const SizedBox(width: 4),
                          Text(openNow ? 'Open now' : 'Closed',
                              style: TextStyle(
                                  fontSize: 11.5, fontWeight: FontWeight.w600,
                                  color: openNow ? const Color(0xFF16A34A) : const Color(0xFF6B7280))),
                        ]),
                    ]),
                    if (locationLine.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(locationLine,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                    ],
                    const SizedBox(height: 6),
                    Wrap(spacing: 14, runSpacing: 4, children: [
                      if (phone != null && phone.isNotEmpty)
                        _actionLink(Icons.call_outlined, phone, const Color(0xFF1B7A43),
                            () => launchUrl(Uri.parse('tel:$phone'))),
                      if (email != null && email.isNotEmpty)
                        _actionLink(Icons.email_outlined, 'Email', const Color(0xFF7C3AED),
                            () => launchUrl(Uri.parse('mailto:$email'))),
                      if (website != null && website.isNotEmpty)
                        _actionLink(Icons.language, 'Website', const Color(0xFF2563EB),
                            () => launchUrl(Uri.parse(website), mode: LaunchMode.externalApplication)),
                      if (mapsUri != null && mapsUri.isNotEmpty)
                        _actionLink(Icons.map_outlined, 'Map', const Color(0xFF2563EB),
                            () => launchUrl(Uri.parse(mapsUri), mode: LaunchMode.externalApplication)),
                      if (directionsUri != null && directionsUri.isNotEmpty)
                        _actionLink(Icons.directions_outlined, 'Directions', const Color(0xFF2563EB),
                            () => launchUrl(Uri.parse(directionsUri), mode: LaunchMode.externalApplication)),
                    ]),
                    if (todayHours.isNotEmpty || (lastReviewAge != null && lastReviewAge.isNotEmpty)) ...[
                      const SizedBox(height: 6),
                      Wrap(spacing: 14, runSpacing: 4, children: [
                        if (todayHours.isNotEmpty)
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            const Icon(Icons.access_time, size: 12, color: Color(0xFF6B7280)),
                            const SizedBox(width: 4),
                            Text(todayHours, style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
                          ]),
                        if (lastReviewAge != null && lastReviewAge.isNotEmpty)
                          Text('Last review: $lastReviewAge',
                              style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: oldReview ? FontWeight.w600 : FontWeight.normal,
                                  color: oldReview ? const Color(0xFFD97706) : const Color(0xFF9CA3AF))),
                      ]),
                    ],
                  ]),
                ),
              ]),
              if (expanded) _buildLeadExpandPanel(r, id),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _miniChip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(10)),
        child: Text(label, style: const TextStyle(fontSize: 10.5, color: Color(0xFF374151))),
      );

  List<Widget> _paymentChips(Map paymentOptions) {
    bool truthy(dynamic v) => v == true;
    final chips = <Widget>[];
    if (truthy(paymentOptions['acceptsCreditCards']) || truthy(paymentOptions['acceptsDebitCards'])) {
      chips.add(_miniChip('Card'));
    }
    if (truthy(paymentOptions['acceptsNfc'])) chips.add(_miniChip('NFC'));
    if (truthy(paymentOptions['acceptsCashOnly'])) chips.add(_miniChip('Cash only'));
    return chips;
  }

  Widget _buildLeadExpandPanel(Map<String, dynamic> r, int? id) {
    final detail = id != null ? _leadDetailCache[id] : null;
    dynamic f(String key) => detail?[key] ?? r[key];

    final hours = ((f('hours_text') as List?) ?? []).map((e) => e.toString()).toList();
    final lat = (f('lat') as num?)?.toDouble();
    final lng = (f('lng') as num?)?.toDouble();
    final plusCode = f('plus_code')?.toString();
    final address = f('address')?.toString() ?? '';
    final area = f('area')?.toString();
    final locality = f('locality')?.toString();
    final district = f('district')?.toString();
    final state = f('state')?.toString();
    final pincode = f('pincode')?.toString();
    final paymentOptions = f('payment_options');
    final allTypes = ((f('all_types') as List?) ?? []).map((e) => e.toString()).toList();
    final reviewSnippets = ((f('review_snippets') as List?) ?? []).map((e) => e.toString()).toList();
    final websitePhones = ((f('website_phones') as List?) ?? []).map((e) => e.toString()).toList();
    final intlPhone = f('intl_phone')?.toString();
    final editorialSummary = f('editorial_summary')?.toString();
    final fullReviews = detail != null ? (detail['reviews'] as List?) : null;
    final loading = id != null && _detailLoading.contains(id);

    final addressParts = [address, area, locality, district, state, pincode]
        .where((e) => e != null && e.toString().trim().isNotEmpty)
        .join(', ');

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (hours.isNotEmpty) ...[
          const Text('Hours', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280))),
          const SizedBox(height: 4),
          ...hours.map((h) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(h, style: const TextStyle(fontSize: 12, color: Color(0xFF374151))))),
          const SizedBox(height: 10),
        ],
        if (lat != null && lng != null) ...[
          Row(children: [
            Expanded(
              child: Text(
                  '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}'
                  '${plusCode != null && plusCode.isNotEmpty ? ' · $plusCode' : ''}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
            ),
            InkWell(
              onTap: () => Clipboard.setData(ClipboardData(text: '$lat, $lng')),
              child: const Icon(Icons.copy, size: 14, color: Color(0xFF6B7280)),
            ),
          ]),
          const SizedBox(height: 10),
        ],
        if (addressParts.isNotEmpty) ...[
          Text(addressParts, style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
          const SizedBox(height: 10),
        ],
        if (paymentOptions is Map && paymentOptions.isNotEmpty) ...[
          Wrap(spacing: 6, runSpacing: 6, children: _paymentChips(paymentOptions)),
          const SizedBox(height: 10),
        ],
        if (allTypes.isNotEmpty) ...[
          Wrap(
            spacing: 4, runSpacing: 4,
            children: allTypes
                .map((t) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(10)),
                      child: Text(t, style: const TextStyle(fontSize: 10, color: Color(0xFF2563EB))),
                    ))
                .toList(),
          ),
          const SizedBox(height: 10),
        ],
        if (fullReviews != null && fullReviews.isNotEmpty) ...[
          const Text('Reviews', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280))),
          const SizedBox(height: 4),
          ...fullReviews.take(3).map((rv) {
            final m = Map<String, dynamic>.from(rv as Map);
            final author = (m['authorAttribution'] as Map?)?['displayName']?.toString() ?? '';
            final rrating = m['rating']?.toString() ?? '';
            final text = (m['text'] as Map?)?['text']?.toString() ?? '';
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('$author${rrating.isNotEmpty ? ' ($rrating★)' : ''}: $text',
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic, color: Color(0xFF4B5563))),
            );
          }),
          const SizedBox(height: 4),
        ] else if (reviewSnippets.isNotEmpty) ...[
          const Text('Reviews', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280))),
          const SizedBox(height: 4),
          ...reviewSnippets.take(3).map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(s,
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic, color: Color(0xFF4B5563))))),
          const SizedBox(height: 4),
        ],
        if (websitePhones.isNotEmpty || (intlPhone != null && intlPhone.isNotEmpty)) ...[
          Text(
              'More numbers: '
              '${[if (intlPhone != null && intlPhone.isNotEmpty) intlPhone, ...websitePhones].join(', ')}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
          const SizedBox(height: 10),
        ],
        if (editorialSummary != null && editorialSummary.isNotEmpty)
          Text(editorialSummary,
              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Color(0xFF6B7280))),
        if (loading) ...[
          const SizedBox(height: 10),
          const Row(children: [
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 6),
            Text('Loading full detail…', style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
          ]),
        ],
      ]),
    );
  }

  Widget _buildPagination() {
    final totalPages = _totalCount == 0 ? 1 : ((_totalCount + _pageSize - 1) ~/ _pageSize);
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      IconButton(
        onPressed: _page > 0 ? () => _goToPage(_page - 1) : null,
        icon: const Icon(Icons.chevron_left, size: 20),
      ),
      Text('Page ${_page + 1} of $totalPages', style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
      IconButton(
        onPressed: (_page + 1) * _pageSize < _totalCount ? () => _goToPage(_page + 1) : null,
        icon: const Icon(Icons.chevron_right, size: 20),
      ),
    ]);
  }

  // ── B5: Past runs ──────────────────────────────────────────────────────

  // ── C: Past runs — real table (web) / stacked cards (mobile) ────────────

  Widget _buildPastRunsSection() {
    final enriched = (_enrichStatus?['enriched'] as num?)?.toInt() ?? 0;
    final errors = (_enrichStatus?['errors'] as num?)?.toInt() ?? 0;
    final withPhoto = (_enrichStatus?['with_photo'] as num?)?.toInt() ?? 0;
    final withHours = (_enrichStatus?['with_hours'] as num?)?.toInt() ?? 0;
    final withWebsite = (_enrichStatus?['with_website'] as num?)?.toInt() ?? 0;
    final withEmail = (_enrichStatus?['with_email'] as num?)?.toInt() ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.history, size: 16, color: Color(0xFF6B7280)),
          const SizedBox(width: 8),
          Text('Past runs (${_pastRuns.length})',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8)),
          child: Text(
            'Enriched $enriched · $errors errors · $withPhoto photos · $withHours with hours · '
            '$withWebsite websites · $withEmail emails',
            style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
          ),
        ),
        const SizedBox(height: 14),
        if (_pastRuns.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text('No scrapes yet.', style: TextStyle(fontSize: 12.5, color: Color(0xFF9CA3AF))),
          )
        else if (widget.isDesktop)
          _buildRunsTable()
        else
          Column(children: _pastRuns.map((r) => _buildRunCard(r)).toList()),
      ]),
    );
  }

  Widget _buildRunsTable() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowColor: const WidgetStatePropertyAll(Color(0xFFF3F4F6)),
        headingTextStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Color(0xFF374151)),
        dataTextStyle: const TextStyle(fontSize: 12, color: Color(0xFF374151)),
        columnSpacing: 24,
        columns: const [
          DataColumn(label: Text('CITY')),
          DataColumn(label: Text('LEVEL')),
          DataColumn(label: Text('TYPES')),
          DataColumn(label: Text('STATUS')),
          DataColumn(label: Text('CELLS')),
          DataColumn(label: Text('CALLS')),
          DataColumn(label: Text('LEADS')),
          DataColumn(label: Text('DATE')),
        ],
        rows: _pastRuns.map((r) {
          final types = _labelsForUiTypes(r['ui_types']).join(', ');
          return DataRow(cells: [
            DataCell(Text(r['city']?.toString() ?? '')),
            DataCell(Text(r['level']?.toString() ?? '')),
            DataCell(Text(types)),
            DataCell(_runStatusChip(r['status']?.toString() ?? '')),
            DataCell(Text(
                '${(r['cells_done'] as num?)?.toInt() ?? 0}/${(r['cells_total'] as num?)?.toInt() ?? 0}')),
            DataCell(Text(
                '${(r['api_calls'] as num?)?.toInt() ?? 0}/${(r['max_calls'] as num?)?.toInt() ?? 0}')),
            DataCell(Text('${(r['leads_new'] as num?)?.toInt() ?? 0}')),
            DataCell(Text(_fmtRunDate(r['created_at']?.toString()))),
          ]);
        }).toList(),
      ),
    );
  }

  Widget _buildRunCard(Map<String, dynamic> r) {
    final types = _labelsForUiTypes(r['ui_types']).join(', ');
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${r['city'] ?? ''} · ${r['level'] ?? ''} · $types',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
          ),
          _runStatusChip(r['status']?.toString() ?? ''),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 12, runSpacing: 4, children: [
          Text('Cells: ${(r['cells_done'] as num?)?.toInt() ?? 0}/${(r['cells_total'] as num?)?.toInt() ?? 0}',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          Text('Calls: ${(r['api_calls'] as num?)?.toInt() ?? 0}/${(r['max_calls'] as num?)?.toInt() ?? 0}',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          Text('Leads: ${(r['leads_new'] as num?)?.toInt() ?? 0}',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          Text(_fmtRunDate(r['created_at']?.toString()), style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
        ]),
      ]),
    );
  }

  Widget _runStatusChip(String status) {
    Color color;
    switch (status) {
      case 'done': color = const Color(0xFF16A34A); break;
      case 'running': color = const Color(0xFF2563EB); break;
      case 'paused_budget': color = const Color(0xFFD97706); break;
      case 'error': color = const Color(0xFFDC2626); break;
      default: color = const Color(0xFF6B7280);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(status, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
    );
  }

  String _fmtRunDate(String? iso) {
    if (iso == null || iso.length < 10) return '';
    try {
      final d = istFromDb(iso);
      return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    } catch (_) {
      return iso.substring(0, 10);
    }
  }
}

// ═════════════════════════════════════════════════════════════════════════
// CHANGE #445 (v2) — "Routes" tab: zones -> ordered route -> REP CHECK-IN
//
// DUMB FRONTEND. Every string below is printed VERBATIM from lead_routes_screen
// / lead_plan_route / my_route / record_visit / lead_visits_report. No client-side
// sorting, distance maths, score banding, or tel:/wa.me/maps URL construction —
// those fields (call_link, wa_link, nav_link, maps_link, km_label, leg_label,
// cum_label, band, verify_label, message, ...) already arrive complete.
// ═════════════════════════════════════════════════════════════════════════

/// C1 status radios — the 8 values record_visit accepts, in mockup order.
const _kVisitStatuses = <(String, String)>[
  ('interested', 'Interested'),
  ('not_interested', 'Not interested'),
  ('revisit', 'Revisit later'),
  ('closed_today', 'Closed today'),
  ('permanently_closed', 'Permanently closed'),
  ('moved', 'Shop has moved'),
  ('not_found', 'Not found here'),
  ('visited', 'Just visited'),
];

class _RoutesTab extends StatefulWidget {
  final bool isDesktop;
  final ValueChanged<int> onZonesChanged;
  final VoidCallback onOpenWarehouseCard;
  const _RoutesTab({
    required this.isDesktop,
    required this.onZonesChanged,
    required this.onOpenWarehouseCard,
  });

  @override
  State<_RoutesTab> createState() => _RoutesTabState();
}

class _RoutesTabState extends State<_RoutesTab> {
  bool _loading = true;
  String? _loadError;

  // ── D: top-level view — 'builder' (admin) or 'myRoute' (rep) ────────────
  String _topMode = 'builder';
  Map<String, dynamic>? _myRoute; // my_route() response, refetched after check-in
  bool _myRouteLoading = false;

  // ── B1: filter bar — the ONLY inputs that drive the count + build ────────
  String _city = 'Raipur';
  Set<String> _classes = {'medical_store'};
  Set<String> _visitFilter = {'fresh'};
  int? _dow; // null = today
  int _startMin = 600; // 10:00

  // ── B2: live count, debounced 300ms on any filter change ─────────────────
  Map<String, dynamic>? _leadCount;
  bool _countLoading = false;
  Timer? _countDebounce;

  // ── B3/B4: the built plan ─────────────────────────────────────────────────
  String? _planId;
  Map<String, dynamic>? _plan;
  bool _buildingPlan = false;
  String? _planError;
  Set<String> _expandedRouteIds = {};

  // ── CHANGE #463: Google Maps, per-route (route_map() has no overview mode) ─
  // Map/List toggle per route, default MAP (B1). Data is fetched lazily the
  // first time a route's map is shown, then cached until the plan reloads.
  final Map<String, bool> _routeMapMode = {}; // routeId -> true=Map, false=List
  final Map<String, Map<String, dynamic>?> _routeMapData = {};
  final Map<String, bool> _routeMapLoading = {};

  // ── CHANGE #485: 'Optimize with Google' — one google-route call per route
  // (<=25 stops), applied via route_apply_google(). Never blocks/crashes the
  // map: any failure per-route just leaves that route as it was.
  bool _googleOptimizing = false;
  String? _googleOptimizeProgress;

  // ── CHANGE #493: 'Optimize from my location' — per-route, keyed by
  // routeId so multiple route cards can be mid-optimize independently.
  final Map<String, bool> _routeOptimizingFromLocation = {};

  // ── CHANGE #494: 'Optimize by warehouse' — the sibling per-route button
  // that re-anchors to the hub, same keying pattern as the location one.
  final Map<String, bool> _routeOptimizingByWarehouse = {};

  // ── C5: past plans, collapsible, lazy-loaded ──────────────────────────────
  bool _pastPlansExpanded = false;
  List<Map<String, dynamic>>? _pastPlans;
  // ── CHANGE #486: realtime status (queued/building/ready) — replaces the
  // old #483 4s poll. Patches the affected card in place, no full reload.
  RealtimeChannel? _planRealtimeChannel;

  // ── D3: Today's Visits (admin, collapsible, lazy-loaded) — unchanged from #446
  bool _visitsExpanded = false;
  bool _visitsLoading = false;
  Map<String, dynamic>? _visitsReport;

  static const List<(String, String)> _classOptions = [
    ('medical_store', 'Pharmacy'),
    ('hospital', 'Hospital'),
    ('clinic', 'Clinic'),
    ('lab', 'Diagnostic Lab'),
    ('chain', 'Chain'),
    ('wholesaler', 'Wholesaler'),
  ];
  static const List<(int?, String)> _dowOptions = [
    (null, 'Today'), (0, 'Sunday'), (1, 'Monday'), (2, 'Tuesday'),
    (3, 'Wednesday'), (4, 'Thursday'), (5, 'Friday'), (6, 'Saturday'),
  ];

  // ── CHANGE #486: no more manual R picker — k is always auto-computed so
  // every route stays under Google's 25-stop cap. Mirrors the backend's
  // route_auto_k(): greatest(1, ceil(leads/25)).
  int get _autoK {
    final leads = (_leadCount?['leads'] as num?)?.toInt() ?? 0;
    return leads > 0 ? max(1, (leads / 25).ceil()) : 1;
  }

  @override
  void initState() {
    super.initState();
    _loadScreen();
    _subscribePlanRealtime();
  }

  @override
  void dispose() {
    _countDebounce?.cancel();
    _planRealtimeChannel?.unsubscribe();
    _planRealtimeChannel = null;
    super.dispose();
  }

  // ── CHANGE #486: subscribe once for the widget's lifetime; INSERT/UPDATE
  // events patch _pastPlans directly from the payload (no refetch, no
  // flicker). Ignored while _pastPlans hasn't been loaded yet — the next
  // expand fetches it fresh via route_plan_list() anyway.
  void _subscribePlanRealtime() {
    try {
      _planRealtimeChannel = Supabase.instance.client
          .channel('route_plans_changes')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'route_plans',
            callback: _onPlanRealtimeChange,
          )
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'route_plans',
            callback: _onPlanRealtimeChange,
          )
          .onPostgresChanges(
            // CHANGE #488: a plan deleted on one device disappears live here too.
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'route_plans',
            callback: _onPlanRealtimeChange,
          )
          .subscribe();
      RenderLog.write('c486_autocluster_realtime', 1);
    } catch (_) {}
  }

  String _planWhenLabel(DateTime createdAt) {
    final ist = toIst(createdAt);
    String p2(int n) => n.toString().padLeft(2, '0');
    return '${p2(ist.day)}/${p2(ist.month)}/${p2(ist.year % 100)} ${p2(ist.hour)}:${p2(ist.minute)}';
  }

  void _onPlanRealtimeChange(PostgresChangePayload payload) {
    if (_pastPlans == null || !mounted) return;
    // CHANGE #488: DELETE payloads carry the row in oldRecord, not newRecord.
    if (payload.eventType == PostgresChangeEvent.delete) {
      final deletedId = payload.oldRecord['id']?.toString();
      if (deletedId == null) return;
      setState(() => _pastPlans =
          _pastPlans!.where((p) => p['plan_id'].toString() != deletedId).toList());
      return;
    }
    final row = payload.newRecord;
    final planId = row['id']?.toString();
    if (planId == null) return;
    if (payload.eventType == PostgresChangeEvent.update) {
      final idx = _pastPlans!.indexWhere((p) => p['plan_id'].toString() == planId);
      if (idx == -1) return;
      setState(() => _pastPlans![idx] = {..._pastPlans![idx], 'status': row['status']});
    } else if (payload.eventType == PostgresChangeEvent.insert) {
      if (_pastPlans!.any((p) => p['plan_id'].toString() == planId)) return;
      final city = row['city']?.toString() ?? '';
      final k = (row['k'] as num?)?.toInt() ?? 0;
      final totalLeads = (row['total_leads'] as num?)?.toInt() ?? 0;
      final classes = ((row['classes'] as List?) ?? []).join(', ');
      final createdAt = DateTime.tryParse(row['created_at']?.toString() ?? '');
      final item = <String, dynamic>{
        'plan_id': planId,
        'city': city,
        'title': '$city · ${k}R · $totalLeads leads',
        'types': classes,
        'when_label': createdAt != null ? _planWhenLabel(createdAt) : '',
        'status': row['status']?.toString() ?? 'queued',
      };
      setState(() => _pastPlans = [item, ..._pastPlans!]);
    }
  }

  Future<void> _loadScreen() async {
    setState(() { _loading = true; _loadError = null; });
    try {
      final myRoute = Map<String, dynamic>.from(
          await Supabase.instance.client.rpc('my_route') as Map);
      if (!mounted) return;
      setState(() {
        _myRoute = myRoute;
        // B2 (#446) — a worker with an assignment today lands on the rep
        // view; an admin with none (or not a worker at all) lands on the
        // route builder.
        _topMode = myRoute['status'] == 'assigned' ? 'myRoute' : 'builder';
        _loading = false;
      });
      final myStops = (myRoute['route'] as List?) ?? [];
      if (_topMode == 'myRoute') {
        RenderLog.write('c445_route_stops', myRoute['stops']);
        RenderLog.write('c445_first_stop', myStops.isNotEmpty
            ? (Map<String, dynamic>.from(myStops.first as Map))['name']?.toString() ?? ''
            : '');
      }
      _fetchLeadCount(); // populates c452_count / c452_suggested_k on first load
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadError = e.toString(); _loading = false; });
    }
  }

  Future<void> _refreshMyRoute() async {
    setState(() => _myRouteLoading = true);
    try {
      final res = await Supabase.instance.client.rpc('my_route');
      final data = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      setState(() { _myRoute = data; _myRouteLoading = false; });
      final stops = (data['route'] as List?) ?? [];
      RenderLog.write('c445_route_stops', data['stops']);
      RenderLog.write('c445_first_stop', stops.isNotEmpty
          ? (Map<String, dynamic>.from(stops.first as Map))['name']?.toString() ?? ''
          : '');
    } catch (_) {
      if (!mounted) return;
      setState(() => _myRouteLoading = false);
    }
  }

  // ── B2: live count — debounced 300ms on any filter change ────────────────
  void _onFilterChanged() {
    _countDebounce?.cancel();
    _countDebounce = Timer(const Duration(milliseconds: 300), _fetchLeadCount);
  }

  Future<void> _fetchLeadCount() async {
    setState(() => _countLoading = true);
    try {
      final res = await Supabase.instance.client.rpc('route_lead_count', params: {
        'p_city': _city,
        'p_classes': _classes.toList(),
        'p_visit': _visitFilter.toList(),
        'p_min_score': 1,
      });
      final data = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      setState(() { _leadCount = data; _countLoading = false; });
      RenderLog.write('c452_count', data['leads']);
      RenderLog.write('c452_suggested_k', data['suggested_k']);
    } catch (e) {
      if (!mounted) return;
      setState(() => _countLoading = false);
    }
  }

  Future<void> _buildPlan(int k) async {
    setState(() { _buildingPlan = true; _planError = null; });
    try {
      final planId = await Supabase.instance.client.rpc('route_plan_build', params: {
        'p_city': _city,
        'p_classes': _classes.toList(),
        'p_visit': _visitFilter.toList(),
        'p_k': k,
        'p_min_score': 1,
        if (_dow != null) 'p_dow': _dow,
        'p_start_min': _startMin,
      });
      await _loadPlan(planId.toString(), isNewBuild: true);
    } catch (e) {
      if (!mounted) return;
      setState(() { _buildingPlan = false; _planError = e.toString(); });
    }
  }

  // Re-called after EVERY write (toggle/rebalance) per the "never patch state
  // in Dart" rule — the plan is always re-fetched, never spliced locally.
  Future<void> _loadPlan(String planId, {bool isNewBuild = false}) async {
    try {
      final res = await Supabase.instance.client.rpc('route_plan_get', params: {'p_plan_id': planId});
      final data = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      final routes = ((data['routes'] as List?) ?? [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      final validIds = routes.map((r) => r['route_id'].toString()).toSet();
      setState(() {
        _planId = planId;
        _plan = data;
        _buildingPlan = false;
        _planError = null;
        _expandedRouteIds = isNewBuild
            ? (routes.isNotEmpty ? {routes.first['route_id'].toString()} : <String>{})
            : _expandedRouteIds.intersection(validIds);
      });
      widget.onZonesChanged(routes.length);
      RenderLog.write('c452_routes', routes.length);
      final summary = Map<String, dynamic>.from(data['summary'] as Map? ?? {});
      RenderLog.write('c452_warning', summary['warning'] != null ? 1 : 0);
      final expanded = routes.where((r) => _expandedRouteIds.contains(r['route_id'].toString()));
      final firstExpandedStops = expanded.isNotEmpty
          ? ((expanded.first['stops'] as List?) ?? []).length
          : 0;
      RenderLog.write('c452_stops', firstExpandedStops);
      // CHANGE #463 — keep each expanded route's map in sync: drop cached map
      // data for routes no longer valid, re-fetch for whichever routes remain
      // expanded (their stop set may have changed via toggle/rebalance).
      _routeMapData.removeWhere((id, _) => !validIds.contains(id));
      _routeMapLoading.removeWhere((id, _) => !validIds.contains(id));
      _routeMapMode.removeWhere((id, _) => !validIds.contains(id));
      for (final id in _expandedRouteIds) {
        _loadRouteMap(id);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _buildingPlan = false; _planError = e.toString(); });
    }
  }

  void _rebuild() {
    setState(() {
      _plan = null;
      _planId = null;
      _planError = null;
      _routeMapData.clear();
      _routeMapLoading.clear();
      _routeMapMode.clear();
    });
  }

  // ── CHANGE #463: per-route Google map — dumb, re-fetched on every plan/ ───
  // route change. route_map() has no plan-wide overview mode (unlike the old
  // #453 OSM map) — one route at a time, matching how a rep actually works.
  Future<void> _loadRouteMap(String routeId) async {
    setState(() => _routeMapLoading[routeId] = true);
    try {
      final res = await Supabase.instance.client
          .rpc('route_map', params: {'p_route_id': routeId});
      final data = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      if (data['error'] != null) {
        setState(() { _routeMapData[routeId] = null; _routeMapLoading[routeId] = false; });
        return;
      }
      setState(() { _routeMapData[routeId] = data; _routeMapLoading[routeId] = false; });
      final legs = (data['legs'] as List?) ?? [];
      RenderLog.write('c463_legs', legs.length.toString());
      RenderLog.write('c463_urlbuilt', '0');
      RenderLog.write('c463_summary', data['summary']?.toString() ?? '');
    } catch (e) {
      if (!mounted) return;
      setState(() => _routeMapLoading[routeId] = false);
    }
  }

  // Calls the google-route edge function for ONE route, then persists the
  // result via route_apply_google(). Boot-safe: any failure (network, quota,
  // malformed response) just returns, leaving the route exactly as it was —
  // never crashes, never partially applies.
  Future<void> _optimizeRouteWithGoogle(
    String routeId,
    Map<String, dynamic> hub,
    List<Map<String, dynamic>> orderedStops,
  ) async {
    try {
      final hubLat = (hub['lat'] as num?)?.toDouble();
      final hubLng = (hub['lng'] as num?)?.toDouble();
      if (hubLat == null || hubLng == null) return;
      if (orderedStops.isEmpty || orderedStops.length > 25) return;

      final stopsPayload = <Map<String, dynamic>>[];
      for (final s in orderedStops) {
        final leadId = s['lead_id'];
        final lat = (s['lat'] as num?)?.toDouble();
        final lng = (s['lng'] as num?)?.toDouble();
        if (leadId == null || lat == null || lng == null) return;
        stopsPayload.add({'lead_id': leadId, 'lat': lat, 'lng': lng});
      }

      final res = await Supabase.instance.client.functions.invoke('google-route', body: {
        'hub': {'lat': hubLat, 'lng': hubLng},
        'return_to_hub': true,
        'stops': stopsPayload,
      });
      final data = res.data;
      if (data is! Map || data['error'] != null) return;
      final optimisedIds = (data['optimised_lead_ids'] as List?)
          ?.map((e) => (e as num).toInt())
          .toList();
      if (optimisedIds == null || optimisedIds.isEmpty) return;
      final polyline = data['encoded_polyline']?.toString();

      await Supabase.instance.client.rpc('route_apply_google', params: {
        'p_route_id': routeId,
        'p_optimised_lead_ids': optimisedIds,
        'p_polyline': polyline,
      });
    } catch (_) {
      // Google/network failure -> keep whatever route already exists.
    }
  }

  // ── CHANGE #493: 'Optimize from my location' — same google-route call as
  // #485 but with the driver's live GPS as origin (instead of the hub), so
  // the nearest stop becomes #1. Backend already supports this: google-route
  // takes an optional 'origin', and route_apply_google_from() persists it
  // exactly like route_apply_google() (seq + polyline), just also stamping
  // the origin lat/lng. Unlike _optimizeRouteWithGoogle (silent, batch-safe),
  // this is a single user-initiated tap, so failures surface via SnackBar.
  Future<void> _optimizeRouteFromMyLocation(String routeId) async {
    if (_routeOptimizingFromLocation[routeId] == true) return;
    setState(() => _routeOptimizingFromLocation[routeId] = true);
    try {
      // a. Live GPS — same dart:html geolocation pattern as CashPaymentSheet /
      // the warehouse GPS capture / the rep check-in card (C445).
      double gpsLat, gpsLng;
      try {
        final completer = Completer<html.Geoposition>();
        html.window.navigator.geolocation
            .getCurrentPosition(enableHighAccuracy: true, timeout: const Duration(seconds: 20))
            .then((pos) { if (!completer.isCompleted) completer.complete(pos); })
            .catchError((e) { if (!completer.isCompleted) completer.completeError(e); });
        final pos = await completer.future.timeout(
          const Duration(seconds: 25),
          onTimeout: () => throw TimeoutException('Location timed out'),
        );
        final lat = pos.coords?.latitude?.toDouble();
        final lng = pos.coords?.longitude?.toDouble();
        if (lat == null || lng == null) throw Exception('No coordinates returned');
        gpsLat = lat;
        gpsLng = lng;
      } catch (e) {
        if (!mounted) return;
        final msg = e.toString().toLowerCase();
        final denied = msg.contains('denied') || msg.contains('permission');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
            denied
                ? 'Location permission needed to optimize from your position'
                : "Couldn't get a GPS fix. Move outdoors and retry.")));
        return;
      }

      // b. This route's stops + hub — reuse the already-loaded route_map()
      // data (the expanded card fetched it to draw the map); refetch if
      // somehow missing.
      var mapData = _routeMapData[routeId];
      if (mapData == null) {
        final res = await Supabase.instance.client
            .rpc('route_map', params: {'p_route_id': routeId});
        mapData = Map<String, dynamic>.from(res as Map);
      }
      final hub = mapData['hub'] as Map?;
      final stops = ((mapData['stops'] as List?) ?? [])
          .map((s) => Map<String, dynamic>.from(s as Map))
          .toList();
      final hubLat = (hub?['lat'] as num?)?.toDouble();
      final hubLng = (hub?['lng'] as num?)?.toDouble();
      if (hubLat == null || hubLng == null || stops.isEmpty || stops.length > 25) {
        throw Exception('Route has no hub/stops to optimize.');
      }
      final stopsPayload = <Map<String, dynamic>>[];
      for (final s in stops) {
        final leadId = s['lead_id'];
        final sLat = (s['lat'] as num?)?.toDouble();
        final sLng = (s['lng'] as num?)?.toDouble();
        if (leadId == null || sLat == null || sLng == null) {
          throw Exception('Route has a stop missing coordinates.');
        }
        stopsPayload.add({'lead_id': leadId, 'lat': sLat, 'lng': sLng});
      }

      // c. google-route with hub + origin(GPS) + this route's stops.
      final res = await Supabase.instance.client.functions.invoke('google-route', body: {
        'hub': {'lat': hubLat, 'lng': hubLng},
        'origin': {'lat': gpsLat, 'lng': gpsLng},
        'stops': stopsPayload,
      });
      final data = res.data;
      if (data is! Map || data['error'] != null) {
        throw Exception(
            data is Map ? (data['error']?.toString() ?? 'google-route failed') : 'google-route failed');
      }
      final optimisedIds = (data['optimised_lead_ids'] as List?)
          ?.map((e) => (e as num).toInt())
          .toList();
      if (optimisedIds == null || optimisedIds.isEmpty) {
        throw Exception('Google returned no route.');
      }
      final polyline = data['encoded_polyline']?.toString();

      // d. persist via route_apply_google_from() — keeps the '✓ Google
      // optimized' badge, just re-anchored to the driver instead of the hub.
      await Supabase.instance.client.rpc('route_apply_google_from', params: {
        'p_route_id': routeId,
        'p_optimised_lead_ids': optimisedIds,
        'p_polyline': polyline,
        'p_origin_lat': gpsLat,
        'p_origin_lng': gpsLng,
      });

      // e. re-fetch route_map() + the plan so the new order/polyline show.
      // _loadPlan() unconditionally re-fetches every still-expanded route's
      // map (see CHANGE #463 note above), so this route's map is rebuilt too.
      final planId = _planId;
      if (planId != null) {
        await _loadPlan(planId);
      } else {
        await _loadRouteMap(routeId);
      }
      RenderLog.write('c493_optimize_from_location', 1);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _routeOptimizingFromLocation[routeId] = false);
    }
  }

  // ── CHANGE #494: 'Optimize by warehouse' — re-anchors this one route back
  // to the hub, undoing a previous "by location" optimize. Reuses
  // _optimizeRouteWithGoogle() verbatim — the exact same google-route
  // (no origin) + route_apply_google() pair the combined "optimize all"
  // button already makes per route — just for a single routeId, with its
  // own spinner + map/plan refresh around it.
  Future<void> _optimizeRouteByWarehouse(String routeId) async {
    if (_routeOptimizingByWarehouse[routeId] == true) return;
    setState(() => _routeOptimizingByWarehouse[routeId] = true);
    try {
      var mapData = _routeMapData[routeId];
      if (mapData == null) {
        final res = await Supabase.instance.client
            .rpc('route_map', params: {'p_route_id': routeId});
        mapData = Map<String, dynamic>.from(res as Map);
      }
      final hub = mapData['hub'] as Map?;
      final stops = ((mapData['stops'] as List?) ?? [])
          .map((s) => Map<String, dynamic>.from(s as Map))
          .toList();
      if (hub == null || stops.isEmpty || stops.length > 25) {
        throw Exception('Route has no hub/stops to optimize.');
      }

      await _optimizeRouteWithGoogle(routeId, Map<String, dynamic>.from(hub), stops);

      final planId = _planId;
      if (planId != null) {
        await _loadPlan(planId);
      } else {
        await _loadRouteMap(routeId);
      }
      RenderLog.write('c494_optimize_by_warehouse', 1);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _routeOptimizingByWarehouse[routeId] = false);
    }
  }

  // 'Optimize with Google' button handler — loops the plan's routes, skips
  // any route over Google's 25-stop cap, gently rate-limited (200ms/call) to
  // stay under Google's per-minute quota.
  // CHANGE #486 (3C): also skips any route with google_optimized already
  // true — each route is sent to Google exactly once, ever, so re-tapping
  // this button doesn't re-call Google for routes already done.
  Future<void> _optimizeAllRoutesWithGoogle() async {
    final plan = _plan;
    final planId = _planId;
    if (plan == null || planId == null || _googleOptimizing) return;
    final routes = ((plan['routes'] as List?) ?? [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    if (routes.isEmpty) return;

    // CHANGE #489: large plans fire one google-route call per un-optimized
    // route (~1-3 min for 90 routes) — confirm before kicking that off.
    final toOptimize = routes.where((r) => r['google_optimized'] != true).length;
    if (toOptimize > 50) {
      final go = await showDialog<bool>(
        context: context,
        builder: (dCtx) => AlertDialog(
          title: const Text('Optimize routes?'),
          content: Text('Optimize $toOptimize routes? ~$toOptimize lookups, this may take a few minutes.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1E3A8A)),
              onPressed: () => Navigator.pop(dCtx, true),
              child: const Text('Optimize'),
            ),
          ],
        ),
      );
      if (go != true) return;
    }

    setState(() {
      _googleOptimizing = true;
      _googleOptimizeProgress = 'Optimizing 0/${routes.length}...';
    });

    for (var i = 0; i < routes.length; i++) {
      final r = routes[i];
      final routeId = r['route_id']?.toString();
      final nStops = (r['n_stops'] as num?)?.toInt() ?? 0;
      final alreadyOptimized = r['google_optimized'] == true;
      if (routeId != null && !alreadyOptimized && nStops > 0 && nStops <= 25) {
        try {
          final mapRes = await Supabase.instance.client
              .rpc('route_map', params: {'p_route_id': routeId});
          final mapData = Map<String, dynamic>.from(mapRes as Map);
          final hub = mapData['hub'] as Map?;
          final stops = ((mapData['stops'] as List?) ?? [])
              .map((s) => Map<String, dynamic>.from(s as Map))
              .toList();
          if (hub != null && stops.isNotEmpty && stops.length <= 25) {
            await _optimizeRouteWithGoogle(routeId, Map<String, dynamic>.from(hub), stops);
          }
        } catch (_) {
          // one route failing must never stop the loop
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }
      if (!mounted) return;
      setState(() => _googleOptimizeProgress = 'Optimizing ${i + 1}/${routes.length}...');
    }

    if (!mounted) return;
    setState(() {
      _googleOptimizing = false;
      _googleOptimizeProgress = null;
      // CHANGE #487: any route's cached map (fetched before this run, then
      // collapsed) may now be stale — its road_polyline was null at fetch
      // time. Clearing here forces the NEXT expand of any route to re-fetch
      // route_map(), instead of the expand handler's containsKey() check
      // silently reusing pre-optimization data forever.
      _routeMapData.clear();
      _routeMapLoading.clear();
    });
    RenderLog.write('c485_google_routes_optimize', 1);
    await _loadPlan(planId); // re-fetch; picks up Google's order + road_polyline
  }

  // B4 DETAIL: tapping a numbered pin -> title/subtitle/leg/cum/open + phone/
  // Navigate. Navigate/phone links are ALREADY built by route_map() — never
  // construct a maps URL or tel: link here.
  void _openMapStopSheet(Map<String, dynamic> stop) {
    final phone = stop['phone']?.toString();
    final address = stop['address']?.toString();
    final openLabel = stop['open_label']?.toString();
    final navigateUrl = stop['navigate_url']?.toString();
    final navigateLabel = stop['navigate_label']?.toString() ?? 'Navigate';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(stop['title']?.toString() ?? '',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            if (stop['subtitle'] != null) ...[
              const SizedBox(height: 2),
              Text(stop['subtitle'].toString(),
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 4, children: [
              if (stop['leg_label'] != null)
                Text(stop['leg_label'].toString(), style: const TextStyle(fontSize: 12.5, color: Color(0xFF374151))),
              if (stop['cum_label'] != null)
                Text(stop['cum_label'].toString(), style: const TextStyle(fontSize: 12.5, color: Color(0xFF374151))),
            ]),
            if (openLabel != null) ...[
              const SizedBox(height: 4),
              Text(openLabel,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFFDC2626))),
            ],
            if (address != null && address.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(address, style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
            ],
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (phone != null && phone.isNotEmpty)
                _stopActionBtn(Icons.call, 'Call', () => launchUrl(Uri.parse('tel:$phone'))),
              if (navigateUrl != null && navigateUrl.isNotEmpty)
                _stopActionBtn(Icons.navigation_outlined, navigateLabel,
                    () => launchUrl(Uri.parse(navigateUrl), mode: LaunchMode.externalApplication)),
              _stopActionBtn(Icons.check_circle, 'Check in', () {
                Navigator.of(sheetCtx).pop();
                _openCheckIn(
                  {'lead_id': stop['lead_id'], 'name': stop['name'] ?? stop['title']},
                  onRefresh: () {
                    if (_planId != null) _loadPlan(_planId!);
                  },
                );
              }, filled: true),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _toggleRouteIncluded(String routeId, bool included) async {
    try {
      await Supabase.instance.client.rpc('route_plan_toggle_route', params: {
        'p_route_id': routeId, 'p_included': included,
      });
      if (_planId != null) await _loadPlan(_planId!);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _toggleStopIncluded(String stopId, bool included) async {
    try {
      await Supabase.instance.client.rpc('route_plan_toggle_stop', params: {
        'p_stop_id': stopId, 'p_included': included,
      });
      if (_planId != null) await _loadPlan(_planId!);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  // ── C3: Rebalance — unchecked leads move into the remaining routes ───────
  Future<void> _rebalance() async {
    final planId = _planId;
    if (planId == null) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Rebalance routes?'),
        content: const Text('Unchecked leads will be moved into the remaining '
            'routes and every route re-optimised. Continue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Rebalance'),
          ),
        ],
      ),
    );
    if (go != true) return;
    setState(() => _buildingPlan = true);
    try {
      final res = await Supabase.instance.client
          .rpc('route_plan_rebalance', params: {'p_plan_id': planId});
      final data = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(data['message']?.toString() ?? 'Rebalanced.'),
        backgroundColor: const Color(0xFF1B7A43),
      ));
      await _loadPlan(planId); // re-call route_plan_get; never patch in Dart
    } catch (e) {
      if (!mounted) return;
      setState(() => _buildingPlan = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  // ── C4: Assign a route to a worker ────────────────────────────────────────
  Future<void> _openAssignRouteSheet(Map<String, dynamic> route) async {
    List<Map<String, dynamic>> workers;
    try {
      final res = await Supabase.instance.client.rpc('lead_workers_list');
      workers = ((res as List?) ?? []).map((w) => Map<String, dynamic>.from(w as Map)).toList();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      return;
    }
    if (!mounted) return;
    final assigned = await showDialog<bool>(
      context: context,
      builder: (_) => _AssignRouteDialog(route: route, initialWorkers: workers),
    );
    if (assigned == true && _planId != null) await _loadPlan(_planId!);
  }

  // ── C5: Past plans ─────────────────────────────────────────────────────────
  Future<void> _togglePastPlans() async {
    final expanding = !_pastPlansExpanded;
    setState(() => _pastPlansExpanded = expanding);
    if (expanding && _pastPlans == null) {
      try {
        final res = await Supabase.instance.client.rpc('route_plan_list', params: {'p_limit': 10});
        final list = ((res as List?) ?? []).map((p) => Map<String, dynamic>.from(p as Map)).toList();
        if (!mounted) return;
        setState(() => _pastPlans = list);
        _fetchOptStatusFor(list);
      } catch (_) {}
    }
  }

  // ── CHANGE #488: per-plan optimization badge — plan_google_status() isn't
  // returned by route_plan_list(), so fetch it per-plan once the list loads.
  // Best-effort: a failed lookup just leaves that card without a badge.
  Future<void> _fetchOptStatusFor(List<Map<String, dynamic>> plans) async {
    for (final p in plans) {
      final planId = p['plan_id']?.toString();
      if (planId == null) continue;
      try {
        final res = await Supabase.instance.client
            .rpc('plan_google_status', params: {'p_plan': planId});
        final status = Map<String, dynamic>.from(res as Map);
        if (!mounted) return;
        final idx = (_pastPlans ?? []).indexWhere((x) => x['plan_id'].toString() == planId);
        if (idx == -1) continue;
        setState(() => _pastPlans![idx] = {..._pastPlans![idx], 'opt_status': status});
      } catch (_) {
        // no badge for this card — never blocks the rest of the list
      }
    }
  }

  // ── CHANGE #488: delete a past plan — always confirm first, since this is
  // permanent (cascades to its routes + stops server-side).
  Future<void> _deletePlan(String planId, String title) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Delete this plan?'),
        content: Text('$title\n\nThis removes all its routes and stops permanently.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      final res = await Supabase.instance.client
          .rpc('delete_route_plan', params: {'p_plan': planId});
      if (!mounted) return;
      final map = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (map['deleted'] != true) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Couldn't delete, try again")));
        return;
      }
      RenderLog.write('c488c_delete_wired', planId);
      // Remove it locally right away for snappy UX — the realtime DELETE
      // handler above will also fire and no-op harmlessly on a second pass.
      setState(() {
        _pastPlans = (_pastPlans ?? []).where((p) => p['plan_id'].toString() != planId).toList();
        if (_planId == planId) {
          _plan = null;
          _planId = null;
          _routeMapData.clear();
          _routeMapLoading.clear();
          _routeMapMode.clear();
        }
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't delete, try again")));
    }
  }

  // ── CHANGE #488 (2D): bulk cleanup, nice-to-have — always confirm first.
  Future<void> _clearOldPlans() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Clear old plans?'),
        content: const Text('Delete all plans older than 7 days? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (go != true) return;
    try {
      final res = await Supabase.instance.client
          .rpc('delete_old_route_plans', params: {'p_days': 7});
      final data = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      final deleted = (data['deleted_plans'] as num?)?.toInt() ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted $deleted old plan(s).')));
      // Realtime DELETE events land per-row already; refetch too so the
      // count is right even if a realtime event is missed.
      final list = await Supabase.instance.client.rpc('route_plan_list', params: {'p_limit': 10});
      if (!mounted) return;
      final freshList = ((list as List?) ?? []).map((p) => Map<String, dynamic>.from(p as Map)).toList();
      setState(() => _pastPlans = freshList);
      _fetchOptStatusFor(freshList);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't clear old plans, try again")));
    }
  }

  // ── B5 (stop-card action): Convert to customer — unchanged from #446 ─────
  Future<void> _convert(Map<String, dynamic> stop, {required VoidCallback onRefresh}) async {
    final nameCtrl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Add as customer'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Owner name (Google doesn\'t have it)',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (go != true) { nameCtrl.dispose(); return; }
    final ownerName = nameCtrl.text.trim();
    nameCtrl.dispose();
    if (!mounted) return;
    try {
      final res = await Supabase.instance.client.rpc('lead_convert_to_customer', params: {
        'p_lead_id': stop['lead_id'],
        if (ownerName.isNotEmpty) 'p_owner_name': ownerName,
      });
      final data = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      if (data['ok'] == true) {
        final code = data['customer_code']?.toString() ?? '';
        final note = data['note']?.toString() ?? '';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Added as customer $code. $note'),
          backgroundColor: const Color(0xFF1B7A43),
        ));
        onRefresh(); // never splice the list in Dart — re-call the route RPC
      } else {
        final err = data['error']?.toString() ?? 'Unknown error';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err == 'already_a_customer' ? 'Already a customer.' : err)),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  // ── C: Check-in bottom sheet ──────────────────────────────────────────────
  void _openCheckIn(Map<String, dynamic> stop, {String? assignmentId, required VoidCallback onRefresh}) {
    RenderLog.write('c445_checkin_wired', 1);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _CheckInSheet(
        stop: stop,
        assignmentId: assignmentId,
        onDone: onRefresh,
      ),
    );
  }

  // ── D3: Today's Visits ────────────────────────────────────────────────────
  Future<void> _toggleVisitsReport() async {
    final expanding = !_visitsExpanded;
    setState(() => _visitsExpanded = expanding);
    if (expanding && _visitsReport == null) {
      setState(() => _visitsLoading = true);
      try {
        final res = await Supabase.instance.client.rpc('lead_visits_report');
        final data = Map<String, dynamic>.from(res as Map);
        if (!mounted) return;
        setState(() { _visitsReport = data; _visitsLoading = false; });
      } catch (e) {
        if (!mounted) return;
        setState(() => _visitsLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.only(top: 80),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)),
      );
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off_rounded, size: 40, color: Color(0xFF6B7280)),
            const SizedBox(height: 12),
            Text('Failed to load: $_loadError',
                style: const TextStyle(fontSize: 13, color: Color(0xFFDC2626)),
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _loadScreen, child: const Text('Retry')),
          ]),
        ),
      );
    }
    final pad = widget.isDesktop ? 28.0 : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 20, pad, 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildTopModeToggle(),
        const SizedBox(height: 14),
        if (_topMode == 'myRoute') _buildMyRouteView() else _buildBuilder(),
      ]),
    );
  }

  Widget _buildTopModeToggle() {
    return Row(children: [
      Expanded(
        child: _segBtn('My route', _topMode == 'myRoute', () {
          setState(() => _topMode = 'myRoute');
          if (_myRoute == null) _refreshMyRoute();
        }),
      ),
      const SizedBox(width: 8),
      Expanded(child: _segBtn('Builder', _topMode == 'builder', () => setState(() => _topMode = 'builder'))),
    ]);
  }

  // ── D1: Rep view — "My route today" ──────────────────────────────────────

  Widget _buildMyRouteView() {
    if (_myRouteLoading) {
      return const Padding(
        padding: EdgeInsets.only(top: 40),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)),
      );
    }
    final route = _myRoute;
    if (route == null || route['status'] == 'none') {
      return Center(
        child: Padding(
          padding: const EdgeInsets.only(top: 40),
          child: Text(route?['empty_label']?.toString() ?? 'No route assigned to you today.',
              style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
        ),
      );
    }
    final assignmentId = route['assignment_id']?.toString();
    final stops = (route['route'] as List?)
            ?.map((s) => Map<String, dynamic>.from(s as Map))
            .toList() ??
        [];
    final mapsLinks = (route['maps_links'] as List?)
            ?.map((m) => Map<String, dynamic>.from(m as Map))
            .toList() ??
        [];
    final emptyLabel = route['empty_label']?.toString();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (route['progress_label'] != null)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(route['progress_label'].toString(),
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF1E40AF))),
        ),
      const SizedBox(height: 12),
      _buildRouteSummaryBar(route, mapsLinks),
      const SizedBox(height: 14),
      if (emptyLabel != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(emptyLabel,
                style: const TextStyle(fontSize: 13.5, color: Color(0xFF6B7280)),
                textAlign: TextAlign.center),
          ),
        )
      else
        ...stops.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _stopCard(s, assignmentId: assignmentId, onRefresh: _refreshMyRoute),
            )),
    ]);
  }

  // ── CHANGE #452 — Route Builder: filter bar -> live count -> K picker ────
  // -> plan (routes + stops, check/uncheck) -> rebalance / assign. Replaces
  // the #445 zone list. The rep check-in flow (#446) is untouched below.

  Widget _buildBuilder() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildFilterBar(),
      const SizedBox(height: 12),
      _buildVisitsReportPanel(),
      const SizedBox(height: 12),
      _buildPastPlansPanel(),
      const SizedBox(height: 12),
      if (_planError != null) ...[
        Text(_planError!, style: const TextStyle(fontSize: 12.5, color: Color(0xFFDC2626))),
        const SizedBox(height: 10),
      ],
      if (_buildingPlan)
        const Padding(
          padding: EdgeInsets.only(top: 24),
          child: Center(child: Column(children: [
            CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
            SizedBox(height: 10),
            Text('Building routes — this can take a few seconds for 1,000+ leads…',
                style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
          ])),
        )
      else if (_plan != null)
        _buildPlanView(),
    ]);
  }

  // ── B1: filter bar — the ONLY inputs ──────────────────────────────────────

  Widget _buildFilterBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('🏠', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Build routes',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          ),
          TextButton(onPressed: widget.onOpenWarehouseCard, child: const Text('Warehouse')),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 12, children: [
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<String>(
              initialValue: _city,
              decoration: const InputDecoration(labelText: 'City', border: OutlineInputBorder(), isDense: true),
              items: const [DropdownMenuItem(value: 'Raipur', child: Text('Raipur'))],
              onChanged: (v) {
                if (v == null) return;
                setState(() => _city = v);
                _onFilterChanged();
              },
            ),
          ),
          SizedBox(
            width: 200,
            child: DropdownButtonFormField<int?>(
              initialValue: _dow,
              decoration: const InputDecoration(labelText: 'Day', border: OutlineInputBorder(), isDense: true),
              items: _dowOptions
                  .map((o) => DropdownMenuItem(value: o.$1, child: Text(o.$2)))
                  .toList(),
              onChanged: (v) {
                setState(() => _dow = v);
                _onFilterChanged();
              },
            ),
          ),
          InkWell(
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: TimeOfDay(hour: _startMin ~/ 60, minute: _startMin % 60),
              );
              // Marshals the picked wall-clock time into minutes-since-midnight
              // for p_start_min — input encoding, not business math.
              if (picked != null) {
                setState(() => _startMin = picked.hour * 60 + picked.minute);
                _onFilterChanged();
              }
            },
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Start time', border: OutlineInputBorder(), isDense: true),
              child: Text(TimeOfDay(hour: _startMin ~/ 60, minute: _startMin % 60).format(context)),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        const Text('Store type',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: _classOptions.map((o) {
          final sel = _classes.contains(o.$1);
          return FilterChip(
            label: Text(o.$2, style: const TextStyle(fontSize: 11.5)),
            selected: sel,
            onSelected: (v) {
              setState(() {
                if (v) { _classes.add(o.$1); } else { _classes.remove(o.$1); }
              });
              _onFilterChanged();
            },
            selectedColor: const Color(0xFFDCFCE7),
            checkmarkColor: const Color(0xFF1B7A43),
            backgroundColor: const Color(0xFFF3F4F6),
            side: BorderSide(color: sel ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
            labelStyle: TextStyle(color: sel ? const Color(0xFF1B7A43) : const Color(0xFF374151)),
          );
        }).toList()),
        const SizedBox(height: 12),
        const Text('Visit filter',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [('fresh', 'Fresh'), ('visited', 'Visited')].map((o) {
          final sel = _visitFilter.contains(o.$1);
          return FilterChip(
            label: Text(o.$2, style: const TextStyle(fontSize: 11.5)),
            selected: sel,
            onSelected: (v) {
              setState(() {
                if (v) { _visitFilter.add(o.$1); } else { _visitFilter.remove(o.$1); }
              });
              _onFilterChanged();
            },
            selectedColor: const Color(0xFFDCFCE7),
            checkmarkColor: const Color(0xFF1B7A43),
            backgroundColor: const Color(0xFFF3F4F6),
            side: BorderSide(color: sel ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
            labelStyle: TextStyle(color: sel ? const Color(0xFF1B7A43) : const Color(0xFF374151)),
          );
        }).toList()),
        const SizedBox(height: 14),
        // ── B2: live count — verbatim ────────────────────────────────────
        Row(children: [
          if (_countLoading)
            const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)))
          else
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_leadCount?['label']?.toString() ?? '—',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                if (_leadCount?['hours_note'] != null)
                  Text(_leadCount!['hours_note'].toString(),
                      style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
                // CHANGE #486: no more R picker — every route is auto-sized to
                // stay under Google's 25-stop cap, shown read-only here.
                if ((_leadCount?['leads'] as num?)?.toInt() != null && (_leadCount!['leads'] as num).toInt() > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_leadCount!['leads']} leads → $_autoK routes (~25 stops each)',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1B7A43)),
                  ),
                ],
              ]),
            ),
        ]),
        const SizedBox(height: 12),
        SizedBox(
          width: widget.isDesktop ? 200 : double.infinity,
          child: ElevatedButton.icon(
            onPressed: (_leadCount == null || (_leadCount!['leads'] as num? ?? 0) == 0)
                ? null
                : () => _buildPlan(_autoK),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              foregroundColor: Colors.white,
              disabledBackgroundColor: const Color(0xFFD1D5DB),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            icon: const Icon(Icons.route, size: 17),
            label: const Text('Add', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }

  // ── C5: Past plans ─────────────────────────────────────────────────────────

  Widget _buildPastPlansPanel() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(children: [
        InkWell(
          onTap: _togglePastPlans,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              const Icon(Icons.history, size: 18, color: Color(0xFF6B7280)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Past plans',
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              ),
              // CHANGE #488 (2D): bulk cleanup, subtle — only worth showing
              // once there's actually a list to clean up.
              if (_pastPlansExpanded && (_pastPlans?.isNotEmpty ?? false))
                TextButton(
                  onPressed: _clearOldPlans,
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF9CA3AF),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('Clear old plans', style: TextStyle(fontSize: 11.5)),
                ),
              Icon(_pastPlansExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 20, color: const Color(0xFF6B7280)),
            ]),
          ),
        ),
        if (_pastPlansExpanded) ...[
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          if (_pastPlans == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)),
            )
          else if (_pastPlans!.isEmpty)
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text('No past plans.', style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
            )
          else
            ..._pastPlans!.map((p) {
              final planId = p['plan_id'].toString();
              final optStatus = p['opt_status'] as Map?;
              final total = (optStatus?['total_routes'] as num?)?.toInt() ?? 0;
              final optimized = (optStatus?['optimized_routes'] as num?)?.toInt() ?? 0;
              return InkWell(
                onTap: () => _loadPlan(planId, isNewBuild: true),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                          Text(p['title']?.toString() ?? '',
                              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                          if (optStatus != null) _optStatusBadge(total: total, optimized: optimized),
                        ]),
                        const SizedBox(height: 2),
                        Text(
                            [p['types'], p['when_label'], p['status']]
                                .where((v) => v != null && v.toString().isNotEmpty)
                                .join(' · '),
                            style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
                      ]),
                    ),
                    // CHANGE #488 (2A): delete, always confirm before it fires.
                    IconButton(
                      onPressed: () => _deletePlan(planId, p['title']?.toString() ?? 'this plan'),
                      icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFF9CA3AF)),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      tooltip: 'Delete plan',
                    ),
                  ]),
                ),
              );
            }),
        ],
      ]),
    );
  }

  // ── B4: plan summary + C1: route cards ───────────────────────────────────

  Widget _buildPlanView() {
    final plan = _plan!;
    final header = Map<String, dynamic>.from(plan['header'] as Map? ?? {});
    final summary = Map<String, dynamic>.from(plan['summary'] as Map? ?? {});
    final routes = ((plan['routes'] as List?) ?? [])
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final warning = summary['warning']?.toString();
    // CHANGE #488: badge + button label both derive from the already-loaded
    // routes list — no extra round trip for the currently-open plan.
    final totalRoutes = routes.length;
    final optimizedRoutes = routes.where((r) => r['google_optimized'] == true).length;
    RenderLog.write('c452_rebalance_wired', 1); // Rebalance button is built below
    RenderLog.write('c485_google_optimize_wired', 1); // Optimize-with-Google button is built below
    RenderLog.write('c488_badges_and_delete', 1); // optimization badges + plan delete are wired
    RenderLog.write('c489_optimize_left', totalRoutes - optimizedRoutes); // any plan size/class mix

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(header['title']?.toString() ?? '',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            _optStatusBadge(total: totalRoutes, optimized: optimizedRoutes),
          ]),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 4, children: [
            if (header['types_label'] != null)
              Text(header['types_label'].toString(),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            if (header['filter_label'] != null)
              Text(header['filter_label'].toString(),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            if (header['day_label'] != null)
              Text(header['day_label'].toString(),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          ]),
          if (header['start_label'] != null) ...[
            const SizedBox(height: 4),
            Text(header['start_label'].toString(),
                style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
          ],
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 4, children: [
            Text('${summary['routes'] ?? 0} routes',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const Text('·', style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            Text('${summary['stops'] ?? 0} stops',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const Text('·', style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            Text(summary['total_km_label']?.toString() ?? '',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          ]),
          if (warning != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3C7),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(warning,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF92400E))),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(
              onPressed: _rebalance,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1B7A43),
                side: const BorderSide(color: Color(0xFF1B7A43)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.balance, size: 15),
              label: const Text('Rebalance', style: TextStyle(fontSize: 12.5)),
            ),
            OutlinedButton.icon(
              onPressed: _rebuild,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF6B7280),
                side: const BorderSide(color: Color(0xFFD1D5DB)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.refresh, size: 15),
              label: const Text('Rebuild', style: TextStyle(fontSize: 12.5)),
            ),
            // CHANGE #489: shown for any plan size/class mix — Google
            // failure never crashes, it just leaves each route as it was.
            if (totalRoutes > 0)
              OutlinedButton.icon(
                onPressed: _googleOptimizing ? null : _optimizeAllRoutesWithGoogle,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1E3A8A),
                  side: const BorderSide(color: Color(0xFF1E3A8A)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: _googleOptimizing
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1E3A8A)),
                      )
                    : const Icon(Icons.route, size: 15),
                label: Text(
                  _googleOptimizing
                      ? (_googleOptimizeProgress ?? 'Optimizing...')
                      : _optimizeButtonLabel(total: totalRoutes, optimized: optimizedRoutes),
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
          ]),
        ]),
      ),
      const SizedBox(height: 12),
      ...routes.map((r) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _routeCard(r),
          )),
    ]);
  }

  Widget _routeCard(Map<String, dynamic> r) {
    final routeId = r['route_id'].toString();
    final expanded = _expandedRouteIds.contains(routeId);
    final included = r['included'] == true;
    final fitsDay = r['fits_day'] == true;
    final dayWarning = r['day_warning']?.toString();
    final closedLabel = r['closed_label']?.toString();
    final assigned = r['assigned'] == true;
    final worker = r['worker']?.toString();
    final stops = ((r['stops'] as List?) ?? [])
        .map((s) => Map<String, dynamic>.from(s as Map))
        .toList();

    return Container(
      decoration: BoxDecoration(
        color: fitsDay ? Colors.white : const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: fitsDay ? const Color(0xFFE5E7EB) : const Color(0xFFFDE68A)),
      ),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Checkbox(
              value: included,
              onChanged: assigned ? null : (v) => _toggleRouteIncluded(routeId, v == true),
              activeColor: const Color(0xFF1B7A43),
            ),
            Expanded(
              child: InkWell(
                onTap: () {
                  setState(() {
                    if (expanded) { _expandedRouteIds.remove(routeId); } else { _expandedRouteIds.add(routeId); }
                  });
                  // CHANGE #463 B1/B2: opening a route -> call route_map(routeId).
                  // Default mode is Map, so fetch immediately unless cached.
                  if (!expanded && !_routeMapData.containsKey(routeId)) {
                    _loadRouteMap(routeId);
                  }
                },
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(
                      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                        Flexible(
                          child: Text(r['title']?.toString() ?? '',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                        ),
                        // CHANGE #488 (1B): route-level Google-optimized badge.
                        if (r['google_optimized'] == true) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                            decoration: BoxDecoration(
                                color: const Color(0xFFD1FAE5), borderRadius: BorderRadius.circular(4)),
                            child: const Text('✓G',
                                style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w800, color: Color(0xFF065F46))),
                          ),
                        ],
                      ]),
                    ),
                    if (assigned)
                      _infoChip(worker ?? 'Assigned', const Color(0xFFEFF6FF), const Color(0xFF1E40AF))
                    else
                      TextButton.icon(
                        onPressed: () => _openAssignRouteSheet(r),
                        icon: const Icon(Icons.person_add_alt_1, size: 14),
                        label: const Text('Assign', style: TextStyle(fontSize: 11.5)),
                        style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF1B7A43),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                      ),
                    Icon(expanded ? Icons.expand_less : Icons.expand_more,
                        size: 20, color: const Color(0xFF6B7280)),
                  ]),
                  const SizedBox(height: 2),
                  Text(r['subtitle']?.toString() ?? '',
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
                  if (dayWarning != null) ...[
                    const SizedBox(height: 4),
                    Text('⚠ $dayWarning',
                        style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFFD97706))),
                  ],
                  if (closedLabel != null) ...[
                    const SizedBox(height: 2),
                    Text(closedLabel, style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
                  ],
                ]),
              ),
            ),
          ]),
        ),
        if (expanded) ...[
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.all(10),
            child: _buildRouteDetail(routeId, stops),
          ),
        ],
      ]),
    );
  }

  // ── CHANGE #463 B1: Map/List toggle at the top of a route's detail view.
  // Default = MAP. The existing stop LIST (B builderStopRow) stays, unchanged.
  Widget _buildRouteDetail(String routeId, List<Map<String, dynamic>> stops) {
    final isMap = _routeMapMode[routeId] ?? true; // default MAP
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
        width: 140,
        child: Row(children: [
          Expanded(child: _segBtn('Map', isMap, () => setState(() => _routeMapMode[routeId] = true))),
          const SizedBox(width: 6),
          Expanded(child: _segBtn('List', !isMap, () => setState(() => _routeMapMode[routeId] = false))),
        ]),
      ),
      // ── CHANGE #494: both per-route optimize buttons are Map-only — they
      // re-anchor the polyline/order, which only means anything while the
      // map is showing. Hidden entirely in List mode.
      if (isMap) ...[
        const SizedBox(height: 10),
        _buildRouteOptimizeButtons(routeId),
      ],
      const SizedBox(height: 10),
      if (isMap)
        _buildRouteMapView(routeId)
      else
        Column(children: stops.map((s) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _builderStopRow(s),
            )).toList()),
    ]);
  }

  // ── CHANGE #494: two equal-size, ~46dp-tall optimize buttons, side by
  // side. "By location" is #493's flow unchanged (origin = driver GPS). "By
  // warehouse" is the same two calls the combined "optimize all" button
  // makes per route (google-route with NO origin -> route_apply_google) —
  // re-anchors this one route back to the hub, undoing a previous "by
  // location" optimize.
  Widget _buildRouteOptimizeButtons(String routeId) {
    final byLocation = _routeOptimizingFromLocation[routeId] == true;
    final byWarehouse = _routeOptimizingByWarehouse[routeId] == true;
    final busy = byLocation || byWarehouse;

    Widget button({required String label, required IconData icon, required bool loading, required VoidCallback onTap}) {
      return Expanded(
        child: OutlinedButton(
          onPressed: busy ? null : onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF1B7A43),
            side: const BorderSide(color: Color(0xFF1B7A43)),
            minimumSize: const Size.fromHeight(46),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: loading
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)))
              : Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 15),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(label,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
        ),
      );
    }

    // CHANGE #495 fix: this Row sits in a plain Column with no fixed height,
    // so it receives an UNBOUNDED height constraint. CrossAxisAlignment
    // .stretch under an unbounded constraint throws ("BoxConstraints forces
    // an infinite height"), which aborted layout of every sibling after it
    // (map, stop-range buttons) too -> the whole Map view went blank.
    // IntrinsicHeight resolves the Row's own height from its children FIRST
    // (a real, finite number), so stretch then has something valid to fill —
    // still gets equal-height buttons even if one label wraps to 2 lines.
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        button(
          label: 'Optimize by location',
          icon: Icons.my_location,
          loading: byLocation,
          onTap: () => _optimizeRouteFromMyLocation(routeId),
        ),
        const SizedBox(width: 8),
        button(
          label: 'Optimize by warehouse',
          icon: Icons.warehouse,
          loading: byWarehouse,
          onTap: () => _optimizeRouteByWarehouse(routeId),
        ),
      ]),
    );
  }

  Widget _buildRouteMapView(String routeId) {
    final loading = _routeMapLoading[routeId] == true;
    final data = _routeMapData[routeId];
    final mapHeight = widget.isDesktop ? 420.0 : 320.0;

    if (loading && data == null) {
      return SizedBox(
        height: mapHeight,
        child: const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)),
      );
    }
    if (data == null) {
      return SizedBox(
        height: mapHeight,
        child: const Center(
          child: Text('Nothing to map.', style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
        ),
      );
    }

    final summary = data['summary']?.toString();
    final closedLabel = data['closed_label']?.toString();
    final legs = ((data['legs'] as List?) ?? []).map((l) => Map<String, dynamic>.from(l as Map)).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // B3 — header above the map: label/summary/closed_label, VERBATIM.
      if (data['label'] != null)
        Text(data['label'].toString(),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
      if (summary != null) ...[
        const SizedBox(height: 2),
        Text(summary, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      ],
      if (closedLabel != null) ...[
        const SizedBox(height: 2),
        Text(closedLabel,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFFDC2626))),
      ],
      // CHANGE #488 (1B): route-map header status line.
      const SizedBox(height: 2),
      Text(
        data['google_optimized'] == true
            ? '✓ Google optimized'
            : 'Tap Optimize with Google for road route',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: data['google_optimized'] == true ? const Color(0xFF065F46) : const Color(0xFF9CA3AF),
        ),
      ),
      const SizedBox(height: 8),
      RouteGoogleMapPanel(
        mapData: data,
        isDesktop: widget.isDesktop,
        onTapStop: _openMapStopSheet,
      ),
      // B5 — leg buttons: Google's directions URL takes only ~9 waypoints, so
      // a 27-stop route is chunked server-side into legs. Never build one URL.
      if (legs.isNotEmpty) ...[
        const SizedBox(height: 10),
        Wrap(
          spacing: 8, runSpacing: 8,
          children: legs.map((leg) {
            final url = leg['url']?.toString();
            return OutlinedButton(
              onPressed: url == null || url.isEmpty
                  ? null
                  : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1B7A43),
                side: const BorderSide(color: Color(0xFF1B7A43)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(leg['label']?.toString() ?? '', style: const TextStyle(fontSize: 12.5)),
            );
          }).toList(),
        ),
      ],
    ]);
  }

  // ── D3: Today's Visits collapsible panel ─────────────────────────────────

  Widget _buildVisitsReportPanel() {
    final report = _visitsReport;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(children: [
        InkWell(
          onTap: _toggleVisitsReport,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              const Icon(Icons.checklist_rtl, size: 18, color: Color(0xFF6B7280)),
              const SizedBox(width: 8),
              const Expanded(
                child: Text("Today's visits",
                    style: TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              ),
              Icon(_visitsExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 20, color: const Color(0xFF6B7280)),
            ]),
          ),
        ),
        if (_visitsExpanded) ...[
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.all(14),
            child: _visitsLoading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
                    ),
                  )
                : report == null
                    ? const Text('Could not load.', style: TextStyle(color: Color(0xFF6B7280)))
                    : _buildVisitsReportBody(report),
          ),
        ],
      ]),
    );
  }

  Widget _buildVisitsReportBody(Map<String, dynamic> report) {
    final totals = Map<String, dynamic>.from(report['totals'] as Map? ?? {});
    final corrections = Map<String, dynamic>.from(report['corrections'] as Map? ?? {});
    final visits = ((report['visits'] as List?) ?? [])
        .map((v) => Map<String, dynamic>.from(v as Map))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 16, runSpacing: 8, children: [
        _statPill('Visits', totals['visits']),
        _statPill('Verified', totals['verified']),
        _statPill('Suspicious', totals['suspicious']),
        _statPill('Interested', totals['interested']),
      ]),
      if (corrections['label'] != null) ...[
        const SizedBox(height: 10),
        Text(corrections['label'].toString(),
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF1B7A43))),
      ],
      const SizedBox(height: 12),
      if (visits.isEmpty)
        const Text('No visits yet today.', style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)))
      else
        ...visits.map((v) => _visitRow(v)),
    ]);
  }

  Widget _statPill(String label, dynamic value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${value ?? 0}',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
    ]);
  }

  Widget _visitRow(Map<String, dynamic> v) {
    final suspicious = v['suspicious'] == true;
    final photoUrl = v['photo_url']?.toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: suspicious ? const Color(0xFFFFFBEB) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: suspicious ? Border.all(color: const Color(0xFFFDE68A)) : null,
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (photoUrl != null && photoUrl.isNotEmpty) ...[
          GestureDetector(
            onTap: () => openFullscreenImage(context, photoUrl),
            child: _routePhoto(photoUrl, 40),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 2, children: [
              Text(v['time_label']?.toString() ?? '',
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
              Text(v['shop']?.toString() ?? '',
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              Text(v['worker']?.toString() ?? '',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            ]),
            const SizedBox(height: 3),
            Wrap(spacing: 8, runSpacing: 2, children: [
              Text(v['status']?.toString() ?? '',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
              Text(v['verify_label']?.toString() ?? '',
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600,
                      color: suspicious ? const Color(0xFF92400E) : const Color(0xFF065F46))),
            ]),
            if (v['note'] != null && v['note'].toString().isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(v['note'].toString(), style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _bandChip(String? band) {
    Color bg, fg;
    switch (band) {
      case 'hot':  bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B); break;
      case 'warm': bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); break;
      default:     bg = const Color(0xFFF3F4F6); fg = const Color(0xFF6B7280);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(band ?? '', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  Widget _segBtn(String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1B7A43) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w600,
                color: active ? Colors.white : const Color(0xFF374151))),
      ),
    );
  }

  Widget _buildRouteSummaryBar(Map<String, dynamic> route, List<Map<String, dynamic>> mapsLinks) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 4, children: [
        Text(route['start_label']?.toString() ?? '',
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF374151))),
        const Text('·', style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
        Text(route['stops_label']?.toString() ?? '',
            style: const TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
        const Text('·', style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
        Text(route['total_label']?.toString() ?? '',
            style: const TextStyle(
                fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
      ]),
      if (mapsLinks.isNotEmpty) ...[
        const SizedBox(height: 10),
        Wrap(
          spacing: 8, runSpacing: 8,
          children: mapsLinks.map((m) {
            return OutlinedButton.icon(
              onPressed: () =>
                  launchUrl(Uri.parse(m['url'].toString()), mode: LaunchMode.externalApplication),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1B7A43),
                side: const BorderSide(color: Color(0xFF1B7A43)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.map_outlined, size: 15),
              label: Text(m['label']?.toString() ?? 'Open in Maps', style: const TextStyle(fontSize: 12)),
            );
          }).toList(),
        ),
      ],
    ]);
  }

  // ── CHANGE #452 C2: builder stop row — check/uncheck + eta/wait/open_ok ──
  // NEW shape from route_plan_get (area, eta_label, wait_label, open_ok,
  // included) — distinct from the #445 my_route() stop shape below (which
  // has branch_label/stale_label/pin_label/visit_label instead). Reuses
  // _openCheckIn / the SAME #446 check-in sheet — record_visit only needs
  // lead_id, which both shapes carry.
  Widget _builderStopRow(Map<String, dynamic> s) {
    final stopId = s['stop_id'].toString();
    final included = s['included'] == true;
    final photoUrl = s['photo_url']?.toString();
    final size = widget.isDesktop ? 56.0 : 44.0;
    final openLabel = s['open_label']?.toString();
    final openOk = s['open_ok'] != false; // only false is a real SHUT; unknown/true are not
    final waitLabel = s['wait_label']?.toString();
    final callLink = s['call_link']?.toString();
    final waLink = s['wa_link']?.toString();
    final navLink = s['nav_link']?.toString();
    final shut = openLabel == 'SHUT on arrival';
    RenderLog.write('c452_checkin_wired', 1); // Check-in button is built below

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: shut ? const Color(0xFFFEF2F2) : const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: shut ? Border.all(color: const Color(0xFFFECACA)) : null,
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Checkbox(
          value: included,
          onChanged: (v) => _toggleStopIncluded(stopId, v == true),
          activeColor: const Color(0xFF1B7A43),
        ),
        SizedBox(
          width: 20,
          child: Text('${s['seq'] ?? ''}',
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w800, color: Color(0xFF9CA3AF))),
        ),
        const SizedBox(width: 6),
        _routePhoto(photoUrl, size),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
              Text(s['name']?.toString() ?? '',
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              if (s['score_label'] != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(4)),
                  child: Text(s['score_label'].toString(),
                      style: const TextStyle(
                          fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
                ),
              _bandChip(s['band']?.toString()),
            ]),
            if (s['area'] != null && s['area'].toString().isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(s['area'].toString(), style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            ],
            if (s['eta_label'] != null || openLabel != null) ...[
              const SizedBox(height: 3),
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 2, children: [
                if (s['eta_label'] != null) ...[
                  const Icon(Icons.schedule, size: 12, color: Color(0xFF9CA3AF)),
                  const SizedBox(width: 2),
                  Text(s['eta_label'].toString(),
                      style: const TextStyle(fontSize: 11.5, color: Color(0xFF374151))),
                ],
                if (openLabel != null)
                  Text(openLabel,
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w600,
                          // Unknown is grey, never red — unknown is not closed.
                          color: !openOk
                              ? const Color(0xFFDC2626)
                              : openLabel == 'Open on arrival'
                                  ? const Color(0xFF065F46)
                                  : const Color(0xFF9CA3AF))),
              ]),
            ],
            if (waitLabel != null) ...[
              const SizedBox(height: 2),
              Text(waitLabel, style: const TextStyle(fontSize: 11.5, color: Color(0xFFD97706))),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (callLink != null)
                _stopActionBtn(Icons.call, 'Call', () => launchUrl(Uri.parse(callLink))),
              if (waLink != null)
                _stopActionBtn(Icons.chat, 'WhatsApp',
                    () => launchUrl(Uri.parse(waLink), mode: LaunchMode.externalApplication)),
              if (navLink != null)
                _stopActionBtn(Icons.navigation_outlined, 'Navigate',
                    () => launchUrl(Uri.parse(navLink), mode: LaunchMode.externalApplication)),
              _stopActionBtn(Icons.check_circle, 'Check in',
                  () => _openCheckIn(s, onRefresh: () { if (_planId != null) _loadPlan(_planId!); }),
                  filled: true),
            ]),
            if (s['leg_label'] != null || s['cum_label'] != null) ...[
              const SizedBox(height: 6),
              Text(
                [s['leg_label'], s['cum_label']].where((v) => v != null).join(' · '),
                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  // ── B6 + C: stop card (#445/#446 my_route() shape) — unchanged, used by
  // the rep view only. ──────────────────────────────────────────────────────

  Widget _stopCard(Map<String, dynamic> s, {String? assignmentId, required VoidCallback onRefresh}) {
    final photoUrl = s['photo_url']?.toString();
    final size = widget.isDesktop ? 56.0 : 44.0;
    final openLabel = s['open_label']?.toString();
    final todayHours = s['today_hours']?.toString();
    final branchLabel = s['branch_label']?.toString();
    final staleLabel = s['stale_label']?.toString();
    final pinLabel = s['pin_label']?.toString();
    final visitLabel = s['visit_label']?.toString();
    final callLink = s['call_link']?.toString();
    final waLink = s['wa_link']?.toString();
    final navLink = s['nav_link']?.toString();
    final addressPincode = [s['address_line'], s['pincode']]
        .where((v) => v != null && v.toString().isNotEmpty)
        .join(' · ');

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 22,
          child: Text('${s['seq'] ?? ''}',
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF9CA3AF))),
        ),
        const SizedBox(width: 6),
        _routePhoto(photoUrl, size),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 4, children: [
              Text(s['name']?.toString() ?? '',
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              if (s['score_label'] != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(4)),
                  child: Text(s['score_label'].toString(),
                      style: const TextStyle(
                          fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
                ),
              _bandChip(s['band']?.toString()),
            ]),
            if (addressPincode.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(addressPincode, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            ],
            if (openLabel != null || todayHours != null) ...[
              const SizedBox(height: 3),
              Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 2, children: [
                if (openLabel != null) ...[
                  Container(
                    width: 7, height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: openLabel == 'Open now' ? const Color(0xFF16A34A) : const Color(0xFF9CA3AF),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text(openLabel, style: const TextStyle(fontSize: 11.5, color: Color(0xFF374151))),
                ],
                if (todayHours != null)
                  Text(todayHours, style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
              ]),
            ],
            if (branchLabel != null) ...[
              const SizedBox(height: 5),
              _infoChip(branchLabel, const Color(0xFFEFF6FF), const Color(0xFF1E40AF)),
            ],
            if (staleLabel != null) ...[
              const SizedBox(height: 5),
              _infoChip('⚠ $staleLabel', const Color(0xFFFEF3C7), const Color(0xFF92400E)),
            ],
            if (pinLabel != null) ...[
              const SizedBox(height: 5),
              _infoChip('📍 $pinLabel', const Color(0xFFEFF6FF), const Color(0xFF1E40AF)),
            ],
            if (visitLabel != null) ...[
              const SizedBox(height: 4),
              Text(visitLabel, style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
            ],
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (callLink != null)
                _stopActionBtn(Icons.call, 'Call', () => launchUrl(Uri.parse(callLink))),
              if (waLink != null)
                _stopActionBtn(Icons.chat, 'WhatsApp',
                    () => launchUrl(Uri.parse(waLink), mode: LaunchMode.externalApplication)),
              if (navLink != null)
                _stopActionBtn(Icons.navigation_outlined, 'Navigate',
                    () => launchUrl(Uri.parse(navLink), mode: LaunchMode.externalApplication)),
              _stopActionBtn(Icons.person_add_alt_1, 'Convert', () => _convert(s, onRefresh: onRefresh)),
              _stopActionBtn(Icons.check_circle, 'CHECK IN',
                  () => _openCheckIn(s, assignmentId: assignmentId, onRefresh: onRefresh),
                  filled: true),
            ]),
            if (s['leg_label'] != null || s['cum_label'] != null) ...[
              const SizedBox(height: 6),
              Text(
                [
                  s['leg_label'] != null ? '${s['leg_label']} from last stop' : null,
                  s['cum_label'],
                ].where((v) => v != null).join(' · '),
                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _infoChip(String label, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  // ── CHANGE #488: Google-optimization status pill — shared by the plan
  // header and each Past Plans card. total==0 means "nothing to badge yet".
  Widget _optStatusBadge({required int total, required int optimized}) {
    if (total == 0) return const SizedBox.shrink();
    if (optimized == total) {
      return _infoChip('✓ Google optimized', const Color(0xFFD1FAE5), const Color(0xFF065F46));
    }
    if (optimized > 0) {
      return _infoChip('⚡ $optimized/$total optimized', const Color(0xFFFEF3C7), const Color(0xFF92400E));
    }
    return _infoChip('Not optimized', const Color(0xFFF3F4F6), const Color(0xFF6B7280));
  }

  // ── CHANGE #488 (1C): Optimize button label adapts to progress. Re-optimize
  // is always allowed even when fully done — the button never disables here.
  String _optimizeButtonLabel({required int total, required int optimized}) {
    if (total > 0 && optimized == total) return '✓ Optimized';
    if (optimized > 0) return 'Optimize remaining (${total - optimized} left)';
    return 'Optimize with Google';
  }

  Widget _stopActionBtn(IconData icon, String label, VoidCallback onTap, {bool filled = false}) {
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: filled ? Colors.white : const Color(0xFF1B7A43),
        backgroundColor: filled ? const Color(0xFF1B7A43) : null,
        side: const BorderSide(color: Color(0xFF1B7A43)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        minimumSize: const Size(44, 40), // big tap targets — D1, used one-handed
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }

  // Same Image.network+loadingBuilder+errorBuilder pattern as
  // _SLeadsTabState._leadThumb (A4) — duplicated rather than shared because
  // it is a private method on a different State class and S Leads must not
  // be touched; the placeholder/loading visuals are identical.
  Widget _routePhoto(String? url, double size) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: (url == null || url.isEmpty)
          ? Container(
              width: size, height: size,
              color: const Color(0xFFF3F4F6),
              alignment: Alignment.center,
              child: Icon(Icons.storefront_outlined, size: size * 0.45, color: const Color(0xFFD1D5DB)),
            )
          : Image.network(
              url,
              width: size, height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              cacheWidth: (size * 2).toInt(),
              loadingBuilder: (_, child, prog) => prog == null
                  ? child
                  : Container(
                      width: size, height: size,
                      color: const Color(0xFFF3F4F6),
                      alignment: Alignment.center,
                      child: const SizedBox(width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD1D5DB))),
                    ),
              errorBuilder: (_, __, ___) => Container(
                width: size, height: size,
                color: const Color(0xFFF3F4F6),
                alignment: Alignment.center,
                child: Icon(Icons.storefront_outlined, size: size * 0.45, color: const Color(0xFFD1D5DB)),
              ),
            ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════
// C: Check-in bottom sheet — the correction engine. GPS is REQUIRED (Submit
// stays disabled without a fix); photo is optional. record_visit does every
// check server-side (100m verified / 500m blocked, moved+not_found exempt) —
// this widget only captures GPS + photo + status and shows the response.
// ═════════════════════════════════════════════════════════════════════════

class _CheckInSheet extends StatefulWidget {
  final Map<String, dynamic> stop;
  final String? assignmentId;
  final VoidCallback onDone;
  const _CheckInSheet({required this.stop, this.assignmentId, required this.onDone});

  @override
  State<_CheckInSheet> createState() => _CheckInSheetState();
}

class _CheckInSheetState extends State<_CheckInSheet> {
  bool _locating = true;
  String? _locError;
  double? _lat;
  double? _lng;

  Uint8List? _photoBytes;
  String? _photoMime;

  String? _status;
  final _noteCtrl = TextEditingController();

  bool _submitting = false;
  String? _submitError; // too_far / other error — shown inline, sheet stays open

  @override
  void initState() {
    super.initState();
    _captureGps();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  // Same GPS pattern as CashPaymentSheet._requestLocation / the Warehouse
  // card / the "Start from: My location" route control — A3.
  Future<void> _captureGps() async {
    setState(() { _locating = true; _locError = null; });
    try {
      final completer = Completer<html.Geoposition>();
      html.window.navigator.geolocation
          .getCurrentPosition(enableHighAccuracy: false, timeout: const Duration(seconds: 20))
          .then((pos) { if (!completer.isCompleted) completer.complete(pos); })
          .catchError((e) { if (!completer.isCompleted) completer.completeError(e); });
      final pos = await completer.future.timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw TimeoutException('Location timed out'),
      );
      final lat = pos.coords?.latitude?.toDouble();
      final lng = pos.coords?.longitude?.toDouble();
      if (lat == null || lng == null) throw Exception('No coordinates returned');
      if (!mounted) return;
      setState(() { _lat = lat; _lng = lng; _locating = false; });
      RenderLog.write('c445_gps_ok', 1);
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().toLowerCase();
      final denied = msg.contains('denied') || msg.contains('permission');
      setState(() {
        _locating = false;
        _locError = denied
            ? 'Location permission is required to check in.'
            : "Couldn't get a GPS fix. Move outdoors and retry.";
      });
    }
  }

  // Same html.FileUploadInputElement + FileReader.readAsDataUrl capture
  // pattern as CashPaymentSheet._pickFile — A3. 'capture=environment' opens
  // the rear camera directly on mobile instead of the gallery picker.
  void _takePhoto() {
    final input = html.FileUploadInputElement();
    input.accept = 'image/*';
    input.setAttribute('capture', 'environment');
    input.click();
    input.onChange.listen((_) async {
      final files = input.files;
      if (files == null || files.isEmpty) return;
      final file = files.first;
      final mime = file.type.isNotEmpty ? file.type : 'image/jpeg';
      if (!mime.startsWith('image/')) return;
      final reader = html.FileReader();
      reader.readAsDataUrl(file);
      await reader.onLoad.first;
      final dataUrl = reader.result as String;
      final comma = dataUrl.indexOf(',');
      final bytes = base64Decode(dataUrl.substring(comma + 1));
      if (!mounted) return;
      setState(() { _photoBytes = bytes; _photoMime = mime; });
    });
  }

  bool get _canSubmit =>
      !_submitting && !_locating && _locError == null && _lat != null && _lng != null && _status != null;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() { _submitting = true; _submitError = null; });

    String? photoPath;
    if (_photoBytes != null) {
      try {
        final leadId = widget.stop['lead_id'];
        final ts = DateTime.now().millisecondsSinceEpoch;
        final rand = Random().nextInt(999999);
        final ext = (_photoMime ?? '').contains('png') ? 'png' : 'jpg';
        final path = '$leadId/${ts}_$rand.$ext';
        await Supabase.instance.client.storage.from('lead-visit-photos').uploadBinary(
          path, _photoBytes!,
          fileOptions: FileOptions(contentType: _photoMime ?? 'image/jpeg', upsert: true),
        );
        photoPath = path;
      } catch (_) {
        photoPath = null; // never lose the check-in over a failed photo upload
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Photo upload failed — visit still recorded.')));
        }
      }
    }

    try {
      final res = await Supabase.instance.client.rpc('record_visit', params: {
        'p_lead_id': widget.stop['lead_id'],
        'p_lat': _lat,
        'p_lng': _lng,
        'p_status': _status,
        if (photoPath != null) 'p_photo_path': photoPath,
        if (_noteCtrl.text.trim().isNotEmpty) 'p_note': _noteCtrl.text.trim(),
        if (widget.assignmentId != null) 'p_assignment_id': widget.assignmentId,
      });
      final data = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      if (data['ok'] == true) {
        final verifyLabel = data['verify_label']?.toString() ?? '';
        final message = data['message']?.toString() ?? '';
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text([verifyLabel, message].where((v) => v.isNotEmpty).join(' — ')),
          backgroundColor: const Color(0xFF1B7A43),
        ));
        widget.onDone(); // re-call the route RPC; the shop may now be gone — correct
      } else {
        // { error: "too_far", message: "..." } or any other error — shown
        // verbatim, sheet stays open, chosen status kept. No retry, no
        // fallback GPS.
        setState(() {
          _submitting = false;
          _submitError = data['message']?.toString() ?? data['error']?.toString() ?? 'Could not record visit.';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _submitting = false; _submitError = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tooFar = _submitError != null; // highlight the two allowed escapes
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Center(
              child: Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(widget.stop['name']?.toString() ?? '',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const SizedBox(height: 14),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            const SizedBox(height: 14),

            // ── GPS ──────────────────────────────────────────────────────
            Row(children: [
              const Icon(Icons.location_on, size: 18, color: Color(0xFF6B7280)),
              const SizedBox(width: 8),
              if (_locating)
                const Row(children: [
                  SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('Getting your location…', style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                ])
              else if (_locError != null)
                Expanded(
                  child: Text(_locError!, style: const TextStyle(fontSize: 13, color: Color(0xFFDC2626))),
                )
              else
                const Text('GPS captured ✅',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF065F46))),
              if (_locError != null) ...[
                const Spacer(),
                TextButton(onPressed: _captureGps, child: const Text('Retry')),
              ],
            ]),
            const SizedBox(height: 14),

            // ── Photo ────────────────────────────────────────────────────
            const Text('Photo proof helps verify the visit.',
                style: TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
            const SizedBox(height: 6),
            Row(children: [
              OutlinedButton.icon(
                onPressed: _takePhoto,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1B7A43),
                  side: const BorderSide(color: Color(0xFF1B7A43)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                icon: const Icon(Icons.camera_alt_outlined, size: 16),
                label: Text(_photoBytes == null ? 'Take photo of the shop' : 'Retake photo',
                    style: const TextStyle(fontSize: 12.5)),
              ),
              if (_photoBytes != null) ...[
                const SizedBox(width: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(_photoBytes!, width: 44, height: 44, fit: BoxFit.cover),
                ),
              ],
            ]),
            const SizedBox(height: 18),

            // ── Status ───────────────────────────────────────────────────
            const Text('What happened?',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const SizedBox(height: 6),
            ..._kVisitStatuses.map((entry) => _statusRadio(entry.$1, entry.$2, highlight: tooFar)),
            const SizedBox(height: 10),

            // ── Note ─────────────────────────────────────────────────────
            TextField(
              controller: _noteCtrl,
              decoration: InputDecoration(
                labelText: 'Note (optional)',
                labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 13),
              maxLines: 2,
            ),

            if (_submitError != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEE2E2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_submitError!,
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFF991B1B))),
              ),
            ],

            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: _canSubmit ? _submit : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1B7A43),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(0xFFD1D5DB),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: _submitting
                      ? const SizedBox(width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Submit', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _statusRadio(String value, String label, {required bool highlight}) {
    final isEscape = value == 'moved' || value == 'not_found'; // C3 — allowed at any GPS reading
    final selected = _status == value;
    return Column(children: [
      InkWell(
        onTap: () => setState(() => _status = value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12), // big tap target
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFEFF6FF) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: highlight && isEscape
                  ? const Color(0xFF1B7A43)
                  : selected ? const Color(0xFF1E40AF) : const Color(0xFFE5E7EB),
              width: highlight && isEscape ? 1.5 : 1,
            ),
          ),
          child: Row(children: [
            Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 18, color: selected ? const Color(0xFF1B7A43) : const Color(0xFF9CA3AF)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 13.5, color: Color(0xFF111827))),
            ),
          ]),
        ),
      ),
      // C4 — pin-correction warning, only for "Shop has moved".
      if (value == 'moved' && selected)
        Padding(
          padding: const EdgeInsets.only(left: 10, bottom: 8),
          child: Text('Your current GPS will replace this shop\'s location.',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFD97706))),
        ),
    ]);
  }
}

// ═════════════════════════════════════════════════════════════════════════
// D2: Admin — assign a zone to a worker
// ═════════════════════════════════════════════════════════════════════════

// ── CHANGE #452 C4: assign a ROUTE (route_plan_assign) — replaces the old
// zone-based _AssignZoneDialog (lead_assign_zone). Pops `true` on success so
// the caller knows to re-call route_plan_get.
class _AssignRouteDialog extends StatefulWidget {
  final Map<String, dynamic> route;
  final List<Map<String, dynamic>> initialWorkers;
  const _AssignRouteDialog({required this.route, required this.initialWorkers});

  @override
  State<_AssignRouteDialog> createState() => _AssignRouteDialogState();
}

class _AssignRouteDialogState extends State<_AssignRouteDialog> {
  late List<Map<String, dynamic>> _workers;
  String? _workerId;
  DateTime _forDate = todayIst();
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _workers = widget.initialWorkers;
  }

  Future<void> _addWorker() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Add worker'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: nameCtrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: phoneCtrl,
            decoration: const InputDecoration(labelText: 'Phone', border: OutlineInputBorder(), isDense: true),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    final name = nameCtrl.text.trim();
    final phone = phoneCtrl.text.trim();
    nameCtrl.dispose();
    phoneCtrl.dispose();
    if (go != true || name.isEmpty) return;
    try {
      await Supabase.instance.client.rpc('lead_worker_upsert', params: {
        'p_name': name,
        if (phone.isNotEmpty) 'p_phone': phone,
      });
      final res = await Supabase.instance.client.rpc('lead_workers_list');
      final workers = ((res as List?) ?? []).map((w) => Map<String, dynamic>.from(w as Map)).toList();
      if (!mounted) return;
      setState(() => _workers = workers);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Worker added.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _forDate,
      firstDate: todayIst().subtract(const Duration(days: 1)),
      lastDate: todayIst().add(const Duration(days: 60)),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: Color(0xFF1B7A43)),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _forDate = picked);
  }

  Future<void> _submit() async {
    if (_workerId == null) { setState(() => _error = 'Pick a worker.'); return; }
    setState(() { _submitting = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc('route_plan_assign', params: {
        'p_route_id': widget.route['route_id'],
        'p_worker_id': _workerId,
        'p_for_date':
            '${_forDate.year.toString().padLeft(4, '0')}-${_forDate.month.toString().padLeft(2, '0')}-${_forDate.day.toString().padLeft(2, '0')}',
      });
      final data = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      if (data['ok'] == true) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(data['message']?.toString() ?? 'Assigned.'),
          backgroundColor: const Color(0xFF1B7A43),
        ));
      } else {
        setState(() { _submitting = false; _error = data['message']?.toString() ?? data['error']?.toString(); });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _submitting = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Assign ${widget.route['title'] ?? ''}'),
      content: SizedBox(
        width: 360,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _workerId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Worker', border: OutlineInputBorder(), isDense: true),
                items: _workers.map((w) {
                  final id = w['worker_id']?.toString() ?? '';
                  final label = '${w['name'] ?? ''} — ${w['subtitle'] ?? ''}';
                  return DropdownMenuItem(value: id, child: Text(label, overflow: TextOverflow.ellipsis));
                }).toList(),
                onChanged: (v) => setState(() => _workerId = v),
              ),
            ),
            IconButton(
              onPressed: _addWorker,
              icon: const Icon(Icons.person_add_alt_1, size: 20),
              tooltip: 'Add worker',
            ),
          ]),
          const SizedBox(height: 12),
          InkWell(
            onTap: _pickDate,
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Date', border: OutlineInputBorder(), isDense: true),
              child: Text(
                  '${_forDate.day.toString().padLeft(2, '0')}/${_forDate.month.toString().padLeft(2, '0')}/${_forDate.year}'),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(fontSize: 12.5, color: Color(0xFFDC2626))),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _submitting ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Assign'),
        ),
      ],
    );
  }
}
