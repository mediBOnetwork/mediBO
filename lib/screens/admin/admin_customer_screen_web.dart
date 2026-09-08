import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart'; // CHANGE #464
import 'package:flutter/material.dart';
import '../../widgets/substitute_choice.dart'; // #366 row 176
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/live_feed.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:pharma_b2b/services/ui_copy.dart';

import '../../widgets/geo_position.dart' as geo;
import '../../utils/file_pick_io.dart' as filepick;

import '../../utils/download_bytes.dart'; // CHANGE #463
import '../../utils/render_log.dart';
import 'customer_pipeline_screen.dart';
import '../../user_state.dart'; // CMD #633 — the session gate below
import '../../design_tokens.dart'; // CHANGE #238 — Ds tokens for the new panel chrome
import 'sleads_filter_bar.dart'; // CMD #1868 — the S Leads filter row
import 'route_stop_checkin_sheet.dart'; // CMD #1873 — the route stop check-in sheet
import 'sleads_bulk.dart'; // CMD #1869 — the bulk lane's pure decisions
import 'scrape_run.dart'; // CMD #1870 — the scrape run's pure decisions
import 'route_notify.dart'; // CMD #1876 — assign/message-stops payload readers
import '../../services/sleads_filter_service.dart'; // CMD #1868
import '../../models/order_item_panel_view.dart'; // CHANGE #238
import '../../fulfill/fulfill_lookups.dart'; // C639: backend-owned entry label
import 'demand_preview_sheet.dart'; // C639 PART D
import '../../services/access.dart';
import '../../widgets/access_readonly_chip.dart';
import '../../services/admin_date_scope.dart'; // CHANGE #545
import '../../services/admin_zone_scope.dart'; // CHANGE #609
import '../../services/date_labels.dart'; // CHANGE #548
import '../../services/map_config.dart'; // C634: map deep links from config
import '../../widgets/route_google_map_panel.dart'; // CHANGE #463
import '../bulk_upload_screen.dart';
import '../../services/payment_claims_service.dart';
import '../../view_as_state.dart';
import '../../widgets/backend_chip.dart'; // CHANGE #606
import '../../widgets/backend_table.dart'; // CHANGE #607
import '../../widgets/bill_actions_row.dart'; // CHANGE #465
import '../../widgets/bill_viewer.dart'; // CHANGE #465
import '../../widgets/import_customer_sheet.dart'; // CHANGE #547
import '../../widgets/native_signed_image.dart'; // CHANGE #550
import '../../widgets/cash_payment_sheet.dart';
import '../../widgets/fullscreen_image.dart';
import '../../utils/bill_mime.dart'; // CHANGE #465
import 'admin_customer_360_screen.dart'; // CHANGE #396
import 'admin_customer_page.dart'; // CHANGE #810
import 'leads_paging.dart'; // CHANGE #1867 — PagedList / SLeadRow
import '../../widgets/customer_console_row.dart'; // CHANGE #810
import '../../widgets/customer_payment_term_sheet.dart'; // CHANGE #1888
import '../../widgets/customer_autofill_strip.dart'; // CHANGE #1888
import '../../url_sync.dart' show initialSearch; // CHANGE #1888
import '../../models/route_cost_chips.dart'; // CMD #1875 — ₹ chip decisions
import '../../models/route_day_summary.dart'; // CMD #1877 — day summary parse

// CHANGE #242: payment-image sharing now goes through the platform-conditional
// download_bytes wrapper (Web Share API on web / share_plus on Android), so no
// dart:js_interop declarations live here anymore.

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

  /// CHANGE #599 — the backend's badge for this line: label + three colours.
  /// It was `if (addedBy == 'admin')` with every string and colour in Dart.
  final Map<String, dynamic> addedByBadge;
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
    this.addedByBadge = const {},
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

  /// CHANGE #606 — the render-ready row from admin_customer_orders, verbatim.
  ///
  /// Customer Orders rows carry this; Cart rows (which have no order and come
  /// from a different RPC) leave it empty. Everything the Orders tab paints —
  /// title, chips, amount, item count, times — is read straight out of here.
  /// Nothing in this file re-derives any of it.
  final Map<String, dynamic> render;

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
    this.render = const {},
  });

  bool get isOrder    => source == 'website' || source == 'whatsapp';
  bool get isCartOnly => source == 'cart_only';

  /// A backend string, verbatim. Empty means "the backend withheld it" — the
  /// caller must not render, never substitute a Dart default.
  String rs(String k) => (render[k] as String?) ?? '';
  bool   rb(String k) => render[k] == true;
  Map<String, dynamic>? rchip(String k) => backendChipOf(render, k);
  /// CHANGE #607 — any nested backend object (actions{}, …), verbatim.
  Map<String, dynamic>? rmap(String k) =>
      render[k] is Map ? (render[k] as Map).cast<String, dynamic>() : null;
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
  // CMD #1886 — the registration funnel: the people who signed in and stopped,
  // the rows somebody owes a call, and the rows that cannot be approved yet.
  signedUp,
  followUps,
  needsAttention,
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

  /// CHANGE #537 — the Fulfill pipeline mounts this SAME screen as its stage-1
  /// tab ("Customer order"). Two things had to be optional for that to be
  /// navigation rather than a rewrite:
  ///
  ///  * [initialFilter] — which of this screen's own sub-tabs it opens on. Null
  ///    keeps the historical default (Customers).
  ///  * [embedded] — when true the screen does not draw its OWN tab row,
  ///    because the Fulfill pipeline bar is already the tab row above it. A
  ///    tab bar inside a tab bar is the thing this change exists to remove.
  ///
  /// Nothing else differs. The embedded instance loads, refetches, renders and
  /// acts exactly as the standalone one does.
  ///
  /// The shell's instance still takes the static [_screenKey], so
  /// [triggerFocus] keeps reaching it and only it; an embedded instance is
  /// given its own key by its host, which is what lets both exist at once.
  final String? initialFilter;
  final bool embedded;

  AdminCustomerScreen({Key? key, this.initialFilter, this.embedded = false})
      : super(key: key ?? _screenKey);

  /// Called by the shell when this screen becomes the active page.
  static void triggerFocus() =>
      _screenKey.currentState?._onScreenFocus();

  /// Called by the Supplier Shop tab's map dropdown "Optimize route" badge —
  /// same action the Route sub-tab's own optimize-all button triggers, not a
  /// reimplementation. Returns false (no-op) if the Route sub-tab isn't
  /// currently built (it's only mounted while that sub-tab is active) or its
  /// plan isn't loaded yet — same early-return the button itself is subject to.
  static bool triggerOptimizeAllRoutes() => _RoutesTab.triggerOptimizeAllRoutes();

  /// CHANGE #1867 — open one of this screen's own sub-tabs on the shell's
  /// instance, by the SAME key the tab row uses (`sLeads`, `routes`, …).
  /// Null, empty or unknown is ignored rather than thrown on, matching how
  /// [initialFilter] treats a stage this build has never heard of.
  ///
  /// It retries for a few frames because the caller is the shell reading the
  /// URL in initState, before this screen's state exists — the deep link must
  /// survive a cold start, which is the only kind that matters for a link.
  /// CMD #1876 — the whole of `/admin/customers?…`, decided in ONE place.
  ///
  /// The shell hands over its query string and nothing else: which of the two
  /// link shapes this is (a sub-tab, or the single route the assignment
  /// WhatsApp points at) is [RouteDeepLink]'s judgement, not the shell's, so
  /// the shell keeps its one job — boot and routing.
  static void openFromLink(String search) {
    final link = RouteDeepLink.parse(search);
    if (link.opensRoute) {
      openRoute(link.routeId);
    } else {
      openTab(link.tab);
    }
  }

  /// CMD #1876 — open ONE route from a link (`?tab=routes&route=<uuid>`), the
  /// link the assignment WhatsApp carries. Same retry story as [openTab]: the
  /// shell reads the URL before this screen's state exists.
  static void openRoute(String? routeId) {
    if (routeId == null || routeId.isEmpty) return;
    // Park FIRST: openTab may mount the Routes sub-tab synchronously, and its
    // initState is what collects the parked id.
    _RoutesTab.openRoute(routeId);
    openTab('routes');
  }

  static void openTab(String? filterName, {int tries = 60}) {
    if (filterName == null || filterName.isEmpty) return;
    final st = _screenKey.currentState;
    if (st != null) {
      st._openTabByName(filterName);
      return;
    }
    if (tries <= 0) return;
    // CMD #1876 — a TIMER, not a post-frame chain. #1867's twelve frames elapse
    // in about a fifth of a second, and a cold start is several SECONDS of auth
    // and fetching before this screen's state exists: the link expired before
    // its destination was built, and did so intermittently, which is worse than
    // never. 60 × 250 ms covers a slow boot and still gives up.
    Timer(const Duration(milliseconds: 250),
        () => openTab(filterName, tries: tries - 1));
  }

  @override
  State<AdminCustomerScreen> createState() => _AdminCustomerScreenState();
}

class _AdminCustomerScreenState extends State<AdminCustomerScreen> {
  // CHANGE #545 — Customer Orders no longer owns a date. The ONE Dashboard
  // picker sets it server-side; this listener just refetches when it moves
  // (fired by AdminDateScope's realtime subscription or an explicit select).
  void _onDateScopeChanged() {
    if (!mounted) return;
    _load(showSpinner: false);
  }

  /// CHANGE #609 — the zone moved. Same shape as the date listener: refetch and
  /// render the response. The tab never filters the list it already holds,
  /// because the zone rule lives in the RPC, not here.
  void _onZoneScopeChanged() {
    if (!mounted) return;
    _load(showSpinner: false);
  }

  // ── CHANGE #547: Import Customer ─────────────────────────────────────────
  // Anchor for the popup menu. Deliberately a menu AT THE BUTTON, not the
  // centred dialog the Import Supplier popover uses.
  final GlobalKey _importCustomerKey = GlobalKey();
  bool _extracting = false;

  Future<void> _openImportCustomerMenu() async {
    final box =
        _importCustomerKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) return;
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    RenderLog.write('c547_menu_open', 'true');

