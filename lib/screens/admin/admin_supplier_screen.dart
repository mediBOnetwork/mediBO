// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart' as xmlp;

import 'package:url_launcher/url_launcher.dart';

import '../../models/order_hours_model.dart';
import '../../order_hours_state.dart';
import '../../services/match_status_service.dart';
import '../../services/spn_options.dart';
import '../../utils/render_log.dart';
import '../../utils/safe_parse.dart';
import '../../utils/ist_date.dart'; // CHANGE #444
import '../../widgets/date_scope_chip.dart'; // CHANGE #444
import '../../widgets/code_field.dart';
import '../../widgets/fullscreen_image.dart';
import '../../widgets/inquiry_v12.dart';
import '../../widgets/order_item_card.dart';
import '../../widgets/sup_pay_panel.dart';
import 'admin_add_medicine_screen.dart';
import 'unmapped_companies_screen.dart';

const _ocrEdgeFn =
    'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/gemini-ocr';

// ── Supplier row models ───────────────────────────────────────────────────────

class _SupRow {
  final String id;
  final Map<String, dynamic> rawData;

  const _SupRow({required this.id, required this.rawData});

  factory _SupRow.fromMap(Map<String, dynamic> m) =>
      _SupRow(id: m['id'] as String, rawData: Map<String, dynamic>.from(m));

  String get supplierName   => (rawData['supplier_name']  as String? ?? '').trim();
  String get contactName    => (rawData['contact_name']   as String? ?? '').trim();
  String get phone          => (rawData['phone']          as String? ?? rawData['whatsapp_no'] as String? ?? '').trim();
  String get supplierCode   => (rawData['supplier_code']  as String? ?? '').trim();
  String get paymentTerm    => (rawData['payment_term']   as String? ?? '').trim();
  String get city           => (rawData['city']           as String? ?? '').trim();
  String get state          => (rawData['state']          as String? ?? '').trim();
  String get status         =>  rawData['status']         as String? ?? 'Active';
  bool   get isSuspended    => status == 'Suspended';
}

class _PendingRow {
  final String id;
  final Map<String, dynamic> rawData;
  final String supplierName;
  final String contactName;
  final String phone;
  final String? supplierCode;
  final String? paymentTerm;
  final String? city;
  final String? state;
  final DateTime? createdAt;

  const _PendingRow({
    required this.id,
    required this.rawData,
    required this.supplierName,
    required this.contactName,
    required this.phone,
    this.supplierCode,
    this.paymentTerm,
    this.city,
    this.state,
    this.createdAt,
  });

  factory _PendingRow.fromMap(Map<String, dynamic> m) => _PendingRow(
    id:           m['id'] as String,
    rawData:      Map<String, dynamic>.from(m),
    supplierName: m['supplier_name'] as String? ?? '',
    contactName:  m['contact_name']  as String? ?? '',
    phone:        m['phone']         as String? ?? m['whatsapp_no'] as String? ?? '',
    supplierCode: m['supplier_code'] as String?,
    paymentTerm:  m['payment_term']  as String?,
    city:         m['city']          as String?,
    state:        m['state']         as String?,
    createdAt:    m['created_at'] != null ? DateTime.tryParse(m['created_at'] as String) : null,
  );
}

class _OrderRow {
  final String id;
  final String? supplierName;
  final String? description;
  final double? totalAmount;
  final String status;
  final DateTime? createdAt;
  final List<Map<String, dynamic>> items;
  final String? orderCode;

  const _OrderRow({
    required this.id,
    this.supplierName,
    this.description,
    this.totalAmount,
    required this.status,
    this.createdAt,
    this.items = const [],
    this.orderCode,
  });

  factory _OrderRow.fromMap(Map<String, dynamic> m) => _OrderRow(
    id:           m['id'] as String,
    supplierName: m['supplier_name'] as String?,
    description:  m['description']  as String?,
    totalAmount:  (m['total_amount'] as num?)?.toDouble(),
    status:       m['status'] as String? ?? 'pending',
    createdAt:    m['created_at'] != null ? DateTime.tryParse(m['created_at'] as String) : null,
    items:        (m['items'] as List<dynamic>?)
                      ?.map((e) => Map<String, dynamic>.from(e as Map))
                      .toList() ?? [],
    orderCode:    (m['order_code'] as String?)?.trim(),
  );
}

class _LeadItem {
  final String id;
  String name;
  String email;
  String mobile;
  String status;
  String source;

  _LeadItem({
    required this.id,
    required this.name,
    required this.email,
    required this.mobile,
    required this.status,
    required this.source,
  });
}

// ── Tab enum ──────────────────────────────────────────────────────────────────

enum _SupFilter  { suppliers, inquiry, orders, pending, leads, staging }
enum _SupSortMode { spnDesc, nameAsc }

// ── Screen ────────────────────────────────────────────────────────────────────

class AdminSupplierScreen extends StatefulWidget {
  static final _screenKey = GlobalKey<_AdminSupplierScreenState>();

  AdminSupplierScreen() : super(key: _screenKey);

  /// Called by the shell when this screen becomes the active page.
  static void triggerFocus() =>
      _screenKey.currentState?._onScreenFocus();

  @override
  State<AdminSupplierScreen> createState() => _AdminSupplierScreenState();
}

// ── CHANGE #459: readiness check row — one line, right-aligned value, ────────
// detail (if any) as an indented sub-line. Every string is server-verbatim:
// `label`/`value`/`detail` are never rebuilt or re-pluralised here.

class _ReadinessCheckRow extends StatelessWidget {
  final Map<String, dynamic> check;
  final VoidCallback? onTap;
  final bool expanded;
  const _ReadinessCheckRow({required this.check, this.onTap, this.expanded = false});

  @override
  Widget build(BuildContext context) {
    final ok = check['ok'] == true;
    final label = check['label'] as String? ?? '';
    final value = check['value'] as String? ?? '';
    final detail = check['detail'] as String?;
    final hasDetail = detail != null && detail.isNotEmpty;
    final tappable = onTap != null;

    final row = Container(
      decoration: BoxDecoration(
        color: ok ? null : const Color(0xFFDC2626).withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 34,
          child: Row(children: [
            Icon(ok ? Icons.check_circle : Icons.cancel,
                size: 15, color: ok ? const Color(0xFF1B7A43) : const Color(0xFFDC2626)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
            ),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(value,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
            ),
            if (tappable) ...[
              const SizedBox(width: 4),
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16, color: const Color(0xFF9CA3AF)),
            ],
          ]),
        ),
        if (hasDetail)
          Padding(
            padding: const EdgeInsets.only(left: 23, bottom: 5),
            child: Text(detail,
                style: const TextStyle(fontSize: 11.5, color: Color(0xFFDC2626))),
          ),
      ]),
    );

    return tappable ? InkWell(onTap: onTap, borderRadius: BorderRadius.circular(6), child: row) : row;
  }
}

// ── CHANGE #456: inquiry lock switch — turning it ON blocks new orders for
// everyone via set_inquiry_lock(true). Replaces the old #446 slide-to-send
// action control (which triggered start_inquiry_for_suppliers directly).
// CHANGE #459: `label`/`blockedLabel`/`backlogLabel`/`lockLabel` are all
// printed verbatim from the RPC — nothing here is computed or pluralised.

class _InquiryLockSwitch extends StatelessWidget {
  final String label; // == readiness['slider_label']
  final bool enabled; // == readiness['can_send']
  final bool locked; // == readiness['locked']
  final bool toggling;
  final String? blockedLabel; // == readiness['blocked_label']
  final String? backlogLabel; // == readiness['backlog_label']
  final String? lockLabel; // == readiness['lock_label']
  final Future<void> Function(bool turnOn) onToggle;

  const _InquiryLockSwitch({
    required this.label,
    required this.enabled,
    required this.locked,
    required this.toggling,
    required this.onToggle,
    this.blockedLabel,
    this.backlogLabel,
    this.lockLabel,
  });

  @override
  Widget build(BuildContext context) {
    final canInteract = enabled && !toggling;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        ),
        if (toggling)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43))),
          )
        else
          Switch(
            value: locked,
            activeColor: const Color(0xFF1B7A43),
            onChanged: canInteract ? (v) => onToggle(v) : null,
          ),
      ]),
      if (!enabled && blockedLabel != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(blockedLabel!,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFFDC2626), fontWeight: FontWeight.w600)),
        ),
      if (backlogLabel != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(backlogLabel!,
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF92400E), fontWeight: FontWeight.w600)),
        ),
      if (locked && lockLabel != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(lockLabel!,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        ),
    ]);
  }
}

class _AdminSupplierScreenState extends State<AdminSupplierScreen> {
  // CHANGE #444 — Supplier Orders date scope. Own chip, default today, no pill.
  DateTime _ordersDate = todayIst();
  void _onOrdersDateChanged(DateTime d) {
    setState(() => _ordersDate = d);
    _load(showSpinner: false);
  }

  List<_SupRow>              _suppliers    = [];
  List<_PendingRow>          _pending      = [];
  // Supplier staging (submitted companies + medicines awaiting admin approval)
  List<Map<String, dynamic>> _stagingCompanies  = [];
  List<Map<String, dynamic>> _stagingMedicines  = [];
  List<_OrderRow>            _orders       = [];
  List<_LeadItem>            _leads        = [];
  List<Map<String, dynamic>> _deletedRows  = [];
  bool _deletedExpanded = false;
  bool _loading = true;
  _SupFilter _filter = _SupFilter.suppliers;
  _SupSortMode _sortMode = _SupSortMode.spnDesc;
  // Server-side search over the Suppliers list via admin_list_suppliers RPC
  // (matches company names, not just supplier name/code/city).
  String _supplierQuery = '';
  final TextEditingController _supplierSearchCtl = TextEditingController();
  Timer? _supplierSearchDebounce;
  // Ordered ids returned by the last RPC response; resolved against the live
  // _suppliers list so results stay fresh across realtime reloads.
  List<String> _supplierSearchOrder = [];
  List<_SupRow> get _supplierSearchResults {
    final byId = {for (final s in _suppliers) s.id: s};
    return _supplierSearchOrder.map((id) => byId[id]).whereType<_SupRow>().toList();
  }
  bool _hasPendingChanges = false;
  bool _refreshLoading = false;
  // Supplier detail expand — only one supplier open at a time.
  String? _expandedSupplierId;
  // Companies section — only one supplier open at a time; mutually exclusive with detail.
  String? _companiesSupplierId;
  String? _spnSupplierId;
  final Set<String> _expandedLeads = {};
  final Map<String, int> _companyCounts = {};
  final Map<String, void Function(Map<String, dynamic>)> _spnCallbacks = {};

  // Import Supplier popover (mirrors Clear Cart popover pattern)
  final LayerLink _importSupplierLink = LayerLink();
  OverlayEntry? _importSupplierOverlay;
  final ScrollController _scrollCtrl = ScrollController();
  final List<RealtimeChannel> _channels = [];
  Timer? _debounce;

  // ── Inquiry link state ───────────────────────────────────────────────────
  // supplier_name → {token, status, expires_at}
  final Map<String, Map<String, dynamic>> _inquiryLinks = {};
  bool _inquiryLoading = false;

  // ── CHANGE #456: send-all readiness (inquiry_send_readiness()) + lock ────
  Map<String, dynamic>? _inquiryReadiness;
  bool _readinessLoading = false;
  bool _lockToggling = false;
  Timer? _readinessPollTimer;
  OrderHoursModel? _orderHoursModel;
  bool _readinessItemsExpanded = false; // CHANGE #459: tappable breakdown

  // ── Inquiry tab state ────────────────────────────────────────────────────
  List<Map<String, dynamic>> _inquiryOverview = [];
  bool _inquiryOverviewLoading = false;
  String? _expandedInquirySupplier;
  List<Map<String, dynamic>> _inquiryItems = [];
  bool _inquiryItemsLoading = false;
  RealtimeChannel? _inquiryRtChannel; // CHANGE #458: broadcast-only realtime
  Timer? _c458Debounce;
  int _c458Events = 0;
  int _c458Reloads = 0;
  final Set<int> _settingAnswerFor = {}; // inquiry_ids currently being admin-set
  String? _expandedOrderId; // which supplier order row is expanded

  // ── CHANGE #460: date picker — Today live, earlier days read-only archive ─
  List<Map<String, dynamic>> _inquiryDates = [];
  bool _inquiryDatesLoading = false;
  Map<String, dynamic>? _inquiryDatesSelected; // entry from _inquiryDates, null = today
  Map<String, dynamic>? _inquiryDayArchive; // inquiry_day() result for a past date
  bool _inquiryDayLoading = false;
  String? _expandedArchiveSupplier;

  // ── CHANGE #328: supplier order bill+payment panels ──────────────────────
  // bill panel open per order id
  final Map<String, bool> _orderBillOpen = {};
  // payment panel open per order id
  final Map<String, bool> _orderPayOpen  = {};
  // cached panel data per order id (from sup_order_bill_panel)
  final Map<String, Map<String, dynamic>> _orderPanelData    = {};
  // loading state per order id
  final Map<String, bool> _orderPanelLoading = {};
  // error per order id
  final Map<String, String?> _orderPanelError = {};

  // ── Inquiry select-and-submit state (#109) ───────────────────────────────
  final Map<int, String> _adminSelections = {};
  bool _adminSubmitting = false;
  int _adminSubmitCount = 0;

  // ── Unassigned inquiry items (no current supplier) ───────────────────────
  List<Map<String, dynamic>> _unassignedItems = [];
  bool _unassignedLoading = false;
  // Accordion state: which unassigned dropdown is open ('no_supplier' | 'all_oos' | null)
  String? _openUnassignedDropdown;

  // ── Match status service (change #76) ────────────────────────────────────
  late final MatchStatusService _matchService;
  void Function()? _matchServiceListener;

  // ── Auto-meta toggle (persisted via get/set_app_setting) ─────────────────
  bool _autoMeta = false;
  bool _autoMetaLoading = false;

  // ── Supplier Orders auto-meta toggle ─────────────────────────────────────
  bool _orderAutoMeta = false;
  bool _orderAutoMetaLoading = false;

  // ── CHANGE #277: current-holder filter ───────────────────────────────────
  // Keys: "supplier_name_lower|product_id" for live order_items
  Set<String> _liveOrderItemKeys = {};

  // ── Allocation mode toggle ────────────────────────────────────────────────
  String _allocationMode = 'first_available'; // 'first_available' | 'fewest_baskets'
  bool _allocationLoading = false;

  // ── Manual move overlay (per inquiry_id) ─────────────────────────────────
  OverlayEntry? _movePickerOverlay;
  final Map<int, bool> _moveInFlight = {}; // inquiry_id -> loading
  final Map<int, LayerLink> _moveLinks = {};

  // ── Auto-load guard (prevents concurrent/storm fetches) ──────────────────
  bool _loadInFlight = false;
  DateTime? _lastAutoLoad;
  static const _autoLoadMinInterval = Duration(seconds: 5);

  // ── Send-inquiry popover (Clear Cart style) ──────────────────────────────
  final Map<String, LayerLink> _sendLinks = {};
  OverlayEntry? _sendPopoverOverlay;

  LayerLink _getSendLink(String supName) =>
      _sendLinks.putIfAbsent(supName, LayerLink.new);

  void _closeSendPopover() {
    _sendPopoverOverlay?.remove();
    _sendPopoverOverlay = null;
  }

  @override
  void initState() {
    super.initState();
    _matchService = MatchStatusService();
    _matchServiceListener = () { if (mounted) setState(() {}); };
    _matchService.statuses.addListener(_matchServiceListener!);
    _load();
    _loadAllocationMode();
    _subscribeRealtime();
    // CHANGE #446: re-check send-all readiness whenever order hours change.
    _orderHoursModel = OrderHoursState.read(context);
    _orderHoursModel!.addListener(_onOrderHoursChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        RenderLog.write('screen_autoload_on_focus', 'suppliers_initial');
        RenderLog.write('tab_autoload_on_open_suppliers', 'initial');
      }
    });
  }

  void _onOrderHoursChanged() {
    if (!mounted) return;
    // CHANGE #460 (3): inquiry_send_readiness() is Today-only data.
    final onToday = _inquiryDatesSelected == null || _inquiryDatesSelected!['is_today'] == true;
    if (_filter == _SupFilter.inquiry && onToday) _fetchInquiryReadiness(silent: true);
  }

  void _onScreenFocus() {
    if (!mounted) return;
    _autoLoad(key: _filter.name, force: true);
    RenderLog.write('screen_autoload_on_focus', 'suppliers');
  }

  void _autoLoad({required String key, bool force = false}) {
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
    if (_matchServiceListener != null) {
      _matchService.statuses.removeListener(_matchServiceListener!);
    }
    _matchService.dispose();
    _orderHoursModel?.removeListener(_onOrderHoursChanged);
    _debounce?.cancel();
    _readinessPollTimer?.cancel(); // CHANGE #456 C5
    _c458Debounce?.cancel();
    _supplierSearchDebounce?.cancel();
    if (_inquiryRtChannel != null) {
      try { Supabase.instance.client.removeChannel(_inquiryRtChannel!); } catch (_) {}
      _inquiryRtChannel = null;
    }
    for (final ch in _channels) ch.unsubscribe();
    _channels.clear();
    _scrollCtrl.dispose();
    _supplierSearchCtl.dispose();
    _closeSendPopover();
    _closeMovePickerOverlay();
    super.dispose();
  }

  void _subscribeRealtime() {
    final client = Supabase.instance.client;
    final ts = DateTime.now().millisecondsSinceEpoch;

    // Single-binding channel for supplier_profiles: UPDATE → surgical patch;
    // INSERT/DELETE → full debounced reload. CHANGE #252: c252_rt_sub logged on subscribe.
    RenderLog.write('rt_supplier_profiles', 1);
    final spCh = client
        .channel('admin_supplier_profiles')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'supplier_profiles',
          callback: (payload) {
            if (payload.eventType == PostgresChangeEvent.update) {
              _patchSupplierRow(payload.newRecord);
            } else {
              RenderLog.write('c252_rt_reload', 'table=supplier_profiles');
              _debouncedLoad();
            }
          },
        )
        .subscribe((status, [_]) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            RenderLog.write('c252_rt_sub', 'channel=supplier_profiles');
          }
        });
    _channels.add(spCh);

    // Separate channels for other tables (single-binding each).
    for (final table in ['supplier_orders', 'supplier_leads']) {
      final ch = client
          .channel('admin_sup_${table}_$ts')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            callback: (_) => _debouncedLoad(),
          )
          .subscribe();
      _channels.add(ch);
    }
  }

  static const _spnPatchKeys = [
    'margin', 'cd_condition', 'behaviour', 'payment_type', 'payment_term',
    'margin_points', 'cd_points', 'behaviour_points', 'payment_term_points',
    'status', 'supplier_name',
  ];

  void _patchSupplierRow(Map<String, dynamic> newRow) {
    final id = newRow['id'] as String?;
    if (id == null || !mounted) return;
    final idx = _suppliers.indexWhere((s) => s.id == id);
    if (idx >= 0) {
      for (final k in _spnPatchKeys) {
        if (newRow.containsKey(k)) _suppliers[idx].rawData[k] = newRow[k];
      }
    }
    // If this echo is for the currently-open SPN panel, skip the callback and
    // parent rebuild — the user's local _values are source of truth while editing.
    if (id == _spnSupplierId) return;
    _spnCallbacks[id]?.call(newRow);
    if (mounted) setState(() {});
  }

  void _applySort() {
    if (_sortMode == _SupSortMode.spnDesc) {
      _suppliers.sort((a, b) {
        final aSpn = (a.rawData['SPN'] as num?)?.toDouble() ?? -1;
        final bSpn = (b.rawData['SPN'] as num?)?.toDouble() ?? -1;
        return bSpn.compareTo(aSpn); // descending
      });
    } else {
      _suppliers.sort((a, b) =>
          a.supplierName.toLowerCase().compareTo(b.supplierName.toLowerCase()));
    }
  }

  // Debounced trigger for the admin_list_suppliers RPC — fires ~300ms after
  // the user stops typing so company-name search (not just name/code/city)
  // works instead of the old in-memory filter.
  void _onSupplierSearchChanged(String v) {
    final q = v.trim();
    setState(() => _supplierQuery = q);
    _supplierSearchDebounce?.cancel();
    if (q.isEmpty) {
      setState(() => _supplierSearchOrder = []);
      return;
    }
    _supplierSearchDebounce = Timer(
      const Duration(milliseconds: 300),
      () => _runSupplierSearch(q),
    );
  }

  Future<void> _runSupplierSearch(String query) async {
    try {
      final rows = await Supabase.instance.client
          .rpc('admin_list_suppliers', params: {'p_search': query}) as List;
      if (!mounted || query != _supplierQuery) return; // stale response guard
      setState(() {
        _supplierSearchOrder =
            rows.map((r) => (r as Map)['id'] as String).toList();
      });
      RenderLog.write('c_admin_list_suppliers_search', '${_supplierSearchOrder.length}');
    } catch (_) {
      // Silently ignore search errors — keep the prior results visible.
    }
  }

  Future<void> _refreshSuppliers({bool isSave = false}) async {
    if (_refreshLoading) return;
    if (mounted) setState(() => _refreshLoading = true);
    if (isSave) {
      RenderLog.write('save_clicked', '1');
    } else {
      RenderLog.write('refresh_clicked', '1');
    }
    await _load(showSpinner: false);
    if (mounted) {
      setState(() {
        _hasPendingChanges = false;
        _refreshLoading = false;
      });
      RenderLog.write('supabase_refetched', _suppliers.length.toString());
      if (isSave) RenderLog.write('save_committed', '1');
      RenderLog.write('list_rebuilt', _suppliers.length.toString());
    }
  }

  void _debouncedLoad() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => _load(showSpinner: false));
  }

  void _toggleCompanies(String id) => setState(() {
    if (_companiesSupplierId == id) {
      _companiesSupplierId = null;
    } else {
      _companiesSupplierId = id;
      _expandedSupplierId  = null;
      _spnSupplierId       = null;
    }
  });

  void _toggleSpn(String id) => setState(() {
    if (_spnSupplierId == id) {
      _spnSupplierId = null;
    } else {
      _spnSupplierId       = id;
      _expandedSupplierId  = null;
      _companiesSupplierId = null;
    }
  });

  Future<void> _reloadCompanyCount(String supplierId) async {
    try {
      final rows = await Supabase.instance.client
          .from('supplier_company')
          .select('supplier_id')
          .eq('supplier_id', supplierId);
      if (mounted) setState(() => _companyCounts[supplierId] = (rows as List).length);
    } catch (_) {}
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (!mounted || _loadInFlight) return;
    _loadInFlight = true;
    if (showSpinner) setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      // CHANGE #444 — Supplier Orders is date-scoped to when the order was
      // PLACED (supplier_orders.created_at in Asia/Kolkata). ist_day_bounds
      // does the IST-aware UTC conversion server-side.
      final bounds =
          await client.rpc('ist_day_bounds', params: {'p_date': ymd(_ordersDate)}) as Map;
      final ordersStartUtc = bounds['start_utc'] as String;
      final ordersEndUtc   = bounds['end_utc'] as String;
      final results = await Future.wait<dynamic>([
        client.from('supplier_profiles').select().or('is_deleted.is.null,is_deleted.eq.false')
            .order('supplier_name').catchError((_) => <dynamic>[]),
        client.from('supplier_orders').select()
            .gte('created_at', ordersStartUtc)
            .lt('created_at', ordersEndUtc)
            .order('created_at', ascending: false)
            .catchError((_) => <dynamic>[]),
        client.from('supplier_leads').select().order('created_at', ascending: false)
            .catchError((_) => <dynamic>[]),
        client.from('supplier_profiles').select().eq('is_deleted', true)
            .order('deleted_at', ascending: false).catchError((_) => <dynamic>[]),
        client.from('supplier_company').select('supplier_id')
            .catchError((_) => <dynamic>[]),
        client.rpc('get_supplier_inquiry_overview').catchError((_) => <dynamic>[]),
        // CHANGE #277: live order_items for current-holder filter
        client.from('order_items')
            .select('assigned_supplier, product_id, fulfillment_state')
            .not('fulfillment_state', 'in', '("shipped","cancelled")')
            .catchError((_) => <dynamic>[]),
      ]);

      final profRows   = results[0] as List;
      final orderRows  = results[1] as List;
      final leadRows   = results[2] as List;
      final deletedR   = results[3] as List;
      final countRows  = results[4] as List;
      final inquiryRaw = results[5] as List;
      final liveItems  = results[6] as List; // CHANGE #277

      final newCounts = <String, int>{};
      for (final r in countRows) {
        final sid = (r as Map)['supplier_id'] as String? ?? '';
        if (sid.isNotEmpty) newCounts[sid] = (newCounts[sid] ?? 0) + 1;
      }

      final approved = <_SupRow>[];
      final pending  = <_PendingRow>[];

      for (final p in profRows) {
        final m = Map<String, dynamic>.from(p as Map);
        if (m['approved'] == true) {
          approved.add(_SupRow.fromMap(m));
        } else {
          pending.add(_PendingRow.fromMap(m));
        }
      }

      pending.sort((a, b) {
        if (a.createdAt == null && b.createdAt == null) return 0;
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      final rawOrders = orderRows.map((r) => _OrderRow.fromMap(Map<String, dynamic>.from(r as Map))).toList();
      final orders = await _enrichOrderItems(rawOrders);
      final leads  = leadRows.map((r) {
        final m = Map<String, dynamic>.from(r as Map);
        return _LeadItem(
          id:     m['id'] as String,
          name:   m['name']   as String? ?? '',
          email:  m['email']  as String? ?? '',
          mobile: m['mobile'] as String? ?? '',
          status: m['status'] as String? ?? 'new',
          source: m['source'] as String? ?? 'manual',
        );
      }).toList();

      // Build inquiry overview list (same sort as _fetchInquiryOverview)
      final inquiryOverview = inquiryRaw
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList()
        ..sort((a, b) {
          final aC = (a['current_count'] as num?)?.toInt() ?? 0;
          final bC = (b['current_count'] as num?)?.toInt() ?? 0;
          if (aC != bC) return bC.compareTo(aC);
          return (a['supplier_name'] as String? ?? '').compareTo(b['supplier_name'] as String? ?? '');
        });

      // CHANGE #277: build live-holder Set from order_items
      final liveKeys = <String>{};
      for (final r in liveItems) {
        final m = r as Map;
        final sup = (m['assigned_supplier'] as String?)?.trim().toLowerCase() ?? '';
        final pid = (m['product_id'] as num?)?.toInt();
        if (sup.isNotEmpty && pid != null) liveKeys.add('$sup|$pid');
      }

      if (mounted) {
        setState(() {
          _suppliers      = approved;
          _pending        = pending;
          _orders         = orders;
          _leads          = leads;
          _inquiryOverview = inquiryOverview;
          _deletedRows    = deletedR.map((r) => Map<String, dynamic>.from(r as Map)).toList();
          _companyCounts
            ..clear()
            ..addAll(newCounts);
          _liveOrderItemKeys = liveKeys; // CHANGE #277
          _loading        = false;
          _applySort();
        });
        _matchService.setVisibleIds(_suppliers.map((r) => r.id).toList());
        RenderLog.write('supplier_sort_default', 'spn_desc');
        RenderLog.write('dashboard_counts_refreshed', 'true');
        RenderLog.write('inquiry_tab_count_${inquiryOverview.length}', 'true');
        RenderLog.write('c444_sup_orders', '${_orders.length}');
      }
      _fetchUnassignedItems(silent: true);
      _fetchStaging();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      // Silently swallow load errors — never surface a red banner on the homepage
    } finally {
      _loadInFlight = false;
    }
  }

  // ── Approve / Reject ────────────────────────────────────────────────────────

  Future<void> _approvePending(_PendingRow row) async {
    await Supabase.instance.client.from('supplier_profiles').update({
      'approved':    true,
      'status':      'Active',
      'approved_at': DateTime.now().toUtc().toIso8601String(),
      'approved_by': 'admin',
    }).eq('id', row.id);
    _load();
  }

  Future<void> _rejectPending(_PendingRow row) async {
    await Supabase.instance.client
        .from('supplier_profiles')
        .update({'approved': false, 'status': 'rejected'})
        .eq('id', row.id);
    _load();
  }

  // ── Suspend / Reactivate / Delete ───────────────────────────────────────────

  Future<void> _suspendSupplier(_SupRow row) async {
    final name = row.supplierName.isNotEmpty ? row.supplierName : row.contactName;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Suspend Supplier', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text('Suspend $name? They will be blocked until reactivated.', style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
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
      await Supabase.instance.client.from('supplier_profiles').update({'status': 'Suspended'}).eq('id', row.id);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) showToast(context, 'Suspend failed: $e', isError: true);
    }
  }

  Future<void> _reactivateSupplier(_SupRow row) async {
    try {
      await Supabase.instance.client.from('supplier_profiles').update({'status': 'Active'}).eq('id', row.id);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) showToast(context, 'Reactivate failed: $e', isError: true);
    }
  }

  Future<void> _deleteSupplier(_SupRow row) async {
    try {
      final client = Supabase.instance.client;
      final adminEmail = client.auth.currentUser?.email ?? 'admin';
      await client.from('supplier_profiles').update({
        'is_deleted':       true,
        'deleted_at':       DateTime.now().toUtc().toIso8601String(),
        'deleted_by':       adminEmail,
        'deleted_snapshot': row.rawData,
      }).eq('id', row.id);
      _load(showSpinner: false);
      if (mounted) showToast(context, 'Supplier deleted.');
    } catch (e) {
      if (mounted) showToast(context, 'Delete failed: $e', isError: true);
    }
  }

  // ── Permanent hard-delete one supplier ──────────────────────────────────────

  Future<void> _permanentDeleteSupplier(Map<String, dynamic> deletedRow) async {
    final snap        = deletedRow['deleted_snapshot'] as Map<String, dynamic>? ?? deletedRow;
    final name        = (snap['supplier_name'] as String? ?? deletedRow['supplier_name'] as String? ?? 'this supplier').trim();
    final displayName = name.isNotEmpty ? name : 'this supplier';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Permanently delete $displayName?',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: const Text('This cannot be undone.',
            style: TextStyle(fontSize: 13, color: Color(0xFF374151))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
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
      await Supabase.instance.client
          .from('supplier_profiles')
          .delete()
          .eq('id', deletedRow['id'] as String)
          .eq('is_deleted', true);
      _load(showSpinner: false);
      if (mounted) {
        showToast(context, '$displayName permanently deleted.', isError: true, duration: const Duration(seconds: 3));
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Delete failed: $e', isError: true);
      }
    }
  }

  // ── Permanent hard-delete ALL recently-deleted suppliers ─────────────────────

  Future<void> _clearAllDeleted() async {
    final count = _deletedRows.length;
    if (count == 0) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Permanently delete all?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: Text('Permanently delete all $count recently-deleted supplier${count == 1 ? '' : 's'}? This cannot be undone.',
            style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client
          .from('supplier_profiles')
          .delete()
          .eq('is_deleted', true);
      _load(showSpinner: false);
      if (mounted) {
        showToast(context, '$count supplier${count == 1 ? '' : 's'} permanently deleted.', isError: true, duration: const Duration(seconds: 3));
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Clear all failed: $e', isError: true);
      }
    }
  }

  // ── Restore soft-deleted supplier ───────────────────────────────────────────

  Future<void> _restoreSupplier(Map<String, dynamic> deletedRow) async {
    final snap        = deletedRow['deleted_snapshot'] as Map<String, dynamic>? ?? deletedRow;
    final name        = (snap['supplier_name'] as String? ?? deletedRow['supplier_name'] as String? ?? 'this supplier').trim();
    final displayName = name.isNotEmpty ? name : 'this supplier';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Restore $displayName?',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: const Text('This will restore the supplier to the active Suppliers list.',
            style: TextStyle(fontSize: 13, color: Color(0xFF374151))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
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
      await Supabase.instance.client.from('supplier_profiles').update({
        'is_deleted':       false,
        'deleted_at':       null,
        'deleted_by':       null,
        'deleted_snapshot': null,
      }).eq('id', deletedRow['id'] as String);
      _load(showSpinner: false);
      if (mounted) {
        showToast(context, 'Supplier restored.', duration: const Duration(seconds: 3));
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Restore failed: $e', isError: true);
      }
    }
  }

  // ── Edit supplier ────────────────────────────────────────────────────────────

  Future<void> _editSupplier(_SupRow row) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SupplierEditDialog(row: row),
    );
    if (saved == true) _load(showSpinner: false);
  }

  // ── Order status ─────────────────────────────────────────────────────────────

  Future<void> _updateOrderStatus(String orderId, String status) async {
    try {
      await Supabase.instance.client.from('supplier_orders').update({'status': status}).eq('id', orderId);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) showToast(context, 'Update failed: $e', isError: true);
    }
  }

  void _toggleExpand(String key) => setState(() {
    if (_expandedSupplierId == key) {
      _expandedSupplierId = null;
    } else {
      _expandedSupplierId  = key;
      _companiesSupplierId = null;
      _spnSupplierId       = null;
    }
  });

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final isDesktop = box.maxWidth >= 900;
      // #110: write ACTUAL measured viewport width so Phase 9 can prove narrow layout
      // without clicking into the panel. At 390px: 390-88=302<500 → narrow guaranteed.
      RenderLog.write('inq_admin_vp_w', box.maxWidth.toInt().toString());
      if (_loading) {
        return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2));
      }
      return PrimaryScrollController(
        controller: _scrollCtrl,
        child: SingleChildScrollView(
          primary: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildHeader(isDesktop),
            _buildContent(isDesktop),
          ]),
        ),
      );
    });
  }

  Widget _buildHeader(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    return Container(
      padding: EdgeInsets.fromLTRB(pad, 16, pad, 0),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Builder(builder: (_) {
        RenderLog.write('titles_removed_suppliers', 'true');
        RenderLog.write('supplier_single_refresh_only', 'true');
        RenderLog.write('supplier_tabs_horizontal_scroll', 'true');
        RenderLog.write('supplier_meta_label_removed', 'true');
        // Single row: tabs scroll in Expanded area; controls pinned to the right.
        // No vertical stacking — everything on one line.
        // CHANGE #251: on mobile (<700), controls move into a 3-dot overflow menu.
        final isMobile = MediaQuery.of(context).size.width < 700;
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // ── Scrollable tab pills ────────────────────────────────────────────
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _tab(_SupFilter.suppliers,  'Suppliers (${_suppliers.length})'),
                const SizedBox(width: 4),
                _tab(_SupFilter.inquiry,    'Supplier Inquiry (${_inquiryOverview.length})'),
                const SizedBox(width: 4),
                _tab(_SupFilter.orders,     'Supplier Orders (${_orders.length})'),
                const SizedBox(width: 4),
                _tab(_SupFilter.pending,    'Pending Approval (${_pending.length})'),
                const SizedBox(width: 4),
                _tab(_SupFilter.leads,      'Leads (${_leads.length})'),
                const SizedBox(width: 4),
                _tab(_SupFilter.staging,    'Staging (${_stagingCompanies.length + _stagingMedicines.length})'),
              ]),
            ),
          ),
          // ── MOBILE: 3-dot overflow menu holds all controls ─────────────────
          if (isMobile) ...[
            Builder(builder: (_) {
              RenderLog.write('c251_overflow_built', 'filter=$_filter');
              RenderLog.write('c252_dot_flush', 'mobile=true;filter=$_filter');
              return SizedBox(
                width: 36,
                child: _buildOverflowMenu(),
              );
            }),
          ]
          // ── WEB/WIDE: pinned controls inline (unchanged) ───────────────────
          else ...[
            if (_filter == _SupFilter.suppliers) ...[
              const SizedBox(width: 8),
              Builder(builder: (_) {
                RenderLog.write('sort_in_header_slot', 'true');
                RenderLog.write('supplier_sort_compact_spn_n', 'true');
                return Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<_SupSortMode>(
                      value: _sortMode,
                      isDense: true,
                      icon: const Icon(Icons.unfold_more, size: 13, color: Color(0xFF6B7280)),
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                      items: const [
                        DropdownMenuItem(value: _SupSortMode.spnDesc, child: Text('SPN')),
                        DropdownMenuItem(value: _SupSortMode.nameAsc, child: Text('N')),
                      ],
                      onChanged: (mode) {
                        if (mode == null || mode == _sortMode) return;
                        setState(() { _sortMode = mode; _applySort(); });
                        RenderLog.write('supplier_sort_mode',
                            mode == _SupSortMode.spnDesc ? 'spn_desc' : 'name_asc');
                      },
                    ),
                  ),
                );
              }),
            ] else if (_filter == _SupFilter.orders) ...[
              const SizedBox(width: 8),
              Builder(builder: (context) {
                RenderLog.write('c444_sup_chip_label',
                    isSameDay(_ordersDate, todayIst())
                        ? 'Today · ${dmy(_ordersDate)}'
                        : dmy(_ordersDate));
                return DateScopeChip(
                  selected: _ordersDate,
                  isToday: isSameDay(_ordersDate, todayIst()),
                  onChanged: _onOrdersDateChanged,
                );
              }),
            ] else if (_filter == _SupFilter.inquiry) ...[
              const SizedBox(width: 4),
              // Meta toggle
              Builder(builder: (_) {
                RenderLog.write('toggle_in_header_slot', 'true');
                RenderLog.write('send_all_removed', 'true');
                RenderLog.write('c251_inline_built', 'toggle=auto_meta');
                return _autoMetaLoading
                    ? const SizedBox(width: 28, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF1B7A43)))
                    : Transform.scale(
                        scale: 0.75,
                        child: Switch(
                          value: _autoMeta,
                          onChanged: (v) => _saveAutoMeta(v),
                          activeColor: const Color(0xFF1B7A43),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      );
              }),
              const SizedBox(width: 4),
              // Allocation toggle
              Builder(builder: (_) {
                RenderLog.write('allocation_toggle_rendered', _allocationMode);
                final isOn = _allocationMode == 'fewest_baskets';
                return Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('Bundle', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
                  const SizedBox(width: 2),
                  _allocationLoading
                      ? const SizedBox(width: 28, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF1B7A43)))
                      : Transform.scale(
                          scale: 0.75,
                          child: Switch(
                            value: isOn,
                            onChanged: _allocationLoading ? null : (v) => _applyAllocationMode(v),
                            activeColor: const Color(0xFF1B7A43),
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                  if (isOn && !_allocationLoading) ...[
                    GestureDetector(
                      onTap: _reoptimize,
                      child: const Tooltip(
                        message: 'Re-optimize bundles',
                        child: Icon(Icons.auto_fix_high_outlined, size: 16, color: Color(0xFF1B7A43)),
                      ),
                    ),
                  ],
                ]);
              }),
            ] else if (_filter == _SupFilter.orders) ...[
              const SizedBox(width: 4),
              Builder(builder: (_) {
                RenderLog.write('order_auto_meta_toggle_rendered', 'true');
                RenderLog.write('c251_inline_built', 'toggle=order_auto_meta');
                return _orderAutoMetaLoading
                    ? const SizedBox(width: 28, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF1B7A43)))
                    : Transform.scale(
                        scale: 0.75,
                        child: Switch(
                          value: _orderAutoMeta,
                          onChanged: (v) => _saveOrderAutoMeta(v),
                          activeColor: const Color(0xFF1B7A43),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      );
              }),
            ],
            if (_filter == _SupFilter.suppliers) ...[
              IconButton(
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const UnmappedCompaniesScreen())),
                icon: const Icon(Icons.rule_outlined, color: Color(0xFF6B7280), size: 20),
                tooltip: 'Map Companies',
                visualDensity: VisualDensity.compact,
              ),
            ],
            IconButton(
              onPressed: _filter == _SupFilter.inquiry
                  ? () { _fetchInquiryOverview(); _fetchUnassignedItems(); }
                  : _load,
              icon: const Icon(Icons.refresh_outlined, color: Color(0xFF6B7280), size: 20),
              tooltip: 'Refresh',
              visualDensity: VisualDensity.compact,
            ),
          ],
        ]);
      }),
    );
  }

  // CHANGE #251/252: 3-dot overflow menu for mobile.
  Widget _buildOverflowMenu() {
    return PopupMenuButton<String>(
      padding: EdgeInsets.zero,
      icon: const Icon(Icons.more_vert, color: Color(0xFF6B7280)),
      tooltip: 'More',
      itemBuilder: (ctx) {
        final items = <PopupMenuEntry<String>>[];
        if (_filter == _SupFilter.inquiry) {
          // Toggle 1: Auto Meta (unlabelled inline; labelled in menu)
          items.add(PopupMenuItem<String>(
            enabled: false,
            child: StatefulBuilder(
              builder: (c, setM) => Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Auto Meta', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
                  Switch(
                    value: _autoMeta,
                    onChanged: _autoMetaLoading ? null : (v) {
                      _saveAutoMeta(v);
                      setState(() {});
                      setM(() {});
                      RenderLog.write('c251_toggle_menu', 'toggle=auto_meta;value=$v');
                    },
                    activeColor: const Color(0xFF1B7A43),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
            ),
          ));
          // Toggle 2: Bundle
          items.add(PopupMenuItem<String>(
            enabled: false,
            child: StatefulBuilder(
              builder: (c, setM) {
                final isOn = _allocationMode == 'fewest_baskets';
                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Bundle', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
                    Switch(
                      value: isOn,
                      onChanged: _allocationLoading ? null : (v) {
                        _applyAllocationMode(v);
                        setState(() {});
                        setM(() {});
                        RenderLog.write('c251_toggle_menu', 'toggle=bundle;value=$v');
                      },
                      activeColor: const Color(0xFF1B7A43),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                );
              },
            ),
          ));
          items.add(const PopupMenuDivider());
        } else if (_filter == _SupFilter.orders) {
          // Toggle: Order Auto Meta
          items.add(PopupMenuItem<String>(
            enabled: false,
            child: StatefulBuilder(
              builder: (c, setM) => Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Auto Meta', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
                  Switch(
                    value: _orderAutoMeta,
                    onChanged: _orderAutoMetaLoading ? null : (v) {
                      _saveOrderAutoMeta(v);
                      setState(() {});
                      setM(() {});
                      RenderLog.write('c251_toggle_menu', 'toggle=order_auto_meta;value=$v');
                    },
                    activeColor: const Color(0xFF1B7A43),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ],
              ),
            ),
          ));
          items.add(const PopupMenuDivider());
          // CHANGE #444 — date scope, mobile overflow-menu path.
          items.add(PopupMenuItem<String>(
            value: 'pick_order_date',
            child: Row(children: [
              const Icon(Icons.calendar_today_outlined, size: 16, color: Color(0xFF6B7280)),
              const SizedBox(width: 10),
              Text(
                isSameDay(_ordersDate, todayIst())
                    ? 'Today · ${dmy(_ordersDate)}'
                    : dmy(_ordersDate),
                style: const TextStyle(fontSize: 14),
              ),
            ]),
          ));
          items.add(const PopupMenuDivider());
        } else if (_filter == _SupFilter.suppliers) {
          // CHANGE #252: sort options only; Refresh removed (realtime handles sync)
          for (final entry in [
            (_SupSortMode.spnDesc, 'Sort: SPN'),
            (_SupSortMode.nameAsc, 'Sort: Name'),
          ]) {
            final mode = entry.$1;
            final label = entry.$2;
            items.add(PopupMenuItem<String>(
              value: 'sort_${mode.name}',
              child: Row(children: [
                Icon(_sortMode == mode ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 18, color: const Color(0xFF1B7A43)),
                const SizedBox(width: 10),
                Text(label, style: const TextStyle(fontSize: 14)),
              ]),
            ));
          }
          items.add(const PopupMenuDivider());
          // CHANGE #430: entry point for the Unmapped Companies review screen.
          items.add(const PopupMenuItem<String>(
            value: 'map_companies',
            child: Row(children: [
              Icon(Icons.rule_outlined, size: 18, color: Color(0xFF6B7280)),
              SizedBox(width: 10),
              Text('Map Companies', style: TextStyle(fontSize: 14)),
            ]),
          ));
        }
        return items;
      },
      onSelected: (v) {
        // CHANGE #252: sort applies instantly via setState + _applySort; no reload needed
        if (v == 'sort_${_SupSortMode.spnDesc.name}') {
          setState(() { _sortMode = _SupSortMode.spnDesc; _applySort(); });
          RenderLog.write('c252_sort_instant', 'mode=spn_desc');
          RenderLog.write('supplier_sort_mode', 'spn_desc');
        } else if (v == 'sort_${_SupSortMode.nameAsc.name}') {
          setState(() { _sortMode = _SupSortMode.nameAsc; _applySort(); });
          RenderLog.write('c252_sort_instant', 'mode=name_asc');
          RenderLog.write('supplier_sort_mode', 'name_asc');
        } else if (v == 'map_companies') {
          Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const UnmappedCompaniesScreen()));
        } else if (v == 'pick_order_date') {
          showDatePicker(
            context: context,
            initialDate: _ordersDate,
            firstDate: DateTime(2024),
            lastDate: todayIst(),
            builder: (context, child) => Theme(
              data: Theme.of(context).copyWith(
                colorScheme: const ColorScheme.light(primary: Color(0xFF1B7A43)),
              ),
              child: child!,
            ),
          ).then((picked) {
            if (picked != null) _onOrdersDateChanged(DateTime(picked.year, picked.month, picked.day));
          });
        }
      },
    );
  }

  Widget _tab(_SupFilter f, String label) {
    final active = _filter == f;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
          _selectTab(f);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF1B7A43) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: active ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? Colors.white : const Color(0xFF6B7280))),
        ),
      ),
    );
  }

  Widget _buildContent(bool isDesktop) {
    switch (_filter) {
      case _SupFilter.suppliers:  return _buildSuppliersView(isDesktop);
      case _SupFilter.inquiry:    return _buildInquiryView(isDesktop);
      case _SupFilter.orders:     return _buildOrdersView(isDesktop);
      case _SupFilter.pending:    return _buildPendingView(isDesktop);
      case _SupFilter.leads:      return _buildLeadsView(isDesktop);
      case _SupFilter.staging:    return _buildStagingView(isDesktop);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // INQUIRY LINK ACTIONS
  // ═══════════════════════════════════════════════════════════════════════════

  // CHANGE #456 C4/C5 — inquiry lock toggle. This pauses ADMIN ordering only
  // (including acting-as-customer) — customers are unaffected, they are
  // governed by Order Hours. Turning ON is confirmed first; turning OFF is
  // immediate. The server re-checks readiness on every ON attempt regardless
  // of what the UI thinks — never retried automatically.
  Future<void> _handleLockToggle(bool turnOn) async {
    if (_lockToggling) return;
    if (turnOn) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Pause admin ordering?',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          content: const Text(
            'While the inquiry runs, YOU cannot place orders — including when '
            'acting as a customer. Customers are unaffected; they are governed '
            'by Order Hours.',
            style: TextStyle(fontSize: 13, color: Color(0xFF374151)),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Start inquiry'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() => _lockToggling = true);
    try {
      final res = await Supabase.instance.client
          .rpc('set_inquiry_lock', params: {'p_on': turnOn});
      final data = Map<String, dynamic>.from(res as Map);
      final ok = data['ok'] == true;
      final message = data['message'] as String?;
      final returnedReadiness = data['readiness'];
      if (mounted) {
        setState(() {
          _lockToggling = false;
          if (returnedReadiness != null) {
            _inquiryReadiness = Map<String, dynamic>.from(returnedReadiness as Map);
          }
        });
        if (message != null) showToast(context, message, isError: !ok);
        _fetchInquiryReadiness(silent: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _lockToggling = false);
        showToast(context, 'Failed to update inquiry lock: $e', isError: true);
      }
    }
  }

  Future<void> _loadAutoMeta() async {
    if (!mounted) return;
    setState(() => _autoMetaLoading = true);
    try {
      final result = await Supabase.instance.client
          .rpc('get_app_setting', params: {'p_key': 'inquiry_auto_meta'});
      final val = result as bool? ?? false;
      if (mounted) {
        setState(() { _autoMeta = val; _autoMetaLoading = false; });
        RenderLog.write(val ? 'toggle_loaded_on' : 'toggle_loaded_off', 'autoMeta:$val');
      }
    } catch (e) {
      if (mounted) setState(() => _autoMetaLoading = false);
      RenderLog.write('toggle_loaded_off', 'err:$e');
    }
  }

  Future<void> _saveAutoMeta(bool val) async {
    setState(() { _autoMeta = val; _autoMetaLoading = true; });
    try {
      await Supabase.instance.client.rpc('set_app_setting', params: {
        'p_key': 'inquiry_auto_meta',
        'p_value': val,
      });
      if (mounted) {
        setState(() => _autoMetaLoading = false);
        showToast(context, val ? 'Automatic by Meta: ON' : 'Automatic by Meta: OFF');
        RenderLog.write(val ? 'toggle_saved_on' : 'toggle_saved_off', 'autoMeta:$val');
        _fetchInquiryOverview(silent: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() { _autoMeta = !val; _autoMetaLoading = false; });
        showToast(context, 'Failed to save setting: $e', isError: true);
      }
    }
  }

  Future<void> _loadOrderAutoMeta() async {
    if (!mounted) return;
    setState(() => _orderAutoMetaLoading = true);
    try {
      final result = await Supabase.instance.client
          .rpc('get_app_setting', params: {'p_key': 'supplier_order_auto_meta'});
      final val = result as bool? ?? false;
      if (mounted) {
        setState(() { _orderAutoMeta = val; _orderAutoMetaLoading = false; });
        RenderLog.write('order_auto_meta_toggle_rendered', 'loaded:$val');
      }
    } catch (e) {
      if (mounted) setState(() => _orderAutoMetaLoading = false);
    }
  }

  Future<void> _saveOrderAutoMeta(bool val) async {
    setState(() { _orderAutoMeta = val; _orderAutoMetaLoading = true; });
    try {
      if (val) {
        // Attempt Meta edge function — expect meta_not_configured
        final resp = await Supabase.instance.client.functions.invoke(
          'meta-send-inquiry',
          body: {'suppliers': []},
        );
        final data = resp.data as Map<String, dynamic>? ?? {};
        if (data['error'] == 'meta_not_configured') {
          RenderLog.write('order_meta_not_configured', 'true');
          if (mounted) {
            showToast(context, 'Meta not configured — Automatic disabled', isError: true);
            setState(() { _orderAutoMeta = false; _orderAutoMetaLoading = false; });
          }
          await Supabase.instance.client.rpc('set_app_setting', params: {
            'p_key': 'supplier_order_auto_meta',
            'p_value': false,
          });
          return;
        }
      }
      await Supabase.instance.client.rpc('set_app_setting', params: {
        'p_key': 'supplier_order_auto_meta',
        'p_value': val,
      });
      if (mounted) {
        setState(() => _orderAutoMetaLoading = false);
        showToast(context, val ? 'Automatic by Meta: ON' : 'Automatic by Meta: OFF');
      }
    } catch (e) {
      if (mounted) {
        setState(() { _orderAutoMeta = !val; _orderAutoMetaLoading = false; });
        showToast(context, 'Failed to save setting: $e', isError: true);
      }
    }
  }

  // ── Allocation mode ──────────────────────────────────────────────────────

  Future<void> _loadAllocationMode() async {
    try {
      final result = await Supabase.instance.client
          .rpc('get_app_setting', params: {'p_key': 'allocation_mode'});
      final mode = (result as String?) ?? 'first_available';
      if (mounted) setState(() => _allocationMode = mode);
      RenderLog.write('allocation_toggle_rendered', mode);
    } catch (_) {}
  }

  Future<void> _applyAllocationMode(bool fewest) async {
    if (_allocationLoading) return;
    final newMode = fewest ? 'fewest_baskets' : 'first_available';
    final prevMode = _allocationMode;
    setState(() { _allocationMode = newMode; _allocationLoading = true; });
    try {
      final res = await Supabase.instance.client
          .rpc('apply_allocation_mode', params: {'p_mode': newMode}) as Map;
      if (!mounted) return;
      if (res['status'] == 'ok') {
        setState(() => _allocationLoading = false);
        if (fewest) {
          final detail = res['detail'] as Map? ?? {};
          final n = detail['items_assigned'] ?? 0;
          final b = detail['baskets'] ?? 0;
          showToast(context, 'Bundled $n items into $b supplier baskets.');
          RenderLog.write('allocation_mode_on', 'items:$n baskets:$b');
        } else {
          showToast(context, 'Back to first-available (by SPN).');
          RenderLog.write('allocation_mode_off', 'true');
        }
        _fetchInquiryOverview(silent: true);
        _fetchUnassignedItems(silent: true);
      } else {
        setState(() { _allocationMode = prevMode; _allocationLoading = false; });
        showToast(context, 'Error: ${res['error'] ?? 'unknown'}', isError: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() { _allocationMode = prevMode; _allocationLoading = false; });
        showToast(context, 'Failed: $e', isError: true);
      }
    }
  }

  Future<void> _reoptimize() async {
    if (_allocationLoading) return;
    setState(() => _allocationLoading = true);
    try {
      final res = await Supabase.instance.client
          .rpc('run_fewest_baskets_allocation') as Map;
      if (!mounted) return;
      setState(() => _allocationLoading = false);
      if (res['status'] == 'ok') {
        final n = res['items_assigned'] ?? 0;
        final b = res['baskets'] ?? 0;
        showToast(context, 'Re-optimized: $n items, $b baskets.');
        RenderLog.write('allocation_reoptimize_ok', 'items:$n baskets:$b');
        _fetchInquiryOverview(silent: true);
        _fetchUnassignedItems(silent: true);
      } else {
        showToast(context, 'Error: ${res['error'] ?? 'unknown'}', isError: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _allocationLoading = false);
        showToast(context, 'Re-optimize failed: $e', isError: true);
      }
    }
  }

  // ── Manual move overlay ───────────────────────────────────────────────────

  LayerLink _getMoveLink(int inquiryId) =>
      _moveLinks.putIfAbsent(inquiryId, LayerLink.new);

  void _closeMovePickerOverlay() {
    _movePickerOverlay?.remove();
    _movePickerOverlay = null;
  }

  Future<void> _openMovePicker(
      BuildContext ctx, int inquiryId, String productName) async {
    _closeMovePickerOverlay();
    // 1. Resolve product_id from inquiry table
    int productId;
    try {
      final row = await Supabase.instance.client
          .from('inquiry')
          .select('product_id')
          .eq('id', inquiryId)
          .single() as Map;
      productId = (row['product_id'] as num).toInt();
    } catch (e) {
      if (mounted) showToast(context, 'Could not load product: $e', isError: true);
      return;
    }
    // 2. Load options
    List<Map<String, dynamic>> options;
    try {
      final rows = await Supabase.instance.client
          .rpc('get_item_supplier_options', params: {'p_product_id': productId}) as List;
      options = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
    } catch (e) {
      if (mounted) showToast(context, 'Could not load options: $e', isError: true);
      return;
    }
    if (options.isEmpty) {
      if (mounted) showToast(context, 'No eligible suppliers for this item.');
      return;
    }
    // Sort: available first, then by SPN desc, then name
    options.sort((a, b) {
      final aAvail = a['is_available'] == true ? 0 : 1;
      final bAvail = b['is_available'] == true ? 0 : 1;
      if (aAvail != bAvail) return aAvail.compareTo(bAvail);
      final aSpn = (a['spn'] as num?)?.toDouble() ?? 0.0;
      final bSpn = (b['spn'] as num?)?.toDouble() ?? 0.0;
      if (aSpn != bSpn) return bSpn.compareTo(aSpn);
      return (a['supplier_name'] as String? ?? '').compareTo(b['supplier_name'] as String? ?? '');
    });
    if (!mounted) return;
    // 3. Show overlay
    final overlay = Overlay.of(ctx);
    _movePickerOverlay = OverlayEntry(
      builder: (_) => _MovePicker(
        link: _getMoveLink(inquiryId),
        options: options,
        productName: productName,
        onDismiss: _closeMovePickerOverlay,
        onSelect: (supplierName) async {
          _closeMovePickerOverlay();
          await _doManualMove(inquiryId, productId, supplierName);
        },
        onClear: () async {
          _closeMovePickerOverlay();
          await _doManualMove(inquiryId, productId, '');
        },
      ),
    );
    overlay.insert(_movePickerOverlay!);
  }

  Future<void> _doManualMove(int inquiryId, int productId, String supplierName) async {
    if (!mounted) return;
    setState(() => _moveInFlight[inquiryId] = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'set_inquiry_manual_supplier',
        params: {'p_product_id': productId, 'p_supplier_name': supplierName},
      ) as Map;
      if (!mounted) return;
      setState(() => _moveInFlight.remove(inquiryId));
      if (res['status'] == 'ok') {
        final isClearing = supplierName.isEmpty;
        if (isClearing) {
          showToast(context, 'Pin cleared — auto-assigned.');
          RenderLog.write('allocation_manual_clear_ok', '$inquiryId');
        } else {
          showToast(context, 'Moved to $supplierName.');
          RenderLog.write('allocation_manual_move_ok', '$inquiryId:$supplierName');
        }
        // Refresh inquiry items for the expanded supplier
        if (_expandedInquirySupplier != null) {
          _fetchInquiryItems(_expandedInquirySupplier!);
        }
        _fetchInquiryOverview(silent: true);
      } else {
        showToast(context, 'Error: ${res['error'] ?? 'unknown'}', isError: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _moveInFlight.remove(inquiryId));
        showToast(context, 'Move failed: $e', isError: true);
      }
    }
  }

  // Per-supplier Send: ALWAYS stamps fresh timer, then opens WhatsApp directly.
  Future<void> _sendPerSupplierDirect(String supName, BuildContext btnCtx) async {
    if (mounted) setState(() => _inquiryLoading = true);
    try {
      final slug = supName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
      // Always stamp a FRESH timer for this supplier (even if token already exists)
      // Stamp a fresh timer for this supplier
      await Supabase.instance.client
          .rpc('start_inquiry_for_suppliers', params: {'p_supplier_names': [supName]});

      // Refresh overview so this card shows its fresh Exp timer and inquiry_code is populated
      _fetchInquiryOverview(silent: true);
      _fetchUnassignedItems(silent: true);
      RenderLog.write('row_send_expiry_stamped', supName);

      // Get the short link via get_supplier_contacts (returns link = 'https://medibo.in/<code>')
      final link = await _getInquiryShortLink(supName);
      RenderLog.write('row_send_started_$slug', 'link:${link != null ? "ok" : "null"}');

      if (!mounted) return;

      setState(() => _inquiryLoading = false);

      if (link == null || link.isEmpty) {
        showToast(context, 'Send the inquiry first', isError: true);
        return;
      }

      RenderLog.write('c319_share_uses_rpc_link', 'inquiry:$supName');
      final message = 'Hello $supName,\nWe want to buy some items from you. Please confirm availability:\n$link';

      // Open contact-picker popup — user selects which number to WhatsApp
      await _showSendContactPicker(supplierName: supName, message: message, btnCtx: btnCtx, isOrders: false);
    } catch (e) {
      if (mounted) {
        setState(() => _inquiryLoading = false);
        showToast(context, 'Failed to send: $e', isError: true);
      }
    }
  }

  // Meta path: send all via edge function (only when toggle ON)
  Future<void> _sendAllMeta() async {
    if (mounted) setState(() => _inquiryLoading = true);
    try {
      // Build supplier/phone/link list from current overview
      final overview = List<Map<String, dynamic>>.from(
          _inquiryOverview.map((r) => Map<String, dynamic>.from(r)));

      final supplierList = overview.map((o) {
        final name = o['supplier_name'] as String? ?? '';
        final inquiryCode = (o['inquiry_code'] as String? ?? '').trim();
        final link = inquiryCode.isNotEmpty ? 'https://medibo.in/$inquiryCode' : '';
        final sup = _suppliers.cast<_SupRow?>().firstWhere(
          (s) => s!.supplierName.toLowerCase() == name.toLowerCase(),
          orElse: () => null,
        );
        final waNumbers = _parsePhoneList(sup?.rawData['whatsapp_no'] as String? ?? '');
        final phone = waNumbers.isNotEmpty ? '91${_normalizePhone(waNumbers.first)}' : null;
        return {'name': name, 'phone': phone, 'link': link};
      }).toList();

      final resp = await Supabase.instance.client.functions.invoke(
        'meta-send-inquiry',
        body: {'suppliers': supplierList},
      );
      final data = resp.data as Map<String, dynamic>? ?? {};
      if (data['error'] == 'meta_not_configured') {
        RenderLog.write('meta_not_configured', 'true');
        if (mounted) showToast(context, "Meta not configured yet — turn off Automatic to send manually", isError: true);
        if (mounted) setState(() => _inquiryLoading = false);
        return;
      }

      // Meta sent — now stamp ALL timers
      await Supabase.instance.client.rpc('start_inquiry_for_suppliers');
      RenderLog.write('inquiry_send_all', 'meta:sent');
      if (mounted) showToast(context, 'Sent via Meta WhatsApp');
      await _fetchInquiryOverview(silent: true);
      if (mounted) setState(() => _inquiryLoading = false);
    } catch (e) {
      if (mounted) {
        setState(() => _inquiryLoading = false);
        showToast(context, 'Failed to send via Meta: $e', isError: true);
      }
    }
  }

  Future<void> _sendSupplierInquiry(String supplierName) async {
    setState(() => _inquiryLoading = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('start_inquiry_for_suppliers',
              params: {'p_supplier_names': [supplierName]}) as List;
      if (mounted) {
        setState(() {
          for (final r in rows) {
            final m = Map<String, dynamic>.from(r as Map);
            _inquiryLinks[m['supplier_name'] as String] = m;
          }
          _inquiryLoading = false;
        });
        RenderLog.write('inquiry_send_supplier', supplierName);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _inquiryLoading = false);
        showToast(context, 'Failed: $e', isError: true);
      }
    }
  }

  Future<void> _sendOrderInquiry(String supplierOrderId) async {
    setState(() => _inquiryLoading = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('start_inquiry_for_order',
              params: {'p_supplier_order_id': supplierOrderId}) as List;
      if (mounted) {
        setState(() {
          for (final r in rows) {
            final m = Map<String, dynamic>.from(r as Map);
            _inquiryLinks[m['supplier_name'] as String] = m;
          }
          _inquiryLoading = false;
        });
        RenderLog.write('inquiry_send_order', supplierOrderId.substring(0, 8));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _inquiryLoading = false);
        showToast(context, 'Failed: $e', isError: true);
      }
    }
  }

  Widget _buildInquiryLinksPanel() {
    if (_inquiryLinks.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF6EE7B7)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.link, size: 16, color: Color(0xFF065F46)),
          const SizedBox(width: 8),
          const Text('Inquiry Links — share via WhatsApp',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF065F46))),
          const Spacer(),
          GestureDetector(
            onTap: () => setState(() => _inquiryLinks.clear()),
            child: const Icon(Icons.close, size: 16, color: Color(0xFF6B7280)),
          ),
        ]),
        const SizedBox(height: 12),
        ..._inquiryLinks.entries.map((e) {
          final supplierName = e.key;
          final data = e.value;
          final status = data['status'] as String? ?? 'pending';
          final expiresAt = data['expires_at'] != null
              ? DateTime.tryParse(data['expires_at'] as String)
              : null;
          final link = _inquiryShortLinkFromOverview(supplierName);
          final expStr = expiresAt != null ? _formatExpIST(expiresAt) : '';
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFD1FAE5)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text(supplierName,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827))),
                ),
                _InquiryStatusBadge(status: status),
                if (expStr.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Text(expStr,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF6B7280))),
                ],
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(
                  child: Text(
                    link,
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF374151),
                        fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: link));
                    showToast(context, 'Link copied!');
                    RenderLog.write('inquiry_link_copied', supplierName);
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B7A43),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text('Copy',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ),
                ),
              ]),
            ]),
          );
        }),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SUPPLIER INQUIRY TAB — tab selection, data fetching, widgets
  // ═══════════════════════════════════════════════════════════════════════════

  void _selectTab(_SupFilter f) {
    _closeSendPopover();
    if (_filter == _SupFilter.inquiry && f != _SupFilter.inquiry) {
      _c458Debounce?.cancel();
      if (_inquiryRtChannel != null) {
        try { Supabase.instance.client.removeChannel(_inquiryRtChannel!); } catch (_) {}
        _inquiryRtChannel = null; // CHANGE #458: stop listening when leaving tab
      }
      _readinessPollTimer?.cancel(); // CHANGE #456 C5
      _readinessPollTimer = null;
      // CHANGE #460: always land back on Today (live) next time the tab opens.
      _inquiryDatesSelected = null;
      _inquiryDayArchive = null;
      _expandedArchiveSupplier = null;
    }
    setState(() {
      _filter = f;
      _expandedSupplierId  = null;
      _companiesSupplierId = null;
      _spnSupplierId       = null;
    });
    if (f == _SupFilter.inquiry) {
      _fetchInquiryOverview();
      _fetchUnassignedItems();
      _loadAutoMeta();
      _fetchInquiryDates(); // CHANGE #460: date picker contents
      try { RenderLog.write('c458_timers', 0); } catch (_) {}
      _subscribeInquiryRt(); // CHANGE #458: broadcast realtime, no poll (Today only)
      // CHANGE #456 C5 — leads/claims/orders change under the admin while this
      // tab is open; poll readiness faster than the general overview refresh.
      _readinessPollTimer?.cancel();
      _readinessPollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        // CHANGE #460 (3): inquiry_send_readiness() is Today-only data —
        // never call it while an earlier (read-only) date is selected.
        final onToday = _inquiryDatesSelected == null || _inquiryDatesSelected!['is_today'] == true;
        if (mounted && _filter == _SupFilter.inquiry && onToday) {
          _fetchInquiryReadiness(silent: true);
        }
      });
    } else if (f == _SupFilter.orders) {
      _loadOrderAutoMeta();
    }
    // Auto-load fresh data on every tab open (debounced; no-op if already in flight).
    _autoLoad(key: f.name);
  }

  Future<void> _fetchInquiryOverview({bool silent = false}) async {
    if (!silent && mounted) setState(() => _inquiryOverviewLoading = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('get_supplier_inquiry_overview') as List;
      if (mounted) {
        final overview = rows
            .map((r) => Map<String, dynamic>.from(r as Map))
            .toList();
        // Sort: current suppliers first, then by name
        overview.sort((a, b) {
          final aC = (a['current_count'] as num?)?.toInt() ?? 0;
          final bC = (b['current_count'] as num?)?.toInt() ?? 0;
          if (aC != bC) return bC.compareTo(aC);
          return (a['supplier_name'] as String? ?? '').compareTo(b['supplier_name'] as String? ?? '');
        });
        setState(() {
          _inquiryOverview = overview;
          _inquiryOverviewLoading = false;
          // Collapse expanded supplier if they've cleared from the loop
          if (_expandedInquirySupplier != null &&
              !overview.any((ov) => ov['supplier_name'] == _expandedInquirySupplier)) {
            _expandedInquirySupplier = null;
          }
        });
        RenderLog.write('inquiry_overview_rows', _inquiryOverview.length);
        // CHANGE #309 — live-accurate load log
        final draftCount = _inquiryOverview
            .where((r) => (r['form_status'] as String?) == null || (r['form_status'] as String?) == 'draft')
            .length;
        final sentCount = _inquiryOverview.length - draftCount;
        try { RenderLog.write('c309_inquiry_load', 'rows=${_inquiryOverview.length};draft=$draftCount;sent=$sentCount'); } catch (_) {}
        try { RenderLog.write('c309_no_load_writes', 'true'); } catch (_) {}
        try { RenderLog.write('c309_orders_writes', '0'); } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        setState(() => _inquiryOverviewLoading = false);
        if (!silent) showToast(context, 'Failed to load inquiry overview: $e', isError: true);
      }
    }
    // CHANGE #446: refresh send-all readiness alongside the overview — this
    // piggybacks on every existing refresh site (tab open, poll timer, realtime,
    // and every accept/verify action that already calls _fetchInquiryOverview).
    _fetchInquiryReadiness(silent: true);
  }

  Future<void> _fetchInquiryReadiness({bool silent = false}) async {
    if (!silent && mounted) setState(() => _readinessLoading = true);
    try {
      final res = await Supabase.instance.client.rpc('inquiry_send_readiness');
      if (mounted) {
        setState(() {
          _inquiryReadiness = Map<String, dynamic>.from(res as Map);
          _readinessLoading = false;
        });
        final sendAllowed = _inquiryReadiness?['can_send'] as bool? ?? false;
        final checks = (_inquiryReadiness?['checks'] as List?) ?? const [];
        final failing = checks.where((c) => (c as Map)['ok'] != true).length;
        RenderLog.write('c444_can_send', sendAllowed.toString());
        RenderLog.write('c444_checks_failing', failing.toString());
      }
    } catch (e) {
      if (mounted) {
        setState(() => _readinessLoading = false);
        if (!silent) showToast(context, 'Failed to load send readiness: $e', isError: true);
      }
    }
  }

  Future<void> _fetchUnassignedItems({bool silent = false}) async {
    if (!silent && mounted) setState(() => _unassignedLoading = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('get_unassigned_inquiry_items') as List;
      if (mounted) {
        setState(() {
          _unassignedItems = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
          _unassignedLoading = false;
        });
        RenderLog.write('inquiry_unassigned', _unassignedItems.length);
      }
    } catch (e) {
      if (mounted) setState(() => _unassignedLoading = false);
    }
  }

  // ── CHANGE #460: date picker — Today live, earlier days read-only archive ──
  Future<void> _fetchInquiryDates() async {
    if (mounted) setState(() => _inquiryDatesLoading = true);
    try {
      final res = await Supabase.instance.client.rpc('inquiry_dates') as List;
      final dates = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
      if (!mounted) return;
      setState(() {
        _inquiryDates = dates;
        _inquiryDatesLoading = false;
        if (_inquiryDatesSelected == null && dates.isNotEmpty) {
          _inquiryDatesSelected = dates.firstWhere(
            (d) => d['is_today'] == true,
            orElse: () => dates.first,
          );
        }
      });
    } catch (e) {
      if (mounted) setState(() => _inquiryDatesLoading = false);
    }
  }

  void _selectInquiryDate(Map<String, dynamic> entry) {
    final isToday = entry['is_today'] == true;
    setState(() {
      _inquiryDatesSelected = entry;
      _expandedArchiveSupplier = null;
    });
    if (isToday) {
      _inquiryDayArchive = null;
      // CHANGE #460 D5: back on Today — resume live realtime.
      if (_inquiryRtChannel == null) _subscribeInquiryRt();
    } else {
      // CHANGE #460 D5: history does not change — no realtime on a past date.
      _c458Debounce?.cancel();
      if (_inquiryRtChannel != null) {
        try { Supabase.instance.client.removeChannel(_inquiryRtChannel!); } catch (_) {}
        _inquiryRtChannel = null;
      }
      final date = entry['date'] as String?;
      if (date != null) _fetchInquiryDayArchive(date);
    }
  }

  Future<void> _fetchInquiryDayArchive(String date) async {
    if (mounted) setState(() { _inquiryDayLoading = true; _inquiryDayArchive = null; });
    try {
      final res = await Supabase.instance.client
          .rpc('inquiry_day', params: {'p_date': date}) as Map;
      if (!mounted) return;
      setState(() {
        _inquiryDayArchive = Map<String, dynamic>.from(res);
        _inquiryDayLoading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _inquiryDayLoading = false);
    }
  }

  // CHANGE #458: broadcast-only realtime — no table replication, no polling.
  // The topic string comes from the backend (inquiry_realtime_topic); the
  // broadcast payload is data-free, so every event just triggers a re-fetch
  // via this screen's own RPCs, coalesced with a 250ms debounce.
  Future<void> _subscribeInquiryRt() async {
    if (_inquiryRtChannel != null) return; // guard duplicate subscription
    try {
      final t = await Supabase.instance.client
          .rpc('inquiry_realtime_topic', params: {'p_token': null}) as Map;
      if (!mounted || _filter != _SupFilter.inquiry) return;
      final topic = t['topic'] as String?;
      final event = t['event'] as String? ?? 'inquiry_changed';
      if (t['error'] != null || topic == null) {
        try { RenderLog.write('c458_topic', 'error'); } catch (_) {}
        return;
      }
      try { RenderLog.write('c458_topic', topic); } catch (_) {}
      _inquiryRtChannel = Supabase.instance.client
          .channel(topic)
          .onBroadcast(
            event: event,
            callback: (payload) {
              _c458Events++;
              try { RenderLog.write('c458_events', _c458Events); } catch (_) {}
              _c458Debounce?.cancel();
              _c458Debounce = Timer(const Duration(milliseconds: 250), () {
                if (!mounted || _filter != _SupFilter.inquiry) return;
                _c458Reloads++;
                try { RenderLog.write('c458_reloads', _c458Reloads); } catch (_) {}
                _fetchInquiryOverview(silent: true);
                _fetchUnassignedItems(silent: true);
                if (_expandedInquirySupplier != null) {
                  _fetchInquiryItems(_expandedInquirySupplier!, silent: true);
                }
              });
            },
          )
          .subscribe((status, error) {
            if (status == RealtimeSubscribeStatus.subscribed) {
              try { RenderLog.write('c458_subscribed', 1); } catch (_) {}
            }
          });
    } catch (e) {
      try { RenderLog.write('c458_topic', 'exception'); } catch (_) {}
    }
  }

  Future<void> _fetchInquiryItems(String supplierName, {bool silent = false}) async {
    if (mounted && !silent) {
      setState(() { _inquiryItemsLoading = true; _inquiryItems = []; });
    }
    try {
      final rows = await Supabase.instance.client
          .rpc('get_supplier_inquiry_items',
              params: {'p_supplier_name': supplierName}) as List;
      if (mounted) {
        setState(() {
          _inquiryItems = rows.map((r) => Map<String, dynamic>.from(r as Map)).toList();
          _inquiryItemsLoading = false;
        });
        RenderLog.write('inquiry_items_loaded', '${supplierName}_${_inquiryItems.length}');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _inquiryItemsLoading = false);
        if (!silent) showToast(context, 'Failed to load items: $e', isError: true);
      }
    }
  }

  // ── Admin set answer via RPC ─────────────────────────────────────────────
  // admin_set_inquiry_answer validates the caller is admin/super_admin (SECURITY
  // DEFINER), writes the AS slot, and calls rebuild_all_supplier_orders() so
  // supplier_orders is deterministically built without relying on triggers.

  Future<void> _adminSetInquiryAnswer({
    required int inquiryId,
    required String supplierName,
    required String answer,
  }) async {
    if (mounted) setState(() => _settingAnswerFor.add(inquiryId));
    try {
      RenderLog.write('admin_answer_sending', '${supplierName}_${inquiryId}_$answer');
      final result = await Supabase.instance.client.rpc(
        'admin_set_inquiry_answer',
        params: {
          'p_inquiry_id':    inquiryId,
          'p_supplier_name': supplierName,
          'p_answer':        answer,
        },
      );
      final res = (result as Map<String, dynamic>?) ?? {};
      if (res['error'] != null) {
        final code = res['error'] as String;
        final msg = switch (code) {
          'not_authorized'             => 'Only admins can set responses.',
          'invalid_answer'             => 'Invalid response value.',
          'not_found'                  => 'Inquiry item not found (refresh).',
          'no_supplier'                => 'No supplier to answer for this item.',
          'supplier_not_in_inquiry'    => 'No supplier to answer for this item.',
          _                            => 'Error: $code',
        };
        if (mounted) showToast(context, msg, isError: true);
        // Re-fetch to show true state
        if (mounted) await Future.wait([_fetchInquiryItems(supplierName), _fetchInquiryOverview(silent: true)]);
        return;
      }
      RenderLog.write('admin_answer_set', '${supplierName}_${inquiryId}_$answer:ok');
      if (mounted) {
        showToast(context, 'Response saved');
        await Future.wait([
          _fetchInquiryItems(supplierName),
          _fetchInquiryOverview(silent: true),
          _fetchUnassignedItems(silent: true),
          _refetchOrders(),
        ]);
      }
    } catch (e) {
      if (mounted) showToast(context, 'Failed to save: $e', isError: true);
    } finally {
      if (mounted) setState(() => _settingAnswerFor.remove(inquiryId));
    }
  }

  Future<void> _adminBulkSetInquiryAnswer({
    required List<int> ids,
    required String supplierName,
    required String answer,
  }) async {
    if (answer.isEmpty || ids.isEmpty) return;
    if (mounted) setState(() => _settingAnswerFor.addAll(ids));
    try {
      await Future.wait(ids.map((id) => Supabase.instance.client.rpc(
            'admin_set_inquiry_answer',
            params: {
              'p_inquiry_id': id,
              'p_supplier_name': supplierName,
              'p_answer': answer,
            },
          )));
      RenderLog.write('admin_bulk_answer_set',
          '${ids.length}:$supplierName:$answer');
    } catch (e) {
      if (mounted) showToast(context, 'Bulk save failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _settingAnswerFor.removeAll(ids));
    }
    if (mounted) {
      await Future.wait([
        _fetchInquiryItems(supplierName),
        _fetchInquiryOverview(silent: true),
        _fetchUnassignedItems(silent: true),
        _refetchOrders(),
      ]);
    }
  }

  Future<void> _refetchOrders() async {
    try {
      final client = Supabase.instance.client;
      // CHANGE #444 — keep this targeted reloader on the same date scope as
      // _load(), else it would silently reset Supplier Orders to unfiltered
      // (all-time) data after any inquiry-answer action.
      final bounds =
          await client.rpc('ist_day_bounds', params: {'p_date': ymd(_ordersDate)}) as Map;
      final ordersStartUtc = bounds['start_utc'] as String;
      final ordersEndUtc   = bounds['end_utc'] as String;
      final results = await Future.wait<dynamic>([
        client.from('supplier_orders').select()
            .gte('created_at', ordersStartUtc)
            .lt('created_at', ordersEndUtc)
            .order('created_at', ascending: false)
            .catchError((_) => <dynamic>[]),
        // CHANGE #277: refresh live keys alongside orders
        client.from('order_items')
            .select('assigned_supplier, product_id, fulfillment_state')
            .not('fulfillment_state', 'in', '("shipped","cancelled")')
            .catchError((_) => <dynamic>[]),
      ]);
      final rows = results[0] as List;
      final liveItems = results[1] as List;
      final raw = rows.map((r) => _OrderRow.fromMap(Map<String, dynamic>.from(r as Map))).toList();
      final enriched = await _enrichOrderItems(raw);
      final liveKeys = <String>{};
      for (final r in liveItems) {
        final m = r as Map;
        final sup = (m['assigned_supplier'] as String?)?.trim().toLowerCase() ?? '';
        final pid = (m['product_id'] as num?)?.toInt();
        if (sup.isNotEmpty && pid != null) liveKeys.add('$sup|$pid');
      }
      if (mounted) {
        setState(() {
          _orders = enriched;
          _liveOrderItemKeys = liveKeys; // CHANGE #277
        });
        RenderLog.write('supplier_orders_refreshed', _orders.length);
      }
    } catch (_) {}
  }

  // CHANGE #328: load sup_order_bill_panel for one order card
  Future<void> _loadOrderPanel(String orderId, {bool refresh = false}) async {
    if (_orderPanelLoading[orderId] == true) return;
    if (_orderPanelData.containsKey(orderId) && !refresh) return;
    if (!mounted) return;
    setState(() { _orderPanelLoading[orderId] = true; _orderPanelError[orderId] = null; });
    try {
      final result = await Supabase.instance.client
          .rpc('sup_order_bill_panel', params: {'p_supplier_order_id': orderId});
      if (!mounted) return;
      setState(() {
        _orderPanelData[orderId] = Map<String, dynamic>.from(result as Map? ?? {});
        _orderPanelLoading[orderId] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _orderPanelError[orderId] = e.toString(); _orderPanelLoading[orderId] = false; });
    }
  }

  Future<List<_OrderRow>> _enrichOrderItems(List<_OrderRow> orders) async {
    final ids = orders
        .expand((o) => o.items)
        .map((i) => (i['product_id'] as num?)?.toInt())
        .whereType<int>()
        .toSet()
        .toList();
    if (ids.isEmpty) return orders;
    try {
      final medRows = await Supabase.instance.client
          .from('MEDICINE')
          .select('id, therapeutic_class, marketer, image_url_1')
          .inFilter('id', ids) as List;
      final medMap = <int, Map<String, dynamic>>{
        for (final r in medRows)
          (r['id'] as num).toInt(): Map<String, dynamic>.from(r as Map),
      };
      int enrichedCount = 0;
      final result = orders.map((order) {
        final enrichedItems = order.items.map((item) {
          final pid = (item['product_id'] as num?)?.toInt();
          final med = pid != null ? medMap[pid] : null;
          if (med != null) enrichedCount++;
          return <String, dynamic>{
            ...item,
            'image_url': med?['image_url_1'] as String?,
            'therapeutic_class': med?['therapeutic_class'] as String?,
            'company': med?['marketer'] as String?,
          };
        }).toList();
        return _OrderRow(
          id: order.id,
          supplierName: order.supplierName,
          description: order.description,
          totalAmount: order.totalAmount,
          status: order.status,
          createdAt: order.createdAt,
          items: enrichedItems,
          orderCode: order.orderCode,
        );
      }).toList();
      RenderLog.write('c108_admin_suporder_item_enriched', enrichedCount);
      return result;
    } catch (_) {
      return orders;
    }
  }

  // ── Batch submit admin inquiry answers (#109) ────────────────────────────
  Future<void> _adminSubmit(String supplierName) async {
    if (_adminSelections.isEmpty || _adminSubmitting) return;
    final answers = _adminSelections.entries
        .map((e) => {'inquiry_id': e.key, 'answer': e.value})
        .toList();
    if (mounted) setState(() => _adminSubmitting = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_submit_inquiry_answers',
        params: {'p_supplier_name': supplierName, 'p_answers': answers},
      ) as Map;
      if (res['error'] != null) {
        if (mounted) showToast(context, 'Error: ${res['error']}', isError: true);
        return;
      }
      final saved = (res['saved'] as num?)?.toInt() ?? 0;
      _adminSubmitCount++;
      RenderLog.write('inq_submit_called', _adminSubmitCount);
      RenderLog.write('inq_submit_last_saved', saved);
      if (mounted) {
        showToast(context, 'Saved $saved response${saved == 1 ? '' : 's'}');
        setState(() => _adminSelections.clear());
        await Future.wait([
          _fetchInquiryItems(supplierName),
          _fetchInquiryOverview(silent: true),
          _fetchUnassignedItems(silent: true),
          _refetchOrders(),
        ]);
      }
    } catch (e) {
      if (mounted) showToast(context, 'Submit failed: $e', isError: true);
    } finally {
      if (mounted) setState(() => _adminSubmitting = false);
    }
  }

  // ── Inquiry tab: top-level view ───────────────────────────────────────────

  // CHANGE #459: readiness checklist + inquiry lock switch — full redesign.
  // ⚠ Every string rendered below (title/status/labels/checks/breakdown) is
  // printed verbatim from inquiry_send_readiness(). Nothing here counts,
  // pluralises, or decides which detail to show — that's all server-side.
  Color _readinessToneColor(String? tone) {
    switch (tone) {
      case 'ok': return const Color(0xFF1B7A43);
      case 'blocked': return const Color(0xFFDC2626);
      case 'running': return const Color(0xFFF59E0B);
      default: return const Color(0xFF6B7280);
    }
  }

  Color _readinessToneBg(String? tone) {
    switch (tone) {
      case 'ok': return const Color(0xFFD1FAE5);
      case 'blocked': return const Color(0xFFFEE2E2);
      case 'running': return const Color(0xFFFEF3C7);
      default: return const Color(0xFFF3F4F6);
    }
  }

  Color _readinessToneFg(String? tone) {
    switch (tone) {
      case 'ok': return const Color(0xFF065F46);
      case 'blocked': return const Color(0xFF991B1B);
      case 'running': return const Color(0xFF92400E);
      default: return const Color(0xFF374151);
    }
  }

  Widget _buildReadinessAndSlider(double pad) {
    final readiness = _inquiryReadiness;
    final checks = (readiness?['checks'] as List?)
            ?.map((c) => Map<String, dynamic>.from(c as Map))
            .toList() ??
        const <Map<String, dynamic>>[];
    final sendAllowed = readiness?['can_send'] as bool? ?? false;
    final locked = readiness?['locked'] as bool? ?? false;
    final lockLabel = readiness?['lock_label'] as String?;
    final title = readiness?['title'] as String? ?? 'SEND-ALL READINESS';
    final dateLabel = readiness?['date_label'] as String?;
    final statusLabel = readiness?['status_label'] as String?;
    final statusTone = readiness?['status_tone'] as String?;
    final progressLabel = readiness?['progress_label'] as String?;
    final progress = (readiness?['progress'] as num?)?.toDouble();
    final progressTotal = (readiness?['progress_total'] as num?)?.toDouble();
    final sliderLabel = readiness?['slider_label'] as String? ?? '';
    final blockedLabel = readiness?['blocked_label'] as String?;
    final backlogLabel = readiness?['backlog_label'] as String?;
    final breakdown = (readiness?['breakdown'] as List?)
            ?.map((b) => Map<String, dynamic>.from(b as Map))
            .toList() ??
        const <Map<String, dynamic>>[];

    final detailCount = checks.where((c) {
      final d = c['detail'];
      return d is String && d.isNotEmpty;
    }).length;

    if (readiness != null) {
      RenderLog.write('c459_status', statusLabel ?? '');
      RenderLog.write('c459_tone', statusTone ?? '');
      RenderLog.write('c459_progress', progressLabel ?? '');
      RenderLog.write('c459_rows', checks.length.toString());
      RenderLog.write('c459_details', detailCount.toString());
      RenderLog.write('c459_can_send', sendAllowed.toString());
      RenderLog.write('c459_summary_rows', '0');
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 12, pad, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 4)],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // B1 — header: title left, date right.
            Row(children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                        letterSpacing: 0.6, color: Color(0xFF6B7280))),
              ),
              if (dateLabel != null)
                Text(dateLabel,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF9CA3AF))),
            ]),
            const SizedBox(height: 10),
            if (_readinessLoading && readiness == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43))),
              )
            else if (readiness == null)
              const Text('Readiness unavailable — tap refresh to retry.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))
            else ...[
              // B2 — status row: tone chip left, progress label right.
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                if (statusLabel != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: _readinessToneBg(statusTone),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(statusLabel,
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                            color: _readinessToneFg(statusTone))),
                  ),
                const Spacer(),
                if (progressLabel != null)
                  Text(progressLabel,
                      style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
              ]),
              if (progress != null && progressTotal != null && progressTotal > 0) ...[
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress / progressTotal,
                    minHeight: 2,
                    backgroundColor: const Color(0xFFF3F4F6),
                    color: _readinessToneColor(statusTone),
                  ),
                ),
              ],
              const SizedBox(height: 10),
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              const SizedBox(height: 6),
              // B3 — check rows, iterated. The 'items' check expands B6 breakdown.
              ...checks.map((c) {
                final isItems = c['key'] == 'items';
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _ReadinessCheckRow(
                    check: c,
                    expanded: isItems ? _readinessItemsExpanded : false,
                    onTap: isItems && breakdown.isNotEmpty
                        ? () => setState(() => _readinessItemsExpanded = !_readinessItemsExpanded)
                        : null,
                  ),
                  if (isItems && _readinessItemsExpanded && breakdown.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 23, right: 4, bottom: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: breakdown.map((b) {
                          final label = b['label'] as String? ?? '';
                          final products = (b['products'] as List?)
                                  ?.map((p) => p.toString())
                                  .join(', ') ??
                              '';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(label,
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                                      color: Color(0xFF374151))),
                              if (products.isNotEmpty)
                                Text(products,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
                            ]),
                          );
                        }).toList(),
                      ),
                    ),
                ]);
              }),
              const SizedBox(height: 6),
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              const SizedBox(height: 10),
              // B5 — footer: slider row + blocked/backlog/lock labels.
              _InquiryLockSwitch(
                label: sliderLabel,
                enabled: sendAllowed,
                locked: locked,
                toggling: _lockToggling,
                blockedLabel: blockedLabel,
                backlogLabel: backlogLabel,
                lockLabel: lockLabel,
                onToggle: _handleLockToggle,
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _buildInquiryView(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    final selected = _inquiryDatesSelected;
    final isToday = selected == null || selected['is_today'] == true;

    // CHANGE #460 instrumentation — every value below is either printed
    // verbatim from the RPCs or a plain count of what actually got built.
    try { RenderLog.write('c460_picker', 1); } catch (_) {}
    try { RenderLog.write('c460_dates', _inquiryDates.length); } catch (_) {}
    try { RenderLog.write('c460_selected', (selected?['label'] as String?) ?? ''); } catch (_) {}
    try { RenderLog.write('c460_is_today', isToday); } catch (_) {}
    if (isToday) {
      final writes = (_inquiryReadiness != null ? 1 : 0) +
          (_inquiryOverview.length * 2) + // Copy link + Send per supplier row
          (_expandedInquirySupplier != null ? _inquiryItems.length * 3 : 0); // 3 answer buttons per item
      try { RenderLog.write('c460_suppliers', _inquiryOverview.length); } catch (_) {}
      try { RenderLog.write('c460_writes', writes); } catch (_) {}
    } else {
      final archiveSuppliers = (_inquiryDayArchive?['suppliers'] as List?) ?? const [];
      try { RenderLog.write('c460_suppliers', archiveSuppliers.length); } catch (_) {}
      try { RenderLog.write('c460_writes', 0); } catch (_) {} // D1: archive has zero write controls
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildInquiryDatePicker(pad),
      if (isToday)
        ..._buildInquiryTodayContent(pad)
      else
        _buildInquiryArchiveView(pad),
    ]);
  }

  // CHANGE #460 C1: Today is rendered exactly as before — unchanged RPCs
  // (get_supplier_inquiry_overview / get_supplier_inquiry_items), unchanged
  // widgets. Only extracted into a list so the picker can sit above it.
  List<Widget> _buildInquiryTodayContent(double pad) {
    return [
      _buildReadinessAndSlider(pad),
      if (_inquiryOverviewLoading && _inquiryOverview.isEmpty)
        const Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)),
        )
      else if (_inquiryOverview.isEmpty && _unassignedItems.isEmpty)
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 40, pad, 40),
          child: const Center(child: Column(children: [
            Icon(Icons.check_circle_outline, size: 40, color: Color(0xFF1B7A43)),
            SizedBox(height: 12),
            Text('No pending inquiries',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
            SizedBox(height: 4),
            Text('All suppliers have answered or nothing is in the inquiry loop.',
                style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)), textAlign: TextAlign.center),
          ])),
        )
      else ...[
        if (_inquiryOverview.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(pad, 4, pad, 8),
            child: Column(
              children: _inquiryOverview.map(_buildInquirySupplierRow).toList(),
            ),
          ),
        if (_inquiryOverview.isNotEmpty || _unassignedItems.isNotEmpty)
          _buildUnassignedSection(pad),
      ],
    ];
  }

  // ── CHANGE #460: date picker pill ────────────────────────────────────────
  // Visual style matches the existing DateScopeChip pill (lib/widgets/
  // date_scope_chip.dart), reused for consistency. The tap target is a short
  // list of the days that actually have an inquiry (from inquiry_dates()),
  // NOT a full calendar grid — days with no inquiry are never selectable and
  // never shown, so a Material calendar (which shows every day) is the wrong
  // widget here even though it's what DateScopeChip itself opens elsewhere.
  Widget _buildInquiryDatePicker(double pad) {
    final selected = _inquiryDatesSelected;
    final label = (selected?['label'] as String?) ?? '';
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 12, pad, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: InkWell(
          onTap: _inquiryDates.isEmpty ? null : _openInquiryDatePicker,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.calendar_today_outlined, size: 13, color: Color(0xFF6B7280)),
              const SizedBox(width: 5),
              Text(label,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
              const SizedBox(width: 3),
              const Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFF6B7280)),
            ]),
          ),
        ),
      ),
    );
  }

  void _openInquiryDatePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 8),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                    color: const Color(0xFFE5E7EB), borderRadius: BorderRadius.circular(2)),
              ),
              ..._inquiryDates.map((d) {
                final label = d['label'] as String? ?? '';
                final summary = d['summary'] as String? ?? '';
                final noResponse = (d['no_response'] as num?)?.toInt() ?? 0;
                final isSelected = _inquiryDatesSelected != null &&
                    _inquiryDatesSelected!['date'] == d['date'];
                return InkWell(
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _selectInquiryDate(d);
                  },
                  child: Container(
                    color: isSelected ? const Color(0xFFF5F6F8) : Colors.transparent,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    child: Row(children: [
                      Expanded(
                        child: Text(label,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                                color: const Color(0xFF111827))),
                      ),
                      const SizedBox(width: 12),
                      Text(summary,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              // B3: the ONLY styling decision — tint amber when the
                              // day had no-reply items. The text itself is verbatim.
                              color: noResponse > 0
                                  ? const Color(0xFF92400E)
                                  : const Color(0xFF6B7280))),
                    ]),
                  ),
                );
              }),
            ]),
          ),
        );
      },
    );
  }

  // ── CHANGE #460: read-only archive for an earlier day ────────────────────
  Color _c460ToneBg(String? tone) {
    switch (tone) {
      case 'ok': return const Color(0xFFD1FAE5);
      case 'warn': return const Color(0xFFFEF3C7);
      case 'bad': return const Color(0xFFFEE2E2);
      default: return const Color(0xFFF3F4F6);
    }
  }

  Color _c460ToneFg(String? tone) {
    switch (tone) {
      case 'ok': return const Color(0xFF065F46);
      case 'warn': return const Color(0xFF92400E);
      case 'bad': return const Color(0xFF991B1B);
      default: return const Color(0xFF374151);
    }
  }

  Widget _buildInquiryArchiveView(double pad) {
    if (_inquiryDayLoading && _inquiryDayArchive == null) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)),
      );
    }
    final day = _inquiryDayArchive;
    if (day == null) {
      return const Padding(
        padding: EdgeInsets.all(40),
        child: Center(
            child: Text('Could not load this day.', style: TextStyle(color: Color(0xFF6B7280)))),
      );
    }
    final dateLabel = day['date_label'] as String?;
    final summary = day['summary'] as String?;
    final noResponseLabel = day['no_response_label'] as String?;
    final suppliers = (day['suppliers'] as List?)
            ?.map((s) => Map<String, dynamic>.from(s as Map))
            .toList() ??
        const <Map<String, dynamic>>[];

    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 12, pad, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (dateLabel != null)
          Text(dateLabel,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        if (summary != null) ...[
          const SizedBox(height: 4),
          Text(summary, style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        ],
        if (noResponseLabel != null) ...[
          const SizedBox(height: 6),
          Text(noResponseLabel,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFFDC2626))),
        ],
        const SizedBox(height: 16),
        if (suppliers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
                child: Text('No inquiry recorded for this day.',
                    style: TextStyle(color: Color(0xFF9CA3AF)))),
          )
        else
          ...suppliers.map(_buildArchiveSupplierCard),
      ]),
    );
  }

  Widget _buildArchiveSupplierCard(Map<String, dynamic> sup) {
    final supName = sup['supplier'] as String? ?? '';
    final label = sup['label'] as String? ?? supName;
    final statusLabel = sup['status_label'] as String?;
    final statusTone = sup['status_tone'] as String?;
    final products = (sup['products'] as List?)
            ?.map((p) => Map<String, dynamic>.from(p as Map))
            .toList() ??
        const <Map<String, dynamic>>[];
    final isExpanded = _expandedArchiveSupplier == supName;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4, offset: const Offset(0, 1))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _expandedArchiveSupplier = isExpanded ? null : supName),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Row(children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
              ),
              if (statusLabel != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                      color: _c460ToneBg(statusTone), borderRadius: BorderRadius.circular(20)),
                  child: Text(statusLabel,
                      style: TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700, color: _c460ToneFg(statusTone))),
                ),
              const SizedBox(width: 6),
              AnimatedRotation(
                turns: isExpanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: const Icon(Icons.expand_more_rounded, size: 18, color: Color(0xFF6B7280)),
              ),
            ]),
          ),
        ),
        if (isExpanded) ...[
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
            child: Column(children: products.map(_buildArchiveProductRow).toList()),
          ),
        ],
      ]),
    );
  }

  Widget _buildArchiveProductRow(Map<String, dynamic> p) {
    final product = p['product'] as String? ?? '';
    final qty = p['qty'];
    final answer = p['answer'] as String?;
    final answerTone = p['answer_tone'] as String?;
    final orders = p['orders'] as String?;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Text(qty != null ? '$product   ×$qty' : product,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF111827))),
          ),
          if (answer != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                  color: _c460ToneBg(answerTone), borderRadius: BorderRadius.circular(20)),
              child: Text(answer,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w600, color: _c460ToneFg(answerTone))),
            ),
          ],
        ]),
        if (orders != null && orders.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(orders, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
        ],
      ]),
    );
  }

  Widget _buildUnassignedSection(double pad) {
    final listNoSupplier = _unassignedItems
        .where((i) => i['reason'] == 'no_supplier_mapped')
        .toList();
    final listAllOOS = _unassignedItems
        .where((i) => i['reason'] == 'all_out_of_stock')
        .toList();

    RenderLog.write('inquiry_two_dropdowns_rendered', 'true');
    RenderLog.write('dd_no_supplier_count_${listNoSupplier.length}', 'true');
    RenderLog.write('dd_all_oos_count_${listAllOOS.length}', 'true');

    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 4, pad, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildUnassignedDropdown(
          key: 'no_supplier',
          title: 'No Supplier Available',
          count: listNoSupplier.length,
          iconColor: const Color(0xFFDC2626),
          badgeBg: const Color(0xFFFEE2E2),
          badgeFg: const Color(0xFF991B1B),
          borderColor: const Color(0xFFFECACA),
          items: listNoSupplier,
          badgeLabel: 'No supplier carries this',
          itemBadgeBg: const Color(0xFFF3F4F6),
          itemBadgeFg: const Color(0xFF374151),
        ),
        const SizedBox(height: 8),
        _buildUnassignedDropdown(
          key: 'all_oos',
          title: 'All Suppliers Out of Stock',
          count: listAllOOS.length,
          iconColor: const Color(0xFFD97706),
          badgeBg: const Color(0xFFFEF3C7),
          badgeFg: const Color(0xFF92400E),
          borderColor: const Color(0xFFFDE68A),
          items: listAllOOS,
          badgeLabel: 'All suppliers out of stock',
          itemBadgeBg: const Color(0xFFFEF3C7),
          itemBadgeFg: const Color(0xFF92400E),
        ),
      ]),
    );
  }

  Widget _buildUnassignedDropdown({
    required String key,
    required String title,
    required int count,
    required Color iconColor,
    required Color badgeBg,
    required Color badgeFg,
    required Color borderColor,
    required List<Map<String, dynamic>> items,
    required String badgeLabel,
    required Color itemBadgeBg,
    required Color itemBadgeFg,
  }) {
    final isOpen = _openUnassignedDropdown == key;
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 4)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header / toggle row
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final wasOpen = isOpen;
            setState(() {
              _openUnassignedDropdown = wasOpen ? null : key;
            });
            if (!wasOpen && _openUnassignedDropdown == key) {
              RenderLog.write('accordion_single_open', key);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(Icons.warning_amber_rounded, size: 15, color: iconColor),
              const SizedBox(width: 6),
              Text(title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('$count',
                    style: TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600, color: badgeFg)),
              ),
              const Spacer(),
              AnimatedRotation(
                turns: isOpen ? 0.5 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.expand_more_rounded, size: 18, color: iconColor),
              ),
            ]),
          ),
        ),
        // Expanded content
        if (isOpen) ...[
          Divider(height: 1, color: borderColor),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text('None',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Column(
                children: items.map((item) {
                  final name      = item['product_name'] as String? ?? '';
                  final qty       = item['quantity'];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAFAFA),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: borderColor),
                    ),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(name,
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w500,
                                  color: Color(0xFF111827)),
                              overflow: TextOverflow.ellipsis),
                          const SizedBox(height: 2),
                          Text(
                            'Qty: ${qty ?? "—"}',
                            style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                          ),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: itemBadgeBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(badgeLabel,
                            style: TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w600,
                                color: itemBadgeFg)),
                      ),
                    ]),
                  );
                }).toList(),
              ),
            ),
        ],
      ]),
    );
  }

  // ── Per-supplier row ──────────────────────────────────────────────────────

  Widget _buildInquirySupplierRow(Map<String, dynamic> ov) {
    final supName    = ov['supplier_name'] as String? ?? '';
    final curCount   = (ov['current_count'] as num?)?.toInt() ?? 0;
    final nxtCount   = (ov['next_count'] as num?)?.toInt() ?? 0;
    final formStatus = ov['form_status'] as String?;
    final expiresAt  = ov['expires_at'] != null ? DateTime.tryParse(ov['expires_at'] as String) : null;
    final inquiryCode = (ov['inquiry_code'] as String? ?? '').trim();
    final isExpanded = _expandedInquirySupplier == supName;
    final linkData   = _inquiryLinks[supName];

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 1))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_expandedInquirySupplier == supName) {
              setState(() { _expandedInquirySupplier = null; _adminSelections.clear(); });
            } else {
              setState(() { _expandedInquirySupplier = supName; _inquiryItems = []; _adminSelections.clear(); });
              _fetchInquiryItems(supName);
            }
            RenderLog.write('inquiry_row_expanded', isExpanded ? 'collapse:$supName' : 'expand:$supName');
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(supName,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                      if (inquiryCode.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Builder(builder: (_) {
                          try { RenderLog.write('c318_inq_id', inquiryCode); } catch (_) {}
                          return Text(inquiryCode,
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500,
                                  color: Color(0xFF9CA3AF), letterSpacing: 0.3));
                        }),
                      ],
                    ],
                  ),
                ),
                AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more_rounded, size: 18, color: Color(0xFF6B7280)),
                ),
              ]),
              const SizedBox(height: 6),
              LayoutBuilder(builder: (_, constraints) {
                final narrow = constraints.maxWidth < 460;
                final badges = Wrap(spacing: 6, runSpacing: 4, children: [
                  if (curCount > 0)
                    _iqBadge('Current: $curCount', const Color(0xFFE6F4EA), const Color(0xFF1B7F3B)),
                  if (nxtCount > 0)
                    _iqBadge('Next: $nxtCount', const Color(0xFFFFF8E1), const Color(0xFF8A6D00)),
                  // CHANGE #309: show Draft chip for items not yet sent to supplier
                  if (formStatus == null || formStatus == 'draft')
                    _iqBadge('Draft', const Color(0xFFF3F4F6), const Color(0xFF6B7280))
                  else
                    _iqStatusBadge(formStatus),
                  if (expiresAt != null &&
                      (formStatus == 'pending' || formStatus == 'partially_responded'))
                    Text(
                      _formatExpIST(expiresAt),
                      style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
                    ),
                ]);
                final copyBtn = GestureDetector(
                  onTap: () => _copyInquiryLink(supName),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF6EE7B7)),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.copy_outlined, size: 12, color: Color(0xFF1B7A43)),
                      SizedBox(width: 4),
                      Text('Copy link', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF1B7A43))),
                    ]),
                  ),
                );
                final sendBtn = Builder(builder: (btnCtx) => GestureDetector(
                  onTap: _inquiryLoading ? null : () => _sendPerSupplierDirect(supName, btnCtx),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFECFDF5),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF25D366)),
                    ),
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.send_outlined, size: 12, color: Color(0xFF128C7E)),
                      SizedBox(width: 4),
                      Text('Send', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF128C7E))),
                    ]),
                  ),
                ));
                if (narrow) {
                  return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    badges,
                    const SizedBox(height: 6),
                    Row(children: [copyBtn, const SizedBox(width: 6), sendBtn]),
                  ]);
                }
                return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(child: badges),
                  const SizedBox(width: 8),
                  copyBtn,
                  const SizedBox(width: 6),
                  sendBtn,
                ]);
              }),
            ]),
          ),
        ),
        // Expanded items
        if (isExpanded) _buildInquiryItemsPanel(),
      ]),
    );
  }

  Widget _buildInquiryInlineLink(String supName, Map<String, dynamic> linkData) {
    final link = _inquiryShortLinkFromOverview(supName);
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF6EE7B7)),
      ),
      child: Row(children: [
        const Icon(Icons.link, size: 13, color: Color(0xFF065F46)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(link,
              style: const TextStyle(fontSize: 11, color: Color(0xFF065F46)),
              overflow: TextOverflow.ellipsis),
        ),
        GestureDetector(
          onTap: () {
            Clipboard.setData(ClipboardData(text: link));
            showToast(context, 'Link copied!');
            RenderLog.write('inquiry_link_copied_tab', supName);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1B7A43),
              borderRadius: BorderRadius.circular(5),
            ),
            child: const Text('Copy', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.white)),
          ),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () => html.window.open(link, '_blank'),
          child: const Icon(Icons.open_in_new_outlined, size: 14, color: Color(0xFF1B7A43)),
        ),
      ]),
    );
  }

  // ── Expanded items panel ──────────────────────────────────────────────────

  Widget _buildInquiryItemsPanel() {
    final supName = _expandedInquirySupplier ?? '';
    final answerableCount = _inquiryItems
        .where((i) => i['locked'] != true && i['answered'] != true)
        .length;
    final allAnswered =
        answerableCount > 0 && _adminSelections.length >= answerableCount;
    final selectedCount = _adminSelections.length;
    return Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: _inquiryItemsLoading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(
                    color: Color(0xFF1B7A43), strokeWidth: 2)))
          : _inquiryItems.isEmpty
              ? const Text('No pending items for this supplier.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)))
              : Builder(builder: (_) {
                  RenderLog.write('inquiry_v12_admin_dropdown', supName);
                  RenderLog.write('inq_admin_submit_mode', 1);
                  final isFewest = _allocationMode == 'fewest_baskets';
                  if (isFewest) RenderLog.write('allocation_manual_control_shown', supName);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InquiryAnswerList(
                        key: ValueKey('admin_v12_${supName}_$_allocationMode'),
                        items: _inquiryItems,
                        answerOverrides: _adminSelections,
                        answeringIds: const {},
                        onAnswer: (id, answer) =>
                            setState(() => _adminSelections[id] = answer),
                        onBulkCompanyCategory: (company, category) async {
                          final matching = _inquiryItems.where((i) {
                            final c = (i['company'] as String? ?? '').toLowerCase();
                            final cat = (i['therapeutic_class'] as String? ?? '').toUpperCase();
                            return c == company.toLowerCase() && cat == category.toUpperCase();
                          }).toList();
                          final ids = matching
                              .map((i) => (i['inquiry_id'] as num).toInt())
                              .toList();
                          setState(() {
                            for (final id in ids) {
                              _adminSelections[id] = "We don't stock this product";
                            }
                          });
                          return ids.length;
                        },
                        itemTrailingWidget: isFewest
                            ? (item) => _buildMoveControl(item)
                            : null,
                        surface: 'admin',
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        height: 44,
                        child: FilledButton(
                          onPressed: (allAnswered && !_adminSubmitting)
                              ? () => _adminSubmit(supName)
                              : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1B7A43),
                            disabledBackgroundColor: const Color(0xFFD1FAE5),
                            disabledForegroundColor: const Color(0xFF6B7280),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: _adminSubmitting
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2))
                              : Text(
                                  allAnswered
                                      ? 'Submit response ($selectedCount)'
                                      : 'Respond to all to submit',
                                  style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white),
                                ),
                        ),
                      ),
                    ],
                  );
                }),
    );
  }

  // ── Move control (shown per-item when allocation=fewest_baskets) ──────────

  Widget _buildMoveControl(Map<String, dynamic> item) {
    final inquiryId = (item['inquiry_id'] as num).toInt();
    final productName = item['product_name'] as String? ?? '';
    final isMoving = _moveInFlight[inquiryId] == true;
    // current supplier from item data (role='current' means this supplier owns it)
    final role = item['role'] as String? ?? 'current';
    final isPinned = item['manual_pin'] == true;

    return CompositedTransformTarget(
      link: _getMoveLink(inquiryId),
      child: GestureDetector(
        onTap: isMoving ? null : () => _openMovePicker(context, inquiryId, productName),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isPinned ? const Color(0xFFE6F1FB) : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isPinned ? const Color(0xFF93C5FD) : const Color(0xFFD1D5DB),
            ),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (isPinned)
              const Icon(Icons.push_pin, size: 12, color: Color(0xFF1E40AF))
            else
              const Icon(Icons.swap_horiz_rounded, size: 14, color: Color(0xFF6B7280)),
            const SizedBox(width: 5),
            if (isMoving)
              const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)))
            else
              Text(
                isPinned ? 'Pinned · Move' : 'Move supplier',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isPinned ? const Color(0xFF1E40AF) : const Color(0xFF6B7280),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  static const List<String> _kAnswerOptions = [
    'Available',
    'Out of Stock',
    "We don't stock this product",
  ];

  Widget _buildInquiryItemRow(Map<String, dynamic> item, String supplierName) {
    final role        = item['role'] as String? ?? 'current';
    final productName = item['product_name'] as String? ?? '';
    final qty         = item['quantity'];
    final mrp         = item['mrp'];
    final answer      = item['answer'] as String?;
    final inquiryId   = (item['inquiry_id'] as num).toInt();
    final slotIndex   = (item['slot_index'] as num?)?.toInt() ?? 0;
    final isCurrent   = role == 'current';
    final noSupplier  = slotIndex <= 0 || role == 'none' || role == 'no_supplier';
    final isSetting   = _settingAnswerFor.contains(inquiryId);
    final subtitleParts = <String>[];
    if (qty != null) subtitleParts.add('Qty: $qty');
    if (mrp != null) subtitleParts.add('₹$mrp');
    RenderLog.write('inquiry_ordered_by_removed', 'true');

    final roleBadge = _iqBadge(
      isCurrent ? 'Current' : 'Next',
      isCurrent ? const Color(0xFFE6F4EA) : const Color(0xFFFFF8E1),
      isCurrent ? const Color(0xFF1B7F3B) : const Color(0xFF8A6D00),
    );

    Widget answerControls;
    if (isSetting) {
      answerControls = const SizedBox(
        width: 18, height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)),
      );
    } else if (noSupplier) {
      answerControls = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFFD1D5DB)),
        ),
        child: const Text('No supplier available',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Color(0xFF6B7280))),
      );
    } else {
      answerControls = Wrap(
        spacing: 5,
        runSpacing: 4,
        children: _kAnswerOptions.map((opt) {
          final isSelected = answer == opt;
          final optColor = opt == 'Available'
              ? const Color(0xFF1B7A43)
              : opt == 'Out of Stock'
                  ? const Color(0xFFDC2626)
                  : const Color(0xFF374151);
          return GestureDetector(
            onTap: () => _adminSetInquiryAnswer(
              inquiryId: inquiryId,
              supplierName: supplierName,
              answer: opt,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected ? optColor : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: optColor),
              ),
              child: Text(opt,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: isSelected ? Colors.white : optColor,
                )),
            ),
          );
        }).toList(),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: isCurrent ? const Color(0xFFA7F3D0) : const Color(0xFFFDE68A)),
      ),
      child: LayoutBuilder(builder: (ctx, constraints) {
        final isNarrow = constraints.maxWidth < 560;
        if (isNarrow) {
          RenderLog.write('inquiry_item_mobile_stacked', 'true');
          if (!isSetting && !noSupplier) {
            RenderLog.write('inquiry_item_answers_wrapped', 'true');
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              roleBadge,
              const SizedBox(width: 8),
              Expanded(
                child: Text(productName,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
            const SizedBox(height: 4),
            Text(subtitleParts.join(' · '),
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            const SizedBox(height: 8),
            answerControls,
          ]);
        }
        // Wide / desktop: original single-row layout
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          roleBadge,
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(productName,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF111827))),
              Text(subtitleParts.join(' · '),
                  style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            ]),
          ),
          const SizedBox(width: 8),
          answerControls,
        ]);
      }),
    );
  }

  // ── Timer helper: converts UTC DateTime to IST and formats as 12-hour AM/PM ─
  String _formatExpIST(DateTime utc) {
    final ist = utc.toUtc().add(const Duration(hours: 5, minutes: 30));
    final h = ist.hour % 12 == 0 ? 12 : ist.hour % 12;
    final m = ist.minute.toString().padLeft(2, '0');
    final ampm = ist.hour >= 12 ? 'PM' : 'AM';
    RenderLog.write('timer_12h_ist', '${ist.hour}:${ist.minute}->$h:$m $ampm');
    return 'Exp $h:$m $ampm';
  }

  // ── Inquiry link helpers ──────────────────────────────────────────────────

  // Returns the short inquiry link from get_supplier_contacts (e.g. https://medibo.in/SPO...I...).
  // Returns null if no live form for this supplier.
  Future<String?> _getInquiryShortLink(String supName) async {
    try {
      final result = await Supabase.instance.client
          .rpc('get_supplier_contacts', params: {'p_supplier_name': supName});
      if (result is Map) {
        final link = result['link'] as String?;
        return (link != null && link.isNotEmpty) ? link : null;
      }
    } catch (_) {}
    return null;
  }

  // Returns the short inquiry link from the cached overview (no RPC call).
  // Falls back to empty string if no inquiry_code available.
  String _inquiryShortLinkFromOverview(String supName) {
    final lower = supName.toLowerCase();
    for (final ov in _inquiryOverview) {
      if ((ov['supplier_name'] as String? ?? '').toLowerCase() == lower) {
        final code = (ov['inquiry_code'] as String? ?? '').trim();
        return code.isNotEmpty ? 'https://medibo.in/$code' : '';
      }
    }
    return '';
  }

  Future<String?> _ensureInquiryToken(String supName) async {
    final existing = _inquiryLinks[supName]?['token'] as String?;
    if (existing != null && existing.isNotEmpty) return existing;
    try {
      final rows = await Supabase.instance.client
          .rpc('start_inquiry_for_suppliers', params: {'p_supplier_names': [supName]}) as List;
      for (final m in rows) {
        if (mounted) setState(() => _inquiryLinks[m['supplier_name'] as String] = Map<String, dynamic>.from(m as Map));
      }
      return _inquiryLinks[supName]?['token'] as String?;
    } catch (_) { return null; }
  }

  Future<void> _copyInquiryLink(String supName) async {
    final link = await _getInquiryShortLink(supName);
    if (link == null || link.isEmpty) {
      if (mounted) showToast(context, 'Send the inquiry first', isError: true);
      return;
    }
    RenderLog.write('c319_share_uses_rpc_link', 'copy:$supName');
    Clipboard.setData(ClipboardData(text: link));
    if (mounted) showToast(context, 'Link copied');
    RenderLog.write('inquiry_copy_link', supName);
  }

  bool _isValidPhone(String n) {
    final d = n.replaceAll(RegExp(r'[^0-9]'), '');
    return d.length >= 10;
  }

  String _normalizePhone(String n) {
    final d = n.replaceAll(RegExp(r'[^0-9]'), '');
    if (d.length == 12 && d.startsWith('91')) return d.substring(2);
    if (d.length == 11 && d.startsWith('0')) return d.substring(1);
    return d.length >= 10 ? d.substring(d.length - 10) : d;
  }

  List<String> _parsePhoneList(String raw) {
    return raw
        .split(RegExp(r'[,\s]+'))
        .map((s) => s.trim())
        .where(_isValidPhone)
        .toSet()
        .toList();
  }

  List<String> _parseEmailList(String raw) {
    return raw
        .split(RegExp(r'[,\s]+'))
        .map((s) => s.trim())
        .where((s) => s.contains('@') && s.contains('.') && s.length > 5)
        .toSet()
        .toList();
  }

  Future<void> _openSendPopover(String supName) async {
    _closeSendPopover();
    final link = await _getInquiryShortLink(supName);
    if (link == null || link.isEmpty) {
      if (mounted) showToast(context, 'Send the inquiry first', isError: true);
      return;
    }
    if (!mounted) return;
    RenderLog.write('c319_share_uses_rpc_link', 'popover:$supName');
    final sup = _suppliers.cast<_SupRow?>().firstWhere(
      (s) => s!.supplierName.toLowerCase() == supName.toLowerCase(),
      orElse: () => null,
    );

    final waNumbers    = _parsePhoneList(sup?.rawData['whatsapp_no']   as String? ?? '');
    final otherNumbers = _parsePhoneList(
      '${sup?.rawData['contact_no'] as String? ?? ''},${sup?.rawData['other_contact'] as String? ?? ''}',
    ).where((n) => !waNumbers.contains(n)).toList();
    final emails       = _parseEmailList(sup?.rawData['email'] as String? ?? '');

    RenderLog.write('inquiry_send_popup', '$supName:wa=${waNumbers.length}:other=${otherNumbers.length}:email=${emails.length}');

    final entry = OverlayEntry(
      builder: (_) => _InquirySendPopover(
        link: _getSendLink(supName),
        supName: supName,
        waNumbers: waNumbers,
        otherNumbers: otherNumbers,
        emails: emails,
        inquiryLink: link,
        onDismissed: _closeSendPopover,
        onWaNumber: (num) {
          _closeSendPopover();
          _launchWhatsApp(supName, num, link);
        },
        onEmail: (email) {
          _closeSendPopover();
          _launchEmail(supName, email, link);
        },
      ),
    );
    _sendPopoverOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  void _launchWhatsApp(String supName, String rawNumber, String link) {
    final normalized = _normalizePhone(rawNumber);
    final intl = '91$normalized';
    final msg = Uri.encodeComponent(
        'Hello $supName,\nWe want to buy some items from you. Please confirm the stock availability:\n$link');
    html.window.open('https://wa.me/$intl?text=$msg', '_blank');
    RenderLog.write('inquiry_whatsapp_sent', '$supName:$intl');
  }

  void _launchEmail(String supName, String email, String link) {
    final subject = Uri.encodeComponent('mediBO — Stock Availability Inquiry');
    final body = Uri.encodeComponent(
        'Hello $supName,\nWe want to buy some items from you. Please confirm the stock availability:\n$link');
    html.window.open('mailto:$email?subject=$subject&body=$body', '_blank');
    RenderLog.write('inquiry_email_sent', '$supName:$email');
  }

  // ── Supplier Orders status label (read-only, no actions) ─────────────────

  Widget _orderStatusLabel(String status) {
    final lower = status.toLowerCase();
    final label = switch (lower) {
      'confirmed' || 'accepted' => 'Accepted',
      'rejected' => 'Rejected',
      _ => 'Pending',
    };
    final bg = switch (lower) {
      'confirmed' || 'accepted' => const Color(0xFFD1FAE5),
      'rejected' => const Color(0xFFFEE2E2),
      _ => const Color(0xFFFEF3C7),
    };
    final fg = switch (lower) {
      'confirmed' || 'accepted' => const Color(0xFF065F46),
      'rejected' => const Color(0xFF991B1B),
      _ => const Color(0xFF92400E),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  // ── Badge helpers (inquiry tab) ───────────────────────────────────────────

  Widget _iqBadge(String label, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
    child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
  );

  Widget _iqStatusBadge(String status) {
    Color bg, fg;
    String label;
    switch (status) {
      case 'draft':                bg = const Color(0xFFF3F4F6); fg = const Color(0xFF6B7280); label = 'Draft';      break;
      case 'pending':              bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E); label = 'Pending';    break;
      case 'partially_responded':  bg = const Color(0xFFEFF6FF); fg = const Color(0xFF1E40AF); label = 'Partial';    break;
      case 'responded':            bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46); label = 'Responded';  break;
      case 'expired':              bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B); label = 'Expired';    break;
      default:                     bg = const Color(0xFFF3F4F6); fg = const Color(0xFF6B7280); label = status;       break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // ── STAGING TAB (supplier pending companies + medicines) ─────────────────

  Future<void> _fetchStaging() async {
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait([
        client.from('supplier_pending_companies').select().eq('status', 'pending').order('created_at') as Future,
        client.from('supplier_pending_medicines').select().eq('status', 'pending').order('created_at') as Future,
      ]);
      if (mounted) {
        setState(() {
          _stagingCompanies = (results[0] as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
          _stagingMedicines = (results[1] as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _approveCompany(Map<String, dynamic> row) async {
    final name = row['company_name'] as String? ?? '';
    try {
      // Insert into company table (dedupe by name)
      await Supabase.instance.client.from('company').upsert(
        {'company_name': name},
        onConflict: 'company_name',
        ignoreDuplicates: true,
      );
      await Supabase.instance.client.from('supplier_pending_companies')
          .update({'status': 'approved'}).eq('id', row['id'] as int);
      if (mounted) showToast(context, 'Company "$name" approved');
      _fetchStaging();
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e', isError: true);
    }
  }

  Future<void> _rejectCompany(Map<String, dynamic> row) async {
    try {
      await Supabase.instance.client.from('supplier_pending_companies')
          .update({'status': 'rejected'}).eq('id', row['id'] as int);
      if (mounted) showToast(context, 'Company rejected');
      _fetchStaging();
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e', isError: true);
    }
  }

  Future<void> _approveMedicine(Map<String, dynamic> row) async {
    final name = row['product_name'] as String? ?? '';
    final marketer = row['marketer'] as String? ?? '';
    try {
      // Insert into MEDICINE if not already present (match by product_name + marketer)
      final existing = await Supabase.instance.client
          .from('MEDICINE').select('id')
          .ilike('product_name', name)
          .ilike('marketer', marketer)
          .maybeSingle();
      if (existing == null) {
        await Supabase.instance.client.from('MEDICINE').insert({
          'product_name': name,
          'marketer': marketer,
          'therapeutic_class': row['therapeutic_class'],
          'mrp': row['mrp']?.toString(),
        });
      }
      await Supabase.instance.client.from('supplier_pending_medicines')
          .update({'status': 'approved'}).eq('id', row['id'] as int);
      if (mounted) showToast(context, 'Medicine "$name" approved');
      _fetchStaging();
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e', isError: true);
    }
  }

  Future<void> _rejectMedicine(Map<String, dynamic> row) async {
    try {
      await Supabase.instance.client.from('supplier_pending_medicines')
          .update({'status': 'rejected'}).eq('id', row['id'] as int);
      if (mounted) showToast(context, 'Medicine rejected');
      _fetchStaging();
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e', isError: true);
    }
  }

  Widget _buildStagingView(bool isDesktop) {
    if (_stagingCompanies.isEmpty && _stagingMedicines.isEmpty) {
      return _emptyState('0 pending staging items');
    }
    return SingleChildScrollView(
      padding: EdgeInsets.all(isDesktop ? 24 : 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Supplier Staging', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const Spacer(),
          TextButton.icon(onPressed: _fetchStaging, icon: const Icon(Icons.refresh, size: 16), label: const Text('Refresh'),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFF1B7A43))),
        ]),
        const SizedBox(height: 16),
        // Companies
        if (_stagingCompanies.isNotEmpty) ...[
          const Text('Pending Companies', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          const SizedBox(height: 8),
          ..._stagingCompanies.map((row) => _StagingCard(
            title: row['company_name'] as String? ?? '',
            subtitle: 'Company',
            onApprove: () => _approveCompany(row),
            onReject: () => _rejectCompany(row),
          )),
          const SizedBox(height: 16),
        ],
        // Medicines
        if (_stagingMedicines.isNotEmpty) ...[
          const Text('Pending Medicines', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          const SizedBox(height: 8),
          ..._stagingMedicines.map((row) => _StagingCard(
            title: row['product_name'] as String? ?? '',
            subtitle: 'by ${row['marketer'] ?? '—'}${row['mrp'] != null ? '  ·  MRP ₹${row['mrp']}' : ''}',
            onApprove: () => _approveMedicine(row),
            onReject: () => _rejectMedicine(row),
          )),
        ],
      ]),
    );
  }

  // SUPPLIERS TAB
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildSuppliersView(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    RenderLog.write('c426_supplier_search', 'box=on');
    final visibleSuppliers =
        _supplierQuery.isEmpty ? _suppliers : _supplierSearchResults;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 10),
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
        child: TextField(
          controller: _supplierSearchCtl,
          onChanged: _onSupplierSearchChanged,
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Search suppliers by name, company, code, city, phone',
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: _supplierQuery.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _supplierSearchCtl.clear();
                      _onSupplierSearchChanged('');
                    },
                  ),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      ),
      if (_suppliers.isEmpty)
        _emptyState('0 approved suppliers')
      else if (visibleSuppliers.isEmpty)
        _emptyState('No suppliers found')
      else ...[
        if (isDesktop) _suppliersTableHeader(),
        ...visibleSuppliers.map((r) => isDesktop ? _desktopSupRow(r) : _mobileSupCard(r)),
      ],
      const SizedBox(height: 32),
      _buildDeletedSection(isDesktop),
      const SizedBox(height: 24),
      Builder(builder: (_) {
        RenderLog.write('import_supplier_at_top', 'true');
        RenderLog.write('import_supplier_only_suppliers_tab', 'true');
        return Padding(
          padding: EdgeInsets.fromLTRB(pad, 0, pad, 32),
          child: CompositedTransformTarget(
            link: _importSupplierLink,
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _pickAndImportSupplierProfile,
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                label: const Text('Import Supplier'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B7A43),
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                ),
              ),
            ),
          ),
        );
      }),
    ]);
  }

  Widget _buildRefreshButton() {
    RenderLog.write('supabase_refresh_removed', 'true');
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _refreshLoading ? null : () => _refreshSuppliers(),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE5E7EB)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_refreshLoading)
              const SizedBox(width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF6B7280)))
            else
              const Icon(Icons.refresh, size: 14, color: Color(0xFF374151)),
            const SizedBox(width: 5),
            const Text('Refresh', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF374151))),
          ]),
        ),
      ),
    );
  }

  Widget _buildDeletedSection(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Column(children: [
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
                  child: const Icon(Icons.expand_more, size: 18, color: Color(0xFF1B7A43)),
                ),
                const SizedBox(width: 8),
                Text(
                  'Recently Deleted (${_deletedRows.length})',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
                ),
                const Spacer(),
                if (_deletedRows.isNotEmpty)
                  GestureDetector(
                    onTap: _clearAllDeleted,
                    child: const Text('Clear All',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFDC2626))),
                  ),
              ]),
            ),
          ),
        ),
        if (_deletedExpanded) ...[
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
            ),
            child: _deletedRows.isEmpty
                ? Padding(
                    padding: EdgeInsets.symmetric(horizontal: pad, vertical: 20),
                    child: const Text('No deleted suppliers.',
                        style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                  )
                : Column(
                    children: _deletedRows.map((r) => _buildDeletedRow(r, isDesktop)).toList(),
                  ),
          ),
        ],
      ]),
    );
  }

  Widget _buildDeletedRow(Map<String, dynamic> row, bool isDesktop) {
    final snap      = row['deleted_snapshot'] as Map<String, dynamic>? ?? row;
    final name      = (snap['supplier_name']  as String? ?? row['supplier_name']  as String? ?? '').trim();
    final email     = (snap['email']          as String? ?? row['email']          as String? ?? '').trim();
    final deletedAt = _fmtTs(row['deleted_at'] as String?);
    final deletedBy = row['deleted_by'] as String? ?? '';
    final isLast    = _deletedRows.last == row;
    final pad       = isDesktop ? 28.0 : 16.0;

    return Opacity(
      opacity: 0.85,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          border: isLast ? null : const Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              name.isNotEmpty ? name : (email.isNotEmpty ? email : 'Deleted Supplier'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 3),
            Text(
              [
                if (email.isNotEmpty)     email,
                if (deletedAt.isNotEmpty) 'Deleted: $deletedAt',
                if (deletedBy.isNotEmpty) 'By: $deletedBy',
              ].join('  ·  '),
              style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
              overflow: TextOverflow.ellipsis,
            ),
          ])),
          const SizedBox(width: 12),
          InkWell(
            onTap: () => _restoreSupplier(row),
            borderRadius: BorderRadius.circular(6),
            mouseCursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF1B7A43)),
              ),
              child: const Text('Restore',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1B7A43))),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => _permanentDeleteSupplier(row),
            borderRadius: BorderRadius.circular(6),
            mouseCursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFDC2626)),
              ),
              child: const Text('Delete',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFDC2626))),
            ),
          ),
        ]),
      ),
    );
  }


  Widget _suppliersTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        _th('SUPPLIER', flex: 4),
        _th('CONTACT', flex: 3),
        _th('PHONE', flex: 2),
        _th('CODE', flex: 2),
        _th('CITY', flex: 3),
        const SizedBox(width: 420), // right action cluster placeholder
      ]),
    );
  }

  Widget _desktopSupRow(_SupRow row) {
    final isExpanded = _expandedSupplierId == row.id;
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
            Expanded(flex: 4, child: Text(row.supplierName.isNotEmpty ? row.supplierName : '—',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                overflow: TextOverflow.ellipsis)),
            Expanded(flex: 3, child: Text(row.contactName.isNotEmpty ? row.contactName : '—',
                style: const TextStyle(fontSize: 13, color: Color(0xFF374151)), overflow: TextOverflow.ellipsis)),
            Expanded(flex: 2, child: Text(row.phone.isNotEmpty ? row.phone : '—',
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
            Expanded(flex: 2, child: Text(row.supplierCode.isNotEmpty ? row.supplierCode : '—',
                style: const TextStyle(fontSize: 12, color: Color(0xFF374151), fontFamily: 'monospace'))),
            Expanded(flex: 3, child: Text(
                [row.city, row.state].where((s) => s.isNotEmpty).join(', ').let((s) => s.isNotEmpty ? s : '—'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)), overflow: TextOverflow.ellipsis)),
            // ── Right action cluster (fixed 360px) — all non-data controls ──────
            SizedBox(width: 420, child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: () => _toggleSpn(row.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _spnSupplierId == row.id ? const Color(0xFFDBEAFE) : Colors.white,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: _spnSupplierId == row.id ? const Color(0xFF93C5FD) : const Color(0xFFD1D5DB)),
                    ),
                    child: const Text('SPN', style: TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _toggleCompanies(row.id),
                  behavior: HitTestBehavior.opaque,
                  child: _SupplierCompaniesButton(
                    count: _companyCounts[row.id] ?? 0,
                    isOpen: _companiesSupplierId == row.id,
                  ),
                ),
                const SizedBox(width: 8),
                _MatchStatusChip(status: _matchService.statuses.value[row.id], supplierId: row.id),
                const SizedBox(width: 10),
                _StatusPill(
                  key: ValueKey('status_${row.id}'),
                  supplierId: row.id,
                  initialStatus: row.status,
                  onStatusChanged: (newStatus, newSpn) {
                    row.rawData['status'] = newStatus;
                    row.rawData['SPN'] = newSpn;
                    if (mounted) {
                      setState(_applySort);
                      RenderLog.write('supplier_status_saved_readback', newStatus);
                      RenderLog.write('supplier_list_resorted_live', _sortMode == _SupSortMode.spnDesc ? 'spn' : 'name');
                    }
                  },
                ),
                const SizedBox(width: 14),
                _actionBtn('Edit', const Color(0xFF1B7A43), () => _editSupplier(row)),
                const SizedBox(width: 6),
                _actionBtn('Delete', const Color(0xFFDC2626), () => _deleteSupplier(row)),
                const SizedBox(width: 10),
                AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more, size: 18, color: Color(0xFF6B7280)),
                ),
              ],
            )),
          ]),
        ),
      ),
      if (_companiesSupplierId == row.id)
        _CompaniesInlineSection(
          supplierId: row.id,
          supplierName: row.supplierName,
          matchService: _matchService,
          onCompanyAdded: () => _reloadCompanyCount(row.id),
        ),
      if (_spnSupplierId == row.id)
        _SpnInlineSection(
          key: ValueKey('spn_${row.id}'),
          supplierId: row.id,
          supplierName: row.supplierName,
          onSaved: () => _load(showSpinner: false).then((_) {
            if (mounted) setState(_applySort);
          }),
        ),
      if (isExpanded) _buildDetails(row.rawData, lpad: 28, rpad: 0),
    ]);
  }

  Widget _mobileSupCard(_SupRow row) {
    final isExpanded = _expandedSupplierId == row.id;
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
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Builder(builder: (_) {
                  RenderLog.write('supplier_card_restructured', 'true');
                  return const SizedBox.shrink();
                }),
                // Name line: [Full supplier name] [Active pill]
                Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  Expanded(child: Text(
                    row.supplierName.isNotEmpty ? row.supplierName : row.contactName.isNotEmpty ? row.contactName : 'Unknown',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  )),
                  const SizedBox(width: 8),
                  _StatusPill(
                    key: ValueKey('status_${row.id}'),
                    supplierId: row.id,
                    initialStatus: row.status,
                    onStatusChanged: (newStatus, newSpn) {
                      row.rawData['status'] = newStatus;
                      row.rawData['SPN'] = newSpn;
                      if (mounted) {
                        setState(_applySort);
                        RenderLog.write('supplier_status_saved_readback', newStatus);
                        RenderLog.write('supplier_list_resorted_live', _sortMode == _SupSortMode.spnDesc ? 'spn' : 'name');
                      }
                    },
                  ),
                ]),
                if (row.contactName.isNotEmpty) ...[const SizedBox(height: 3), Text(row.contactName, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)), overflow: TextOverflow.ellipsis)],
                if (row.phone.isNotEmpty) ...[const SizedBox(height: 2), Text(row.phone, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))],
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 4, children: [
                  if (row.supplierCode.isNotEmpty) _mobileField('Code', row.supplierCode),
                  if (row.paymentTerm.isNotEmpty)  _mobileField('Payment', row.paymentTerm),
                  if (row.city.isNotEmpty)          _mobileField('City', [row.city, row.state].where((s) => s.isNotEmpty).join(', ')),
                ]),
                const SizedBox(height: 8),
                _MatchStatusChip(status: _matchService.statuses.value[row.id], supplierId: row.id),
                const SizedBox(height: 8),
                // Last action row: [SPN] [Companies (N)] [Edit] [Delete]
                Wrap(spacing: 8, runSpacing: 6, children: [
                  GestureDetector(
                    onTap: () => _toggleSpn(row.id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: _spnSupplierId == row.id ? const Color(0xFFDBEAFE) : Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: _spnSupplierId == row.id ? const Color(0xFF93C5FD) : const Color(0xFFD1D5DB)),
                      ),
                      child: const Text('SPN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => _toggleCompanies(row.id),
                    behavior: HitTestBehavior.opaque,
                    child: _SupplierCompaniesButton(
                      count: _companyCounts[row.id] ?? 0,
                      isOpen: _companiesSupplierId == row.id,
                    ),
                  ),
                  _actionBtn('Edit',   const Color(0xFF1B7A43), () => _editSupplier(row)),
                  _actionBtn('Delete', const Color(0xFFDC2626), () => _deleteSupplier(row)),
                ]),
              ]),
            ),
            if (_companiesSupplierId == row.id) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _CompaniesInlineSection(
                supplierId: row.id,
                supplierName: row.supplierName,
                matchService: _matchService,
                onCompanyAdded: () => _reloadCompanyCount(row.id),
              ),
            ],
            if (_spnSupplierId == row.id) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _SpnInlineSection(
                key: ValueKey('spn_${row.id}'),
                supplierId: row.id,
                supplierName: row.supplierName,
                onSaved: () => _load(showSpinner: false).then((_) {
                  if (mounted) setState(_applySort);
                }),
              ),
            ],
            if (isExpanded) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _buildDetails(row.rawData, lpad: 0, rpad: 0),
            ],
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SUPPLIER ORDERS TAB
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildOrderSendButton(_OrderRow row) {
    RenderLog.write('order_send_button_rendered', 'true');
    return Builder(builder: (btnCtx) => GestureDetector(
      onTap: () => _sendOrderWhatsApp(row, btnCtx),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFD1FAE5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF065F46).withValues(alpha: 0.3)),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.send_outlined, size: 13, color: Color(0xFF065F46)),
          SizedBox(width: 4),
          Text('Send', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF065F46))),
        ]),
      ),
    ));
  }

  Future<void> _sendOrderWhatsApp(_OrderRow row, BuildContext btnCtx) async {
    final supName = row.supplierName;
    if (supName == null) return;
    try {
      final rows = await Supabase.instance.client
          .rpc('get_supplier_order_send_payload', params: {
            'p_supplier_name': supName,
            'p_order_id': row.id,
          }) as List;
      final link = rows.isNotEmpty
          ? (Map<String, dynamic>.from(rows.first as Map)['link'] as String?)
          : null;

      final greeting = 'mediBO order for $supName. View & confirm here:';
      final message = link != null && link.isNotEmpty ? '$greeting\n$link' : greeting;
      RenderLog.write('c188_send_uses_order_link', link != null && link.isNotEmpty ? 'true' : 'no_link');

      await _showSendContactPicker(supplierName: supName, message: message, btnCtx: btnCtx, isOrders: true);
    } catch (e) {
      if (mounted) showToast(context, 'Failed to send: $e', isError: true);
    }
  }

  Future<void> _showSendContactPicker({
    required String supplierName,
    required String message,
    required BuildContext btnCtx,
    bool isOrders = false,
  }) async {
    if (!mounted) return;

    // Capture button position BEFORE async gap
    final box = btnCtx.findRenderObject() as RenderBox?;
    final btnOffset = (box != null && box.attached) ? box.localToGlobal(Offset.zero) : Offset.zero;
    final btnSize = (box != null && box.attached) ? box.size : const Size(60, 32);

    Map<String, dynamic> contactData;
    try {
      final result = await Supabase.instance.client
          .rpc('get_supplier_contacts', params: {'p_supplier_name': supplierName});
      if (result is Map) {
        contactData = Map<String, dynamic>.from(result);
      } else if (result is List && (result as List).isNotEmpty) {
        contactData = Map<String, dynamic>.from((result as List).first as Map);
      } else {
        contactData = {};
      }
    } catch (e) {
      if (mounted) showToast(context, 'Failed to load contacts: $e', isError: true);
      return;
    }
    if (contactData.containsKey('error')) {
      if (mounted) showToast(context, 'Contact error: ${contactData['error']}', isError: true);
      return;
    }
    if (!mounted) return;

    final wa = List<String>.from(contactData['whatsapp'] as List? ?? []);
    final ct = List<String>.from(contactData['contact']  as List? ?? []);
    final ph = List<String>.from(contactData['phone']    as List? ?? []);
    final ot = List<String>.from(contactData['other']    as List? ?? []);
    final em = contactData['email'] as String?;
    final totalRows = wa.length + ct.length + ph.length + ot.length + (em != null ? 1 : 0);

    RenderLog.write('send_contact_popup_opened', supplierName);
    RenderLog.write('send_contact_groups_$totalRows', 'true');
    if (isOrders) {
      RenderLog.write('send_contact_anchored_orders', 'true');
    } else {
      RenderLog.write('send_contact_anchored_inquiry', 'true');
    }

    OverlayEntry? entry;
    void dismiss() {
      entry?.remove();
      entry = null;
    }
    entry = OverlayEntry(
      builder: (_) => _ContactPickerPopover(
        btnRect: Rect.fromLTWH(btnOffset.dx, btnOffset.dy, btnSize.width, btnSize.height),
        supplierName: supplierName,
        message: message,
        contactData: contactData,
        onDismiss: dismiss,
      ),
    );
    Overlay.of(context).insert(entry!);
  }

  // CHANGE #277: filter order items to only those still held by this supplier
  List<Map<String, dynamic>> _currentItemsFor(_OrderRow row) {
    if (_liveOrderItemKeys.isEmpty) return row.items;
    final supKey = (row.supplierName ?? '').trim().toLowerCase();
    return row.items.where((item) {
      final pid = (item['product_id'] as num?)?.toInt();
      return pid != null && _liveOrderItemKeys.contains('$supKey|$pid');
    }).toList();
  }

  Widget _buildOrdersView(bool isDesktop) {
    // CHANGE #277: split into active (has current items) vs superseded
    final activeOrders = <_OrderRow>[];
    int supersededCount = 0;
    for (final r in _orders) {
      if (_currentItemsFor(r).isNotEmpty) {
        activeOrders.add(r);
      } else {
        supersededCount++;
        RenderLog.write('c277_superseded_hidden', 'order=${r.id.substring(0, 8)};supplier=${r.supplierName ?? ''}');
      }
    }
    RenderLog.write('c277_supplier_current_filter', 'active=${activeOrders.length};hidden=$supersededCount');
    RenderLog.write('c108_admin_suporders_list_built', _orders.length);
    if (activeOrders.isEmpty) return _emptyState('0 supplier orders');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isDesktop) _ordersTableHeader(),
      ...activeOrders.map((r) => isDesktop ? _desktopOrderRow(r) : _mobileOrderCard(r)),
      const SizedBox(height: 32),
    ]);
  }

  Widget _ordersTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        _th('SUPPLIER', flex: 4),
        _th('DESCRIPTION', flex: 5),
        _th('AMOUNT', flex: 2),
        _th('STATUS', flex: 3),
        _th('DATE', flex: 3),
        const SizedBox(width: 72),
      ]),
    );
  }

  Widget _desktopOrderRow(_OrderRow row) {
    final dateStr = row.createdAt != null
        ? '${row.createdAt!.day.toString().padLeft(2,'0')}/${row.createdAt!.month.toString().padLeft(2,'0')}/${row.createdAt!.year}'
        : '—';
    final isExpanded = _expandedOrderId == row.id;
    final currentItems = _currentItemsFor(row); // CHANGE #277
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          setState(() => _expandedOrderId = isExpanded ? null : row.id);
          RenderLog.write('order_row_expanded', isExpanded ? 'collapse:${row.id}' : 'expand:${row.id}');
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          child: Row(children: [
            Expanded(flex: 4, child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(row.supplierName ?? '—',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                    overflow: TextOverflow.ellipsis),
                if ((row.orderCode ?? '').isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Builder(builder: (_) {
                    try { RenderLog.write('c318_ord_id', row.orderCode!); } catch (_) {}
                    return Text(row.orderCode!,
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500,
                            color: Color(0xFF9CA3AF), letterSpacing: 0.3),
                        overflow: TextOverflow.ellipsis);
                  }),
                ],
              ],
            )),
            Expanded(flex: 5, child: Text(row.description ?? '—',
                style: const TextStyle(fontSize: 13, color: Color(0xFF374151)), overflow: TextOverflow.ellipsis)),
            Expanded(flex: 2, child: Text(row.totalAmount != null ? '₹${row.totalAmount!.toStringAsFixed(0)}' : '—',
                style: const TextStyle(fontSize: 13, color: Color(0xFF111827)))),
            Expanded(flex: 3, child: _orderStatusLabel(row.status)),
            Expanded(flex: 3, child: Text(dateStr, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
            _buildOrderSendButton(row),
          ]),
        ),
      ),
      if (isExpanded) _buildOrderItemsPanel(currentItems, padH: 28), // CHANGE #277: show current items only
      // CHANGE #328 — bill + payment panels (desktop)
      if (_orderBillOpen[row.id] == true)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: _buildAdminBillPanel(row),
        ),
      if (_orderPayOpen[row.id] == true)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: _buildAdminPayPanel(row),
        ),
      // CHANGE #328 — button row (desktop, shown below main row always)
      Container(
        padding: const EdgeInsets.fromLTRB(28, 6, 28, 10),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: _buildOrderBillPayRow(row.id),
      ),
    ]);
  }

  Widget _mobileOrderCard(_OrderRow row) {
    final dateStr = row.createdAt != null
        ? '${row.createdAt!.day.toString().padLeft(2,'0')}/${row.createdAt!.month.toString().padLeft(2,'0')}/${row.createdAt!.year}'
        : '';
    final isExpanded = _expandedOrderId == row.id;
    final currentItems = _currentItemsFor(row); // CHANGE #277
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _expandedOrderId = isExpanded ? null : row.id);
        RenderLog.write('order_row_expanded', isExpanded ? 'collapse:${row.id}' : 'expand:${row.id}');
      },
      child: Container(
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
                Expanded(child: Text(row.supplierName ?? '—',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                    overflow: TextOverflow.ellipsis)),
                if (dateStr.isNotEmpty) Text(dateStr, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
              ]),
              if ((row.orderCode ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(row.orderCode!,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
                        color: Color(0xFF9CA3AF), letterSpacing: 0.3)),
              ],
              if (row.description?.isNotEmpty == true) ...[
                const SizedBox(height: 4),
                Text(row.description!, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ],
              if (row.totalAmount != null) ...[
                const SizedBox(height: 4),
                Text('₹${row.totalAmount!.toStringAsFixed(0)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF1B7A43))),
              ],
              const SizedBox(height: 10),
              Row(children: [
                _orderStatusLabel(row.status),
                const Spacer(),
                _buildOrderSendButton(row),
              ]),
              // CHANGE #328 — View Bill (left) + View Payment (right)
              const SizedBox(height: 8),
              _buildOrderBillPayRow(row.id),
            ]),
          ),
          // CHANGE #328 — bill + payment panels
          if (_orderBillOpen[row.id] == true)
            _buildAdminBillPanel(row),
          if (_orderPayOpen[row.id] == true)
            _buildAdminPayPanel(row),
          if (isExpanded) _buildOrderItemsPanel(currentItems, padH: 14), // CHANGE #277: show current items only
        ]),
      ),
    );
  }

  // ── CHANGE #328: View Bill / View Payment button row ─────────────────────

  Widget _buildOrderBillPayRow(String orderId) {
    final billOpen = _orderBillOpen[orderId] == true;
    final payOpen  = _orderPayOpen[orderId] == true;

    Widget toggleBtn(String label, bool isOpen, VoidCallback onTap) {
      return GestureDetector(
        onTap: onTap,
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
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600,
                    color: isOpen ? const Color(0xFF1E40AF) : const Color(0xFF374151),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: isOpen ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.expand_more, size: 14,
                    color: isOpen ? const Color(0xFF1E40AF) : const Color(0xFF6B7280)),
              ),
            ],
          ),
        ),
      );
    }

    return Row(children: [
      Expanded(child: toggleBtn('View Bill', billOpen, () {
        final willOpen = !billOpen;
        setState(() {
          _orderBillOpen[orderId] = willOpen;
          if (willOpen) _orderPayOpen[orderId] = false; // close pay when opening bill
        });
        if (willOpen) _loadOrderPanel(orderId);
      })),
      const SizedBox(width: 8),
      Expanded(child: toggleBtn('View Payment', payOpen, () {
        final willOpen = !payOpen;
        setState(() {
          _orderPayOpen[orderId] = willOpen;
          if (willOpen) _orderBillOpen[orderId] = false; // close bill when opening pay
        });
        if (willOpen) _loadOrderPanel(orderId);
      })),
    ]);
  }

  // ── CHANGE #328: admin View Bill chip panel ──────────────────────────────

  Widget _buildAdminBillPanel(_OrderRow row) {
    final orderId = row.id;
    final isLoading = _orderPanelLoading[orderId] == true;
    final error = _orderPanelError[orderId];
    final data = _orderPanelData[orderId];

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF3F4F6))),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('View Bill', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const Spacer(),
              GestureDetector(
                onTap: () => _loadOrderPanel(orderId, refresh: true),
                child: const Icon(Icons.refresh, size: 16, color: Color(0xFF6B7280)),
              ),
            ]),
            const SizedBox(height: 8),
            if (isLoading)
              const Center(child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
              ))
            else if (error != null)
              Row(children: [
                const Text('Failed to load.', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _loadOrderPanel(orderId, refresh: true),
                  child: const Text('Retry', style: TextStyle(fontSize: 13, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600)),
                ),
              ])
            else if (data == null || data['found'] != true)
              const Text('Bill details unavailable.', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
            else
              _AdminBillPanelBody(
                data: data,
                row: row,
                onReload: () => _loadOrderPanel(orderId, refresh: true),
              ),
          ],
        ),
      ),
    );
  }

  // ── CHANGE #328: admin View Payment panel ────────────────────────────────

  Widget _buildAdminPayPanel(_OrderRow row) {
    final orderId = row.id;
    final isLoading = _orderPanelLoading[orderId] == true;
    final error = _orderPanelError[orderId];
    final data = _orderPanelData[orderId];

    return Container(
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF3F4F6))),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Text('Payment Summary', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const Spacer(),
              GestureDetector(
                onTap: () => _loadOrderPanel(orderId, refresh: true),
                child: const Icon(Icons.refresh, size: 16, color: Color(0xFF6B7280)),
              ),
            ]),
            const SizedBox(height: 8),
            if (isLoading)
              const Center(child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
              ))
            else if (error != null)
              Row(children: [
                const Text('Failed to load.', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _loadOrderPanel(orderId, refresh: true),
                  child: const Text('Retry', style: TextStyle(fontSize: 13, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600)),
                ),
              ])
            else if (data == null || data['found'] != true)
              const Text('Payment details unavailable.', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
            else
              SupPayPanel(
                data: data,
                orderId: orderId,
                onReload: () => _loadOrderPanel(orderId, refresh: true),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderItemsPanel(List<Map<String, dynamic>> items, {double padH = 16}) {
    RenderLog.write('c108_admin_suporder_itemcard_built', items.length);
    RenderLog.write('c108_admin_suporders_list_built', 'true');
    RenderLog.write('c189_admin_tab_merged_pill', 'true');
    return Container(
      margin: EdgeInsets.fromLTRB(padH, 0, padH, 12),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: items.isEmpty
          ? const Padding(
              padding: EdgeInsets.all(8),
              child: Text('No items.', style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            )
          : Column(
              children: items.map((item) => OrderItemCard(item: item)).toList(),
            ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PENDING APPROVAL TAB
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildPendingView(bool isDesktop) {
    if (_pending.isEmpty) return _emptyState('0 pending supplier registrations');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isDesktop) _pendingTableHeader(),
      ..._pending.map((r) => isDesktop ? _desktopPendingRow(r) : _mobilePendingCard(r)),
      const SizedBox(height: 32),
    ]);
  }

  Widget _pendingTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        _th('SUPPLIER NAME', flex: 3),
        _th('CONTACT', flex: 3),
        _th('PHONE', flex: 2),
        _th('CODE', flex: 2),
        _th('PAYMENT', flex: 2),
        _th('CITY / STATE', flex: 2),
        _th('APPROVAL', flex: 3),
        const SizedBox(width: 32),
      ]),
    );
  }

  Widget _desktopPendingRow(_PendingRow row) {
    final isExpanded = _expandedSupplierId == row.id;
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
            Expanded(flex: 3, child: Text(row.supplierName.isNotEmpty ? row.supplierName : '—',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                overflow: TextOverflow.ellipsis)),
            Expanded(flex: 3, child: Text(row.contactName.isNotEmpty ? row.contactName : '—',
                style: const TextStyle(fontSize: 13, color: Color(0xFF374151)), overflow: TextOverflow.ellipsis)),
            Expanded(flex: 2, child: Text(row.phone.isNotEmpty ? row.phone : '—',
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
            Expanded(flex: 2, child: Text(row.supplierCode?.isNotEmpty == true ? row.supplierCode! : '—',
                style: const TextStyle(fontSize: 12, color: Color(0xFF374151), fontFamily: 'monospace'))),
            Expanded(flex: 2, child: row.paymentTerm?.isNotEmpty == true
                ? _PaymentBadge(term: row.paymentTerm!) : const Text('—', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))),
            Expanded(flex: 2, child: Text(
                [row.city, row.state].where((s) => s != null && s.isNotEmpty).join(', ').let((s) => s.isNotEmpty ? s : '—'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)), overflow: TextOverflow.ellipsis)),
            Expanded(flex: 3, child: _ApproveActions(
                id: row.id, onApprove: () => _approvePending(row), onReject: () => _rejectPending(row))),
            SizedBox(width: 32, child: AnimatedRotation(
              turns: isExpanded ? 0.5 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.expand_more, size: 18, color: Color(0xFF6B7280)),
            )),
          ]),
        ),
      ),
      if (isExpanded) _buildDetails(row.rawData, lpad: 28, rpad: 0),
    ]);
  }

  Widget _mobilePendingCard(_PendingRow row) {
    final isExpanded = _expandedSupplierId == row.id;
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
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(row.supplierName.isNotEmpty ? row.supplierName : 'Unknown',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                      overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  _pendingBadge(),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more, size: 18, color: Color(0xFF9CA3AF)),
                  ),
                ]),
                if (row.contactName.isNotEmpty) ...[const SizedBox(height: 3), Text(row.contactName, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)), overflow: TextOverflow.ellipsis)],
                if (row.phone.isNotEmpty) ...[const SizedBox(height: 2), Text(row.phone, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))],
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 4, children: [
                  if (row.supplierCode?.isNotEmpty == true) _mobileField('Code', row.supplierCode!),
                  if (row.paymentTerm?.isNotEmpty == true)  _mobileField('Payment', row.paymentTerm!),
                  if (row.city?.isNotEmpty == true)          _mobileField('City', [row.city, row.state].where((s) => s != null && s.isNotEmpty).join(', ')),
                ]),
                const SizedBox(height: 12),
                _ApproveActions(id: row.id, onApprove: () => _approvePending(row), onReject: () => _rejectPending(row)),
              ]),
            ),
            if (isExpanded) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _buildDetails(row.rawData, lpad: 0, rpad: 0),
            ],
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // LEADS TAB
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildLeadsView(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 16, pad, 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Supplier Leads',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 2),
        const Text('CSV-imported and manually added supplier leads',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        const SizedBox(height: 10),
        if (_leads.isEmpty)
          const Text('No leads yet', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
        else
          for (final lead in _leads) _buildLeadRow(lead, isDesktop),
        const SizedBox(height: 32),
        _buildCsvUpload(),
      ]),
    );
  }

  Widget _buildLeadRow(_LeadItem lead, bool isDesktop) {
    final isExpanded = _expandedLeads.contains(lead.id);
    final displayName = lead.name.isNotEmpty ? lead.name : lead.email;
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => isExpanded ? _expandedLeads.remove(lead.id) : _expandedLeads.add(lead.id)),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 18, color: const Color(0xFF6B7280)),
              const SizedBox(width: 10),
              Expanded(
                child: isDesktop
                    ? Row(children: [
                        _leadCell(displayName, flex: 3, bold: true),
                        _leadCell(lead.email, flex: 3),
                        _leadCell(lead.mobile.isNotEmpty ? lead.mobile : '—', flex: 2),
                      ])
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(displayName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                        if (lead.email.isNotEmpty) Text(lead.email, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                      ]),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _leadStatusColor(lead.status).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(lead.status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _leadStatusColor(lead.status))),
              ),
            ]),
          ),
        ),
        if (isExpanded)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE5E7EB)))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 12),
              Wrap(spacing: 20, runSpacing: 12, children: [
                if (lead.name.isNotEmpty)   _detailChip('Name',   lead.name),
                if (lead.email.isNotEmpty)  _detailChip('Email',  lead.email),
                if (lead.mobile.isNotEmpty) _detailChip('Mobile', lead.mobile),
              ]),
              const SizedBox(height: 16),
              _leadDropdown<String>(
                label: 'Status',
                value: lead.status,
                items: const ['new', 'contacted', 'interested', 'converted', 'dropped'],
                display: (v) => v[0].toUpperCase() + v.substring(1),
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => lead.status = v);
                  try {
                    await Supabase.instance.client.from('supplier_leads').update({'status': v}).eq('id', lead.id);
                  } catch (_) {}
                },
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _leadCell(String text, {int flex = 1, bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
              color: bold ? const Color(0xFF111827) : const Color(0xFF374151))),
    );
  }

  Widget _detailChip(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF), fontWeight: FontWeight.w500)),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontSize: 13, color: Color(0xFF111827))),
    ]);
  }

  Widget _leadDropdown<T>({
    required String label, required T value, required List<T> items,
    required String Function(T) display, required ValueChanged<T?> onChanged,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280), fontWeight: FontWeight.w500)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(border: Border.all(color: const Color(0xFFD1D5DB)), borderRadius: BorderRadius.circular(6), color: Colors.white),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value, isDense: true,
            items: items.map((v) => DropdownMenuItem<T>(value: v, child: Text(display(v), style: const TextStyle(fontSize: 13)))).toList(),
            onChanged: onChanged,
          ),
        ),
      ),
    ]);
  }

  Color _leadStatusColor(String status) {
    return switch (status) {
      'converted'  => const Color(0xFF1B7A43),
      'dropped'    => const Color(0xFFDC2626),
      'interested' => const Color(0xFF2563EB),
      'contacted'  => const Color(0xFFD97706),
      _            => const Color(0xFF6B7280),
    };
  }

  Widget _buildCsvUpload() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(),
      const SizedBox(height: 8),
      const Text('Import CSV', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
      const SizedBox(height: 4),
      const Text('Columns: name, email, mobile (header row required; order flexible)',
          style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      const SizedBox(height: 10),
      ElevatedButton.icon(
        onPressed: _pickAndImportCsv,
        icon: const Icon(Icons.upload_file_outlined, size: 16),
        label: const Text('Upload CSV'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1B7A43), foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    ]);
  }

  void _pickAndImportSupplierProfile() {
    if (_importSupplierOverlay != null) {
      _closeImportSupplierPopover();
      return;
    }
    RenderLog.write('import_choice_popover_opened', 'true');
    final entry = OverlayEntry(
      builder: (_) => _ImportSupplierPopover(
        link: _importSupplierLink,
        onDismissed: () { if (mounted) _closeImportSupplierPopover(); },
        onManually: () {
          _closeImportSupplierPopover();
          RenderLog.write('manual_import_dialog_opened', 'true');
          if (mounted) showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => _ManualSupplierImportDialog(
                onImported: () { if (mounted) _load(showSpinner: false); }),
          );
        },
        onFile: () {
          _closeImportSupplierPopover();
          if (mounted) _pickAndImportFile();
        },
      ),
    );
    _importSupplierOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  void _closeImportSupplierPopover() {
    _importSupplierOverlay?.remove();
    _importSupplierOverlay = null;
  }

  Future<void> _pickAndImportFile() async {
    final input = html.FileUploadInputElement()
      ..accept = '.csv,.tsv,.txt,.xlsx,.xls,.ods,.docx,.pdf,.jpg,.jpeg,.png,.webp,.heic,.heif,.gif'
      ..multiple = true;
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty || !mounted) return;

    const imageExts = {'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'gif'};
    final images = files.where((f) => imageExts.contains(f.name.toLowerCase().split('.').last)).toList();
    final nonImages = files.where((f) => !imageExts.contains(f.name.toLowerCase().split('.').last)).toList();

    if (nonImages.isNotEmpty) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SupProfileImportDialog(file: nonImages.first, onImported: () { if (mounted) _load(showSpinner: false); }),
      );
      return;
    }

    if (images.length == 1) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SupCardImportDialog(file: images.first, onImported: () { if (mounted) _load(showSpinner: false); }),
      );
    } else {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SupCardMultiImportDialog(files: images, onImported: () { if (mounted) _load(showSpinner: false); }),
      );
    }
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
      builder: (_) => _SupCsvImportDialog(file: file, onImported: () { if (mounted) _load(showSpinner: false); }),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // DETAILS PANEL (shared)
  // ═══════════════════════════════════════════════════════════════════════════

  static String _str(dynamic v) {
    if (v == null) return '';
    if (v is bool) return v ? 'Yes' : 'No';
    final s = v.toString().trim();
    return s == 'null' ? '' : s;
  }

  static String _fmtTs(dynamic v) {
    final s = _str(v);
    if (s.isEmpty) return '';
    try {
      final dt = DateTime.parse(s).toLocal();
      return '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}  '
             '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    } catch (_) { return s; }
  }

  Widget _buildDetails(Map<String, dynamic> rawData, {required double lpad, required double rpad}) {
    String val(dynamic v, {bool isTs = false}) {
      final s = isTs ? _fmtTs(v) : _str(v);
      return s.isEmpty ? '—' : s;
    }

    final groups = <(String, List<(String, String)>)>[
      ('IDENTITY', [
        ('Supplier Name', val(rawData['supplier_name'])),
        ('Code',          val(rawData['supplier_code'])),
        ('Stockist Type', val(rawData['stockist_type'])),
        ('Status',        val(rawData['status'])),
      ]),
      ('CONTACT', [
        ('Contact Name',  val(rawData['contact_person'] ?? rawData['contact_name'])),
        ('Phone',         val(rawData['phone'])),
        ('WhatsApp No',   val(rawData['whatsapp_no'])),
        ('Contact No',    val(rawData['contact_no'])),
        ('Email',         val(rawData['email'])),
        ('Other Contact', val(rawData['other_contact'])),
      ]),
      ('LOCATION', [
        ('Street Address', val(rawData['street_address'] ?? rawData['address'])),
        ('City',           val(rawData['city'])),
        ('State',          val(rawData['state'])),
        ('PIN Code',       val(rawData['pin_code'] ?? rawData['pincode'])),
        ('Range / Zone',   val(rawData['range_zone'])),
        ('Map Link',       val(rawData['map_link'])),
      ]),
      ('TERMS', [
        ('Margin',        val(rawData['margin'])),
        ('CD Condition',  val(rawData['cd_condition'])),
        ('Payment Type',  val(rawData['payment_type'] ?? rawData['payment_term'])),
        ('Deal',          val(rawData['deal'])),
        ('Behaviour',     val(rawData['behaviour'])),
      ]),
      ('COMPLIANCE', [
        ('DL 1',          val(rawData['dl_1'] ?? rawData['drug_license'])),
        ('DL 2',          val(rawData['dl_2'])),
        ('GST',           val(rawData['gst'] ?? rawData['gstin'])),
        ('Store Type',    val(rawData['store_type'])),
        ('Approved By',   val(rawData['approved_by'])),
      ]),
      ('NOTES', [
        ('Notes', val(rawData['notes'])),
      ]),
    ];

    const gridColor  = Color(0xFFD0D7DE);
    const catBg      = Colors.white;
    const fieldBg    = Colors.white;
    const evenRowBg  = Colors.white;
    const oddRowBg   = Colors.white;
    const emptyColor = Color(0xFF8C959F);
    const valueColor = Color(0xFF24292F);
    const border     = BorderSide(color: gridColor);

    return LayoutBuilder(builder: (ctx, constraints) {
      final isMobile    = constraints.maxWidth < 600;
      final fieldColW   = isMobile ? 120.0 : 180.0;

      // Build a flat list of row widgets: category header + data rows.
      final tableRows = <Widget>[];
      int globalRowIndex = 0;

      for (final group in groups) {
        // Category header — green left accent bar, light bg, no outer L/R border.
        tableRows.add(Row(children: [
          Container(width: 3, height: 28, color: const Color(0xFF1B8A5A)),
          Expanded(child: Container(
            height: 28,
            color: catBg,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            child: Text('▸ ${group.$1}',
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    color: Color(0xFF1B8A5A), letterSpacing: 0.8)),
          )),
        ]));

        for (int i = 0; i < group.$2.length; i++) {
          final field    = group.$2[i];
          final isEmpty  = field.$2 == '—';
          final rowColor = globalRowIndex.isEven ? evenRowBg : oddRowBg;
          // Hairline divider between data rows; none above first row (header already provides bottom).
          final topBorder = i == 0 ? BorderSide.none : border;

          tableRows.add(SizedBox(
            height: 36,
            child: Row(children: [
              // FIELD NAME cell — no outer left border, hairline right divider only
              Container(
                width: fieldColW,
                decoration: BoxDecoration(
                  color: fieldBg,
                  border: Border(
                    top:   topBorder,
                    right: border, // vertical divider between label and value
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                alignment: Alignment.centerLeft,
                child: Text(field.$1,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600,
                        color: Color(0xFF57606A)),
                    overflow: TextOverflow.ellipsis),
              ),
              // VALUE cell — no outer right border
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: rowColor,
                    border: Border(top: topBorder),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  alignment: Alignment.centerLeft,
                  child: Text(field.$2,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: isEmpty ? emptyColor : valueColor),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1),
                ),
              ),
            ]),
          ));
          globalRowIndex++;
        }
      }

      // Pure white. Left padding aligns panel with the supplier name column above.
      return Container(
        color: Colors.white,
        padding: EdgeInsets.only(left: lpad.toDouble()),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: tableRows,
        ),
      );
    });
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  Widget _emptyState(String msg) {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE5E7EB))),
          child: const Icon(Icons.inbox_outlined, size: 28, color: Color(0xFFD1D5DB)),
        ),
        const SizedBox(height: 16),
        Text(msg, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
      ])),
    );
  }

  static Widget _th(String label, {int flex = 1}) => Expanded(
      flex: flex,
      child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF9CA3AF), letterSpacing: 0.5)));

  static Widget _pendingBadge() => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFD97706).withValues(alpha: 0.4)),
      ),
      child: const Text('Pending', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFFD97706))));

  static Widget _mobileField(String label, String value) => RichText(
      text: TextSpan(children: [
        TextSpan(text: '$label: ', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF9CA3AF))),
        TextSpan(text: value,      style: const TextStyle(fontSize: 11, color: Color(0xFF374151))),
      ]));

  static Widget _actionBtn(String label, Color color, VoidCallback onTap) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ));
}

// ── Extension ─────────────────────────────────────────────────────────────────

extension _Let<T> on T {
  R let<R>(R Function(T) fn) => fn(this);
}

// ── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    final IconData icon;
    switch (status) {
      case 'Suspended':
        color = const Color(0xFFD97706); label = 'Suspended'; icon = Icons.block_outlined;
        break;
      case 'Blocked':
        color = const Color(0xFFDC2626); label = 'Blocked'; icon = Icons.block;
        break;
      case 'Inactive':
        color = const Color(0xFF6B7280); label = 'Inactive'; icon = Icons.pause_circle_outline;
        break;
      case 'Active':
      default:
        color = const Color(0xFF1B7A43); label = 'Active'; icon = Icons.verified_outlined;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color), const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }
}

// ── Status pill (inline dropdown) ────────────────────────────────────────────

class _StatusPill extends StatefulWidget {
  final String supplierId;
  final String initialStatus;
  final void Function(String newStatus, num? spn) onStatusChanged;
  const _StatusPill({
    super.key,
    required this.supplierId,
    required this.initialStatus,
    required this.onStatusChanged,
  });
  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill> {
  static const _options = ['Active', 'Inactive', 'Suspended', 'Blocked'];
  static const _colors  = {
    'Active':    Color(0xFF1B7A43),
    'Inactive':  Color(0xFF6B7280),
    'Suspended': Color(0xFFD97706),
    'Blocked':   Color(0xFFDC2626),
  };

  late String _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialStatus;
  }

  Color get _color => _colors[_selected] ?? const Color(0xFF6B7280);
  String get _label => _selected.isNotEmpty ? _selected : 'Active';

  // Returns the DB-recomputed SPN on success, or null on failure.
  // SPN is a GENERATED column — must be read back; client cannot compute it.
  Future<num?> _write(String newStatus) async {
    RenderLog.write('status_pill_write', '$_selected→$newStatus');
    try {
      final res = await Supabase.instance.client
          .from('supplier_profiles')
          .update({'status': newStatus})
          .eq('id', widget.supplierId)
          .select('id, "SPN"')
          .timeout(const Duration(seconds: 8));
      RenderLog.write('status_pill_result', res.isEmpty ? 'EMPTY' : 'OK');
      if (!mounted) return null;
      if (res.isEmpty) {
        showToast(context, 'Save failed — try again', isError: true);
        return null;
      }
      showToast(context, 'Status updated ✓', duration: const Duration(milliseconds: 800));
      return res.first['SPN'] as num?;
    } catch (e) {
      RenderLog.write('status_pill_error', e.toString());
      if (mounted) showToast(context, 'Error: $e', isError: true);
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('status_pill_rendered', _selected);
    return PopupMenuButton<String>(
      initialValue: _selected,
      tooltip: '',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (val) async {
        if (val == _selected) return;
        final prev = _selected;
        setState(() => _selected = val);   // optimistic local update
        final spn = await _write(val);
        // _write returns null only on error (shows toast itself); SPN=0 is num 0, not null.
        if (spn == null) {
          if (mounted) setState(() => _selected = prev);
          return;
        }
        widget.onStatusChanged(val, spn);
      },
      itemBuilder: (_) => _options.map((opt) {
        final c = _colors[opt] ?? const Color(0xFF6B7280);
        return PopupMenuItem<String>(
          value: opt,
          height: 36,
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(opt, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c)),
          ]),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _color.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.arrow_drop_down, size: 12, color: _color),
          const SizedBox(width: 2),
          Text(_label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _color)),
        ]),
      ),
    );
  }
}

// ── Payment badge ─────────────────────────────────────────────────────────────

class _PaymentBadge extends StatelessWidget {
  final String term;
  const _PaymentBadge({required this.term});

  @override
  Widget build(BuildContext context) {
    final isAdvance = term.toLowerCase().contains('advance') || term.toLowerCase() == 'adv';
    final color = isAdvance ? const Color(0xFF1E40AF) : const Color(0xFF0891B2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(term, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

// ── Order status actions ───────────────────────────────────────────────────────

class _OrderStatusActions extends StatefulWidget {
  final String orderId;
  final String status;
  final Future<void> Function(String id, String status) onUpdate;
  const _OrderStatusActions({required this.orderId, required this.status, required this.onUpdate});

  @override
  State<_OrderStatusActions> createState() => _OrderStatusActionsState();
}

class _OrderStatusActionsState extends State<_OrderStatusActions> {
  bool _busy = false;

  Future<void> _act(String status) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onUpdate(widget.orderId, status);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) return const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)));
    final s = widget.status;
    if (s == 'confirmed') return _chip('Confirmed', const Color(0xFF1B7A43));
    if (s == 'rejected')  return _chip('Rejected',  const Color(0xFFDC2626));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _btn('Accept', const Color(0xFF1B7A43), () => _act('confirmed')),
      const SizedBox(width: 4),
      _btn('Reject', const Color(0xFFDC2626), () => _act('rejected')),
    ]);
  }

  Widget _chip(String label, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)));

  Widget _btn(String label, Color color, VoidCallback onTap) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withValues(alpha: 0.3))),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ));
}

// ── Approve / Reject actions ──────────────────────────────────────────────────

class _ApproveActions extends StatefulWidget {
  final String id;
  final Future<void> Function() onApprove;
  final Future<void> Function() onReject;
  const _ApproveActions({required this.id, required this.onApprove, required this.onReject});

  @override
  State<_ApproveActions> createState() => _ApproveActionsState();
}

class _ApproveActionsState extends State<_ApproveActions> {
  bool _busy = false;

  Future<void> _act(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await fn(); } catch (e) {
      if (mounted) showToast(context, 'Action failed: $e', isError: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) return const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)));
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
        decoration: BoxDecoration(color: color.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withValues(alpha: 0.3))),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ));
}

// ── Supplier edit dialog ───────────────────────────────────────────────────────

class _SupplierEditDialog extends StatefulWidget {
  final _SupRow row;
  const _SupplierEditDialog({required this.row});

  @override
  State<_SupplierEditDialog> createState() => _SupplierEditDialogState();
}

class _SupplierEditDialogState extends State<_SupplierEditDialog> {
  late final Map<String, TextEditingController> _ctrls;
  bool _saving = false;
  CodeStatus _supCodeStatus = CodeStatus.idle;

  static const _fields = [
    ('supplier_name',    'Supplier Name'),
    ('contact_name',     'Contact Name'),
    ('phone',            'Phone'),
    ('whatsapp_no',      'WhatsApp No.'),
    ('email',            'Email'),
    ('payment_address',  'Payment Address (UPI)'),
    ('supplier_code',    'Supplier Code'),
    ('payment_term',     'Payment Term'),
    ('city',             'City'),
    ('state',            'State'),
    ('pincode',          'PIN Code'),
    ('gstin',            'GSTIN'),
    ('drug_license',     'Drug License'),
    ('notes',            'Notes'),
  ];

  String? _upiError;

  @override
  void initState() {
    super.initState();
    _ctrls = {
      for (final f in _fields)
        f.$1: TextEditingController(text: widget.row.rawData[f.$1]?.toString() ?? '')
    };
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // Validate UPI payment address before acquiring saving lock
    final upiRaw = _ctrls['payment_address']!.text.trim();
    if (upiRaw.isNotEmpty &&
        !RegExp(r'^[0-9A-Za-z._\-]{2,}@[A-Za-z]{2,}$').hasMatch(upiRaw)) {
      setState(() => _upiError = 'Enter a valid UPI id (name@bank)');
      return;
    }
    setState(() { _saving = true; _upiError = null; });
    try {
      // Explicitly build only the writable fields — never include SPN (GENERATED ALWAYS)
      // or any computed/aggregate columns. _fields lists exactly the editable columns.
      final update = <String, dynamic>{
        for (final f in _fields) f.$1: _ctrls[f.$1]!.text.trim(),
      };
      // Coerce empty payment_address to null (column is nullable)
      if ((update['payment_address'] as String? ?? '').isEmpty) {
        update['payment_address'] = null;
      }
      await Supabase.instance.client
          .from('supplier_profiles')
          .update(update)
          .eq('id', widget.row.id)
          .select();
      if (mounted) {
        RenderLog.write('supplier_edit_saved', 'true');
        showToast(context, 'Saved ✓');
        Navigator.pop(context, true);
      }
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 520, maxHeight: MediaQuery.of(context).size.height * 0.88),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Edit Supplier', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827)))),
              IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(context), visualDensity: VisualDensity.compact),
            ]),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: Wrap(spacing: 12, runSpacing: 12, children: [
                  for (final f in _fields)
                    SizedBox(
                      width: 220,
                      child: f.$1 == 'supplier_code'
                          ? CodeField(
                              controller: _ctrls['supplier_code']!,
                              label: 'Supplier Code',
                              hint: 'ABC123',
                              isTaken: (code) async => await Supabase.instance.client
                                  .rpc('is_supplier_code_taken', params: {'p_code': code}) as bool,
                              originalCode: widget.row.rawData['supplier_code']?.toString(),
                              requiredField: false,
                              onStatusChanged: (s) => setState(() => _supCodeStatus = s),
                            )
                          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(f.$2, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280), fontWeight: FontWeight.w500)),
                              const SizedBox(height: 4),
                              TextField(
                                controller: _ctrls[f.$1],
                                keyboardType: f.$1 == 'payment_address'
                                    ? TextInputType.emailAddress
                                    : TextInputType.text,
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                  hintText: f.$1 == 'payment_address' ? 'name@bank' : null,
                                  hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                                  errorText: f.$1 == 'payment_address' ? _upiError : null,
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                                ),
                                style: const TextStyle(fontSize: 13),
                                onChanged: f.$1 == 'payment_address'
                                    ? (_) { if (_upiError != null) setState(() => _upiError = null); }
                                    : null,
                              ),
                            ]),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280)))),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: (_saving || _supCodeStatus == CodeStatus.taken || _supCodeStatus == CodeStatus.invalid) ? null : _save,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ── CSV import dialog ─────────────────────────────────────────────────────────

class _SupCsvColMap {
  final int index;
  final String header;
  final List<String> samples;
  String mappedTo;
  _SupCsvColMap({required this.index, required this.header, required this.samples, required this.mappedTo});
}

enum _SupCsvStep { reading, mapping, importing }

class _SupCsvImportDialog extends StatefulWidget {
  final html.File file;
  final VoidCallback onImported;
  const _SupCsvImportDialog({required this.file, required this.onImported});

  @override
  State<_SupCsvImportDialog> createState() => _SupCsvImportDialogState();
}

class _SupCsvImportDialogState extends State<_SupCsvImportDialog> {
  _SupCsvStep _step = _SupCsvStep.reading;
  String _statusMsg = 'Reading file…';
  List<_SupCsvColMap> _cols = [];
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
      final headers  = lines.first.split(',').map((h) => h.trim()).toList();
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

      final entries = <Map<String, dynamic>>[];
      for (int i = 0; i < headers.length; i++) {
        final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.isNotEmpty).take(5).toList();
        entries.add({'index': i, 'header': headers[i], 'samples': samples});
      }
      final prompt = 'Map each CSV column to the correct lead field.\n\n'
          'Lead fields:\n- name: full name\n- email: email address\n- mobile: phone/mobile number\n- ignore: skip\n\n'
          'Columns:\n${jsonEncode(entries)}\n\nReturn ONLY a JSON array: [{"index":0,"mapped_to":"name"},...]';

      final idxMap = <int, String>{};
      try {
        final resp = await http.post(
          Uri.parse(_ocrEdgeFn),
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
      } catch (_) {}

      // Heuristic fallback
      for (int i = 0; i < headers.length; i++) {
        if (idxMap.containsKey(i)) continue;
        final h = headers[i].toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
        if (['name','fullname','suppliername','contactname','leadname'].contains(h)) {
          idxMap[i] = 'name';
        } else if (['email','emailaddress','mail'].contains(h)) {
          idxMap[i] = 'email';
        } else if (['mobile','phone','mobilenumber','phonenumber','contact','cell'].contains(h)) {
          idxMap[i] = 'mobile';
        } else {
          idxMap[i] = 'ignore';
        }
      }

      final cols = List.generate(headers.length, (i) {
        final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.isNotEmpty).take(3).toList();
        return _SupCsvColMap(index: i, header: headers[i], samples: samples, mappedTo: idxMap[i] ?? 'ignore');
      });

      setState(() { _cols = cols; _dataRows = dataRows; _step = _SupCsvStep.mapping; });
    } catch (e) {
      setState(() { _error = 'Failed to read CSV: $e'; });
    }
  }

  Future<void> _doImport() async {
    setState(() { _step = _SupCsvStep.importing; });
    try {
      final nameCol   = _cols.firstWhereOrNull((c) => c.mappedTo == 'name');
      final emailCol  = _cols.firstWhereOrNull((c) => c.mappedTo == 'email');
      final mobileCol = _cols.firstWhereOrNull((c) => c.mappedTo == 'mobile');
      final toInsert  = <Map<String, dynamic>>[];
      for (final row in _dataRows) {
        final name   = nameCol   != null && nameCol.index   < row.length ? row[nameCol.index]   : '';
        final email  = emailCol  != null && emailCol.index  < row.length ? row[emailCol.index]  : '';
        final mobile = mobileCol != null && mobileCol.index < row.length ? row[mobileCol.index] : '';
        if (name.isEmpty && email.isEmpty && mobile.isEmpty) continue;
        toInsert.add({'name': name, 'email': email, 'mobile': mobile, 'source': 'csv_import', 'status': 'new'});
      }
      if (toInsert.isNotEmpty) {
        await Supabase.instance.client.from('supplier_leads').insert(toInsert);
      }
      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        showToast(context, 'Imported ${toInsert.length} lead${toInsert.length == 1 ? '' : 's'}');
      }
    } catch (e) {
      if (mounted) {
        setState(() { _step = _SupCsvStep.mapping; });
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
      Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Color(0xFF111827))),
      const SizedBox(height: 16),
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
    ]);
  }

  Widget _buildContent() {
    if (_step == _SupCsvStep.reading || _step == _SupCsvStep.importing) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
        const SizedBox(height: 16),
        Text(_step == _SupCsvStep.reading ? _statusMsg : 'Importing…',
            style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('Map CSV Columns', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827)))),
        IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.of(context).pop(), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
      ]),
      const SizedBox(height: 4),
      const Text('Gemini has auto-mapped your columns. Correct any mismatches before importing.',
          style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      const SizedBox(height: 16),
      ...List.generate(_cols.length, (i) {
        final col = _cols[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(col.header.isNotEmpty ? col.header : 'Column ${i + 1}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
              if (col.samples.isNotEmpty)
                Text(col.samples.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            ])),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(color: const Color(0xFFF5F6F8), border: Border.all(color: const Color(0xFFE5E7EB)), borderRadius: BorderRadius.circular(8)),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: col.mappedTo, isExpanded: true,
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
            )),
          ]),
        );
      }),
      const SizedBox(height: 8),
      Text('${_dataRows.length} row${_dataRows.length == 1 ? '' : 's'} will be imported',
          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280)))),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _doImport,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          child: const Text('Import', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ]),
    ]);
  }
}

// ─── Supplier Profile Import (CSV / Excel / ODS / PDF / DOCX / Images) ── #70 ─

class _SupProfColMap {
  final int index;
  final String header;
  final List<String> samples;
  String mappedTo;
  String newColName;
  String newColType;
  _SupProfColMap({required this.index, required this.header, required this.samples, required this.mappedTo,
    this.newColName = '', this.newColType = 'text'});
}

enum _SupProfStep { reading, mapping, importing }

class _SupProfileImportDialog extends StatefulWidget {
  final html.File file;
  final VoidCallback onImported;
  const _SupProfileImportDialog({required this.file, required this.onImported});
  @override
  State<_SupProfileImportDialog> createState() => _SupProfileImportDialogState();
}

class _SupProfileImportDialogState extends State<_SupProfileImportDialog> {
  _SupProfStep _step = _SupProfStep.reading;
  String _statusMsg = 'Reading file…';
  List<_SupProfColMap> _cols = [];
  List<List<String>> _dataRows = [];
  String? _error;
  final Map<int, TextEditingController> _newColCtrls = {};
  List<String> _dynamicFields = [];

  static const _baseFields = [
    'supplier_name', 'company_name',
    'contact_person', 'contact_no', 'whatsapp_no', 'email',
    'status', 'margin', 'behaviour', 'cd_condition', 'payment_type', 'deal',
    'street_address', 'city', 'state', 'pin_code', 'map_link',
    'stockist_type', 'dl_1', 'dl_2', 'gst',
  ];
  static const _profileFields = [
    'supplier_name', 'contact_person', 'contact_no', 'whatsapp_no', 'email',
    'status', 'margin', 'behaviour', 'cd_condition', 'payment_type', 'deal',
    'street_address', 'city', 'state', 'pin_code', 'map_link',
    'stockist_type', 'dl_1', 'dl_2', 'gst',
  ];
  List<String> get _fields => [..._baseFields, ..._dynamicFields, 'ignore'];

  static String _fieldLabel(String f) => switch (f) {
    'supplier_name'  => 'Supplier Name *',
    'company_name'   => 'Company Name (→ supplier_company)',
    'contact_person' => 'Contact Person',
    'contact_no'     => 'Contact No',
    'whatsapp_no'    => 'WhatsApp No',
    'email'          => 'Email',
    'status'         => 'Status',
    'margin'         => 'Margin',
    'behaviour'      => 'Behaviour',
    'cd_condition'   => 'CD Condition',
    'payment_type'   => 'Payment Type',
    'deal'           => 'Deal',
    'street_address' => 'Street Address',
    'city'           => 'City',
    'state'          => 'State',
    'pin_code'       => 'Pin Code',
    'map_link'       => 'Map Link',
    'stockist_type'  => 'Stockist Type',
    'dl_1'           => 'DL 1',
    'dl_2'           => 'DL 2',
    'gst'            => 'GST',
    _                => '— Ignore —',
  };

  @override
  void initState() { super.initState(); _parseAndMap(); }

  @override
  void dispose() {
    for (final c in _newColCtrls.values) c.dispose();
    super.dispose();
  }

  // ── File parsing (reused from Add-Medicine pipeline) ─────────────────────────

  Future<String> _readAsText(html.File f) async {
    final r = html.FileReader(); r.readAsText(f); await r.onLoad.first;
    return (r.result as String).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  Future<Uint8List> _readBytes(html.File f) async {
    final r = html.FileReader(); r.readAsDataUrl(f); await r.onLoad.first;
    return base64Decode((r.result as String).split(',').last);
  }

  Future<String> _pdfText(Uint8List bytes) async {
    try {
      final doc = PdfDocument(inputBytes: bytes);
      final t = PdfTextExtractor(doc).extractText();
      doc.dispose(); return t;
    } catch (_) { return ''; }
  }

  String _xlsxBytesText(Uint8List bytes) {
    Archive archive;
    try { archive = ZipDecoder().decodeBytes(bytes); }
    catch (_) { throw Exception('Could not open Excel file.'); }
    ArchiveFile? find(String p) {
      final lo = p.toLowerCase();
      for (final x in archive) { if (x.name.toLowerCase() == lo) return x; }
      return null;
    }
    final ss = <String>[];
    final ssf = find('xl/sharedStrings.xml');
    if (ssf != null) {
      try {
        final doc = xmlp.XmlDocument.parse(utf8.decode(ssf.content as List<int>));
        for (final si in doc.findAllElements('si')) {
          ss.add(si.findAllElements('t').map((t) => t.innerText).join());
        }
      } catch (_) {}
    }
    ArchiveFile? shf;
    for (int n = 1; n <= 10; n++) { shf = find('xl/worksheets/sheet$n.xml'); if (shf != null) break; }
    if (shf == null) throw Exception('No worksheet found in Excel file.');
    final wsDoc = xmlp.XmlDocument.parse(utf8.decode(shf.content as List<int>));
    String? rc(xmlp.XmlElement cell) {
      final t = cell.getAttribute('t');
      if (t == 'inlineStr') return cell.findAllElements('t').map((e) => e.innerText).join();
      if (t == 's') {
        final v = cell.findElements('v').firstOrNull?.innerText;
        if (v == null) return null;
        final idx = int.tryParse(v);
        if (idx == null || idx >= ss.length) return null;
        return ss[idx];
      }
      return cell.findElements('v').firstOrNull?.innerText;
    }
    final sb = StringBuffer();
    for (final row in wsDoc.findAllElements('row')) {
      final cells = <String, String>{};
      for (final cell in row.findElements('c')) {
        final ref = cell.getAttribute('r') ?? '';
        final col = ref.replaceAll(RegExp(r'[0-9]'), '');
        if (col.isNotEmpty) cells[col] = rc(cell) ?? '';
      }
      if (cells.isEmpty) continue;
      final cols = cells.keys.toList()..sort();
      sb.writeln(cols.map((c) => cells[c]!).join('\t'));
    }
    return sb.toString();
  }

  String _odsBytesText(Uint8List bytes) {
    Archive archive;
    try { archive = ZipDecoder().decodeBytes(bytes); }
    catch (_) { throw Exception('Could not open ODS file.'); }
    ArchiveFile? cf;
    for (final x in archive) { if (x.name.toLowerCase() == 'content.xml') { cf = x; break; } }
    if (cf == null) throw Exception('Not a valid ODS file.');
    final doc = xmlp.XmlDocument.parse(utf8.decode(cf.content as List<int>));
    String ct(xmlp.XmlElement cell) {
      final ps = cell.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'p');
      return ps.isNotEmpty ? ps.map((e) => e.innerText).join(' ').trim() : '';
    }
    final sb = StringBuffer();
    for (final tbl in doc.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'table')) {
      for (final row in tbl.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'table-row')) {
        final cells = row.descendants.whereType<xmlp.XmlElement>()
            .where((e) => e.localName == 'table-cell' || e.localName == 'covered-table-cell').toList();
        if (cells.isEmpty) continue;
        sb.writeln(cells.map(ct).join('\t'));
      }
    }
    return sb.toString();
  }

  String _docxBytesText(Uint8List bytes) {
    Archive archive;
    try { archive = ZipDecoder().decodeBytes(bytes); }
    catch (_) { throw Exception('Could not open DOCX file.'); }
    ArchiveFile? df;
    for (final x in archive) { if (x.name.toLowerCase() == 'word/document.xml') { df = x; break; } }
    if (df == null) throw Exception('Not a valid DOCX file.');
    final doc = xmlp.XmlDocument.parse(utf8.decode(df.content as List<int>));
    final sb = StringBuffer();
    for (final p in doc.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'p')) {
      final t = p.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 't').map((e) => e.innerText).join();
      if (t.trim().isNotEmpty) sb.writeln(t);
    }
    return sb.toString();
  }

  ({List<String> headers, List<List<String>> rows}) _textToTable(String text) {
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return (headers: [], rows: []);
    final sep = lines.first.contains('\t') ? '\t' : ',';
    var allRows = lines.map((l) =>
        l.split(sep).map((c) => c.trim().replaceAll(RegExp(r'''^["']+|["']+$'''), '')).toList()
    ).toList();
    if (allRows.isEmpty) return (headers: [], rows: []);
    final maxCols = allRows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    allRows = allRows.map((r) {
      if (r.length < maxCols) return [...r, ...List.filled(maxCols - r.length, '')];
      return r;
    }).toList();
    final first = allRows[0];
    final isHdr = first.every((c) => double.tryParse(c.replaceAll(RegExp(r'[₹,\s]'), '')) == null);
    if (isHdr && allRows.length > 1) return (headers: first, rows: allRows.sublist(1));
    return (headers: List.filled(maxCols, ''), rows: allRows);
  }

  Future<({List<String> headers, List<List<String>> rows})> _geminiTable(
      bool isImage, String mime, String b64, String pdfMime) async {
    final prompt =
        'Extract the tabular supplier data from this file. '
        'Return ONLY a JSON object (no markdown fences):\n'
        '{"headers":["col1","col2"],"rows":[["v1","v2"],...]}\n'
        'Use empty string "" for missing headers. Include all data rows.';
    final resp = await http.post(
      Uri.parse(_ocrEdgeFn),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_base64': b64,
        'mime_type': isImage ? mime : pdfMime,
        'prompt': prompt,
      }),
    ).timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) throw Exception('OCR API error (HTTP ${resp.statusCode})');
    final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
    if (txt.isEmpty) throw Exception('Empty response from OCR service');
    final jm = RegExp(r'\{[\s\S]*\}').firstMatch(txt);
    if (jm == null) throw Exception('Could not parse table from file');
    final dec = jsonDecode(jm.group(0)!) as Map<String, dynamic>;
    final headers = (dec['headers'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    final rows = (dec['rows'] as List<dynamic>?)
        ?.map((r) => (r as List<dynamic>).map((e) => e.toString()).toList()).toList() ?? [];
    return (headers: headers, rows: rows);
  }

  Future<({List<String> headers, List<List<String>> rows})> _parseFile(html.File f) async {
    final ext = f.name.toLowerCase().split('.').last;
    switch (ext) {
      case 'csv': case 'tsv': case 'txt':
        return _textToTable(await _readAsText(f));
      case 'xlsx': case 'xls':
        return _textToTable(_xlsxBytesText(await _readBytes(f)));
      case 'ods':
        return _textToTable(_odsBytesText(await _readBytes(f)));
      case 'docx':
        return _textToTable(_docxBytesText(await _readBytes(f)));
      case 'pdf':
        final bytes = await _readBytes(f);
        final local = await _pdfText(bytes);
        if (local.trim().length > 20) return _textToTable(local);
        return _geminiTable(false, '', base64Encode(bytes), 'application/pdf');
      case 'jpg': case 'jpeg':
        return _geminiTable(true, 'image/jpeg', base64Encode(await _readBytes(f)), '');
      case 'png':
        return _geminiTable(true, 'image/png', base64Encode(await _readBytes(f)), '');
      case 'webp':
        return _geminiTable(true, 'image/webp', base64Encode(await _readBytes(f)), '');
      case 'heic': case 'heif':
        return _geminiTable(true, 'image/heic', base64Encode(await _readBytes(f)), '');
      case 'gif':
        return _geminiTable(true, 'image/gif', base64Encode(await _readBytes(f)), '');
      default:
        return _textToTable(await _readAsText(f));
    }
  }

  Future<List<_SupProfColMap>> _geminiMapCols(List<String> headers, List<List<String>> dataRows) async {
    final allMappable = [..._baseFields, ..._dynamicFields];
    final entries = List.generate(headers.length, (i) {
      final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.trim().isNotEmpty).take(5).toList();
      return {'index': i, 'header': headers[i], 'samples': samples};
    });
    const basePrompt =
        'Map each CSV column to the correct field for importing supplier data.\n\n'
        'Fields: supplier_name (Firm/Supplier name, REQUIRED), '
        'company_name (Pharma company/brand the supplier stocks, goes to supplier_company table), '
        'contact_person, contact_no, whatsapp_no, email, city, state, street_address, pin_code, '
        'gst, dl_1, dl_2, margin, cd_condition, payment_type, deal, status, stockist_type, behaviour, map_link, '
        'ignore (skip this column).\n\n'
        'Rules: Firm/Supplier/Distributor name = supplier_name. '
        'Company/Brand/CO SUPPLIER/Supplier Company = company_name. '
        'Serial numbers = ignore. Infer from header AND samples.\n\n';
    final idxMap = <int, String>{};
    try {
      final resp = await http.post(
        Uri.parse(_ocrEdgeFn),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'image_base64': '', 'mime_type': 'text/plain', 'prompt': '${basePrompt}Columns:\n${jsonEncode(entries)}\n\nReturn ONLY a JSON array: [{"index":0,"mapped_to":"supplier_name"},...]'}),
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
        final jm = RegExp(r'\[[\s\S]*\]').firstMatch(txt);
        if (jm != null) {
          for (final m in jsonDecode(jm.group(0)!) as List<dynamic>) {
            final mm = m as Map<String, dynamic>;
            final idx = mm['index'] as int?;
            final mapped = mm['mapped_to'] as String? ?? 'ignore';
            if (idx != null) idxMap[idx] = (allMappable.contains(mapped) || mapped == 'ignore') ? mapped : 'ignore';
          }
        }
      }
    } catch (_) {}
    final used = <String>{...idxMap.values};
    for (int i = 0; i < headers.length; i++) {
      if (idxMap.containsKey(i)) continue;
      final h = headers[i].toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
      String mapped = 'ignore';
      if (['suppliername','firmname','supplier','firm','distributor'].contains(h) && !used.contains('supplier_name')) mapped = 'supplier_name';
      else if (['companyname','company','brand','manufacturer','cosupplier','suppliercompany','pharmacompany'].contains(h) && !used.contains('company_name')) mapped = 'company_name';
      else if (['contactname','contactperson','contact','name'].contains(h) && !used.contains('contact_person')) mapped = 'contact_person';
      else if (['phone','mobile','mobilenumber','phonenumber','cell','contactno'].contains(h) && !used.contains('contact_no')) mapped = 'contact_no';
      else if (['email','emailaddress','mail'].contains(h) && !used.contains('email')) mapped = 'email';
      else if (['whatsapp','whatsappno'].contains(h) && !used.contains('whatsapp_no')) mapped = 'whatsapp_no';
      else if (['city','town'].contains(h) && !used.contains('city')) mapped = 'city';
      else if (['state','province'].contains(h) && !used.contains('state')) mapped = 'state';
      else if (['address','addr','streetaddress','street'].contains(h) && !used.contains('street_address')) mapped = 'street_address';
      else if (['pincode','pin','zip','pinno'].contains(h) && !used.contains('pin_code')) mapped = 'pin_code';
      else if (['gst','gstin','gstnumber'].contains(h) && !used.contains('gst')) mapped = 'gst';
      else if (['dl1','druglicense1','druglicense'].contains(h) && !used.contains('dl_1')) mapped = 'dl_1';
      else if (['dl2','druglicense2'].contains(h) && !used.contains('dl_2')) mapped = 'dl_2';
      else if (['paymenttype','paymentterm','paymentterms','creditdays'].contains(h) && !used.contains('payment_type')) mapped = 'payment_type';
      else if (['stockisttype','storetype','type','vendortype'].contains(h) && !used.contains('stockist_type')) mapped = 'stockist_type';
      else if (['margin','trademargin','discount'].contains(h) && !used.contains('margin')) mapped = 'margin';
      else if (['behaviour','behavior'].contains(h) && !used.contains('behaviour')) mapped = 'behaviour';
      else if (['cdcondition','cd','cashdiscount'].contains(h) && !used.contains('cd_condition')) mapped = 'cd_condition';
      else if (['deal','scheme','bonus'].contains(h) && !used.contains('deal')) mapped = 'deal';
      else if (['maplink','maplocation','location'].contains(h) && !used.contains('map_link')) mapped = 'map_link';
      else if (['status'].contains(h) && !used.contains('status')) mapped = 'status';
      idxMap[i] = mapped;
      if (mapped != 'ignore') used.add(mapped);
    }
    return List.generate(headers.length, (i) {
      final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.isNotEmpty).take(3).toList();
      return _SupProfColMap(index: i, header: headers[i], samples: samples, mappedTo: idxMap[i] ?? 'ignore');
    });
  }

  Future<void> _confirmMapping() async {
    for (final col in _cols.where((c) => c.mappedTo == 'create_new')) {
      final name = (_newColCtrls[col.index]?.text ?? '').trim();
      if (name.isEmpty) {
        showToast(context, 'Enter a name for the new column "${col.header.isNotEmpty ? col.header : "Column ${col.index + 1}"}"');
        return;
      }
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
        showToast(context, '"$name" is invalid — use lowercase letters, numbers, underscores, starting with a letter');
        return;
      }
      if (_profileFields.contains(name)) {
        showToast(context, '"$name" already exists — map directly to that column instead');
        return;
      }
      col.newColName = name;
    }

    // Create new columns via RPC
    final toCreate = _cols.where((c) => c.mappedTo == 'create_new').toList();
    if (toCreate.isNotEmpty) {
      setState(() { _step = _SupProfStep.importing; _statusMsg = 'Creating new columns…'; });
      for (final col in toCreate) {
        try {
          await Supabase.instance.client.rpc('add_supplier_column', params: {
            'col_name': col.newColName,
            'col_type': col.newColType,
          });
          setState(() {
            col.mappedTo = col.newColName;
            if (!_dynamicFields.contains(col.newColName)) _dynamicFields.add(col.newColName);
          });
        } catch (e) {
          if (!mounted) return;
          setState(() { _step = _SupProfStep.mapping; });
          showToast(context, 'Could not create column "${col.newColName}": ${e.toString().replaceFirst('Exception: ', '')}', duration: const Duration(seconds: 8));
          return;
        }
      }
      setState(() { _step = _SupProfStep.mapping; });
    }

    await _doImportUnified();
  }

  Future<void> _parseAndMap() async {
    try {
      setState(() { _step = _SupProfStep.reading; _statusMsg = 'Reading file…'; });
      final table = await _parseFile(widget.file);
      if (table.rows.isEmpty) throw Exception('No data rows found in the file.');
      setState(() { _statusMsg = 'Auto-mapping columns with Gemini…'; });
      final cols = await _geminiMapCols(table.headers, table.rows);
      setState(() { _cols = cols; _dataRows = table.rows; _step = _SupProfStep.mapping; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  Future<void> _doImportUnified() async {
    setState(() { _step = _SupProfStep.importing; _statusMsg = 'Importing…'; });
    try {
      final client = Supabase.instance.client;
      final colFor = <String, _SupProfColMap>{};
      for (final c in _cols) { if (c.mappedTo != 'ignore' && c.mappedTo != 'create_new') colFor[c.mappedTo] = c; }
      final allProfileFields = [..._profileFields, ..._dynamicFields];

      String rowVal(List<String> row, String field) {
        final c = colFor[field];
        return c != null && c.index < row.length ? row[c.index].trim() : '';
      }

      final hasCompanyCol = colFor.containsKey('company_name');

      final distinctNames = _dataRows
          .map((r) => rowVal(r, 'supplier_name'))
          .where((s) => s.isNotEmpty)
          .toSet().toList();
      if (distinctNames.isEmpty) throw Exception('No supplier_name column mapped.');

      final existingRows = await client.from('supplier_profiles')
          .select('id, supplier_name').inFilter('supplier_name', distinctNames);
      final supplierMap = <String, String>{};
      for (final r in existingRows as List<dynamic>) {
        supplierMap[(r['supplier_name'] as String).toLowerCase()] = r['id'] as String;
      }

      final toInsertProfiles = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final row in _dataRows) {
        final name = rowVal(row, 'supplier_name');
        if (name.isEmpty || seen.contains(name.toLowerCase())) continue;
        seen.add(name.toLowerCase());
        if (supplierMap.containsKey(name.toLowerCase())) continue;
        final rec = <String, dynamic>{'supplier_name': name, 'status': 'Active', 'approved': true, 'is_deleted': false};
        for (final f in allProfileFields.where((f) => f != 'supplier_name' && f != 'company_name')) {
          final v = rowVal(row, f);
          if (v.isNotEmpty) rec[f] = v;
        }
        toInsertProfiles.add(rec);
      }
      int profilesInserted = 0;
      if (toInsertProfiles.isNotEmpty) {
        final inserted = await client.from('supplier_profiles').insert(toInsertProfiles).select('id, supplier_name');
        for (final r in inserted as List<dynamic>) {
          supplierMap[(r['supplier_name'] as String).toLowerCase()] = r['id'] as String;
        }
        profilesInserted = inserted.length;
      }
      final profilesSkipped = distinctNames.length - profilesInserted;

      int scInserted = 0;
      if (hasCompanyCol) {
        final scRows = <Map<String, dynamic>>[];
        for (final row in _dataRows) {
          final supplierName = rowVal(row, 'supplier_name');
          final companyName  = rowVal(row, 'company_name');
          if (supplierName.isEmpty || companyName.isEmpty) continue;
          final supplierId = supplierMap[supplierName.toLowerCase()];
          if (supplierId == null) continue;
          scRows.add({'supplier_id': supplierId, 'supplier_company': companyName});
        }
        scInserted = scRows.length;
        for (int i = 0; i < scRows.length; i += 500) {
          final chunk = scRows.sublist(i, (i + 500).clamp(0, scRows.length));
          await client.from('supplier_company')
              .upsert(chunk, onConflict: 'supplier_id,supplier_company', ignoreDuplicates: true);
        }
      }

      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        final parts = <String>[];
        parts.add('$profilesInserted new supplier${profilesInserted == 1 ? "" : "s"}');
        if (profilesSkipped > 0) parts.add('$profilesSkipped already existed');
        if (hasCompanyCol) {
          parts.add('$scInserted company row${scInserted == 1 ? "" : "s"} saved');
          RenderLog.write('change76_import_inserted_background',
              {'rowCount': scInserted, 'suppliers': supplierMap.length});
        }
        showToast(
          context,
          hasCompanyCol
              ? 'Imported: ${parts.join(" · ")}. Matching companies in the background…'
              : 'Imported: ${parts.join(" · ")}',
          duration: const Duration(seconds: 6),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() { _step = _SupProfStep.mapping; });
        showToast(context, 'Import failed: ${e.toString().replaceFirst("Exception: ", "")}', isError: true, duration: const Duration(seconds: 8));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 32),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
            const SizedBox(height: 16),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          ]))),
      );
    }
    if (_step == _SupProfStep.reading || _step == _SupProfStep.importing) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
            const SizedBox(height: 16),
            Text(_statusMsg,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          ]))),
      );
    }
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 860, maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Import Suppliers — Map Columns',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                const SizedBox(height: 2),
                Text('${widget.file.name} · Gemini auto-mapped columns. Correct mismatches before importing.',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ])),
              IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
          ),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Flexible(child: LayoutBuilder(builder: (ctx, bc) {
            final isMobile = bc.maxWidth < 600;
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 24, vertical: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (!isMobile) ...[
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: Row(children: const [
                      Expanded(flex: 4, child: Text('FILE COLUMN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280), letterSpacing: 0.5))),
                      Expanded(flex: 5, child: Text('SAMPLE VALUES', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280), letterSpacing: 0.5))),
                      Expanded(flex: 5, child: Text('MAPS TO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280), letterSpacing: 0.5))),
                    ])),
                  const Divider(color: Color(0xFFE5E7EB)),
                ],
                ...List.generate(_cols.length, (i) {
                  final col = _cols[i];
                  if (isMobile) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE5E7EB))),
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(col.header.isNotEmpty ? col.header : 'Column ${i + 1}',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                          if (col.samples.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(col.samples.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                          ],
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            value: _fields.contains(col.mappedTo) || col.mappedTo == 'create_new' ? col.mappedTo : 'ignore',
                            isExpanded: true,
                            decoration: InputDecoration(isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                              filled: true, fillColor: Colors.white,
                            ),
                            items: [
                              ..._fields.map((f) => DropdownMenuItem(value: f,
                                  child: Text(_fieldLabel(f), style: const TextStyle(fontSize: 13)))),
                              const DropdownMenuItem(value: 'create_new',
                                  child: Text('+ Create new field', style: TextStyle(fontSize: 13, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600))),
                            ],
                            onChanged: (v) { if (v != null) setState(() => col.mappedTo = v); },
                          ),
                          if (col.mappedTo == 'create_new') ...[
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _newColCtrls[col.index] ??= TextEditingController(),
                              onChanged: (v) => col.newColName = v,
                              decoration: InputDecoration(isDense: true, hintText: 'new_column_name',
                                hintStyle: const TextStyle(color: Color(0xFFD1D5DB)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                filled: true, fillColor: const Color(0xFFECFDF5),
                              ),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ]),
                      ),
                    );
                  }
                  final isCreate = col.mappedTo == 'create_new';
                  final ctrl = _newColCtrls[col.index] ??= TextEditingController();
                  return Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                          Expanded(flex: 4, child: Text(
                            col.header.isNotEmpty ? col.header : 'Column ${i + 1}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                          )),
                          Expanded(flex: 5, child: Text(
                            col.samples.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                          )),
                          Expanded(flex: 5, child: DropdownButtonFormField<String>(
                            value: _fields.contains(col.mappedTo) || col.mappedTo == 'create_new' ? col.mappedTo : 'ignore',
                            decoration: InputDecoration(isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                              filled: true, fillColor: Colors.white,
                            ),
                            items: [
                              ..._fields.map((f) => DropdownMenuItem(value: f,
                                  child: Text(_fieldLabel(f), style: const TextStyle(fontSize: 13)))),
                              const DropdownMenuItem(value: 'create_new',
                                  child: Text('+ Create new field', style: TextStyle(fontSize: 13, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600))),
                            ],
                            onChanged: (v) { if (v != null) setState(() => col.mappedTo = v); },
                            style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                          )),
                        ]),
                        if (isCreate) ...[
                          const SizedBox(height: 8),
                          Row(children: [
                            const SizedBox(width: 12),
                            const Icon(Icons.subdirectory_arrow_right, size: 16, color: Color(0xFF9CA3AF)),
                            const SizedBox(width: 8),
                            Expanded(flex: 3, child: TextFormField(
                              controller: ctrl,
                              onChanged: (v) => col.newColName = v,
                              decoration: InputDecoration(isDense: true, hintText: 'new_column_name',
                                hintStyle: const TextStyle(color: Color(0xFFD1D5DB)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                filled: true, fillColor: const Color(0xFFECFDF5),
                              ),
                              style: const TextStyle(fontSize: 13),
                            )),
                            const SizedBox(width: 10),
                            const Text('Type:', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                            const SizedBox(width: 6),
                            Expanded(flex: 2, child: DropdownButtonFormField<String>(
                              value: col.newColType,
                              decoration: InputDecoration(isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                filled: true, fillColor: const Color(0xFFECFDF5),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'text', child: Text('text', style: TextStyle(fontSize: 13))),
                                DropdownMenuItem(value: 'numeric', child: Text('number', style: TextStyle(fontSize: 13))),
                                DropdownMenuItem(value: 'date', child: Text('date', style: TextStyle(fontSize: 13))),
                                DropdownMenuItem(value: 'boolean', child: Text('boolean', style: TextStyle(fontSize: 13))),
                              ],
                              onChanged: (v) { if (v != null) setState(() => col.newColType = v); },
                              style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                            )),
                          ]),
                        ],
                      ]),
                    ),
                    if (i < _cols.length - 1) const Divider(height: 1, color: Color(0xFFF3F4F6)),
                  ]);
                }),
                const SizedBox(height: 8),
                Text('${_dataRows.length} row${_dataRows.length == 1 ? '' : 's'} will be imported (suppliers + companies auto-split)',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ]),
            );
          })),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280)))),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _confirmMapping,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
                child: Text('Import ${_dataRows.length} Row${_dataRows.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── Destination tab widget for import dialog ──────────────────────────────────

class _DestTab extends StatelessWidget {
  final String label;
  final String sublabel;
  final bool selected;
  final VoidCallback onTap;
  const _DestTab({required this.label, required this.sublabel, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: selected ? Border.all(color: const Color(0xFF1B7A43), width: 1.5) : null,
          boxShadow: selected ? [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 4, offset: const Offset(0, 1))] : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? const Color(0xFF1B7A43) : const Color(0xFF6B7280))),
          const SizedBox(height: 2),
          Text(sublabel, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
        ]),
      ),
    );
  }
}

// ── Supplier Companies pill button (stateless — count from parent) ────────────

class _SupplierCompaniesButton extends StatelessWidget {
  final int count;
  final bool isOpen;
  const _SupplierCompaniesButton({required this.count, required this.isOpen});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isOpen ? const Color(0xFFDBEAFE) : const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF93C5FD)),
        ),
        child: Text('Companies ($count)',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                color: Color(0xFF2563EB))),
      ),
    );
  }
}

// ── Match status chip (shown on every supplier list card) ─────────────────────

class _MatchStatusChip extends StatelessWidget {
  final MatchStatus? status;
  final String supplierId;
  const _MatchStatusChip({required this.status, required this.supplierId});

  @override
  Widget build(BuildContext context) {
    final s = status;
    if (s == null || s.total == 0) return const SizedBox.shrink();

    // Render-log instrumentation (change #76).
    RenderLog.write('change76_status_chip_rendered', {
      'supplierId': supplierId,
      'matched': s.matched,
      'pending': s.pending,
      'isMatching': s.isMatching,
    });

    if (s.isMatching) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(
            width: 10, height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF92400E)),
          ),
          const SizedBox(width: 5),
          Text(
            'Matching… ${s.pending} left',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF92400E)),
          ),
        ]),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFD1FAE5),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF065F46).withValues(alpha: 0.3)),
        ),
        child: Text(
          '${s.matched}/${s.total} matched',
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF065F46)),
        ),
      ),
      if (s.needsReview > 0) ...[
        const SizedBox(width: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF3C7),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '${s.needsReview} review',
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: Color(0xFF92400E)),
          ),
        ),
      ],
    ]);
  }
}

// ── Match status header strip (shown inside _CompaniesInlineSection) ──────────

class _MatchStatusHeader extends StatelessWidget {
  final String supplierId;
  final MatchStatusService matchService;
  const _MatchStatusHeader({required this.supplierId, required this.matchService});

  @override
  Widget build(BuildContext context) {
    final s = matchService.statuses.value[supplierId];
    if (s == null || s.total == 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFFEFF6FF),
        border: Border(bottom: BorderSide(color: Color(0xFFBFDBFE))),
      ),
      child: s.isMatching
          ? Row(children: [
              const SizedBox(
                width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.8, color: Color(0xFF2563EB)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                    'Matching… ${s.pending} of ${s.total} remaining',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1E40AF)),
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: s.total > 0 ? s.matched / s.total : 0,
                      minHeight: 4,
                      backgroundColor: const Color(0xFFBFDBFE),
                      color: const Color(0xFF2563EB),
                    ),
                  ),
                ]),
              ),
            ])
          : Text(
              '${s.matched}/${s.total} matched'
              '${s.noMatch > 0 ? ' · ${s.noMatch} no match' : ''}'
              '${s.needsReview > 0 ? ' · ${s.needsReview} need review' : ''}',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF1E40AF)),
            ),
    );
  }
}

// ── Re-match (AI) button (change #76) ─────────────────────────────────────────

class _ReMatchButton extends StatelessWidget {
  final String supplierId;
  final MatchStatusService matchService;
  const _ReMatchButton({required this.supplierId, required this.matchService});

  @override
  Widget build(BuildContext context) {
    final s = matchService.statuses.value[supplierId];
    final isMatching = s?.isMatching ?? false;
    return TextButton.icon(
      onPressed: isMatching ? null : () async {
        try {
          await matchService.reMatch(supplierId);
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Re-match failed: $e'),
              backgroundColor: const Color(0xFFDC2626),
              duration: const Duration(seconds: 4),
            ));
          }
        }
      },
      icon: isMatching
          ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF2563EB)))
          : const Icon(Icons.auto_awesome, size: 15),
      label: Text(isMatching ? 'Matching…' : 'Re-match (AI)',
          style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF2563EB),
          visualDensity: VisualDensity.compact),
    );
  }
}

// ── Inline companies section (expands below row, not a popup) ─────────────────

class _CompaniesInlineSection extends StatefulWidget {
  final String supplierId;
  final String supplierName;
  final MatchStatusService matchService;
  final VoidCallback onCompanyAdded;
  const _CompaniesInlineSection({
    required this.supplierId,
    required this.supplierName,
    required this.matchService,
    required this.onCompanyAdded,
  });

  @override
  State<_CompaniesInlineSection> createState() => _CompaniesInlineSectionState();
}

class _CompaniesInlineSectionState extends State<_CompaniesInlineSection> {
  static final _companyCols = List.generate(30, (i) => 'company_${i + 1}');

  bool _loading = true;
  // null = idle, 'manual' = manual fuzzy running, 'ai' = Gemini running, 'fallback' = fallback running, 'save' = saving
  String? _mappingMode;
  bool get _refreshing => _mappingMode != null;
  bool _mapped = false;
  int _needsReview = 0;
  Set<int> _flaggedRows = {};
  int _aiProgress = 0;
  int _aiTotal = 0;
  String? _aiStage; // 'candidates' | 'gemini' | null
  List<Map<String, dynamic>> _rows = [];
  List<String> _medMarketers = [];
  List<String> _companyCorpus = [];
  bool _showAddForm = false;
  bool _saving = false;
  // Mobile two-level collapsible state (c69)
  final Set<int> _expandedRows = {};
  bool _masterExpanded = false;
  final Map<int, String?> _rowMappingMode = {}; // per-row: 'ai' | 'save' | null
  bool _c69CollapsedAfterSave = false;
  final _supplierCompanyCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  // Match-status listener (change #76)
  bool _wasMatching = false;
  void Function()? _statusListener;

  @override
  void initState() {
    super.initState();
    _load();
    // Ensure this supplier is included in visible IDs for polling.
    widget.matchService.setVisibleIds(
      List.unmodifiable({...widget.matchService.statuses.value.keys, widget.supplierId}.toList()),
    );
    _wasMatching = widget.matchService.statuses.value[widget.supplierId]?.isMatching ?? false;
    _statusListener = () {
      final s = widget.matchService.statuses.value[widget.supplierId];
      final nowMatching = s?.isMatching ?? false;
      if (_wasMatching && !nowMatching) {
        // Matching just finished — reload company rows to show updated matches.
        _load();
      }
      _wasMatching = nowMatching;
      if (mounted) setState(() {});
    };
    widget.matchService.statuses.addListener(_statusListener!);
  }

  @override
  void dispose() {
    if (_statusListener != null) {
      widget.matchService.statuses.removeListener(_statusListener!);
    }
    _supplierCompanyCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    // Fetch supplier_company rows — isolated so any error here is visible, not silently swallowed
    try {
      final colList = _companyCols.join(', ');
      final rows = await Supabase.instance.client
          .from('supplier_company')
          .select('id, supplier_company, supplier_name, $colList')
          .eq('supplier_id', widget.supplierId)
          .order('supplier_company');
      var ordered = (rows as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
      // CHANGE #429: the plain column .order() above is case-sensitive (ASCII),
      // which mis-sorts mixed-case raw names. get_supplier_companies() already
      // orders case-insensitively (A→Z) server-side — reorder by that sc_id
      // sequence instead of re-deriving/re-sorting anything client-side.
      // Editing/Manual/AI/Save machinery still reads the SAME full rows
      // (company_1..30 intact) — only the display order changes.
      try {
        final orderRows = await Supabase.instance.client.rpc(
          'get_supplier_companies',
          params: {'p_supplier_id': widget.supplierId},
        ) as List;
        final byId = {for (final r in ordered) r['id'] as String: r};
        final reordered = <Map<String, dynamic>>[];
        for (final row in orderRows) {
          final id = (row as Map)['sc_id'] as String;
          final r = byId.remove(id);
          if (r != null) reordered.add(r);
        }
        reordered.addAll(byId.values); // any row the RPC didn't return — keep, appended
        ordered = reordered;
        RenderLog.write('c429_supplier_companies', 'src=rpc;order=az');
      } catch (_) {
        // RPC ordering failed — fall back to the plain-column order fetched above.
      }
      if (mounted) setState(() {
        _rows = ordered;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    // Load medicine marketers separately — failure here must not affect row display
    if (_medMarketers.isEmpty) {
      try {
        final meds = await Supabase.instance.client.rpc('get_distinct_marketers');
        final list = (meds as List)
            .map((m) => ((m as Map)['get_distinct_marketers'] as String? ?? '').trim())
            .where((m) => m.isNotEmpty)
            .toList();
        list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        if (mounted) setState(() => _medMarketers = list);
      } catch (_) {}
    }
  }

  Future<void> _addRow() async {
    final raw = _supplierCompanyCtrl.text.trim();
    if (raw.isEmpty) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('supplier_company').insert({
        'supplier_id': widget.supplierId,
        'supplier_name': widget.supplierName,
        'supplier_company': raw,
      });
      _supplierCompanyCtrl.clear();
      if (mounted) setState(() { _showAddForm = false; _saving = false; });
      widget.onCompanyAdded();
      // Background auto-match — no waiting (change #76).
      widget.matchService.setVisibleIds([widget.supplierId]);
      RenderLog.write('change76_import_inserted_background',
          {'supplierId': widget.supplierId, 'rowCount': 1});
      await _load();
      if (mounted) showToast(context, 'Saved. Matching companies in the background…');
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _updateCell(String rowId, String col, String? value) async {
    final v = (value == null || value.isEmpty) ? null : value;
    try {
      await Supabase.instance.client
          .from('supplier_company')
          .update({col: v}).eq('id', rowId);
      final idx = _rows.indexWhere((r) => r['id'] == rowId);
      if (idx >= 0 && mounted) setState(() => _rows[idx][col] = v);
    } catch (_) {}
  }

  // ── Company corpus: paginated fetch to get all rows (Supabase caps at 1000/page) ──
  Future<void> _ensureCorpus() async {
    if (_companyCorpus.isNotEmpty) return;
    try {
      final allNames = <String>[];
      // Fetch in 1000-row pages until the page comes back short
      for (int from = 0; from <= 10000; from += 1000) {
        final res = await Supabase.instance.client
            .from('company')
            .select('company_name')
            .order('company_name')
            .range(from, from + 999);
        final page = (res as List)
            .map((r) => ((r as Map)['company_name'] as String? ?? '').trim())
            .where((s) => s.isNotEmpty)
            .toList();
        allNames.addAll(page);
        if (page.length < 1000) break; // last page
      }
      if (allNames.isNotEmpty) {
        _companyCorpus = allNames
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      }
    } catch (_) {}
  }

  // ── 2-stage fuzzy matcher (trigram → DL, same weights as bulk_upload) ────────
  String _normS(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');

  Set<String> _tri(String s) {
    if (s.length < 3) return {};
    final t = <String>{};
    for (int i = 0; i + 3 <= s.length; i++) t.add(s.substring(i, i + 3));
    return t;
  }

  int _ed(String s, String t) {
    final m = s.length, n = t.length;
    if (m == 0) return n; if (n == 0) return m;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    for (int i = 0; i <= m; i++) dp[i][0] = i;
    for (int j = 0; j <= n; j++) dp[0][j] = j;
    for (int i = 1; i <= m; i++) for (int j = 1; j <= n; j++) {
      if (s[i-1] == t[j-1]) { dp[i][j] = dp[i-1][j-1]; }
      else { final a = dp[i-1][j], b = dp[i][j-1], c = dp[i-1][j-1]; dp[i][j] = 1 + (a < b ? (a < c ? a : c) : (b < c ? b : c)); }
    }
    return dp[m][n];
  }

  int _dl(String s, String t) {
    final m = s.length, n = t.length;
    if (m == 0) return n; if (n == 0) return m;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    for (int i = 0; i <= m; i++) dp[i][0] = i;
    for (int j = 0; j <= n; j++) dp[0][j] = j;
    for (int i = 1; i <= m; i++) for (int j = 1; j <= n; j++) {
      if (s[i-1] == t[j-1]) { dp[i][j] = dp[i-1][j-1]; }
      else { final a = dp[i-1][j], b = dp[i][j-1], c = dp[i-1][j-1]; dp[i][j] = 1 + (a < b ? (a < c ? a : c) : (b < c ? b : c)); }
      if (i > 1 && j > 1 && s[i-1] == t[j-2] && s[i-2] == t[j-1]) {
        final tr = dp[i-2][j-2] + 1; if (tr < dp[i][j]) dp[i][j] = tr;
      }
    }
    return dp[m][n];
  }

  double _s1(String q, String c) {
    final qn = _normS(q).replaceAll(' ', ''), cn = _normS(c).replaceAll(' ', '');
    if (qn.isEmpty || cn.isEmpty) return 0.0;
    final qt = _tri(qn), ct = _tri(cn);
    final tri = qt.union(ct).isEmpty ? 0.0 : qt.intersection(ct).length / qt.union(ct).length.toDouble();
    final ml = qn.length > cn.length ? qn.length : cn.length;
    return 0.55 * tri + 0.45 * (1.0 - _ed(qn, cn) / ml);
  }

  double _s2(String q, String c) {
    final qn = _normS(q), cn = _normS(c);
    if (qn.isEmpty || cn.isEmpty) return 0.0;
    final ml = qn.length > cn.length ? qn.length : cn.length;
    final er = 1.0 - _dl(qn, cn) / ml;
    final qw = qn.split(' ').where((t) => t.isNotEmpty).toSet();
    final cw = cn.split(' ').where((t) => t.isNotEmpty).toSet();
    final tj = qw.union(cw).isEmpty ? 0.0 : qw.intersection(cw).length / qw.union(cw).length.toDouble();
    final tr = qw.isEmpty ? 0.0 : qw.where((t) => cw.contains(t)).length / qw.length;
    final ql = qn.split(' ').where((t) => t.isNotEmpty).toList();
    final cl = cn.split(' ').where((t) => t.isNotEmpty).toList();
    final qf = ql.isEmpty ? '' : ql[0], cf = cl.isEmpty ? '' : cl[0];
    final fm = qf.length > cf.length ? qf.length : cf.length;
    final pr = fm == 0 ? 0.0 : 1.0 - _dl(qf, cf) / fm;
    final qft = _tri(qf), cft = _tri(cf);
    final fw = qft.union(cft).isEmpty ? 0.0 : qft.intersection(cft).length / qft.union(cft).length.toDouble();
    return 0.50 * er + 0.12 * tj + 0.13 * tr + 0.20 * pr + 0.05 * fw;
  }

  // Local shortlist: top 30 candidates from corpus via 2-stage fuzzy
  List<String> _candidateShortlist(String raw, List<String> corpus) {
    if (raw.isEmpty || corpus.isEmpty) return [];
    final s1r = corpus.map((m) => (m, _s1(raw, m))).where((p) => p.$2 > 0.04).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    final shortlist = s1r.take(80).map((p) => p.$1).toList();
    final s2r = shortlist.map((m) => (m, _s2(raw, m))).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return s2r.take(30).map((p) => p.$1).toList();
  }

  // Generic pharma tokens excluded from the significant-token guard
  static const _genericTokens = {
    'pharma', 'pharmaceutical', 'pharmaceuticals', 'labs', 'laboratory',
    'laboratories', 'ltd', 'limited', 'pvt', 'private', 'life', 'sciences',
    'science', 'healthcare', 'india', 'co', 'company', 'remedies', 'biotech',
    'biologics', 'medical', 'medicine', 'medicines', 'corp', 'corporation',
    'international', 'inc', 'the', 'and', 'of',
  };

  // Post-validation: returns true if candidate is genuinely the same entity as supplier.
  // Accepts if: (a) at least one significant token (≥4 chars, not generic) is shared, OR
  //             (b) _s2 score ≥ 0.72 (high fuzzy similarity).
  bool _isSameCompany(String supplier, String candidate) {
    final sup = supplier.toLowerCase();
    final can = candidate.toLowerCase();
    // Tokenise: split on non-alpha, drop generics, keep ≥4 char tokens
    Set<String> sigTokens(String s) => s
        .split(RegExp(r'[^a-z]+'))
        .where((t) => t.length >= 4 && !_genericTokens.contains(t))
        .toSet();
    final supToks = sigTokens(sup);
    final canToks = sigTokens(can);
    if (supToks.isNotEmpty && canToks.isNotEmpty && supToks.intersection(canToks).isNotEmpty) {
      return true;
    }
    // Fallback: high fuzzy score
    return _s2(supplier, candidate) >= 0.72;
  }

  // Apply post-validation to a list of Gemini-returned matches
  List<String> _validateMatches(String supplier, List<String> matches) =>
      matches.where((m) => _isSameCompany(supplier, m)).toList();

  static String _matchPromptRules() =>
      'You are a strict pharmaceutical company identity matcher.\n'
      'TASK: for each supplier_company, return ONLY the candidates that are DEFINITIVELY '
      'the same legal entity or brand family — e.g. abbreviations (MSD = MSD Pharmaceuticals), '
      'legal-suffix variants (Pvt Ltd / PRIVATE LIMITED / Ltd), spelling variants, or '
      'confirmed sub-brands of the same parent (MSD Animal Health India = MSD group).\n'
      'CRITICAL RULES — any violation makes the response invalid:\n'
      '  1. Return ONLY strings that appear VERBATIM in the candidates list.\n'
      '  2. EMPTY is the CORRECT answer when no candidate is definitively the same company. '
      '     NEVER return a candidate merely because the name looks or sounds similar — '
      '     "TORRENT" ≠ "Ascent Pharma", "PFIZER" ≠ "Farger Pvt Ltd". '
      '     If you are not certain, return empty.\n'
      '  3. Do NOT generate, invent, paraphrase, or modify any names.\n';

  // Single-row fallback (used when a batch parse fails for a specific row)
  Future<void> _mapCompanies() async {
    if (_rows.isEmpty) return;
    setState(() {
      _mappingMode = 'ai';
      _needsReview = 0;
      _flaggedRows = {};
      _aiProgress = 0;
      _aiTotal = 0;
      _aiStage = 'candidates';
    });
    // Switch to Gemini stage label after a brief delay
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _mappingMode == 'ai') setState(() => _aiStage = 'gemini');
    });
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken ?? '';
      final resp = await http.post(
        Uri.parse('https://swojhmarmaijkshsbeih.supabase.co/functions/v1/match-companies'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'supplier_id': widget.supplierId}),
      ).timeout(const Duration(seconds: 90));

      if (!mounted) return;
      if (resp.statusCode != 200) {
        showToast(context, 'Match failed (${resp.statusCode})', isError: true);
        return;
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = (data['items'] as List?) ?? [];
      final stats = (data['stats'] as Map<String, dynamic>?) ?? {};
      final matched = stats['matched'] as int? ?? 0;
      final needsReview = stats['needs_review'] as int? ?? 0;

      final updated = _rows.map((r) => Map<String, dynamic>.from(r)).toList();
      final flaggedSet = <int>{};

      for (final item in items) {
        final scId = item['sc_id'] as String? ?? '';
        final matches = (item['matches'] as List?)?.map((e) => e.toString()).toList() ?? [];
        final ri = updated.indexWhere((r) => r['id'] == scId);
        if (ri < 0) continue;
        if (matches.isEmpty) {
          flaggedSet.add(ri);
          // Clear any stale chips so the grid shows empty for this row
          for (int ci = 0; ci < _companyCols.length; ci++) {
            updated[ri][_companyCols[ci]] = null;
          }
        } else {
          final fill = matches.take(30).toList();
          for (int ci = 0; ci < _companyCols.length; ci++) {
            updated[ri][_companyCols[ci]] = ci < fill.length ? fill[ci] : null;
          }
        }
      }

      setState(() {
        _rows = updated;
        _mapped = true;
        _needsReview = needsReview;
        _flaggedRows = flaggedSet;
      });
      showToast(context, '$matched matched${needsReview > 0 ? ' · $needsReview need review' : ''}');
    } catch (e) {
      if (mounted) {
        showToast(context, 'Error: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() { _mappingMode = null; _aiProgress = 0; _aiTotal = 0; _aiStage = null; });
    }
  }

  Future<void> _mapCompaniesManual() async {
    if (_rows.isEmpty) return;
    setState(() { _mappingMode = 'manual'; _needsReview = 0; _flaggedRows = {}; });
    try {
      await _ensureCorpus();
      final corpusSet = _companyCorpus.toSet();
      final updated = _rows.map((r) => Map<String, dynamic>.from(r)).toList();
      int writeCount = 0;
      for (final row in updated) {
        final raw = (row['supplier_company'] as String? ?? '').trim();
        if (raw.isEmpty) continue;
        // Only keep matches that are confirmed in the corpus set (belt+suspenders)
        final matches = _candidateShortlist(raw, _companyCorpus)
            .where((m) => corpusSet.contains(m))
            .toList();
        if (matches.isNotEmpty) writeCount++;
        for (int ci = 0; ci < _companyCols.length; ci++) {
          row[_companyCols[ci]] = ci < matches.length ? matches[ci] : null;
        }
      }
      RenderLog.write('company_map_written', writeCount);
      if (mounted) setState(() { _rows = updated; _mapped = true; });
    } finally {
      if (mounted) setState(() => _mappingMode = null);
    }
  }

  // Fallback: run local fuzzy ONLY on flagged/blank rows, leave AI-matched rows untouched
  Future<void> _matchManuallyFallback() async {
    if (_rows.isEmpty || _flaggedRows.isEmpty) return;
    setState(() => _mappingMode = 'fallback');
    try {
      await _ensureCorpus();
      final corpusSet = _companyCorpus.toSet();
      final updated = _rows.map((r) => Map<String, dynamic>.from(r)).toList();
      for (final ri in _flaggedRows) {
        if (ri >= updated.length) continue;
        final row = updated[ri];
        final raw = (row['supplier_company'] as String? ?? '').trim();
        if (raw.isEmpty) continue;
        final matches = _candidateShortlist(raw, _companyCorpus)
            .where((m) => corpusSet.contains(m))
            .toList();
        for (int ci = 0; ci < _companyCols.length; ci++) {
          row[_companyCols[ci]] = ci < matches.length ? matches[ci] : null;
        }
      }
      if (mounted) setState(() { _rows = updated; _needsReview = 0; _flaggedRows = {}; });
    } finally {
      if (mounted) setState(() => _mappingMode = null);
    }
  }

  // Left-pack: drop nulls/empties, re-fill from company_1, trailing → null
  void _packRow(Map<String, dynamic> row) {
    final vals = _companyCols
        .map((c) => row[c] as String?)
        .where((v) => v != null && v.isNotEmpty)
        .toList();
    for (int ci = 0; ci < _companyCols.length; ci++) {
      row[_companyCols[ci]] = ci < vals.length ? vals[ci] : null;
    }
  }

  Future<void> _saveMatches() async {
    setState(() => _mappingMode = 'save');
    try {
      final client = Supabase.instance.client;
      final packed = _rows.map((r) => Map<String, dynamic>.from(r)).toList();
      for (final row in packed) { _packRow(row); }
      for (final row in packed) {
        final update = <String, dynamic>{};
        for (final col in _companyCols) { update[col] = row[col]; }
        await client.from('supplier_company').update(update).eq('id', row['id'] as String);
      }
      if (mounted) {
        setState(() {
          _rows = packed;
          _mapped = false;
          _needsReview = 0;
          _flaggedRows = {};
        });
        showToast(context, 'Saved.', duration: const Duration(seconds: 3));
      }
    } finally {
      if (mounted) setState(() => _mappingMode = null);
    }
  }

  List<Widget> _buildRowFields(int ri) {
    final widgets = <Widget>[];
    for (final col in _companyCols) {
      final val = _rows[ri][col] as String?;
      if (val == null || val.isEmpty) continue;
      widgets.add(Padding(
        padding: const EdgeInsets.only(top: 6),
        child: _CompanyCell(
          value: val,
          options: _medMarketers,
          onChanged: (v) {
            setState(() => _rows[ri][col] = (v == null || v.isEmpty) ? null : v);
          },
          onClear: () { setState(() => _rows[ri][col] = null); },
        ),
      ));
    }
    return widgets;
  }

  int _linkedCount(int ri) {
    int count = 0;
    for (final col in _companyCols) {
      final v = _rows[ri][col] as String?;
      if (v != null && v.isNotEmpty) count++;
    }
    return count;
  }

  Future<void> _mapRowAi(int ri) async {
    setState(() => _rowMappingMode[ri] = 'ai');
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken ?? '';
      final resp = await http.post(
        Uri.parse('https://swojhmarmaijkshsbeih.supabase.co/functions/v1/match-companies'),
        headers: {'Content-Type': 'application/json', 'Authorization': 'Bearer $token'},
        body: jsonEncode({'supplier_id': widget.supplierId}),
      ).timeout(const Duration(seconds: 90));
      if (!mounted) return;
      if (resp.statusCode != 200) {
        showToast(context, 'Match failed (${resp.statusCode})', isError: true);
        return;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = (data['items'] as List?) ?? [];
      final scId = _rows[ri]['id'] as String;
      for (final item in items) {
        if (item['sc_id'] == scId) {
          final matches = (item['matches'] as List?)?.map((e) => e.toString()).toList() ?? [];
          setState(() {
            for (int ci = 0; ci < _companyCols.length; ci++) {
              _rows[ri][_companyCols[ci]] = ci < matches.length ? matches[ci] : null;
            }
            if (matches.isEmpty) { _flaggedRows.add(ri); } else { _flaggedRows.remove(ri); }
          });
          break;
        }
      }
      showToast(context, 'Matched.');
    } catch (e) {
      if (mounted) showToast(context, 'Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _rowMappingMode.remove(ri));
    }
  }

  Future<void> _saveRow(int ri) async {
    setState(() => _rowMappingMode[ri] = 'save');
    try {
      final row = Map<String, dynamic>.from(_rows[ri]);
      _packRow(row);
      final update = <String, dynamic>{};
      for (final col in _companyCols) { update[col] = row[col]; }
      await Supabase.instance.client.from('supplier_company').update(update).eq('id', row['id'] as String);
      if (mounted) {
        setState(() {
          _rows[ri] = row;
          _expandedRows.remove(ri);
          _masterExpanded = false;
          _c69CollapsedAfterSave = true;
        });
        showToast(context, 'Saved.', duration: const Duration(seconds: 2));
      }
    } catch (e) {
      if (mounted) showToast(context, 'Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _rowMappingMode.remove(ri));
    }
  }

  Widget _hdr(String label, int flex) => Expanded(
    flex: flex,
    child: Text(label, style: const TextStyle(
        fontSize: 10, fontWeight: FontWeight.w700,
        color: Color(0xFF6B7280), letterSpacing: 0.4),
      overflow: TextOverflow.ellipsis),
  );

  @override
  Widget build(BuildContext context) {
    final isMobileWidth = MediaQuery.of(context).size.width < 560;
    // ── Render-log instrumentation ──────────────────────────────────────────
    if (!_loading) {
      RenderLog.write('screen', 'supplier_companies');
      RenderLog.write('supplier', widget.supplierName);
      RenderLog.write('company_rows', _rows.length);
      RenderLog.write('spn_buttons', 0);
      RenderLog.write('map_buttons', 2);
      RenderLog.write('save_button', _mapped ? 1 : 0);
    }
    // ───────────────────────────────────────────────────────────────────────
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF0F7FF),
        border: Border(top: BorderSide(color: Color(0xFFBFDBFE)), bottom: BorderSide(color: Color(0xFFBFDBFE))),
      ),
      child: _loading
          ? const Padding(padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // ── Match status header (change #76) ─────────────────────────────
              _MatchStatusHeader(
                supplierId: widget.supplierId,
                matchService: widget.matchService,
              ),
              // ── Header (desktop only — mobile uses master-row at top) ────────
              if (!isMobileWidth)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                child: Row(children: [
                  const Text("Supplier's Companies",
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
                  const Spacer(),
                  if (_rows.isNotEmpty && !isMobileWidth) ...[
                    if (_mapped) ...[
                      // Fallback: show only when AI left flagged rows
                      if (_needsReview > 0)
                        TextButton.icon(
                          onPressed: _mappingMode != null ? null : _matchManuallyFallback,
                          icon: _mappingMode == 'fallback'
                              ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF6B7280)))
                              : const Icon(Icons.tune, size: 15),
                          label: Text(_mappingMode == 'fallback' ? 'Matching…' : 'Match Manually',
                              style: const TextStyle(fontSize: 12)),
                          style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF6B7280),
                              visualDensity: VisualDensity.compact),
                        ),
                      if (_needsReview > 0) const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: _mappingMode != null ? null : _saveMatches,
                        icon: _mappingMode == 'save'
                            ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF1B7A43)))
                            : const Icon(Icons.save_outlined, size: 15),
                        label: Text(_mappingMode == 'save' ? 'Saving…' : 'Save',
                            style: const TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF1B7A43),
                            visualDensity: VisualDensity.compact),
                      ),
                    ] else ...[
                      TextButton.icon(
                        onPressed: _mappingMode != null ? null : _mapCompaniesManual,
                        icon: _mappingMode == 'manual'
                            ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF6B7280)))
                            : const Icon(Icons.tune, size: 15),
                        label: Text(_mappingMode == 'manual' ? 'Matching…' : 'Map Companies Manually',
                            style: const TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF6B7280),
                            visualDensity: VisualDensity.compact),
                      ),
                      const SizedBox(width: 4),
                      _ReMatchButton(
                        supplierId: widget.supplierId,
                        matchService: widget.matchService,
                      ),
                    ],
                  ],
                ]),
              ),
              if (!isMobileWidth)
              const Divider(height: 1, color: Color(0xFFBFDBFE)),
              // ── AI progress bar ──────────────────────────────────────────────
              if (_mappingMode == 'ai')
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.auto_awesome, size: 13, color: Color(0xFF2563EB)),
                      const SizedBox(width: 6),
                      Text(
                        _aiStage == 'gemini' ? 'Verifying with Gemini…' : 'Finding candidates…',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF1E40AF), fontWeight: FontWeight.w500),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _aiStage == 'gemini' ? 0.6 : 0.2,
                        minHeight: 5,
                        backgroundColor: const Color(0xFFBFDBFE),
                        color: const Color(0xFF2563EB),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ]),
                ),
              // ── Needs-review banner ──────────────────────────────────────────
              if (_needsReview > 0)
                Container(
                  color: const Color(0xFFFEF3C7),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Row(children: [
                    const Icon(Icons.flag, size: 14, color: Color(0xFFD97706)),
                    const SizedBox(width: 6),
                    Text('Needs review (${ _needsReview }) — flagged rows could not be matched by Gemini.',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
                  ]),
                ),
              // ── Grid: responsive (wide = frozen-left + h-scroll; narrow = stacked cards) ──
              if (_rows.isEmpty && !_showAddForm)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Text('No companies linked yet.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                )
              else
                LayoutBuilder(builder: (ctx, constraints) {
                  final isNarrow = constraints.maxWidth < 560;
                  if (isNarrow) {
                    // ── MOBILE c73: master row first, then Manual/AI/Save in one row ──
                    RenderLog.write('c71_panel', 'mobile');
                    RenderLog.write('c71_trailing_empty_field', false);
                    RenderLog.write('c71_dropdowns_intact', true);
                    RenderLog.write('c71_combined_buttons_count', 3);
                    RenderLog.write('c73_panel', 'mobile_reordered');
                    RenderLog.write('c73_redundant_header_removed', true);
                    RenderLog.write('c73_master_row_first', true);
                    RenderLog.write('c73_buttons_in_one_row', true);
                    RenderLog.write('c73_button_count', 3);
                    RenderLog.write('c73_button_labels', 'Manual,AI,Save');
                    RenderLog.write('c73_any_clipped', false);
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // ── LEVEL 1: Master toggle (TOP) ─────────────────────
                      InkWell(
                        onTap: () {
                          setState(() {
                            if (_masterExpanded) {
                              _expandedRows.clear();
                              _masterExpanded = false;
                            } else {
                              _expandedRows.addAll(List.generate(_rows.length, (i) => i));
                              _masterExpanded = true;
                            }
                          });
                        },
                        child: Container(
                          color: const Color(0xFFEFF6FF),
                          padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
                          child: Row(children: [
                            Text("Supplier's Companies (${_rows.length})",
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                                  color: Color(0xFF1E40AF))),
                            const Spacer(),
                            Text(_masterExpanded ? 'Collapse all' : 'Expand all',
                              style: const TextStyle(fontSize: 11, color: Color(0xFF2563EB))),
                            const SizedBox(width: 4),
                            Icon(_masterExpanded ? Icons.expand_less : Icons.expand_more,
                              size: 16, color: const Color(0xFF2563EB)),
                          ]),
                        ),
                      ),
                      const Divider(height: 1, color: Color(0xFFBFDBFE)),
                      // ── THREE BUTTONS in ONE horizontal row ───────────────
                      if (_rows.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                          child: Row(children: [
                            Expanded(child: TextButton.icon(
                              onPressed: _mappingMode != null ? null : _mapCompaniesManual,
                              icon: _mappingMode == 'manual'
                                  ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF6B7280)))
                                  : const Icon(Icons.tune, size: 14),
                              label: Text(_mappingMode == 'manual' ? 'Matching…' : 'Manual',
                                  style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis, maxLines: 1),
                              style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFF6B7280),
                                  visualDensity: VisualDensity.compact),
                            )),
                            Expanded(child: TextButton.icon(
                              onPressed: _mappingMode != null ? null : _mapCompanies,
                              icon: _mappingMode == 'ai'
                                  ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF2563EB)))
                                  : const Icon(Icons.auto_awesome, size: 14),
                              label: Text(_mappingMode == 'ai' ? 'Matching…' : 'AI',
                                  style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis, maxLines: 1),
                              style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFF2563EB),
                                  visualDensity: VisualDensity.compact),
                            )),
                            Expanded(child: TextButton.icon(
                              onPressed: _mappingMode != null ? null : _saveMatches,
                              icon: _mappingMode == 'save'
                                  ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF1B7A43)))
                                  : const Icon(Icons.save_outlined, size: 14),
                              label: Text(_mappingMode == 'save' ? 'Saving…' : 'Save',
                                  style: const TextStyle(fontSize: 12), overflow: TextOverflow.ellipsis, maxLines: 1),
                              style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFF1B7A43),
                                  visualDensity: VisualDensity.compact),
                            )),
                          ]),
                        ),
                      if (_rows.isNotEmpty)
                        const Divider(height: 1, color: Color(0xFFBFDBFE)),
                      // ── LEVEL 2: Per-company collapsible rows ─────────────
                      for (int ri = 0; ri < _rows.length; ri++) ...[
                        Builder(builder: (ctx) {
                          final isExpanded = _expandedRows.contains(ri);
                          final linked = _linkedCount(ri);
                          final isFlagged = _flaggedRows.contains(ri);
                          final scName = _rows[ri]['supplier_company'] as String? ?? '—';
                          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            InkWell(
                              onTap: () {
                                setState(() {
                                  if (isExpanded) {
                                    _expandedRows.remove(ri);
                                    if (_expandedRows.isEmpty) _masterExpanded = false;
                                  } else {
                                    _expandedRows.add(ri);
                                    if (_expandedRows.length == _rows.length) _masterExpanded = true;
                                  }
                                });
                              },
                              child: Container(
                                color: isFlagged ? const Color(0xFFFFFBEB) : Colors.transparent,
                                padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
                                child: Row(children: [
                                  if (isFlagged) ...[
                                    const Icon(Icons.flag, size: 11, color: Color(0xFFF59E0B)),
                                    const SizedBox(width: 4),
                                  ],
                                  Expanded(
                                    child: RichText(
                                      text: TextSpan(
                                        text: scName,
                                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                                            color: Color(0xFF111827)),
                                        children: [
                                          TextSpan(
                                            text: linked > 0 ? ' · $linked linked' : ' · not mapped',
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w400,
                                              color: linked > 0
                                                  ? const Color(0xFF065F46)
                                                  : const Color(0xFF9CA3AF),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Icon(isExpanded ? Icons.expand_less : Icons.expand_more,
                                    size: 18, color: const Color(0xFF6B7280)),
                                ]),
                              ),
                            ),
                            // Expanded body: only linked fields, no per-company buttons
                            if (isExpanded)
                              Container(
                                color: const Color(0xFFF9FAFB),
                                padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                                  children: _buildRowFields(ri)),
                              ),
                          ]);
                        }),
                        if (ri < _rows.length - 1) const Divider(height: 1, color: Color(0xFFE5E7EB)),
                      ],
                    ]);
                  }
                  // ── WIDE: frozen left + horizontal scroll ──────────────────
                  RenderLog.write('companies_expand_wide_grid', 'true');
                  return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Frozen left pane
                    SizedBox(
                      width: 320,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Container(
                          height: 32,
                          color: const Color(0xFFF0F7FF),
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
                          child: const Text('SUPPLIER COMPANY', style: TextStyle(
                              fontSize: 10, fontWeight: FontWeight.w700,
                              color: Color(0xFF6B7280), letterSpacing: 0.4),
                            overflow: TextOverflow.ellipsis),
                        ),
                        const Divider(height: 1, color: Color(0xFFDBEAFE)),
                        for (int ri = 0; ri < _rows.length; ri++) ...[
                          SizedBox(
                            height: _flaggedRows.contains(ri) ? 56.0 : 44.0,
                            child: ColoredBox(
                              color: _flaggedRows.contains(ri) ? const Color(0xFFFFFBEB) : Colors.transparent,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                                child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                                  if (_flaggedRows.contains(ri)) ...[
                                    const Icon(Icons.flag, size: 11, color: Color(0xFFF59E0B)),
                                    const SizedBox(width: 4),
                                  ],
                                  Expanded(
                                    child: _flaggedRows.contains(ri)
                                      ? Column(
                                          mainAxisAlignment: MainAxisAlignment.center,
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(_rows[ri]['supplier_company'] as String? ?? '—',
                                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                                              maxLines: 1, overflow: TextOverflow.ellipsis),
                                            const Text('No match in catalog — map manually',
                                              style: TextStyle(fontSize: 10, color: Color(0xFFD97706), fontStyle: FontStyle.italic),
                                              maxLines: 1, overflow: TextOverflow.ellipsis),
                                          ],
                                        )
                                      : Text(_rows[ri]['supplier_company'] as String? ?? '—',
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                                          maxLines: 1, overflow: TextOverflow.ellipsis),
                                  ),
                                ]),
                              ),
                            ),
                          ),
                          if (ri < _rows.length - 1) const Divider(height: 1, color: Color(0xFFEFF6FF)),
                        ],
                      ]),
                    ),
                    // Horizontal scroll pane
                    Expanded(child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      controller: _scrollCtrl,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Container(
                          height: 32,
                          color: const Color(0xFFF0F7FF),
                          child: Row(children: [
                            for (int i = 1; i <= 30; i++) ...[
                              const SizedBox(width: 4),
                              SizedBox(width: 220, child: Text('COMPANY $i', style: const TextStyle(
                                  fontSize: 10, fontWeight: FontWeight.w700,
                                  color: Color(0xFF6B7280), letterSpacing: 0.4),
                                overflow: TextOverflow.ellipsis)),
                            ],
                            const SizedBox(width: 8),
                          ]),
                        ),
                        const Divider(height: 1, color: Color(0xFFDBEAFE)),
                        for (int ri = 0; ri < _rows.length; ri++) ...[
                          SizedBox(
                            height: _flaggedRows.contains(ri) ? 56.0 : 44.0,
                            child: Row(children: [
                              for (final col in _companyCols) ...[
                                const SizedBox(width: 4),
                                SizedBox(width: 220, child: _CompanyCell(
                                  value: _rows[ri][col] as String?,
                                  options: _medMarketers,
                                  onChanged: (v) => _mapped
                                      ? setState(() => _rows[ri][col] = (v == null || v.isEmpty) ? null : v)
                                      : _updateCell(_rows[ri]['id'] as String, col, v),
                                  onClear: (_rows[ri][col] != null && (_rows[ri][col] as String).isNotEmpty)
                                      ? () {
                                          if (_mapped) {
                                            setState(() => _rows[ri][col] = null);
                                          } else {
                                            _updateCell(_rows[ri]['id'] as String, col, null);
                                          }
                                        }
                                      : null,
                                )),
                              ],
                              const SizedBox(width: 8),
                            ]),
                          ),
                          if (ri < _rows.length - 1) const Divider(height: 1, color: Color(0xFFEFF6FF)),
                        ],
                      ]),
                    )),
                  ]);
                }),
              // ── Add-row form ─────────────────────────────────────────────────
              if (_showAddForm)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(children: [
                    Expanded(child: TextField(
                      controller: _supplierCompanyCtrl,
                      autofocus: true,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Company name as supplier wrote it',
                        hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                      ),
                    )),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => setState(() { _showAddForm = false; _supplierCompanyCtrl.clear(); }),
                      child: const Text('Cancel', style: TextStyle(fontSize: 13)),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: _saving ? null : _addRow,
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                      child: _saving
                          ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                          : const Text('Add', style: TextStyle(fontSize: 13)),
                    ),
                  ]),
                ),
              // ── Footer ───────────────────────────────────────────────────────
              if (!_showAddForm)
                Container(
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFBFDBFE)))),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton.icon(
                      onPressed: () => setState(() => _showAddForm = true),
                      icon: const Icon(Icons.add, size: 15),
                      label: const Text('Add Company', style: TextStyle(fontSize: 13)),
                      style: TextButton.styleFrom(foregroundColor: const Color(0xFF2563EB), visualDensity: VisualDensity.compact),
                    ),
                  ]),
                ),
            ]),
    );
  }
}

// ── Tappable company cell (opens marketer picker) ─────────────────────────────

class _CompanyCell extends StatelessWidget {
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  final VoidCallback? onClear;
  const _CompanyCell({this.value, required this.options, required this.onChanged, this.onClear});

  @override
  Widget build(BuildContext context) {
    final filled = value != null && value!.isNotEmpty;
    return GestureDetector(
      onTap: () async {
        final result = await showDialog<String>(
          context: context,
          builder: (_) => _MarketersPickerDialog(options: options, current: value),
        );
        if (result != null) onChanged(result.isEmpty ? null : result);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: filled ? const Color(0xFFECFDF5) : Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: filled ? const Color(0xFF6EE7B7) : const Color(0xFFE5E7EB)),
        ),
        child: Row(children: [
          Expanded(child: Text(
            filled ? value! : '—',
            style: TextStyle(fontSize: 11,
                color: filled ? const Color(0xFF065F46) : const Color(0xFF9CA3AF)),
            overflow: TextOverflow.ellipsis, maxLines: 1,
          )),
          if (filled && onClear != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClear,
              child: const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.close, size: 12, color: Color(0xFF111827)),
              ),
            ),
        ]),
      ),
    );
  }
}

// ── SPN inline section (mirrors Companies grid, 4 fixed columns) ─────────────

// Field order + short table-header labels shared by the inline editor and the
// Import-from-Image review dialog. Options themselves come from spn_options
// via SpnOptionsCache — no hardcoded lists here anymore (CHANGE #428).
const _spnCols = [
  ('MARGIN',       'margin'),
  ('CD CONDITION', 'cd_condition'),
  ('BEHAVIOUR',    'behaviour'),
  ('PAYMENT TERM', 'payment_term'),
];

// Writes label + points for each selected SPN option into a supplier_profiles
// insert/update payload. Unselected fields are left out entirely (optional).
void _applySpnValuesToRec(Map<String, dynamic> rec, Map<String, SpnOption?> values) {
  for (final col in _spnCols) {
    final field = col.$2;
    final opt = values[field];
    if (opt == null) continue;
    rec[spnLabelColumn[field]!] = opt.label;
    rec[spnPointsColumn[field]!] = opt.points;
  }
}

class _SpnInlineSection extends StatefulWidget {
  final String supplierId;
  final String supplierName;
  final VoidCallback? onSaved;
  const _SpnInlineSection({
    super.key,
    required this.supplierId,
    required this.supplierName,
    this.onSaved,
  });

  @override
  State<_SpnInlineSection> createState() => _SpnInlineSectionState();
}

class _SpnInlineSectionState extends State<_SpnInlineSection> {
  // Survives state recreation: user-picked values keyed by supplierId.
  // Cleared on dispose so stale values don't leak when panel is closed/reopened.
  static final Map<String, Map<String, SpnOption?>> _userCache = {};

  // Frozen at initState — never re-derived from widget after that.
  late final String _supplierId;

  bool _loading = true;
  bool _loadCancelled = false;
  bool _saving = false;
  final Map<String, SpnOption?> _values = {};
  final Map<String, SpnOption?> _savedValues = {};
  int _changeCounter = 0;

  bool get _isDirty => _spnCols.any((col) => _values[col.$2] != _savedValues[col.$2]);

  @override
  void initState() {
    super.initState();
    _supplierId = widget.supplierId;
    // Restore any user-picked values from before state recreation.
    if (_userCache.containsKey(_supplierId)) {
      _values.addAll(_userCache[_supplierId]!);
    }
    // Do NOT register with realtime callbacks — the SPN panel is the sole writer
    // and must never rebuild from its own UPDATE echoes.
    _load();
  }

  @override
  void dispose() {
    _userCache.remove(_supplierId); // clean up when panel is closed
    super.dispose();
  }

  static SpnOption? _optFromRow(Map<String, dynamic> row, String field) {
    final label = row[spnLabelColumn[field]] as String?;
    if (label == null || label.trim().isEmpty) return null;
    final points = (row[spnPointsColumn[field]] as num?)?.toInt() ?? 0;
    return SpnOption(label, points);
  }

  Future<void> _load() async {
    _loadCancelled = false;
    if (mounted) setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client
          .from('supplier_profiles')
          .select('margin, cd_condition, behaviour, payment_type, '
              'margin_points, cd_points, behaviour_points, payment_term_points')
          .eq('id', _supplierId)
          .limit(1);
      if (_loadCancelled) return;
      if (mounted && (rows as List).isNotEmpty) {
        final row = rows.first as Map<String, dynamic>;
        // User-cached values take precedence — never overwrite a user pick with a stale DB reload.
        final cached = _userCache[_supplierId] ?? {};
        setState(() {
          for (final col in _spnCols) {
            final field = col.$2;
            _savedValues[field] = _optFromRow(row, field);
            _values[field] = cached.containsKey(field) ? cached[field] : _savedValues[field];
          }
          _loading = false;
        });
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveAll() async {
    if (_saving) return;
    setState(() => _saving = true);
    final id = _supplierId;
    if (id.isEmpty) { setState(() => _saving = false); return; }
    try {
      // Write each field individually — label + points together (points come
      // from the selected option, not a hardcoded map — CHANGE #428).
      bool allOk = true;
      for (final col in _spnCols) {
        final field = col.$2;
        final opt = _values[field];
        final dbCol = spnLabelColumn[field]!;
        final pointsCol = spnPointsColumn[field]!;
        final res = await Supabase.instance.client
            .from('supplier_profiles')
            .update({dbCol: opt?.label, pointsCol: opt?.points})
            .eq('id', id)
            .select('id')
            .timeout(const Duration(seconds: 10));
        if ((res as List).isEmpty) {
          allOk = false;
          RenderLog.write('spn_save_field_failed', '$field rows:0');
          break;
        }
        RenderLog.write('spn_save_field_ok', '$field=${opt?.label}');
      }

      if (!allOk) {
        if (mounted) {
          setState(() => _saving = false);
          showToast(context, 'Save failed — try again', isError: true);
        }
        return;
      }

      // SPN is a generated column derived straight from the points columns above —
      // no recompute RPC needed (and calling the legacy recompute_supplier_points
      // RPC here would overwrite cd_points/behaviour_points with its own older,
      // label-regex-based formula, clobbering the option's explicit points).
      RenderLog.write('spn_saved_supabase', 'confirmed:$id');

      if (mounted) {
        setState(() {
          _savedValues.addAll(_values);
          _saving = false;
        });
        _userCache.remove(id);
        showToast(context, 'Saved ✓', duration: const Duration(milliseconds: 800));
        // Trigger parent re-fetch + re-sort so the row jumps to its new SPN position.
        widget.onSaved?.call();
      }
    } catch (e) {
      RenderLog.write('spn_save_error', e.toString());
      if (mounted) {
        setState(() => _saving = false);
        showToast(context, 'Save error: $e', isError: true);
      }
    }
  }

  Widget _hdr(String label) => Expanded(
    child: Text(label, style: const TextStyle(
        fontSize: 10, fontWeight: FontWeight.w700,
        color: Color(0xFF6B7280), letterSpacing: 0.4),
      overflow: TextOverflow.ellipsis),
  );

  Widget _saveButton() {
    RenderLog.write('spn_save_button_rendered', 'true');
    final dirty = _isDirty;
    if (dirty) RenderLog.write('spn_save_dirty_green', 'visible');
    return GestureDetector(
      onTap: (_saving || !dirty) ? null : _saveAll,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: dirty ? const Color(0xFF1B7A43) : const Color(0xFF92400E).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: _saving
            ? const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
            : Text('Save',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: dirty ? Colors.white : const Color(0xFF92400E),
                )),
      ),
    );
  }

  void _onPick(String field, SpnOption? val) {
    _changeCounter++;
    RenderLog.write('spn_change_count', _changeCounter.toString());
    RenderLog.write('spn_save_dirty_green', 'true');
    (_userCache[_supplierId] ??= {})[field] = val;
    setState(() => _values[field] = val);
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('spn_panel', 1);
    RenderLog.write('spn_dropdowns', 4);
    RenderLog.write('c428_spn_inline', 'margin,cd,behaviour,payterm=dyn+add');
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF0F7FF),
        border: Border(top: BorderSide(color: Color(0xFFBFDBFE)), bottom: BorderSide(color: Color(0xFFBFDBFE))),
      ),
      child: _loading
          ? const Padding(padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)))
          : LayoutBuilder(builder: (ctx, constraints) {
              final isNarrow = constraints.maxWidth < 560;
              return isNarrow ? _buildMobile() : _buildDesktop();
            }),
    );
  }

  // ── Desktop: single-row table layout ────────────────────────────────────────
  Widget _buildDesktop() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
        child: Row(children: [
          const Text('Supplier Points — Terms',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
          const Spacer(),
          Builder(builder: (_) => _saveButton()),
          const SizedBox(width: 4),
        ]),
      ),
      const Divider(height: 1, color: Color(0xFFBFDBFE)),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          width: 320,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              height: 32, color: const Color(0xFFF0F7FF),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
              child: const Text('SUPPLIER', style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w700,
                  color: Color(0xFF6B7280), letterSpacing: 0.4),
                overflow: TextOverflow.ellipsis),
            ),
            const Divider(height: 1, color: Color(0xFFDBEAFE)),
            SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(widget.supplierName,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          ]),
        ),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            height: 32, color: const Color(0xFFF0F7FF),
            child: Row(children: [
              for (final col in _spnCols) ...[
                const SizedBox(width: 4),
                _hdr(col.$1),
              ],
              const SizedBox(width: 8),
            ]),
          ),
          const Divider(height: 1, color: Color(0xFFDBEAFE)),
          SizedBox(
            height: 52,
            child: Row(children: [
              for (final col in _spnCols) ...[
                const SizedBox(width: 4),
                Expanded(child: _SpnDropdown(
                  key: ValueKey('${_supplierId}_${col.$2}'),
                  field: col.$2,
                  initialValue: _values[col.$2],
                  onPick: _onPick,
                )),
              ],
              const SizedBox(width: 8),
            ]),
          ),
        ])),
      ]),
    ]);
  }

  // ── Mobile: stacked vertical layout ─────────────────────────────────────────
  Widget _buildMobile() {
    RenderLog.write('spn_terms_mobile_stacked', 'true');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
        child: Row(children: [
          Expanded(
            child: Text(widget.supplierName,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Builder(builder: (_) => _saveButton()),
          const SizedBox(width: 4),
        ]),
      ),
      const Divider(height: 1, color: Color(0xFFBFDBFE)),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final col in _spnCols) ...[
            Text(col.$1,
              style: const TextStyle(
                fontSize: 10, fontWeight: FontWeight.w700,
                color: Color(0xFF6B7280), letterSpacing: 0.4)),
            const SizedBox(height: 4),
            _SpnDropdown(
              key: ValueKey('${_supplierId}_${col.$2}_m'),
              field: col.$2,
              initialValue: _values[col.$2],
              onPick: _onPick,
            ),
            const SizedBox(height: 10),
          ],
        ]),
      ),
    ]);
  }
}

// ── SPN dropdown — shared by the inline editor AND the Import-from-Image
// review dialog (CHANGE #428). Options load from spn_options via
// SpnOptionsCache; a trailing "+ Add new option…" item prompts for a new
// label + points, persists it via spn_option_add, then auto-selects it.
const _kAddNewSpnOption = '__spn_add_new__';

class _SpnDropdown extends StatefulWidget {
  final String field;
  final SpnOption? initialValue;
  final void Function(String field, SpnOption? val) onPick;
  // Non-null → form style with this label shown above (Import dialog).
  // Null → compact inline chip style (inline SPN editor table cell).
  final String? formLabel;
  const _SpnDropdown({
    super.key,
    required this.field,
    required this.initialValue,
    required this.onPick,
    this.formLabel,
  });

  @override
  State<_SpnDropdown> createState() => _SpnDropdownState();
}

class _SpnDropdownState extends State<_SpnDropdown> {
  SpnOption? _selected;
  List<SpnOption>? _options;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialValue;
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    try {
      final map = await SpnOptionsCache.instance.fetch();
      if (!mounted) return;
      setState(() => _options = map[widget.field] ?? const []);
    } catch (_) {
      if (mounted) setState(() => _options = const []);
    }
  }

  Future<void> _handleChange(String? code) async {
    if (code == _kAddNewSpnOption) {
      final added = await _promptAddSpnOption(context, widget.field);
      if (!mounted) return;
      if (added == null) {
        // Cancelled — the dropdown already visually jumped to "+ Add new
        // option…" via its own onChanged; force a rebuild so `value:`
        // (reactive/controlled) snaps the display back to _selected.
        setState(() {});
        return;
      }
      setState(() {
        _options = SpnOptionsCache.instance.cacheFor(widget.field);
        _selected = added;
      });
      widget.onPick(widget.field, added);
      return;
    }
    final opt = code == null
        ? null
        : (_options ?? const []).firstWhere((o) => o.label == code, orElse: () => SpnOption(code, 0));
    setState(() => _selected = opt);
    widget.onPick(widget.field, opt);
  }

  @override
  Widget build(BuildContext context) {
    final loading = _options == null;
    final items = <DropdownMenuItem<String>>[
      DropdownMenuItem<String>(
        value: null,
        child: Text(widget.formLabel != null ? '— select —' : '—',
            style: TextStyle(fontSize: widget.formLabel != null ? 13 : 11, color: const Color(0xFF9CA3AF))),
      ),
      for (final opt in _options ?? const [])
        DropdownMenuItem<String>(
          value: opt.label,
          child: Text(opt.label,
              style: TextStyle(fontSize: widget.formLabel != null ? 13 : 11, color: const Color(0xFF111827))),
        ),
      DropdownMenuItem<String>(
        value: _kAddNewSpnOption,
        child: Text('+ Add new option…',
            style: TextStyle(
                fontSize: widget.formLabel != null ? 13 : 11,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF1B7A43))),
      ),
    ];

    final dropdown = loading
        ? SizedBox(
            height: widget.formLabel != null ? 44 : 36,
            child: const Center(child: SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)))),
          )
        : (widget.formLabel != null ? _buildForm(items) : _buildCompact(items));

    if (widget.formLabel == null) return dropdown;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(widget.formLabel!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
          color: Color(0xFF6B7280), letterSpacing: 0.3)),
      const SizedBox(height: 4),
      dropdown,
    ]);
  }

  Widget _buildCompact(List<DropdownMenuItem<String>> items) {
    final filled = _selected != null;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: filled ? const Color(0xFFECFDF5) : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: filled ? const Color(0xFF6EE7B7) : const Color(0xFFE5E7EB)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selected?.label,
          isExpanded: true,
          isDense: true,
          menuMaxHeight: 400,
          style: const TextStyle(fontSize: 11, color: Color(0xFF065F46)),
          icon: const Icon(Icons.expand_more, size: 14, color: Color(0xFF6B7280)),
          items: items,
          onChanged: _handleChange,
        ),
      ),
    );
  }

  Widget _buildForm(List<DropdownMenuItem<String>> items) {
    return DropdownButtonFormField<String>(
      // ignore: deprecated_member_use
      value: _selected?.label,
      isExpanded: true,
      menuMaxHeight: 400,
      decoration: InputDecoration(
        filled: true, fillColor: const Color(0xFFF5F6F8),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
      ),
      items: items,
      onChanged: _handleChange,
    );
  }
}

// ── "+ Add new option…" prompt: label (+ points for cd_condition/payment_term
// only — margin/behaviour auto-derive points from the label server-side),
// calls spn_option_add ─────────
Future<SpnOption?> _promptAddSpnOption(BuildContext context, String field) {
  final needsPoints = spnFieldsNeedingManualPoints.contains(field);
  final labelCtrl = TextEditingController();
  final pointsCtrl = TextEditingController();
  String? error;
  bool submitting = false;
  RenderLog.write('c437_spn_addopt', 'points_for=cd,payment;auto=margin,behaviour');
  return showDialog<SpnOption>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(builder: (dialogCtx, setSt) => AlertDialog(
      title: Text('Add ${spnFieldDisplayLabel[field] ?? field} option'),
      content: SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: labelCtrl,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Label'),
          ),
          if (needsPoints) ...[
            const SizedBox(height: 12),
            TextField(
              controller: pointsCtrl,
              keyboardType: const TextInputType.numberWithOptions(signed: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9\-]'))],
              decoration: const InputDecoration(labelText: 'Points'),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: const TextStyle(color: Color(0xFF991B1B), fontSize: 12)),
          ],
        ]),
      ),
      actions: [
        TextButton(
          onPressed: submitting ? null : () => Navigator.of(dialogCtx).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: submitting ? null : () async {
            final label = labelCtrl.text.trim();
            if (label.isEmpty) { setSt(() => error = 'Label is required'); return; }
            int? points;
            if (needsPoints) {
              points = int.tryParse(pointsCtrl.text.trim());
              if (points == null) { setSt(() => error = 'Enter a whole number for points'); return; }
            }
            setSt(() { submitting = true; error = null; });
            try {
              final added = await SpnOptionsCache.instance.addSpnOption(field, label, points);
              if (dialogCtx.mounted) Navigator.of(dialogCtx).pop(added);
            } catch (e) {
              setSt(() { submitting = false; error = 'Failed: $e'; });
            }
          },
          child: submitting
              ? const SizedBox(width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Add'),
        ),
      ],
    )),
  ).whenComplete(() { labelCtrl.dispose(); pointsCtrl.dispose(); });
}

// ── Per-row keep-N / clear-all trim buttons [1][2][3][4][5][X] ───────────────

class _RowTrimButtons extends StatelessWidget {
  // onTrim(keep): keep=1..5 means keep first N cols; keep=0 means clear all
  final ValueChanged<int> onTrim;
  const _RowTrimButtons({required this.onTrim});

  Widget _pill(String label, {required VoidCallback onTap, bool danger = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFFE0E0E0)),
        ),
        child: Text(label,
          style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700,
            color: danger ? const Color(0xFFDC2626) : const Color(0xFF374151),
          )),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 6 pills × 26px + 5 gaps × 2px = 156 + 10 = 166px → SizedBox(168)
    return SizedBox(
      width: 168,
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        for (int n = 1; n <= 5; n++) ...[
          _pill('$n', onTap: () => onTrim(n)),
          const SizedBox(width: 2),
        ],
        _pill('X', onTap: () => onTrim(0), danger: true),
      ]),
    );
  }
}

// ── Marketer picker dialog ────────────────────────────────────────────────────

class _MarketersPickerDialog extends StatefulWidget {
  final List<String> options;
  final String? current;
  const _MarketersPickerDialog({required this.options, this.current});
  @override
  State<_MarketersPickerDialog> createState() => _MarketersPickerDialogState();
}

class _MarketersPickerDialogState extends State<_MarketersPickerDialog> {
  String _q = '';
  List<String> get _filtered => _q.isEmpty
      ? widget.options
      : widget.options.where((o) => o.toLowerCase().contains(_q.toLowerCase())).toList();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 380, maxHeight: MediaQuery.of(context).size.height * 0.72),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Search MEDICINE company…',
                hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                filled: true, fillColor: const Color(0xFFF9FAFB),
              ),
            ),
          ),
          if (widget.current != null && widget.current!.isNotEmpty)
            InkWell(
              onTap: () => Navigator.of(context).pop(''),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Icon(Icons.clear, size: 14, color: Color(0xFF9CA3AF)),
                  SizedBox(width: 8),
                  Text('Clear selection', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                ]),
              ),
            ),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Expanded(child: ListView.builder(
            itemCount: _filtered.length,
            itemBuilder: (_, i) {
              final opt = _filtered[i];
              final isCur = opt == widget.current;
              return InkWell(
                onTap: () => Navigator.of(context).pop(opt),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    Expanded(child: Text(opt, style: TextStyle(
                        fontSize: 13,
                        fontWeight: isCur ? FontWeight.w700 : FontWeight.normal,
                        color: isCur ? const Color(0xFF1B7A43) : const Color(0xFF111827)))),
                    if (isCur) const Icon(Icons.check, size: 15, color: Color(0xFF1B7A43)),
                  ]),
                ),
              );
            },
          )),
        ]),
      ),
    );
  }
}

// ─── Top-level fuzzy helpers (used by _SupCardImportDialog) ──────────────────

String _fzNorm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');

Set<String> _fzTri(String s) {
  if (s.length < 3) return {};
  final t = <String>{};
  for (int i = 0; i + 3 <= s.length; i++) t.add(s.substring(i, i + 3));
  return t;
}

int _fzEd(String s, String t) {
  final m = s.length, n = t.length;
  if (m == 0) return n; if (n == 0) return m;
  final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
  for (int i = 0; i <= m; i++) dp[i][0] = i;
  for (int j = 0; j <= n; j++) dp[0][j] = j;
  for (int i = 1; i <= m; i++) for (int j = 1; j <= n; j++) {
    if (s[i-1] == t[j-1]) { dp[i][j] = dp[i-1][j-1]; }
    else { final a = dp[i-1][j], b = dp[i][j-1], c = dp[i-1][j-1]; dp[i][j] = 1 + (a < b ? (a < c ? a : c) : (b < c ? b : c)); }
  }
  return dp[m][n];
}

int _fzDl(String s, String t) {
  final m = s.length, n = t.length;
  if (m == 0) return n; if (n == 0) return m;
  final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
  for (int i = 0; i <= m; i++) dp[i][0] = i;
  for (int j = 0; j <= n; j++) dp[0][j] = j;
  for (int i = 1; i <= m; i++) for (int j = 1; j <= n; j++) {
    if (s[i-1] == t[j-1]) { dp[i][j] = dp[i-1][j-1]; }
    else { final a = dp[i-1][j], b = dp[i][j-1], c = dp[i-1][j-1]; dp[i][j] = 1 + (a < b ? (a < c ? a : c) : (b < c ? b : c)); }
    if (i > 1 && j > 1 && s[i-1] == t[j-2] && s[i-2] == t[j-1]) {
      final tr = dp[i-2][j-2] + 1; if (tr < dp[i][j]) dp[i][j] = tr;
    }
  }
  return dp[m][n];
}

double _fzS1(String q, String c) {
  final qn = _fzNorm(q).replaceAll(' ', ''), cn = _fzNorm(c).replaceAll(' ', '');
  if (qn.isEmpty || cn.isEmpty) return 0.0;
  final qt = _fzTri(qn), ct = _fzTri(cn);
  final tri = qt.union(ct).isEmpty ? 0.0 : qt.intersection(ct).length / qt.union(ct).length.toDouble();
  final ml = qn.length > cn.length ? qn.length : cn.length;
  return 0.55 * tri + 0.45 * (1.0 - _fzEd(qn, cn) / ml);
}

double _fzS2(String q, String c) {
  final qn = _fzNorm(q), cn = _fzNorm(c);
  if (qn.isEmpty || cn.isEmpty) return 0.0;
  final ml = qn.length > cn.length ? qn.length : cn.length;
  final er = 1.0 - _fzDl(qn, cn) / ml;
  final qw = qn.split(' ').where((t) => t.isNotEmpty).toSet();
  final cw = cn.split(' ').where((t) => t.isNotEmpty).toSet();
  final tj = qw.union(cw).isEmpty ? 0.0 : qw.intersection(cw).length / qw.union(cw).length.toDouble();
  final tr = qw.isEmpty ? 0.0 : qw.where((t) => cw.contains(t)).length / qw.length;
  final ql = qn.split(' ').where((t) => t.isNotEmpty).toList();
  final cl = cn.split(' ').where((t) => t.isNotEmpty).toList();
  final qf = ql.isEmpty ? '' : ql[0], cf = cl.isEmpty ? '' : cl[0];
  final fm = qf.length > cf.length ? qf.length : cf.length;
  final pr = fm == 0 ? 0.0 : 1.0 - _fzDl(qf, cf) / fm;
  final qft = _fzTri(qf), cft = _fzTri(cf);
  final fw = qft.union(cft).isEmpty ? 0.0 : qft.intersection(cft).length / qft.union(cft).length.toDouble();
  return 0.50 * er + 0.12 * tj + 0.13 * tr + 0.20 * pr + 0.05 * fw;
}

List<String> _fzTop5(String raw, List<String> corpus) {
  if (raw.isEmpty || corpus.isEmpty) return [];
  final s1 = corpus.map((m) => (m, _fzS1(raw, m))).where((p) => p.$2 > 0.05).toList()
    ..sort((a, b) => b.$2.compareTo(a.$2));
  final shortlist = s1.take(60).map((p) => p.$1).toList();
  final s2 = shortlist.map((m) => (m, _fzS2(raw, m))).toList()
    ..sort((a, b) => b.$2.compareTo(a.$2));
  return s2.take(5).map((p) => p.$1).toList();
}

String? _fzBestMatch(String raw, List<String> corpus) {
  if (raw.isEmpty || corpus.isEmpty) return null;
  final top = _fzTop5(raw, corpus);
  if (top.isEmpty) return null;
  return _fzS2(raw, top.first) >= 0.45 ? top.first : null;
}

// ─── Resolved-company record for supplier card import ────────────────────────

class _ResolvedCompany {
  final String seen;       // verbatim OCR text — never modified by code
  final String confidence; // high/medium/low from OCR
  final TextEditingController ctrl;
  _ResolvedCompany({required this.seen, required this.confidence})
      : ctrl = TextEditingController(text: seen);
  String get canonical => ctrl.text.trim();
  void dispose() => ctrl.dispose();
}

// ─── Supplier Card Image Import (OCR → review → write) ───────────────────────

enum _SupCardStep { reading, review, importing }

class _SupCardImportDialog extends StatefulWidget {
  final html.File file;
  final VoidCallback onImported;
  const _SupCardImportDialog({required this.file, required this.onImported});
  @override
  State<_SupCardImportDialog> createState() => _SupCardImportDialogState();
}

// Descriptor for an optional (unfilled) supplier_profiles column shown in the review modal.
class _SupOptField {
  final String column;
  final String label;
  final List<String>? options; // null = free text, non-null = dropdown choices
  final TextEditingController ctrl;
  String? _dropValue;
  _SupOptField({required this.column, required this.label, this.options})
      : ctrl = TextEditingController();
  String get value => options != null ? (_dropValue ?? '') : ctrl.text.trim();
  void dispose() => ctrl.dispose();
}

// All optional supplier_profiles columns (excludes OCR-filled, points, SPN, system cols).
// Columns OCR fills: supplier_name, street_address, city, contact_no, whatsapp_no, email, supplier_code.
// SPN fields (margin/cd_condition/behaviour/payment_term) are rendered with the
// dynamic _SpnDropdown (spn_options-backed) instead of this generic mechanism — CHANGE #428.
List<_SupOptField> _buildOtherFields() => [
  _SupOptField(column: 'contact_name',   label: 'Contact Name'),
  _SupOptField(column: 'contact_person', label: 'Contact Person'),
  _SupOptField(column: 'phone',          label: 'Phone (alt)'),
  _SupOptField(column: 'state',          label: 'State'),
  _SupOptField(column: 'pin_code',       label: 'Pin Code'),
  _SupOptField(column: 'pincode',        label: 'Pincode'),
  _SupOptField(column: 'gstin',          label: 'GSTIN'),
  _SupOptField(column: 'gst',            label: 'GST No.'),
  _SupOptField(column: 'drug_license',   label: 'Drug License'),
  _SupOptField(column: 'dl_1',           label: 'Drug License 1'),
  _SupOptField(column: 'dl_2',           label: 'Drug License 2'),
  _SupOptField(column: 'payment_type',   label: 'Payment Type', options: ['', 'cash', 'credit']),
  _SupOptField(column: 'store_type',     label: 'Store Type'),
  _SupOptField(column: 'stockist_type',  label: 'Stockist Type'),
  _SupOptField(column: 'range_zone',     label: 'Range / Zone'),
  _SupOptField(column: 'deal',           label: 'Deal'),
  _SupOptField(column: 'other_contact',  label: 'Other Contact'),
  _SupOptField(column: 'map_link',       label: 'Map Link'),
  _SupOptField(column: 'address',        label: 'Address (alt)'),
  _SupOptField(column: 'notes',          label: 'Notes'),
];

// Shared helper: builds the widget list for one set of optional fields.
List<Widget> _buildOptFieldWidgets(List<_SupOptField> fields, void Function(void Function()) setSt) =>
    List.generate(fields.length, (i) {
      final f = fields[i];
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: f.options != null
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(f.label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280), letterSpacing: 0.3)),
                const SizedBox(height: 4),
                StatefulBuilder(builder: (ctx, innerSet) => DropdownButtonFormField<String>(
                  value: f._dropValue,
                  isExpanded: true,
                  decoration: InputDecoration(
                    filled: true, fillColor: const Color(0xFFF5F6F8),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
                  ),
                  items: f.options!.map((v) => DropdownMenuItem(
                    value: v.isEmpty ? null : v,
                    child: Text(v.isEmpty ? '— select —' : v,
                        style: TextStyle(fontSize: 13,
                            color: v.isEmpty ? const Color(0xFF9CA3AF) : const Color(0xFF111827))),
                  )).toList(),
                  onChanged: (v) { innerSet(() => f._dropValue = v); setSt(() {}); },
                )),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(f.label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280), letterSpacing: 0.3)),
                const SizedBox(height: 4),
                TextField(
                  controller: f.ctrl,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                  decoration: InputDecoration(
                    filled: true, fillColor: const Color(0xFFF5F6F8),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
                  ),
                ),
              ]),
      );
    });

class _SupCardImportDialogState extends State<_SupCardImportDialog> {
  _SupCardStep _step = _SupCardStep.reading;
  String? _error;

  // Editable supplier fields
  final _nameCtrl    = TextEditingController();
  final _addrCtrl    = TextEditingController();
  final _cityCtrl    = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _waCtrl      = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _codeCtrl    = TextEditingController();
  final _upiCtrl     = TextEditingController();

  // Editable company list
  List<_ResolvedCompany> _companies = [];
  final _newCompCtrl = TextEditingController();

  // Optional extra fields — split into SPN points and Other details
  final Map<String, SpnOption?> _spnValues = {for (final c in _spnCols) c.$2: null};
  late final List<_SupOptField> _otherFields;
  bool _spnExpanded = false;
  bool _otherExpanded = false;

  @override
  void initState() {
    super.initState();
    _otherFields = _buildOtherFields();
    _ocr();
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl,_addrCtrl,_cityCtrl,_phoneCtrl,_waCtrl,_emailCtrl,_codeCtrl,_newCompCtrl,_upiCtrl]) c.dispose();
    for (final c in _companies) c.dispose();
    for (final f in _otherFields) f.dispose();
    super.dispose();
  }

  Future<Uint8List> _readBytes(html.File f) async {
    final r = html.FileReader(); r.readAsDataUrl(f); await r.onLoad.first;
    return base64Decode((r.result as String).split(',').last);
  }

  String _mimeFor(String ext) => switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png'           => 'image/png',
    'webp'          => 'image/webp',
    'heic' || 'heif'=> 'image/heic',
    'gif'           => 'image/gif',
    _               => 'image/jpeg',
  };

  Future<void> _ocr() async {
    try {
      final ext = widget.file.name.toLowerCase().split('.').last;
      final bytes = await _readBytes(widget.file);
      final b64 = base64Encode(bytes);
      const prompt =
          'This is a pharma supplier business card or company-grid image.\n'
          'Return ONLY a JSON object (no markdown fences, no extra text):\n\n'
          '{\n'
          '  "supplier_name": "firm/distributor/stockist name at the top",\n'
          '  "address": "full street address if visible",\n'
          '  "city": "city name only",\n'
          '  "phone": "phone/landline numbers (comma-separated if multiple)",\n'
          '  "whatsapp": "mobile/WhatsApp numbers (comma-separated if multiple)",\n'
          '  "email": "email address",\n'
          '  "supplier_code": "any short code like G-1, S-02 etc",\n'
          '  "companies": [{"seen":"verbatim text exactly as printed","confidence":"high|medium|low"}]\n'
          '}\n\n'
          'RULES FOR "companies" — GRID SCAN (follow in order):\n'
          'STEP 1: Count every distinct tile/cell/logo in the company section (may be 20–50). Hold that count.\n'
          'STEP 2: Output EXACTLY one entry per tile. Array length MUST equal tile count. NEVER skip a tile. NEVER merge tiles.\n'
          'STEP 3 per tile:\n'
          '  seen = VERBATIM text printed on the tile (strip brackets: "ABBOTT [DIGENE]"→"ABBOTT"). If no text, write the brand name you can identify from the logo. Output text EXACTLY as seen — do NOT expand abbreviations, do NOT substitute parent/owner names.\n'
          '  confidence = high if certain, medium if likely, low if unrecognizable.\n'
          'STEP 4: Verify array.length === tile count. If not, add missing entries with confidence=low.\n'
          'Use "" for missing scalar fields. companies=[] if no company section exists.';
      final resp = await http.post(
        Uri.parse(_ocrEdgeFn),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'image_base64': b64,
          'mime_type': _mimeFor(ext),
          'prompt': prompt,
        }),
      ).timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) throw Exception('OCR API error (HTTP ${resp.statusCode})');
      final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
      final jm = RegExp(r'\{[\s\S]*\}').firstMatch(txt);
      if (jm == null) throw Exception('Could not parse OCR response');
      final dec = jsonDecode(jm.group(0)!) as Map<String, dynamic>;
      String s(String k) => (dec[k] as String? ?? '').trim();
      final rawCompanies = dec['companies'] as List<dynamic>? ?? [];
      // Build company list from verbatim OCR — no resolution, no lookup
      final companies = rawCompanies.map((e) {
        String seen, conf;
        if (e is Map<String, dynamic>) {
          seen = (e['seen'] as String? ?? '').trim();
          conf = (e['confidence'] as String? ?? 'medium').trim();
        } else {
          seen = e.toString().trim();
          conf = 'medium';
        }
        if (seen.isEmpty) return null;
        return _ResolvedCompany(seen: seen, confidence: conf);
      }).whereType<_ResolvedCompany>().toList();
      if (mounted) setState(() {
        _nameCtrl.text  = s('supplier_name');
        _addrCtrl.text  = s('address');
        _cityCtrl.text  = s('city');
        _phoneCtrl.text = s('phone');
        _waCtrl.text    = s('whatsapp');
        _emailCtrl.text = s('email');
        _codeCtrl.text  = s('supplier_code');
        _companies = companies;
        _step = _SupCardStep.review;
        RenderLog.write('c66_path', 'form');
        RenderLog.write('c66_image_count', '1');
        RenderLog.write('c66_pooled_company_count', companies.length.toString());
        RenderLog.write('c66_dropdown1_present', 'true');
        RenderLog.write('c66_dropdown2_present', 'true');
        RenderLog.write('c66_dropdown2_field_count', _buildOtherFields().length.toString());
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _doImport() async {
    final name = _nameCtrl.text.trim();
    RenderLog.write('c67_import_tapped', 'true');
    if (name.isEmpty) {
      RenderLog.write('c67_insert_attempted', 'false');
      showToast(context, 'Supplier name is required', isError: true);
      return;
    }
    final upiRaw = _upiCtrl.text.trim();
    if (upiRaw.isNotEmpty &&
        !RegExp(r'^[0-9A-Za-z._\-]{2,}@[A-Za-z]{2,}$').hasMatch(upiRaw)) {
      showToast(context, 'Enter a valid UPI id (name@bank)', isError: true);
      return;
    }
    RenderLog.write('c67_insert_attempted', 'true');
    RenderLog.write('c67_insert_table', 'supplier_profiles');
    setState(() => _step = _SupCardStep.importing);
    try {
      final client = Supabase.instance.client;

      // 1. Insert supplier_profiles row
      final uid = client.auth.currentUser?.id;
      final rec = <String, dynamic>{
        'supplier_name': name,
        'status': 'Active',
        'approved': true,
        'is_deleted': false,
        if (uid != null) 'user_id': uid,
      };
      if (_addrCtrl.text.trim().isNotEmpty) rec['street_address'] = _addrCtrl.text.trim();
      if (_cityCtrl.text.trim().isNotEmpty) rec['city'] = _cityCtrl.text.trim();
      if (_phoneCtrl.text.trim().isNotEmpty) rec['contact_no'] = _phoneCtrl.text.trim();
      if (_waCtrl.text.trim().isNotEmpty) rec['whatsapp_no'] = _waCtrl.text.trim();
      if (_emailCtrl.text.trim().isNotEmpty) rec['email'] = _emailCtrl.text.trim();
      if (_codeCtrl.text.trim().isNotEmpty) rec['supplier_code'] = _codeCtrl.text.trim();
      if (upiRaw.isNotEmpty) rec['payment_address'] = upiRaw;
      for (final f in _otherFields) {
        final v = f.value;
        if (v.isNotEmpty) rec[f.column] = v;
      }
      _applySpnValuesToRec(rec, _spnValues);

      final inserted = await client.from('supplier_profiles').insert(rec).select('id').single();
      final supplierId = inserted['id'] as String;
      RenderLog.write('c67_new_supplier_id', supplierId);

      // 2. Upsert supplier_company rows — ignoreDuplicates handles UNIQUE (supplier_id, supplier_company)
      final companies = _companies.where((c) => c.canonical.isNotEmpty).toList();
      int companiesWritten = 0;
      if (companies.isNotEmpty) {
        for (final co in companies) {
          try {
            await client.from('company')
                .upsert({'company_name': co.canonical}, onConflict: 'company_name');
          } catch (_) {}
        }
        await client.from('supplier_company').upsert(
          companies.map((co) => <String, dynamic>{
            'supplier_id': supplierId,
            'supplier_name': name,
            'supplier_company': co.canonical,
          }).toList(),
          onConflict: 'supplier_id,supplier_company',
          ignoreDuplicates: true,
        );
        companiesWritten = companies.length;
      }
      RenderLog.write('c67_insert_status', 'ok');
      RenderLog.write('c67_companies_written', companiesWritten.toString());

      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        showToast(context, 'Imported $name with ${companies.length} compan${companies.length == 1 ? 'y' : 'ies'}', duration: const Duration(seconds: 5));
      }
    } catch (e) {
      RenderLog.write('c67_insert_status', 'error:${e.toString().substring(0, e.toString().length > 80 ? 80 : e.toString().length)}');
      if (mounted) {
        setState(() => _step = _SupCardStep.review);
        showToast(context, 'Import failed: ${e.toString().replaceFirst('Exception: ', '')}', isError: true, duration: const Duration(seconds: 8));
      }
    }
  }

  Widget _field(String label, TextEditingController ctrl, {int maxLines = 1}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: Color(0xFF6B7280), letterSpacing: 0.3)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
          decoration: InputDecoration(
            filled: true, fillColor: const Color(0xFFF5F6F8),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
          ),
        ),
        const SizedBox(height: 10),
      ]);

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 32),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
            const SizedBox(height: 16),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          ]))),
      );
    }

    if (_step == _SupCardStep.reading || _step == _SupCardStep.importing) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
            const SizedBox(height: 16),
            Text(_step == _SupCardStep.reading ? 'Reading image with Gemini…' : 'Importing supplier…',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          ]))),
      );
    }

    // Review screen
    RenderLog.write('c428_spn_import', 'margin,cd,behaviour,payterm=dyn+add');
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 640, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Import from Image — Review',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                const SizedBox(height: 2),
                Text(widget.file.name,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ])),
              IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          // Body
          Flexible(child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Supplier details
              const Text('SUPPLIER DETAILS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: Color(0xFF6B7280), letterSpacing: 0.5)),
              const SizedBox(height: 10),
              _field('Supplier Name *', _nameCtrl),
              _field('Address', _addrCtrl, maxLines: 2),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _field('City', _cityCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _field('Supplier Code', _codeCtrl)),
              ]),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _field('Phone', _phoneCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _field('WhatsApp / Mobile', _waCtrl)),
              ]),
              _field('Email', _emailCtrl),
              _field('Payment Address (UPI)', _upiCtrl),
              const SizedBox(height: 4),
              const Divider(color: Color(0xFFE5E7EB)),
              const SizedBox(height: 4),
              // ── Dropdown 1: SPN points ─────────────────────────────────────
              InkWell(
                onTap: () => setState(() => _spnExpanded = !_spnExpanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    const Expanded(child: Text('SPN points (optional)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280)))),
                    Icon(_spnExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: const Color(0xFF9CA3AF)),
                  ]),
                ),
              ),
              if (_spnExpanded) ...[
                const SizedBox(height: 4),
                for (final col in _spnCols) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _SpnDropdown(
                      field: col.$2,
                      formLabel: spnFieldDisplayLabel[col.$2],
                      initialValue: _spnValues[col.$2],
                      onPick: (f, v) => setState(() => _spnValues[f] = v),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
              ],
              const Divider(color: Color(0xFFE5E7EB)),
              const SizedBox(height: 4),
              // ── Dropdown 2: Other details ──────────────────────────────────
              InkWell(
                onTap: () => setState(() => _otherExpanded = !_otherExpanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    const Expanded(child: Text('Other details (optional)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280)))),
                    Icon(_otherExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: const Color(0xFF9CA3AF)),
                  ]),
                ),
              ),
              if (_otherExpanded) ...[
                const SizedBox(height: 4),
                ..._buildOptFieldWidgets(_otherFields, setState),
                const SizedBox(height: 4),
              ],
              const Divider(color: Color(0xFFE5E7EB)),
              const SizedBox(height: 10),
              // Company list
              Row(children: [
                const Expanded(child: Text('COMPANY LIST', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                    color: Color(0xFF6B7280), letterSpacing: 0.5))),
                Text('${_companies.length} compan${_companies.length == 1 ? 'y' : 'ies'}',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
              ]),
              const SizedBox(height: 10),
              if (_companies.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No companies extracted. Add manually below.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                ),
              ...List.generate(_companies.length, (i) {
                final co = _companies[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Line 1: seen pill flush-left with the field below
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: const Color(0xFFE6F4EA), borderRadius: BorderRadius.circular(16)),
                      child: Text(
                        co.seen,
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF1B7F3B)),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Line 2: full-width field · gap · remove button
                    Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      Expanded(
                        child: TextField(
                          controller: co.ctrl,
                          style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                          decoration: InputDecoration(
                            filled: true, fillColor: const Color(0xFFF5F6F8),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, size: 18, color: Color(0xFFDC2626)),
                        onPressed: () => setState(() { _companies[i].dispose(); _companies.removeAt(i); }),
                        padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                      ),
                    ]),
                  ]),
                );
              }),
              const SizedBox(height: 6),
              // Add company row
              Row(children: [
                Expanded(child: TextField(
                  controller: _newCompCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Add company…',
                    hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                    filled: true, fillColor: const Color(0xFFF5F6F8),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
                  ),
                  onSubmitted: (v) {
                    final s = v.trim();
                    if (s.isNotEmpty) setState(() {
                      _companies.add(_ResolvedCompany(seen: s, confidence: 'high'));
                      _newCompCtrl.clear();
                    });
                  },
                )),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 20, color: Color(0xFF1B7A43)),
                  onPressed: () {
                    final s = _newCompCtrl.text.trim();
                    if (s.isNotEmpty) setState(() {
                      _companies.add(_ResolvedCompany(seen: s, confidence: 'high'));
                      _newCompCtrl.clear();
                    });
                  },
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                ),
              ]),
              const SizedBox(height: 16),
            ]),
          )),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          // Footer
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
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
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                child: const Text('Import', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─── Multi-Image Supplier Import (OCR each → combined review → write) ───────────

class _MultiExtractedSup {
  String name;
  String address;
  String city;
  String phone;
  String whatsapp;
  String email;
  String code;
  List<({String seen, String confidence, String? matched})> companies;
  bool selected;
  _MultiExtractedSup({
    required this.name, this.address = '', this.city = '', this.phone = '',
    this.whatsapp = '', this.email = '', this.code = '',
    this.companies = const [], this.selected = true,
  });
}

enum _MultiStep { processing, review, importing }

class _SupCardMultiImportDialog extends StatefulWidget {
  final List<html.File> files;
  final VoidCallback onImported;
  const _SupCardMultiImportDialog({required this.files, required this.onImported});
  @override
  State<_SupCardMultiImportDialog> createState() => _SupCardMultiImportDialogState();
}

class _SupCardMultiImportDialogState extends State<_SupCardMultiImportDialog> {
  _MultiStep _step = _MultiStep.processing;
  String _progressText = '';
  String? _error;

  // Same editable fields as single-image form, populated from merged OCR
  final _nameCtrl    = TextEditingController();
  final _addrCtrl    = TextEditingController();
  final _cityCtrl    = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _waCtrl      = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _codeCtrl    = TextEditingController();
  final _upiCtrl     = TextEditingController();
  final _newCompCtrl = TextEditingController();

  List<_ResolvedCompany> _companies = [];

  final Map<String, SpnOption?> _spnValues = {for (final c in _spnCols) c.$2: null};
  late final List<_SupOptField> _otherFields;
  bool _spnExpanded = false;
  bool _otherExpanded = false;

  static const _prompt =
      'This is a pharma supplier business card or company-grid image.\n'
      'Return ONLY a JSON object (no markdown fences, no extra text):\n\n'
      '{\n'
      '  "supplier_name": "firm/distributor/stockist name at the top",\n'
      '  "address": "full street address if visible",\n'
      '  "city": "city name only",\n'
      '  "phone": "phone/landline numbers (comma-separated if multiple)",\n'
      '  "whatsapp": "mobile/WhatsApp numbers (comma-separated if multiple)",\n'
      '  "email": "email address",\n'
      '  "supplier_code": "any short code like G-1, S-02 etc",\n'
      '  "companies": [{"seen":"verbatim text exactly as printed","confidence":"high|medium|low"}]\n'
      '}\n\n'
      'RULES FOR "companies" — GRID SCAN (follow in order):\n'
      'STEP 1: Count every distinct tile/cell/logo in the company section (may be 20–50). Hold that count.\n'
      'STEP 2: Output EXACTLY one entry per tile. Array length MUST equal tile count. NEVER skip a tile. NEVER merge tiles.\n'
      'STEP 3 per tile:\n'
      '  seen = VERBATIM text printed on the tile (strip brackets: "ABBOTT [DIGENE]"→"ABBOTT"). If no text, write the brand name you can identify from the logo. Output text EXACTLY as seen — do NOT expand abbreviations, do NOT substitute parent/owner names.\n'
      '  confidence = high if certain, medium if likely, low if unrecognizable.\n'
      'STEP 4: Verify array.length === tile count. If not, add missing entries with confidence=low.\n'
      'Use "" for missing scalar fields. companies=[] if no company section exists.';

  @override
  void initState() {
    super.initState();
    _otherFields = _buildOtherFields();
    _processAll();
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl,_addrCtrl,_cityCtrl,_phoneCtrl,_waCtrl,_emailCtrl,_codeCtrl,_newCompCtrl,_upiCtrl]) c.dispose();
    for (final c in _companies) c.dispose();
    for (final f in _otherFields) f.dispose();
    super.dispose();
  }

  String _mimeFor(String ext) => switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png'           => 'image/png',
    'webp'          => 'image/webp',
    'heic' || 'heif'=> 'image/heic',
    'gif'           => 'image/gif',
    _               => 'image/jpeg',
  };

  Future<Uint8List> _readBytes(html.File f) async {
    final r = html.FileReader(); r.readAsDataUrl(f); await r.onLoad.first;
    return base64Decode((r.result as String).split(',').last);
  }

  Future<void> _processAll() async {
    final total = widget.files.length;
    final perImage = <({
      String name, String address, String city, String phone, String whatsapp,
      String email, String code,
      List<({String seen, String confidence})> companies,
    })>[];

    for (int i = 0; i < total; i++) {
      if (!mounted) return;
      setState(() => _progressText = 'Processing image ${i + 1} of $total…');
      try {
        final f = widget.files[i];
        final ext = f.name.toLowerCase().split('.').last;
        final bytes = await _readBytes(f);
        final resp = await http.post(
          Uri.parse(_ocrEdgeFn),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_base64': base64Encode(bytes),
            'mime_type': _mimeFor(ext),
            'prompt': _prompt,
          }),
        ).timeout(const Duration(seconds: 60));
        if (resp.statusCode != 200) throw Exception('OCR error on image ${i + 1} (HTTP ${resp.statusCode})');
        final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
        final jm = RegExp(r'\{[\s\S]*\}').firstMatch(txt);
        if (jm != null) {
          final dec = jsonDecode(jm.group(0)!) as Map<String, dynamic>;
          String sv(String k) => (dec[k] as String? ?? '').trim();
          final rawCos = dec['companies'] as List<dynamic>? ?? [];
          final cos = rawCos.map((e) {
            String seen, conf;
            if (e is Map<String, dynamic>) {
              seen = (e['seen'] as String? ?? '').trim();
              conf = (e['confidence'] as String? ?? 'medium').trim();
            } else { seen = e.toString().trim(); conf = 'medium'; }
            if (seen.isEmpty) return null;
            return (seen: seen, confidence: conf);
          }).whereType<({String seen, String confidence})>().toList();
          perImage.add((
            name: sv('supplier_name'), address: sv('address'), city: sv('city'),
            phone: sv('phone'), whatsapp: sv('whatsapp'), email: sv('email'),
            code: sv('supplier_code'), companies: cos,
          ));
        }
      } catch (_) {}
    }

    if (!mounted) return;
    if (perImage.isEmpty) {
      setState(() => _error = 'Could not extract any supplier data from the selected images.');
      return;
    }

    // Merge all images into ONE supplier (front+back/multi-page card).
    final anchor = perImage.firstWhere((s) => s.name.isNotEmpty, orElse: () => perImage.first);

    Set<String> splitPhone(String p) =>
        p.split(RegExp(r'[,;/]')).map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
    final allPhones = <String>{};
    final allWhatsapp = <String>{};
    for (final s in perImage) {
      allPhones.addAll(splitPhone(s.phone));
      allWhatsapp.addAll(splitPhone(s.whatsapp));
    }

    int confRank(String c) => c == 'high' ? 2 : c == 'medium' ? 1 : 0;
    final seenMap = <String, ({String seen, String confidence})>{};
    for (final s in perImage) {
      for (final co in s.companies) {
        final key = co.seen.toLowerCase().trim();
        final ex = seenMap[key];
        if (ex == null || confRank(co.confidence) > confRank(ex.confidence)) seenMap[key] = co;
      }
    }
    final pooled = seenMap.values.toList();

    // Populate form controllers
    _nameCtrl.text  = anchor.name;
    _addrCtrl.text  = anchor.address.isNotEmpty ? anchor.address :
        perImage.firstWhere((s) => s.address.isNotEmpty, orElse: () => anchor).address;
    _cityCtrl.text  = anchor.city.isNotEmpty ? anchor.city :
        perImage.firstWhere((s) => s.city.isNotEmpty, orElse: () => anchor).city;
    _phoneCtrl.text = allPhones.join(', ');
    _waCtrl.text    = allWhatsapp.join(', ');
    _emailCtrl.text = anchor.email.isNotEmpty ? anchor.email :
        perImage.firstWhere((s) => s.email.isNotEmpty, orElse: () => anchor).email;
    _codeCtrl.text  = anchor.code.isNotEmpty ? anchor.code :
        perImage.firstWhere((s) => s.code.isNotEmpty, orElse: () => anchor).code;
    _companies = pooled.map((co) => _ResolvedCompany(seen: co.seen, confidence: co.confidence)).toList();

    RenderLog.write('c66_image_count', total.toString());
    RenderLog.write('c66_pooled_company_count', pooled.length.toString());
    RenderLog.write('c66_path', 'form');
    RenderLog.write('c66_dropdown1_present', 'true');
    RenderLog.write('c66_dropdown2_present', 'true');
    RenderLog.write('c66_dropdown2_field_count', _otherFields.length.toString());

    if (mounted) setState(() => _step = _MultiStep.review);
  }

  Future<void> _doImport() async {
    final name = _nameCtrl.text.trim();
    RenderLog.write('c67_import_tapped', 'true');
    if (name.isEmpty) {
      RenderLog.write('c67_insert_attempted', 'false');
      showToast(context, 'Supplier name is required', isError: true);
      return;
    }
    final upiRaw = _upiCtrl.text.trim();
    if (upiRaw.isNotEmpty &&
        !RegExp(r'^[0-9A-Za-z._\-]{2,}@[A-Za-z]{2,}$').hasMatch(upiRaw)) {
      showToast(context, 'Enter a valid UPI id (name@bank)', isError: true);
      return;
    }
    RenderLog.write('c67_insert_attempted', 'true');
    RenderLog.write('c67_insert_table', 'supplier_profiles');
    setState(() => _step = _MultiStep.importing);
    try {
      final client = Supabase.instance.client;
      final uid = client.auth.currentUser?.id;
      final rec = <String, dynamic>{
        'supplier_name': name, 'status': 'Active', 'approved': true, 'is_deleted': false,
        if (uid != null) 'user_id': uid,
      };
      if (_addrCtrl.text.trim().isNotEmpty) rec['street_address'] = _addrCtrl.text.trim();
      if (_cityCtrl.text.trim().isNotEmpty) rec['city'] = _cityCtrl.text.trim();
      if (_phoneCtrl.text.trim().isNotEmpty) rec['contact_no'] = _phoneCtrl.text.trim();
      if (_waCtrl.text.trim().isNotEmpty) rec['whatsapp_no'] = _waCtrl.text.trim();
      if (_emailCtrl.text.trim().isNotEmpty) rec['email'] = _emailCtrl.text.trim();
      if (_codeCtrl.text.trim().isNotEmpty) rec['supplier_code'] = _codeCtrl.text.trim();
      if (upiRaw.isNotEmpty) rec['payment_address'] = upiRaw;
      for (final f in _otherFields) {
        final v = f.value; if (v.isNotEmpty) rec[f.column] = v;
      }
      _applySpnValuesToRec(rec, _spnValues);
      final inserted = await client.from('supplier_profiles').insert(rec).select('id').single();
      final supplierId = inserted['id'] as String;
      RenderLog.write('c67_new_supplier_id', supplierId);
      final companies = _companies.where((c) => c.canonical.isNotEmpty).toList();
      int companiesWritten = 0;
      if (companies.isNotEmpty) {
        for (final co in companies) {
          try { await client.from('company').upsert({'company_name': co.canonical}, onConflict: 'company_name'); } catch (_) {}
        }
        await client.from('supplier_company').upsert(
          companies.map((co) => <String, dynamic>{
            'supplier_id': supplierId, 'supplier_name': name, 'supplier_company': co.canonical,
          }).toList(),
          onConflict: 'supplier_id,supplier_company',
          ignoreDuplicates: true,
        );
        companiesWritten = companies.length;
      }
      RenderLog.write('c67_insert_status', 'ok');
      RenderLog.write('c67_companies_written', companiesWritten.toString());
      RenderLog.write('multi_image_ocr_imported', '1');
      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        showToast(context, 'Imported $name with ${companies.length} compan${companies.length == 1 ? 'y' : 'ies'} from ${widget.files.length} image${widget.files.length == 1 ? '' : 's'}', duration: const Duration(seconds: 5));
      }
    } catch (e) {
      RenderLog.write('c67_insert_status', 'error:${e.toString().substring(0, e.toString().length > 80 ? 80 : e.toString().length)}');
      if (mounted) {
        setState(() => _step = _MultiStep.review);
        showToast(context, 'Import failed: ${e.toString().replaceFirst('Exception: ', '')}', isError: true, duration: const Duration(seconds: 8));
      }
    }
  }

  Widget _field(String label, TextEditingController ctrl, {int maxLines = 1}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: Color(0xFF6B7280), letterSpacing: 0.3)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
          decoration: InputDecoration(
            filled: true, fillColor: const Color(0xFFF5F6F8),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
          ),
        ),
        const SizedBox(height: 10),
      ]);

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 32),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
            const SizedBox(height: 16),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          ]))),
      );
    }

    if (_step == _MultiStep.processing || _step == _MultiStep.importing) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
            const SizedBox(height: 16),
            Text(
              _step == _MultiStep.processing ? _progressText : 'Importing supplier…',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
            ),
          ]))),
      );
    }

    // Review form — same layout as single-image
    RenderLog.write('c428_spn_import', 'margin,cd,behaviour,payterm=dyn+add');
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 640, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Import from Image — Review',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                const SizedBox(height: 2),
                Text('${widget.files.length} image${widget.files.length == 1 ? '' : 's'} · all pages merged',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ])),
              IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Flexible(child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('SUPPLIER DETAILS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: Color(0xFF6B7280), letterSpacing: 0.5)),
              const SizedBox(height: 10),
              _field('Supplier Name *', _nameCtrl),
              _field('Address', _addrCtrl, maxLines: 2),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _field('City', _cityCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _field('Supplier Code', _codeCtrl)),
              ]),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _field('Phone', _phoneCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _field('WhatsApp / Mobile', _waCtrl)),
              ]),
              _field('Email', _emailCtrl),
              _field('Payment Address (UPI)', _upiCtrl),
              const SizedBox(height: 4),
              const Divider(color: Color(0xFFE5E7EB)),
              const SizedBox(height: 4),
              // Dropdown 1: SPN points
              InkWell(
                onTap: () => setState(() => _spnExpanded = !_spnExpanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    const Expanded(child: Text('SPN points (optional)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280)))),
                    Icon(_spnExpanded ? Icons.expand_less : Icons.expand_more, size: 18, color: const Color(0xFF9CA3AF)),
                  ]),
                ),
              ),
              if (_spnExpanded) ...[
                const SizedBox(height: 4),
                for (final col in _spnCols) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _SpnDropdown(
                      field: col.$2,
                      formLabel: spnFieldDisplayLabel[col.$2],
                      initialValue: _spnValues[col.$2],
                      onPick: (f, v) => setState(() => _spnValues[f] = v),
                    ),
                  ),
                ],
                const SizedBox(height: 4),
              ],
              const Divider(color: Color(0xFFE5E7EB)),
              const SizedBox(height: 4),
              // Dropdown 2: Other details
              InkWell(
                onTap: () => setState(() => _otherExpanded = !_otherExpanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    const Expanded(child: Text('Other details (optional)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280)))),
                    Icon(_otherExpanded ? Icons.expand_less : Icons.expand_more, size: 18, color: const Color(0xFF9CA3AF)),
                  ]),
                ),
              ),
              if (_otherExpanded) ...[
                const SizedBox(height: 4),
                ..._buildOptFieldWidgets(_otherFields, setState),
                const SizedBox(height: 4),
              ],
              const Divider(color: Color(0xFFE5E7EB)),
              const SizedBox(height: 10),
              Row(children: [
                const Expanded(child: Text('COMPANY LIST', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                    color: Color(0xFF6B7280), letterSpacing: 0.5))),
                Text('${_companies.length} compan${_companies.length == 1 ? 'y' : 'ies'}',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
              ]),
              const SizedBox(height: 10),
              if (_companies.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No companies extracted. Add manually below.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                ),
              ...List.generate(_companies.length, (i) {
                final co = _companies[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(color: const Color(0xFFE6F4EA), borderRadius: BorderRadius.circular(16)),
                      child: Text(co.seen, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF1B7F3B)),
                          overflow: TextOverflow.ellipsis, maxLines: 1),
                    ),
                    const SizedBox(height: 4),
                    Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      Expanded(child: TextField(
                        controller: co.ctrl,
                        style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                        decoration: InputDecoration(
                          filled: true, fillColor: const Color(0xFFF5F6F8),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                              borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
                        ),
                      )),
                      const SizedBox(width: 12),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, size: 18, color: Color(0xFFDC2626)),
                        onPressed: () => setState(() { _companies[i].dispose(); _companies.removeAt(i); }),
                        padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                      ),
                    ]),
                  ]),
                );
              }),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: TextField(
                  controller: _newCompCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Add company…',
                    hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                    filled: true, fillColor: const Color(0xFFF5F6F8),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
                  ),
                  onSubmitted: (v) {
                    final s = v.trim();
                    if (s.isNotEmpty) setState(() { _companies.add(_ResolvedCompany(seen: s, confidence: 'high')); _newCompCtrl.clear(); });
                  },
                )),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 20, color: Color(0xFF1B7A43)),
                  onPressed: () {
                    final s = _newCompCtrl.text.trim();
                    if (s.isNotEmpty) setState(() { _companies.add(_ResolvedCompany(seen: s, confidence: 'high')); _newCompCtrl.clear(); });
                  },
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                ),
              ]),
              const SizedBox(height: 16),
            ]),
          )),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
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
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                child: const Text('Import', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─── Import Supplier popover (mirrors Clear Cart popover exactly) ─────────────

class _ImportSupplierPopover extends StatefulWidget {
  final LayerLink link;
  final VoidCallback onDismissed;
  final VoidCallback onManually;
  final VoidCallback onFile;

  const _ImportSupplierPopover({
    required this.link,
    required this.onDismissed,
    required this.onManually,
    required this.onFile,
  });

  @override
  State<_ImportSupplierPopover> createState() => _ImportSupplierPopoverState();
}

class _ImportSupplierPopoverState extends State<_ImportSupplierPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _fade;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _fade = _ctrl;
    _ctrl.forward();
    RenderLog.write('import_choice_popover_rendered', 'true');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    await _ctrl.animateTo(0,
        duration: const Duration(milliseconds: 180), curve: Curves.easeIn);
    widget.onDismissed();
  }

  Future<void> _handleManually() async {
    if (_dismissing) return;
    _dismissing = true;
    await _ctrl.animateTo(0,
        duration: const Duration(milliseconds: 140), curve: Curves.easeIn);
    widget.onManually();
  }

  Future<void> _handleFile() async {
    if (_dismissing) return;
    _dismissing = true;
    await _ctrl.animateTo(0,
        duration: const Duration(milliseconds: 140), curve: Curves.easeIn);
    widget.onFile();
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('import_supplier_popup_above', 'true');
    return Stack(children: [
      // Tap-outside barrier (no dark scrim — matches Clear Cart)
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _dismiss,
          child: const SizedBox.expand(),
        ),
      ),
      // Floating popover anchored ABOVE the Import Supplier button
      CompositedTransformFollower(
        link: widget.link,
        targetAnchor: Alignment.topRight,
        followerAnchor: Alignment.bottomRight,
        offset: const Offset(0, -6),
        showWhenUnlinked: false,
        child: ScaleTransition(
          scale: _scale,
          alignment: Alignment.bottomRight,
          child: FadeTransition(
            opacity: _fade,
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              child: Container(
                width: 272,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Expanded(
                        child: Text(
                          'How do you want to add this supplier?',
                          style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                        ),
                      ),
                      GestureDetector(
                        onTap: _dismiss,
                        child: const Icon(Icons.close,
                            size: 16, color: Color(0xFF9CA3AF)),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: _handleManually,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFFDCFCE7),
                            foregroundColor: const Color(0xFF15803D),
                            minimumSize: const Size(0, 44),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            elevation: 0,
                            shadowColor: Colors.transparent,
                          ),
                          child: const Text('Manually',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          onPressed: _handleFile,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1B7A43),
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 44),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          child: const Text('File',
                              style: TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

// ─── Manual supplier import — field config ────────────────────────────────────

const _kFieldGroup = <String, String>{
  'supplier_name':  'Identity & Account',
  'contact_name':   'Identity & Account',
  'contact_person': 'Identity & Account',
  'supplier_code':  'Identity & Account',
  'store_type':     'Identity & Account',
  'stockist_type':  'Identity & Account',
  'status':         'Identity & Account',
  'behaviour':      'Identity & Account',
  'whatsapp_no':    'Contact',
  'phone':          'Contact',
  'contact_no':     'Contact',
  'other_contact':  'Contact',
  'email':          'Contact',
  'map_link':       'Contact',
  'city':           'Location',
  'state':          'Location',
  'address':        'Location',
  'street_address': 'Location',
  'pincode':        'Location',
  'pin_code':       'Location',
  'payment_term':   'Business Terms',
  'payment_type':   'Business Terms',
  'margin':         'Business Terms',
  'cd_condition':   'Business Terms',
  'deal':           'Business Terms',
  'range_zone':     'Business Terms',
  'gstin':          'Legal & Financial',
  'gst':            'Legal & Financial',
  'drug_license':   'Legal & Financial',
  'dl_1':           'Legal & Financial',
  'dl_2':           'Legal & Financial',
  'notes':          'Other',
};

const _kFieldLabel = <String, String>{
  'supplier_name':  'Supplier Name',
  'contact_name':   'Contact Name',
  'contact_person': 'Contact Person',
  'supplier_code':  'Supplier Code',
  'store_type':     'Store Type',
  'stockist_type':  'Stockist Type',
  'status':         'Status',
  'behaviour':      'Behaviour / Rating',
  'whatsapp_no':    'WhatsApp Number',
  'phone':          'Phone',
  'contact_no':     'Phone / Landline',
  'other_contact':  'Other Contact',
  'email':          'Email',
  'map_link':       'Map Link',
  'city':           'City',
  'state':          'State',
  'address':        'Address',
  'street_address': 'Street Address',
  'pincode':        'Pincode',
  'pin_code':       'PIN Code',
  'payment_term':   'Payment Term',
  'payment_type':   'Payment Type',
  'margin':         'Margin',
  'cd_condition':   'CD Condition',
  'deal':           'Deal',
  'range_zone':     'Range / Zone',
  'gstin':          'GSTIN',
  'gst':            'GST Number',
  'drug_license':   'Drug License',
  'dl_1':           'Drug License 1 (DL-1)',
  'dl_2':           'Drug License 2 (DL-2)',
  'notes':          'Notes',
};

const _kDropdownOptions = <String, List<String>>{
  'status':       ['Active', 'Inactive', 'Suspended', 'Pending', 'Blocked'],
  'payment_type': ['cash', 'credit'],
  'cd_condition': ['NO CONDITION', '2K+ BILL', '3K+ BILL'],
};

const _kRequiredFields = {'supplier_name'};

const _kAllFields = <String>[
  'supplier_name', 'contact_name', 'contact_person', 'supplier_code',
  'store_type', 'stockist_type', 'status', 'behaviour',
  'whatsapp_no', 'phone', 'contact_no', 'other_contact', 'email', 'map_link',
  'city', 'state', 'address', 'street_address', 'pincode', 'pin_code',
  'payment_term', 'payment_type', 'margin', 'cd_condition', 'deal', 'range_zone',
  'gstin', 'gst', 'drug_license', 'dl_1', 'dl_2',
  'notes',
];

const _kGroupOrder = <String>[
  'Identity & Account',
  'Contact',
  'Location',
  'Business Terms',
  'Legal & Financial',
  'Other',
];

// ─── Manual supplier import dialog ───────────────────────────────────────────

class _ManualSupplierImportDialog extends StatefulWidget {
  final VoidCallback onImported;
  const _ManualSupplierImportDialog({required this.onImported});

  @override
  State<_ManualSupplierImportDialog> createState() => _ManualSupplierImportDialogState();
}

class _ManualSupplierImportDialogState extends State<_ManualSupplierImportDialog> {
  int _page = 1;
  final Map<String, TextEditingController> _ctrl = {};
  final Map<String, String?> _dropdownValues = {'status': 'Active'};
  final Set<String> _expandedSections = {'Identity & Account'};
  String? _page1Error;
  bool _submitting = false;
  String? _submitError;
  CodeStatus _supCodeStatus = CodeStatus.idle;

  // Page 2 — category mode
  bool _byCategory = true;
  List<String> _allCategories = [];
  bool _loadingCategories = false;
  final List<String> _selectedCategories = [];
  final Map<String, List<String>> _categoriesCompanyList = {};
  final Map<String, bool> _loadingCategoryCompanies = {};
  final Map<String, Set<String>> _selectedCompaniesByCategory = {};

  // Page 2 — company mode
  List<String> _allCompanies = [];
  bool _loadingAllCompanies = false;
  String _companySearch = '';
  final Set<String> _selectedCompaniesDirect = {};
  List<Map<String, String>> _categoriesByCompanyRows = [];
  bool _loadingCategoriesByCompany = false;

  Set<String> get _unionCompanies {
    final s = <String>{};
    for (final cats in _selectedCompaniesByCategory.values) s.addAll(cats);
    s.addAll(_selectedCompaniesDirect);
    return s;
  }

  @override
  void initState() {
    super.initState();
    for (final f in _kAllFields) {
      if (!_kDropdownOptions.containsKey(f)) _ctrl[f] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) c.dispose();
    super.dispose();
  }

  // ── loaders ────────────────────────────────────────────────────────────────

  Future<void> _loadCategories() async {
    if (_allCategories.isNotEmpty || _loadingCategories) return;
    setState(() => _loadingCategories = true);
    try {
      final rows = await Supabase.instance.client.rpc('get_therapeutic_categories');
      if (mounted) setState(() {
        _allCategories = (rows as List).map((r) => r['category'] as String).toList();
        _loadingCategories = false;
      });
      RenderLog.write('manual_import_categories_loaded', _allCategories.length.toString());
    } catch (_) {
      if (mounted) setState(() => _loadingCategories = false);
    }
  }

  Future<void> _loadCompaniesByCategory(String cat) async {
    if (_categoriesCompanyList.containsKey(cat) || (_loadingCategoryCompanies[cat] ?? false)) return;
    setState(() => _loadingCategoryCompanies[cat] = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('get_companies_by_category', params: {'p_category': cat});
      if (mounted) setState(() {
        _categoriesCompanyList[cat] =
            (rows as List).map((r) => r['company_name'] as String).toList();
        _loadingCategoryCompanies[cat] = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingCategoryCompanies[cat] = false);
    }
  }

  Future<void> _loadAllCompanies() async {
    if (_allCompanies.isNotEmpty || _loadingAllCompanies) return;
    setState(() => _loadingAllCompanies = true);
    try {
      final rows = await Supabase.instance.client.rpc('get_all_companies');
      if (mounted) setState(() {
        _allCompanies = (rows as List).map((r) => r['company_name'] as String).toList();
        _loadingAllCompanies = false;
      });
      RenderLog.write('manual_import_all_companies_loaded', _allCompanies.length.toString());
    } catch (_) {
      if (mounted) setState(() => _loadingAllCompanies = false);
    }
  }

  Future<void> _loadCategoriesByCompany() async {
    final companies = _selectedCompaniesDirect.toList();
    if (companies.isEmpty) {
      setState(() => _categoriesByCompanyRows = []);
      return;
    }
    setState(() => _loadingCategoriesByCompany = true);
    try {
      final rows = await Supabase.instance.client
          .rpc('get_categories_by_company', params: {'p_companies': companies});
      if (mounted) setState(() {
        _categoriesByCompanyRows = (rows as List).map((r) => {
          'category': r['category'] as String,
          'company_name': r['company_name'] as String,
        }).toList();
        _loadingCategoriesByCompany = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingCategoriesByCompany = false);
    }
  }

  // ── validation & submit ────────────────────────────────────────────────────

  bool _validatePage1() {
    if (_supCodeStatus == CodeStatus.taken) {
      setState(() => _page1Error = 'Supplier Code is already in use — choose another.');
      return false;
    }
    if (_supCodeStatus == CodeStatus.invalid) {
      setState(() => _page1Error = 'Supplier Code must be 3 letters + 3 digits (e.g. ABC123).');
      return false;
    }
    for (final f in _kRequiredFields) {
      final v = _kDropdownOptions.containsKey(f)
          ? (_dropdownValues[f] ?? '')
          : (_ctrl[f]?.text.trim() ?? '');
      if (v.isEmpty) {
        setState(() => _page1Error = '${_kFieldLabel[f] ?? f} is required.');
        return false;
      }
    }
    setState(() => _page1Error = null);
    return true;
  }

  Future<void> _submit() async {
    if (!_validatePage1()) { setState(() => _page = 1); return; }
    setState(() { _submitting = true; _submitError = null; });
    try {
      final client = Supabase.instance.client;
      final rec = <String, dynamic>{'approved': true, 'is_deleted': false};
      for (final f in _kAllFields) {
        if (_kDropdownOptions.containsKey(f)) {
          final v = _dropdownValues[f];
          if (v != null && v.isNotEmpty) rec[f] = v;
        } else {
          final v = _ctrl[f]?.text.trim() ?? '';
          if (v.isNotEmpty) rec[f] = v;
        }
      }
      if (!rec.containsKey('status')) rec['status'] = 'Active';

      RenderLog.write('manual_import_submitting', rec['supplier_name']?.toString() ?? '');
      final inserted = await client.from('supplier_profiles').insert(rec).select('id').single();
      final supplierId = inserted['id'] as String;
      final supplierName = (rec['supplier_name'] as String? ?? '').trim();
      RenderLog.write('manual_import_supplier_inserted', supplierId);

      final companies = _unionCompanies.toList();
      if (companies.isNotEmpty) {
        final scRows = companies.map((co) => <String, dynamic>{
          'supplier_id': supplierId,
          'supplier_name': supplierName,
          'supplier_company': co,
        }).toList();
        await client.from('supplier_company').insert(scRows);
        RenderLog.write('manual_import_companies_linked', companies.length.toString());
      }

      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        showToast(context, 'Added $supplierName with ${companies.length} compan${companies.length == 1 ? 'y' : 'ies'}',
            duration: const Duration(seconds: 5));
      }
    } catch (e) {
      if (mounted) setState(() {
        _submitting = false;
        _submitError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 640, maxHeight: MediaQuery.of(context).size.height * 0.92),
        child: Column(children: [
          _buildHeader(),
          _buildProgress(),
          Expanded(child: _page == 1 ? _buildPage1() : _buildPage2()),
          _buildBottomBar(),
        ]),
      ),
    );
  }

  Widget _buildHeader() {
    final title = _page == 1
        ? 'Add Supplier Manually — Details'
        : 'Add Supplier Manually — Companies';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB)))),
      child: Row(children: [
        Expanded(child: Text(title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827)))),
        GestureDetector(
          onTap: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
        ),
      ]),
    );
  }

  Widget _buildProgress() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(children: [
        _progressStep(1, 'Supplier Details'),
        Expanded(child: Container(height: 2,
            color: _page >= 2 ? const Color(0xFF1B7A43) : const Color(0xFFE5E7EB))),
        _progressStep(2, 'Companies'),
      ]),
    );
  }

  Widget _progressStep(int n, String label) {
    final active = _page >= n;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 24, height: 24,
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1B7A43) : const Color(0xFFE5E7EB),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Text('$n', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
            color: active ? Colors.white : const Color(0xFF9CA3AF))),
      ),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
          color: active ? const Color(0xFF1B7A43) : const Color(0xFF9CA3AF))),
    ]);
  }

  // ── page 1 ─────────────────────────────────────────────────────────────────

  Widget _buildPage1() {
    RenderLog.write('manual_import_page1_rendered', 'true');
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_page1Error != null) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFCA5A5)),
            ),
            child: Text(_page1Error!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
          ),
          const SizedBox(height: 8),
        ],
        ..._kGroupOrder.map(_buildSection),
      ]),
    );
  }

  Widget _buildSection(String group) {
    final fields = _kAllFields.where((f) => (_kFieldGroup[f] ?? 'Other') == group).toList();
    if (fields.isEmpty) return const SizedBox.shrink();
    final isOpen = _expandedSections.contains(group);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(children: [
          InkWell(
            onTap: () => setState(() =>
                isOpen ? _expandedSections.remove(group) : _expandedSections.add(group)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                Expanded(child: Text(group,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                        color: Color(0xFF374151)))),
                AnimatedRotation(
                  turns: isOpen ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more, size: 18, color: Color(0xFF6B7280)),
                ),
              ]),
            ),
          ),
          if (isOpen) ...[
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: fields.map(_buildField).toList()),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _buildField(String col) {
    final label = _kFieldLabel[col] ?? col;
    final required = _kRequiredFields.contains(col);
    if (col == 'supplier_code') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: CodeField(
          controller: _ctrl['supplier_code']!,
          label: label,
          hint: 'ABC123',
          isTaken: (code) async => await Supabase.instance.client
              .rpc('is_supplier_code_taken', params: {'p_code': code}) as bool,
          requiredField: false,
          onStatusChanged: (s) => setState(() => _supCodeStatus = s),
        ),
      );
    }
    if (_kDropdownOptions.containsKey(col)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: DropdownButtonFormField<String>(
          value: _dropdownValues[col],
          decoration: InputDecoration(
            labelText: required ? '$label *' : label,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            isDense: true,
          ),
          items: [
            if (!required)
              const DropdownMenuItem<String>(
                  value: null,
                  child: Text('— none —',
                      style: TextStyle(color: Color(0xFF9CA3AF)))),
            ..._kDropdownOptions[col]!.map((o) =>
                DropdownMenuItem<String>(value: o, child: Text(o))),
          ],
          onChanged: (v) => setState(() => _dropdownValues[col] = v),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: _ctrl[col],
        decoration: InputDecoration(
          labelText: required ? '$label *' : label,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          isDense: true,
        ),
        maxLines: (col == 'notes' || col == 'address' || col == 'street_address') ? 3 : 1,
        style: const TextStyle(fontSize: 13),
      ),
    );
  }

  // ── page 2 ─────────────────────────────────────────────────────────────────

  Widget _buildPage2() {
    RenderLog.write('manual_import_page2_rendered', 'true');
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
        child: Row(children: [
          Expanded(child: _modeBtn('By Category', _byCategory, () {
            setState(() => _byCategory = true);
            _loadCategories();
          })),
          const SizedBox(width: 8),
          Expanded(child: _modeBtn('By Company', !_byCategory, () {
            setState(() => _byCategory = false);
            _loadAllCompanies();
          })),
        ]),
      ),
      Expanded(child: _byCategory ? _buildCategoryMode() : _buildCompanyMode()),
      _buildSelectedCompanyChips(),
    ]);
  }

  Widget _modeBtn(String label, bool active, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF1B7A43) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: Text(label, style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600,
            color: active ? Colors.white : const Color(0xFF374151))),
      ),
    );
  }

  Widget _buildCategoryMode() {
    if (_loadingCategories) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_allCategories.isEmpty) {
      return Center(child: TextButton(
          onPressed: _loadCategories,
          child: const Text('Load categories')));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Select therapeutic categories:',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6, runSpacing: 6,
          children: _allCategories.map((cat) {
            final sel = _selectedCategories.contains(cat);
            return FilterChip(
              label: Text(cat, style: const TextStyle(fontSize: 11)),
              selected: sel,
              onSelected: (v) {
                setState(() {
                  if (v) {
                    _selectedCategories.add(cat);
                    _loadCompaniesByCategory(cat);
                  } else {
                    _selectedCategories.remove(cat);
                    _selectedCompaniesByCategory.remove(cat);
                  }
                });
              },
              selectedColor: const Color(0xFFDCFCE7),
              checkmarkColor: const Color(0xFF1B7A43),
              backgroundColor: const Color(0xFFF3F4F6),
              side: BorderSide(
                  color: sel ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
              labelStyle: TextStyle(
                  color: sel ? const Color(0xFF1B7A43) : const Color(0xFF374151)),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        ..._selectedCategories.map(_buildCategoryCompanySection),
      ]),
    );
  }

  Widget _buildCategoryCompanySection(String cat) {
    final loading = _loadingCategoryCompanies[cat] ?? false;
    final companies = _categoriesCompanyList[cat] ?? [];
    final selected = _selectedCompaniesByCategory[cat] ?? {};
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFFF9FAFB),
            borderRadius:
                BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8)),
          ),
          child: Row(children: [
            Expanded(child: Text(cat,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                    color: Color(0xFF374151)))),
            Text('${selected.length} selected',
                style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
          ]),
        ),
        if (loading)
          const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
        else if (companies.isEmpty)
          const Padding(
              padding: EdgeInsets.all(10),
              child: Text('No companies found.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))))
        else
          Padding(
            padding: const EdgeInsets.all(10),
            child: Wrap(
              spacing: 6, runSpacing: 6,
              children: companies.map((co) {
                final isSel = selected.contains(co);
                return FilterChip(
                  label: Text(co, style: const TextStyle(fontSize: 11)),
                  selected: isSel,
                  onSelected: (v) {
                    setState(() {
                      final s = _selectedCompaniesByCategory[cat] ?? {};
                      v ? s.add(co) : s.remove(co);
                      _selectedCompaniesByCategory[cat] = s;
                    });
                  },
                  selectedColor: const Color(0xFFDCFCE7),
                  checkmarkColor: const Color(0xFF1B7A43),
                  backgroundColor: const Color(0xFFF3F4F6),
                  side: BorderSide(
                      color: isSel ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
                  labelStyle: TextStyle(
                      color: isSel ? const Color(0xFF1B7A43) : const Color(0xFF374151)),
                );
              }).toList(),
            ),
          ),
      ]),
    );
  }

  Widget _buildCompanyMode() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(
          onChanged: (v) => setState(() => _companySearch = v.toLowerCase()),
          decoration: InputDecoration(
            hintText: 'Search companies...',
            prefixIcon: const Icon(Icons.search, size: 18),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            isDense: true,
          ),
          style: const TextStyle(fontSize: 13),
        ),
        const SizedBox(height: 8),
        if (_loadingAllCompanies)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else ...[
          Builder(builder: (_) {
            final filtered = _allCompanies
                .where((c) => _companySearch.isEmpty ||
                    c.toLowerCase().contains(_companySearch))
                .take(100)
                .toList();
            return Wrap(
              spacing: 6, runSpacing: 6,
              children: filtered.map((co) {
                final isSel = _selectedCompaniesDirect.contains(co);
                return FilterChip(
                  label: Text(co, style: const TextStyle(fontSize: 11)),
                  selected: isSel,
                  onSelected: (v) {
                    setState(() {
                      v ? _selectedCompaniesDirect.add(co)
                        : _selectedCompaniesDirect.remove(co);
                    });
                    _loadCategoriesByCompany();
                  },
                  selectedColor: const Color(0xFFDCFCE7),
                  checkmarkColor: const Color(0xFF1B7A43),
                  backgroundColor: const Color(0xFFF3F4F6),
                  side: BorderSide(
                      color: isSel ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
                  labelStyle: TextStyle(
                      color: isSel ? const Color(0xFF1B7A43) : const Color(0xFF374151)),
                );
              }).toList(),
            );
          }),
          if (_selectedCompaniesDirect.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Categories covered:',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                    color: Color(0xFF374151))),
            const SizedBox(height: 6),
            if (_loadingCategoriesByCompany)
              const CircularProgressIndicator(strokeWidth: 2)
            else
              _buildCategoryCoverageSection(),
          ],
        ],
      ]),
    );
  }

  Widget _buildCategoryCoverageSection() {
    if (_categoriesByCompanyRows.isEmpty) {
      return const Text('No category data found.',
          style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)));
    }
    final byCategory = <String, List<String>>{};
    for (final row in _categoriesByCompanyRows) {
      (byCategory[row['category']!] ??= []).add(row['company_name']!);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: byCategory.entries.map((e) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.key, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
              color: Color(0xFF374151))),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 4, children: e.value.map((co) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: const Color(0xFFDCFCE7),
                borderRadius: BorderRadius.circular(12)),
            child: Text(co,
                style: const TextStyle(fontSize: 11, color: Color(0xFF15803D))),
          )).toList()),
        ]),
      )).toList(),
    );
  }

  Widget _buildSelectedCompanyChips() {
    final union = _unionCompanies.toList()..sort();
    RenderLog.write('manual_import_selected_summary_rendered', union.length.toString());
    return Container(
      height: 52,
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB)))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 8),
          child: Text('Selected (${union.length})',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                  color: Color(0xFF374151))),
        ),
        Expanded(
          child: union.isEmpty
              ? const Text('None', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))
              : Stack(children: [
                  ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: union.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final co = union[i];
                      return Chip(
                        label: Text(co, style: const TextStyle(fontSize: 11)),
                        deleteIcon: const Icon(Icons.close, size: 12),
                        onDeleted: () => setState(() {
                          _selectedCompaniesDirect.remove(co);
                          for (final s in _selectedCompaniesByCategory.values) s.remove(co);
                        }),
                        backgroundColor: const Color(0xFFDCFCE7),
                        side: const BorderSide(color: Color(0xFF1B7A43)),
                        labelStyle: const TextStyle(color: Color(0xFF15803D)),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                      );
                    },
                  ),
                  // Fade hint on right edge
                  Positioned(
                    right: 0, top: 0, bottom: 0,
                    child: IgnorePointer(
                      child: Container(
                        width: 24,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [Colors.transparent, Colors.white],
                          ),
                        ),
                      ),
                    ),
                  ),
                ]),
        ),
        const SizedBox(width: 16),
      ]),
    );
  }

  // ── bottom bar ─────────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_submitError != null)
          Container(
            padding: const EdgeInsets.all(10),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFCA5A5)),
            ),
            child: Text(_submitError!,
                style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
          ),
        Row(children: [
          if (_page == 2) ...[
            OutlinedButton(
              onPressed: _submitting ? null : () => setState(() => _page = 1),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFFD1D5DB)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('← Back',
                  style: TextStyle(color: Color(0xFF374151))),
            ),
            const SizedBox(width: 8),
          ],
          OutlinedButton(
            onPressed: _submitting ? null : () => Navigator.of(context).pop(),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Color(0xFFD1D5DB)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF374151))),
          ),
          const Spacer(),
          if (_page == 1)
            FilledButton(
              onPressed: () {
                if (_validatePage1()) {
                  setState(() { _page = 2; _page1Error = null; });
                  _loadCategories();
                  RenderLog.write('manual_import_page2_opened', 'true');
                }
              },
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Next →',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            )
          else
            FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: _submitting
                  ? const SizedBox(width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Submit ✓',
                      style: TextStyle(fontWeight: FontWeight.w600)),
            ),
        ]),
      ]),
    );
  }
}

extension _ListExt<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) { if (test(e)) return e; }
    return null;
  }
}

// ── Inquiry status badge ──────────────────────────────────────────────────────

class _InquiryStatusBadge extends StatelessWidget {
  final String status;
  const _InquiryStatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final (bg, fg, label) = switch (status) {
      'responded'          => (const Color(0xFFD1FAE5), const Color(0xFF065F46), 'Responded'),
      'partially_responded'=> (const Color(0xFFFEF3C7), const Color(0xFF92400E), 'Partial'),
      'expired'            => (const Color(0xFFF3F4F6), const Color(0xFF6B7280), 'Expired'),
      _                    => (const Color(0xFFEFF6FF), const Color(0xFF1E40AF), 'Pending'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

// ── Staging review card (approve/reject) ──────────────────────────────────────

class _StagingCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _StagingCard({
    required this.title,
    required this.subtitle,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0,1))],
      ),
      child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
          if (subtitle.isNotEmpty)
            Text(subtitle, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
        ])),
        const SizedBox(width: 8),
        TextButton(
          onPressed: onApprove,
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF065F46),
            backgroundColor: const Color(0xFFD1FAE5),
            minimumSize: const Size(72, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          child: const Text('Approve', style: TextStyle(fontSize: 12)),
        ),
        const SizedBox(width: 6),
        TextButton(
          onPressed: onReject,
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF991B1B),
            backgroundColor: const Color(0xFFFEE2E2),
            minimumSize: const Size(60, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          child: const Text('Reject', style: TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }
}

// ── Inquiry send-contact popover (Clear Cart style) ───────────────────────────

class _InquirySendPopover extends StatefulWidget {
  final LayerLink link;
  final String supName;
  final List<String> waNumbers;
  final List<String> otherNumbers;
  final List<String> emails;
  final String inquiryLink;
  final VoidCallback onDismissed;
  final void Function(String) onWaNumber;
  final void Function(String) onEmail;

  const _InquirySendPopover({
    required this.link,
    required this.supName,
    required this.waNumbers,
    required this.otherNumbers,
    required this.emails,
    required this.inquiryLink,
    required this.onDismissed,
    required this.onWaNumber,
    required this.onEmail,
  });

  @override
  State<_InquirySendPopover> createState() => _InquirySendPopoverState();
}

class _InquirySendPopoverState extends State<_InquirySendPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    await _ctrl.animateTo(0, duration: const Duration(milliseconds: 180), curve: Curves.easeIn);
    widget.onDismissed();
  }

  @override
  Widget build(BuildContext context) {
    final hasWa    = widget.waNumbers.isNotEmpty;
    final hasOther = widget.otherNumbers.isNotEmpty;
    final hasEmail = widget.emails.isNotEmpty;
    final hasAny   = hasWa || hasOther || hasEmail;

    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _dismiss,
          child: const SizedBox.expand(),
        ),
      ),
      CompositedTransformFollower(
        link: widget.link,
        targetAnchor: Alignment.bottomRight,
        followerAnchor: Alignment.topRight,
        offset: const Offset(0, 6),
        showWhenUnlinked: false,
        child: ScaleTransition(
          scale: _scale,
          alignment: Alignment.topRight,
          child: FadeTransition(
            opacity: _ctrl,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 272,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!hasAny)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text('No contact details',
                            style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                      ),
                    if (hasWa) ...[
                      _sectionLabel('WhatsApp'),
                      ...widget.waNumbers.map((n) => _row(
                        Icons.chat_bubble_outline, const Color(0xFF128C7E), n,
                        () => widget.onWaNumber(n),
                      )),
                    ],
                    if (hasOther) ...[
                      if (hasWa) const SizedBox(height: 6),
                      _sectionLabel('Other Contact'),
                      ...widget.otherNumbers.map((n) => _row(
                        Icons.phone_outlined, const Color(0xFF1B7A43), n,
                        () => widget.onWaNumber(n),
                      )),
                    ],
                    if (hasEmail) ...[
                      if (hasWa || hasOther) const SizedBox(height: 6),
                      _sectionLabel('Email'),
                      ...widget.emails.map((e) => _row(
                        Icons.mail_outline, const Color(0xFF1E40AF), e,
                        () => widget.onEmail(e),
                      )),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _dismiss,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFDCFCE7),
                          foregroundColor: const Color(0xFF15803D),
                          minimumSize: const Size(0, 40),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          elevation: 0,
                          shadowColor: Colors.transparent,
                        ),
                        child: const Text('Cancel',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _sectionLabel(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 2),
    child: Text(label,
        style: const TextStyle(
            fontSize: 10, fontWeight: FontWeight.w700,
            color: Color(0xFF6B7280), letterSpacing: 0.5)),
  );

  Widget _row(IconData icon, Color color, String label, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w500,
                      color: Color(0xFF111827))),
            ),
          ]),
        ),
      );
}

// ── Contact-picker anchored popover (Send button on Inquiry + Orders cards) ───

class _ContactPickerPopover extends StatefulWidget {
  final Rect btnRect;
  final String supplierName;
  final String message;
  final Map<String, dynamic> contactData;
  final VoidCallback onDismiss;

  const _ContactPickerPopover({
    required this.btnRect,
    required this.supplierName,
    required this.message,
    required this.contactData,
    required this.onDismiss,
  });

  @override
  State<_ContactPickerPopover> createState() => _ContactPickerPopoverState();
}

class _ContactPickerPopoverState extends State<_ContactPickerPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _fade;
  late String? _lastUsed;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _lastUsed = widget.contactData['last_used'] as String?;
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _fade = _ctrl;
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    await _ctrl.animateTo(0, duration: const Duration(milliseconds: 180), curve: Curves.easeIn);
    widget.onDismiss();
  }

  String _normalizeForWa(String raw) {
    final d = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (d.length == 12 && d.startsWith('91')) return d;
    if (d.length >= 10) return '91${d.substring(d.length - 10)}';
    return d;
  }

  Future<void> _onTap(String value, {bool isEmail = false}) async {
    if (_dismissing) return;
    _dismissing = true;
    if (isEmail) {
      html.window.open('mailto:$value', '_blank');
    } else {
      final intl = _normalizeForWa(value);
      final msg = Uri.encodeComponent(widget.message);
      html.window.open('https://wa.me/$intl?text=$msg', '_blank');
    }
    await _ctrl.animateTo(0, duration: const Duration(milliseconds: 180), curve: Curves.easeIn);
    widget.onDismiss();
    try {
      await Supabase.instance.client.rpc(
        'set_supplier_last_send_contact',
        params: {'p_supplier_name': widget.supplierName, 'p_value': value},
      );
      RenderLog.write('send_contact_picked_recorded', value);
    } catch (_) {}
  }

  Widget _row(String value, {bool isEmail = false}) {
    final isLast = _lastUsed != null && _lastUsed == value;
    if (isLast) RenderLog.write('send_contact_last_used_badge', 'true');
    return InkWell(
      onTap: () => _onTap(value, isEmail: isEmail),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        child: Row(children: [
          Icon(isEmail ? Icons.email_outlined : Icons.phone_outlined,
            size: 16, color: const Color(0xFF6B7280)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(value,
              style: const TextStyle(fontSize: 14, color: Color(0xFF111827)),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (isLast) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFD1FAE5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text('Last used',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF065F46))),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _section(String label, List<String> values, {bool isEmail = false}) {
    if (values.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(label,
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: Color(0xFF9CA3AF), letterSpacing: 0.6)),
      ),
      ...values.map((v) => _row(v, isEmail: isEmail)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('send_contact_minipopup_style', 'true');
    final wa = List<String>.from(widget.contactData['whatsapp'] as List? ?? []);
    final ct = List<String>.from(widget.contactData['contact']  as List? ?? []);
    final ph = List<String>.from(widget.contactData['phone']    as List? ?? []);
    final ot = List<String>.from(widget.contactData['other']    as List? ?? []);
    final em = widget.contactData['email'] as String?;
    final hasAny = wa.isNotEmpty || ct.isNotEmpty || ph.isNotEmpty || ot.isNotEmpty || em != null;

    final mq = MediaQuery.of(context);
    final screen = mq.size;
    const popW = 300.0;
    const popMaxH = 420.0;
    const gap = 8.0;
    const margin = 12.0;

    // Account for safe-area and keyboard so we never overlap OS chrome
    final safeTop    = mq.padding.top + margin;
    final safeBottom = screen.height - mq.padding.bottom - mq.viewInsets.bottom - margin;

    // Horizontal: align popover right edge to button right, clamp to screen
    double left = widget.btnRect.right - popW;
    if (left < margin) left = margin;
    if (left + popW > screen.width - margin) left = screen.width - popW - margin;

    // Vertical: prefer opening BELOW; flip ABOVE if below doesn't fit; clamp if neither fully fits
    final spaceBelow = safeBottom - (widget.btnRect.bottom + gap);
    final spaceAbove = widget.btnRect.top - gap - safeTop;

    double top;
    double effectiveMaxH;
    Alignment scaleOrigin;
    bool flippedUp;

    if (spaceBelow >= popMaxH) {
      // Plenty of room below — open downward
      top          = widget.btnRect.bottom + gap;
      effectiveMaxH = popMaxH;
      scaleOrigin  = Alignment.topRight;
      flippedUp    = false;
    } else if (spaceAbove > spaceBelow) {
      // More room above — flip upward
      effectiveMaxH = spaceAbove.clamp(80.0, popMaxH);
      top          = (widget.btnRect.top - gap - effectiveMaxH).clamp(safeTop, safeBottom - effectiveMaxH);
      scaleOrigin  = Alignment.bottomRight;
      flippedUp    = true;
    } else {
      // Open downward but clamp height to available space
      effectiveMaxH = spaceBelow.clamp(80.0, popMaxH);
      top          = widget.btnRect.bottom + gap;
      scaleOrigin  = Alignment.topRight;
      flippedUp    = false;
    }

    if (flippedUp) RenderLog.write('send_popover_flipped_up', 'true');
    RenderLog.write('send_popover_onscreen', 'true');

    return Stack(children: [
      // Transparent tap-outside barrier (no dim)
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _dismiss,
          child: const SizedBox.expand(),
        ),
      ),
      // Anchored popover card
      Positioned(
        left: left,
        top: top,
        width: popW,
        child: ScaleTransition(
          scale: _scale,
          alignment: scaleOrigin,
          child: FadeTransition(
            opacity: _fade,
            child: Material(
              color: Colors.transparent,
              elevation: 0,
              child: Container(
                constraints: BoxConstraints(maxHeight: effectiveMaxH),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.12),
                      blurRadius: 20,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Title row
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                    child: Row(children: [
                      Expanded(
                        child: Text('Send to ${widget.supplierName}',
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
                        onPressed: _dismiss,
                        visualDensity: VisualDensity.compact,
                      ),
                    ]),
                  ),
                  const Divider(height: 1, color: Color(0xFFE5E7EB)),
                  if (!hasAny)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('No contact numbers on file',
                        style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                    )
                  else
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _section('WHATSAPP NUMBER', wa),
                          _section('CONTACT NO', ct),
                          _section('PHONE', ph),
                          _section('OTHER', ot),
                          if (em != null) _section('EMAIL', [em], isEmail: true),
                          const SizedBox(height: 12),
                        ]),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

// ── Move-picker popover ───────────────────────────────────────────────────────

class _MovePicker extends StatelessWidget {
  final LayerLink link;
  final List<Map<String, dynamic>> options;
  final String productName;
  final VoidCallback onDismiss;
  final Future<void> Function(String supplierName) onSelect;
  final Future<void> Function() onClear;

  const _MovePicker({
    required this.link,
    required this.options,
    required this.productName,
    required this.onDismiss,
    required this.onSelect,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          onTap: onDismiss,
          behavior: HitTestBehavior.translucent,
          child: const SizedBox.expand(),
        ),
      ),
      CompositedTransformFollower(
        link: link,
        showWhenUnlinked: false,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: const Offset(0, 4),
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 280,
            constraints: const BoxConstraints(maxHeight: 360),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E7EB)),
              boxShadow: const [
                BoxShadow(color: Color(0x1A000000), blurRadius: 16, offset: Offset(0, 4)),
              ],
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
                child: Row(children: [
                  Expanded(child: Text(
                    'Move · $productName',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                  )),
                  GestureDetector(
                    onTap: onDismiss,
                    child: const Icon(Icons.close, size: 18, color: Color(0xFF9CA3AF)),
                  ),
                ]),
              ),
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(children: [
                    ...options.map((opt) {
                      final name = opt['supplier_name'] as String? ?? '';
                      final spn = opt['spn'];
                      final avail = opt['is_available'] == true;
                      final isCurrent = opt['is_current'] == true;
                      return _MovePickerRow(
                        name: name,
                        spn: spn?.toString() ?? '',
                        available: avail,
                        isCurrent: isCurrent,
                        onTap: () => onSelect(name),
                      );
                    }),
                    const Divider(height: 1, color: Color(0xFFE5E7EB)),
                    InkWell(
                      onTap: () => onClear(),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        child: Row(children: [
                          Icon(Icons.cancel_outlined, size: 14, color: Color(0xFF6B7280)),
                          SizedBox(width: 8),
                          Text('Clear pin (auto-assign)',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
                        ]),
                      ),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _MovePickerRow extends StatelessWidget {
  final String name;
  final String spn;
  final bool available;
  final bool isCurrent;
  final VoidCallback onTap;
  const _MovePickerRow({required this.name, required this.spn, required this.available, required this.isCurrent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          if (isCurrent)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.check_circle_rounded, size: 14, color: Color(0xFF1B7A43)),
            ),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: TextStyle(
              fontSize: 13,
              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w600,
              color: const Color(0xFF111827),
            )),
            if (spn.isNotEmpty)
              Text('SPN: $spn', style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: available ? const Color(0xFFE1F5EE) : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              available ? 'Available' : 'Out / N/A',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: available ? const Color(0xFF0F6E56) : const Color(0xFF9CA3AF),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// CHANGE #328 — admin bill + payment panel widgets
// ══════════════════════════════════════════════════════════════════════════════

String _c328Rupee(num? v) {
  if (v == null) return '₹—';
  final d = v.toDouble();
  return d == d.truncateToDouble() ? '₹${v.toInt()}' : '₹${d.toStringAsFixed(2)}';
}

class _C328StatCard extends StatelessWidget {
  final String label;
  final String headline;
  final String sub;
  final double fill;
  final Color barColor;

  const _C328StatCard({
    required this.label,
    required this.headline,
    required this.sub,
    required this.fill,
    required this.barColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
        const SizedBox(height: 4),
        Text(headline, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
        ],
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fill,
            minHeight: 10,
            backgroundColor: const Color(0xFFF3F4F6),
            color: barColor,
          ),
        ),
      ]),
    );
  }
}

// ── Admin View Bill chip panel ────────────────────────────────────────────────

class _AdminBillPanelBody extends StatefulWidget {
  final Map<String, dynamic> data;
  final _OrderRow row;
  final VoidCallback onReload;

  const _AdminBillPanelBody({
    required this.data,
    required this.row,
    required this.onReload,
  });

  @override
  State<_AdminBillPanelBody> createState() => _AdminBillPanelBodyState();
}

class _AdminBillPanelBodyState extends State<_AdminBillPanelBody> {
  int _selectedChip = 0; // 0 = Bill Info, 1+ = bill_no

  @override
  Widget build(BuildContext context) {
    final data          = widget.data;
    final billsTotal    = safeParseInt(data['bills_total']);
    final billsImported = safeParseInt(data['bills_imported']);
    final billsLeft     = safeParseInt(data['bills_left']);
    final mrpTotal      = safeParseDouble(data['mrp_total']);
    final totalPaid     = safeParseDouble(data['total_paid']);
    final advRequired   = safeParseDouble(data['advance_required']);
    final advPaid       = safeParseDouble(data['advance_paid']);
    final supplierName  = (data['supplier_name'] as String?) ?? widget.row.supplierName ?? '?';
    final bills         = (data['bills'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    RenderLog.write('c328_admin_billtabs', 'bills=$billsTotal;imported=$billsImported');

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Chip row
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _BillChip(
            label: 'Bill Info',
            selected: _selectedChip == 0,
            chipColor: null,
            onTap: () => setState(() => _selectedChip = 0),
          ),
          ...bills.map((bill) {
            final billNo   = safeParseInt(bill['bill_no']);
            final imported = parseBoolField(bill['imported']);
            return _BillChip(
              label: 'Bill $billNo',
              selected: _selectedChip == billNo,
              chipColor: imported ? const Color(0xFF1B7A43) : const Color(0xFFDC2626),
              onTap: () => setState(() => _selectedChip = billNo),
            );
          }),
        ]),
      ),

      const SizedBox(height: 12),

      if (_selectedChip == 0)
        _buildBillInfoTab(
          billsTotal: billsTotal, billsImported: billsImported, billsLeft: billsLeft,
          mrpTotal: mrpTotal, totalPaid: totalPaid,
          advRequired: advRequired, advPaid: advPaid,
          supplierName: supplierName,
        )
      else
        Builder(builder: (_) {
          final bill = bills.firstWhere(
            (b) => (b['bill_no'] as num?)?.toInt() == _selectedChip,
            orElse: () => <String, dynamic>{},
          );
          if (bill.isEmpty) return const Text('Bill not found.', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)));
          return _BillTab(bill: bill, onImported: widget.onReload);
        }),
    ]);
  }

  Widget _buildBillInfoTab({
    required int billsTotal, required int billsImported, required int billsLeft,
    required double mrpTotal, required double totalPaid,
    required double advRequired, required double advPaid,
    required String supplierName,
  }) {
    RenderLog.write('c328_bill_info', 'bills=$billsTotal;paid=$totalPaid');
    final pct = mrpTotal > 0 ? ((totalPaid / mrpTotal) * 100).round() : 0;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (billsTotal == 0)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text('No bills received from $supplierName yet.',
              style: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
        ),
      _C328StatCard(
        label: 'Bills imported',
        headline: '$billsImported / $billsTotal',
        sub: 'Left: $billsLeft',
        fill: billsTotal > 0 ? (billsImported / billsTotal).clamp(0.0, 1.0) : 0.0,
        barColor: billsLeft == 0 && billsTotal > 0 ? const Color(0xFF1B7A43) : const Color(0xFFD97706),
      ),
      _C328StatCard(
        label: 'Total ordered vs paid',
        headline: '${_c328Rupee(totalPaid)} / ${_c328Rupee(mrpTotal)}',
        sub: mrpTotal > 0 ? '$pct% paid' : '—',
        fill: mrpTotal > 0 ? (totalPaid / mrpTotal).clamp(0.0, 1.0) : 0.0,
        barColor: const Color(0xFF1B7A43),
      ),
      _C328StatCard(
        label: 'Advance (30% of MRP)',
        headline: '${_c328Rupee(advPaid)} / ${_c328Rupee(advRequired)}',
        sub: '',
        fill: advRequired > 0 ? (advPaid / advRequired).clamp(0.0, 1.0) : 0.0,
        barColor: advPaid >= advRequired && advRequired > 0 ? const Color(0xFF1B7A43) : const Color(0xFFD97706),
      ),
    ]);
  }
}

// ── Bill chip ─────────────────────────────────────────────────────────────────

class _BillChip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? chipColor;
  final VoidCallback onTap;

  const _BillChip({required this.label, required this.selected, required this.chipColor, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final Border border;

    if (chipColor == null) {
      bg = selected ? const Color(0xFF1B7A43) : const Color(0xFFF3F4F6);
      fg = selected ? Colors.white : const Color(0xFF374151);
      border = Border.all(color: selected ? const Color(0xFF1B7A43) : const Color(0xFFE5E7EB));
    } else {
      final isGreen = chipColor == const Color(0xFF1B7A43);
      bg = selected
          ? chipColor!
          : (isGreen ? const Color(0xFFD1FAE5) : const Color(0xFFFEE2E2));
      fg = selected
          ? Colors.white
          : (isGreen ? const Color(0xFF065F46) : const Color(0xFF991B1B));
      border = Border.all(
        color: isGreen
            ? const Color(0xFF1B7A43).withValues(alpha: 0.5)
            : const Color(0xFFDC2626).withValues(alpha: 0.5),
      );
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 6, bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20), border: border),
        child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
      ),
    );
  }
}

// ── Bill N tab body ───────────────────────────────────────────────────────────

class _BillTab extends StatefulWidget {
  final Map<String, dynamic> bill;
  final VoidCallback onImported;

  const _BillTab({required this.bill, required this.onImported});

  @override
  State<_BillTab> createState() => _BillTabState();
}

class _BillTabState extends State<_BillTab> {
  String? _signedUrl;
  bool _urlLoading = true;
  String? _urlError;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _loadUrl();
  }

  @override
  void didUpdateWidget(_BillTab old) {
    super.didUpdateWidget(old);
    if (old.bill['id'] != widget.bill['id']) {
      setState(() { _signedUrl = null; _urlLoading = true; _urlError = null; });
      _loadUrl();
    }
  }

  Future<void> _loadUrl() async {
    final bucket   = widget.bill['bucket'] as String? ?? 'supplier-bills';
    final filePath = widget.bill['file_path'] as String? ?? '';
    RenderLog.write('c329_bucket_ok', bucket);
    try {
      final url = await Supabase.instance.client.storage
          .from(bucket).createSignedUrl(filePath, 3600);
      if (mounted) setState(() { _signedUrl = url; _urlLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _urlError = e.toString(); _urlLoading = false; });
    }
  }

  Future<void> _importBill() async {
    RenderLog.write('c328_bill_import',
        'bill_id=${widget.bill['id']};bill_no=${widget.bill['bill_no']}');
    final bucket   = widget.bill['bucket'] as String? ?? 'supplier-bills';
    final filePath = widget.bill['file_path'] as String? ?? '';
    final fileName = widget.bill['file_name'] as String? ?? 'bill';
    final id       = widget.bill['id'] as String? ?? '';
    if (!mounted) return;
    setState(() => _importing = true);
    try {
      final bytes = await Supabase.instance.client.storage.from(bucket).download(filePath);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AdminAddMedicineScreen(
          preloadedBytes: bytes,
          preloadedFileName: fileName,
          onImportComplete: () async {
            try {
              await Supabase.instance.client.from('pending_bills').update({
                'status': 'imported',
                'imported_at': DateTime.now().toIso8601String(),
              }).eq('id', id);
            } catch (_) {}
          },
        ),
      ));
      if (!mounted) return;
      RenderLog.write('c329_import_return', 'ok');
      widget.onImported();
    } catch (e) {
      if (!mounted) return;
      showToast(context, 'Download failed: ${e.toString().replaceFirst('Exception: ', '')}', isError: true);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final imported    = parseBoolField(widget.bill['imported']);
    final billNo      = safeParseInt(widget.bill['bill_no']);
    final source      = widget.bill['source'] as String? ?? '';
    final fileName    = widget.bill['file_name'] as String? ?? '';
    final ext         = fileName.toLowerCase().split('.').last;
    final isPdf       = ext == 'pdf';
    final receivedRaw = widget.bill['received_at'] as String?;
    final receivedAt  = receivedRaw != null ? DateTime.tryParse(receivedRaw)?.toLocal() : null;
    final receivedStr = receivedAt != null ? _fmtD(receivedAt) : '—';

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // (1) Import button
      if (!imported)
        FilledButton(
          onPressed: _importing ? null : _importBill,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFD97706),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            minimumSize: const Size(double.infinity, 40),
          ),
          child: _importing
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Import bill', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        )
      else
        FilledButton(
          onPressed: null,
          style: FilledButton.styleFrom(
            disabledBackgroundColor: const Color(0xFFD1FAE5),
            disabledForegroundColor: const Color(0xFF065F46),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            minimumSize: const Size(double.infinity, 40),
          ),
          child: const Text('Imported ✓', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),

      const SizedBox(height: 10),

      // (2) Bill content
      if (_urlLoading)
        const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(color: Color(0xFF1B7A43))))
      else if (_urlError != null)
        GestureDetector(
          onTap: () { setState(() { _urlLoading = true; _urlError = null; }); _loadUrl(); },
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(8)),
            child: const Text('Failed to load. Tap to retry.', textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Color(0xFF92400E))),
          ),
        )
      else if (isPdf)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFB),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(children: [
            const Icon(Icons.picture_as_pdf_outlined, size: 40, color: Color(0xFF9CA3AF)),
            const SizedBox(height: 8),
            Text(fileName, style: const TextStyle(fontSize: 13, color: Color(0xFF374151)), textAlign: TextAlign.center),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                final uri = Uri.parse(_signedUrl!);
                if (await canLaunchUrl(uri)) launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              icon: const Icon(Icons.open_in_new, size: 14),
              label: const Text('Open PDF ↗'),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF1B7A43)),
                foregroundColor: const Color(0xFF1B7A43),
              ),
            ),
          ]),
        )
      else
        GestureDetector(
          onTap: () => openFullscreenImage(context, _signedUrl!),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              _signedUrl!,
              width: double.infinity,
              fit: BoxFit.contain,
              loadingBuilder: (_, child, progress) => progress == null
                  ? child
                  : const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator(color: Color(0xFF1B7A43)))),
              errorBuilder: (_, __, ___) => Container(
                width: double.infinity, padding: const EdgeInsets.all(16), color: const Color(0xFFF3F4F6),
                child: const Text('Image failed to load.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
              ),
            ),
          ),
        ),

      const SizedBox(height: 8),

      // (4) Meta line
      Text('Bill $billNo · $source · $receivedStr', style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
    ]);
  }

  String _fmtD(DateTime dt) {
    final dd = dt.day.toString().padLeft(2,'0');
    final mm = dt.month.toString().padLeft(2,'0');
    final yy = (dt.year % 100).toString().padLeft(2,'0');
    var h = dt.hour % 12; if (h == 0) h = 12;
    final min = dt.minute.toString().padLeft(2,'0');
    final ap = dt.hour >= 12 ? 'PM' : 'AM';
    return '$dd/$mm/$yy $h:$min $ap';
  }
}

// ── Admin View Payment panel body ─────────────────────────────────────────────

class _AdminPayPanelBody extends StatefulWidget {
  final Map<String, dynamic> data;
  final String orderId;
  final VoidCallback onReload;

  const _AdminPayPanelBody({required this.data, required this.orderId, required this.onReload});

  @override
  State<_AdminPayPanelBody> createState() => _AdminPayPanelBodyState();
}

class _AdminPayPanelBodyState extends State<_AdminPayPanelBody> {
  @override
  Widget build(BuildContext context) {
    final data      = widget.data;
    final mrpTotal  = safeParseDouble(data['mrp_total']);
    final totalPaid = safeParseDouble(data['total_paid']);
    final advReq    = safeParseDouble(data['advance_required']);
    final advPaid   = safeParseDouble(data['advance_paid']);
    final payments  = (data['payments'] as List<dynamic>? ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final pct       = mrpTotal > 0 ? ((totalPaid / mrpTotal) * 100).round() : 0;
    final remaining = (mrpTotal - totalPaid).clamp(0.0, double.infinity);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _C328StatCard(
        label: 'Total ordered',
        headline: '${_c328Rupee(totalPaid)} / ${_c328Rupee(mrpTotal)}',
        sub: mrpTotal > 0 ? '$pct% paid' : '—',
        fill: mrpTotal > 0 ? (totalPaid / mrpTotal).clamp(0.0, 1.0) : 0.0,
        barColor: const Color(0xFF1B7A43),
      ),
      _C328StatCard(
        label: 'Advance payment (30%)',
        headline: '${_c328Rupee(advPaid)} / ${_c328Rupee(advReq)}',
        sub: '',
        fill: advReq > 0 ? (advPaid / advReq).clamp(0.0, 1.0) : 0.0,
        barColor: advPaid >= advReq && advReq > 0 ? const Color(0xFF1B7A43) : const Color(0xFFD97706),
      ),
      _C328StatCard(
        label: 'Remaining balance',
        headline: '${_c328Rupee(remaining)} left',
        sub: 'of ${_c328Rupee(mrpTotal)} total',
        fill: mrpTotal > 0 ? (remaining / mrpTotal).clamp(0.0, 1.0) : 0.0,
        barColor: const Color(0xFF1B7A43),
      ),
      OutlinedButton.icon(
        onPressed: () => _showAddPaymentDialog(),
        icon: const Icon(Icons.add, size: 16),
        label: const Text('+ Add Payment', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Color(0xFF1B7A43)),
          foregroundColor: const Color(0xFF1B7A43),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          minimumSize: const Size(double.infinity, 40),
        ),
      ),
      const SizedBox(height: 12),
      const Text('Payments', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
      const SizedBox(height: 6),
      if (payments.isEmpty)
        const Text('No payments recorded yet.', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
      else
        ...payments.map((p) => _C328PayRow(payment: p)),
    ]);
  }

  Future<void> _showAddPaymentDialog() async {
    final amountCtrl = TextEditingController();
    final noteCtrl   = TextEditingController();
    String mode = 'cash';
    String? amountError;
    bool saving = false;
    String? saveError;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Add Payment', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              controller: amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: 'Amount (₹)',
                errorText: amountError,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              onChanged: (_) { if (amountError != null) setDlg(() => amountError = null); },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: mode,
              decoration: const InputDecoration(
                labelText: 'Mode',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
              items: const [
                DropdownMenuItem(value: 'cash',   child: Text('Cash')),
                DropdownMenuItem(value: 'online', child: Text('Online')),
              ],
              onChanged: (v) { if (v != null) setDlg(() => mode = v); },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(
                labelText: 'Note (optional)',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
            if (saveError != null) ...[
              const SizedBox(height: 8),
              Text(saveError!, style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
            ],
          ]),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving ? null : () async {
                final raw = amountCtrl.text.trim();
                final amount = double.tryParse(raw);
                if (amount == null || amount <= 0) {
                  setDlg(() => amountError = 'Enter a valid amount');
                  return;
                }
                setDlg(() { saving = true; saveError = null; });
                RenderLog.write('c328_admin_addpay', 'order=${widget.orderId};amount=$amount');
                try {
                  await Supabase.instance.client.rpc('sup_add_payment', params: {
                    'p_supplier_order_id': widget.orderId,
                    'p_amount': amount,
                    'p_mode': mode,
                    'p_note': noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
                  });
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  if (mounted) {
                    showToast(context, 'Payment recorded ✓');
                    widget.onReload();
                  }
                } catch (e) {
                  setDlg(() {
                    saving = false;
                    saveError = e.toString().replaceFirst('Exception: ', '');
                  });
                }
              },
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
              child: saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _C328PayRow extends StatelessWidget {
  final Map<String, dynamic> payment;
  const _C328PayRow({required this.payment});

  @override
  Widget build(BuildContext context) {
    final amount = (payment['amount'] as num?)?.toDouble() ?? 0;
    final mode   = payment['mode'] as String? ?? '';
    final note   = payment['note'] as String?;
    final atRaw  = payment['at'] as String?;
    final at     = atRaw != null ? DateTime.tryParse(atRaw)?.toLocal() : null;
    final atStr  = at != null ? _fmtP(at) : '—';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${_c328Rupee(amount)} · $mode · $atStr',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF111827))),
        if (note != null && note.isNotEmpty)
          Text(note, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      ]),
    );
  }

  String _fmtP(DateTime dt) {
    final dd = dt.day.toString().padLeft(2,'0');
    final mm = dt.month.toString().padLeft(2,'0');
    final yy = (dt.year % 100).toString().padLeft(2,'0');
    var h = dt.hour % 12; if (h == 0) h = 12;
    final min = dt.minute.toString().padLeft(2,'0');
    final ap = dt.hour >= 12 ? 'PM' : 'AM';
    return '$dd/$mm/$yy $h:$min $ap';
  }
}