    final choice = await showMenu<String>(
      context: context,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + box.size.height + 4,
        (overlay.size.width - origin.dx - box.size.width)
            .clamp(0.0, overlay.size.width),
        0,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'manual',
          child: Row(children: [
            const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF6B7280)),
            const SizedBox(width: 10),
            Text(c('admin_customer.import_manually'), style: const TextStyle(fontSize: 14)),
          ]),
        ),
        PopupMenuItem<String>(
          value: 'file',
          child: Row(children: [
            const Icon(Icons.photo_library_outlined, size: 18, color: Color(0xFF6B7280)),
            const SizedBox(width: 10),
            Text(c('admin_customer.import_by_file'), style: const TextStyle(fontSize: 14)),
          ]),
        ),
      ],
    );
    if (!mounted || choice == null) return;

    if (choice == 'manual') {
      final saved = await ImportCustomerSheet.open(context);
      if (saved == true && mounted) _load(showSpinner: false);
    } else {
      await _importCustomerByFile();
    }
  }

  /// Multi-select photos, ALL belonging to ONE customer -> customer-import
  /// 'extract' -> the same registration form, pre-filled and fully editable.
  Future<void> _importCustomerByFile() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;

    // The edge function accepts at most 8 images per customer.
    final files = picked.files.where((f) => f.bytes != null).take(8).toList();
    if (files.isEmpty) return;

    setState(() => _extracting = true);
    try {
      final images = [for (final f in files) base64Encode(f.bytes!)];
      RenderLog.write('c547_extract_send', 'images=${images.length}');

      final res = await Supabase.instance.client.functions.invoke(
        'customer-import',
        body: {
          'mode': 'extract',
          'images': images,
          'mime_type': 'image/jpeg',
        },
      );
      final data = res.data;
      final m =
          data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};
      if (!mounted) return;
      setState(() => _extracting = false);

      if (m['error'] != null) {
        // Backend copy, verbatim.
        showToast(context, m['error'].toString(), isError: true);
        return;
      }

      final saved = await ImportCustomerSheet.open(context, extracted: m);
      if (saved == true && mounted) _load(showSpinner: false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _extracting = false);
      final msg = e is FunctionException
          ? ((e.details is Map && (e.details as Map)['error'] != null)
              ? (e.details as Map)['error'].toString()
              : (e.details?.toString() ?? e.reasonPhrase ?? '$e'))
          : '$e';
      showToast(context, msg, isError: true);
    }
  }

  Widget _buildImportCustomerButton() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 220,
          child: ElevatedButton.icon(
            key: _importCustomerKey,
            onPressed: _extracting ? null : _openImportCustomerMenu,
            icon: _extracting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.upload_file_outlined, size: 18),
            label: Text(c('admin_customer.import_customer')),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              foregroundColor: Colors.white,
              textStyle:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              elevation: 0,
            ),
          ),
        ),
      ),
    );
  }

  List<_CustRow>     _orderRows    = [];
  List<_CustRow>     _cartRows     = [];

  /// CHANGE #606 — the Customer Orders tab's own header, count and empty state,
  /// exactly as admin_customer_orders returned them. The tab pill used to read
  /// `_orderRows.length` and the empty state was the Dart literal '0 orders';
  /// both are backend strings now, so changing either is an app_settings edit,
  /// not a deploy.
  String _ordersSummaryLabel = '';
  int    _ordersCount        = 0;
  Map<String, dynamic> _ordersEmpty = const {};

  /// CHANGE #607 — the Customer Orders desktop table's shape, from the RPC's
  /// columns[]. Header text, alignment, width and column ORDER all live in
  /// app_settings.order_tab_columns now. There is no Dart fallback list: a
  /// second copy would render a stale shape the moment the config changed.
  List<BackendColumn> _ordersColumns = const [];

  /// CHANGE #609 — the scope the backend applied, as it reported it.
  /// `zone_label` reads "Raipur Zone" / "All zones"; both strings are the
  /// backend's. This tab sends no zone argument and does no zone filtering —
  /// these are display only, so the header can state what is on screen.
  String _ordersDateLabel = '';
  String _ordersZoneLabel = '';

  /// CHANGE #601 — footer totals as the server computed them.
  int    _cartFooterLines = 0;
  double _cartFooterValue = 0.0;
  List<_RegRow>      _regRows      = [];
  List<_ApprovedRow> _approvedRows = [];
  List<Map<String, dynamic>> _deletedRows = [];
  bool _deletedExpanded = false;
  List<_LeadItem> _loggedInLeads = [];
  List<_LeadItem> _otherLeads    = [];
  List<_AdminEntry> _admins      = [];
  final Set<String> _expandedLeads = {};
  bool _loading = true;
  /// CMD #1886 — customer_pipeline_home(): the three new tab captions, their
  /// counts and the office team the follow-up sheet may assign to. Every word
  /// of it is the backend's.
  Map<String, dynamic> _pipeHome = const {};
  /// customers_stage_meta(): {customer id -> {chip, approve, missing_label}}.
  /// The stage chip on every Customers row, and the reason the Approve button
  /// is disabled, both come from here.
  Map<String, dynamic> _stageMeta = const {};
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
  // CHANGE #238 — orderId → the render-ready item lines from
  // order_item_status_panel(), and that order's reconciliation block. Both are
  // stored verbatim: nothing in this file re-counts, re-orders or re-words them.
  final Map<String, OrderItemPanelView> _orderPanels = {};
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

  /// CMD #1868 — sleads_count()'s own caption for the S Leads tab, filtered
  /// exactly like the list. Null until the tab has loaded once, at which point
  /// it OUTRANKS the locally composed fallback below.
  String? _sLeadsCountChip;
  // CHANGE #445 — "Routes" tab badge count (zones.length from
  // lead_routes_screen). Kept in sync via _RoutesTab.onZonesChanged; only
  // populated once the tab has been opened (no independent bootstrap fetch,
  // unlike S Leads — zones list is heavier and city-scoped).
  int _routesZones = 0;
  /// CHANGE #1867 — the two chip CAPTIONS, whole, from customers_tab_counts().
  /// Two cheap count(*)s; neither is a list length, so the chip can no longer
  /// disagree with a page of 50. Absent (not yet loaded, or the call failed)
  /// falls back to the old locally-composed caption.
  Map<String, dynamic> _tabCounts = const {};

  final List<LiveFeedHandle> _realtimeChannels = [];
  Timer? _debounce;

  // ── Auto-load guard (prevents concurrent/storm fetches) ──────────────────
  bool _loadInFlight = false;
  DateTime? _lastAutoLoad;
  static const _autoLoadMinInterval = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    // CHANGE #537 — open on the sub-tab the host asked for. An unknown key is
    // ignored rather than thrown on, so the backend can name a stage this
    // build has never heard of without white-screening the pipeline.
    final want = widget.initialFilter;
    if (want != null && want.isNotEmpty) {
      for (final f in _CustFilter.values) {
        if (f.name == want) { _filter = f; break; }
      }
    }
    // CHANGE #545 — follow the central admin date.
    AdminDateScope.instance.addListener(_onDateScopeChanged);
    AdminDateScope.instance.ensureLoaded();
    // CHANGE #609 — and the central admin zone. The zone lives server-side, so
    // this tab does not receive it and does not filter by it: it just refetches
    // admin_customer_orders, which applies the saved scope itself.
    AdminZoneScope.instance.addListener(_onZoneScopeChanged);
    AdminZoneScope.instance.ensureLoaded();
    // CHANGE #639 — the copy catalog that owns the Demand preview entry's
    // label. ensureLoaded() is idempotent and shared with the fulfillment tab;
    // the rebuild once it lands is what makes the entry appear.
    FulfillLookups.instance.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
    // CMD #633 — the first fetch moved to didChangeDependencies, where the
    // session is actually readable. See _bootForAdminOnce below.
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

  /// CMD #633 — an admin tab must not fetch admin data for a visitor who is
  /// not an admin.
  ///
  /// HomeShell builds this screen as one of an IndexedStack's children, and an
  /// IndexedStack builds EVERY child, so initState here ran for anonymous
  /// visitors too: admin_customer_screen_data was called on a signed-out boot,
  /// refused, and the catch showed a red error toast on the public storefront —
  /// which is exactly what a shopper saw on medibo.in/<anything-unknown>.
  ///
  /// The gate lives in didChangeDependencies rather than initState because the
  /// session is an inherited dependency: this runs again the moment auth
  /// resolves to an admin, so a real admin still loads on open (and loads once,
  /// not on every rebuild).
  bool _bootedForAdmin = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_bootedForAdmin) return;
    if (!UserState.of(context).isAdmin) {
      RenderLog.write('c633_anon_boot', 'admin_fetch=0');
      return;
    }
    _bootedForAdmin = true;
    // CHANGE #810 — Customer 360 is a route this screen owns, so the customer
    // page is handed the opener rather than importing the route itself.
    AdminCustomerPage.open360 = (ctx, id) => Navigator.of(ctx).push(
        MaterialPageRoute(builder: (_) => AdminCustomer360Screen(customerId: id)));
    _load();
    _loadCusConsole(); // CHANGE #810
    _subscribeRealtime();
    _loadSLeadsTotal();
    _loadTabCounts(); // CHANGE #1867
    _openDeepLinkPanel(); // CHANGE #1888
  }

  /// CHANGE #1888 — /admin/customers?panel=import opens the Import Customer
  /// sheet on a cold start.
  ///
  /// The registration form is where the mandatory GPS pin, the "I don't have
  /// GST" answer and the Cash-on-Delivery default actually live, and until now
  /// the only way in was a tap. A Flutter web app paints to canvas, so a tap is
  /// exactly what no verifier can perform: the sheet was deployed, correct and
  /// unphotographable. A URL the admin session can be driven to makes it
  /// provable — and gives an admin a link to hand somebody.
  ///
  /// Only an admin reaches this (it runs behind the isAdmin gate above), an
  /// unknown panel name is ignored the way [openTab] ignores an unknown tab,
  /// and it fires once because [_bootedForAdmin] has already been set.
  void _openDeepLinkPanel() {
    // initialSearch(), never Uri.base: usePathUrlStrategy() rewrites the
    // browser URL to '/' about a second into boot, and this screen mounts
    // after that — Uri.base was ALWAYS empty here, so the link opened the
    // customer list and nothing else. CHANGE #747 captured the query at the
    // top of main() for exactly this class of deep link; the catalogue and
    // orders screens already read it the same way.
    String? panel;
    try {
      panel = Uri.splitQueryString(
          initialSearch().replaceFirst('?', ''))['panel'];
    } catch (_) {
      // A malformed percent-escape in someone's URL is not worth losing
      // the admin customer screen over.
      return;
    }
    if (panel == null || panel.isEmpty) return;
    RenderLog.write('c1888_panel_link', panel);
    if (panel != 'import') return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final saved = await ImportCustomerSheet.open(context);
      if (saved == true && mounted) _load(showSpinner: false);
    });
  }

  void _onScreenFocus() {
    if (!mounted) return;
    // CHANGE #545 — re-read the central date on focus so a backgrounded tab is
    // never stale; if it moved, the listener fires its own refetch.
    AdminDateScope.instance.refresh();
    _autoLoad(key: _filter.name, force: true);
    RenderLog.write('screen_autoload_on_focus', 'customers');
  }

  /// CHANGE #1867 — one cheap RPC for both tab captions.
  void _loadTabCounts() {
    Supabase.instance.client.rpc('customers_tab_counts').then((res) {
      if (!mounted || res is! Map) return;
      setState(() => _tabCounts = Map<String, dynamic>.from(res));
      RenderLog.write('c1867_tab_counts',
          '${_tabCounts['sleads']?['n']}/${_tabCounts['routes']?['n']}');
    }).catchError((_) {});
  }

  /// The caption for one of the two counted tabs, verbatim from the backend.
  String _countedTabLabel(String key, String fallback) {
    final m = _tabCounts[key];
    final label = m is Map ? m['label']?.toString() : null;
    return (label == null || label.isEmpty) ? fallback : label;
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

  /// CHANGE #1867 — see [AdminCustomerScreen.openTab].
  void _openTabByName(String filterName) {
    for (final f in _CustFilter.values) {
      if (f.name != filterName) continue;
      if (!mounted) return;
      setState(() => _filter = f);
      _autoLoad(key: f.name, force: true);
      return;
    }
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
    AdminDateScope.instance.removeListener(_onDateScopeChanged);
    AdminZoneScope.instance.removeListener(_onZoneScopeChanged); // CHANGE #609
    _debounce?.cancel();
    for (final ch in _realtimeChannels) {
      ch.unsubscribe();
    }
    _realtimeChannels.clear();
    _scrollCtrl.dispose();
    _cusSearchDebounce?.cancel();   // CHANGE #810
    _cusSearchCtl.dispose();
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
    // CHANGE #643: six UNFILTERED bindings, one per table, held open by every
    // admin session — on the two busiest tables in the product. LiveFeed asks
    // realtime_plan() which of these still publish and polls the rest on the
    // registry's interval. The refetch is the same debounced reload.
    LiveFeed.instance
        .watch(
          channelPrefix: 'admin_customer_feeds',
          tables: tables,
          onChange: (_) => _debouncedLoad(),
        )
        .then((h) {
      if (!mounted) {
        h.dispose();
        return;
      }
      _realtimeChannels.add(h);
    });
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
      //
      // CHANGE #545 — ist_day_bounds is a pure date→UTC-range helper, NOT one of
      // the date-scoped read RPCs, so it does not default to admin_active_date():
      // omitting p_date here would pin this tab to the server's today. It gets
      // the central date's own 'YYYY-MM-DD' string, verbatim from the backend —
      // still zero client-side date formatting.
      final scopeYmd = AdminDateScope.instance.dateYmd;
      // CHANGE #593 — ONE RPC replaces six raw table legs.
      //
      // user_profiles, pharmacy_profiles (active AND deleted), day-bounded
      // orders and cart_items each scoped and ordered themselves here. Row
      // shapes are unchanged, so everything downstream parses as before.
      final screenRaw = await client.rpc('admin_customer_screen_data',
          params: {if (scopeYmd != null) 'p_date': scopeYmd});
      final screen = (screenRaw is List ? screenRaw.first : screenRaw) as Map;
      List<dynamic> seg(String k) => (screen[k] as List<dynamic>?) ?? const [];

      final results = await Future.wait<dynamic>([
        client.rpc('get_unregistered_users').catchError((_) => <dynamic>[]),
        // CHANGE #369 — grouped WhatsApp leads for the Customer Orders tab.
        client.rpc('get_leads_grouped_today').catchError((_) => <dynamic>[]),
        // CHANGE #606 — the Customer Orders tab, render-ready.
        //
        // The tab used to build every visible string here: it joined the raw
        // orders segment against user_profiles/pharmacy_profiles to invent a
        // title, formatted ₹ with toStringAsFixed, pluralised "N items" in
        // Dart, mapped status -> label and status -> colour in _ConfirmActions,
        // and printed '0 orders' as a literal. admin_customer_orders returns
        // all of it already decided — title, four chips, amount_label,
        // items_label, time_label, the summary line and the empty state — in
        // the order it wants them drawn.
        client
            .rpc('admin_customer_orders',
                params: {if (scopeYmd != null) 'p_date': scopeYmd})
            .catchError((_) => <String, dynamic>{}),
      ]);

      final upRows       = seg('user_profiles');
      final ppRows       = seg('profiles');
      final orderRows    = seg('orders');
      final cartRows     = seg('cart_items');
      final authRows     = results[0] as List;
      final deletedList  = seg('deleted');
      final leadRowsRaw  = results[1] as List;

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

      // ── CHANGE #606 — Customer Orders rows, rendered from the RPC verbatim ──
      //
      // What used to happen here: a uid-keyed join into upMap/ppMap to invent a
      // customer name, a pharmacy and a phone (_name/_pharmacy/_phone), a
      // client-side order code via orderDisplayId(), a raw status string that
      // _ConfirmActions later mapped to a label AND a colour, and a raw
      // total_amount that two widgets each formatted with toStringAsFixed.
      // Six chances for this screen to disagree with the database about one
      // order. admin_customer_orders decided all of it already.
      final coRaw = results[2];
      final coOne = coRaw is List ? (coRaw.isEmpty ? null : coRaw.first) : coRaw;
      final coMap =
          coOne is Map ? coOne.cast<String, dynamic>() : <String, dynamic>{};

      // Item LINES are not in admin_customer_orders' payload — they feed the
      // expand-a-row detail panel, not the row. They stay keyed off the screen
      // RPC's orders segment by order id. This is a lookup for a detail panel,
      // never a display decision: no string painted on the row comes from here.
      final itemsByOrderId = <String, List<_ItemLine>>{};
      for (final o in orderRows) {
        final mo = Map<String, dynamic>.from(o as Map);
        final id = mo['id'] as String?;
        if (id != null) itemsByOrderId[id] = _parseItems(mo['items']);
      }

      final orders = <_CustRow>[];
      // Order is the backend's (created_at DESC). NOT re-sorted here — two
      // real sort bugs came from a client re-sorting an already-ordered list.
      for (final r in ((coMap['orders'] as List<dynamic>?) ?? const [])) {
        final m = Map<String, dynamic>.from(r as Map);
        final oid = m['order_id'] as String?;
        final srcChip = (m['source_chip'] as Map?)?.cast<String, dynamic>();
        final stChip  = (m['status_chip'] as Map?)?.cast<String, dynamic>();
        orders.add(_CustRow(
          userId:      m['user_id'] as String? ?? '',
          // `title` already resolves the unnamed-pharmacy case backend-side.
          name:        m['title'] as String? ?? '',
          pharmacy:    '',
          phone:       m['phone_label'] as String? ?? '',
          // The backend's own normalised source/status values — used only to
          // route behaviour (which panel, which action), never to pick a
          // label or a colour. Those come from the chips.
          source:      srcChip?['value'] as String? ?? '',
          orderId:     oid,
          orderNumber: m['code_label'] as String? ?? '',
          orderStatus: stChip?['value'] as String? ?? '',
          items:       oid != null ? (itemsByOrderId[oid] ?? const []) : const [],
          render:      m,
        ));
      }

      final coSummary =
          (coMap['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
      final coEmpty =
          (coMap['empty'] as Map?)?.cast<String, dynamic>() ?? const {};
      final coCount = (coMap['count'] as num?)?.toInt() ?? 0;
      final coSummaryLabel = coSummary['label'] as String? ?? '';
      // CHANGE #607 — the desktop table's columns, in the backend's order.
      final coColumns = backendColumns(coMap['columns']);
      final coDateLabel = coMap['date_label'] as String? ?? '';   // CHANGE #609
      final coZoneLabel = coMap['zone_label'] as String? ?? '';   // CHANGE #609

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
                  addedByBadge:   (ci['added_by_badge'] as Map?)?.cast<String, dynamic>()
                      ?? const {},
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
          // CHANGE #601 — the server's number for this customer's cart.
          netPayable:   _serverNetPayable(screen, pp?['id']?.toString()),
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
          // CHANGE #606 — header, count and empty state as returned.
          _ordersSummaryLabel = coSummaryLabel;
          _ordersCount        = coCount;
          _ordersEmpty        = coEmpty;
          _ordersColumns      = coColumns; // CHANGE #607
          _ordersDateLabel    = coDateLabel; // CHANGE #609
          _ordersZoneLabel    = coZoneLabel; // CHANGE #609
          _cartRows     = carts;
          _cartFooterLines =
              ((screen['cart_footer'] as Map?)?['total_lines'] as num?)?.toInt() ?? 0;
          _cartFooterValue =
              ((screen['cart_footer'] as Map?)?['total_value'] as num?)?.toDouble() ?? 0.0;
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
        showToast(context, cf('admin_customer.failed_to_load', {'e': '$e'}), isError: true);
      }
    } finally {
      _loadInFlight = false;
    }
    _loadLeads();
    _loadPipeline();
  }

  /// CMD #1886 — the registration funnel's own two reads. Fire-and-forget, like
  /// the lead load above: neither the tab captions nor the stage chips may hold
  /// up the list, and a failure leaves the previous payload on screen rather
  /// than a Dart-invented substitute.
  Future<void> _loadPipeline() async {
    try {
      final client = Supabase.instance.client;
      final home = await client.rpc('customer_pipeline_home');
      final meta = await client.rpc('customers_stage_meta');
      if (!mounted) return;
      setState(() {
        _pipeHome = home is Map ? Map<String, dynamic>.from(home) : const {};
        _stageMeta = (meta is Map && meta['by_id'] is Map)
            ? Map<String, dynamic>.from(meta['by_id'] as Map)
            : const {};
      });
      RenderLog.write('c1886_pipeline_tabs', _pipeTabs.length);
    } catch (_) {
      // the backend owns every sentence here; silence beats a Dart apology
    }
  }

  List<Map<String, dynamic>> get _pipeTabs =>
      ((_pipeHome['tabs'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  List<Map<String, dynamic>> get _pipeAssignees =>
      ((_pipeHome['assignees'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// The caption for one pipeline tab, as the backend wrote it: "Signed up (5)".
  /// A tab the payload has not described yet renders nothing at all.
  String _pipeLabel(String key) {
    for (final t in _pipeTabs) {
      if ((t['key'] ?? '').toString() == key) {
        final label = (t['label'] ?? '').toString();
        final count = (t['count_label'] ?? '').toString();
        if (label.isEmpty) return '';
        return count.isEmpty ? label : '$label ($count)';
      }
    }
    return '';
  }

  /// The stage chip + approve gate the backend computed for one customer row.
  Map<String, dynamic> _metaFor(String id) => (_stageMeta[id] is Map)
      ? Map<String, dynamic>.from(_stageMeta[id] as Map)
      : const {};

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
        // #593 — medicine_rows_by_ids() also resolves gst_percent through
        // gst_rate_for(), so this lookup can never disagree with the cart.
        final raw = await client.rpc('medicine_rows_by_ids', params: {'p_ids': chunk});
        final rows = (((raw is List ? raw.first : raw) as Map)['rows']
            as List<dynamic>? ?? const []);
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
      // #593 — same screen payload, fetched in this scope.
      final lRaw = await client.rpc('admin_customer_screen_data');
      final lMap = (lRaw is List ? lRaw.first : lRaw) as Map;
      final leadsRows = (lMap['leads'] as List<dynamic>?) ?? const [];
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
      final aRaw = await client.rpc('admin_customer_screen_data');
      final aMap = (aRaw is List ? aRaw.first : aRaw) as Map;
      final adminsRows = (aMap['admins'] as List<dynamic>?) ?? const [];
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

  /// CHANGE #601 — reads cart_totals_for() out of the screen payload.
  ///
  /// This replaced _computeNetPayable(), a full tax engine in Dart: it summed
  /// mrp*qty, called cartDiscountPercent() (a TIER LADDER evaluated in Dart),
  /// grouped by GST rate, applied the discount and added tax per group — a
  /// second, independent implementation of what the customer is charged, free
  /// to disagree with the cart itself.
  static double _serverNetPayable(Map screen, String? customerId) {
    if (customerId == null) return 0.0;
    final totals = (screen['cart_totals'] as Map?)?[customerId] as Map?;
    return (totals?['net_payable'] as num?)?.toDouble() ?? 0.0;
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
      // CMD #1886 — the three funnel tabs draw their own rows from their own
      // RPC; this legacy list is not theirs.
      case _CustFilter.signedUp:
      case _CustFilter.followUps:
      case _CustFilter.needsAttention:
        return [];
    }
  }

  bool get _isRegView      => _filter == _CustFilter.pendingRegistrations;
  bool get _isApprovedView => _filter == _CustFilter.approvedCustomers;
  bool get _isLeadsView    => _filter == _CustFilter.leads;
  bool get _isSLeadsView   => _filter == _CustFilter.sLeads;
  bool get _isRoutesView   => _filter == _CustFilter.routes;

  // ── Approve / Reject registrations ────────────────────────────────────────

  // CHANGE #578 — admin_customer_action() owns the customer lifecycle.
  //
  // This matters more than the supplier equivalent: `approved` on
  // pharmacy_profiles is exactly what my_session().can_place_order reads. A
  // client-writable approval flag means the app could grant itself the right
  // to order. It also stamped approved_at from the DEVICE clock and wrote
  // approved_by as the literal string 'admin' rather than a person.
  Future<void> _approveReg(_RegRow row) async {
    await Supabase.instance.client.rpc('admin_customer_action',
        params: {'p_customer_id': row.id, 'p_action': 'approve'});
    _notifyRegistration(row, isApproved: true);
    _load();
  }

  Future<void> _rejectReg(_RegRow row) async {
    await Supabase.instance.client.rpc('admin_customer_action',
        params: {'p_customer_id': row.id, 'p_action': 'reject'});
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

  // ── Suspend / Reactivate / Edit / Delete an approved customer ────────────
  //
  // CHANGE #810 — these four moved to the customer page, where each one now
  // collects a reason and records it: Block and Delete go through
  // admin_customer_action_reason(), and Edit is a backend-described form
  // (admin_customer_edit_form / _save) rather than a hardcoded field list.

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
        title: Text(cf('admin_customer.restore_confirm_title', {'a': displayName}),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700,
                color: Color(0xFF111827))),
        content: Text(
          email.isNotEmpty
              ? cf('admin_customer.restore_with_magic_link', {'a': email})
              : c('admin_customer.restore_active_list'),
          style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(c('admin_customer.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            child: Text(c('admin_customer.restore')),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final client = Supabase.instance.client;
      // #578 — restore via the same RPC family.
      await client.rpc('admin_customer_action', params: {
        'p_customer_id': deletedRow['id'] as String,
        'p_action': 'restore',
      });
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
            ? cf('admin_customer.customer_restored_magic_link', {'a': email})
            : c('admin_customer.customer_restored'));
      }
    } catch (e) {
      if (mounted) {
        showToast(context, cf('admin_customer.restore_failed', {'a': '$e'}), isError: true);
      }
    }
  }

  // ── Order status ───────────────────────────────────────────────────────────

  /// CHANGE #608 — the BackendActionHandler the desktop table's
  /// `type:"actions"` cell calls. The order id is read out of the same payload
  /// row the cell rendered from, so the write can only ever target the row the
  /// admin actually tapped.
  Future<void> _orderActionHandler(
      Map<String, dynamic> row, String status, String note) async {
    final orderId = row['order_id'] as String? ?? '';
    if (orderId.isEmpty) return;
    await _updateStatus(orderId, status, note);
  }

  /// CHANGE #607 — [status] is the value the backend put in the action object,
  /// and [note] is the backend's success copy. After the write this refetches
  /// admin_customer_orders via _load() and re-renders from the response: the
  /// row's status and chip are never mutated locally, so the screen cannot show
  /// a state the database did not confirm.
  Future<void> _updateStatus(String orderId, String status, String note) async {
    try {
      await Supabase.instance.client
          .rpc('admin_set_order_status',
               params: {'p_order_id': orderId, 'p_status': status});
      RenderLog.write('order_status_written', 'orderId:$orderId status:$status');
      await _load();
      if (mounted && note.isNotEmpty) showToast(context, note);
    } catch (e) {
      RenderLog.write('order_status_err', e.toString());
      if (mounted) {
        showToast(context, cf('admin_customer.update_failed', {'a': '$e'}), isError: true);
      }
    }
  }

  Future<void> _adminSoftRemoveItem(int itemId) async {
    try {
      // #577 — removed_at came from the DEVICE clock and the only thing
      // stopping a non-admin was RLS. The RPC stamps server time and states
      // the admin check in the database.
      await Supabase.instance.client
          .rpc('admin_cart_remove_item', params: {'p_item_id': itemId});
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) {
        showToast(context, cf('admin_customer.remove_failed', {'a': '$e'}), isError: true);
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

  /// CHANGE #238 — one RPC feeds the whole expanded panel.
  ///
  /// It replaces get_order_item_inquiry_status, which returned rows keyed only
  /// by product name (the caller had to name-match them against the orders
  /// JSONB) and hid `current_supplier` behind `asked_at is not null` — NULL for
  /// the entire manual lane, which blanked the supplier badge on every item.
  /// order_item_status_panel returns one line per order_items row, in backend
  /// order, plus the reconciliation block for the order as a whole.
  Future<void> _fetchOrderItemStatus(String orderId) async {
    try {
      final raw = await Supabase.instance.client.rpc(
        'order_item_status_panel',
        params: {'p_order_id': orderId},
      );
      final view = OrderItemPanelView.fromPayload(raw,
          errorFallback: c('admin_customer.items_load_failed'));
      final lines = view.lines;
      final recon = view.reconcile.raw;
      if (mounted) {
        setState(() => _orderPanels[orderId] = view);
        RenderLog.write('order_item_status', 'orderId:$orderId count:${lines.length}');
        // CHANGE #238 — proof the panel painted from the RPC: how many lines
        // arrived, and whether the backend says this order reconciles.
        RenderLog.write(
            'c238_reconcile',
            'admin;order:$orderId;lines:${lines.length}'
            ';balanced:${recon['balanced']}'
            ';assigned:${recon['assigned']}'
            ';unfulfillable:${recon['unfulfillable']}'
            ';in_inquiry:${recon['in_inquiry']}'
            ';unaccounted:${recon['unaccounted']}'
            ';missing_po:${recon['missing_po']}');
        final withSupplier = lines.where((l) => l.hasSupplier).length;
        RenderLog.write('c238_supplier_labels',
            'order:$orderId;lines:${lines.length};with_supplier:$withSupplier');
        for (final l in lines) {
          RenderLog.write(
              'order_item_rpc_row',
              '${l.productName}:state=${l.state}'
              ':status=${l.statusLabel}:sup=${l.supplierLabel}');
        }
      }
    } catch (e) {
      RenderLog.write('order_item_status_error', 'orderId:$orderId err:$e');
      if (mounted) {
        setState(() => _orderPanels[orderId] =
            OrderItemPanelView.failed(c('admin_customer.items_load_failed')));
      }
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
        title: Text(cf('admin_customer.delete_order_confirm_title', {'a': code})),
        content: Text(
            c('admin_customer.delete_order_warning')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: Text(c('admin_customer.cancel')),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(dCtx, true),
            child: Text(c('admin_customer.delete')),
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
        showToast(context, cf('admin_customer.delete_failed_map', {'a': map['error']}), isError: true);
      } else {
        showToast(context, c('admin_customer.order_deleted_lead_restored'));
      }
    } catch (e) {
      if (mounted) showToast(context, cf('admin_customer.delete_error', {'a': '$e'}), isError: true);
    } finally {
      if (mounted) setState(() => _deletingOrders.remove(orderId));
    }
  }

  // CHANGE #465: row-level bill actions (upload/view/delete/download/
  // WhatsApp/share) now live in the self-contained _AdminBillRowActions
  // widget below — it fetches its own customer_bill_file() state, so this
  // superseded #464's _uploadCustomerBillFor/_buildUploadBillAndPayRow.
  // _billUploadEpoch is kept only to key the separate _AdminBillView tile in
  // the expanded-items panel so IT remounts and refetches too after an
  // upload/delete from the row above (it has its own independent fetch).
  int _billUploadEpoch = 0;

  Widget _buildUploadBillAndPayRow(_CustRow row, {required VoidCallback onViewPayTap}) {
    final orderId = row.orderId;
    if (orderId == null) return const SizedBox();
    return _AdminBillRowActions(
      key: ValueKey(orderId),
      orderId: orderId,
      payOpen: _payOpen[orderId] == true,
      onViewPayTap: onViewPayTap,
      onViewPayLongPress: () => showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => CashPaymentSheet(
          orderId: orderId,
          onSuccess: () => setState(() {}),
        ),
      ),
      onBillChanged: () => setState(() => _billUploadEpoch++),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    _redirectIfTabHidden();
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
              // CHANGE #537 — embedded in the Fulfill pipeline the bar above is
              // already the tab row; drawing this screen's own would be two.
              if (!widget.embedded) _buildHeader(isDesktop),
              _buildScrollContent(isDesktop),
            ],
          ),
        ),
      );
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // CHANGE #810 — the Customers CONSOLE.
  //
  // The tall per-customer card is gone. Rows, chips and their counts, the sort
  // options and every label all arrive from admin_customers_console(); this
  // screen holds the chosen filters and prints what came back. Numbers and
  // actions live on the customer page you reach by tapping a row.
  // ═══════════════════════════════════════════════════════════════════════════
  Map<String, dynamic> _cusConsole = const {};
  final Set<String> _cusFilters = <String>{};
  final TextEditingController _cusSearchCtl = TextEditingController();
  String _cusQuery = '';
  String _cusSort = '';
  bool _cusLoading = false;
  Timer? _cusSearchDebounce;

  List<Map<String, dynamic>> _cusList(String key) {
    final v = _cusConsole[key];
    return v is List
        ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : const <Map<String, dynamic>>[];
  }

  String _cusStr(String key) => (_cusConsole[key] as String?) ?? '';

  Future<void> _loadCusConsole() async {
    if (!mounted) return;
    setState(() => _cusLoading = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_customers_console',
        params: {
          'p_filters': _cusFilters.toList(),
          if (_cusSort.isNotEmpty) 'p_sort': _cusSort,
          if (_cusQuery.isNotEmpty) 'p_search': _cusQuery,
        },
      );
      if (!mounted) return;
      setState(() {
        _cusConsole = res is Map ? res.cast<String, dynamic>() : const {};
        _cusLoading = false;
      });
      RenderLog.write('c810_customer_rows', '${_cusList('rows').length}');
      RenderLog.write('c810_customer_chips', '${_cusList('chips').length}');
    } catch (_) {
      if (mounted) setState(() => _cusLoading = false);
    }
  }

  void _onCusSearchChanged(String v) {
    _cusQuery = v.trim();
    _cusSearchDebounce?.cancel();
    _cusSearchDebounce =
        Timer(const Duration(milliseconds: 300), _loadCusConsole);
  }

  void _toggleCusFilter(String key) {
    if (key.isEmpty) return;
    setState(() {
      if (!_cusFilters.remove(key)) _cusFilters.add(key);
    });
    _loadCusConsole();
  }

  void _setCusSort(String key) {
    if (key.isEmpty || key == _cusSort) return;
    setState(() => _cusSort = key);
    _loadCusConsole();
  }

  /// ONE horizontally scrollable row of small chips, with the sort sheet
  /// behind the filter icon. No zone chip: the header's zone picker already
  /// said which zone this is.
  Widget _buildCusChips(double pad) {
    final chips = _cusList('chips');
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(0, 0, 0, Ds.space.x12),
      child: Row(children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: pad),
            child: Row(children: [
              for (final ch in chips) ...[
                _CusChip(
                  label: (ch['label'] as String?) ?? '',
                  count:
                      ch['count'] is num ? (ch['count'] as num).toInt() : null,
                  active: ch['active'] == true,
                  onTap: () => _toggleCusFilter((ch['key'] as String?) ?? ''),
                ),
                SizedBox(width: Ds.space.x8),
              ],
            ]),
          ),
        ),
        Padding(
          padding: EdgeInsets.only(right: pad),
          child: IconButton(
            tooltip: _cusStr('filters_label'),
            icon: Icon(Icons.tune,
                size: Ds.space.x16 + Ds.space.x4, color: Ds.c.textSecondary),
            onPressed: _openCusSortSheet,
          ),
        ),
      ]),
    );
  }

  Future<void> _openCusSortSheet() async {
    final sorts = _cusList('sorts');
    if (sorts.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (sctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: Text(_cusStr('sort_sheet_title'), style: Ds.t.subtitle),
          ),
          for (final so in sorts)
            ListTile(
              title: Text((so['label'] as String?) ?? '', style: Ds.t.body),
              trailing: so['active'] == true
                  ? Icon(Icons.check,
                      color: Ds.c.brand, size: Ds.space.x16 + Ds.space.x4)
                  : null,
              onTap: () {
                Navigator.pop(sctx);
                _setCusSort((so['key'] as String?) ?? '');
              },
            ),
          SizedBox(height: Ds.space.x8),
        ]),
      ),
    );
  }

  /// The follow-ups inbox strip. It appears only when the backend says a
  /// follow-up is due, and its wording and count are the payload's.
  Widget _buildCusFollowups(double pad) {
    final fu = _cusConsole['followups'];
    final m = fu is Map ? fu.cast<String, dynamic>() : const {};
    if (m['has'] != true) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 0, pad, Ds.space.x12),
      child: InkWell(
        onTap: () => _openCusFollowups((m['rpc'] as String?) ?? ''),
        borderRadius: Ds.r.rButton,
        child: Container(
          width: double.infinity,
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          padding: EdgeInsets.all(Ds.space.x12),
          decoration: BoxDecoration(
            color: Ds.c.warningSoft,
            borderRadius: Ds.r.rButton,
          ),
          child: Row(children: [
            Icon(Icons.notifications_active_outlined,
                size: Ds.space.x16 + Ds.space.x4, color: Ds.c.warning),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: Text((m['label'] as String?) ?? '',
                  style: Ds.t.body.copyWith(color: Ds.c.warning)),
            ),
            Icon(Icons.chevron_right, color: Ds.c.warning),
          ]),
        ),
      ),
    );
  }

  Future<void> _openCusFollowups(String rpc) async {
    if (rpc.isEmpty) return;
    Map<String, dynamic> res;
    try {
      final raw = await Supabase.instance.client.rpc(rpc);
      res = raw is Map ? raw.cast<String, dynamic>() : const {};
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
      return;
    }
    if (!mounted) return;
    final items = (res['items'] is List)
        ? (res['items'] as List)
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList()
        : const <Map<String, dynamic>>[];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (sctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text((res['title'] as String?) ?? '', style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x12),
              if (items.isEmpty)
                Text((res['empty'] as String?) ?? '',
                    style: Ds.t.bodySecondary)
              else
                for (final it in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text((it['title'] as String?) ?? '',
                        style: Ds.t.bodyStrong),
                    subtitle: Text(
                        '${(it['subtitle'] as String?) ?? ''}\n${(it['meta'] as String?) ?? ''}',
                        style: Ds.t.caption),
                    isThreeLine: true,
                    onTap: () {
                      Navigator.pop(sctx);
                      _openCustomerPage((it['customer_id'] as String?) ?? '');
                    },
                  ),
              SizedBox(height: Ds.space.x8),
            ],
          ),
        ),
      ),
    );
  }

  /// The page owns every customer action now — approval, edit, zone, notes,
  /// merge, block and delete-with-reason all run there. The list only reloads
  /// afterwards, because a rename, a merge or a delete changes what it shows.
  Future<void> _openCustomerPage(String id, {String initialTab = ''}) async {
    if (id.isEmpty) return;
    await openAdminCustomerPage(context, id, initialTab: initialTab);
    if (!mounted) return;
    await _load(showSpinner: false);
    await _loadCusConsole();
  }

  Widget _buildCustomersConsole(bool isDesktop) {
    final pad = isDesktop ? Ds.space.x24 : Ds.space.x16;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 0, pad, Ds.space.x8),
        child: TextField(
          controller: _cusSearchCtl,
          onChanged: _onCusSearchChanged,
          textInputAction: TextInputAction.search,
          style: Ds.t.caption,
          decoration: InputDecoration(
            hintText: _cusStr('search_hint'),
            prefixIcon: Icon(Icons.search, size: Ds.space.x16 + Ds.space.x4),
            suffixIcon: _cusQuery.isEmpty
                ? null
                : IconButton(
                    icon: Icon(Icons.clear, size: Ds.space.x16 + Ds.space.x4),
                    onPressed: () {
                      _cusSearchCtl.clear();
                      _onCusSearchChanged('');
                    },
                  ),
            isDense: true,
            contentPadding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x8),
            border: OutlineInputBorder(borderRadius: Ds.r.rButton),
          ),
        ),
      ),
      _buildCusChips(pad),
      // CHANGE #1888 — the book's own completeness, above the list that has
      // the holes in it.
      CustomerAutofillStrip(
          padding: EdgeInsets.fromLTRB(pad, 0, pad, Ds.space.x8)),
      _buildCusFollowups(pad),
      if (_cusLoading && _cusList('rows').isEmpty)
        Padding(
          padding: EdgeInsets.all(Ds.space.x32),
          child: const Center(child: CircularProgressIndicator()),
        )
      else if (_cusList('rows').isEmpty)
        _ssvEmptyState(_cusStr('empty_label'))
      else ...[
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 0, pad, Ds.space.x8),
          child: Text(_cusStr('count_label'), style: Ds.t.caption),
        ),
        for (final row in _cusList('rows'))
          CustomerConsoleRow(
            row: row,
            // CMD #1886 — the funnel's word for this row, from the backend.
            stageChip: _metaFor((row['id'] as String?) ?? '')['chip'],
            onOpen: () => _openCustomerPage((row['id'] as String?) ?? ''),
          ),
      ],
    ]);
  }

  Widget _buildScrollContent(bool isDesktop) {
    // CMD #1886 — the three funnel tabs. One widget, one backend tab key; the
    // payload decides everything it draws.
    final pipeKey = const {
      _CustFilter.signedUp: 'signed_up',
      _CustFilter.followUps: 'followups',
      _CustFilter.needsAttention: 'needs',
    }[_filter];
    if (pipeKey != null) {
      return CustomerPipelineTab(
        key: ValueKey('c1886_$pipeKey'),
        tabKey: pipeKey,
        assignees: _pipeAssignees,
        onCountChanged: (_) => _loadPipeline(),
      );
    }
    // S Leads tab (CHANGE #443 — scraped lead-generation UI)
    if (_isSLeadsView) {
      RenderLog.write('c443_tab_present', 1);
      return _SLeadsTab(
        isDesktop: isDesktop,
        onTotalChanged: (n) {
          if (mounted) setState(() => _sLeadsTotal = n);
        },
        onCountChip: (chip) {
          if (mounted) setState(() => _sLeadsCountChip = chip);
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
      RenderLog.write('c547_import_customer_btn', 'true');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // CHANGE #547 — Import Customer, mirroring Import Supplier's styling.
          _buildImportCustomerButton(),
          // CHANGE #810 — the console replaces the tall per-customer card.
          _buildCustomersConsole(isDesktop),
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
    // CHANGE #606 — the Customer Orders empty state is the backend's
    // empty{show,title,note}. The Dart literals '0 orders' (twice) are gone.
    // empty.show is what decides; an empty title renders no text rather than a
    // Dart substitute.
    final isOrders = _filter == _CustFilter.customerOrders;
    if (rows.isEmpty && !showLeads) {
      return isOrders
          ? _ordersEmptyState()
          : _ssvEmptyState('0 customers with unpurchased cart items');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLeads) ..._buildLeadsSection(isDesktop),
        if (rows.isNotEmpty) ...[
          // CHANGE #606 — summary.label: "N orders • N items • ₹N". Not one
          // number of it is added up in Dart.
          if (isOrders)
            Padding(
              padding: EdgeInsets.fromLTRB(isDesktop ? 28 : 16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // CHANGE #609 — the scope line: the date and the zone the
                  // backend actually applied, each printed only when it sent
                  // one. Neither string is built here.
                  if (_ordersDateLabel.isNotEmpty || _ordersZoneLabel.isNotEmpty)
                    Row(children: [
                      if (_ordersDateLabel.isNotEmpty)
                        Text(_ordersDateLabel,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF6B7280))),
                      if (_ordersDateLabel.isNotEmpty &&
                          _ordersZoneLabel.isNotEmpty)
                        const SizedBox(width: 10),
                      if (_ordersZoneLabel.isNotEmpty)
                        Text(_ordersZoneLabel,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF1B7A43))),
                    ]),
                  if (_ordersSummaryLabel.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(_ordersSummaryLabel,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF374151))),
                  ],
                  // CHANGE #639 PART D — the Demand preview entry. Its label
                  // lives in the fw_ui_label catalog, so rewording it is an
                  // UPDATE rather than a rebuild; while the catalog has not
                  // loaded ui() returns '' and the entry simply is not drawn,
                  // rather than falling back to an English literal here.
                  if (FulfillLookups.instance
                      .ui('c639_demand_preview_entry')
                      .isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => DemandPreviewSheet.show(context),
                        icon: const Icon(Icons.insights_outlined, size: 16),
                        label: Text(FulfillLookups.instance
                            .ui('c639_demand_preview_entry')),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1B7A43),
                          side: const BorderSide(color: Color(0xFF1B7A43)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 10),
                          textStyle: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (isDesktop) _buildCustTableHeader(),
          ...rows.map(
            (r) => isDesktop ? _buildDesktopCustRow(r) : _buildMobileCustCard(r)),
        ] else if (showLeads)
          _ordersEmptyState(),
        if (_filter == _CustFilter.cartNotOrdered)
          _buildCartTotalsFooter(isDesktop),
        const SizedBox(height: 32),
      ],
    );
  }

  /// CHANGE #606 — the Customer Orders empty state, from the RPC's
  /// empty{show,title,note}. Renders nothing at all when the backend says
  /// show:false, and skips title or note individually when either is empty —
  /// no Dart fallback copy anywhere in this path.
  Widget _ordersEmptyState() {
    if (_ordersEmpty['show'] != true) return const SizedBox.shrink();
    final title = _ordersEmpty['title'] as String? ?? '';
    final note  = _ordersEmpty['note'] as String? ?? '';
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: const Icon(Icons.inbox_outlined,
                  size: 28, color: Color(0xFFD1D5DB)),
            ),
            if (title.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6B7280))),
            ],
            if (note.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(note,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 13, color: Color(0xFF9CA3AF))),
            ],
          ],
        ),
      ),
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
                // CHANGE #653 — ONE interface. Each tab is its own row in the
                // permission matrix (partner_screen_tab -> feature_registry),
                // so a super admin, an admin and a partner see the SAME screen
                // with the tabs their matrix turned on. `tabCanView` answers
                // true for a tab the backend has not catalogued, so a new tab
                // is never hidden by a stale registry.
                if (_tabOn('customers'))
                  _tab(_CustFilter.approvedCustomers,
                      'Customers (${_approvedRows.length})'),
                const SizedBox(width: 4),
                // CHANGE #606 — the count is the backend's `count`, not
                // _orderRows.length. The list and the number can no longer
                // disagree because only one of them is computed.
                if (_tabOn('orders'))
                  _tab(_CustFilter.customerOrders,
                      'Customer Orders ($_ordersCount)'),
                const SizedBox(width: 4),
                if (_tabOn('cart'))
                  _tab(_CustFilter.cartNotOrdered,
                      'Cart (${_cartRows.length})'),
                const SizedBox(width: 4),
                if (_tabOn('pending'))
                  _tab(_CustFilter.pendingRegistrations,
                      'Pending Approval (${_regRows.length})'),
                const SizedBox(width: 4),
                if (_tabOn('leads'))
                  _tab(_CustFilter.leads,
                      'Leads (${_loggedInLeads.length + _otherLeads.length})'),
                const SizedBox(width: 4),
                if (_tabOn('s_leads'))
                  _tab(
                      _CustFilter.sLeads,
                      _sLeadsCountChip ??
                          _countedTabLabel('sleads', 'S Leads ($_sLeadsTotal)')),
                const SizedBox(width: 4),
                if (_tabOn('routes'))
                  _tab(_CustFilter.routes,
                      _countedTabLabel('routes', 'Routes ($_routesZones)')),
                // CMD #1886 — the funnel. Each caption and count is
                // customer_pipeline_home()'s; an undescribed tab draws nothing.
                if (_tabOn('signed_up') && _pipeLabel('signed_up').isNotEmpty) ...[
                  const SizedBox(width: 4),
                  _tab(_CustFilter.signedUp, _pipeLabel('signed_up')),
                ],
                if (_tabOn('followups') && _pipeLabel('followups').isNotEmpty) ...[
                  const SizedBox(width: 4),
                  _tab(_CustFilter.followUps, _pipeLabel('followups')),
                ],
                if (_tabOn('needs_attention') && _pipeLabel('needs').isNotEmpty) ...[
                  const SizedBox(width: 4),
                  _tab(_CustFilter.needsAttention, _pipeLabel('needs')),
                ],
              ]),
            ),
          ),
          // CHANGE #545 — the Customer Orders date chip is DELETED. The one
          // admin date picker lives on the Dashboard, above ORDER HOURS.
        ]);
      }),
    );
  }

  /// CHANGE #653 — is this tab turned on for the signed-in login? The screen
  /// asks the matrix; it never decides by role.
  bool _tabOn(String tabKey) => Access.instance.tabCanView('customer', tabKey);

  /// The backend's tab key for each filter, in the tab row's own order.
  static const Map<_CustFilter, String> _tabKeys = {
    _CustFilter.approvedCustomers: 'customers',
    _CustFilter.customerOrders: 'orders',
    _CustFilter.cartNotOrdered: 'cart',
    _CustFilter.pendingRegistrations: 'pending',
    _CustFilter.leads: 'leads',
    _CustFilter.sLeads: 's_leads',
    _CustFilter.routes: 'routes',
    _CustFilter.signedUp: 'signed_up',
    _CustFilter.followUps: 'followups',
    _CustFilter.needsAttention: 'needs_attention',
  };

  /// CHANGE #653 — a tab this login does not hold must not be left OPEN
  /// either: the button is gone, so there would be no way back. Land on the
  /// first tab the matrix does allow.
  void _redirectIfTabHidden() {
    // CHANGE #754 — an EMBEDDED instance is a Fulfill stage, not this screen's
    // tab bar. Its permission is `fulfill_tabs()`, and the customer/orders row
    // is now retired precisely BECAUSE the stage owns it, so honouring that
    // row here would bounce the Fulfill Customer-order tab off its own body.
    if (widget.embedded) return;
    if (_tabOn(_tabKeys[_filter] ?? '')) return;
    for (final e in _tabKeys.entries) {
      if (_tabOn(e.value)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_tabOn(_tabKeys[_filter] ?? '')) {
            setState(() => _filter = e.key);
          }
        });
        return;
      }
    }
  }

  // Part D: MouseRegion for pointer cursor on all tabs
  // Part E: pill/chip style tabs — active = green fill, inactive = grey outline
  Widget _tab(_CustFilter f, String label) {
    final active = _filter == f;
    // CHANGE #653 — View on + Write off is a real state, and the tab says so
    // in the backend's own word. The refusal itself is server-side.
    final readOnly = !Access.instance.tabCanWrite('customer', _tabKeys[f] ?? '');
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
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: active ? Colors.white : const Color(0xFF6B7280),
              ),
            ),
            if (readOnly)
              AccessReadOnlyChip(label: Access.instance.readonlyBadge),
          ]),
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
          Text(cf('admin_customer.leads_count', {'a': '${_leads.length}'}),
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF4338CA))),
        ]),
      ),
      ..._leads.map((l) => _buildLeadCard(l, pad: pad)),
      SizedBox(height: isDesktop ? 20 : 16),
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 0, pad, 8),
        child: Text(c('admin_customer.orders'),
            style: const TextStyle(
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
            tooltip: c('admin_customer.delete_all_order_lists_today'),
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
        title: Text(cf('admin_customer.delete_all_order_lists_from_today', {'a': displayName})),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: Text(c('admin_customer.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFDC2626)),
            child: Text(c('admin_customer.delete')),
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
      if (mounted) showToast(context, cf('admin_customer.delete_failed', {'a': '$e'}), isError: true);
    }
  }

  Future<void> _deleteLeadImage(LeadImage img) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(c('admin_customer.delete_this_order_list')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: Text(c('admin_customer.cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            style: TextButton.styleFrom(foregroundColor: const Color(0xFFDC2626)),
            child: Text(c('admin_customer.delete')),
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
      if (mounted) showToast(context, cf('admin_customer.delete_failed', {'a': '$e'}), isError: true);
    }
  }

  Future<void> _convertLeadImage(Lead lead, LeadImage image) async {
    final viewAs = ViewAsState.of(context);
    final scaffoldCtx = context;
    final res = await Supabase.instance.client
        .rpc('wa_convert_start', params: {'p_image_id': image.id});
    final data = Map<String, dynamic>.from(res as Map);
    if (data['ok'] != true) {
      if (mounted) showToast(scaffoldCtx, c('admin_customer.toast_convert_start_failed'), isError: true);
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
      // #593 — `found` is explicit; an empty row object is not "no customer".
      final pr = await Supabase.instance.client
          .rpc('admin_customer_profile_by_user', params: {'p_user_id': userId});
      final pm = (pr is List ? pr.first : pr) as Map;
      profRow = pm['found'] == true
          ? Map<String, dynamic>.from(pm['row'] as Map)
          : null;
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

    // CHANGE #607 — Customer Orders header is columns[], nothing else.
    //
    // Deleted here: the literals 'PHONE', 'STATUS', 'AMOUNT', 'ITEMS',
    // 'CONFIRMATION', 'PAYMENT' and the 'CUSTOMER' shared with Cart, plus every
    // hardcoded flex on the orders branch. Renaming a column, reordering the
    // table or changing a width is now an app_settings.order_tab_columns edit.
    // The Cart tab is a different tab and keeps its own literal header until it
    // gets a columns[] of its own.
    if (!isCart) {
      RenderLog.write('c607_cust_cols', _ordersColumns.length);
      return BackendTableHeader(
        columns: _ordersColumns,
        // Fixed chrome only: the delete-order icon and the expand chevron.
        // Neither is a column — no header text, no payload flex.
        trailingWidth: 64,
      );
    }

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
        _th('ITEMS', flex: 1),
        _th('VALUE', flex: 2),
        const SizedBox(width: 32),
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
            // ── CHANGE #607 — Customer Orders cells come from columns[] ─────
            //
            // Order, width, alignment and cell TYPE are all the backend's. The
            // hand-built cells that lived here (title+code column, phone cell,
            // a four-chip BackendChipRow, amount, items+time) are gone: the
            // payload says which keys to print and in what order, and
            // BackendTableCell prints them. Note the config currently shows
            // ONE chip (status_chip) — fulfillment/source/admin are still in
            // every row and can be added as columns without a deploy.
            if (!isCart)
              Expanded(
                flex: _ordersColumns.fold<int>(0, (a, c) => a + c.flex),
                child: BackendTableRowCells(
                  columns: _ordersColumns,
                  row: row.render,
                  // CHANGE #608 — feeds the type:"actions" cell. The row's
                  // order_id comes from the payload the cell was built from,
                  // so the write always targets the row the admin tapped.
                  actionHandler: _orderActionHandler,
                ),
              ),
            if (isCart) ...[
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
              Expanded(
                flex: 1,
                // CHANGE #238 — the backend's own order_items count. This read
                // `row.items.length` (the orders.items JSONB), so the collapsed
                // row could say 9 while expanding it listed 18. Cart rows have
                // no render payload and keep their own list length.
                child: Text(
                    row.isOrder
                        ? '${(row.render['items_count'] as num?)?.toInt() ?? row.items.length}'
                        : '${row.items.length}',
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
      // CHANGE #607 — the action strip.
      //
      // Accept/Reject (whose visibility, labels, colours and written status all
      // come from actions{}) and the bill/payment row are NOT columns: they
      // carry no header text and no payload flex. Giving them their own
      // full-width strip under the row is what lets the grid above be exactly
      // the columns[] the backend described, with nothing hardcoded wedged in.
      if (!isCart && row.orderId != null)
        Container(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          // CHANGE #608 — accept/reject is GONE from this strip. columns[]
          // now carries a type:"actions" CONFIRMATION column, so the buttons
          // render in the grid where the header says they are. Leaving a copy
          // here would put two live accept buttons on one row. What remains is
          // the bill/payment affordance, which is not a column: PAYMENT in
          // columns[] is payment_chip, the status, not these buttons.
          child: Row(children: [
            const Spacer(),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: _buildUploadBillAndPayRow(row,
                  onViewPayTap: () => _togglePayOpen(row.orderId!)),
            ),
          ]),
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
                // CHANGE #606 — orders paint the backend's source_chip (in the
                // chip row below); only Cart rows still use the Dart badge,
                // because 'cart_only' is not an order source the backend
                // returns a chip for.
                if (isCart) ...[
                  _SourceBadge(source: row.source),
                  const SizedBox(width: 4),
                ],
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
              if (isCart && row.pharmacy.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(row.pharmacy,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280)),
                    overflow: TextOverflow.ellipsis),
              ],
              // CHANGE #606 — orders: the phone line is phone_label, drawn only
              // when has_phone. No `isEmpty ? A : B` display ternary.
              if (isCart ? row.phone.isNotEmpty : row.rb('has_phone')) ...[
                const SizedBox(height: 2),
                Text(isCart ? row.phone : row.rs('phone_label'),
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
                    cf('admin_customer.items_count_value', {
                      'a': '${row.items.length}',
                      'b': row.items.length == 1 ? '' : 's',
                      'c': row.netPayable.toStringAsFixed(0),
                    }),
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1B7A43)),
                  ),
                ]),
              ],
              // CHANGE #606 — code_label drawn only when show_code is true.
              // Was `row.orderNumber ?? '—'`: an em-dash the app invented for
              // an order the backend simply had no code for.
              if (row.rb('show_code')) ...[
                const SizedBox(height: 6),
                Row(children: [
                  const Icon(Icons.receipt_outlined,
                      size: 13, color: Color(0xFF9CA3AF)),
                  const SizedBox(width: 4),
                  Text(row.rs('code_label'),
                      style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF6B7280),
                          fontFamily: 'monospace')),
                ]),
              ],
              if (showOrderCols) ...[
                // CHANGE #606 — every chip the backend chose to show, painted
                // in its colours. Hidden chips render zero pixels.
                const SizedBox(height: 8),
                BackendChipRow(chips: [
                  row.rchip('status_chip'),
                  row.rchip('fulfillment_chip'),
                  row.rchip('source_chip'),
                  row.rchip('admin_chip'),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Text(row.rs('amount_label'),
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827))),
                  const SizedBox(width: 12),
                  Text(row.rs('items_label'),
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF6B7280))),
                  const Spacer(),
                  Text(row.rs('time_label'),
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF9CA3AF))),
                ]),
                const SizedBox(height: 10),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: BackendActionsCell(
                    actions: row.rmap('actions'),
                    onAct: (status, note) =>
                        _updateStatus(row.orderId!, status, note),
                  ),
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

  /// CHANGE #625 — the per-item status chip, printed exactly as
  /// get_order_item_inquiry_status returned it.
  ///
  /// What was here before was a workaround. The RPC used to answer
  /// "Not asked yet" for every item (two backend bugs, both now fixed), so this
  /// method lower-cased the status, substring-matched it and wrote its OWN
  /// words back out — 'No supplier available', 'Available — $supplier',
  /// 'Awaiting $supplier', 'Confirmation pending' — against its own hard-coded
  /// colour map. Every one of those was the app answering "what do I show?".
  /// The RPC's status values are correct now, so the override is deleted rather
  /// than corrected: it renders `current_status` verbatim and paints it with
  /// the `status_colors` that came with the row.
  ///
  /// `current_status` already resolves to `unfulfillable_reason` server-side
  /// when an item could not be sourced, so C2's reason text needs no branch
  /// here — the same field carries it.
  Widget _itemInquiryBadge(Map<String, dynamic>? s) {
    // CHANGE #238 — `status_label` from order_item_status_panel; it already
    // resolves to the unfulfillable reason, the live inquiry status, or the
    // backend's own "not accounted for" wording.
    final text = (s?['status_label'] ?? '').toString().trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final colors = s?['status_colors'] is Map
        ? (s!['status_colors'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: _hex(colors['bg'], const Color(0xFFF3F4F6)),
          borderRadius: BorderRadius.circular(4)),
      child: Text(text,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: _hex(colors['fg'], const Color(0xFF374151)))),
    );
  }

  /// #625 — the assigned supplier, when there is one. It used to be glued into
  /// the status chip's sentence in Dart; it is a value, so it renders as a
  /// value beside the chip instead of being written into a phrase.
  ///
  /// CHANGE #238 — it prints `supplier_label`, the backend's finished phrase:
  /// "Accepted by X" once a supplier has taken the line, "Asking X" while the
  /// waterfall is still on X. The app no longer reads the bare name and no
  /// longer decides which of those two things is happening.
  Widget _itemSupplierBadge(Map<String, dynamic>? s) {
    final name = (s?['supplier_label'] ?? '').toString().trim();
    if (s?['has_supplier'] != true || name.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(4)),
      child: Text(name,
          style: const TextStyle(
              fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF4B5563))),
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

    if (row.isCartOnly) {
      return _buildCartExpandedItems(row, lpad: lpad, rpad: rpad);
    }

    // ── CHANGE #238 — the item list is the BACKEND's list ────────────────────
    //
    // What was here: `row.items` (parsed out of the orders.items JSONB) joined
    // in Dart against get_order_item_inquiry_status rows by lower-cased,
    // whitespace-collapsed product NAME. Any item whose JSONB name differed
    // from order_items.product_name lost its status, its supplier and its
    // unfulfillable flag — silently, with a dash where the answer should be.
    // That name-match is also the app deciding what the list is.
    //
    // order_item_status_panel() returns one line per order_items row, in the
    // backend's order, with state, status_label, supplier_label, qty_label,
    // price_label and the reconciliation block already decided. Nothing on
    // this panel is computed here anymore.
    final panel = row.orderId != null
        ? (_orderPanels[row.orderId!] ?? OrderItemPanelView.loading)
        : OrderItemPanelView.loading;
    final panelLines = panel.lines;
    final loaded = panel.loaded;
    final reconcile = panel.reconcile;

    // CHANGE #238 — the error state. The catch used to only write a render-log
    // line, so a failed RPC left the panel skeleton-ing forever with no words
    // and no way out; and a `{"error": ...}` reply parsed as "this order has no
    // items" for an order that has eighteen.
    if (panel.hasError) {
      return Container(
        color: const Color(0xFFF9FAFB),
        padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
        child: Row(children: [
          Expanded(
            child: Text(panel.errorMessage,
                style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ),
          TextButton(
            onPressed: row.orderId == null
                ? null
                : () => _fetchOrderItemStatus(row.orderId!),
            child: Text(c('admin_customer.retry')),
          ),
        ]),
      );
    }

    // The WhatsApp case is decided AFTER the panel has answered. It used to be
    // an early return keyed on the orders.items JSONB being empty, which meant
    // a WhatsApp order with real order_items rows printed "items unavailable"
    // and never rendered a single line, a state, or the reconciliation banner.
    if (panel.isEmpty) {
      return Container(
        color: const Color(0xFFF9FAFB),
        padding: EdgeInsets.fromLTRB(lpad, 10, rpad, 14),
        child: Text(
            row.source == 'whatsapp'
                ? c('admin_customer.whatsapp_order_items_unavailable')
                : c('admin_customer.no_items_recorded'),
            style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
      );
    }

    // CHANGE #606 — items_label and amount_label, verbatim. This line used to
    // be `'Order Items (${row.items.length})' + ' · ₹' + total.toStringAsFixed(2)`
    // — a Dart count, a Dart rupee prefix and a Dart decimal format, all three
    // of which the backend already returns as finished strings.
    final itemsLabel  = row.rs('items_label');
    final amountLabel = row.rs('amount_label');

    RenderLog.write('c238_panel_lines',
        'orderId:${row.orderId ?? "?"}:lines:${panelLines.length}'
        ':balanced:${reconcile.balanced}'
        ':unaccounted:${reconcile.raw['unaccounted']}');

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
              // CHANGE #686 — the header Om photographed. It passed {a} and
              // {b} at a template that takes {name}, so cf() stripped the
              // unresolved placeholder and the dangling colon and the customer's
              // name never appeared at all. It also built " · <pharmacy>" here,
              // separator included — copy composed in Dart.
              // Both live in the backend now: two keys, and this file only
              // answers "is there a pharmacy", which is why both keys exist.
              row.pharmacy.isEmpty
                  ? cf('admin_customer.ordered_by', {'name': row.name})
                  : cf('admin_customer.ordered_by_with_pharmacy', {
                      'name': row.name,
                      'pharmacy': row.pharmacy,
                    }),
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
        // CHANGE #606 — two backend strings, side by side. Neither is glued to
        // the other with Dart punctuation, and either is skipped when empty.
        Row(children: [
          if (itemsLabel.isNotEmpty)
            Text(itemsLabel,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF374151))),
          if (amountLabel.isNotEmpty) ...[
            const SizedBox(width: 12),
            Text(amountLabel,
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827))),
          ],
        ]),
        // CHANGE #238 — the reconciliation banner. It says, in the backend's
        // own words, whether every customer item is accounted for: on a
        // purchase order, explicitly unfulfillable, or explicitly still under
        // inquiry. An order that does not add up says so here instead of
        // looking complete while items are missing downstream.
        _reconcileBanner(reconcile),
        const SizedBox(height: 8),
        if (!loaded) ..._itemSkeletons(),
        // CHANGE #382 — responsive per-item row: thumbnail + name/pack/company
        // /qty+price+status. CHANGE #238 drives every field off the backend
        // line; there is no orders.items JSONB and no name match left.
        ...panelLines.map((line) {
          final unfulfillable = line.isFlagged;
          final imageUrl   = line.imageUrl;
          final company    = line.company;
          final packLine   = line.packLabel;
          final qtyLabel   = line.qtyLabel;
          final priceText  = line.priceLabel;
          final name       = line.productName;
          final poWarning  = line.poWarning;
          final nextLabel  = line.nextSupplierLabel;

          // #625 — an unfulfilled item is tinted with the SAME status_colors
          // its chip uses, so the card and the chip cannot disagree about
          // which items we could not source.
          final rowColors = line.statusColors;
          return Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: unfulfillable
                  ? _hex(rowColors['bg'], const Color(0xFFFBE9E7))
                  : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: unfulfillable
                      ? _hex(rowColors['fg'], const Color(0xFFB42318))
                      : const Color(0xFFE5E7EB),
                  width: unfulfillable ? 1 : 0.5),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _custOrderItemThumb(imageUrl.isEmpty ? null : imageUrl,
                  isDesktop: isDesktop),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF111827))),
                    if (company.isNotEmpty) ...[
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
                    if (packLine.isNotEmpty) ...[
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
                        if (qtyLabel.isNotEmpty) _custOrderItemQtyPill(qtyLabel),
                        if (priceText.isNotEmpty)
                          Text(priceText,
                              style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF111827))),
                        _itemInquiryBadge(line.raw),
                        _itemSupplierBadge(line.raw),
                      ],
                    ),
                    // CHANGE #238 — who is next in the waterfall, and the loud
                    // case: an item assigned to a supplier that never reached
                    // that supplier's purchase order. Both are backend strings.
                    if (nextLabel.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(nextLabel, style: Ds.t.caption),
                    ],
                    if (poWarning.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(poWarning,
                          style: Ds.t.caption.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Ds.c.danger)),
                    ],
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
    return content;
  }

  /// CHANGE #238 — the reconciliation banner, printed exactly as
  /// order_reconcile() returned it. The app never counts the items itself and
  /// never decides whether an order balances: `label`, `detail` and the three
  /// tone colours all arrive in the payload.
  Widget _reconcileBanner(OrderItemPanelReconcile v) {
    if (!v.show) return const SizedBox.shrink();
    final r = v.raw;
    final label = v.label;
    final detail = v.detail;
    return Container(
      margin: EdgeInsets.only(top: Ds.space.x8),
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: _hex(r['bg'], Ds.c.brandSoft),
        borderRadius: Ds.r.rButton,
        border: Border.all(color: _hex(r['border'], Ds.c.divider), width: 0.5),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: _hex(r['fg'], Ds.c.text))),
        if (detail.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(detail,
              style: Ds.t.caption
                  .copyWith(color: _hex(r['fg'], Ds.c.textSecondary))),
        ],
      ]),
    );
  }

  /// CHANGE #238 — a skeleton while order_item_status_panel is in flight, so
  /// an expanding row never flashes an "no items" state it is about to
  /// contradict.
  List<Widget> _itemSkeletons() => List<Widget>.generate(
      3,
      (_) => Container(
            margin: EdgeInsets.only(top: Ds.space.x8),
            height: Ds.space.x48 + Ds.space.x24,
            decoration: BoxDecoration(
              color: Ds.c.bg,
              borderRadius: Ds.r.rButton,
            ),
          ));

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
              cf('admin_customer.cart_items_count', {'a': '${row.items.length}'}),
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF374151)),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _adminAddCartItem(row.userId),
              icon: const Icon(Icons.add, size: 14),
              label: Text(c('admin_customer.add_item'), style: const TextStyle(fontSize: 12)),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF1B7A43),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ]),
          const SizedBox(height: 6),
          if (row.items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(c('admin_customer.no_active_items'),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
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
                          child: _addedByBadge(item.addedByBadge)),
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
                              _addedByBadge(item.addedByBadge),
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
          // CMD #366 row 176 — the substitution panel. Om's rule is the whole
          // design: never auto-substitute. This asks the customer and shows
          // their answer; Apply is enabled only once the BACKEND says the
          // customer approved, and the backend refuses it otherwise even if
          // this button were somehow tapped.
          if (row.isOrder && row.orderId != null)
            _SubstitutePanel(orderId: row.orderId!),
          if (row.removedItems.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            const SizedBox(height: 8),
            Text(
              cf('admin_customer.removed_by_admin', {'n': '${row.removedItems.length}'}),
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

  /// CHANGE #599 — prints the backend's badge. No branch on addedBy, no
  /// label and no colour written here.
  static Color _hex(Object? v, Color fallback) {
    final h = (v ?? '').toString().replaceFirst('#', '').trim();
    if (h.length != 6) return fallback;
    final n = int.tryParse(h, radix: 16);
    return n == null ? fallback : Color(0xFF000000 | n);
  }

  static Widget _addedByBadge(Map<String, dynamic> badge) {
    final label = (badge['label'] ?? '').toString();
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: _hex(badge['bg'], const Color(0xFFF3F4F6)),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: _hex(badge['border'], const Color(0xFFD1D5DB))),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w600,
              color: _hex(badge['fg'], const Color(0xFF6B7280)))),
    );
  }

  Widget _buildCartTotalsFooter(bool isDesktop) {
    // #601 — footer totals are the server's; the screen no longer folds rows.
    final totalItems = _cartFooterLines;
    final totalValue = _cartFooterValue;

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
            // CMD #1886 — the stage chip. Word and tone are the backend's;
            // a row the payload has not described draws nothing.
            Padding(
                padding: EdgeInsets.only(right: Ds.space.x8),
                child: CustomerStageChip(chip: _metaFor(row.id)['chip'])),
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
                    gate: _metaFor(row.id)['approve'],
                    onFix: () => _openCustomerPage(row.id),
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
                  // CMD #1886 — the funnel stage, in the backend's own word.
                  CustomerStageChip(chip: _metaFor(row.id)['chip']),
                  SizedBox(width: Ds.space.x8),
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
                    gate: _metaFor(row.id)['approve'],
                    onFix: () => _openCustomerPage(row.id),
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
  // APPROVED CUSTOMERS view — replaced by the CHANGE #810 console.
  //
  // The tall card (desktop table row + mobile card, each with its own Edit /
  // Suspend / Delete buttons and an expanding detail panel) is gone. Its every
  // capability moved to the customer page: Edit is the backend-described edit
  // form, Suspend is Block-with-reason, Delete is Delete-with-reason, and the
  // expanded detail panel is the Info tab. See _buildCustomersConsole above.
  // ═══════════════════════════════════════════════════════════════════════════

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
    return DateLabels.instance.label(s, DateStyle.dmyHm2) ?? '';
  }

  static String _fmtTsUnused(dynamic v) {
    final s = _str(v);
    try {
      final dt = DateTime.parse(s);
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
        (c('admin_customer.phone'),         val(rawData['phone'])),
        ('Other Contact', val(rawData['other_contact_no'])),
      ]),
      ('LOCATION', [
        (c('admin_customer.address'),          val(rawData['address_local'] ?? rawData['address'])),
        (c('admin_customer.city'),             val(rawData['city'])),
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
            // CHANGE #1888 — the payment term is the one field on this panel a
            // human still decides, so it is the one that gets a control. Its
            // options, its copy and its refusal all come from
            // customer_payment_term_panel(); this button only opens it.
            if (_str(rawData['id']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x16),
              Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  height: 44,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Ds.c.brand),
                      shape: RoundedRectangleBorder(
                          borderRadius: Ds.r.rButton),
                    ),
                    icon: Icon(Icons.account_balance_wallet_outlined,
                        size: Ds.space.x16, color: Ds.c.brand),
                    label: Text(
                      c('customer_form.term_title'),
                      style: Ds.t.body.copyWith(color: Ds.c.brand),
                    ),
                    onPressed: () => CustomerPaymentTermSheet.open(
                        ctx, _str(rawData['id'])),
                  ),
                ),
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
          Text(c('admin_customer.leads_logged_in_subtitle'),
              style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          const SizedBox(height: 10),
          if (_loggedInLeads.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(c('admin_customer.leads_logged_in_empty'),
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
          Text(c('admin_customer.leads_other_subtitle'),
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
      // CHANGE #588 — admin_lead_save() owns insert-vs-update and the auth_uid
      // dedupe. The conditional onConflict was expressed in Dart, so two
      // admins saving the same lead could race; the server decides now.
      final res = await client.rpc('admin_lead_save', params: {
        'p_lead': <String, dynamic>{
          if (lead.leadsId != null) 'leads_id': lead.leadsId,
          'name':        lead.name,
          'email':       lead.email,
          'mobile':      lead.mobile,
          'source':      lead.source,
          if (status != null)     'status':      status,
          if (status == null)     'status':      lead.status,
          if (assignedTo != null) 'assigned_to': assignedTo,
          if (assignedTo == null) 'assigned_to': lead.assignedTo,
          if (lead.authUid != null) 'auth_uid': lead.authUid,
        },
      });
      final m = (res is List ? res.first : res) as Map;
      final newId = (m['id'] ?? '').toString();
      if (newId.isNotEmpty) lead.leadsId = newId;
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
    final res = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['csv'],
      withData: true,
    );
    final bytes = res?.files.isNotEmpty == true ? res!.files.first.bytes : null;
    if (bytes == null || !mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CsvImportDialog(
        fileBytes: bytes,
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
                      child: Text(c('admin_customer.no_deleted_customers'),
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
                      child: Text(c('admin_customer.badge_new_account_exists'),
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

// ── Order confirmation ────────────────────────────────────────────────────────
//
// CHANGE #608 — _ConfirmActions is DELETED.
//
// #607 wrote the accept/reject logic here, inside this screen. #608 needs the
// identical behaviour in the table's `type:"actions"` cell, and a second copy
// is how one surface ends up deciding something the other overwrites. The
// implementation moved to BackendActionsCell in widgets/backend_table.dart;
// this screen's mobile card and its desktop CONFIRMATION column both render
// that one widget, wired through _orderActionHandler below.

// ── Registration Approve / Reject ─────────────────────────────────────────────

class _RegApproveActions extends StatefulWidget {
  final String id;
  final Future<void> Function() onApprove;
  final Future<void> Function() onReject;

  /// CMD #1886 — customer_approve_gate(). The Approve button is NEVER hidden:
  /// when `can` is false it is disabled and carries the backend's own sentence
  /// ("Licence not verified", or the fields that are actually absent) plus a
  /// Fix link to the page that edits them. An absent gate leaves the button
  /// exactly as it was before this change.
  final dynamic gate;
  final VoidCallback? onFix;

  const _RegApproveActions(
      {required this.id,
      required this.onApprove,
      required this.onReject,
      this.gate,
      this.onFix});

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
    final gate = widget.gate is Map
        ? Map<String, dynamic>.from(widget.gate as Map)
        : const <String, dynamic>{};
    final blocked = gate.isNotEmpty && gate['can'] != true;
    final reason = (gate['reason'] ?? '').toString();
    final fixLabel = (gate['fix_label'] ?? '').toString();
    final fixField = (gate['fix_field_label'] ?? '').toString();

    final buttons = Row(mainAxisSize: MainAxisSize.min, children: [
      _btn('Approve', const Color(0xFF1B7A43),
          blocked ? null : () => _act(widget.onApprove)),
      const SizedBox(width: 4),
      _btn('Reject',  const Color(0xFFDC2626), () => _act(widget.onReject)),
    ]);
    if (!blocked || reason.isEmpty) return buttons;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        buttons,
        SizedBox(height: Ds.space.x4),
        Text(reason, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
        if (fixLabel.isNotEmpty && widget.onFix != null)
          InkWell(
            onTap: widget.onFix,
            child: Padding(
              padding: EdgeInsets.only(top: Ds.space.x4),
              child: Text(
                  fixField.isEmpty ? fixLabel : '$fixLabel: $fixField',
                  style: Ds.t.caption.copyWith(color: Ds.c.brand)),
            ),
          ),
      ],
    );
  }

  Widget _btn(String label, Color color, VoidCallback? onTap) => InkWell(
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
      // #596 — medicine_search_admin() resolves gst_percent through
      // gst_rate_for(), so search results, cart lines and product cards all
      // report the same rate.
      final raw = await Supabase.instance.client.rpc('medicine_search_admin',
          params: {'p_term': query.trim(), 'p_limit': 30});
      final rows = ((raw is List ? raw.first : raw) as Map)['rows'] as List? ?? const [];
      if (mounted) {
        setState(() {
          _results = List<Map<String, dynamic>>.from(rows);
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
      // CHANGE #577 — admin_cart_add() owns this entirely.
      //
      // CLAUDE.md names this violation by name: never .from('cart_items').
      // The old code SELECTed and then INSERTed/UPDATEd cart_items directly,
      // keyed on user_id (the LOGIN, not the account — the cart-vanishing
      // bug), merged the quantity itself
      //     newQty = wasRemoved ? qty : existing.quantity + qty
      // set the PRICE from the client ('price': mrp), invented defaults
      // (gst ?? 12, category ?? 'Other'), stamped updated_at from the DEVICE
      // clock, and wrote added_by: 'admin' as a literal rather than a person.
      //
      // The RPC takes only WHO, WHAT and HOW MANY. Price, MRP, GST, category,
      // pack size and manufacturer are read from MEDICINE server-side; the
      // quantity merge, the timestamp and the acting admin are resolved there
      // too. It also accepts either an account id or an auth user id and
      // resolves one to the other, because that is a backend question.
      final productId = item['id'].toString();
      await Supabase.instance.client.rpc('admin_cart_add', params: {
        'p_customer_id': widget.userId,
        'p_product_id': productId,
        'p_qty': _qty,
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _adding = false);
        showToast(context, e.toString().contains('column')
            ? c('admin_customer.toast_db_migration_required')
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
                  hintText: c('admin_customer.hint_search_medicine'),
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
                              ? c('admin_customer.search_medicine_prompt')
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

// ── Customer Edit Dialog — replaced by the CHANGE #810 backend-described form.
//
// The dialog held a const list of 23 (column, label, required) records: the
// field list, the labels and which one was mandatory were all Dart. They now
// live in admin_customer_edit_field and arrive from admin_customer_edit_form(),
// so adding a field to the customer form is an INSERT, not a deploy.

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
  final Uint8List fileBytes;
  final VoidCallback onImported;
  const _CsvImportDialog({required this.fileBytes, required this.onImported});

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
      final csvText = utf8.decode(widget.fileBytes, allowMalformed: true);

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
        await Supabase.instance.client
            .rpc('admin_import_leads_csv', params: {'p_rows': toInsert});
      }

      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        showToast(context, cf('admin_customer.imported_leads', {'n': '${toInsert.length}', 's': '${toInsert.length == 1 ? '' : 's'}'}));
      }
    } catch (e) {
      if (mounted) {
        setState(() { _step = _CsvStep.mapping; });
        showToast(context, cf('admin_customer.import_failed_e', {'e': '$e'}), isError: true);
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
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(c('admin_customer.close'))),
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
        Expanded(
          child: Text(c('admin_customer.map_csv_columns'),
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
      Text(c('admin_customer.gemini_automapped_hint'),
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
      Text(cf('admin_customer.rows_will_import', {'n': '${_dataRows.length}', 's': '${_dataRows.length == 1 ? '' : 's'}'}),
          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      const SizedBox(height: 16),

      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(c('admin_customer.cancel'), style: const TextStyle(color: Color(0xFF6B7280))),
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
        height: 44, // CHANGE #465: matches _CompactActionButton's height for the 50:50 row
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        alignment: Alignment.center,
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
            c('admin_customer.view_payment'),
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

// ── CHANGE #465: admin bill row actions ───────────────────────────────────────
// Self-contained: fetches customer_bill_file() itself, so the row knows
// whether to show "Upload Bill" or "View Bill" without the parent state
// tracking it. Row 1 is the exact 50:50 [Upload Bill / View Bill] | [View
// Payment] split; row 2 (Delete + the shared Download/WhatsApp/Share) only
// appears once a bill exists. Reuses the SAME upload_customer_bill RPC and
// customer-bills/<order_id>/... storage key #463/#464 established.

class _AdminBillRowActions extends StatefulWidget {
  final String orderId;
  final bool payOpen;
  final VoidCallback onViewPayTap;
  final VoidCallback? onViewPayLongPress;
  final VoidCallback? onBillChanged;
  const _AdminBillRowActions({
    super.key,
    required this.orderId,
    required this.payOpen,
    required this.onViewPayTap,
    this.onViewPayLongPress,
    this.onBillChanged,
  });

  @override
  State<_AdminBillRowActions> createState() => _AdminBillRowActionsState();
}

class _AdminBillRowActionsState extends State<_AdminBillRowActions> {
  Map<String, dynamic>? _info; // null while loading
  bool _uploading = false;
  bool _deleting = false;
  // #466: "View Bill" now toggles an inline preview+actions block (matching
  // the customer Bill tab's layout) instead of jumping straight to the
  // full-screen viewer — the preview/buttons must stay hidden until tapped.
  bool _viewBillOpen = false;

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

  bool get _hasFile => _info?['has_file'] == true;

  Future<void> _upload() async {
    if (_uploading) return;
    setState(() => _uploading = true);
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
        if (mounted) showToast(context, c('admin_customer.file_too_large'), isError: true);
        return;
      }
      // Namespaced by order_id so files can't collide across orders.
      final path = '${widget.orderId}/${DateTime.now().millisecondsSinceEpoch}_${picked.name}';
      await Supabase.instance.client.storage.from('customer-bills').uploadBinary(
            path,
            bytes,
            fileOptions: FileOptions(contentType: mimeFromBillName(picked.name)),
          );
      final raw = await Supabase.instance.client.rpc('upload_customer_bill', params: {
        'p_order_id': widget.orderId,
        'p_file_path': path,
        'p_file_name': picked.name,
        'p_bucket': 'customer-bills',
      });
      final res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (!mounted) return;
      if (res['status'] == 'ok') {
        showToast(context, c('admin_customer.bill_uploaded'));
        await _load();
        widget.onBillChanged?.call();
      } else {
        showToast(context, res['error']?.toString() ?? c('admin_customer.upload_bill_fail'), isError: true);
      }
    } catch (_) {
      if (mounted) showToast(context, c('admin_customer.upload_bill_fail'), isError: true);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _delete() async {
    if (_deleting || !_hasFile) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(c('admin_customer.delete_bill_q')),
        content: Text(
            c('admin_customer.delete_bill_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(c('admin_customer.cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(dCtx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      final raw = await Supabase.instance.client
          .rpc('delete_customer_bill', params: {'p_order_id': widget.orderId});
      final res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (!mounted) return;
      if (res['status'] == 'ok') {
        showToast(context, c('admin_customer.bill_deleted'));
        setState(() => _viewBillOpen = false);
        await _load();
        widget.onBillChanged?.call();
      } else {
        showToast(context, res['error']?.toString() ?? c('admin_customer.delete_bill_fail'), isError: true);
      }
    } catch (_) {
      if (mounted) showToast(context, c('admin_customer.delete_bill_fail'), isError: true);
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final loading = _info == null;
    final info = _info;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: _hasFile
              ? _CompactActionButton(
                  icon: Icons.receipt_long_outlined,
                  label: c('admin_customer.view_bill'),
                  onTap: () => setState(() => _viewBillOpen = !_viewBillOpen),
                )
              : _CompactActionButton(
                  icon: Icons.upload_outlined,
                  label: c('admin_customer.upload_bill'),
                  loading: _uploading,
                  onTap: loading ? null : _upload,
                ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _ViewPayBtn(
            isOpen: widget.payOpen,
            onTap: widget.onViewPayTap,
            onLongPress: widget.onViewPayLongPress,
          ),
        ),
      ]),
      // #466: preview + actions stay hidden until "View Bill" is tapped, and
      // when shown, preview comes FIRST with the action row BELOW it — same
      // order as the customer Bill tab.
      if (_hasFile && _viewBillOpen && info != null) ...[
        const SizedBox(height: 12),
        BillFilePreview(
          key: ValueKey('${widget.orderId}/${info['path']}'),
          bucket: info['bucket']?.toString() ?? 'customer-bills',
          path: info['path']?.toString() ?? '',
          name: info['name']?.toString() ?? 'Bill',
        ),
        const SizedBox(height: 12),
        Row(children: [
          GestureDetector(
            onTap: _deleting ? null : _delete,
            child: Container(
              height: 44,
              width: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                border: Border.all(color: const Color(0xFFFCA5A5)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _deleting
                  ? const SizedBox(
                      width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF991B1B)))
                  : const Icon(Icons.delete_outline, size: 18, color: Color(0xFF991B1B)),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: UploadedBillActionsRow(
              key: ValueKey('${widget.orderId}/${info['path']}'),
              orderId: widget.orderId,
              bucket: info['bucket']?.toString() ?? 'customer-bills',
              path: info['path']?.toString() ?? '',
              fileName: info['name']?.toString() ?? 'Bill',
            ),
          ),
        ]),
      ],
    ]);
  }
}

// Fixed-width/fixed-height action button (sits inside an Expanded 50% slot)
// with the spinner rendered INSIDE the same box while loading — the button
// never resizes, unlike #464's shrink-to-a-tiny-circle bug.
class _CompactActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool loading;
  final VoidCallback? onTap;
  const _CompactActionButton({
    required this.icon,
    required this.label,
    this.loading = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !loading;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFFF5F6F8),
          border: Border.all(color: const Color(0xFFD1D5DB)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: loading
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 15, color: const Color(0xFF374151)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
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
                      cf('admin_customer.advance_extra_adjusted', {'amt': _rupee(advanceCarry)}),
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
                    cf('admin_customer.paid_of', {'a': _rupee(received), 'b': _rupee(expected)}),
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
      if (mounted) showToast(context, c('admin_customer.open_bill_fail'), isError: true);
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
      downloadBytes(bytes, name, mimeFromBillName(name));
    } catch (_) {
      if (mounted) showToast(context, c('admin_customer.download_bill_fail'), isError: true);
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
  final Set<String> _signedUrlErrors = {};        // claimId → sign or image-load failed (CHANGE #474)
  final Map<String, int> _imgAttempt = {};        // claimId → retry attempt counter (CHANGE #474)
  LiveFeedHandle? _paymentChannel;

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
    // CHANGE #643: payment_claims is an admin list feed on the registry's
    // interval. No order_id filter, as before — an online claim can arrive with
    // order_id null and be linked later, so the RPC is what filters.
    LiveFeed.instance
        .watch(
          channelPrefix: 'payclaims_${widget.orderId}',
          tables: const ['payment_claims'],
          onChange: (_) {
            if (mounted) _load();
          },
        )
        .then((h) {
      if (!mounted) {
        h.dispose();
        return;
      }
      _paymentChannel?.unsubscribe();
      _paymentChannel = h;
    });
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
      await _signOneClaimProof(claim.claimId, claim.filePath!, claim.storageBucket);
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

  // CHANGE #474 — sign one claim's proof image. Bounded: sign failure/timeout
  // OR a load error (surfaced by NativeSignedImage.onError) both land in
  // _signedUrlErrors (never leaves the caller on an unbounded spinner).
  // A fresh cacheKey per attempt forces a real reload on retry.
  Future<void> _signOneClaimProof(String claimId, String filePath, String? storageBucket) async {
    RenderLog.write('c474_pay_img_widget', 1);
    try {
      final url = await PaymentClaimsService.signedScreenshotUrl(filePath,
          bucket: storageBucket);
      if (url == null) {
        if (mounted) setState(() => _signedUrlErrors.add(claimId));
        return;
      }
      if (!mounted) return;
      final attempt = (_imgAttempt[claimId] ?? 0) + 1;
      _imgAttempt[claimId] = attempt;
      setState(() {
        _signedUrlErrors.remove(claimId);
        _signedUrls[claimId] = url;
        // Now holds the per-attempt cacheKey for NativeSignedImage (not a viewType).
        _imgViewTypes[claimId] = 'claim-img-$claimId-$attempt';
      });
    } catch (_) {
      if (mounted) setState(() => _signedUrlErrors.add(claimId));
    }
  }

  void _retryClaimProof(PaymentClaim claim) {
    final path = claim.filePath;
    if (path == null || path.isEmpty) return;
    setState(() {
      _signedUrlErrors.remove(claim.claimId);
      _signedUrls.remove(claim.claimId);
      _imgViewTypes.remove(claim.claimId);
    });
    _signOneClaimProof(claim.claimId, path, claim.storageBucket);
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(c('admin_customer.cancel'))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43), foregroundColor: Colors.white),
            child: Text(c('admin_customer.mark_received')),
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
        SnackBar(content: Text(cf('admin_customer.failed_e', {'e': '$e'})), backgroundColor: const Color(0xFFDC2626)),
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
        title: Text(c('admin_customer.reject_payment'),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          decoration: InputDecoration(labelText: c('admin_customer.reason')),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(c('admin_customer.cancel'))),
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
        SnackBar(content: Text(c('admin_customer.payment_rejected')), backgroundColor: const Color(0xFF6B7280)),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(cf('admin_customer.reject_failed_e', {'e': '$e'})), backgroundColor: const Color(0xFFDC2626)),
      );
    } finally {
      if (mounted) setState(() => _acting.remove(claimId));
    }
  }

  void _showScreenshot(BuildContext ctx, String url) {
    RenderLog.write('c226_fullscreen', 1);
    openFullscreenImage(ctx, url);
  }

  /// CHANGE #396 — "reachable from any order". The order does not know which
  /// pharmacy it belongs to; `customer_360_for_order` answers that (and its own
  /// button label), and the 360 view opens on that pharmacy.
  Future<void> _openCustomer360() async {
    try {
      final raw = await Supabase.instance.client
          .rpc('customer_360_for_order', params: {'p_order_id': widget.orderId});
      final m = raw is Map
          ? Map<String, dynamic>.from(raw)
          : const <String, dynamic>{};
      final id = (m['customer_id'] ?? '').toString();
      if (!mounted) return;
      if (m['ok'] != true || id.isEmpty) {
        final msg = (m['message'] ?? '').toString();
        if (msg.isNotEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
        return;
      }
      RenderLog.write('c396_c360_from_order', 1);
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => AdminCustomer360Screen(customerId: id)));
    } catch (_) {
      // a failed lookup leaves the order panel exactly as it was
    }
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
            label: Text(c('admin_customer.add_cash_payment')),
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
          // CHANGE #396 — every order is a door into the pharmacy behind it.
          TextButton.icon(
            onPressed: _openCustomer360,
            icon: Icon(Icons.person_search, size: Ds.space.x16),
            label: Text(c('c360.open_from_order'), style: Ds.t.caption),
          ),
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
            Expanded(child: Text(cf('admin_customer.error_e', {'e': '$_error'}),
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
          label: c('admin_customer.all'),
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
              Text(c('admin_customer.advance_payment'),
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
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.check_circle, size: 14, color: Colors.white),
                      SizedBox(width: 5),
                      Text(c('admin_customer.ready_to_accept'),
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
            Expanded(
              child: Text(c('admin_customer.remaining_balance'),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
                      color: Color(0xFF9CA3AF))),
            ),
            if (isSettled)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: const Color(0xFFD1FAE5),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(c('admin_customer.fully_settled'),
                    style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                        color: Color(0xFF065F46))),
              ),
          ]),
          const SizedBox(height: 4),
          Text(cf('admin_customer.amt_left', {'amt': _rupee(remaining)}),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                  color: isSettled ? const Color(0xFF065F46) : const Color(0xFF111827))),
          const SizedBox(height: 2),
          Text(cf('admin_customer.of_total', {'amt': _rupee(d.totalValue)}),
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
              Text(c('admin_customer.cash_vs_online'),
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
              // CHANGE #634: from map_config.point_deeplink, not a literal.
              // Keyless — the Google Maps app link never touches the JS API.
              // MapConfigService is warmed when the session loads, so `cached`
              // is populated long before this row can be tapped.
              final mapsUrl = MapConfigService.cached
                      ?.pointUrl(claim.locationLat!, claim.locationLng!) ??
                  '';
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
                          onTap: () async {
                            // Warmed at session load; the await is only for the
                            // rare first-paint window before the config lands.
                            final url = mapsUrl.isNotEmpty
                                ? mapsUrl
                                : (await MapConfigService.load()).pointUrl(
                                    claim.locationLat!, claim.locationLng!);
                            if (url.isEmpty) return;
                            try { launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication); } catch (_) {}
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.location_on, size: 18, color: Color(0xFF1A73E8)),
                              SizedBox(width: 6),
                              Text(c('admin_customer.view_in_maps'),
                                style: TextStyle(color: Color(0xFF1A73E8),
                                    fontWeight: FontWeight.w600, fontSize: 14)),
                            ]),
                          ),
                        ),
                        InkWell(
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: locAddr));
                            ScaffoldMessenger.of(mCtx).showSnackBar(
                              SnackBar(content: Text(c('admin_customer.address_copied')),
                                  duration: const Duration(seconds: 1)),
                            );
                          },
                          borderRadius: BorderRadius.circular(8),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8F5E9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.copy_rounded, size: 16, color: Color(0xFF1B7A43)),
                              SizedBox(width: 6),
                              Text(c('admin_customer.copy'), style: const TextStyle(color: Color(0xFF1B7A43),
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
                // CHANGE #474 — bounded: a sign/load failure lands here as a
                // tappable retry, never an unbounded spinner.
                final errored = _signedUrlErrors.contains(claim.claimId);
                return GestureDetector(
                  onTap: errored ? () => _retryClaimProof(claim) : null,
                  child: Container(
                    width: double.infinity, height: 120,
                    decoration: BoxDecoration(
                        color: const Color(0xFFF3F4F6),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE5E7EB))),
                    child: Center(
                      child: errored
                          ? Column(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.refresh, size: 20, color: Color(0xFF9CA3AF)),
                              SizedBox(height: 4),
                              Text(c('admin_customer.proof_load_fail'),
                                  style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7280)),
                                  textAlign: TextAlign.center),
                            ])
                          : const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  ),
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
                        child: NativeSignedImage(
                          url: url ?? '',
                          cacheKey: vt,
                          onTap: () => openFullscreenImage(ctx, url ?? ''),
                          onError: () {
                            if (!mounted) return;
                            setState(() {
                              _signedUrls.remove(claim.claimId);
                              _imgViewTypes.remove(claim.claimId);
                              _signedUrlErrors.add(claim.claimId);
                            });
                          },
                        ),
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
                      ? Text(c('admin_customer.missing_claim_id'),
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

  // CHANGE #242: native share through the platform-conditional download_bytes
  // wrapper — Web Share API (file) on web, share_plus on Android. Falls back to
  // opening/downloading the URL when a native share sheet isn't available.
  Future<void> sharePaymentImage(String signedUrl, BuildContext ctx) async {
    if (signedUrl.isEmpty) return;

    // PRIMARY: fetch the bytes and hand them to the native share sheet.
    try {
      final resp = await http.get(Uri.parse(signedUrl));
      if (resp.statusCode == 200) {
        final ct = resp.headers['content-type'] ?? 'image/jpeg';
        final shared =
            await shareBytes(resp.bodyBytes, 'payment.png', ct, text: 'Payment proof');
        // true = shared, false = user cancelled — either way the sheet handled it.
        if (shared != null) {
          try { RenderLog.write('c242_share_invoked', 'path=file'); } catch (_) {}
          return;
        }
        // null = no native share on this platform → fall through to URL open.
      }
    } catch (_) {}

    // FALLBACK: open/download the image URL externally.
    try {
      downloadUrl(signedUrl, 'payment.png');
      try { RenderLog.write('c242_share_invoked', 'path=opentab'); } catch (_) {}
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: Text(c('admin_customer.opening_image')),
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
                content: Text(cf('admin_customer.copied_v', {'v': '$v'}),
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

  // CHANGE #548: backend-formatted (ist_fmt 'dmy2_time12'); only the
  // lower-casing of AM/PM happens here, which is a case transform.
  String _fmtDate(String raw) {
    final t = DateLabels.instance.label(raw, DateStyle.dmy2Time12);
    if (t == null) return '';
    final stamp = t.toLowerCase();
    RenderLog.write('c246_received_compact', stamp);
    return stamp;
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
  /// #643 — the STORAGE bucket this proof lives in, named by
  /// admin_order_payment_view. Distinct from [bucket], which is the
  /// advance/rest grouping — an unfortunate collision, hence the longer name.
  final String? storageBucket;
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
    this.storageBucket,
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
      storageBucket:  m['bucket'] as String?,
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
        final raw = await Supabase.instance.client
            .rpc('admin_pending_orders_for_user',
                 params: {'p_user_id': widget.userId});
        final m0 = (raw is List ? raw.first : raw) as Map;
        for (final r in (m0['rows'] as List<dynamic>? ?? const [])) {
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
          setState(() {
            _signedUrls[imageId] = url;
            // Cache key for NativeSignedImage (was an HtmlElementView viewType).
            _imgViewTypes[imageId] = 'wa-img-$imageId';
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
        if (mounted) showToast(scaffoldCtx, c('admin_customer.toast_convert_start_failed'), isError: true);
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
            Text(c('admin_customer.whatsapp_orders'),
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
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Row(children: [
              SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Text(c('admin_customer.loading'), style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            ]),
          )
        else if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text(cf('admin_customer.error_e', {'e': '$_error'}),
                style: const TextStyle(fontSize: 12, color: Color(0xFF991B1B))),
          )
        else if (_data == null || _data!['found'] != true)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Text(c('admin_customer.no_wa_images'),
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
            label: c('admin_customer.all'),
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
                label: cf('admin_customer.order_idx', {'n': '${idx + 1}'}),
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
              ? NativeSignedImage(
                  url: _signedUrls[imageId] ?? '',
                  cacheKey: vt,
                  onTap: () =>
                      openFullscreenImage(context, _signedUrls[imageId] ?? ''),
                )
              : const Center(child: SizedBox(
                  width: 24, height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        ),
        if (leadCode != null) ...[
          const SizedBox(height: 8),
          Row(children: [
            Text(cf('admin_customer.lead_code', {'code': '$leadCode'}),
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF4338CA), fontFamily: 'monospace')),
            if (isDone && convertedCode != null) ...[
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.arrow_forward, size: 11, color: Color(0xFF9CA3AF)),
              ),
              Text(cf('admin_customer.order_converted_code', {'code': '$convertedCode'}),
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFF065F46), fontFamily: 'monospace')),
            ] else
              Padding(
                padding: EdgeInsets.only(left: 6),
                child: Text(c('admin_customer.not_yet_converted'),
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
                        ? Row(
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
                              Text(c('admin_customer.opening'),
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF92400E))),
                            ],
                          )
                        : Text(c('admin_customer.convert_to_order'),
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
  String? _imgUrl;
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
      setState(() => _imgUrl = url);
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
        Text(cf('admin_customer.order_seq', {'seq': '${img.orderSeq}'}),
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
              ? Center(
                  child: Text(c('admin_customer.photo_load_fail'),
                      style: TextStyle(fontSize: 12, color: Color(0xFF991B1B))))
              : (_imgUrl != null
                  ? NativeSignedImage(
                      url: _imgUrl!,
                      cacheKey: 'lead-img-${widget.image.id}',
                      onTap: () {
                        RenderLog.write('co_img_zoom_369', 'lead_image:${widget.image.id}');
                        openFullscreenImage(context, _imgUrl!);
                      },
                      onError: () {
                        if (mounted) setState(() => _error = 'load');
                      },
                    )
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
              label: Text(_converting ? c('admin_customer.opening') : 'Convert',
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

class _LeadCategoryNode {
  final String key;
  final String label;
  final List<String> googleTypes;
  final List<_LeadCategoryNode> sub;

  const _LeadCategoryNode({
    required this.key,
    required this.label,
    required this.googleTypes,
    required this.sub,
  });

  factory _LeadCategoryNode.fromMap(Map<String, dynamic> m) => _LeadCategoryNode(
        key: m['key']?.toString() ?? '',
        label: m['label']?.toString() ?? '',
        googleTypes:
            ((m['google_types'] as List?) ?? const []).map((e) => e.toString()).toList(),
        sub: ((m['sub'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => _LeadCategoryNode.fromMap(Map<String, dynamic>.from(e)))
            .toList(),
      );

  /// Every google type this branch can contribute — its own plus its subs'.
}

List<_LeadCategoryNode> _parseCategoryTree(dynamic raw) => (raw as List? ?? const [])
    .whereType<Map>()
    .map((e) => _LeadCategoryNode.fromMap(Map<String, dynamic>.from(e)))
    .toList();

Future<List<_LeadCategoryNode>> _fetchCategoryTree(String use) async {
  final res = await Supabase.instance.client
      .rpc('lead_category_tree', params: {'p_use': use});
  return _parseCategoryTree(res);
}

// CMD #1868 — the class taxonomy that used to live here (_sLeadClassLabels /
// _sLeadClassOrder) is GONE. Chips, their order, their labels and their counts
// now arrive from sleads_filters(); adding Hospital / Lab was a deploy, and is
// now one INSERT. See lib/screens/admin/sleads_filter_bar.dart.

const List<String> _sLeadActiveStatuses = ['planning', 'running', 'paused_budget'];

class _SLeadsTab extends StatefulWidget {
  final bool isDesktop;
  final ValueChanged<int> onTotalChanged;

  /// CMD #1868 — the tab's caption, whole, from sleads_count() for the SAME
  /// filters the list is showing. "S Leads (12)" is the backend's sentence.
  final ValueChanged<String> onCountChip;
  const _SLeadsTab({
    required this.isDesktop,
    required this.onTotalChanged,
    required this.onCountChip,
  });

  @override
  State<_SLeadsTab> createState() => _SLeadsTabState();
}

class _SLeadsTabState extends State<_SLeadsTab> {
  // ── Scrape form (CHANGE #552 — every option comes from
  //    scrape_form_options(); nothing below is a hardcoded list) ──────────
  Map<String, dynamic> _form = const {};
  List<_LeadCategoryNode> _cats = const [];
  String _mode = '';
  String _level = '';
  String? _sourceRunId;
  final Set<String> _include = {};
  final Set<String> _exclude = {};
  final Set<String> _expandedCats = {};
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _budgetCtrl = TextEditingController();
  bool _starting = false;
  String? _formError;
  Map<String, dynamic>? _monthUsage;

  List<Map<String, dynamic>> _mapList(dynamic raw) => (raw as List? ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  List<Map<String, dynamic>> get _modes => _mapList(_form['modes']);
  List<Map<String, dynamic>> get _levels => _mapList(_form['levels']);
  List<Map<String, dynamic>> get _sources => _mapList(_form['sources']);
  List<Map<String, dynamic>> get _resultActions => _mapList(_form['result_actions']);
  Map<String, dynamic> get _selection => _form['selection'] is Map
      ? Map<String, dynamic>.from(_form['selection'] as Map)
      : const {};
  Map<String, dynamic> get _maxCalls => _form['max_calls'] is Map
      ? Map<String, dynamic>.from(_form['max_calls'] as Map)
      : const {};

  /// Applies the form payload: options, plus the backend's own defaults for
  /// mode / level / max calls. Never invents a fallback value in Dart.
  void _applyFormOptions(Map<String, dynamic> f) {
    _form = f;
    _cats = _parseCategoryTree(f['categories']);
    if (_mode.isEmpty && _modes.isNotEmpty) _mode = _modes.first['key']?.toString() ?? '';
    if (_level.isEmpty && _levels.isNotEmpty) _level = _levels.first['key']?.toString() ?? '';
    if (_budgetCtrl.text.isEmpty) {
      final d = _maxCalls['default'];
      if (d != null) _budgetCtrl.text = d.toString();
    }
    final quota = f['quota'];
    if (quota is Map) _monthUsage = Map<String, dynamic>.from(quota);
  }

  // ── Saved scrapes (scrape_runs_list) ───────────────────────────────────
  List<Map<String, dynamic>> _runs = [];
  final Set<String> _expandedRuns = {};
  final Set<String> _runBusy = {};

  // ── Result selection (scrape_results_bulk needs a run scope) ───────────
  /// null = the whole Scraped-leads list (get_scraped_leads). Non-null = one
  /// run's own results, listed from scrape_run_export().leads so that
  /// "Keep selected" means "keep these, drop the rest OF THIS RUN".
  String? _resultsRunId;
  List<Map<String, dynamic>> _runLeads = [];
  bool _runLeadsLoading = false;
  /// CMD #1869 — the tested model (SLeadsSelection) IS the selection: the
  /// screen holds no second copy of these rules.
  final SLeadsSelection _leadSelection = SLeadsSelection();
  Set<int> get _selectedLeadIds => _leadSelection.ids;
  bool get _selectMode => _leadSelection.mode;
  bool _bulkBusy = false;

  // ── CMD #1869 — S Leads bulk lane ─────────────────────────────────────
  /// Multi-select is entered by long-pressing a card (or Select all) and left
  /// by Clear. Every label below comes from lead_leads_summary().bulk.
  /// The "Archived" view is a FILTER (CMD #1868's canonical map), so the
  /// existing filter row draws its toggle and a saved view can carry it.
  bool get _archivedFilter => SLeadsBulk.isArchivedView(_fs.value);

  /// The toolbar's copy rides the page envelope (sleads_page().bulk), falling
  /// back to the summary's copy of the SAME block before the first page lands.
  SLeadsBulk get _bulkUi {
    final fromPage = _leadPage.meta['bulk'];
    if (fromPage is Map) return SLeadsBulk(Map<String, dynamic>.from(fromPage));
    final fromSummary = _summary?['bulk'];
    if (fromSummary is Map) {
      return SLeadsBulk(Map<String, dynamic>.from(fromSummary));
    }
    return const SLeadsBulk(<String, dynamic>{});
  }

  Map<String, dynamic> get _bulk => _bulkUi.payload;

  List<Map<String, String>> get _bulkClasses => _bulkUi.classes;

  String _bulkLabel(String key, {int? n}) => _bulkUi.label(key, n: n);

  // ── CHANGE #552 — scrape_lead_card() cache, one call per lead ──────────
  final Map<int, Map<String, dynamic>> _leadCards = {};
  final Set<int> _leadCardsInFlight = {};
  final Set<int> _leadCardsFailed = {};

  // ── Active run / progress ─────────────────────────────────────────────
  String? _activeRunId;
  String? _activeRunLevel;
  List<String> _activeRunTypeLabels = [];
  Map<String, dynamic>? _runStatus;
  LiveFeedHandle? _runChannel;
  Timer? _pollTimer;
  bool _resuming = false;

  // ── Results / filters ─────────────────────────────────────────────────
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> get _rows => _leadPage.rows;
  bool _rowsLoading = false;
  String? _cityFilter;

  // ── CMD #1868 — ONE filter map, the shape _sleads_filters_norm() returns.
  // It is what sleads_page() / sleads_count() / sleads_filters() are called
  // with and what a saved view stores, so save -> apply is a round-trip with
  // nothing translated in Dart.
  SLeadsFilterState _fs = const SLeadsFilterState();
  SLeadsFilterModel _filterModel = const SLeadsFilterModel({});
  static const SLeadsFilterService _filterSvc = SLeadsFilterService();
  bool _filterBusy = false;
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  // CHANGE #1867 — 50-row pages, appended by infinite scroll. The old value
  // was 100 rows built EAGERLY, each with a network photo and its own
  // scrape_lead_card() call; that, not the 107-250 ms RPC, was the jank.
  static const int _pageSize = 50;
  /// sleads_page()'s rows + its envelope (count_label / empty_label /
  /// more_label / end_label / has_more / next_offset). PagedList owns the two
  /// paging decisions; see lib/screens/admin/leads_paging.dart.
  PagedList _leadPage = const PagedList();

  /// CMD #1871 — which collapsed rows have their branch list open. The rows
  /// themselves come from scrape_lead_card(); this only remembers the taps.
  final Set<int> _expandedBranchIds = {};
  bool _moreLoading = false;
  /// The results list scrolls in its own viewport so ListView.builder is
  /// genuinely lazy (a shrinkWrap list inside the page's SingleChildScrollView
  /// builds every row, which is the bug). This controller drives the append.
  final ScrollController _resultsCtrl = ScrollController();

  // ── CHANGE #443 (part 2) — row expand + get_lead_detail cache ──────────
  final Set<int> _expandedIds = {};
  final Map<int, Map<String, dynamic>> _leadDetailCache = {};
  final Set<int> _detailLoading = {};

  // ── Past runs / enrichment ───────────────────────────────────────────
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
  /// CHANGE #548: RAW backend timestamp, verbatim.
  String? _hubUpdatedAt;
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
    _resultsCtrl.addListener(_onResultsScroll);
    _bootstrap();
  }

  /// CHANGE #1867 — infinite scroll: within 400 px of the end, append the
  /// next 50. Guarded by _moreLoading so a fling fires one fetch, not ten.
  void _onResultsScroll() {
    if (!_resultsCtrl.hasClients) return;
    final pos = _resultsCtrl.position;
    if (pos.pixels >= pos.maxScrollExtent - 400) _loadMore();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _resultsCtrl.removeListener(_onResultsScroll);
    _resultsCtrl.dispose();
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

  /// CMD #1877 — the `strip` block of route_day_summary(): the SAME payload
  /// the Routes tab's day-summary card draws, rendered here as one line. Leads
  /// are what the field team works, so the tab that lists them says what today
  /// did to them. Nothing is recomputed — the strip is printed verbatim.
  RouteDayStrip? _fieldStrip;

  Future<void> _bootstrap() async {
    setState(() {
      _initialLoading = true;
      _loadError = null;
    });
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait<dynamic>([
        client.rpc('admin_lead_type_map'),
        client.rpc('lead_leads_summary', params: {'p_city': null}),
        // CHANGE #552 — one call now carries the title, modes, levels, the
        // category tree, the include/exclude labels, the saved-run sources,
        // the max-calls bounds, the quota and the submit/result labels.
        client.rpc('scrape_form_options'),
        client.rpc('scrape_runs_list', params: {'p_limit': 50}),
        client.rpc('lead_enrich_status', params: {'p_run_id': null}),
        // CHANGE #447 — warehouse (hub) card
        client.rpc('lead_get_hub'),
        // CMD #1877 — the field day, same RPC as the Routes tab. Caught on its
        // own: a caller it does not serve loses the strip, never the tab.
        client.rpc('route_day_summary').catchError((_) => null),
      ]);

      // #593 — admin_lead_type_map() returns {rows, count}; rows are already
      // active-filtered and sort_order-ordered by the backend. CMD #1870 — the
      // screen no longer keeps them: mapping chips to Google types moved into
      // lead_scrape_start(). The count still proves the map loaded.
      final types = (((results[0] is List ? results[0].first : results[0]) as Map)['rows']
              as List<dynamic>? ?? const []);
      final summary = Map<String, dynamic>.from(results[1] as Map);
      final form = Map<String, dynamic>.from(results[2] as Map);
      final runs = (results[3] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final enrichStatus = Map<String, dynamic>.from(results[4] as Map);
      final hub = Map<String, dynamic>.from(results[5] as Map);
      final field = results[6] is Map
          ? RouteDaySummary.from(Map<String, dynamic>.from(results[6] as Map)).strip
          : null;
      _fieldStrip = field;
      RenderLog.write('c1877_leads_strip', field?.has == true ? 1 : 0);

      RenderLog.write('c443_types_loaded', types.length);
      RenderLog.write('c443_summary_total', (summary['total'] as num?)?.toInt() ?? 0);
      RenderLog.write('c443_enriched', (enrichStatus['enriched'] as num?)?.toInt() ?? 0);
      RenderLog.write('c443_runs_rows', runs.length);
      RenderLog.write('c552_form_modes', (form['modes'] as List?)?.length ?? 0);
      RenderLog.write('c552_categories', (form['categories'] as List?)?.length ?? 0);
      RenderLog.write('c552_sources', (form['sources'] as List?)?.length ?? 0);
      RenderLog.write('c552_runs', runs.length);

      if (!mounted) return;
      setState(() {
        _summary = summary;
        _applyFormOptions(form);
        _runs = runs;
        _enrichStatus = enrichStatus;
        _initialLoading = false;
        _applyHubMap(hub);
      });
      RenderLog.write('c552_month_used', (_monthUsage?['used'] as num?)?.toInt() ?? 0);
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
        // CHANGE #552 — scrape_runs_list() ships the joined label itself.
        _activeRunTypeLabels = [
          if ((active['types_label']?.toString() ?? '').isNotEmpty)
            active['types_label'].toString()
        ];
        _refreshStatus();
        _startPolling();
        if (_activeRunId != null) _subscribeToRun(_activeRunId!);
      }

      await Future.wait([_loadRows(reset: true), _refreshFilterModel()]);
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
    _hubUpdatedAt = h['updated_at']?.toString();
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

  // CHANGE #548: backend-formatted (ist_fmt 'dmy_hm').
  String _fmtUpdatedAt(String? ts) =>
      DateLabels.instance.label(ts, DateStyle.dmyHm) ?? '—';

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
        title: Text(c('admin_customer.update_warehouse_q')),
        content: Text('This recalculates delivery zones and route start points '
            'for all $total leads. Continue?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, false),
            child: Text(c('admin_customer.cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            onPressed: () => Navigator.pop(dCtx, true),
            child: Text(c('admin_customer.update_warehouse_btn')),
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
      final pos = await geo.getCurrentPosition(enableHighAccuracy: false);
      final lat = pos?.lat;
      final lng = pos?.lng;
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

  Future<void> _refreshSummaryAndUsage() async {
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait<dynamic>([
        client.rpc('lead_leads_summary', params: {'p_city': null}),
        // CHANGE #552 — the quota now rides along with the form options, so a
        // refresh re-reads the whole option set (sources[] grows after a run).
        client.rpc('scrape_form_options'),
        client.rpc('lead_enrich_status', params: {'p_run_id': null}),
      ]);
      final summary = Map<String, dynamic>.from(results[0] as Map);
      final form = Map<String, dynamic>.from(results[1] as Map);
      final enrichStatus = Map<String, dynamic>.from(results[2] as Map);
      RenderLog.write('c443_summary_total', (summary['total'] as num?)?.toInt() ?? 0);
      RenderLog.write('c443_enriched', (enrichStatus['enriched'] as num?)?.toInt() ?? 0);
      if (!mounted) return;
      setState(() {
        _summary = summary;
        _applyFormOptions(form);
        _enrichStatus = enrichStatus;
      });
      widget.onTotalChanged((summary['total'] as num?)?.toInt() ?? 0);
    } catch (_) {}
  }

  Future<void> _loadPastRuns() async {
    try {
      final res = await Supabase.instance.client
          .rpc('scrape_runs_list', params: {'p_limit': 50}) as List;
      final runs = res.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      RenderLog.write('c443_runs_rows', runs.length);
      RenderLog.write('c552_runs', runs.length);
      if (!mounted) return;
      setState(() {
        _runs = runs;
      });
    } catch (_) {}
  }

  // ── Results ────────────────────────────────────────────────────────────

  // CHANGE #1867 — 300 ms, and it resets to page 1: a keystroke can never
  // append someone else's page onto the list it is filtering.
  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce =
        Timer(const Duration(milliseconds: 300), () => _loadRows(reset: true));
  }

  /// CHANGE #1867 — ONE page of sleads_page(). `reset` starts at offset 0 and
  /// replaces the list; otherwise the payload's own next_offset is appended.
  /// Every label on screen is the envelope's; nothing is composed here.
  Future<void> _loadRows({bool reset = false}) async {
    final offset = _leadPage.offsetFor(reset: reset);
    setState(() {
      if (reset) {
        _rowsLoading = true;
      } else {
        _moreLoading = true;
      }
    });
    try {
      final search = _searchCtrl.text.trim();
      final res = await Supabase.instance.client.rpc('sleads_page', params: {
        'p_filters': _effectiveFilters(search),
        'p_limit': _pageSize,
        'p_offset': offset,
      });
      final env = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final before = reset ? 0 : _leadPage.rows.length;
      if (!mounted) return;
      setState(() {
        _leadPage = _leadPage.applyPage(env, reset: reset);
        _rowsLoading = false;
        _moreLoading = false;
      });
      final page = _leadPage.rows.length - before;
      RenderLog.write('c1867_page_rows', page);
      RenderLog.write('c1867_loaded_rows', _leadPage.rows.length);
      RenderLog.write('c443_rows_rendered', page);
      RenderLog.write('c443_total_count', _leadPage.total);
      RenderLog.write('c443_rows', page);
      // CMD #1871 — proof the collapse reached the screen, not just the RPC.
      RenderLog.write('c1871_rows', _leadPage.rows.length);
      RenderLog.write(
          'c1871_branch_chips',
          _leadPage.rows
              .where((r) => (r['branches_label'] as String?)?.isNotEmpty == true)
              .length);
      RenderLog.write('c1871_show_all', _fs.toggle('show_all_branches') ? 1 : 0);
    } catch (e) {
      if (mounted) {
        setState(() {
          _rowsLoading = false;
          _moreLoading = false;
        });
        showToast(context, cf('admin_customer.load_leads_fail_e', {'e': '$e'}), isError: true);
      }
    }
  }

  /// Append the next page. The BACKEND decides there is one (has_more +
  /// next_offset); the client never guesses from a list length.
  void _loadMore() {
    if (_moreLoading || _rowsLoading || !_leadPage.canLoadMore) return;
    if (_resultsRunId != null) return; // a run's own set is not paged
    _loadRows();
  }

  /// The filter map actually sent: the canonical state plus the two controls
  /// the screen still owns (the city dropdown and the search box).
  Map<String, dynamic> _effectiveFilters([String? search]) => _fs
      .withCity(_cityFilter)
      .withSearch(search ?? _searchCtrl.text)
      .value;

  /// CMD #1868 — one filter change: re-read the rows AND the chip model
  /// (counts, which chip is lit, the score caption, the count chip). Every one
  /// of those is the backend's answer to the SAME map.
  ///
  /// CHANGE #1867's 300 ms debounce is kept: tapping three chips in a row is
  /// one fetch, not three.
  void _applyFilters(SLeadsFilterState next) {
    setState(() => _fs = next);
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _loadRows(reset: true);
      _refreshFilterModel();
    });
  }

  Future<void> _refreshFilterModel() async {
    final sent = _effectiveFilters();
    try {
      final results = await Future.wait([
        _filterSvc.filters(sent),
        _filterSvc.count(sent),
      ]);
      if (!mounted) return;
      final model = SLeadsFilterModel.fromPayload(results[0]);
      setState(() {
        _filterModel = model;
        // The backend normalised the map (defaults filled in); adopt its
        // version so the next call round-trips exactly what it sent back.
        if (model.filters.isNotEmpty) _fs = model.state;
      });
      final chip = results[1]['count_chip']?.toString() ?? model.countChip;
      widget.onCountChip(chip);
      RenderLog.write('c1868_chips', model.chips.length);
      RenderLog.write('c1868_toggles', model.toggles.length);
      RenderLog.write('c1868_views', model.viewItems.length);
      RenderLog.write('c1868_count_chip', chip);
    } catch (_) {
      // A failed filter read leaves the last good model on screen; the list
      // itself reports its own error.
    }
  }

  void _changeFilters({String? city, bool cityIsAll = false}) {
    if (cityIsAll) _cityFilter = null;
    if (city != null) _cityFilter = city;
    _applyFilters(_fs);
  }

  // ── CMD #1868 — saved views ─────────────────────────────────────────────

  Future<void> _saveView() async {
    final ctrl = TextEditingController();
    final views = _filterModel.views;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(views['save_label']?.toString() ?? ''),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: views['name_hint']?.toString()),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(c('admin_customer.cancel'))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(views['save_label']?.toString() ?? '')),
        ],
      ),
    );
    if (name == null || !mounted) return;
    await _runViewRpc(() => _filterSvc.saveView(name, _effectiveFilters()));
  }

  Future<void> _applyView(int id) async {
    final res = await _runViewRpc(() => _filterSvc.applyView(id));
    if (res == null || res['ok'] != true) return;
    _applyFilters(SLeadsFilterState.fromPayload(res['filters']));
  }

  Future<void> _deleteView(int id) async =>
      _runViewRpc(() => _filterSvc.deleteView(id));

  /// Every saved-view RPC answers with its own message and the fresh list;
  /// this prints both verbatim and never composes a sentence.
  Future<Map<String, dynamic>?> _runViewRpc(
      Future<Map<String, dynamic>> Function() call) async {
    if (_filterBusy) return null;
    setState(() => _filterBusy = true);
    try {
      final res = await call();
      if (!mounted) return res;
      setState(() => _filterBusy = false);
      final msg = res['message']?.toString();
      if (msg != null && msg.isNotEmpty) {
        showToast(context, msg, isError: res['ok'] != true);
      }
      await _refreshFilterModel();
      return res;
    } catch (e) {
      if (mounted) {
        setState(() => _filterBusy = false);
        showToast(context, '$e', isError: true);
      }
      return null;
    }
  }


  // ── Scrape control ────────────────────────────────────────────────────

  bool get _isRescrape => _mode == 'rescrape';

  /// The saved run chosen as a re-scrape source, matched back into
  /// scrape_runs_list() so its city/level/types can be replayed.
  Map<String, dynamic>? get _sourceRun {
    if (_sourceRunId == null) return null;
    for (final r in _runs) {
      if (r['run_id']?.toString() == _sourceRunId) return r;
    }
    return null;
  }

  // CMD #1870 — _effectiveGoogleTypes() and _resolveUiTypes() are GONE.
  // They turned the tray selection into ui_types in Dart, which meant the
  // screen had to know what a Google place type is and which parent implies
  // which child. lead_scrape_start() now takes the chip keys themselves and
  // resolves them against lead_categories, so the same rule also decides
  // which places are allowed back in (lead_scrape_finish_cell).

  int? get _budgetValue {
    final n = int.tryParse(_budgetCtrl.text.trim());
    if (n == null) return null;
    final min = (_maxCalls['min'] as num?)?.toInt();
    final max = (_maxCalls['max'] as num?)?.toInt();
    if (min != null && n < min) return null;
    if (max != null && n > max) return null;
    return n;
  }

  bool get _canScrape {
    if (_starting || _activeRunId != null) return false;
    if (_budgetValue == null) return false;
    if (_isRescrape) return _sourceRun != null;
    return _include.isNotEmpty && _nameCtrl.text.trim().isNotEmpty;
  }

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

  /// CMD #1870 — the labels of the Include chips the admin actually tapped,
  /// read straight out of lead_category_tree(). Picking a label off the
  /// payload is not a decision; deciding which Google types it stands for is,
  /// and that now happens in lead_scrape_start().
  List<String> _includeChipLabels() {
    final out = <String>[];
    for (final c in _cats) {
      if (_include.contains(c.key)) out.add(c.label);
      for (final sub in c.sub) {
        if (_include.contains(sub.key)) out.add(sub.label);
      }
    }
    return out;
  }

  Future<void> _startScrape() async {
    final src = _isRescrape ? _sourceRun : null;

    // Re-scrape replays the saved run's own area; a fresh scrape uses the
    // typed City/District. Categories chosen in the trays always win — a
    // re-scrape with no tray selection falls back to that run's own chips
    // (and, for a run started before CMD #1870, to its stored ui_types, which
    // lead_scrape_start() still understands).
    final name = src != null ? (src['city']?.toString() ?? '') : _nameCtrl.text.trim();
    final level = src != null ? (src['level']?.toString() ?? _level) : _level;
    var include = _include;
    if (include.isEmpty && src != null) {
      final saved = ((src['include_keys'] as List?) ?? const []).map((e) => e.toString());
      final legacy = ((src['types'] as List?) ?? const []).map((e) => e.toString());
      include = {...(saved.isEmpty ? legacy : saved)};
    }
    final budget = _budgetValue;
    if (budget == null) return;

    final args = ScrapeStartArgs.fromTrays(
      name: name,
      level: level,
      include: include,
      exclude: _exclude,
      maxCalls: budget,
    );

    setState(() {
      _starting = true;
      _formError = null;
    });
    try {
      final runId = await Supabase.instance.client
          .rpc('lead_scrape_start', params: args.toParams());
      if (!mounted) return;
      final id = runId?.toString();
      setState(() {
        _activeRunId = id;
        _activeRunLevel = level;
        _activeRunTypeLabels = _includeChipLabels();
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
      if (mounted) showToast(context, cf('admin_customer.resume_failed_e', {'e': '$e'}), isError: true);
    } finally {
      if (mounted) setState(() => _resuming = false);
    }
  }

  void _subscribeToRun(String runId) {
    _runChannel?.unsubscribe();
    // CHANGE #643: the filter is kept and handed to LiveFeed, so if the
    // registry ever puts lead_scrape_runs back on a live channel this stays
    // narrowed to one run rather than every run in the system.
    LiveFeed.instance
        .watch(
          channelPrefix: 's_leads_run_$runId',
          tables: const ['lead_scrape_runs'],
          filters: {
            'lead_scrape_runs': PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'id',
              value: runId,
            ),
          },
          onChange: (_) => _refreshStatus(),
        )
        .then((h) {
      if (!mounted) {
        h.dispose();
        return;
      }
      _runChannel?.unsubscribe();
      _runChannel = h;
    });
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
        showToast(context, cf('admin_customer.scrape_complete', {'n': '$newLeads'}));
        await Future.wait([_refreshSummaryAndUsage(), _loadRows(reset: true), _loadPastRuns()]);
        if (mounted) setState(() => _activeRunId = null);
      } else if (s == 'error') {
        _stopPolling();
        _runChannel?.unsubscribe();
        _runChannel = null;
        showToast(context, cf('admin_customer.scrape_error', {'e': '${status['error'] ?? 'unknown'}'}), isError: true);
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
            Text(cf('admin_customer.failed_to_load', {'e': '$_loadError'}),
                style: const TextStyle(color: Color(0xFFDC2626), fontSize: 13)),
            const SizedBox(height: 12),
          ],
          _buildFieldStrip(),
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

  // ── CMD #1877: the "Field" strip — the day summary, one line ────────────

  /// The Routes tab's card and this strip are the same three numbers from the
  /// same call. `has` is the backend's flag: on a day with no field work the
  /// strip is absent, never a row of zeroes.
  Widget _buildFieldStrip() {
    final strip = _fieldStrip;
    if (strip == null || !strip.has) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(strip.title,
                    style: Ds.t.subtitle, overflow: TextOverflow.ellipsis)),
            if (strip.headerLabel != null)
              Text(strip.headerLabel!, style: Ds.t.caption),
          ]),
          if (strip.summaryLabel != null) ...[
            SizedBox(height: Ds.space.x4),
            Text(strip.summaryLabel!, style: Ds.t.body),
          ],
          if (strip.conversionLabel != null || strip.costLabel != null) ...[
            SizedBox(height: Ds.space.x4),
            Text(
                [strip.conversionLabel, strip.costLabel]
                    .whereType<String>()
                    .join(' · '),
                style: Ds.t.caption),
          ],
          if (strip.chips.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: strip.chips.map(_fieldChip).toList(),
            ),
          ],
        ]),
      ),
    );
  }

  /// The one place a tone NAME becomes a colour on this tab. Same vocabulary
  /// as the Routes tab's chips, same tokens.
  Widget _fieldChip(RouteCostChip chip) {
    late final Color bg;
    late final Color fg;
    switch (chip.tone) {
      case RouteChipTone.brand:
        bg = Ds.c.brandSoft;
        fg = Ds.c.brand;
      case RouteChipTone.success:
        bg = Ds.c.successSoft;
        fg = Ds.c.success;
      case RouteChipTone.warning:
        bg = Ds.c.warningSoft;
        fg = Ds.c.warning;
      case RouteChipTone.danger:
        bg = Ds.c.dangerSoft;
        fg = Ds.c.danger;
      case RouteChipTone.info:
        bg = Ds.c.infoSoft;
        fg = Ds.c.info;
      case RouteChipTone.muted:
        bg = Ds.c.bg;
        fg = Ds.c.textSecondary;
    }
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
      child: Text(chip.label,
          style: Ds.t.caption.copyWith(color: fg, fontWeight: FontWeight.w600)),
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
                    cf('admin_customer.warehouse_name', {'name': _hubNameCtrl.text.isNotEmpty ? _hubNameCtrl.text : "Not set"}),
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                  ),
                  Text(
                    cf('admin_customer.hub_counts', {'a': '${_hubCounts['core']}', 'b': '${_hubCounts['extended']}'}),
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)),
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: () => setState(() => _hubExpanded = !_hubExpanded),
              child: Text(_hubExpanded ? c('admin_customer.close') : 'Change'),
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
          Text(cf('admin_customer.last_updated', {'t': _fmtUpdatedAt(_hubUpdatedAt)}),
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
          const SizedBox(height: 14),
          // ── Radii ────────────────────────────────────────────────────
          Text(c('admin_customer.delivery_radii'),
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
          Text(c('admin_customer.search_and_set'),
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
            Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(c('admin_customer.recomputing_distances'),
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
            ),
          const SizedBox(height: 18),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          const SizedBox(height: 14),
          // ── (b) Use my current location ─────────────────────────────
          Text(c('admin_customer.use_current_location'),
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
              Text(cf('admin_customer.gps_captured', {'lat': '${_hubGpsLat!.toStringAsFixed(6)}', 'lng': '${_hubGpsLng!.toStringAsFixed(6)}'}) +
                      '${_hubGpsAddress != null ? " — $_hubGpsAddress" : ""}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
              ElevatedButton(
                onPressed: (_hubBusy || !_radiiValid) ? null : _confirmAndSaveGps,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B7A43),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(c('admin_customer.confirm_and_save'), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
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
          Text(c('admin_customer.paste_coords_label'),
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
        labelText: c('admin_customer.name_label'),
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
        hintText: c('admin_customer.hub_name_hint'),
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
        labelText: cf('admin_customer.radius_km', {'label': '$label'}),
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
        hintText: c('admin_customer.coords_hint'),
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
    final modeHint = _modes
        .firstWhere((m) => m['key']?.toString() == _mode, orElse: () => const {})['hint']
        ?.toString();
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
          Text(_form['title']?.toString() ?? '',
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const SizedBox(height: 12),

          // ── Mode: fresh scrape vs re-scrape a saved run ──────────────────
          _modeSelector(),
          if (modeHint != null && modeHint.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(modeHint,
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          ],
          const SizedBox(height: 14),

          // Re-scrape replaces City/District + Name with the saved-run picker.
          if (_isRescrape) ...[
            widget.isDesktop
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _sourceDropdown()),
                    const SizedBox(width: 12),
                    SizedBox(width: 180, child: _budgetField()),
                  ])
                : Column(children: [
                    _sourceDropdown(),
                    const SizedBox(height: 10),
                    _budgetField(),
                  ]),
            _sourceDeleteAction(),
          ] else
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
          const SizedBox(height: 16),

          // ── Include / Exclude category trays ─────────────────────────────
          _categoryTray(
            _selection['include_label']?.toString() ?? '',
            _include,
            _exclude,
            const Color(0xFF1B7A43),
          ),
          const SizedBox(height: 14),
          _categoryTray(
            _selection['exclude_label']?.toString() ?? '',
            _exclude,
            _include,
            const Color(0xFFB42318),
          ),
          if ((_selection['hint']?.toString() ?? '').isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_selection['hint'].toString(),
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          ],

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
              label: Text(_form['submit_label']?.toString() ?? '',
                  style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }

  /// CMD #1870 — the saved run picked here is also the one you can get rid
  /// of. A run scraped for the wrong city is the reason this exists: choose
  /// it, delete it, and its leads go to Archived where Restore can undo it.
  /// The caption is the backend's; the action is the same _deleteRun().
  Widget _sourceDeleteAction() {
    final src = _sourceRun;
    if (src == null) {
      RenderLog.write('c1870_rescrape_delete', 'no_source_picked');
      return const SizedBox.shrink();
    }
    final view = ScrapeRunView.from(src);
    final d = view.delete;
    if (d == null) {
      RenderLog.write('c1870_rescrape_delete', 'backend_withheld');
      return const SizedBox.shrink();
    }
    RenderLog.write('c1870_rescrape_delete', d.label);
    final busy = _runBusy.contains(view.runId);
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: _runActionButton(d.label, Icons.delete_outline,
            busy ? null : () => _deleteRun(src),
            danger: true),
      ),
    );
  }

  Widget _modeSelector() {
    final modes = _modes;
    if (modes.isEmpty) return const SizedBox.shrink();
    return Row(children: [
      for (int i = 0; i < modes.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: _segBtn(
            modes[i]['label']?.toString() ?? '',
            _mode == modes[i]['key']?.toString(),
            () => setState(() {
              _mode = modes[i]['key']?.toString() ?? '';
              _formError = null;
            }),
          ),
        ),
      ],
    ]);
  }

  Widget _sourceDropdown() {
    final sources = _sources;
    return InputDecorator(
      decoration: InputDecoration(
        labelText: _modes
            .firstWhere((m) => m['key']?.toString() == 'rescrape', orElse: () => const {})['label']
            ?.toString(),
        labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        isDense: true,
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: _sourceRunId,
          items: sources
              .map((s) => DropdownMenuItem<String>(
                    value: s['run_id']?.toString(),
                    child: Text(s['label']?.toString() ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5)),
                  ))
              .toList(),
          onChanged: (v) => setState(() {
            _sourceRunId = v;
            _formError = null;
          }),
        ),
      ),
    );
  }

  /// One include/exclude tray. [selected] is the set this tray writes to and
  /// [opposite] is the other tray — a key can only sit in one of them.
  Widget _categoryTray(
      String title, Set<String> selected, Set<String> opposite, Color accent) {
    void toggle(String key, bool on) {
      setState(() {
        if (on) {
          selected.add(key);
          opposite.remove(key);
        } else {
          selected.remove(key);
        }
      });
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title,
          style: const TextStyle(
              fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF6B7280))),
      const SizedBox(height: 8),
      for (final c in _cats) ...[
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          _catChip(c.label, selected.contains(c.key), accent,
              (v) => toggle(c.key, v)),
          if (c.sub.isNotEmpty)
            IconButton(
              onPressed: () => setState(() {
                final id = '$title|${c.key}';
                if (!_expandedCats.remove(id)) _expandedCats.add(id);
              }),
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              constraints: const BoxConstraints(),
              icon: Icon(
                  _expandedCats.contains('$title|${c.key}')
                      ? Icons.expand_less
                      : Icons.expand_more,
                  color: const Color(0xFF9CA3AF)),
            ),
        ]),
        if (c.sub.isNotEmpty && _expandedCats.contains('$title|${c.key}'))
          Padding(
            padding: const EdgeInsets.only(left: 18, top: 2, bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: c.sub
                  .map((s) => _catChip(s.label, selected.contains(s.key), accent,
                      (v) => toggle(s.key, v)))
                  .toList(),
            ),
          ),
      ],
    ]);
  }

  Widget _catChip(String label, bool sel, Color accent, ValueChanged<bool> onSel) {
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: sel,
      onSelected: onSel,
      selectedColor: accent.withValues(alpha: 0.12),
      checkmarkColor: accent,
      backgroundColor: const Color(0xFFF3F4F6),
      side: BorderSide(color: sel ? accent : const Color(0xFFD1D5DB)),
      labelStyle: TextStyle(color: sel ? accent : const Color(0xFF374151)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _levelToggle() {
    final levels = _levels;
    return Row(children: [
      for (int i = 0; i < levels.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(
          child: _segBtn(
            levels[i]['label']?.toString() ?? '',
            _level == levels[i]['key']?.toString(),
            () => setState(() => _level = levels[i]['key']?.toString() ?? ''),
          ),
        ),
      ],
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
    // Label follows the chosen level (City / District) — both come from the RPC.
    final levelLabel = _levels
        .firstWhere((l) => l['key']?.toString() == _level, orElse: () => const {})['label']
        ?.toString();
    return TextField(
      controller: _nameCtrl,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        labelText: levelLabel,
        labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  Widget _budgetField() {
    final min = (_maxCalls['min'] as num?)?.toInt();
    final max = (_maxCalls['max'] as num?)?.toInt();
    return TextField(
      controller: _budgetCtrl,
      onChanged: (_) => setState(() {}),
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: _maxCalls['label']?.toString(),
        helperText: (min != null && max != null) ? '$min–$max' : null,
        helperStyle: const TextStyle(fontSize: 10.5, color: Color(0xFF9CA3AF)),
        errorText: (_budgetCtrl.text.isNotEmpty && _budgetValue == null && min != null && max != null)
            ? '$min–$max'
            : null,
        labelStyle: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        isDense: true,
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  /// Quota line — every number (including the over-quota cost) comes from
  /// scrape_form_options().quota, not from a rate hardcoded here.
  Widget _costStrip() {
    final used = (_monthUsage?['used'] as num?)?.toInt() ?? 0;
    final freeLimit = (_monthUsage?['free_limit'] as num?)?.toInt() ?? 0;
    final remaining = (_monthUsage?['remaining'] as num?)?.toInt() ?? 0;
    final over = (_monthUsage?['over'] as num?)?.toInt() ?? 0;
    final cost = _monthUsage?['est_cost_inr'];
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
          cf('admin_customer.quota_line', {'used': '$used', 'limit': '$freeLimit', 'remaining': '$remaining', 'resets': '$resetsOn'}),
          style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
        ),
        if (over > 0 && cost != null) ...[
          const SizedBox(height: 4),
          Text(cf('admin_customer.over_free_tier', {'over': '$over', 'cost': '$cost'}),
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFDC2626))),
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
          cf('admin_customer.scrape_progress', {'done': '$cellsDone', 'total': '$cellsTotal', 'calls': '$apiCalls', 'maxcalls': '$maxCalls', 'newleads': '$leadsNew'}),
          style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
        ),
        if (s == 'paused_budget') ...[
          const SizedBox(height: 10),
          Text(cf('admin_customer.budget_reached', {'calls': '$apiCalls'}),
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
            label: Text(c('admin_customer.resume_500'), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
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

    final runMode = _resultsRunId != null;
    final rows = runMode ? _runLeads : _rows;
    final loading = runMode ? _runLeadsLoading : _rowsLoading;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(c('admin_customer.scraped_leads'),
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 12),
        _resultScopeBar(),
        const SizedBox(height: 12),
        // Filters only drive get_scraped_leads; a run's own result set is
        // whatever that run produced, so they are hidden in run mode.
        if (!runMode) ...[
          _buildFilterBar(byClass, cities, total),
          // CMD #1869 — the bulk toolbar, drawn entirely from the payload's
          // own bulk block. The Archived toggle itself lives in the filter
          // row above, because it is a filter like any other.
          _bulkToolbar(rows),
          SizedBox(height: Ds.space.x12),
        ] else ...[
          _selectionBar(rows),
          const SizedBox(height: 14),
        ],
        if (loading && rows.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 40),
            child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)),
          )
        else if (rows.isEmpty)
          _ssvEmptyStateLocal(runMode
              ? 'This run has no leads left.'
              : (_leadPage.emptyLabel ?? ''))
        else
          _leadCardGrid(rows,
              selectable: runMode || _selectMode || _selectedLeadIds.isNotEmpty),
      ],
    );
  }

  /// CHANGE #552 — scrape_results_bulk() is scoped to ONE run, so Keep/Remove
  /// only make sense while a saved run is the active scope. Picking a run
  /// lists that run's own leads (from scrape_run_export().leads) so that
  /// "Keep selected" can honestly mean "drop the rest of this run".
  Widget _resultScopeBar() {
    return Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      DropdownButton<String?>(
        value: _resultsRunId,
        underline: const SizedBox.shrink(),
        hint: Text(c('admin_customer.all_leads'), style: const TextStyle(fontSize: 12.5)),
        items: [
          DropdownMenuItem<String?>(
              value: null, child: Text(c('admin_customer.all_leads'), style: const TextStyle(fontSize: 12.5))),
          ..._runs.map((r) => DropdownMenuItem<String?>(
                value: r['run_id']?.toString(),
                child: Text(
                    '${r['city'] ?? ''} · ${_fmtRunDate(r['created_at']?.toString())} · '
                    '${(r['lead_count'] as num?)?.toInt() ?? 0}',
                    style: const TextStyle(fontSize: 12.5)),
              )),
        ],
        onChanged: (v) => _selectResultsRun(v),
      ),
    ]);
  }

  Widget _selectionBar(List<Map<String, dynamic>> rows) {
    final ids = rows.map((r) => (r['id'] as num?)?.toInt()).whereType<int>().toSet();
    final allSelected = ids.isNotEmpty && _selectedLeadIds.containsAll(ids);
    return Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Checkbox(
          value: allSelected,
          tristate: false,
          onChanged: (v) => setState(() {
            if (v == true) {
              _leadSelection.selectAll(ids);
            } else {
              _leadSelection.removeAll(ids);
            }
          }),
          activeColor: const Color(0xFF1B7A43),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        Text(cf('admin_customer.select_all', {'sel': '${_selectedLeadIds.length}', 'total': '${ids.length}'}),
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF374151))),
      ]),
      // Both buttons, their labels and their action keys come from
      // scrape_form_options().result_actions[].
      for (final a in _resultActions)
        OutlinedButton(
          onPressed: (_bulkBusy || _selectedLeadIds.isEmpty)
              ? null
              : () => _runBulkAction(a['key']?.toString() ?? ''),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFF1B7A43),
            side: const BorderSide(color: Color(0xFF1B7A43)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            visualDensity: VisualDensity.compact,
          ),
          child: Text(a['label']?.toString() ?? '',
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ),
      if (_bulkBusy)
        const SizedBox(
            width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
    ]);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // CMD #1869 — S Leads bulk lane: Archived filter, multi-select toolbar,
  // Archive / Restore / Reclassify.
  //
  // Nothing below decides anything. Every label, every count and every message
  // arrives in lead_leads_summary().bulk or in the reply of the two mutation
  // RPCs (leads_bulk_set_status, leads_bulk_set_class); this code renders them
  // and sends the ids back.
  // ═══════════════════════════════════════════════════════════════════════

  /// Idle it is the backend's one-line hint; with a selection it is the
  /// toolbar. Archive is replaced by Restore while the Archived filter is on —
  /// the UI can never hard-delete a lead.
  Widget _bulkToolbar(List<Map<String, dynamic>> rows) {
    final n = _selectedLeadIds.length;
    final ids = rows.map((r) => (r['id'] as num?)?.toInt()).whereType<int>().toSet();
    if (!_selectMode && n == 0) {
      final hint = _bulk['select_hint']?.toString() ?? '';
      if (hint.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(top: Ds.space.x8),
        child: Text(hint, style: Ds.t.caption),
      );
    }
    RenderLog.write('c1869_bulk_bar', 1);
    RenderLog.write('c1869_selected', n);
    final selectedLabel = _bulkUi.selectedLabel(n);
    return Container(
      margin: EdgeInsets.only(top: Ds.space.x12),
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(color: Ds.c.brandSoft, borderRadius: Ds.r.rCard),
      child: Wrap(
        spacing: Ds.space.x12,
        runSpacing: Ds.space.x8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(selectedLabel, style: Ds.t.body),
          _bulkTextButton(_bulk['select_all_label']?.toString() ?? '', () {
            setState(() => _leadSelection.selectAll(ids));
          }),
          _bulkTextButton(_bulk['clear_label']?.toString() ?? '', () {
            setState(() => _leadSelection.clear());
          }),
          _bulkAction(_bulkUi.primaryActionLabel(_archivedFilter, n),
              primary: true,
              onTap: n == 0
                  ? null
                  : () => _archivedFilter
                      ? _setLeadStatus(_selectedLeadIds.toList(),
                          _bulkUi.primaryActionKey(true))
                      : _confirmArchive(_selectedLeadIds.toList())),
          _bulkAction(_bulkUi.reclassifyLabel(n), primary: false,
              onTap:
                  n == 0 ? null : () => _pickLeadClass(_selectedLeadIds.toList())),
          if (_bulkBusy)
            SizedBox(
                width: Ds.space.x16,
                height: Ds.space.x16,
                child: const CircularProgressIndicator(strokeWidth: 2)),
        ],
      ),
    );
  }

  Widget _bulkTextButton(String label, VoidCallback onTap) {
    if (label.isEmpty) return const SizedBox.shrink();
    return TextButton(
      onPressed: _bulkBusy ? null : onTap,
      style: TextButton.styleFrom(
        foregroundColor: Ds.c.brand,
        minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: Ds.c.brand)),
    );
  }

  /// One brand-filled action per bar; everything else is outlined.
  Widget _bulkAction(String label,
      {required bool primary, required VoidCallback? onTap}) {
    if (label.isEmpty) return const SizedBox.shrink();
    final child = Text(label,
        style: Ds.t.body.copyWith(color: primary ? Ds.c.surface : Ds.c.brand));
    if (primary) {
      return ElevatedButton(
        onPressed: _bulkBusy ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: Ds.c.brand,
          foregroundColor: Ds.c.surface,
          minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
        ),
        child: child,
      );
    }
    return OutlinedButton(
      onPressed: _bulkBusy ? null : onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: Ds.c.brand,
        side: BorderSide(color: Ds.c.brand),
        minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
      ),
      child: child,
    );
  }

  void _toggleLeadSelected(int id) {
    setState(() => _leadSelection.toggle(id));
  }

  /// Long-press is the entry into multi-select.
  void _enterLeadSelect(int id) {
    setState(() => _leadSelection.enter(id));
  }

  Future<void> _confirmArchive(List<int> ids) async {
    if (ids.isEmpty) return;
    final title = _bulkUi.confirmTitle(ids.length);
    final body = _bulk['confirm_body']?.toString() ?? '';
    final okLabel = _bulk['confirm_ok']?.toString() ?? '';
    final cancelLabel = _bulk['confirm_cancel']?.toString() ?? '';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Ds.t.title),
              SizedBox(height: Ds.space.x8),
              Text(body, style: Ds.t.bodySecondary),
              SizedBox(height: Ds.space.x24),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Ds.c.brand,
                      side: BorderSide(color: Ds.c.divider),
                      minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
                      shape:
                          RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                    child: Text(cancelLabel, style: Ds.t.body),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Ds.c.brand,
                      foregroundColor: Ds.c.surface,
                      minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
                      shape:
                          RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                    child: Text(okLabel,
                        style: Ds.t.body.copyWith(color: Ds.c.surface)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
    if (ok == true) await _setLeadStatus(ids, 'archive');
  }

  /// The class list, its order and its labels are all app_settings + ui_copy.
  Future<void> _pickLeadClass(List<int> ids) async {
    if (ids.isEmpty) return;
    final classes = _bulkClasses;
    if (classes.isEmpty) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(_bulk['class_title']?.toString() ?? '',
                  style: Ds.t.title),
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final k in classes)
                  ListTile(
                    minVerticalPadding: Ds.space.x12,
                    title: Text(k['label']?.toString() ?? '', style: Ds.t.body),
                    onTap: () => Navigator.of(ctx).pop(k['key']?.toString()),
                  ),
              ],
            ),
          ),
          SizedBox(height: Ds.space.x8),
        ]),
      ),
    );
    if (picked != null && picked.isNotEmpty) await _setLeadClass(ids, picked);
  }

  Future<void> _setLeadStatus(List<int> ids, String action) async {
    if (ids.isEmpty || _bulkBusy) return;
    setState(() => _bulkBusy = true);
    try {
      final res = await Supabase.instance.client.rpc('leads_bulk_set_status',
          params: {'p_ids': ids, 'p_status': action});
      await _afterBulk(res, ids, 'c1869_${action}_n');
    } catch (e) {
      if (!mounted) return;
      setState(() => _bulkBusy = false);
      showToast(context, '$e', isError: true);
    }
  }

  Future<void> _setLeadClass(List<int> ids, String classKey) async {
    if (ids.isEmpty || _bulkBusy) return;
    setState(() => _bulkBusy = true);
    try {
      final res = await Supabase.instance.client.rpc('leads_bulk_set_class',
          params: {'p_ids': ids, 'p_class': classKey});
      await _afterBulk(res, ids, 'c1869_reclassify_n');
    } catch (e) {
      if (!mounted) return;
      setState(() => _bulkBusy = false);
      showToast(context, '$e', isError: true);
    }
  }

  /// One reply shape for both RPCs: ok + n + the message to show, verbatim.
  Future<void> _afterBulk(
      dynamic res, List<int> ids, String renderKey) async {
    final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    final ok = m['ok'] == true;
    final msg = m['message']?.toString();
    RenderLog.write(renderKey, (m['n'] as num?)?.toInt() ?? 0);
    if (!mounted) return;
    setState(() {
      _bulkBusy = false;
      if (ok) _leadSelection.removeAll(ids);
    });
    if (msg != null && msg.isNotEmpty) showToast(context, msg, isError: !ok);
    if (!ok) return;
    _leadCards.clear();
    _leadCardsFailed.clear();
    // The archived count, the chip counts and the "S Leads (N)" tab chip are
    // all the backend's answer to the SAME filter map — re-ask for all three.
    await _refreshSummaryAndUsage();
    await _loadRows(reset: true);
    await _refreshFilterModel();
  }

  Future<void> _selectResultsRun(String? runId) async {
    setState(() {
      _resultsRunId = runId;
      _leadSelection.clear();
      _runLeads = [];
      _runLeadsLoading = runId != null;
    });
    if (runId == null) return;
    try {
      final res = await Supabase.instance.client
          .rpc('scrape_run_export', params: {'p_run_id': runId});
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final leads = _mapList(m['leads']);
      RenderLog.write('c552_run_leads', leads.length);
      if (!mounted) return;
      setState(() {
        _runLeads = leads;
        _runLeadsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _runLeadsLoading = false);
      showToast(context, '$e', isError: true);
    }
  }

  Future<void> _runBulkAction(String actionKey) async {
    final runId = _resultsRunId;
    if (runId == null || actionKey.isEmpty || _selectedLeadIds.isEmpty) return;
    setState(() => _bulkBusy = true);
    try {
      final res = await Supabase.instance.client.rpc('scrape_results_bulk', params: {
        'p_run_id': runId,
        'p_action': actionKey,
        'p_lead_ids': _selectedLeadIds.toList(),
      });
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;
      setState(() => _bulkBusy = false);
      // Backend copy, verbatim — it is the only place that knows how many
      // rows were protected because they are already customers/visited.
      final msg = (m['message'] ?? m['error'])?.toString();
      if (msg != null && msg.isNotEmpty) {
        showToast(context, msg, isError: m['error'] != null);
      }
      if (m['error'] == null) {
        _leadSelection.clear();
        _leadCards.clear();
        _leadCardsFailed.clear();
        await _selectResultsRun(runId);
        await _loadPastRuns();
        await _loadRows(reset: true);
        await _refreshSummaryAndUsage();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _bulkBusy = false);
      showToast(context, '$e', isError: true);
    }
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

  /// CMD #1868 — the filter row is sleads_filters(), rendered. The chips,
  /// their order, their labels, their counts, the four hidden-by-default
  /// switches, the score range and its caption, the active zone's name and
  /// the saved views all arrive in that one payload. `byClass` is still the
  /// summary's, but only the city dropdown reads it now.
  Widget _buildFilterBar(
      List<Map<String, dynamic>> byClass, List<Map<String, dynamic>> cities, int total) {
    final cityDropdown = DropdownButton<String?>(
      value: _cityFilter,
      hint: Text(c('admin_customer.all_cities'), style: Ds.t.body),
      underline: const SizedBox.shrink(),
      items: [
        DropdownMenuItem<String?>(
            value: null,
            child: Text(c('admin_customer.all_cities'), style: Ds.t.body)),
        ...cities.map((c) => DropdownMenuItem<String?>(
              value: c['city']?.toString(),
              child: Text('${c['city']} (${c['n']})', style: Ds.t.body),
            )),
      ],
      onChanged: (v) => _changeFilters(city: v, cityIsAll: v == null),
    );

    final searchBox = TextField(
      controller: _searchCtrl,
      decoration: InputDecoration(
        hintText: c('admin_customer.search_leads_hint'),
        hintStyle: Ds.t.caption,
        prefixIcon: const Icon(Icons.search),
        border: OutlineInputBorder(borderRadius: Ds.r.rButton),
        isDense: true,
      ),
      style: Ds.t.body,
    );

    return SLeadsFilterBar(
      model: _filterModel,
      onChipTap: (key, kind) => _applyFilters(_fs.tapChip(key, kind)),
      onToggle: (key, value) => _applyFilters(_fs.setToggle(key, value)),
      onScore: (score) => _applyFilters(_fs.setScore(score)),
      onApplyView: _applyView,
      onDeleteView: _deleteView,
      onSaveView: _saveView,
      trailing: Wrap(
        spacing: Ds.space.x16,
        runSpacing: Ds.space.x8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          cityDropdown,
          SizedBox(
              width: widget.isDesktop ? Ds.space.x48 * 8 : double.infinity,
              child: searchBox),
        ],
      ),
    );
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


  // ═══════════════════════════════════════════════════════════════════════
  // CHANGE #552 — redesigned Scraped-leads card, driven by scrape_lead_card()
  // and laid out like the route stop card: one big photo across the top with
  // the score chip overlaid, then name / type / rating / open / address /
  // phone / review, then ONE compact action row built from actions[].
  //
  // Every label, colour pair and URI below arrives complete from the RPC.
  // Nothing is composed, formatted or constructed in Dart.
  // ═══════════════════════════════════════════════════════════════════════

  // ═══════════════════════════════════════════════════════════════════════
  // CHANGE #1867 — the results list is LAZY.
  //
  // It was a Wrap (desktop) / Column (mobile) of 100 full cards, built eagerly
  // inside the page's SingleChildScrollView: 100 network photos and 100
  // scrape_lead_card() calls, each completion setState-ing the whole thing.
  // Now it is a ListView.builder in its own bounded viewport — only the rows
  // on screen exist — and a row is a COMPACT tile drawn straight from
  // sleads_page(). The rich card (photo, actions, scrape_lead_card()) is
  // built for an EXPANDED row only, i.e. on tap.
  // ═══════════════════════════════════════════════════════════════════════

  Widget _leadCardGrid(List<Map<String, dynamic>> rows, {required bool selectable}) {
    final vh = MediaQuery.of(context).size.height;
    final h = (vh * 0.72).clamp(360.0, 900.0);
    // rows + one footer slot (loading more / end-of-list, both backend copy).
    final footer = _resultsRunId == null ? 1 : 0;
    return SizedBox(
      height: h,
      child: Scrollbar(
        controller: _resultsCtrl,
        child: ListView.builder(
          controller: _resultsCtrl,
          primary: false,
          padding: EdgeInsets.only(bottom: Ds.space.x8),
          itemCount: rows.length + footer,
          itemBuilder: (ctx, i) {
            if (i >= rows.length) return _leadListFooter();
            final r = rows[i];
            final id = (r['id'] as num?)?.toInt();
            final expanded = id != null && _expandedIds.contains(id);
            RenderLog.write('c1867_row_built', '$i');
            return Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: expanded
                  ? _scrapeLeadCard(r, selectable: selectable)
                  : _leadCompactRow(r, selectable: selectable),
            );
          },
        ),
      ),
    );
  }

  /// The list footer. Both strings are sleads_page()'s own — "Loading more…"
  /// while a page is in flight, its end_label once the backend says there is
  /// nothing left. Neither is composed in Dart.
  Widget _leadListFooter() {
    if (_moreLoading) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x16),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: Ds.c.brand)),
          SizedBox(width: Ds.space.x8),
          Text(_leadPage.moreLabel ?? '', style: Ds.t.caption),
        ]),
      );
    }
    final end = _leadPage.endLabel;
    if (end != null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x16),
        child: Center(child: Text(end, style: Ds.t.caption)),
      );
    }
    return SizedBox(height: Ds.space.x24);
  }

  /// CHANGE #1867 — a list row. Text only: no photo, no map, no per-row RPC.
  /// Every string is sleads_page()'s (a run's own leads fall back to that
  /// payload's field of the same meaning); absent means the line is absent.
  Widget _leadCompactRow(Map<String, dynamic> r, {required bool selectable}) {
    final row = SLeadRow.from(r);
    final id = row.id;
    final title = row.title;
    final typeLabel = row.typeLabel;
    final ratingLabel = row.ratingLabel;
    final openLabel = row.openLabel;
    final address = row.addressLabel;
    final phone = row.phoneLabel;
    final selected = id != null && _selectedLeadIds.contains(id);

    return InkWell(
      onTap: id == null
          ? null
          : () {
              setState(() => _expandedIds.add(id));
              if (!_leadDetailCache.containsKey(id) && !_detailLoading.contains(id)) {
                _fetchLeadDetail(id);
              }
            },
      borderRadius: Ds.r.rCard,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(
              color: selected ? Ds.c.brand : Ds.c.divider, width: selected ? 1.5 : 1),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (selectable && id != null)
            Padding(
              padding: EdgeInsets.only(right: Ds.space.x4),
              child: Checkbox(
                value: selected,
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selectedLeadIds.add(id);
                  } else {
                    _selectedLeadIds.remove(id);
                  }
                }),
                activeColor: Ds.c.brand,
              ),
            ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x4),
              Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x4,
                  crossAxisAlignment: WrapCrossAlignment.center, children: [
                if (typeLabel != null && typeLabel.isNotEmpty)
                  _leadRowChip(typeLabel, Ds.c.bg, Ds.c.text),
                if (ratingLabel != null && ratingLabel.isNotEmpty)
                  Text(ratingLabel, style: Ds.t.caption.copyWith(color: Ds.c.warning)),
                if (openLabel != null && openLabel.isNotEmpty)
                  _leadRowChip(openLabel, Ds.hex(row.openBg, Ds.c.bg),
                      Ds.hex(row.openFg, Ds.c.textSecondary)),
                // CMD #1871 — "3 branches". Tapping opens the row WITH its
                // branch list; when the toggle is on the backend sends
                // branches_expandable:false and the chip is a plain label.
                // CMD #1874 — "Revisit": this lead's parked date has come
                // due, so the next plan build is allowed to pick it up again.
                if (row.revisitLabel != null && row.revisitLabel!.isNotEmpty)
                  _leadRowChip(row.revisitLabel!, Ds.c.warningSoft, Ds.c.warning),
                if (row.branchesLabel != null && row.branchesLabel!.isNotEmpty)
                  _branchChip(row.branchesLabel!,
                      open: false,
                      onTap: (row.branchesExpandable && id != null)
                          ? () {
                              setState(() {
                                _expandedIds.add(id);
                                _expandedBranchIds.add(id);
                              });
                              if (!_leadDetailCache.containsKey(id) &&
                                  !_detailLoading.contains(id)) {
                                _fetchLeadDetail(id);
                              }
                            }
                          : null),
              ]),
              if (address != null && address.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(address,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: Ds.t.caption),
              ],
              if (phone != null && phone.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(phone, style: Ds.t.caption.copyWith(color: Ds.c.text)),
              ],
            ]),
          ),
          Padding(
            padding: EdgeInsets.only(left: Ds.space.x8),
            child: Icon(Icons.expand_more, size: 20, color: Ds.c.textSecondary),
          ),
        ]),
      ),
    );
  }

  /// One pill on a compact row. Colours arrive already decided (the open/closed
  /// pair comes straight from sleads_page()); this only draws them.
  Widget _leadRowChip(String label, Color bg, Color fg) => Container(
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
        child: Text(label,
            style: Ds.t.caption.copyWith(color: fg, fontWeight: FontWeight.w600)),
      );

  // ═══════════════════════════════════════════════════════════════════════
  // CMD #1871 — one row per phone, with the branch count on it.
  //
  // A chain publishes ONE phone and Maps lists every branch, so the same shop
  // was in the list N times. The backend now returns the best-scored member of
  // each phone group and puts the group size on the row. Everything printed
  // here is a backend string: the chip's own label says whether this is a
  // collapsed group ("3 branches") or one member of an expanded one
  // ("1 of 3 branches"), and each branch line is rendered exactly as
  // scrape_lead_card() composed it.
  // ═══════════════════════════════════════════════════════════════════════

  Widget _branchChip(String label, {required bool open, VoidCallback? onTap}) {
    final padH = Ds.space.x8;
    final padV = Ds.space.x4;

    final chip = Container(
      constraints: BoxConstraints(
          minHeight: onTap == null ? 0 : Ds.touch.minTarget),
      padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
      decoration: BoxDecoration(
        color: Ds.c.infoSoft,
        borderRadius: Ds.r.rChip,
        border: Border.all(color: Ds.c.info),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.store_mall_directory_outlined,
            size: Ds.t.bodySize, color: Ds.c.info),
        SizedBox(width: padV),
        Text(label,
            style: Ds.t.caption
                .copyWith(color: Ds.c.info, fontWeight: FontWeight.w700)),
        if (onTap != null) ...[
          SizedBox(width: padV),
          Icon(open ? Icons.expand_less : Icons.expand_more,
              size: Ds.t.bodySize, color: Ds.c.info),
        ],
      ]),
    );

    if (onTap == null) return chip;
    return InkWell(borderRadius: Ds.r.rChip, onTap: onTap, child: chip);
  }

  /// The branch list behind the chip. `loaded` is false only for the instant
  /// before scrape_lead_card() lands, and it draws a skeleton, not a spinner.
  Widget _branchPanel(String? title, List<Map<String, dynamic>> rows,
      {required bool loaded}) {
    String str(Map<String, dynamic> b, String k) => b[k]?.toString() ?? '';

    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x12, Ds.space.x8, Ds.space.x12, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null && title.isNotEmpty)
          Text(title,
              style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700)),
        SizedBox(height: Ds.space.x4),
        if (!loaded)
          Container(
            height: Ds.touch.minTarget,
            decoration:
                BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rButton),
          )
        else
          for (final b in rows)
            Container(
              width: double.infinity,
              margin: EdgeInsets.only(bottom: Ds.space.x4),
              padding: EdgeInsets.all(Ds.space.x8),
              decoration: BoxDecoration(
                color: b['is_primary'] == true ? Ds.c.infoSoft : Ds.c.bg,
                borderRadius: Ds.r.rButton,
              ),
              child:
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(
                    child: Text(str(b, 'name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.caption.copyWith(
                            color: Ds.c.text, fontWeight: FontWeight.w700)),
                  ),
                  if (str(b, 'score_label').isNotEmpty)
                    Text(str(b, 'score_label'), style: Ds.t.caption),
                ]),
                if (str(b, 'address').isNotEmpty)
                  Text(str(b, 'address'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.caption),
                Row(children: [
                  if (str(b, 'rating_label').isNotEmpty)
                    Text(str(b, 'rating_label'), style: Ds.t.caption),
                  if (str(b, 'badge_label').isNotEmpty) ...[
                    if (str(b, 'rating_label').isNotEmpty)
                      SizedBox(width: Ds.space.x8),
                    Text(str(b, 'badge_label'),
                        style: Ds.t.caption.copyWith(
                            color: Ds.c.info, fontWeight: FontWeight.w700)),
                  ],
                ]),
              ]),
            ),
      ]),
    );
  }

  static const Map<String, IconData> _scrapeActionIcons = {
    'call': Icons.call,
    'whatsapp': Icons.chat,
    'map': Icons.map_outlined,
    'directions': Icons.directions_outlined,
    'website': Icons.language,
    'email': Icons.email_outlined,
    'import': Icons.person_add_alt_1_outlined,
  };

  /// scrape_lead_card() fetch + cache.
  ///
  /// CHANGE #1867 — this is a TAP-ONLY call now. It runs from _scrapeLeadCard,
  /// and _scrapeLeadCard is built for an EXPANDED row only; a list row is the
  /// text-only _leadCompactRow, drawn from sleads_page() with no call of its
  /// own. The concurrency cap stays for the case where several cards are open
  /// at once. Each completion setStates, so the queue drains itself; the error
  /// path setStates too, otherwise a failure would stall that pump.
  static const int _leadCardConcurrency = 8;

  Future<void> _loadLeadCard(int id) async {
    if (_leadCards.containsKey(id) ||
        _leadCardsInFlight.contains(id) ||
        _leadCardsFailed.contains(id) ||
        _leadCardsInFlight.length >= _leadCardConcurrency) return;
    _leadCardsInFlight.add(id);
    Map<String, dynamic>? card;
    try {
      final res = await Supabase.instance.client
          .rpc('scrape_lead_card', params: {'p_lead_id': id});
      if (res is Map) {
        card = Map<String, dynamic>.from(res);
        RenderLog.write('c552_lead_card', 'lead=$id');
      }
    } catch (_) {
      // Falls back to the list row's own fields. Remembered as failed so the
      // rebuild this setState triggers does not retry it in a hot loop.
    }
    _leadCardsInFlight.remove(id);
    if (!mounted) return;
    setState(() {
      if (card != null) {
        _leadCards[id] = card;
      } else {
        _leadCardsFailed.add(id);
      }
    });
  }

  Future<void> _refreshLeadCard(int id) async {
    _leadCards.remove(id);
    _leadCardsFailed.remove(id);
    await _loadLeadCard(id);
  }

  Color _colorFromHex(String? hex, Color fallback) {
    if (hex == null || hex.isEmpty) return fallback;
    final v = hex.replaceFirst('#', '');
    final n = int.tryParse(v, radix: 16);
    if (n == null) return fallback;
    return Color(v.length <= 6 ? (0xFF000000 | n) : n);
  }

  Widget _scrapeLeadCard(Map<String, dynamic> r, {required bool selectable}) {
    final id = (r['id'] as num?)?.toInt();
    if (id != null) _loadLeadCard(id);
    final card = id == null ? null : _leadCards[id];

    final photoUrl = (card?['photo_url'] ?? r['photo_url'])?.toString();
    final name = (card?['name'] ?? r['name'])?.toString() ?? '';
    final typeLabel = (card?['type_label'] ?? r['type_label'])?.toString();
    final ratingLabel = card?['rating_label']?.toString();
    final openLabel = card?['open_label']?.toString();
    final openColors = card?['open_colors'] is Map
        ? Map<String, dynamic>.from(card!['open_colors'] as Map)
        : const <String, dynamic>{};
    final hoursLabel = card?['hours_label']?.toString();
    final address = (card?['address'] ?? r['short_address'] ?? r['address'])?.toString();
    final phoneDisplay = card?['phone_display']?.toString();
    final scoreLabel = card?['score_label']?.toString();
    final reviewLabel = card?['review_label']?.toString();
    final reviewStale = card?['review_stale'] == true;
    final alreadyCustomer = card?['already_customer'] == true;
    final disabledReason = card?['disabled_reason'] is Map
        ? Map<String, dynamic>.from(card!['disabled_reason'] as Map)
        : const <String, dynamic>{};
    final actions = _mapList(card?['actions']);
    // ── CMD #1871 — the branches sharing this lead's phone ───────────────
    // The chip's wording is the LIST row's, so it still says "3 branches"
    // while collapsed and "1 of 3 branches" once the toggle is on; the branch
    // rows are scrape_lead_card()'s. Dart counts and formats nothing.
    final branchesLabel =
        (r['branches_label'] ?? card?['branches_label'])?.toString();
    final branchesExpandable = r['branches_expandable'] == true;
    final branchesTitle = card?['branches_title']?.toString();
    final branchRows = _mapList(card?['branches']);
    final branchesOpen = id != null && _expandedBranchIds.contains(id);
    final photoH = widget.isDesktop ? 168.0 : 140.0;
    final expanded = id != null && _expandedIds.contains(id);
    final selected = id != null && _selectedLeadIds.contains(id);

    VoidCallback? tapFor(String key, bool enabled) {
      if (!enabled) return null;
      if (key == 'import') {
        return id == null ? null : () => _importCustomerFromLead(id);
      }
      final uri = card?['${key}_uri']?.toString();
      if (uri == null || uri.isEmpty) return null;
      return () => launchUrl(Uri.parse(uri), mode: LaunchMode.externalApplication);
    }

    // CMD #1869 — long-press is how multi-select starts.
    return GestureDetector(
      onLongPress: id == null ? null : () => _enterLeadSelect(id),
      child: Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: selected ? const Color(0xFF1B7A43) : const Color(0xFFE5E7EB),
            width: selected ? 1.5 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Photo, with the score chip (and selection box) overlaid ────────
        SizedBox(
          height: photoH,
          width: double.infinity,
          child: Stack(fit: StackFit.expand, children: [
            if (photoUrl != null && photoUrl.isNotEmpty)
              NativeSignedImage(url: photoUrl, cacheKey: photoUrl)
            else
              // Neutral placeholder of the SAME height so cards stay uniform.
              Container(
                color: const Color(0xFFF3F4F6),
                child: const Center(
                  child: Icon(Icons.storefront_outlined, size: 34, color: Color(0xFF9CA3AF)),
                ),
              ),
            if (selectable && id != null)
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Checkbox(
                    value: selected,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _leadSelection.enter(id);
                      } else if (_leadSelection.contains(id)) {
                        _leadSelection.toggle(id);
                      }
                    }),
                    activeColor: const Color(0xFF1B7A43),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            if (scoreLabel != null && scoreLabel.isNotEmpty)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(scoreLabel,
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            if (alreadyCustomer)
              Positioned(
                bottom: 8,
                left: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F6E56).withValues(alpha: 0.92),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(disabledReason['import']?.toString() ?? '',
                      style: const TextStyle(
                          fontSize: 10.5, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
          ]),
        ),

        // ── Name, type, rating, open, address, phone, review ──────────────
        InkWell(
          onTap: id == null
              ? null
              : () {
                  // CMD #1869 — while a selection is live, a tap picks the
                  // card instead of expanding it.
                  if (_selectMode || _selectedLeadIds.isNotEmpty) {
                    _toggleLeadSelected(id);
                    return;
                  }
                  setState(() {
                    if (expanded) {
                      _expandedIds.remove(id);
                    } else {
                      _expandedIds.add(id);
                    }
                  });
                  if (!expanded &&
                      !_leadDetailCache.containsKey(id) &&
                      !_detailLoading.contains(id)) {
                    _fetchLeadDetail(id);
                  }
                },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                // CMD #1869 — tap the class to reclassify just this lead.
                if (id != null) _leadClassChip(id, r),
                if (typeLabel != null && typeLabel.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF3F4F6),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(typeLabel,
                        style: const TextStyle(
                            fontSize: 10.5, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                  ),
                if (ratingLabel != null && ratingLabel.isNotEmpty)
                  Text(ratingLabel,
                      style: const TextStyle(fontSize: 11.5, color: Color(0xFFD97706))),
                if (openLabel != null && openLabel.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: _colorFromHex(openColors['bg']?.toString(), const Color(0xFFF3F4F6)),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(openLabel,
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: _colorFromHex(
                                openColors['fg']?.toString(), const Color(0xFF6B7280)))),
                  ),
                // CMD #1874 — the revisit engine's chip, on the same row as
                // every other state. Present only when the backend sent a
                // label, which is its answer to "is this lead due again?".
                if ((r['revisit_label']?.toString() ?? '').isNotEmpty)
                  Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x8, vertical: Ds.space.x4),
                    decoration: BoxDecoration(
                        color: Ds.c.warningSoft, borderRadius: Ds.r.rChip),
                    child: Text(r['revisit_label'].toString(),
                        style: Ds.t.caption.copyWith(color: Ds.c.warning)),
                  ),
              ]),
              if (hoursLabel != null && hoursLabel.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(hoursLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
              ],
              if (address != null && address.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ],
              if (phoneDisplay != null && phoneDisplay.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(phoneDisplay,
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
              ],
              if (reviewLabel != null && reviewLabel.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(reviewLabel,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: reviewStale ? FontWeight.w700 : FontWeight.normal,
                        color: reviewStale ? const Color(0xFFB42318) : const Color(0xFF9CA3AF))),
              ],
            ]),
          ),
        ),

        // ── CMD #1869 — Restore, the only way back out of Archived ───────
        if (SLeadsBulk.rowArchived(r) && id != null)
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x12, Ds.space.x8, Ds.space.x12, 0),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _bulkBusy
                    ? null
                    : () => _setLeadStatus([id], 'restore'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  side: BorderSide(color: Ds.c.brand),
                  minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(_bulk['row_restore']?.toString() ?? '',
                    style: Ds.t.body.copyWith(color: Ds.c.brand)),
              ),
            ),
          ),

        // ── CMD #1871 — the branch chip, and the branches behind it ───────
        if (branchesLabel != null && branchesLabel.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x12, Ds.space.x8, Ds.space.x12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: _branchChip(branchesLabel,
                  open: branchesOpen,
                  onTap: (branchesExpandable && id != null)
                      ? () => setState(() {
                            if (branchesOpen) {
                              _expandedBranchIds.remove(id);
                            } else {
                              _expandedBranchIds.add(id);
                            }
                          })
                      : null),
            ),
          ),
        if (branchesOpen)
          _branchPanel(branchesTitle, branchRows, loaded: card != null),

        // ── ONE compact action row, from actions[] ────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
          child: Row(children: [
            for (final a in actions)
              Expanded(
                child: _scrapeActionCompact(
                  a['key']?.toString() ?? '',
                  a['label']?.toString() ?? '',
                  tapFor(a['key']?.toString() ?? '', a['enabled'] != false),
                  disabledReason[a['key']?.toString()]?.toString(),
                ),
              ),
          ]),
        ),

        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: _buildLeadExpandPanel(r, id),
          ),
      ]),
      ),
    );
  }

  /// The lead's own class, tappable. The key comes from get_scraped_leads
  /// (effective_class) and the label from lead_leads_summary().bulk.classes —
  /// nothing here names a class in Dart.
  Widget _leadClassChip(int id, Map<String, dynamic> r) {
    final key = (r['class_key'] ?? r['effective_class'] ?? r['lead_class'])
            ?.toString() ??
        '';
    if (key.isEmpty) return const SizedBox.shrink();
    // The row carries its own rendered label; the bulk block is the fallback.
    final rowLabel = r['class_label']?.toString() ?? '';
    final label = rowLabel.isNotEmpty ? rowLabel : _bulkUi.classLabel(key);
    final title = _bulk['row_reclassify']?.toString() ?? '';
    return Tooltip(
      message: title,
      child: InkWell(
        onTap: _bulkBusy ? null : () => _pickLeadClass([id]),
        borderRadius: Ds.r.rChip,
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x8, vertical: Ds.space.x4),
          decoration: BoxDecoration(
            color: Ds.c.brandSoft,
            borderRadius: Ds.r.rChip,
            border: Border.all(color: Ds.c.brand),
          ),
          child: Text(label,
              style: Ds.t.caption.copyWith(color: Ds.c.brand)),
        ),
      ),
    );
  }

  /// Disabled rather than hidden. Tapping a disabled action surfaces the
  /// backend's disabled_reason for that key instead of doing nothing.
  Widget _scrapeActionCompact(
      String key, String label, VoidCallback? onTap, String? disabledReason) {
    final on = onTap != null;
    const green = Color(0xFF1B7A43);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: on
            ? onTap
            : (disabledReason != null && disabledReason.isNotEmpty)
                ? () => showToast(context, disabledReason)
                : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFECFDF5) : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: on ? const Color(0xFFBBDDC8) : const Color(0xFFE5E7EB)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_scrapeActionIcons[key] ?? Icons.circle_outlined,
                size: 15, color: on ? green : const Color(0xFF9CA3AF)),
            const SizedBox(height: 2),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    color: on ? green : const Color(0xFF9CA3AF))),
          ]),
        ),
      ),
    );
  }

  /// lead_customer_prefill() -> the SAME registration form Import Customer
  /// uses, pre-filled and fully editable. Saving goes through edge
  /// customer-import mode 'import' inside the sheet, never an RPC directly.
  Future<void> _importCustomerFromLead(int leadId) async {
    try {
      final res = await Supabase.instance.client
          .rpc('lead_customer_prefill', params: {'p_lead_id': leadId});
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;

      if (m['error'] != null) {
        showToast(context, (m['hint'] ?? m['error']).toString(), isError: true);
        await _refreshLeadCard(leadId);
        return;
      }

      final note = m['note']?.toString();
      if (note != null && note.isNotEmpty) showToast(context, note);

      final customer =
          m['customer'] is Map ? Map<String, dynamic>.from(m['customer'] as Map) : <String, dynamic>{};
      final missing =
          (m['missing'] as List?)?.map((e) => e.toString()).toList() ?? const <String>[];

      final saved =
          await ImportCustomerSheet.open(context, prefill: customer, missing: missing);
      if (saved == true && mounted) {
        await _refreshLeadCard(leadId);
        await _loadRows(reset: true);
        await _refreshSummaryAndUsage();
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, '$e', isError: true);
    }
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
          Text(c('admin_customer.hours'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280))),
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
          Text(c('admin_customer.reviews'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280))),
          const SizedBox(height: 4),
          ...fullReviews.take(3).map((rv) {
            final m = Map<String, dynamic>.from(rv as Map);
            final author = (m['authorAttribution'] as Map?)?['displayName']?.toString() ?? '';
            final rrating = m['rating']?.toString() ?? '';
            final text = (m['text'] as Map?)?['text']?.toString() ?? '';
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(cf('admin_customer.review_line', {'author': '$author', 'rating': rrating.isNotEmpty ? ' ($rrating★)' : '', 'text': '$text'}),
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic, color: Color(0xFF4B5563))),
            );
          }),
          const SizedBox(height: 4),
        ] else if (reviewSnippets.isNotEmpty) ...[
          Text(c('admin_customer.reviews'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280))),
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
              c('admin_customer.more_numbers') +
              '${[if (intlPhone != null && intlPhone.isNotEmpty) intlPhone, ...websitePhones].join(', ')}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
          const SizedBox(height: 10),
        ],
        if (editorialSummary != null && editorialSummary.isNotEmpty)
          Text(editorialSummary,
              style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Color(0xFF6B7280))),
        if (loading) ...[
          const SizedBox(height: 10),
          Row(children: [
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 6),
            Text(c('admin_customer.loading_full_detail'), style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
          ]),
        ],
      ]),
    );
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
          Text(cf('admin_customer.saved_scrapes', {'n': '${_runs.length}'}),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8)),
          child: Text(
            // CHANGE #686 — the template ended on a dangling ' · ' because
            // the last two counts were concatenated here, separator and
            // wording included. All six counts are slots now.
            cf('admin_customer.enrich_summary', {
              'enriched': '$enriched',
              'errors': '$errors',
              'photos': '$withPhoto',
              'hours': '$withHours',
              'websites': '$withWebsite',
              'emails': '$withEmail',
            }),
            style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563)),
          ),
        ),
        const SizedBox(height: 14),
        if (_runs.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(c('admin_customer.no_scrapes'), style: const TextStyle(fontSize: 12.5, color: Color(0xFF9CA3AF))),
          )
        else
          Column(children: _runs.map(_buildRunCard).toList()),
      ]),
    );
  }

  /// CHANGE #552 — one card per saved run, entirely from scrape_runs_list():
  /// city, date, the status chip (colours included), types_label and
  /// summary_label. Expanding shows breakdown[] as a small table.
  Widget _buildRunCard(Map<String, dynamic> r) {
    final view = ScrapeRunView.from(r);
    final runId = view.runId;
    final expanded = _expandedRuns.contains(runId);
    final busy = _runBusy.contains(runId);
    final breakdown = _mapList(r['breakdown']);
    final typesLabel = view.typesLabel;
    final summaryLabel = view.summaryLabel;
    // CMD #1870 — one more backend sentence: what the Include chips kept and
    // what they threw away before anything was stored.
    final keptDropped = view.keptDroppedLabel;
    final error = view.error;
    RenderLog.write('c1870_run_cards', _runs.length);
    RenderLog.write('c1870_kept_dropped',
        _runs.where((x) => ScrapeRunView.from(x).keptDroppedLabel != null).length);
    RenderLog.write('c1870_delete_actions',
        _runs.where((x) => ScrapeRunView.from(x).canDelete).length);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() {
            if (!_expandedRuns.remove(runId)) _expandedRuns.add(runId);
          }),
          borderRadius: BorderRadius.circular(8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text(
                    '${r['city'] ?? ''} · ${_fmtRunDate(r['created_at']?.toString())}',
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              ),
              _runStatusChip(r),
              Icon(expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18, color: const Color(0xFF9CA3AF)),
            ]),
            if (typesLabel.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(typesLabel,
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
            ],
            if (summaryLabel.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(summaryLabel,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563))),
            ],
            if (keptDropped != null) ...[
              const SizedBox(height: 2),
              Text(keptDropped,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF4B5563))),
            ],
            if (error != null && error.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(error, style: const TextStyle(fontSize: 11.5, color: Color(0xFFB42318))),
            ],
          ]),
        ),
        if (expanded) ...[
          const SizedBox(height: 10),
          if (breakdown.isNotEmpty) _runBreakdownTable(breakdown),
          const SizedBox(height: 10),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _runActionButton('Save file', Icons.download_outlined,
                busy ? null : () => _exportRun(r, share: false)),
            _runActionButton('Share', Icons.ios_share,
                busy ? null : () => _exportRun(r, share: true)),
            if (view.delete != null)
              _runActionButton(view.delete!.label, Icons.delete_outline,
                  busy ? null : () => _deleteRun(r), danger: true),
            if (busy)
              const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
        ],
      ]),
    );
  }

  Widget _runBreakdownTable(List<Map<String, dynamic>> breakdown) {
    const head = TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: Color(0xFF6B7280));
    const cell = TextStyle(fontSize: 11.5, color: Color(0xFF374151));
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(2.2),
        1: FlexColumnWidth(1),
        2: FlexColumnWidth(1.2),
        3: FlexColumnWidth(1.2),
      },
      border: TableBorder(
          horizontalInside: BorderSide(color: const Color(0xFFE5E7EB).withValues(alpha: 0.8))),
      children: [
        TableRow(children: [
          Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text(c('admin_customer.col_type'), style: head)),
          Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text(c('admin_customer.col_count'), style: head)),
          Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text(c('admin_customer.col_phone'), style: head)),
          Padding(padding: EdgeInsets.symmetric(vertical: 4), child: Text(c('admin_customer.col_photo'), style: head)),
        ]),
        ...breakdown.map((b) => TableRow(children: [
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(b['type']?.toString() ?? '',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: cell)),
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('${b['count'] ?? 0}', style: cell)),
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('${b['with_phone'] ?? 0}', style: cell)),
              Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text('${b['with_photo'] ?? 0}', style: cell)),
            ])),
      ],
    );
  }

  Widget _runActionButton(String label, IconData icon, VoidCallback? onTap,
      {bool danger = false}) {
    final color = danger ? const Color(0xFFB42318) : const Color(0xFF1B7A43);
    return OutlinedButton.icon(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: onTap == null ? const Color(0xFFD1D5DB) : color),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      icon: Icon(icon, size: 15),
      label: Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  /// scrape_run_export() builds the whole JSON payload AND names the file.
  /// Dart only writes those bytes out — it never assembles the export.
  Future<void> _exportRun(Map<String, dynamic> r, {required bool share}) async {
    final runId = r['run_id']?.toString();
    if (runId == null) return;
    setState(() => _runBusy.add(runId));
    try {
      final res = await Supabase.instance.client
          .rpc('scrape_run_export', params: {'p_run_id': runId});
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final filename = m['filename']?.toString() ?? '$runId.json';
      final bytes = utf8.encode(jsonEncode(m));
      RenderLog.write('c552_export', filename);
      if (!mounted) return;
      setState(() => _runBusy.remove(runId));
      if (share) {
        final ok = await shareBytes(bytes, filename, 'application/json');
        // null = this browser has no Web Share for files -> save instead.
        if (ok == null) downloadBytes(bytes, filename, 'application/json');
      } else {
        downloadBytes(bytes, filename, 'application/json');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _runBusy.remove(runId));
      showToast(context, '$e', isError: true);
    }
  }

  /// CMD #1870 — deleting a run ARCHIVES its leads (the CMD #1869 lane:
  /// Restore from the Archived filter, auto-purged after the backend's own
  /// number of days) and soft-deletes the run. There is no checkbox any more:
  /// the choice used to be the client's, and a hard DELETE made a mis-typed
  /// city unrecoverable. Every word of the confirmation — title, body with
  /// the count in it, both buttons — is scrape_runs_list().delete, printed.
  Future<void> _deleteRun(Map<String, dynamic> r) async {
    final view = ScrapeRunView.from(r);
    final d = view.delete;
    final runId = view.runId;
    if (d == null || runId.isEmpty) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(d.title),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${view.city} · ${_fmtRunDate(r['created_at']?.toString())}',
              style: Ds.t.body),
          SizedBox(height: Ds.space.x8),
          Text(d.body, style: Ds.t.caption),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dCtx, false), child: Text(d.cancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ds.c.danger),
            onPressed: () => Navigator.pop(dCtx, true),
            child: Text(d.ok),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _runBusy.add(runId));
    try {
      final res = await Supabase.instance.client
          .rpc('scrape_run_delete', params: {'p_run_id': runId});
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _runBusy.remove(runId);
        _expandedRuns.remove(runId);
        if (_sourceRunId == runId) _sourceRunId = null;
        if (_resultsRunId == runId) {
          _resultsRunId = null;
          _runLeads = [];
          _leadSelection.clear();
        }
      });
      RenderLog.write('c1870_run_deleted', '${m['archived'] ?? 0}');
      final msg = (m['message'] ?? m['error'])?.toString();
      if (msg != null && msg.isNotEmpty) {
        showToast(context, msg, isError: m['ok'] != true);
      }
      await _loadPastRuns();
      await _refreshSummaryAndUsage();
      await _refreshFilterModel();
      await _loadRows(reset: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _runBusy.remove(runId));
      showToast(context, '$e', isError: true);
    }
  }

  /// Status chip — label AND colours come from scrape_runs_list().status_colors.
  Widget _runStatusChip(Map<String, dynamic> r) {
    final status = r['status']?.toString() ?? '';
    final colors = r['status_colors'] is Map
        ? Map<String, dynamic>.from(r['status_colors'] as Map)
        : const <String, dynamic>{};
    final bg = _colorFromHex(colors['bg']?.toString(), const Color(0xFFF3F4F6));
    final fg = _colorFromHex(colors['fg']?.toString(), const Color(0xFF6B7280));
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(status,
          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: fg)),
    );
  }

  // CHANGE #548: backend-formatted (ist_fmt 'dmy').
  String _fmtRunDate(String? iso) =>
      DateLabels.instance.label(iso, DateStyle.dmy) ?? '';
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

// CHANGE #551: the hardcoded 8-outcome list is DELETED. The options, their
// order and their labels all come from lead_checkin_sheet().outcome.options[],
// and option.key is posted back to record_visit(p_status:) verbatim.

class _RoutesTab extends StatefulWidget {
  static final GlobalKey<_RoutesTabState> _routesKey = GlobalKey<_RoutesTabState>();

  /// Cross-screen entry point (via AdminCustomerScreen.triggerOptimizeAllRoutes) —
  /// the Supplier Shop tab's map dropdown "Optimize route" badge calls this
  /// exact function, reusing the flow verbatim rather than reimplementing it.
  /// Returns false when this sub-tab isn't currently mounted (only built
  /// while the Route sub-tab is the active Customer-screen filter).
  static bool triggerOptimizeAllRoutes() {
    final state = _routesKey.currentState;
    if (state == null) return false;
    state._optimizeAllRoutesWithGoogle();
    return true;
  }

  /// CMD #1876 — the deep link's route.
  ///
  /// This sub-tab is built only while Routes is the active filter, and on a
  /// cold start that is several seconds of auth and fetching away — far longer
  /// than a post-frame retry survives. So the id is PARKED and the tab's own
  /// initState collects it: whenever this widget next mounts, it opens that
  /// route. Already mounted → open it now.
  static String? _pendingRouteId;

  static bool openRoute(String routeId) {
    final state = _routesKey.currentState;
    if (state == null) {
      _pendingRouteId = routeId;
      return false;
    }
    state.openRouteById(routeId);
    return true;
  }

  /// Consumed once, by the state that mounts next.
  static String? takePendingRoute() {
    final id = _pendingRouteId;
    _pendingRouteId = null;
    return id;
  }

  final bool isDesktop;
  final ValueChanged<int> onZonesChanged;
  final VoidCallback onOpenWarehouseCard;
  _RoutesTab({
    required this.isDesktop,
    required this.onZonesChanged,
    required this.onOpenWarehouseCard,
  }) : super(key: _routesKey);

  @override
  State<_RoutesTab> createState() => _RoutesTabState();
}

class _RoutesTabState extends State<_RoutesTab> {
  bool _loading = true;
  String? _loadError;

  // ── D: top-level view — 'today' (CMD #1872 landing), 'builder' (admin
  // plan builder) or 'myRoute' (rep check-in). The tab OPENS on 'today'.
  String _topMode = 'today';
  Map<String, dynamic>? _myRoute; // my_route() response, refetched after check-in
  bool _myRouteLoading = false;

  /// CMD #1872 — routes_today(): the route assigned to the logged-in worker
  /// for admin_active_date() in admin_active_zone(), or every route for that
  /// date (with worker names) for an admin. Title, header, count, progress
  /// line, Navigate caption, empty state and the mode-row captions all arrive
  /// in this payload and are printed verbatim.
  Map<String, dynamic>? _today;
  bool _todayLoading = false;

  /// CMD #1877 — route_day_summary(): what the field team actually did for
  /// admin_active_date() in admin_active_zone(). Drawn as the card at the top
  /// of this tab and, from the same payload's `strip`, on the Leads tab. Every
  /// count, km figure, ₹ string and percentage is the backend's own wording.
  RouteDaySummary? _daySummary;

  /// CMD #1873 — route_stops_today(route_id) per today-route card: the stop
  /// rows, their outcome chips, the "Closed at ETA" warning and the actions
  /// (Check in / Skip). Cached by route id; refetched after every check-in.
  final Map<String, Map<String, dynamic>> _routeStops = {};
  final Set<String> _routeStopsInFlight = {};

  // ── B1: filter bar — the ONLY inputs that drive the count + build ────────
  String _city = 'Raipur';

  /// CHANGE #552 — the Store-type chips are no longer a Dart list. They come
  /// from lead_category_tree('route'), the SAME taxonomy the scrape form uses.
  List<_LeadCategoryNode> _routeCats = const [];
  final Set<String> _expandedRouteCats = {};

  /// lead_class values that actually exist in scraped_leads, read from
  /// lead_leads_summary().by_class. Needed because the route RPCs still filter
  /// on scraped_leads.lead_class while the chips now speak category keys —
  /// see _classesForSelection().
  List<String> _leadClassValues = const [];

  Set<String> _classes = {};
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
  // CHANGE #550: the Map/List toggle is gone; this is the selected stop-range
  // window (0 = stops 1-10, 1 = 11-20, ...).
  final Map<String, int> _routeStopWindow = {};

  /// CHANGE #550 — lead_stop_card() payloads, keyed by lead_id. The card's
  /// photo, labels, action buttons and URIs are ALL backend-owned; nothing is
  /// constructed here.
  final Map<String, Map<String, dynamic>> _stopCards = {};
  final Set<String> _stopCardsInFlight = {};
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

  // ── CMD #1875: "Rebuild from current leads" is in flight. The rebuilt plan
  // is QUEUED, so the card keeps showing the backend's own build_stage until
  // route_plans realtime says it is ready.
  bool _rebuilding = false;

  // ── C5: past plans, collapsible, lazy-loaded ──────────────────────────────
  bool _pastPlansExpanded = false;
  // CHANGE #1867 — route_plan_list() is paged and its rows are built lazily.
  // Same envelope, same two paging decisions, same class as S Leads.
  PagedList? _plans;
  List<Map<String, dynamic>>? get _pastPlans => _plans?.rows;
  bool _plansMoreLoading = false;
  static const int _plansPageSize = 20;
  final ScrollController _plansCtrl = ScrollController();
  // ── CHANGE #486: realtime status (queued/building/ready) — replaces the
  // old #483 4s poll. Patches the affected card in place, no full reload.
  LiveFeedHandle? _planRealtimeChannel;

  // ── D3: Today's Visits (admin, collapsible, lazy-loaded) — unchanged from #446
  bool _visitsExpanded = false;
  bool _visitsLoading = false;
  Map<String, dynamic>? _visitsReport;

  /// Resolves the selected category keys into the lead_class values the route
  /// RPCs (route_lead_count / route_plan_build) still filter on.
  ///
  /// CHANGE #552 note: lead_categories is the new source of truth for the
  /// taxonomy, but scraped_leads.lead_class was never migrated onto those
  /// keys and no route RPC accepts category keys yet. So a key is matched
  /// against the lead_class values the backend reports as actually present —
  /// exactly ('clinic' -> 'clinic') or as a prefix ('medical' ->
  /// 'medical_store'). No class name is written in Dart. Once the route RPCs
  /// take p_categories this whole function goes away.
  Widget _routeCatChip(String label, String key) {
    final sel = _classes.contains(key);
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 11.5)),
      selected: sel,
      onSelected: (v) {
        setState(() {
          if (v) { _classes.add(key); } else { _classes.remove(key); }
        });
        _onFilterChanged();
      },
      selectedColor: const Color(0xFFDCFCE7),
      checkmarkColor: const Color(0xFF1B7A43),
      backgroundColor: const Color(0xFFF3F4F6),
      side: BorderSide(color: sel ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
      labelStyle: TextStyle(color: sel ? const Color(0xFF1B7A43) : const Color(0xFF374151)),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }

  List<String> _classesForSelection() {
    final out = <String>{};
    for (final k in _classes) {
      for (final v in _leadClassValues) {
        if (v == k || v.startsWith('${k}_')) out.add(v);
      }
      out.add(k); // harmless if unmatched; lets a migrated backend work as-is
    }
    return out.toList();
  }

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

  /// CMD #1876 — set while a deep-linked route is being opened, so the
  /// screen-load default below cannot drop the view back onto 'today'.
  String? _openingRouteId;

  @override
  void initState() {
    super.initState();
    _openingRouteId = _RoutesTab.takePendingRoute();
    _loadScreen();
    _subscribePlanRealtime();
    final pending = _openingRouteId;
    if (pending != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => openRouteById(pending));
    }
  }

  @override
  void dispose() {
    _countDebounce?.cancel();
    _plansCtrl.dispose();
    _planRealtimeChannel?.unsubscribe();
    _planRealtimeChannel = null;
    super.dispose();
  }

  // ── CHANGE #486: subscribe once for the widget's lifetime; INSERT/UPDATE
  // events patch _pastPlans directly from the payload (no refetch, no
  // flicker). Ignored while _pastPlans hasn't been loaded yet — the next
  // expand fetches it fresh via route_plan_list() anyway.
  void _subscribePlanRealtime() {
    // CHANGE #643: route_plans is an admin list feed and no longer publishes,
    // so there is no per-row payload to patch from. The list is refetched with
    // route_plan_list() — the same call the expand and the clear-old path
    // already used, and the one that was always the fallback "so the count is
    // right even if a realtime event is missed".
    LiveFeed.instance
        .watch(
          channelPrefix: 'route_plans_changes',
          tables: const ['route_plans'],
          onChange: (_) {
            _refetchPlans();
            // CMD #1875 — a rebuilt plan is queued, then built by the drain.
            // The open card must follow it to 'ready' on its own.
            final id = _planId;
            if (id != null && _planIsBuilding) _loadPlan(id);
          },
        )
        .then((h) {
      if (!mounted) {
        h.dispose();
        return;
      }
      _planRealtimeChannel?.unsubscribe();
      _planRealtimeChannel = h;
      RenderLog.write('c486_autocluster_realtime', 1);
    });
  }

  /// CHANGE #1867 — ONE page of route_plan_list(p_limit, p_offset). `reset`
  /// starts at offset 0 and replaces the list; otherwise the payload's own
  /// next_offset is appended. Only the rows just fetched get their
  /// plan_google_status badge, so appending never re-fetches the page above.
  Future<void> _loadPlans({bool reset = false}) async {
    if (!mounted) return;
    final held = _plans ?? const PagedList();
    final offset = held.offsetFor(reset: reset);
    if (!reset) setState(() => _plansMoreLoading = true);
    try {
      final res = await Supabase.instance.client.rpc('route_plan_list',
          params: {'p_limit': _plansPageSize, 'p_offset': offset});
      final env = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      final next = held.applyPage(env, reset: reset);
      if (!mounted) return;
      final page = next.rows.sublist(reset ? 0 : held.rows.length);
      setState(() {
        _plans = next;
        _plansMoreLoading = false;
      });
      RenderLog.write('c1867_plan_page_rows', page.length);
      RenderLog.write('c1867_plans_loaded', next.rows.length);
      // CMD #1875 — the ₹ chip on a saved-plan row is the ONLY part of this
      // change that paints without a tap, so it is the one the render-log can
      // prove. Count the rows the backend priced; 0 here means route_plan_list
      // stopped sending cost_label and the chip is gone.
      RenderLog.write(
          'c1875_list_cost_chips',
          next.rows
              .where((r) => (r['cost_label']?.toString() ?? '').isNotEmpty)
              .length);
      _fetchOptStatusFor(page);
    } catch (_) {
      if (mounted) setState(() => _plansMoreLoading = false);
    }
  }

  /// One refetch, used by every path that needs the plan list to be current.
  /// It re-reads page 1 only — a realtime tick must not silently drop the
  /// pages the user already scrolled past, and it must not refetch them all.
  Future<void> _refetchPlans() async {
    if (_plans == null || !mounted) return;
    await _loadPlans(reset: true);
  }

  /// CHANGE #1867 — infinite scroll inside the past-plans panel.
  void _onPlansScroll() {
    if (!_plansCtrl.hasClients) return;
    final pos = _plansCtrl.position;
    if (pos.pixels < pos.maxScrollExtent - 240) return;
    if (_plansMoreLoading || !(_plans?.canLoadMore ?? false)) return;
    _loadPlans();
  }

  // CHANGE #548: backend-formatted (ist_fmt 'dmy2_hm').
  String _planWhenLabel(String? createdAt) =>
      DateLabels.instance.label(createdAt, DateStyle.dmy2Hm) ?? '';


  /// CHANGE #552 — chips + their lead_class mapping, both backend-sourced.
  /// Best-effort: a failure here leaves the chip row empty rather than
  /// falling back to a hardcoded list.
  Future<void> _loadRouteTaxonomy() async {
    try {
      final client = Supabase.instance.client;
      final res = await Future.wait<dynamic>([
        _fetchCategoryTree('route'),
        client.rpc('lead_leads_summary', params: {'p_city': null}),
      ]);
      final cats = res[0] as List<_LeadCategoryNode>;
      final summary = Map<String, dynamic>.from(res[1] as Map);
      final classes = ((summary['by_class'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e['class']?.toString() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
      RenderLog.write('c552_route_cats', cats.length);
      if (!mounted) return;
      setState(() {
        _routeCats = cats;
        _leadClassValues = classes;
        // Default selection is the backend's first category, not a Dart key.
        if (_classes.isEmpty && cats.isNotEmpty) _classes = {cats.first.key};
      });
    } catch (_) {}
  }

  Future<void> _loadScreen() async {
    setState(() { _loading = true; _loadError = null; });
    try {
      await _loadRouteTaxonomy();
      // routes_today() raises not_authorized for anyone who is neither an
      // admin nor a lead worker. That must NOT take the whole tab down with
      // it — the builder still loads, so the new call is caught on its own.
      final res = await Future.wait<dynamic>([
        Supabase.instance.client.rpc('my_route'),
        Supabase.instance.client.rpc('routes_today').catchError((_) => null),
        // CMD #1877 — the day summary is answered for the same date and zone.
        // Caught on its own for the same reason as routes_today(): a caller it
        // does not serve must lose the card, never the tab.
        Supabase.instance.client.rpc('route_day_summary').catchError((_) => null),
      ]);
      final myRoute = Map<String, dynamic>.from(res[0] as Map);
      final today = res[1] is Map
          ? Map<String, dynamic>.from(res[1] as Map)
          : <String, dynamic>{};
      final day = res[2] is Map
          ? RouteDaySummary.from(Map<String, dynamic>.from(res[2] as Map))
          : null;
      if (!mounted) return;
      setState(() {
        _myRoute = myRoute;
        _today = today;
        _daySummary = day;
        // CMD #1872 — the tab opens on today's assigned route for EVERY role.
        // 'All plans' (the builder) and 'Check in' are secondary links, and
        // the payload names them.
        // CMD #1876 — a deep-linked route owns the mode; routes_today() must
        // not pull the view back to 'today' underneath it.
        _topMode = _openingRouteId != null
            ? 'builder'
            : (today['ok'] == true ? 'today' : 'builder');
        _loading = false;
      });
      _logToday(today);
      _logDaySummary(day);
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

  /// CMD #1872 — one refetch of routes_today(). Used by the mode row, by
  /// pull-to-retry and after a check-in, so the progress line and the next
  /// stop the Navigate button opens are always the backend's current answer.
  Future<void> _refreshToday() async {
    if (!mounted) return;
    setState(() => _todayLoading = true);
    try {
      // CMD #1877 — a check-in changes BOTH the route progress line and the
      // day summary, so the two are refetched together and never disagree on
      // screen.
      final res = await Future.wait<dynamic>([
        Supabase.instance.client.rpc('routes_today'),
        Supabase.instance.client.rpc('route_day_summary').catchError((_) => null),
      ]);
      if (!mounted) return;
      final today =
          res[0] is Map ? Map<String, dynamic>.from(res[0] as Map) : <String, dynamic>{};
      final day = res[1] is Map
          ? RouteDaySummary.from(Map<String, dynamic>.from(res[1] as Map))
          : null;
      setState(() {
        _today = today;
        if (day != null) _daySummary = day;
        _todayLoading = false;
      });
      _logToday(today);
      _logDaySummary(day);
    } catch (_) {
      if (mounted) setState(() => _todayLoading = false);
    }
  }

  void _logToday(Map<String, dynamic> today) {
    final rows = (today['routes'] as List?) ?? const [];
    RenderLog.write('c1872_today_routes', rows.length);
    RenderLog.write(
        'c1872_nav_ready',
        rows
            .whereType<Map>()
            .where((e) => e['can_navigate'] == true)
            .length);
  }

  /// CMD #1877 — the card PAINTED. worker rows and converted are reported
  /// separately: a day with no field work is a legitimate render of the
  /// backend's own empty copy, so a count of 0 must not read as "never drew".
  void _logDaySummary(RouteDaySummary? day) {
    if (day == null) return;
    RenderLog.write('c1877_day_card', day.showCard ? 1 : 0);
    RenderLog.write('c1877_day_workers', day.workers.length);
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
        'p_classes': _classesForSelection(),
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
        'p_classes': _classesForSelection(),
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
      _routeStopWindow.removeWhere((id, _) => !validIds.contains(id));
      for (final id in _expandedRouteIds) {
        _loadRouteMap(id);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() { _buildingPlan = false; _planError = e.toString(); });
    }
  }

  /// CMD #1875 — true while the OPEN plan has not finished building. The
  /// status and the stage caption are the backend's; nothing is inferred.
  bool get _planIsBuilding {
    final st = (_plan?['header'] as Map?)?['status']?.toString();
    return st == 'queued' || st == 'building';
  }

  /// CMD #1875 — the ₹ chips. Every string is the backend's own
  /// (cost_label / cost_per_converted_label / converted_label): Dart never
  /// does money arithmetic and never formats a rupee.
  Widget _costChips(Map<String, dynamic> m) {
    final model = RouteCostChips.from(m);
    if (model.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x8),
      child: Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x4,
        children: model.chips.map(_toneChip).toList(),
      ),
    );
  }

  /// The ONLY place a tone name becomes a colour. RouteCostChips decides which
  /// chips exist; Ds decides what they look like.
  Widget _toneChip(RouteCostChip chip) {
    switch (chip.tone) {
      case RouteChipTone.brand:
        return _tokenChip(chip.label, Ds.c.brandSoft, Ds.c.brand);
      case RouteChipTone.success:
        return _tokenChip(chip.label, Ds.c.successSoft, Ds.c.success);
      case RouteChipTone.info:
        return _tokenChip(chip.label, Ds.c.infoSoft, Ds.c.info);
      case RouteChipTone.warning:
        return _tokenChip(chip.label, Ds.c.warningSoft, Ds.c.warning);
      case RouteChipTone.danger:
        return _tokenChip(chip.label, Ds.c.dangerSoft, Ds.c.danger);
      case RouteChipTone.muted:
        return _tokenChip(chip.label, Ds.c.bg, Ds.c.textSecondary);
    }
  }

  Widget _tokenChip(String label, Color bg, Color fg) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
        child: Text(label,
            style: Ds.t.caption.copyWith(color: fg, fontWeight: FontWeight.w600)),
      );

  void _toast(String? msg) {
    if (msg == null || msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// CMD #1875 — "Rebuild from current leads". The preview counts the leads
  /// that pass the S Leads DEFAULT filters right now (archived, non-target and
  /// matched are out; the header zone and date apply), and every word of the
  /// confirmation is that payload printed verbatim.
  Future<void> _openRebuildSheet() async {
    final planId = _planId;
    if (planId == null) return;
    Map<String, dynamic> pv;
    try {
      final res = await Supabase.instance.client
          .rpc('route_plan_rebuild_preview', params: {'p_plan_id': planId});
      pv = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    } catch (e) {
      _toast(e.toString());
      return;
    }
    if (!mounted) return;
    RenderLog.write('c1875_rebuild_preview', (pv['leads'] as num?)?.toInt() ?? 0);
    final canRebuild = pv['can_rebuild'] == true;
    final go = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(pv['title']?.toString() ?? '', style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            Text(pv['body']?.toString() ?? '', style: Ds.t.body),
            if ((pv['hint']?.toString() ?? '').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(pv['hint'].toString(), style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x24),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(pv['cancel_label']?.toString() ?? ''),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: FilledButton(
                  onPressed: canRebuild ? () => Navigator.pop(ctx, true) : null,
                  child: Text(pv['confirm_label']?.toString() ?? ''),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
    if (go != true) return;
    setState(() => _rebuilding = true);
    try {
      final res = await Supabase.instance.client
          .rpc('route_plan_rebuild', params: {'p_plan_id': planId});
      final out = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;
      setState(() => _rebuilding = false);
      _toast((out['toast'] ?? out['message'])?.toString());
      if (out['ok'] == true) {
        RenderLog.write('c1875_rebuilt_version', (out['version'] as num?)?.toInt() ?? 0);
        await _loadPlan(out['plan_id'].toString(), isNewBuild: true);
        await _refetchPlans();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _rebuilding = false);
      _toast(e.toString());
    }
  }

  /// CMD #1875 — the ₹/km and ₹/hour rates behind every cost chip. They live
  /// in app_settings, so changing them re-prices every plan with no deploy.
  Future<void> _openRatesSheet() async {
    Map<String, dynamic> r;
    try {
      final res = await Supabase.instance.client.rpc('route_rates_get');
      r = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    } catch (e) {
      _toast(e.toString());
      return;
    }
    if (!mounted) return;
    final kmCtrl = TextEditingController(text: '${r['km_rate'] ?? ''}');
    final hrCtrl = TextEditingController(text: '${r['hour_rate'] ?? ''}');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x24),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['title']?.toString() ?? '', style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x8),
              Text(r['hint']?.toString() ?? '', style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              TextField(
                controller: kmCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: r['km_label']?.toString() ?? ''),
              ),
              SizedBox(height: Ds.space.x12),
              TextField(
                controller: hrCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: r['hour_label']?.toString() ?? ''),
              ),
              SizedBox(height: Ds.space.x24),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: Text(r['cancel_label']?.toString() ?? ''),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: Text(r['save_label']?.toString() ?? ''),
                  ),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
    if (saved != true) return;
    try {
      final res = await Supabase.instance.client.rpc('route_rates_set', params: {
        'p_km_rate': num.tryParse(kmCtrl.text.trim()) ?? r['km_rate'],
        'p_hour_rate': num.tryParse(hrCtrl.text.trim()) ?? r['hour_rate'],
      });
      final out = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      _toast(out['toast']?.toString());
      RenderLog.write('c1875_rates_saved', 1);
      if (_planId != null) await _loadPlan(_planId!);
      await _refetchPlans();
    } catch (e) {
      _toast(e.toString());
    }
  }

  void _rebuild() {
    setState(() {
      _plan = null;
      _planId = null;
      _planError = null;
      _routeMapData.clear();
      _routeMapLoading.clear();
      _routeStopWindow.clear();
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
        final pos = await geo.getCurrentPosition(enableHighAccuracy: true);
        final lat = pos?.lat;
        final lng = pos?.lng;
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
          title: Text(c('admin_customer.optimize_routes_q')),
          content: Text(cf('admin_customer.optimize_body', {'n': '$toOptimize', 'm': '$toOptimize'})),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(c('admin_customer.cancel'))),
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
        title: Text(c('admin_customer.rebalance_routes_q')),
        content: Text(c('admin_customer.rebalance_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(c('admin_customer.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            onPressed: () => Navigator.pop(dCtx, true),
            child: Text(c('admin_customer.rebalance')),
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

  // ── CMD #1876: bulk "visiting today" to every stop on a route ─────────────
  //
  // Two RPCs, nothing decided here. route_message_stops_sheet() says what the
  // confirm sheet reads and whether there is anyone to reach; route_message_stops()
  // does the sending through the SAME switchboard every other WhatsApp uses
  // (wa_send_event_or_fallback), so the opt-out, notification and dedupe rails
  // are the ones already in place. Every count and every skip reason below is
  // a string the backend wrote — this widget only prints them.
  final Set<String> _msgStopsBusy = <String>{};

  Future<void> _openMessageStopsSheet(Map<String, dynamic> route) async {
    final routeId = route['route_id']?.toString() ?? '';
    if (routeId.isEmpty || _msgStopsBusy.contains(routeId)) return;
    Map<String, dynamic> sheet;
    try {
      final res = await Supabase.instance.client
          .rpc('route_message_stops_sheet', params: {'p_route_id': routeId});
      sheet = Map<String, dynamic>.from(res as Map);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), isError: true);
      return;
    }
    if (!mounted) return;
    if (sheet['ok'] != true) {
      showToast(context, sheet['message']?.toString() ?? '', isError: true);
      return;
    }
    RenderLog.write('c1876_msg_sheet', sheet['reachable'] ?? 0);
    final canSend = sheet['can_send'] == true;
    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x24, Ds.space.x24, Ds.space.x24, Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(sheet['title']?.toString() ?? '', style: Ds.t.title),
          SizedBox(height: Ds.space.x8),
          Text(sheet['body']?.toString() ?? '', style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x12),
          Text(
              (canSend
                      ? sheet['count_label']?.toString()
                      : sheet['blocked_label']?.toString()) ??
                  '',
              style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(sheet['cancel_label']?.toString() ?? '')),
            SizedBox(width: Ds.space.x12),
            FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  minimumSize: Size(Ds.space.x48 * 2, Ds.touch.minTarget)),
              onPressed: canSend ? () => Navigator.pop(ctx, true) : null,
              child: Text(sheet['send_label']?.toString() ?? ''),
            ),
          ]),
        ]),
      ),
    );
    if (go != true || !mounted) return;

    setState(() => _msgStopsBusy.add(routeId));
    Map<String, dynamic> result;
    try {
      final res = await Supabase.instance.client
          .rpc('route_message_stops', params: {'p_route_id': routeId});
      result = Map<String, dynamic>.from(res as Map);
    } catch (e) {
      if (!mounted) return;
      setState(() => _msgStopsBusy.remove(routeId));
      showToast(context, e.toString(), isError: true);
      return;
    }
    if (!mounted) return;
    setState(() => _msgStopsBusy.remove(routeId));
    if (result['ok'] != true) {
      showToast(context, result['message']?.toString() ?? '', isError: true);
      return;
    }
    final parsed = RouteMessageResult.fromPayload(result);
    RenderLog.write('c1876_msg_sent', parsed.sent);
    RenderLog.write('c1876_msg_skipped', parsed.skipped);
    _showMessageStopsResult(parsed);
  }

  void _showMessageStopsResult(RouteMessageResult result) {
    final rows = result.orderedRows;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x24, Ds.space.x24, Ds.space.x24, Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(result.title, style: Ds.t.title),
          SizedBox(height: Ds.space.x8),
          Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
            _c1876Chip(result.sentLabel, 'success'),
            _c1876Chip(result.skippedLabel, 'warning'),
          ]),
          SizedBox(height: Ds.space.x12),
          Text(result.summaryLabel, style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x16),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: Ds.space.x48 * 6),
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: rows.length,
              separatorBuilder: (_, __) => Divider(height: Ds.space.x16, color: Ds.c.divider),
              itemBuilder: (_, i) {
                final r = rows[i];
                return Row(children: [
                  Expanded(
                      child: Text(r.name,
                          style: Ds.t.body, overflow: TextOverflow.ellipsis)),
                  SizedBox(width: Ds.space.x8),
                  _c1876Chip(r.label, r.tone),
                ]);
              },
            ),
          ),
          SizedBox(height: Ds.space.x16),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(UiCopy.t('routes.msg_stops_cancel'))),
          ),
        ]),
      ),
    );
  }

  /// Tone name → the token pair for it. The NAME is the backend's; the colours
  /// are always the design system's, never a hex written here.
  Widget _c1876Chip(String text, String tone) {
    final bg = tone == 'success' ? Ds.c.successSoft : Ds.c.warningSoft;
    final fg = tone == 'success' ? Ds.c.success : Ds.c.warning;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
      child: Text(text, style: Ds.t.caption.copyWith(color: fg)),
    );
  }

  /// CMD #1876 — a WhatsApp link carries a ROUTE id. route_open() resolves the
  /// plan that holds it, so the deep link is one backend answer rather than a
  /// client-side hunt through every plan.
  Future<void> openRouteById(String routeId) async {
    if (routeId.isEmpty) return;
    try {
      final res = await Supabase.instance.client
          .rpc('route_open', params: {'p_route_id': routeId});
      final data = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      if (data['ok'] != true) {
        showToast(context, data['message']?.toString() ?? '', isError: true);
        return;
      }
      setState(() {
        _openingRouteId = routeId;
        _topMode = 'builder';
        _expandedRouteIds = {routeId};
      });
      await _loadPlan(data['plan_id'].toString());
      if (!mounted) return;
      setState(() {
        _topMode = 'builder';
        _expandedRouteIds = {routeId};
      });
      // _openingRouteId is deliberately NOT cleared here: _loadScreen()'s own
      // setState can still land after this one, and it reads the flag to decide
      // the mode. The mode row clears it — the first time a person picks a mode
      // themselves, the link has been honoured and is no longer in charge.
      RenderLog.write('c1876_route_opened', routeId);
      _loadRouteMap(routeId);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), isError: true);
    }
  }

  // ── C5: Past plans ─────────────────────────────────────────────────────────
  Future<void> _togglePastPlans() async {
    final expanding = !_pastPlansExpanded;
    setState(() => _pastPlansExpanded = expanding);
    if (expanding && _plans == null) await _loadPlans(reset: true);
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
        title: Text(c('admin_customer.delete_plan_q')),
        content: Text(cf('admin_customer.delete_plan_body', {'title': '$title'})),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(c('admin_customer.cancel'))),
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
            SnackBar(content: Text(c('admin_customer.delete_fail'))));
        return;
      }
      RenderLog.write('c488c_delete_wired', planId);
      // Remove it locally right away for snappy UX — the realtime DELETE
      // handler above will also fire and no-op harmlessly on a second pass.
      setState(() {
        final held = _plans;
        if (held != null) {
          _plans = PagedList(
            rows: held.rows.where((p) => p['plan_id'].toString() != planId).toList(),
            meta: held.meta,
            hasMore: held.hasMore,
            nextOffset: held.nextOffset,
            total: held.total,
            loaded: held.loaded,
          );
        }
        if (_planId == planId) {
          _plan = null;
          _planId = null;
          _routeMapData.clear();
          _routeMapLoading.clear();
          _routeStopWindow.clear();
        }
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(c('admin_customer.delete_fail'))));
    }
  }

  // ── CHANGE #488 (2D): bulk cleanup, nice-to-have — always confirm first.
  Future<void> _clearOldPlans() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(c('admin_customer.clear_old_plans_q')),
        content: Text(c('admin_customer.clear_old_plans_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(c('admin_customer.cancel'))),
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
          SnackBar(content: Text(cf('admin_customer.deleted_old_plans', {'n': '$deleted'}))));
      // Realtime DELETE events land per-row already; refetch too so the
      // count is right even if a realtime event is missed.
      await _loadPlans(reset: true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(c('admin_customer.clear_old_fail'))));
    }
  }

  // ── B5 (stop-card action): Convert to customer — unchanged from #446 ─────
  Future<void> _convert(Map<String, dynamic> stop, {required VoidCallback onRefresh}) async {
    final nameCtrl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text(c('admin_customer.add_as_customer')),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: c('admin_customer.owner_name_hint'),
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: Text(c('admin_customer.cancel'))),
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
          content: Text(cf('admin_customer.added_as_customer', {'code': '$code', 'note': '$note'})),
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
            Text(cf('admin_customer.failed_to_load', {'e': '$_loadError'}),
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
        // CMD #1877 — the day summary sits above the mode row, so it reads the
        // same in every mode: it answers "what did the field team do today",
        // not "what is on this screen".
        _buildDaySummaryCard(),
        _buildTopModeToggle(),
        SizedBox(height: Ds.space.x16),
        if (_topMode == 'today')
          _buildTodayView()
        else if (_topMode == 'myRoute')
          _buildMyRouteView()
        else
          _buildBuilder(),
      ]),
    );
  }

  // ── CMD #1877: the day summary card ─────────────────────────────────────

  /// One card, one RPC, zero arithmetic. Each worker's line, the team totals
  /// and every chip are printed exactly as `route_day_summary()` worded them.
  /// A payload this caller is not served (`ok:false` — partner staff) draws
  /// nothing: the tab below it is unaffected.
  Widget _buildDaySummaryCard() {
    final day = _daySummary;
    if (day == null || !day.showCard) return const SizedBox.shrink();
    final children = <Widget>[
      Text(day.title, style: Ds.t.subtitle),
      SizedBox(height: Ds.space.x4),
      if (day.headerLabel != null) Text(day.headerLabel!, style: Ds.t.caption),
      if (day.countLabel != null) Text(day.countLabel!, style: Ds.t.caption),
    ];

    if (!day.has) {
      children
        ..add(SizedBox(height: Ds.space.x12))
        ..add(Text(day.emptyLabel ?? '', style: Ds.t.bodySecondary));
    } else {
      if (day.showTotals) {
        children
          ..add(SizedBox(height: Ds.space.x16))
          ..add(_daySummaryLine(day.totals!, strong: true))
          ..add(Divider(height: Ds.space.x24, color: Ds.c.divider));
      } else {
        children.add(SizedBox(height: Ds.space.x16));
      }
      for (var i = 0; i < day.workers.length; i++) {
        if (i > 0) children.add(SizedBox(height: Ds.space.x16));
        children.add(_daySummaryLine(day.workers[i]));
      }
    }

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }

  /// One worker's day — or, with [strong], the team's. The row name is empty
  /// for the totals line, which is how the backend says "this is everyone".
  Widget _daySummaryLine(RouteDayRow row, {bool strong = false}) {
    final head = <Widget>[];
    if (row.label.isNotEmpty) {
      head
        ..add(Expanded(
            child: Text(row.label,
                style: strong ? Ds.t.subtitle : Ds.t.bodyStrong,
                overflow: TextOverflow.ellipsis)))
        ..add(SizedBox(width: Ds.space.x8));
    } else if (row.progressLabel != null) {
      head.add(Expanded(
          child: Text(row.progressLabel!,
              style: Ds.t.bodyStrong, overflow: TextOverflow.ellipsis)));
    }
    if (row.conversionLabel != null) {
      head.add(Text(row.conversionLabel!, style: Ds.t.caption));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (head.isNotEmpty) Row(children: head),
      if (row.label.isNotEmpty && row.progressLabel != null) ...[
        SizedBox(height: Ds.space.x4),
        Text(row.progressLabel!, style: Ds.t.caption),
      ],
      if (row.chips.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: row.chips.map(_toneChip).toList(),
        ),
      ],
    ]);
  }

  /// CMD #1872 — the mode row is the payload's own `links[]`: 'today' is the
  /// landing mode, 'all_plans' opens the builder and 'my_route' the check-in
  /// view. Every caption is the backend's; no mode name is written here.
  static const Map<String, String> _kModeForLink = {
    'today': 'today',
    'all_plans': 'builder',
    'my_route': 'myRoute',
  };

  Widget _buildTopModeToggle() {
    final links = ((_today?['links'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((e) => _kModeForLink.containsKey(e['key']?.toString()))
        .toList();
    if (links.isEmpty) return const SizedBox.shrink();
    final row = <Widget>[];
    for (final l in links) {
      final mode = _kModeForLink[l['key'].toString()]!;
      if (row.isNotEmpty) row.add(SizedBox(width: Ds.space.x8));
      row.add(Expanded(
        child: _segBtn(l['label']?.toString() ?? '', _topMode == mode, () {
          // CMD #1876 — a person picking a mode outranks the deep link.
          setState(() { _openingRouteId = null; _topMode = mode; });
          if (mode == 'myRoute' && _myRoute == null) _refreshMyRoute();
          if (mode == 'today') _refreshToday();
        }),
      ));
    }
    return Row(children: row);
  }

  // ── CMD #1872: the landing view — today's assigned route(s) ─────────────

  Widget _buildTodayView() {
    if (_todayLoading) {
      return Padding(
        padding: EdgeInsets.only(top: Ds.space.x32),
        child: Center(
            child: CircularProgressIndicator(color: Ds.c.brand, strokeWidth: 2)),
      );
    }
    final today = _today ?? const <String, dynamic>{};
    final routes = ((today['routes'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    // The landing view PAINTED. Separate from c1872_today_routes on purpose:
    // a day with no assigned route is a legitimate render (the backend's own
    // empty copy), so route count 0 must not read as "the widget never drew".
    RenderLog.write('c1872_today_view', 1);
    final children = <Widget>[
      Text(today['title']?.toString() ?? '', style: Ds.t.title),
      SizedBox(height: Ds.space.x4),
      Text(today['header_label']?.toString() ?? '', style: Ds.t.caption),
      SizedBox(height: Ds.space.x4),
      Text(today['count_label']?.toString() ?? '', style: Ds.t.caption),
      SizedBox(height: Ds.space.x16),
    ];
    if (routes.isEmpty) {
      children.add(Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x24),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Text(today['empty_label']?.toString() ?? '',
            style: Ds.t.bodySecondary, textAlign: TextAlign.center),
      ));
    } else {
      for (final r in routes) {
        children.add(Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: _todayRouteCard(r),
        ));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  Widget _todayRouteCard(Map<String, dynamic> r) {
    final worker = r['worker_label']?.toString();
    final next = r['next_label']?.toString();
    final nextSub = r['next_sub']?.toString();
    final navUri = r['nav_uri']?.toString();
    final canNav = r['can_navigate'] == true && (navUri ?? '').isNotEmpty;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(r['title']?.toString() ?? '',
                style: Ds.t.subtitle, overflow: TextOverflow.ellipsis),
          ),
          if (worker != null && worker.isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                  color: Ds.c.infoSoft, borderRadius: Ds.r.rChip),
              child: Text(worker, style: Ds.t.caption),
            ),
        ]),
        SizedBox(height: Ds.space.x4),
        Text(r['subtitle']?.toString() ?? '', style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        Text(r['progress_label']?.toString() ?? '', style: Ds.t.bodyStrong),
        if (next != null && next.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Text(next, style: Ds.t.body, overflow: TextOverflow.ellipsis),
          if (nextSub != null && nextSub.isNotEmpty)
            Text(nextSub, style: Ds.t.caption, overflow: TextOverflow.ellipsis),
        ],
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: ElevatedButton.icon(
            onPressed: canNav
                ? () => launchUrl(Uri.parse(navUri!),
                    mode: LaunchMode.externalApplication)
                : null,
            icon: const Icon(Icons.navigation_rounded),
            label: Text(r['nav_label']?.toString() ?? ''),
          ),
        ),
        // CMD #1873 — the route's stops, each with its outcome and its
        // check-in button. This is the only surface that closes a stop.
        if ((r['route_id']?.toString() ?? '').isNotEmpty)
          _todayStopList(r['route_id'].toString()),
      ]),
    );
  }

  /// CMD #1873 — one route_stops_today() call per route card. The payload is
  /// rendered verbatim: this method decides nothing about a stop.
  Future<void> _loadRouteStops(String routeId, {bool force = false}) async {
    if (!force &&
        (_routeStops.containsKey(routeId) ||
            _routeStopsInFlight.contains(routeId))) {
      return;
    }
    _routeStopsInFlight.add(routeId);
    try {
      final res = await Supabase.instance.client
          .rpc('route_stops_today', params: {'p_route_id': routeId});
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() => _routeStops[routeId] = m);
      RenderLog.write('c1873_stop_rows', (m['stops'] as List?)?.length ?? 0);
    } catch (_) {
      // The card keeps its progress line; the stop list simply stays absent
      // until the next refresh.
    } finally {
      _routeStopsInFlight.remove(routeId);
    }
  }

  /// Open the check-in sheet for one stop, then refetch BOTH the stop list and
  /// routes_today() so the outcome chip and the progress line are the
  /// backend's new answer, never a patched local row.
  Future<void> _openStopCheckIn(String routeId, String stopId) async {
    final res = await RouteStopCheckInSheet.open(context, stopId);
    if (res == null || !mounted) return;
    await _loadRouteStops(routeId, force: true);
    await _refreshToday();

    // CMD #1874 — a Converted check-in hands the rep straight to the
    // registration form. WHETHER that happens is route_stop_checkin()'s call
    // (next_action), never a status this file recognises.
    final next = RouteStopCheckInPlan.nextAction(res);
    if (!mounted || !RouteStopCheckInPlan.isAddCustomer(next)) return;
    final leadId = RouteStopCheckInPlan.leadIdOf(next);
    if (leadId == null) return;
    RenderLog.write('c1874_convert_form', leadId);
    await _addCustomerFromLead(leadId, routeId: routeId);
  }

  /// CMD #1874 — lead_customer_prefill() -> the SAME registration form Import
  /// Customer and S Leads use, pre-filled from the lead and fully editable.
  /// Saving goes through lead_import_customer(), so the customer and the
  /// lead's matched_customer_id land in ONE transaction.
  Future<void> _addCustomerFromLead(int leadId, {String? routeId}) async {
    try {
      final res = await Supabase.instance.client
          .rpc('lead_customer_prefill', params: {'p_lead_id': leadId});
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;
      if (m['error'] != null) {
        showToast(context, (m['hint'] ?? m['error']).toString(), isError: true);
        return;
      }
      final note = m['note']?.toString();
      if (note != null && note.isNotEmpty) showToast(context, note);

      final customer = m['customer'] is Map
          ? Map<String, dynamic>.from(m['customer'] as Map)
          : <String, dynamic>{};
      final missing =
          (m['missing'] as List?)?.map((e) => e.toString()).toList() ??
              const <String>[];

      final saved = await ImportCustomerSheet.open(context,
          prefill: customer, missing: missing, leadId: leadId);
      if (saved == true && mounted && routeId != null) {
        await _loadRouteStops(routeId, force: true);
        await _refreshToday();
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, '$e', isError: true);
    }
  }

  /// CMD #1874 — Skip / Restore one stop. The menu entry carries the new
  /// state, so both directions are the same call and this method decides
  /// neither. The backend re-sequences and returns the fresh stop list.
  Future<void> _skipStopFromMenu(
      String routeId, String stopId, Map<String, dynamic> entry) async {
    final params = RouteStopCheckInPlan.skipStopParams(stopId, entry);
    if (params == null) return;
    try {
      final res =
          await Supabase.instance.client.rpc('route_stop_skip', params: params);
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;
      showToast(context, m['message']?.toString() ?? '', isError: m['ok'] != true);
      if (m['ok'] == true) {
        RenderLog.write('c1874_stop_skipped', m['skipped']?.toString() ?? '');
        final stops = m['stops'];
        if (stops is Map) {
          setState(() =>
              _routeStops[routeId] = Map<String, dynamic>.from(stops));
        } else {
          await _loadRouteStops(routeId, force: true);
        }
        await _refreshToday();
      }
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    }
  }

  /// CMD #1874 — a drag posts the WHOLE new order to route_reorder(), which
  /// recomputes seq / leg / cum / ETA on the same OSRM matrix the planner used
  /// and answers with the re-sequenced list. Nothing is renumbered here.
  Future<void> _reorderStops(
      String routeId, int oldIndex, int newIndex) async {
    final data = _routeStops[routeId];
    final ordered = RouteStopCheckInPlan.move(
        RouteStopCheckInPlan.draggable(data), oldIndex, newIndex);
    final params = RouteStopCheckInPlan.reorderParams(routeId, ordered);
    if (params == null) return;
    try {
      final res =
          await Supabase.instance.client.rpc('route_reorder', params: params);
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;
      showToast(context, m['message']?.toString() ?? '', isError: m['ok'] != true);
      RenderLog.write('c1874_stop_reorder', ordered.length);
      final stops = m['stops'];
      if (stops is Map) {
        setState(() => _routeStops[routeId] = Map<String, dynamic>.from(stops));
      } else {
        await _loadRouteStops(routeId, force: true);
      }
      await _refreshToday();
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    }
  }

  /// The one-tap Skip on a stop the backend flagged as shut at its ETA. The
  /// status posted is the one the ACTION carried — Dart never decides what
  /// skipping a stop writes.
  Future<void> _skipStop(
      String routeId, String stopId, Map<String, dynamic> action) async {
    final params = RouteStopCheckInPlan.skipParams(stopId, action);
    if (params == null) return;
    try {
      final res =
          await Supabase.instance.client.rpc('route_stop_checkin', params: params);
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;
      showToast(context, m['message']?.toString() ?? '', isError: m['ok'] != true);
      if (m['ok'] == true) {
        RenderLog.write('c1873_stop_skipped', m['status']?.toString() ?? '');
        await _loadRouteStops(routeId, force: true);
        await _refreshToday();
      }
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    }
  }

  /// The stop list under a today-route card. Title, count, empty copy, chips
  /// and every action label come from route_stops_today().
  Widget _todayStopList(String routeId) {
    final data = _routeStops[routeId];
    if (data == null) {
      _loadRouteStops(routeId);
      return Padding(
        padding: EdgeInsets.only(top: Ds.space.x16),
        child: Center(
            child: SizedBox(
          width: Ds.space.x24,
          height: Ds.space.x24,
          child: CircularProgressIndicator(
              color: Ds.c.brand, strokeWidth: Ds.space.hairline * 2),
        )),
      );
    }
    // CMD #1874 — the two groups are the BACKEND's: a stop it left in the day
    // (can_drag) and a stop it took out of the order (skipped). This file
    // never works out which is which from a status.
    final active = RouteStopCheckInPlan.draggable(data);
    final parked = RouteStopCheckInPlan.skipped(data);
    final empty = data['empty_label']?.toString();
    final hint = data['reorder_hint']?.toString() ?? '';
    final canReorder = RouteStopCheckInPlan.canReorder(data);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(height: Ds.space.x24),
      Row(children: [
        Expanded(
            child: Text(data['title']?.toString() ?? '', style: Ds.t.subtitle)),
        Text(data['count_label']?.toString() ?? '', style: Ds.t.caption),
      ]),
      if (hint.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(hint, style: Ds.t.caption),
      ],
      if (active.isEmpty && parked.isEmpty && (empty ?? '').isNotEmpty) ...[
        SizedBox(height: Ds.space.x12),
        Text(empty!, style: Ds.t.bodySecondary),
      ],
      if (active.isNotEmpty)
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          padding: EdgeInsets.only(top: Ds.space.x12),
          itemCount: active.length,
          onReorder: canReorder
              ? (o, n) => _reorderStops(routeId, o, n)
              : (_, __) {},
          proxyDecorator: (child, _, _) =>
              Material(type: MaterialType.transparency, child: child),
          itemBuilder: (_, i) => Padding(
            key: ValueKey(active[i]['stop_id']?.toString() ?? '$i'),
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: _todayStopRow(routeId, active[i], index: i,
                canReorder: canReorder),
          ),
        ),
      for (final st in parked) ...[
        SizedBox(height: Ds.space.x12),
        _todayStopRow(routeId, st),
      ],
    ]);
  }

  Widget _todayStopRow(String routeId, Map<String, dynamic> st,
      {int? index, bool canReorder = false}) {
    final stopId = st['stop_id']?.toString() ?? '';
    final skipped = RouteStopCheckInPlan.isSkipped(st);
    final skippedLabel = st['skipped_label']?.toString();
    final hasMenu = RouteStopCheckInPlan.menu(st).isNotEmpty;
    final tone = st['status_tone']?.toString();
    final closed = st['closed_label']?.toString();
    final eta = st['eta_label']?.toString();
    final noteLine = st['note_label']?.toString();
    final photoUrl = st['photo_url']?.toString();
    final photoLabel = st['photo_label']?.toString();
    final actions = ((st['actions'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    final card = Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.bg,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider, width: Ds.space.hairline),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: Ds.space.x24,
            height: Ds.space.x24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: skipped ? Ds.c.bg : Ds.c.brandSoft,
                borderRadius: Ds.r.rChip),
            // CMD #1874 — the badge prints the backend's seq_label, which is
            // the placeholder for a stop that holds no place in the day.
            child: Text(
                st['seq_label']?.toString() ?? '${st['seq'] ?? ''}',
                style: Ds.t.caption),
          ),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(st['name']?.toString() ?? '',
                      style: Ds.t.bodyStrong, overflow: TextOverflow.ellipsis),
                  if ((st['address']?.toString() ?? '').isNotEmpty)
                    Text(st['address'].toString(),
                        style: Ds.t.caption, overflow: TextOverflow.ellipsis),
                ]),
          ),
          if ((eta ?? '').isNotEmpty) Text(eta!, style: Ds.t.caption),
        ]),
        SizedBox(height: Ds.space.x8),
        Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x4),
            decoration: BoxDecoration(
                color: routeStopToneSoft(tone), borderRadius: Ds.r.rChip),
            child: Text(st['status_label']?.toString() ?? '',
                style: Ds.t.caption),
          ),
          if ((closed ?? '').isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                  color: Ds.c.warningSoft, borderRadius: Ds.r.rChip),
              child: Text(closed!, style: Ds.t.caption),
            ),
          // CMD #1874 — a skipped stop says so in the backend's own word.
          if ((skippedLabel ?? '').isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                  color: Ds.c.warningSoft, borderRadius: Ds.r.rChip),
              child: Text(skippedLabel!, style: Ds.t.caption),
            ),
        ]),
        if ((noteLine ?? '').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(noteLine!, style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x12),
        Row(children: [
          for (final a in actions) ...[
            Expanded(
              child: SizedBox(
                height: Ds.touch.minTarget,
                child: RouteStopCheckInPlan.isSkip(a)
                    ? OutlinedButton(
                        onPressed: () => _skipStop(routeId, stopId, a),
                        child: Text(a['label']?.toString() ?? ''),
                      )
                    // CMD #1874 — Restore is the same route_stop_skip call
                    // with the backend's own boolean.
                    : RouteStopCheckInPlan.isUnskip(a)
                        ? OutlinedButton(
                            onPressed: () => _skipStopFromMenu(routeId, stopId,
                                {'skipped': false}),
                            child: Text(a['label']?.toString() ?? ''),
                          )
                        : ElevatedButton(
                            onPressed: () => _openStopCheckIn(routeId, stopId),
                            child: Text(a['label']?.toString() ?? ''),
                          ),
              ),
            ),
            SizedBox(width: Ds.space.x8),
          ],
          if ((photoUrl ?? '').isNotEmpty)
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextButton.icon(
                onPressed: () => launchUrl(Uri.parse(photoUrl!),
                    mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.photo_outlined),
                label: Text(photoLabel ?? ''),
              ),
            ),
          // CMD #1874 — the drag handle. Long-press anywhere else on the row
          // opens the menu instead, so the two gestures never fight.
          if (index != null && canReorder)
            ReorderableDragStartListener(
              index: index,
              child: SizedBox(
                width: Ds.touch.minTarget,
                height: Ds.touch.minTarget,
                child: Icon(Icons.drag_handle, color: Ds.c.textSecondary),
              ),
            ),
        ]),
      ]),
    );

    if (!hasMenu) return card;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () async {
        final entry = await RouteStopMenuSheet.open(context, st);
        if (entry == null || !mounted) return;
        await _skipStopFromMenu(routeId, stopId, entry);
      },
      child: card,
    );
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
              child: _stopCard(s, assignmentId: assignmentId, onRefresh: () async {
                await _refreshMyRoute();
                await _refreshToday();
              }),
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
        Padding(
          padding: EdgeInsets.only(top: 24),
          child: Center(child: Column(children: [
            CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
            SizedBox(height: 10),
            Text(c('admin_customer.building_routes'),
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
          Expanded(
            child: Text(c('admin_customer.build_routes'),
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          ),
          TextButton(onPressed: widget.onOpenWarehouseCard, child: Text(c('admin_customer.warehouse'))),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 12, runSpacing: 12, children: [
          SizedBox(
            width: 160,
            child: DropdownButtonFormField<String>(
              initialValue: _city,
              decoration: InputDecoration(labelText: c('admin_customer.city'), border: const OutlineInputBorder(), isDense: true),
              items: [DropdownMenuItem(value: 'Raipur', child: Text(c('admin_customer.raipur')))],
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
              decoration: InputDecoration(labelText: c('admin_customer.day_label'), border: const OutlineInputBorder(), isDense: true),
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
              decoration: InputDecoration(labelText: c('admin_customer.start_time_label'), border: const OutlineInputBorder(), isDense: true),
              child: Text(TimeOfDay(hour: _startMin ~/ 60, minute: _startMin % 60).format(context)),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        Text(c('admin_customer.store_type_label'),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280))),
        const SizedBox(height: 8),
        // CHANGE #552 — chips from lead_category_tree('route'). A top category
        // with sub-categories expands to show them, exactly like the scrape form.
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final c in _routeCats) ...[
            Row(children: [
              _routeCatChip(c.label, c.key),
              if (c.sub.isNotEmpty)
                IconButton(
                  onPressed: () => setState(() {
                    if (!_expandedRouteCats.remove(c.key)) _expandedRouteCats.add(c.key);
                  }),
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  constraints: const BoxConstraints(),
                  icon: Icon(
                      _expandedRouteCats.contains(c.key)
                          ? Icons.expand_less
                          : Icons.expand_more,
                      color: const Color(0xFF9CA3AF)),
                ),
            ]),
            if (c.sub.isNotEmpty && _expandedRouteCats.contains(c.key))
              Padding(
                padding: const EdgeInsets.only(left: 18, top: 2, bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: c.sub.map((s) => _routeCatChip(s.label, s.key)).toList(),
                ),
              ),
          ],
        ]),
        const SizedBox(height: 12),
        Text(c('admin_customer.visit_filter'),
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
                    cf('admin_customer.leads_routes', {'leads': '${_leadCount!['leads']}', 'routes': '$_autoK'}),
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
              Expanded(
                child: Text(c('admin_customer.past_plans'),
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
                  child: Text(c('admin_customer.clear_old_plans_btn'), style: const TextStyle(fontSize: 11.5)),
                ),
              Icon(_pastPlansExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 20, color: const Color(0xFF6B7280)),
            ]),
          ),
        ),
        if (_pastPlansExpanded) ...[
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          if (_plans == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)),
            )
          else if (_pastPlans!.isEmpty)
            Padding(
              padding: EdgeInsets.all(Ds.space.x16),
              child: Text(
                  _plans?.emptyLabel ?? c('admin_customer.no_past_plans'),
                  style: Ds.t.caption),
            )
          else
            // CHANGE #1867 — lazy rows in their own viewport: a plan row is
            // built when it scrolls into view, and the next page is appended
            // when the backend says there is one. Never the whole table.
            SizedBox(
              height: (MediaQuery.of(context).size.height * 0.5).clamp(220.0, 560.0),
              child: NotificationListener<ScrollNotification>(
                onNotification: (_) {
                  _onPlansScroll();
                  return false;
                },
                child: Scrollbar(
                  controller: _plansCtrl,
                  child: ListView.builder(
                    controller: _plansCtrl,
                    primary: false,
                    itemCount: _pastPlans!.length + 1,
                    itemBuilder: (ctx, i) {
                      if (i >= _pastPlans!.length) return _plansListFooter();
                      return _pastPlanRow(_pastPlans![i]);
                    },
                  ),
                ),
              ),
            ),
        ],
      ]),
    );
  }

  /// The past-plans footer — route_plan_list()'s own more_label / end_label.
  Widget _plansListFooter() {
    if (_plansMoreLoading) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x16),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: Ds.c.brand)),
          SizedBox(width: Ds.space.x8),
          Text(_plans?.moreLabel ?? '', style: Ds.t.caption),
        ]),
      );
    }
    final end = _plans?.endLabel;
    if (end != null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x16),
        child: Center(child: Text(end, style: Ds.t.caption)),
      );
    }
    return SizedBox(height: Ds.space.x12);
  }

  Widget _pastPlanRow(Map<String, dynamic> p) {
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
                          // CMD #1875 — a rebuilt plan reads as v2 of the one
                          // above it, not as a mystery duplicate.
                          if ((p['version_label']?.toString() ?? '').isNotEmpty)
                            _toneChip(RouteCostChip(
                                p['version_label'].toString(), RouteChipTone.info)),
                          if ((p['cost_label']?.toString() ?? '').isNotEmpty)
                            _toneChip(RouteCostChip(
                                p['cost_label'].toString(), RouteChipTone.brand)),
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
                      tooltip: c('admin_customer.delete_plan_tooltip'),
                    ),
                  ]),
                ),
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
    // CMD #1875 — the Rebuild button and the ₹ chips are built below.
    RenderLog.write('c1875_rebuild_btn', header['can_rebuild'] == true ? 1 : 0);
    RenderLog.write('c1875_cost_chips',
        routes.where((r) => (r['cost_label']?.toString() ?? '').isNotEmpty).length
            + ((summary['cost_label']?.toString() ?? '').isNotEmpty ? 1 : 0));
    RenderLog.write('c1875_plan_version', (header['version'] as num?)?.toInt() ?? 1);

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
            // CMD #1875 — the plan's version, and the version that replaced it.
            ...RoutePlanVersionChips.from(header).chips.map(_toneChip),
          ]),
          // CMD #1875 — a rebuilt plan is queued and built by the drain; the
          // stage caption is the backend's own build_stage.
          if (_planIsBuilding)
            Padding(
              padding: EdgeInsets.only(top: Ds.space.x8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                    width: Ds.space.x12, height: Ds.space.x12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Ds.c.brand)),
                SizedBox(width: Ds.space.x8),
                Text(header['build_stage']?.toString() ?? '', style: Ds.t.caption),
              ]),
            ),
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
            Text(cf('admin_customer.n_routes', {'n': '${summary['routes'] ?? 0}'}),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const Text('·', style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            Text(cf('admin_customer.n_stops', {'n': '${summary['stops'] ?? 0}'}),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const Text('·', style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            Text(summary['total_km_label']?.toString() ?? '',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          ]),
          // CMD #1875 — plan cost + ₹ per converted lead, both backend strings.
          _costChips(summary),
          if ((summary['rates_label']?.toString() ?? '').isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: Ds.space.x4),
              child: Text(summary['rates_label'].toString(), style: Ds.t.caption),
            ),
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
              label: Text(c('admin_customer.rebalance'), style: const TextStyle(fontSize: 12.5)),
            ),
            OutlinedButton.icon(
              onPressed: _rebuild,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF6B7280),
                side: const BorderSide(color: Color(0xFFD1D5DB)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              icon: const Icon(Icons.refresh, size: 15),
              label: Text(c('admin_customer.rebuild'), style: const TextStyle(fontSize: 12.5)),
            ),
            // CMD #1875 — re-run the builder over the CURRENT S Leads list.
            if (header['can_rebuild'] == true)
              FilledButton.icon(
                onPressed: _rebuilding ? null : _openRebuildSheet,
                icon: _rebuilding
                    ? SizedBox(
                        width: Ds.space.x12, height: Ds.space.x12,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Ds.c.surface))
                    : const Icon(Icons.autorenew, size: 15),
                label: Text(header['rebuild_label']?.toString() ?? ''),
              ),
            // CMD #1875 — the ₹/km and ₹/hour behind every cost chip.
            TextButton.icon(
              onPressed: _openRatesSheet,
              icon: const Icon(Icons.currency_rupee, size: 15),
              label: Text(header['rates_label']?.toString() ?? ''),
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
                    // CMD #1876 — bulk "visiting today" to every stop on
                    // this route that has a phone. The caption is ui_copy's;
                    // an empty key hides the button rather than inventing one.
                    if (UiCopy.t('routes.msg_stops_btn').isNotEmpty)
                      TextButton.icon(
                        onPressed: _msgStopsBusy.contains(routeId)
                            ? null
                            : () => _openMessageStopsSheet(r),
                        icon: Icon(Icons.campaign_outlined, size: Ds.space.x16),
                        label: Text(UiCopy.t('routes.msg_stops_btn'),
                            style: Ds.t.caption.copyWith(color: Ds.c.brand)),
                        style: TextButton.styleFrom(
                            foregroundColor: Ds.c.brand,
                            padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
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
                  // CMD #1875 — route cost + ₹ per converted lead.
                  _costChips(r),
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

  // ── CHANGE #550: the Map/List toggle is DELETED. Both are always visible,
  // stacked: map on top, then the stop-range buttons, then the stop list.
  Widget _buildRouteDetail(String routeId, List<Map<String, dynamic>> stops) {
    RenderLog.write('c550_route_stacked', 'stops=${stops.length}');
    final visible = _stopsInWindow(routeId, stops);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _buildRouteOptimizeButtons(routeId),
      const SizedBox(height: 10),
      _buildRouteMapView(routeId),
      const SizedBox(height: 10),
      // Stop-range buttons sit directly under the map and scope the list.
      _buildStopRangeButtons(routeId, stops.length),
      const SizedBox(height: 10),
      Column(
          children: visible
              .map((s) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _builderStopRow(s),
                  ))
              .toList()),
    ]);
  }

  /// CHANGE #550 — Stops 1-10 / 11-20 / 21-25, sized to the real stop count.
  /// Windows are 10 wide; the last one is clamped to the number of stops.
  Widget _buildStopRangeButtons(String routeId, int total) {
    if (total <= 10) return const SizedBox.shrink();
    final windows = <List<int>>[];
    for (var start = 1; start <= total; start += 10) {
      windows.add([start, (start + 9) > total ? total : (start + 9)]);
    }
    final sel = _routeStopWindow[routeId] ?? 0;
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (var i = 0; i < windows.length; i++)
        _segBtn('Stops ${windows[i][0]}-${windows[i][1]}', sel == i,
            () => setState(() => _routeStopWindow[routeId] = i)),
    ]);
  }

  List<Map<String, dynamic>> _stopsInWindow(
      String routeId, List<Map<String, dynamic>> stops) {
    if (stops.length <= 10) return stops;
    final sel = _routeStopWindow[routeId] ?? 0;
    final start = sel * 10;
    if (start >= stops.length) return stops;
    final end = (start + 10) > stops.length ? stops.length : start + 10;
    return stops.sublist(start, end);
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
          label: c('admin_customer.opt_by_location'),
          icon: Icons.my_location,
          loading: byLocation,
          onTap: () => _optimizeRouteFromMyLocation(routeId),
        ),
        const SizedBox(width: 8),
        button(
          label: c('admin_customer.opt_by_warehouse'),
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
        child: Center(
          child: Text(c('admin_customer.nothing_to_map'), style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
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
              Expanded(
                child: Text(c('admin_customer.todays_visits'),
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
                    ? Text(c('admin_customer.could_not_load'), style: const TextStyle(color: Color(0xFF6B7280)))
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
        Text(c('admin_customer.no_visits_today'), style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)))
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
  /// CHANGE #550 — redesigned stop card, driven by lead_stop_card().
  ///
  /// Layout: a large photo across the top with the score chip and the include
  /// checkbox overlaid on it, then the pharmacy name and address, then ONE
  /// compact row of actions built from the backend's actions[].
  ///
  /// Everything user-visible is backend-owned: photo_url, name, address,
  /// score_label, each action's label/enabled flag, and the call / whatsapp /
  /// navigate URIs. No URI is constructed in Dart.
  Widget _builderStopRow(Map<String, dynamic> s) {
    final stopId = s['stop_id'].toString();
    final leadId = s['lead_id'];
    final included = s['included'] == true;
    final card = leadId == null ? null : _stopCards[leadId.toString()];
    if (leadId != null && card == null) _loadStopCard(leadId);

    final photoUrl = (card?['photo_url'] ?? s['photo_url'])?.toString();
    final name = (card?['name'] ?? s['name'])?.toString() ?? '';
    final address = (card?['address'] ?? s['area'])?.toString() ?? '';
    final scoreLabel = (card?['score_label'] ?? s['score_label'])?.toString();
    final openLabel = s['open_label']?.toString();
    final shut = openLabel == 'SHUT on arrival';
    final photoH = widget.isDesktop ? 168.0 : 140.0;
    RenderLog.write('c452_checkin_wired', 1);

    // actions[] is backend-owned; disabled (never hidden) when enabled=false.
    final actions = ((card?['actions'] as List?) ?? [])
        .whereType<Map>()
        .map((a) => Map<String, dynamic>.from(a))
        .toList();

    VoidCallback? tapFor(String key, bool enabled) {
      if (!enabled) return null;
      String? uri;
      switch (key) {
        case 'call':
          uri = card?['call_uri']?.toString();
          break;
        case 'whatsapp':
          uri = card?['whatsapp_uri']?.toString();
          break;
        case 'navigate':
          uri = card?['navigate_uri']?.toString();
          break;
        case 'checkin':
          return () => _openCheckIn(s, onRefresh: () {
                if (leadId != null) _refreshStopCard(leadId);
                if (_planId != null) _loadPlan(_planId!);
              });
      }
      if (uri == null || uri.isEmpty) return null;
      final u = uri;
      return () => launchUrl(Uri.parse(u), mode: LaunchMode.externalApplication);
    }

    return Container(
      decoration: BoxDecoration(
        color: shut ? const Color(0xFFFEF2F2) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: shut ? const Color(0xFFFECACA) : const Color(0xFFE5E7EB)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Photo with overlaid score chip + checkbox ─────────────────────
        SizedBox(
          height: photoH,
          width: double.infinity,
          child: Stack(fit: StackFit.expand, children: [
            if (photoUrl != null && photoUrl.isNotEmpty)
              NativeSignedImage(url: photoUrl, cacheKey: photoUrl)
            else
              // Neutral placeholder of the SAME height so cards stay uniform.
              Container(
                color: const Color(0xFFF3F4F6),
                child: const Center(
                  child: Icon(Icons.storefront_outlined,
                      size: 34, color: Color(0xFF9CA3AF)),
                ),
              ),
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Checkbox(
                  value: included,
                  onChanged: (v) => _toggleStopIncluded(stopId, v == true),
                  activeColor: const Color(0xFF1B7A43),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
            if (scoreLabel != null && scoreLabel.isNotEmpty)
              Positioned(
                top: 8,
                right: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(scoreLabel,
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ),
            if (s['seq'] != null)
              Positioned(
                bottom: 8,
                left: 8,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${s['seq']}',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ),
              ),
          ]),
        ),

        // ── Name / address ────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827))),
            if (address.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(address,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280))),
            ],
          ]),
        ),

        // ── ONE compact action row, from actions[] ───────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          child: Row(children: [
            for (final a in actions) ...[
              Expanded(
                child: _stopActionCompact(
                  a['key']?.toString() ?? '',
                  a['label']?.toString() ?? '',
                  tapFor(a['key']?.toString() ?? '', a['enabled'] != false),
                ),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  static const Map<String, IconData> _stopActionIcons = {
    'call': Icons.call,
    'whatsapp': Icons.chat,
    'navigate': Icons.navigation_outlined,
    'checkin': Icons.check_circle,
  };

  /// Compact action button. Disabled (greyed, not hidden) when the backend
  /// says enabled=false, or when it supplied no URI for that action.
  Widget _stopActionCompact(String key, String label, VoidCallback? onTap) {
    final on = onTap != null;
    final green = const Color(0xFF1B7A43);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFECFDF5) : const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: on ? const Color(0xFFBBDDC8) : const Color(0xFFE5E7EB)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(_stopActionIcons[key] ?? Icons.circle_outlined,
                size: 16, color: on ? green : const Color(0xFF9CA3AF)),
            const SizedBox(height: 3),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: on ? green : const Color(0xFF9CA3AF))),
          ]),
        ),
      ),
    );
  }

  /// lead_stop_card() fetch + cache. One call per lead, on first render.
  Future<void> _loadStopCard(dynamic leadId) async {
    final key = leadId.toString();
    if (_stopCards.containsKey(key) || _stopCardsInFlight.contains(key)) return;
    _stopCardsInFlight.add(key);
    try {
      final res = await Supabase.instance.client
          .rpc('lead_stop_card', params: {'p_lead_id': leadId});
      if (res is Map && mounted) {
        setState(() => _stopCards[key] = Map<String, dynamic>.from(res));
        RenderLog.write('c550_stop_card', 'lead=$key');
      }
    } catch (_) {
      // Card falls back to the stop row's own fields until a later rebuild.
    } finally {
      _stopCardsInFlight.remove(key);
    }
  }

  /// Force a refetch — used after an import so already_customer flips.
  Future<void> _refreshStopCard(dynamic leadId) async {
    _stopCards.remove(leadId.toString());
    await _loadStopCard(leadId);
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
  // ── CHANGE #551: the WHOLE sheet is backend-owned ───────────────────────
  // lead_checkin_sheet() supplies every label, the outcome options, the photo
  // bucket, the button copy and the import-customer block. Nothing below is
  // constructed in Dart.
  Map<String, dynamic>? _sheet;
  bool _sheetLoading = true;
  bool _prefilling = false;

  Map<String, dynamic> _obj(String key) {
    final v = _sheet?[key];
    return v is Map ? Map<String, dynamic>.from(v) : const {};
  }

  String _str2(Map<String, dynamic> m, String k) => m[k]?.toString() ?? '';

  Future<void> _loadSheet() async {
    final leadId = widget.stop['lead_id'];
    if (leadId == null) {
      if (mounted) setState(() => _sheetLoading = false);
      return;
    }
    try {
      final res = await Supabase.instance.client
          .rpc('lead_checkin_sheet', params: {'p_lead_id': leadId});
      if (!mounted) return;
      setState(() {
        _sheet = res is Map ? Map<String, dynamic>.from(res) : null;
        _sheetLoading = false;
      });
      RenderLog.write('c551_checkin_sheet',
          'opts=${(_obj('outcome')['options'] as List?)?.length ?? 0}');
    } catch (_) {
      if (mounted) setState(() => _sheetLoading = false);
    }
  }

  /// lead_customer_prefill() -> the SAME registration form used by Import
  /// Customer, pre-filled and fully editable. Saving goes through edge
  /// customer-import mode 'import' (inside the sheet), never the RPC directly.
  Future<void> _importCustomer() async {
    final leadId = widget.stop['lead_id'];
    if (leadId == null) return;
    setState(() => _prefilling = true);
    try {
      final res = await Supabase.instance.client
          .rpc('lead_customer_prefill', params: {'p_lead_id': leadId});
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (!mounted) return;
      setState(() => _prefilling = false);

      if (m['error'] != null) {
        // e.g. already_a_customer — backend copy, verbatim.
        showToast(context, m['error'].toString(), isError: true);
        if (m['error'].toString() == 'already_a_customer') {
          await _loadSheet(); // backend now reports show=false + already_label
        }
        return;
      }

      final note = m['note']?.toString();
      if (note != null && note.isNotEmpty) showToast(context, note);

      final customer = m['customer'] is Map
          ? Map<String, dynamic>.from(m['customer'] as Map)
          : <String, dynamic>{};
      final missing = (m['missing'] as List?)?.map((e) => e.toString()).toList() ??
          const <String>[];

      final saved = await ImportCustomerSheet.open(context,
          prefill: customer, missing: missing);
      if (saved == true && mounted) {
        // Refetch the sheet so import_customer.show flips false and the button
        // is replaced by the backend's already_label.
        await _loadSheet();
        widget.onDone();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _prefilling = false);
      showToast(context, '$e', isError: true);
    }
  }

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
    _loadSheet(); // CHANGE #551
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
      final pos = await geo.getCurrentPosition(enableHighAccuracy: false);
      final lat = pos?.lat;
      final lng = pos?.lng;
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

  // Rear-camera capture: web uses an <input capture=environment>, Android the
  // native camera — both via the file_pick_io wrapper. Returns bytes + name.
  Future<void> _takePhoto() async {
    final picked = await filepick.pickCameraPhoto();
    if (picked == null || !mounted) return;
    final ext = picked.name.toLowerCase().split('.').last;
    final mime = ext == 'png'
        ? 'image/png'
        : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
    setState(() { _photoBytes = picked.bytes; _photoMime = mime; });
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
        final bucket = _str2(_obj('photo'), 'bucket');
        await Supabase.instance.client.storage
            .from(bucket.isEmpty ? 'lead-visit-photos' : bucket)
            .uploadBinary(
          path, _photoBytes!,
          fileOptions: FileOptions(contentType: _photoMime ?? 'image/jpeg', upsert: true),
        );
        photoPath = path;
      } catch (_) {
        photoPath = null; // never lose the check-in over a failed photo upload
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(c('admin_customer.photo_upload_fail'))));
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
            if (_sheetLoading) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF1B7A43), strokeWidth: 2)),
              ),
            ] else if (_sheet != null && _sheet!['can_check_in'] == false) ...[
              // CHANGE #551: blocked — show the backend's reason, not the form.
              Text(_str2(_sheet ?? const {}, 'title'),
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827))),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_str2(_sheet ?? const {}, 'blocked_reason'),
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF92400E))),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: Text(_str2(
                      _obj('buttons')['cancel'] is Map
                          ? Map<String, dynamic>.from(
                              _obj('buttons')['cancel'] as Map)
                          : const {},
                      'label')),
                ),
              ),
            ] else ...[
            Text(_str2(_sheet ?? const {}, 'title'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            if (_str2(_sheet ?? const {}, 'subtitle').isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(_str2(_sheet ?? const {}, 'subtitle'),
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
            ],
            if (_str2(_obj('visit_history'), 'label').isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(_str2(_obj('visit_history'), 'label'),
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
            ],
            const SizedBox(height: 14),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            const SizedBox(height: 14),

            // ── GPS ──────────────────────────────────────────────────────
            Row(children: [
              const Icon(Icons.location_on, size: 18, color: Color(0xFF6B7280)),
              const SizedBox(width: 8),
              if (_locating)
                Row(children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(_str2(_obj('gps'), 'waiting_label'),
                      style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                ])
              else if (_locError != null)
                Expanded(
                  // Backend copy when it has one, else the platform's own error.
                  child: Text(
                      _str2(_obj('gps'), 'denied_label').isNotEmpty
                          ? _str2(_obj('gps'), 'denied_label')
                          : _locError!,
                      style: const TextStyle(fontSize: 13, color: Color(0xFFDC2626))),
                )
              else
                Text(_str2(_obj('gps'), 'captured_label'),
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF065F46))),
              if (_locError != null) ...[
                const Spacer(),
                TextButton(onPressed: _captureGps, child: const Text('Retry')),
              ],
            ]),
            const SizedBox(height: 14),

            // ── Photo ────────────────────────────────────────────────────
            Text(_str2(_obj('photo'), 'hint'),
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF))),
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
                label: Text(_str2(_obj('photo'), 'label'),
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
            // CHANGE #551 — driven by lead_checkin_sheet().import_customer.
            // show=true -> the button (backend label + hint); show=false with
            // an already_label -> that label instead.
            if (_obj('import_customer')['show'] == true) ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _prefilling ? null : _importCustomer,
                  icon: _prefilling
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Color(0xFF1B7A43)))
                      : const Icon(Icons.person_add_alt_1_outlined, size: 16),
                  label: Text(_str2(_obj('import_customer'), 'label')),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF1B7A43),
                    side: const BorderSide(color: Color(0xFF1B7A43)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              if (_str2(_obj('import_customer'), 'hint').isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(_str2(_obj('import_customer'), 'hint'),
                    style: const TextStyle(
                        fontSize: 11.5, color: Color(0xFF9CA3AF))),
              ],
              const SizedBox(height: 18),
            ] else if (_str2(_obj('import_customer'), 'already_label')
                .isNotEmpty) ...[
              Text(_str2(_obj('import_customer'), 'already_label'),
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280))),
              const SizedBox(height: 18),
            ],

            Text(_str2(_obj('outcome'), 'title'),
                style: const TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const SizedBox(height: 6),
            // CHANGE #551: rendered in backend order; option.key is posted to
            // record_visit(p_status:) verbatim.
            ...(((_obj('outcome')['options'] as List?) ?? [])
                .whereType<Map>()
                .map((o) => _statusRadio(o['key']?.toString() ?? '',
                    o['label']?.toString() ?? '',
                    highlight: tooFar))),
            const SizedBox(height: 10),

            // ── Note ─────────────────────────────────────────────────────
            TextField(
              controller: _noteCtrl,
              decoration: InputDecoration(
                labelText: _str2(_obj('note'), 'label'),
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
                  child: Text(_str2(_obj('buttons')['cancel'] is Map
                      ? Map<String, dynamic>.from(_obj('buttons')['cancel'] as Map)
                      : const {}, 'label')),
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
                      : Text(
                          _str2(
                              _obj('buttons')['submit'] is Map
                                  ? Map<String, dynamic>.from(
                                      _obj('buttons')['submit'] as Map)
                                  : const {},
                              'label'),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
            ],
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
  // CHANGE #548: the schedulable dates come from route_plan_date_options()
  // (yesterday .. +60d, each with its own backend label). The client no longer
  // computes "today", bounds, or the p_for_date string.
  List<Map<String, dynamic>> _dateOptions = const [];
  String? _forDate; // 'YYYY-MM-DD', backend value verbatim
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _workers = widget.initialWorkers;
    _loadDateOptions();
  }

  Future<void> _loadDateOptions() async {
    try {
      final res =
          await Supabase.instance.client.rpc('route_plan_date_options');
      final list = (res as List?) ?? [];
      final opts = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      setState(() {
        _dateOptions = opts;
        _forDate ??= (opts.firstWhere((o) => o['is_today'] == true,
                orElse: () => opts.isNotEmpty ? opts.first : <String, dynamic>{})['date'])
            ?.toString();
      });
    } catch (_) {
      // No client-side fallback: without options the picker stays empty.
    }
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

  Future<void> _submit() async {
    if (_workerId == null) { setState(() => _error = 'Pick a worker.'); return; }
    setState(() { _submitting = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc('route_plan_assign', params: {
        'p_route_id': widget.route['route_id'],
        'p_worker_id': _workerId,
        // Backend's own date value, passed straight back.
        'p_for_date': _forDate,
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
          // CHANGE #548: pick from the backend's own dates; each row prints
          // that option's own label, verbatim.
          DropdownButtonFormField<String>(
            initialValue: _forDate,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Date', border: OutlineInputBorder(), isDense: true),
            items: [
              for (final o in _dateOptions)
                DropdownMenuItem<String>(
                  value: o['date']?.toString(),
                  child: Text(o['label']?.toString() ?? ''),
                ),
            ],
            onChanged: (v) => setState(() => _forDate = v),
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

/// CMD #366 row 176 — the admin side of substitution.
///
/// It offers exactly two verbs: ASK the customer, and APPLY what the customer
/// already approved. There is deliberately no third verb that swaps a line on
/// the customer's behalf — the backend's sub_offer_apply refuses anything that
/// is not status='approved' with a chosen product the customer picked from the
/// list they were shown, so this panel cannot become one either.
class _SubstitutePanel extends StatefulWidget {
  final String orderId;
  const _SubstitutePanel({required this.orderId});

  @override
  State<_SubstitutePanel> createState() => _SubstitutePanelState();
}

class _SubstitutePanelState extends State<_SubstitutePanel> {
  List<Map<String, dynamic>> _offers = const [];
  bool _busy = false;
  bool _loaded = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await SubstituteChoice.rpc(
          'sub_offers_for_order', {'p_order_id': widget.orderId});
      if (!mounted) return;
      final rows = (res is Map ? (res['offers'] as List?) : null) ?? const [];
      setState(() {
        _offers = rows
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _run(String fn, Map<String, dynamic> params) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final res = await SubstituteChoice.rpc(fn, params);
      if (res is Map && res['ok'] == false) {
        // The refusal ships its own sentence — "The customer has not approved
        // a substitute for this line yet." Print that, never a local one.
        if (mounted) {
          setState(() =>
              _error = (res['message'] ?? res['error'] ?? '').toString());
        }
      }
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: Ds.space.x12),
        Row(
          children: [
            Expanded(
              child: Text(
                c('admin_customer.substitute_title'),
                style: Ds.t.caption.copyWith(
                    fontWeight: FontWeight.w700, color: Ds.c.textSecondary),
              ),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run('sub_offer_open_for_order',
                      {'p_order_id': widget.orderId}),
              child: Text(c('admin_customer.substitute_ask')),
            ),
          ],
        ),
        if (_error.isNotEmpty)
          Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
        for (final o in _offers) ...[
          SizedBox(height: Ds.space.x8),
          Container(
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rButton,
              border: Border.all(color: Ds.c.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // readOnly: the admin sees the customer's options and their
                // answer, and cannot answer for them.
                SubstituteChoice(offer: o, readOnly: true),
                if ((o['status'] ?? '') == 'approved') ...[
                  SizedBox(height: Ds.space.x8),
                  SizedBox(
                    width: double.infinity,
                    height: Ds.space.x48,
                    child: FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _run(
                              'sub_offer_apply', {'p_offer_id': o['offer_id']}),
                      child: Text(c('admin_customer.substitute_apply')),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// CHANGE #810 — one filter chip on the Customers list. Label and count are
/// the payload's; this widget only says whether it is on.
class _CusChip extends StatelessWidget {
  final String label;
  final int? count;
  final bool active;
  final VoidCallback onTap;
  const _CusChip(
      {required this.label,
      this.count,
      required this.active,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
        decoration: BoxDecoration(
          color: active ? Ds.c.brandSoft : Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: active ? Ds.c.brand : Ds.c.divider),
        ),
        child: Text(
          count == null ? label : '$label  $count',
          style:
              active ? Ds.t.caption.copyWith(color: Ds.c.brand) : Ds.t.caption,
        ),
      ),
    );
  }
}
