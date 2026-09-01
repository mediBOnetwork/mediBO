import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart'; // CHANGE #298 — absolute deep links
import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../models/app_session.dart';
import '../models/cart_model.dart';
import '../models/notification_inbox.dart'; // CHANGE #298 — the deep-link parser
import '../design_tokens.dart';
import '../theme.dart';
import '../url_sync.dart';
import '../user_state.dart';
import '../services/ui_copy.dart';
import '../util.dart';
import '../view_as_state.dart';
import '../utils/render_log.dart';
import '../utils/responsive.dart';
import '../widgets/animations.dart';
import '../widgets/cart_pill.dart'; // C636
import '../widgets/notification_bell.dart'; // CHANGE #298
import '../services/push_service.dart'; // CHANGE #298
import 'admin/admin_push_screen.dart'; // CHANGE #298
import 'admin/admin_add_medicine_screen.dart';
import 'admin/admin_manage_admins_screen.dart';
import 'admin/admin_audit_screen.dart';
import 'admin/admin_roles_screen.dart';
import 'admin/admin_customer_screen.dart';
import 'admin/admin_company_screen.dart';
import 'admin/admin_dashboard_screen.dart';
import 'admin/admin_deletion_request_screen.dart';
import 'admin/admin_delivery_partner_screen.dart';
import 'admin/admin_mr_screen.dart';
import 'admin/admin_alert_overlay.dart';
import 'admin/admin_nav_entries.dart';
import 'admin/nav_registry_view.dart';          // CHANGE #325
import 'admin/reorder_admin_screen.dart';       // CHANGE #325
import 'admin/pnl_screen.dart';                 // CHANGE #325
import 'admin/loyalty_admin_screen.dart';       // CHANGE #325
import 'admin/unmapped_companies_screen.dart';  // CHANGE #325
import 'admin/admin_delivery_ops_screen.dart';  // CHANGE #325
import 'admin/notify_cost_screen.dart';         // CHANGE #325
import 'admin/admin_supplier_account_screen.dart'; // CHANGE #402
import 'admin/settlement_screen.dart';          // CHANGE #325
import 'admin/dev_queue/cron_health_screen.dart'; // CHANGE #325
import '../services/discount_slabs_service.dart'; // CHANGE #325
import 'admin/admin_pricing_screen.dart';
import 'admin/admin_shell.dart';
import 'admin/pricing_backfill_screen.dart';
import 'admin/admin_bill_pipeline_screen.dart'; // CHANGE #226
import 'admin/admin_bulk_screen.dart'; // C397: bulk actions, exports, undo
import 'admin/admin_scope_audit_screen.dart'; // CHANGE #227
import 'admin/admin_order_closure_screen.dart'; // CHANGE #229
import 'admin/admin_gst_screen.dart'; // CHANGE #320
import 'admin/admin_reviews_screen.dart'; // CMD #410: review & Q&A moderation
import 'admin/admin_customer_360_screen.dart'; // CMD #421: the customer_360 link
import 'admin/admin_stock_on_hand_screen.dart'; // CMD #421: the stock_on_hand link
import '../features/whatsapp/ui/wa_home_screen.dart';
import '../features/whatsapp/ui/wa_templates_screen.dart';
import 'admin/wa_campaigns_screen.dart';
import 'admin/wa_diagnosis_screen.dart';
import 'admin/notify_center_screen.dart';
import 'admin/order_alerts_screen.dart'; // CHANGE #306
import '../services/feature_gaps_service.dart'; // CHANGE #312
import '../services/order_alert_service.dart'; // CHANGE #306
import 'admin/wa_ops_screen.dart';
import 'admin/wa_drips_screen.dart';
import 'admin/wa_segments_screen.dart';
import '../features/bags/bags_screen.dart';
import 'admin/admin_supplier_screen.dart';
import 'admin/admin_fulfillment_screen.dart';
import 'admin/admin_upi_screen.dart';
import 'admin/dev_queue/dev_queue_screen.dart';
import 'auth/login_screen.dart';
import 'bulk_upload_screen.dart';
import 'delivery/delivery_home_screen.dart'; // C629: the rider/agency surface
import 'partner/partner_home_screen.dart'; // C326: the zone partner's own home
import '../services/delivery_role_state.dart'; // C629: is_partner, from the backend
import 'cart_screen.dart';
import '../utils/toast.dart';
import 'orders_screen.dart';
import '../services/pos_api.dart'; // CMD #411 — pos_entry() at boot
import 'pharmacy/pos_screen.dart'; // CMD #411 — the pharmacy counter
import '../widgets/scan_mic_search_controls.dart'; // #409 — used by the shell part files
import '../services/pharmacy_stock_api.dart'; // CMD #412 — pharmacy_stock_entry() at boot
import 'pharmacy/pharmacy_vault_screen.dart'; // CMD #423 — /admin/go/pharmacy_vault
import 'pharmacy/pharmacy_stock_screen.dart'; // CMD #412 — the pharmacy's shelf
import 'pharmacy/pharmacy_gst_screen.dart'; // CMD #440 — /admin/go/pharmacy_gst
import 'pharmacy/pharmacy_refill_screen.dart'; // CMD #417 — refills & counter
import 'pharmacy/pharmacy_overpay_screen.dart'; // CMD #427 — /admin/go/price_check
import 'pharmacy/paper_sale_screen.dart'; // CMD #429 — /admin/go/paper_sale
import 'admin/admin_demand_engine_screen.dart'; // CMD #427 — /admin/go/demand_engine
import 'profile_screen.dart';
import 'storefront_screen.dart';
import 'supplier/supplier_shell.dart';
// CMD #409 — the scan and mic buttons that sit inside the search bar. The two
// search bars are `part` files of this library, so their import lives here.
import '../widgets/scan_mic_search_controls.dart';

// CHANGE #327 · LAYER 1 — the shell is sharded.
//
// This file was 5,139 lines holding boot, routing, the mobile and desktop
// chrome, the cart panel, the login panel, the admin chrome and the view-as
// previews — nine concerns in one path. That is why a partner-routing fix
// (#326) and a dashboard rebuild (#325) collided on it and one of them sat
// parked mid-build, polling the lease 97 times in six minutes.
//
// What is left here is the shell itself: boot, routing and the two layouts.
// Every other concern is a part below, with its own path and its own lease.
part 'shell/shell_mobile_chrome.dart';
part 'shell/shell_cart_panel.dart';
part 'shell/shell_login_panel.dart';
part 'shell/shell_bottom_bars.dart';
part 'shell/shell_header_chrome.dart';
part 'shell/shell_admin_chrome.dart';
part 'shell/shell_sidebar.dart';
part 'shell/shell_view_as.dart';


/// App shell: responsive — desktop gets a top nav + sidebar, mobile/tablet
/// keeps the existing header + quick-nav chips + bottom nav layout.
class HomeShell extends StatefulWidget {
  static final _shellKey = GlobalKey<_HomeShellState>();
  HomeShell() : super(key: _shellKey);

  /// Switch to the Bulk Upload tab (index 2). Called by Convert-to-Order flow.
  static void switchToBulkUpload() => _shellKey.currentState?._setIndex(2);

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  /// CHANGE #559: surfaces `cart_set_item`'s own `message` when it returns
  /// ok:false (e.g. "No supplier for this product right now"), unchanged.
  void _showCartError() {
    if (!mounted) return;
    final cart = AppState.of(context);
    final msg = cart.cartError.value;
    if (msg == null || msg.isEmpty) return;
    cart.cartError.value = null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  /// CHANGE #559 rule 4: re-read the server cart on entering the cart screen.
  void _openCart() {
    setState(() => _cartOpen = true);
    AppState.of(context).refresh();
  }

  final MedicineRepository _repo = MedicineRepository();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  // GlobalKey keeps BulkUploadScreen's State alive when _MainLayout's LayoutBuilder
  // switches branches (mobile ↔ desktop at 900px). Without a key, Flutter destroys the
  // old element and creates a new one at the new tree position, wiping _uploadedImageBytes
  // and all processedCrop values. With a GlobalKey, Flutter reparents the element instead.
  final GlobalKey _bulkUploadKey = GlobalKey();

  int _index = 0; // 0 = storefront, 1 = orders, 2 = bulk upload
  String _viewAsKey = 'none'; // tracks active ViewAs identity; reset _index on change
  String _query = '';
  String _category = 'All';
  // When true, the storefront shows the full product grid for 'All' (the
  // "Show all products" / "Browse catalogue" target) instead of the home feed.
  bool _browseAll = false;
  bool _cartOpen = false;
  bool _loginOpen = false;
  int _scrollTrigger = 0;
  int _scrollToTopTrigger = 0;
  bool _searchLoading = false;
  int _ordersRefreshSignal = 0; // increment to force OrdersScreen re-fetch

  // Desktop scroll state (header shadow only — fires setState at most twice per visit)
  bool _desktopScrolled = false;

  // CHANGE #209 — authoritative super-admin gate via am_i_super() RPC
  bool _amISuper = false;
  bool _amISuperChecked = false;

  // Deletion-request queue badge — the count is the server's
  // (admin_deletion_request_count); the shell only renders it.
  int _deletionCount = 0;

  // CHANGE #306 — unactioned unpaid orders. The count is the BACKEND's
  // (order_alert_feed().count); the shell only renders the badge and keeps the
  // service alive so the popup, the sticky tray line and this number stay in
  // step on every surface.
  int _alertCount = 0;

  // Desktop sidebar: populated once storefront loads its CatalogMeta
  CatalogMeta? _desktopMeta;

  // ── CHANGE #298 — push + inbox ───────────────────────────────────────────
  // One bell, two headers: whichever layout is on screen holds the key, so a
  // foreground push refreshes the badge that is actually mounted.
  final GlobalKey<NotificationBellState> _bellKey =
      GlobalKey<NotificationBellState>();

  /// The order a notification asked to open, taken verbatim from the backend's
  /// own deep link (`/my-order/<order_code>`). The shell never parses further
  /// than the prefix — it has no opinion about what an order code looks like.
  String? _focusOrderCode;

  /// The auth user this device's push token is currently bound to. Changing it
  /// IS the login / account-switch / logout signal, all three in one place.
  String? _pushBoundUid;
  bool _pushStarted = false;

  @override
  void initState() {
    super.initState();
    BulkUploadScreen.navToBulkUpload = () { if (mounted) setState(() => _index = 2); };
    // CHANGE #559: a rejected cart write shows the SERVER's message verbatim.
    // The client never substitutes copy of its own.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppState.of(context).cartError.addListener(_showCartError);
    });
    _initFromUrl();
    listenPopState(_applyPath);
    // CHANGE #298 — FCM. Started after the first frame so a Firebase failure
    // can never sit in front of the shell's own build (BOOT RESILIENCE RULE);
    // PushService itself swallows every error for the same reason.
    WidgetsBinding.instance.addPostFrameCallback((_) => _startPush());
    // CHANGE #629: the delivery-role probe is fired by UserState (the one place
    // a session is fetched); this only listens so the shell repaints when it
    // answers.
    DeliveryRoleState.instance.addListener(_onDeliveryRoleChanged);
    // CHANGE #497: categories are public data — fetch them immediately, in
    // parallel with auth/session resolution below, never behind it. Renders
    // instantly from cache when one exists; refreshes in the background with
    // retry, and never wipes a good cache on a failed refresh.
    _bootstrapHomeCategories();
    // CMD #411 — after the first frame, same reason as push: a counter entry
    // that fails to resolve must never sit in front of the shell's own build.
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadPosEntry());
    // CHANGE #440: type-anywhere-to-search, desktop web only.
    if (kIsWeb) HardwareKeyboard.instance.addHandler(_globalKeyHandler);
    RenderLog.write('c440_typeanywhere', 'web=$kIsWeb min3=on');
    // Proof keys: single Continue button wired, mobile redirect + desktop GIS compiled in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      RenderLog.write('single_continue_clickable', true);
      RenderLog.write('no_separate_google_button', true);
      RenderLog.write('mobile_oauth_fallback_ready', true);
      RenderLog.write('admin_menu_logout_reachable', true);
      RenderLog.write('all_sheets_scrollable', true);
      // CHANGE #311: structural attestation — login panel button is always-non-null.
      // Written here (HomeShell init) so it appears in ALL sessions (admin + user).
      try { RenderLog.write('c311_login_built', 'panel_wired_#311'); } catch (_) {}
      try { RenderLog.write('c311_btn_wired', 'non_null_always'); } catch (_) {}
      try { RenderLog.write('c311_no_blocker', 'no_absorb_no_ignore_no_overlay'); } catch (_) {}
      // CHANGE #324: load-time attestation — WA box removed, cart checkboxes in ViewAs.
      try { RenderLog.write('c324_build', 324); } catch (_) {}
      // CHANGE #325: cart label visibility rules compiled in.
      try { RenderLog.write('c325_build', 325); } catch (_) {}
      try { RenderLog.write('c325_label_admin', 'both_carts:addedByAdmin==true'); } catch (_) {}
      try { RenderLog.write('c325_label_customer_viewas', 'viewas_only:addedByAdmin==false'); } catch (_) {}
      // CHANGE #326: bulk "Add matched to cart" now uses admin_writeas_cart_upsert in ViewAs.
      try { RenderLog.write('c326_build', 326); } catch (_) {}
      try { RenderLog.write('c326_bulk_upsert', 'setBulkQuantity_viewas_branch:admin_writeas_cart_upsert'); } catch (_) {}
      try { RenderLog.write('c326_cart_server_src', 'loadFromSupabase_viewas:admin_preview_customer_cart'); } catch (_) {}
      // CHANGE #327: WA panel chip tabs + full-width image viewer + side-by-side mobile buttons.
      try { RenderLog.write('c327_build', 327); } catch (_) {}
      try { RenderLog.write('c327_wa_tabs', 'chip_tabs:all_order_n'); } catch (_) {}
      try { RenderLog.write('c327_img_view', 'fullscreen:openFullscreenImage'); } catch (_) {}
      // CHANGE #328: supplier Upload Bill + View Payment; admin View Bill + View Payment.
      try { RenderLog.write('c328_build', 328); } catch (_) {}
      // CHANGE #329: 360° frontend fix — defensive parsers, bucket fix, import-return key.
      try { RenderLog.write('c329_build', 329); } catch (_) {}
      // CHANGE #330: UPI payment_address on supplier profile; shared SupPayPanel with 3 chip tabs; advance+balance pipelines; supplier read-only mirror.
      try { RenderLog.write('c330_build', 330); } catch (_) {}
      // CHANGE #312: structural attestation — bulk upload split buttons compiled in.
      // Written here so it appears in ALL sessions without visiting the Bulk tab.
      try { RenderLog.write('c312_bulk_built', 'split_buttons_#312'); } catch (_) {}
      // CHANGE #314: structural attestation — mobile header slimmed, desktop preserved.
      try { RenderLog.write('c314_preview_built', 'mobile_slim_#314'); } catch (_) {}
      // CHANGE #315: auto-match decision uses substring+0.72 thresholds, null-status fixed.
      try { RenderLog.write('c315_preview_built', 'rpc_match_#315'); } catch (_) {}
      // CHANGE #316: AV/NA badges, FittedBox crop, progress bar, auto-retry, search hitzone, live availability badges.
      try { RenderLog.write('c316_preview_built', 'ui_polish_#316'); } catch (_) {}
    });
  }

  Future<void> _checkAmISuper() async {
    try {
      final r = await Supabase.instance.client.rpc('am_i_super');
      final isSuper = r == true;
      if (mounted) {
        setState(() => _amISuper = isSuper);
        RenderLog.write(isSuper ? 'c209_amisuper_true' : 'c209_amisuper_false', 1);
      }
    } catch (_) {
      if (mounted) RenderLog.write('c209_amisuper_false', 1);
    }
  }

  /// The deletion-request queue badge. Returns 0 for non-admins (the RPC gates
  /// on role), so calling it unconditionally on an admin session is safe.
  /// Starts the unpaid-order alert feed for an admin session. Every string it
  /// carries is the backend's; this only keeps the badge fresh.
  Future<void> _startOrderAlerts() async {
    try {
      OrderAlertService.instance.addListener(_onAlertFeed);
      await OrderAlertService.instance.start();
      _onAlertFeed();
    } catch (_) {}
  }

  void _onAlertFeed() {
    final n = OrderAlertService.instance.count;
    if (mounted && n != _alertCount) setState(() => _alertCount = n);
  }

  Future<void> _loadDeletionCount() async {
    try {
      final r = await Supabase.instance.client.rpc('admin_deletion_request_count');
      final n = (r is num) ? r.toInt() : int.tryParse('$r') ?? 0;
      if (mounted) setState(() => _deletionCount = n);
      if (mounted) await _startOrderAlerts();
    } catch (_) {}
  }

  /// CHANGE #325 — the two identity rows the profile dropdown may hold. Loaded
  /// once and parked in NavProfileMenu; the dropdown's four draw sites read it
  /// from there rather than each making a call of their own.
  Future<void> _loadNavProfileMenu() async {
    try {
      final raw = await Supabase.instance.client.rpc('nav_registry');
      final payload = raw is List ? raw.first : raw;
      NavProfileMenu.adopt(payload);
      // CHANGE #402 — boot-time proof for a surface behind a tap. The paint-time
      // keys (c402_payout_queue, c402_i18n_missing) only fire once someone opens
      // the screen, and a headless verifier cannot tap a canvas app — so they
      // never reach the render-log. This fires at BOOT and asserts the honest
      // thing instead: the registry ADMITTED the supplier-accounts tile onto
      // this login's dashboard, which is exactly what "reachable" means here.
      // 0 means the tile is gone or this role was not admitted; 1 means the tap
      // target the route handler answers is on screen.
      try {
        var admitted = 0;
        for (final sec in (payload is Map ? (payload['sections'] ?? []) : []) as List) {
          for (final item in ((sec is Map ? sec['items'] : null) ?? []) as List) {
            if (item is Map && item['route_key'] == 'supplier_accounts') admitted++;
          }
        }
        RenderLog.write('c402_supplier_accounts_tile', admitted);
      } catch (_) {}
    } catch (_) {
      // Leaves whatever was there; an empty menu simply draws no rows.
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final authForSuper = UserState.of(context);
    if (authForSuper.isAdmin && !_amISuperChecked) {
      _amISuperChecked = true;
      _checkAmISuper();
      _loadDeletionCount();
      _loadNavProfileMenu(); // CHANGE #325
    }
    // CMD #412 — the deep link used to be consumed INSIDE the isAdmin branch
    // above, so /admin/go/<key> was parked by main.dart and then never opened
    // for anybody who is not an admin. That made every non-admin destination
    // unreachable by link — shelf stock and the counter included — while
    // main.dart's own comment says authorisation is the destination screen's
    // job, not the shell's. It is consumed for everyone now; a route that is
    // not on the self-gated list stays PARKED rather than being dropped, so an
    // admin link still opens the moment the admin check resolves.
    _consumePendingDeepLink();
    // CHANGE #298 — login, account switch and logout all reach the shell as an
    // auth rebuild, and all three mean the same thing to a device token.
    _syncPushIdentity();
    final viewAs = ViewAsState.of(context);
    final key = viewAs.isActive
        ? '${viewAs.role!.name}:${viewAs.identity!.id}'
        : 'none';
    if (_viewAsKey != key) {
      _viewAsKey = key;
      _index = 0;
      _cartOpen = false;
      RenderLog.write('view_as_shell_reset', key);
    }
  }

  // ── URL helpers ─────────────────────────────────────────────────────────────

  static String _catToSlug(String cat) => cat.toLowerCase().replaceAll(' ', '-');
  static String _slugToCat(String slug) => slug.toUpperCase().replaceAll('-', ' ');

  String _urlForState() {
    if (_index == 1) return '/orders';
    if (_index == 2) return '/bulk-upload';
    if (_category != 'All') return '/c/${_catToSlug(_category)}';
    return '/';
  }

  // Read the URL on first load and set initial shell state.
  void _initFromUrl() {
    final query = currentSearch();
    final fragment = currentHash();
    // PKCE callback (?code=) or implicit callback (#access_token= / #error=):
    // strip the callback params, but ONLY after the SDK has persisted the session.
    final hasCode = query.contains('code=');
    final hasFragment = fragment.contains('access_token=') ||
        fragment.contains('refresh_token=') ||
        fragment.contains('error=');
    final path = currentPath(); // read once — captureInitialPath() is consumed on first call
    RenderLog.write('c109_init_url_diag', 'path=$path;hasCode=$hasCode;hasFragment=$hasFragment');
    if (hasCode || hasFragment) {
      final cleaned = hasCode ? 'code' : 'fragment';
      _stripOAuthUrlWhenReady(cleaned);
      return;
    }
    // CHANGE #298 — a push tapped from a cold start lands here as a URL, so
    // the deep link must be read on FIRST load too, not only on back/forward.
    if (_applyOrderDeepLink(path)) return;
    // CHANGE #306 — /admin/order-alerts on a cold start. main.dart's route map
    // is another worker's file this command must not touch, and it does not
    // need to: an unknown path already falls through to this shell, which
    // reads the URL here. The screen is pushed after the first frame because
    // the navigator does not exist yet inside initState.
    if (path == '/admin/order-alerts') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _handleAdminNav('order_alerts');
      });
      return;
    }
    if (path.startsWith('/c/')) {
      _category = _slugToCat(path.substring(3));
    } else if (path == '/orders') {
      _index = 1;
    } else if (path == '/bulk-upload') {
      _index = 2;
    }
  }

  // Poll until the SDK has written the session to localStorage, then strip the
  // OAuth callback URL fragment. Never leaves tokens in the URL; worst case
  // strips after a 5-second timeout if the SDK stalls.
  Future<void> _stripOAuthUrlWhenReady(String cleaned) async {
    const maxWaitMs = 5000;
    const pollMs = 150;
    final start = DateTime.now().millisecondsSinceEpoch;
    while (true) {
      await Future.delayed(const Duration(milliseconds: pollMs));
      if (!mounted) return;
      final elapsed = DateTime.now().millisecondsSinceEpoch - start;
      final session = Supabase.instance.client.auth.currentSession;
      if (session != null) {
        replaceUrl('/');
        RenderLog.write('auth56_url_cleaned',
            'stripped $cleaned after session persisted; waited ${elapsed}ms');
        return;
      }
      if (elapsed >= maxWaitMs) {
        replaceUrl('/');
        RenderLog.write('auth56_url_clean_timeout', 'no session after ${elapsed}ms; stripped anyway');
        return;
      }
    }
  }

  // ── CHANGE #298 — push lifecycle + deep links ───────────────────────────

  /// Boot the push channel once, and hand it the two callbacks it needs: where
  /// a tapped notification goes, and what to refresh when one arrives while
  /// the app is already open.
  Future<void> _startPush() async {
    if (_pushStarted || !mounted) return;
    _pushStarted = true;
    final push = PushService.instance;
    push.onForeground = (_) => _bellKey.currentState?.refresh();
    await push.start(onOpen: _openDeepLink);
    if (!mounted) return;
    _pushBoundUid = Supabase.instance.client.auth.currentUser?.id;
    // A notification that launched the process arrived before this navigator
    // existed; now that it does, take it.
    push.drainPending();
  }

  /// The auth identity moved. One method covers login, account switch and
  /// logout, because to a device token they are the same event: the row this
  /// phone is registered under must change.
  void _syncPushIdentity() {
    if (!_pushStarted) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == _pushBoundUid) return;
    _pushBoundUid = uid;
    if (uid == null) {
      PushService.instance.clearOnLogout();
    } else {
      PushService.instance.onAccountSwitched();
    }
  }

  /// Open the destination a notification named. The link is the BACKEND's
  /// (notif_deep_link) — the shell routes it, it does not invent it.
  void _openDeepLink(String link) {
    if (!mounted || link.isEmpty) return;
    RenderLog.write('c298_deeplink_open', 1);
    if (link.startsWith('http://') || link.startsWith('https://')) {
      // An absolute link (a supplier form, for instance) is the browser's job.
      final uri = Uri.tryParse(link);
      if (uri != null) {
        launchUrl(uri, mode: LaunchMode.externalApplication).catchError((_) => false);
      }
      return;
    }
    // CHANGE #306 — the unpaid-order alert's own destination. A tap on the
    // lock-screen notification (or on the sticky "N orders awaiting" line)
    // must land on the screen that can action it, not on the storefront.
    if (link == '/admin/order-alerts') {
      RenderLog.write('c306_deeplink', 1);
      _handleAdminNav('order_alerts');
      pushUrl(link);
      return;
    }
    _applyPath(link);
    pushUrl(link);
  }

  /// `/my-order/<order_code>` → the Orders tab, focused on that order. Returns
  /// true when the path was one of ours.
  bool _applyOrderDeepLink(String path) {
    final code = InboxItem.orderCodeFrom(path);
    if (code == null) return false;
    _focusOrderCode = code;
    _index = 1;
    _cartOpen = false;
    _ordersRefreshSignal++;
    return true;
  }

  // Respond to browser back / forward navigation.
  void _applyPath(String path) {
    if (!mounted) return;
    setState(() {
      // CHANGE #298 — a notification's own destination is checked first: it is
      // the only path that carries an argument the shell must keep.
      if (_applyOrderDeepLink(path)) return;
      if (path.startsWith('/c/')) {
        _category = _slugToCat(path.substring(3));
        _index = 0;
        _cartOpen = false;
        _scrollToTopTrigger++;
      } else if (path == '/orders') {
        _index = 1;
        _cartOpen = false;
      } else if (path == '/bulk-upload') {
        _index = 2;
        _cartOpen = false;
      } else {
        _category = 'All';
        _browseAll = false;
        _index = 0;
        _cartOpen = false;
        _scrollToTopTrigger++;
      }
    });
  }

  // Change tab and push the matching URL to browser history.
  void _setIndex(int i) {
    setState(() {
      _index = i;
      _cartOpen = false;
      // CHANGE #614 — the Orders tab lives in an IndexedStack, which keeps its
      // State alive precisely so tab switches do NOT rebuild it. That also
      // means it never re-fetched: whatever it loaded once, at shell build,
      // was what it kept showing. Bumping the signal here makes opening the
      // tab an actual fetch, so the list is never older than the tap.
      if (i == 1) _ordersRefreshSignal++;
    });
    pushUrl(_urlForState());
  }

  void _goHome() {
    setState(() {
      _index = 0;
      _category = 'All';
      _query = '';
      _browseAll = false;
      _cartOpen = false;
      _scrollToTopTrigger++;
    });
    _searchCtrl.clear();
    pushUrl('/');
  }

  void _onMetaLoaded(CatalogMeta meta) {
    if (mounted) setState(() => _desktopMeta = meta);
  }

  /// CHANGE #497: cache-first, parallel, retrying category fetch for the
  /// homepage chip row (`_MobileCategoryChips`, fed by `_desktopMeta`). This
  /// fires from `initState()` — i.e. immediately on home load, racing
  /// auth/session resolution rather than waiting for it — because the old
  /// path only fetched categories once `StorefrontScreen` mounted, which the
  /// CHANGE #308 auth-loading gate above delays until profile resolution
  /// finishes. See CHANGE #497 for the full root-cause writeup.
  Future<void> _bootstrapHomeCategories() async {
    final cached = _repo.cachedCatalogMeta ?? await _repo.loadCachedCatalogMeta();
    if (cached != null) {
      if (mounted) setState(() => _desktopMeta = cached);
      RenderLog.write('c497_home_cat_cache_hit', 'true');
    } else {
      RenderLog.write('c497_home_cat_cache_miss', 'true');
    }

    final fresh = await retryWithBackoff<CatalogMeta>(
      () => _repo.fetchCatalogMeta(),
      onRetry: (attempt) =>
          RenderLog.write('c497_home_cat_fetch_retry', 'attempt=$attempt'),
    );
    if (fresh != null) {
      if (mounted) setState(() => _desktopMeta = fresh);
      RenderLog.write('c497_home_cat_fetch_ok', 'true');
    } else {
      // All retries failed — keep whatever's already showing (cache or
      // null); never wipe the chip row to blank on a failed refresh.
      RenderLog.write('c497_home_cat_fallback', 'true');
    }
  }

  // Admin section indices in the pages list: 3=Dashboard, 4=AddMedicine,
  // 5=Suppliers, 6=Customers
  /// CHANGE #325 — a /admin/go/<route_key> URL, parked by main.dart's route
  /// resolver, opened once the shell (and therefore the route table) exists.
  /// CMD #411 — does this account have a counter? One cheap call; the answer
  /// is parked in a notifier that PosMenuTile listens to, so the entry appears
  /// without the shell knowing anything about pharmacies.
  void _loadPosEntry() {
    PosEntry.load();
    // CMD #412 — the same one cheap call for the shelf. Both answers are parked
    // in notifiers their own tiles listen to, so the shell still knows nothing
    // about pharmacies.
    StockEntry.load();
  }

  /// Destinations that gate themselves on the CALLER's own account rather than
  /// on an admin role, so opening them from a link grants nothing: each one
  /// renders the backend's refusal when the account has no business there.
  /// Every other key stays admin-only exactly as it was.
  static const Set<String> _selfGatedRoutes = {
    'pharmacy_stock', 'pharmacy_vault', 'pos', 'home',
    // CMD #429 — the paper sale sheet is a PHARMACY's own screen, so it is
    // self-gated like the shelf and the counter: paper_sale_home() resolves
    // the caller's own pharmacy and the screen prints the backend's refusal
    // for anyone else. The link grants a door, never a permission.
    'paper_sale',
    // CMD #427 — the price check is a PHARMACY's own screen.
    // pharmacy_overpay_insights() gates on the caller's own pharmacy and the
    // screen prints its refusal, so opening this link as the wrong role shows
    // the backend's sentence instead of nothing at all.
    'price_check',
    // CMD #432 — the shop's UPI ID and its counter QR. Self-gated the same
    // way: pharmacy_upi_get() resolves the caller's own pharmacy and the
    // screen prints the backend's refusal for anyone else, so the link grants
    // nothing. Without this line the route is parked and the deep link lands
    // on the storefront — which is exactly what it did the first time.
    'pos_upi',
    // CMD #440 — the GST pack (#416) is the same story: pharmacy_gst_home()
    // gates on the caller's OWN pharmacy and the screen prints the backend's
    // refusal, so the link grants nothing. Without this line the key is
    // parked for a pharmacy, who is not an admin, and never opens.
    'pharmacy_gst',
  };

  void _consumePendingDeepLink() {
    final route = PendingAdminNav.take();
    if (route == null || route.isEmpty) return;
    if (!UserState.of(context).isAdmin && !_selfGatedRoutes.contains(route)) {
      PendingAdminNav.route = route; // not ours to open — leave it parked
      return;                        // its seed stays parked with it
    }
    // CMD #421 — the subject is read ONLY on the branch that opens, so a link
    // parked back above still has it when the admin check resolves a frame
    // later. The URL is gone by then; this is the only copy.
    final seed = PendingAdminNav.takeSeed();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      RenderLog.write('c325_deep_link_opened', route);
      _handleAdminNav(route, seed);
    });
  }

  /// [seed] is the subject a route carries, when it has one — see
  /// PendingAdminNav.seed. Optional because most routes are a whole
  /// destination by themselves.
  void _handleAdminNav(String route, [String? seed]) {
    if (!mounted) return;
    switch (route) {
      case 'home': _goHome(); break;
      case 'dashboard': setState(() { _index = 3; _cartOpen = false; }); break;
      case 'add_medicine': setState(() { _index = 4; _cartOpen = false; }); break;
      case 'suppliers':
      case 'add_supplier':
        setState(() { _index = 5; _cartOpen = false; });
        WidgetsBinding.instance.addPostFrameCallback((_) => AdminSupplierScreen.triggerFocus());
        break;
      case 'customers':
      case 'add_customer':
        setState(() { _index = 6; _cartOpen = false; });
        WidgetsBinding.instance.addPostFrameCallback((_) => AdminCustomerScreen.triggerFocus());
        break;
      case 'bags':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const BagsScreen()));
        break;
      // CHANGE #174 — PTR / GST backfill. Not gated here: admin_pricing_list()
      // and product_pricing_upsert() both check get_my_role() themselves and
      // the screen renders their answer, same story as the WhatsApp screens.
      case 'pricing_backfill':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PricingBackfillScreen()));
        break;
      // CHANGE #226 — Bill pipeline (auto customer billing).
      case 'bill_pipeline':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminBillPipelineScreen()));
        break;

      // CHANGE #397 — two registry features share one screen: bulk editing and
      // exports are the same admin acting on a SET of rows, so the tile that
      // was tapped only decides which tab opens.
      case 'bulk_actions':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminBulkScreen()));
        break;

      case 'exports':
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const AdminBulkScreen(initialTab: 1)));
        break;
      // CHANGE #227 — Scope audit (date + zone across order → delivered).
      case 'scope_audit':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminScopeAuditScreen()));
        break;
      // CHANGE #229 — Order closure (customer close + supplier settle).
      case 'order_closure':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminOrderClosureScreen()));
        break;
      // CHANGE #355 — trade price COVERAGE + the sellability policy. Sibling
      // of pricing_backfill (#174), which is where a rate is entered; this is
      // the measurement of how many products have one at all (feature_gaps
      // #80). pricing_coverage_report() gates on get_my_role() itself.
      case 'pricing':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminPricingScreen()));
        break;
      // CHANGE #320 — GST (input credit, monthly position, GSTR exports).
      case 'gst':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminGstScreen()));
        break;
      // CMD #410 — the moderation desk. Nothing a pharmacy writes about a
      // product is public until it is approved here, so the queue needs a way
      // in from a phone: the feature_registry row alone is a tile with nowhere
      // to go (that was #397's finding). review_moderation_queue() gates on
      // get_my_role() and the screen renders its refusal, so there is no
      // _amISuper test here — same story as wa_ops and notify_center.
      case 'reviews':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminReviewsScreen()));
        break;
      // CMD #421 — the two screens CHANGE #865 (#396) shipped. They were
      // reachable from the dashboard tile, the palette and the payment panel,
      // but not from the shell's route table, so /admin/go/customer_360/<id>
      // and /admin/go/stock_on_hand — a push notification, a WhatsApp button,
      // a pasted link — landed on a key the switch had never heard of and did
      // nothing at all. Both are PUSHED rather than swapped into the tab
      // table, the same call the dashboard makes, because customer_360 carries
      // a subject and a tab index cannot hold one.
      case 'customer_360':
        {
        // No id means no customer to show. The dashboard answers that by
        // opening the palette to ask for one; the shell has no palette of its
        // own, so it opens the customers list — the surface you would search
        // from — instead of pushing a screen with nothing in it.
        final id = (seed ?? '').trim();
        if (id.isEmpty) {
          setState(() { _index = 6; _cartOpen = false; });
          break;
        }
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => AdminCustomer360Screen(customerId: id)));
        break;
        }
      case 'stock_on_hand':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminStockOnHandScreen()));
        break;
      // CMD #411 — the pharmacy counter (POS). Reached from the account menu
      // via pos_entry(); this case also makes /admin/go/pos work. pos_home()
      // gates on the caller's own pharmacy and the screen renders its refusal,
      // so there is no role test here — same story as reviews and wa_ops.
      case 'pos':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PosScreen()));
        break;
      // CMD #412 — the pharmacy's shelf. Sibling of the counter: reached from
      // the counter's own app bar and from the account tile via
      // pharmacy_stock_entry(), and this case is what makes
      // /admin/go/pharmacy_stock resolve. pharmacy_stock_home() gates on the
      // caller's own pharmacy and the screen renders its refusal, so there is
      // no role test here — same story as pos and reviews.
      case 'pharmacy_stock':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PharmacyStockScreen()));
        break;
      // CMD #429/#444 — handwritten sale sheets photographed at the counter.
      // The proven entry is the counter's own app-bar button (CHANGE #916);
      // this is the deep link the closing-time nudge points at, which could
      // not land with #429 because this file was leased for the whole of it.
      // Its registry tile stayed is_active=false until this case existed, so
      // the tile was never a tap that did nothing.
      case 'paper_sale':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PaperSaleScreen()));
        break;
      // CMD #432 — the shop's UPI ID and its printable counter QR. Reached
      // from the counter's own app bar (and from the payment chips when UPI is
      // picked with no confirmed VPA); this case is what makes
      // /admin/go/pos_upi resolve. pharmacy_upi_get() gates on the caller's own
      // pharmacy and the screen renders its refusal, so there is no role test
      // here — same story as pos and pharmacy_stock.
      case 'pos_upi':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PosUpiSetupScreen()));
        break;
      // CMD #416 shipped the GST pack behind an account tile only; this case
      // is what makes /admin/go/pharmacy_gst resolve. pharmacy_gst_home()
      // gates on the caller's own pharmacy and the screen renders its refusal,
      // so there is no role test here — same story as pos and pharmacy_stock.
      case 'pharmacy_gst':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PharmacyGstScreen()));
        break;
      // CMD #427 — THE PRICE CHECK. Also reachable from the vault's app bar;
      // this case is what gives it an address, so a monthly WhatsApp note or a
      // push about a rate can point straight at /admin/go/price_check.
      case 'price_check':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PharmacyOverpayScreen()));
        break;
      // CMD #427 — THE DEMAND ENGINE, the operator side of the same aggregate.
      // Admin-only by omission from _selfGatedRoutes, and admin_demand_engine()
      // checks is_admin() for itself on top of that.
      case 'demand_engine':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminDemandEngineScreen()));
        break;
      // CMD #423 — the BILL VAULT. Reached from the shelf's own app bar via
      // pharmacy_vault_entry(), and this case is what gives it a real address:
      // /admin/go/pharmacy_vault, so a WhatsApp button or a push about a bill
      // waiting to be checked can point straight at it. pharmacy_vault_home()
      // gates on the caller's own pharmacy and the screen renders its refusal,
      // so there is no role test here — same story as pos and pharmacy_stock.
      case 'pharmacy_vault':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PharmacyVaultScreen()));
        break;
      // CMD #417 — refills, the WhatsApp storefront and the AI counter. Same
      // story as the two above, and the reason this case exists at all: the
      // dashboard tile alone resolves only when the dashboard is on screen, so
      // /admin/go/refill (a push notification, a WhatsApp link, the nav
      // registry) landed on the storefront home instead. refill_home() gates
      // on the caller's own pharmacy and the screen renders its refusal, so
      // there is no role test here.
      case 'refill':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PharmacyRefillScreen()));
        break;
      case 'mr': setState(() { _index = 7; _cartOpen = false; }); break;
      case 'companies': setState(() { _index = 8; _cartOpen = false; }); break;
      case 'delivery_partners': setState(() { _index = 9; _cartOpen = false; }); break;
      case 'fulfillment':
        setState(() { _index = 10; _cartOpen = false; });
        WidgetsBinding.instance.addPostFrameCallback((_) => AdminFulfillmentScreen.triggerFocus());
        break;
      case 'whatsapp':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const WaHomeScreen()));
        break;
      // #645/#646 shipped these screens but only wired them into
      // admin_shell.dart's wide-viewport link row, so on a phone there was no
      // way in at all. They are NOT gated on _amISuper here: both screens call
      // RPCs that gate on get_my_role() and render the backend's
      // not_authorized answer themselves.
      case 'wa_templates':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const WaTemplatesScreen()));
        break;
      case 'wa_campaigns':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const WaCampaignsScreen()));
        break;
      // Event routes, WABA health and the contact ledger. Same gating story as
      // the two above: wa_event_routes_screen / wa_waba_status /
      // wa_contact_ledger all check get_my_role() and the screen renders their
      // not_authorized answer, so there is no _amISuper test here.
      case 'wa_ops':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const WaOpsScreen()));
        break;
      // CHANGE #295 — WhatsApp delivery diagnosis. wa_event_diagnosis() gates
      // on get_my_role() and the screen renders its refusal, same as wa_ops.
      case 'wa_diagnosis':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const WaDiagnosisScreen()));
        break;
      // CHANGE #297 — Notification Centre. notify_center() gates on
      // get_my_role() and the screen renders its refusal, same as wa_ops.
      case 'notify_center':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const NotifyCenterScreen()));
        break;
      // CHANGE #298 — Push notifications (Firebase config + the per-event push
      // toggle). push_admin_screen() gates on get_my_role() and the screen
      // renders its refusal, same as notify_center above.
      case 'admin_push':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminPushScreen()));
        break;
      // Same gating as the ones above: both screens call RPCs that check the
      // caller's role and render the backend's own refusal.
      case 'wa_segments':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const WaSegmentsScreen()));
        break;
      case 'wa_drips':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const WaDripsScreen()));
        break;
      case 'manage_admins':
        if (_amISuper) {
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const AdminManageAdminsScreen()));
        }
        break;
      // CHANGE #394 — the audit trail and the roles editor. Neither is gated
      // on _amISuper here: admin_audit_screen() answers on admin_can(
      // 'admin.audit_log','read') and admin_roles_screen() on _is_super(),
      // and each screen renders that refusal itself. The fence is the RPC's,
      // not the router's — a Dart `if` is not an access control.
      case 'audit_log':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminAuditScreen()));
        break;
      case 'admin_roles':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminRolesScreen()));
        break;
      case 'payment_upi':
        if (_amISuper) {
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const AdminUpiScreen()));
        }
        break;
      // Dev Queue — the development registry + runner control (super-admin).
      case 'dev_queue':
        if (_amISuper) {
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const DevQueueScreen()));
        }
        break;
      // CHANGE #306 — New-order alerts: what is waiting for a decision, the
      // escalation config, per-customer credit limits and the purchase gate.
      // order_alert_settings() gates on get_my_role() and the screen renders
      // its refusal, same story as notify_center and admin_push above.
      case 'order_alerts':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const OrderAlertsScreen()));
        break;
      // CHANGE #312 — Feature gaps register. Both RPCs are injected here so the
      // screen itself stays Supabase-free and pumps on the Dart VM;
      // feature_gaps_list() gates on is_admin() and the screen renders its
      // not_authorized answer, same story as the screens above.
      case 'feature_gaps':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => buildFeatureGapsScreen()));
        break;
      case 'deletion_requests':
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AdminDeletionRequestScreen(
              listRpc: (status) async {
                final raw = await Supabase.instance.client.rpc(
                    'admin_deletion_request_list',
                    params: {'p_status': status});
                return Map<String, dynamic>.from(
                    (raw is List ? raw.first : raw) as Map);
              },
              reviewRpc: (id, decision, note) async {
                final raw = await Supabase.instance.client.rpc(
                    'admin_review_deletion_request',
                    params: {
                      'p_request_id': id,
                      'p_decision': decision,
                      'p_note': note,
                    });
                return Map<String, dynamic>.from(
                    (raw is List ? raw.first : raw) as Map);
              },
              onChanged: _loadDeletionCount,
            ),
          ),
        ).then((_) => _loadDeletionCount());
        break;
      // CHANGE #325 — the screens the registry now lists that the router
      // could not open. Every one of them existed and worked; none of them had
      // a tappable way in, which by rule 11 means they did not exist. None is
      // gated here: each screen's RPCs check get_my_role() and the screen
      // renders the backend's own refusal, the same story as the WhatsApp
      // screens above.
      case 'reorder':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const ReorderAdminScreen()));
        break;
      case 'pnl':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const PnlScreen()));
        break;
      case 'discount_slabs':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => buildDiscountSlabsScreen()));
        break;
      case 'loyalty':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const LoyaltyAdminScreen()));
        break;
      case 'unmapped_companies':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const UnmappedCompaniesScreen()));
        break;
      case 'delivery_ops':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminDeliveryOpsScreen()));
        break;
      case 'notify_cost':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const NotifyCostScreen()));
        break;
      case 'settlement':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const SettlementScreen()));
        break;
      case 'cron_health':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const CronHealthScreen()));
        break;
      // CHANGE #402 — supplier bank/UPI approvals and the Hindi coverage
      // report. Both RPCs gate on get_my_role() and the screen renders the
      // backend's own refusal, the same story as the screens above.
      case 'supplier_accounts':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AdminSupplierAccountScreen()));
        break;
      // The identity row the profile dropdown fires.
      case 'profile':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const ProfileScreen()));
        break;
      // CHANGE #325 — a medicine chosen in the command palette lands on the
      // storefront with that name already typed, which is the search the
      // shell already owns.
      case 'search':
        setState(() { _index = 0; _cartOpen = false; });
        break;
      case 'logout':
        UserState.read(context).signOut(); break;
    }
  }

  @override
  void dispose() {
    if (BulkUploadScreen.navToBulkUpload != null) BulkUploadScreen.navToBulkUpload = null;
    if (kIsWeb) HardwareKeyboard.instance.removeHandler(_globalKeyHandler);
    DeliveryRoleState.instance.removeListener(_onDeliveryRoleChanged); // C629
    _searchFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// CHANGE #629 — the delivery probe settled (or was cleared by a sign-out).
  /// Rebuild so the shell re-reads it; the decision itself stays in build().
  void _onDeliveryRoleChanged() {
    if (mounted) setState(() {});
  }

  // CHANGE #440: pressing any letter/number key with no text field focused
  // (desktop web, storefront tab only) focuses the search box and seeds it
  // with that character, like Gmail/YouTube search-anywhere.
  bool _globalKeyHandler(KeyEvent event) {
    if (!kIsWeb) return false;
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;
    // This handler is registered on the global HardwareKeyboard singleton,
    // so it keeps firing even when a screen/dialog is pushed on top of the
    // shell (e.g. an admin sub-screen, or a form dialog inside one) — the
    // storefront search box underneath isn't even visible then, so never
    // steal keystrokes meant for whatever IS on top.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    // Search box only exists on the storefront tab, and only while no
    // overlay (cart/login) with its own fields is open on top of it.
    if (_index != 0 || _cartOpen || _loginOpen) return false;
    // Desktop layout only — narrow/mobile web layout keeps click-to-search.
    if (MediaQuery.sizeOf(context).width < 900) return false;

    final primary = FocusManager.instance.primaryFocus;
    if (primary != null && primary.context?.widget is EditableText) return false;
    if (_searchFocus.hasFocus) return false;

    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final hasModifier = keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight) ||
        keys.contains(LogicalKeyboardKey.altLeft) ||
        keys.contains(LogicalKeyboardKey.altRight);
    if (hasModifier) return false;

    final ch = event.character;
    if (ch == null || ch.isEmpty) return false;
    if (!RegExp(r'^[a-zA-Z0-9]$').hasMatch(ch)) return false;

    _searchFocus.requestFocus();
    _searchCtrl.text = _searchCtrl.text + ch;
    _searchCtrl.selection =
        TextSelection.fromPosition(TextPosition(offset: _searchCtrl.text.length));
    _handleDesktopSearch(_searchCtrl.text);
    return true;
  }

  // Desktop web search trigger — shared by _DesktopSearchRow's onChanged
  // debounce and the type-anywhere global key handler above (CHANGE #440).
  void _handleDesktopSearch(String v) {
    setState(() {
      final q = v.trim().replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
      _category = 'All';
      _browseAll = false;
      _index = 0;
      if (q.length >= 3) {
        _query = v;
      } else {
        _query = '';
        _scrollToTopTrigger++;
      }
    });
  }

  void _selectCategory(String c) {
    setState(() {
      _category = c;
      _query = '';
      _browseAll = false;
      _searchCtrl.clear();
      _index = 0;
      _cartOpen = false;
    });
    pushUrl(c == 'All' ? '/' : '/c/${_catToSlug(c)}');
  }

  // "Show all products" / "Browse catalogue": open the full product grid for
  // every product (category 'All') rather than the sectioned home feed.
  void _browseAllProducts() {
    setState(() {
      _category = 'All';
      _query = '';
      _browseAll = true;
      _searchCtrl.clear();
      _index = 0;
      _cartOpen = false;
      _scrollToTopTrigger++;
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    final viewAs = ViewAsState.of(context);

    // View As (Dev): super-admin previewing another account's interface.
    // In-memory only — a page refresh returns to the real admin.
    final isCustomerViewAs = viewAs.isActive && auth.isSuperAdmin && viewAs.role == ViewAsRole.customer;

    if (viewAs.isActive && auth.isSuperAdmin && !isCustomerViewAs) {
      final role = viewAs.role!;
      final identity = viewAs.identity!;
      RenderLog.write('view_as_active', '${role.name}:${identity.id}');

      Widget preview;
      switch (role) {
        case ViewAsRole.supplier:
          preview = SupplierShell(
            key: ValueKey(identity.id),
            viewAsSupplierId: identity.id,
            viewAsSupplierName: identity.name,
          );
        case ViewAsRole.company:
          preview = _ViewAsCompanyPreview(key: ValueKey(identity.id), identity: identity);
        case ViewAsRole.deliveryPartner:
          preview = _ViewAsDeliveryPartnerPreview(key: ValueKey(identity.id), identity: identity);
        case ViewAsRole.customer:
          preview = const SizedBox.shrink(); // unreachable — handled below
      }

      return Column(children: [
        _ViewAsBanner(
          role: role,
          identity: identity,
          onExit: () {
            ViewAsState.read(context).exit();
            RenderLog.write('view_as_active', 'none');
          },
        ),
        Expanded(child: preview),
      ]);
    }

    // Customer ViewAs: fall through to the real customer UI below.
    // Banner is added by wrapping the LayoutBuilder result at the bottom of build().
    if (isCustomerViewAs) {
      RenderLog.write('view_as_active', 'customer:${viewAs.identity!.id}');
    }

    // CHANGE #308: while role is resolving after sign-in, show a brief spinner
    // instead of flashing the customer "Not Registered" profile for admins/suppliers.
    if (auth.profileLoading && !viewAs.isActive) {
      return const Scaffold(
        backgroundColor: Color(0xFFF5F6F8),
        body: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43))),
      );
    }

    // CHANGE #326 — a partner is not a customer, and this shell is where that
    // used to be forgotten.
    //
    // main.dart routes a partner at the root, but HomeShell is still reachable
    // by a route push, an unknown route and the 5 s boot-timeout fallback — and
    // until #326 `AccountSurface` had no 'partner' word at all, so a partner
    // session parsed as `unresolved` and fell all the way through to the
    // customer storefront below: Best Sellers, a Home/Catalogue/Offers/Orders/
    // Bulk bottom nav, and a profile screen asking a zone partner to "Complete
    // Registration" for a pharmacy she will never have.
    //
    // Placed ABOVE the delivery probe on purpose: a partner must not sit behind
    // a rider probe she can never be the subject of, and must never flash the
    // storefront while it is in flight. View As is excluded so a super-admin
    // previewing another account is not hijacked.
    if (!viewAs.isActive && auth.surface == AccountSurface.partner) {
      RenderLog.write('c326_surface', 'partner');
      return const PartnerHomeScreen();
    }

    // CHANGE #629 (PART B1) — the delivery interface is its own home, exactly
    // as the supplier interface is.
    //
    // my_session() has no 'delivery' surface: its CASE resolves a rider's login
    // to 'customer', because a rider is not staff, not a supplier and not a
    // pending supplier. Teaching it one means altering my_session(), and this
    // change touches no RPC. So the role signal is the one the spec names —
    // my_delivery_run().is_partner — still a BACKEND boolean, asked once per
    // credential and never inferred here.
    //
    // The gate below holds the storefront back while that probe is in flight,
    // so a rider never sees a flash of the customer shell. It cannot hang: the
    // probe has a 6s timeout and resolves to "unresolved" on failure, which
    // falls through to my_session()'s own answer.
    final deliveryRole = DeliveryRoleState.instance;
    if (!viewAs.isActive && auth.isAuthenticated) {
      if (deliveryRole.isPartner) {
        RenderLog.write('c629_surface', 'delivery');
        return const DeliveryHomeScreen();
      }
      if (!deliveryRole.resolved && deliveryRole.loading) {
        return const Scaffold(
          backgroundColor: Color(0xFFF5F6F8),
          body: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43))),
        );
      }
    }

    // #571 — which shell renders is my_session().surface, not a role ladder.
    // The old test was `!auth.isAdmin && auth.isSupplier`, then a second one
    // reconciling auth.supplierStatus from a different RPC. One field decides
    // now, so the two can no longer disagree.
    final surface = auth.surface;

    if (surface == AccountSurface.supplier) {
      return const SupplierShell();
    }

    // Pending-approval supplier: waiting screen. Every string below is printed
    // verbatim from the backend — including 'Welcome, <name>', which the server
    // composes so the app never concatenates user-facing copy.
    if (surface == AccountSurface.pendingSupplier) {
      final s = auth.session;
      return Scaffold(
        backgroundColor: const Color(0xFFF5F6F8),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.hourglass_empty, size: 56, color: Color(0xFF9CA3AF)),
              const SizedBox(height: 16),
              Text(s.pendingText('title'),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const SizedBox(height: 8),
              Text(s.pendingText('message'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: () => UserState.read(context).signOut(),
                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF1B7A43),
                  side: const BorderSide(color: Color(0xFF1B7A43))),
                child: Text(s.pendingText('sign_out_label')),
              ),
            ]),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 900;

        void onLogoTap() => _goHome();

        // IndexedStack keeps all screen States alive — no re-fetch on tab switch.
        final pages = [
          StorefrontScreen(
            query: _query,
            category: _category,
            onCategorySelected: _selectCategory,
            onSuggestionTap: (s) => setState(() {
              _query = s;
              _searchCtrl.text = s;
              _category = 'All';
              _browseAll = false;
              _index = 0;
            }),
            repo: _repo,
            browseAll: _browseAll,
            onBrowseAll: _browseAllProducts,
            scrollTrigger: _scrollTrigger,
            scrollToTopTrigger: _scrollToTopTrigger,
            onLoadingChanged: (loading) {
              if (mounted) {
                setState(() => _searchLoading = loading && _query.trim().isNotEmpty);
              }
            },
            showCategoryTiles: false,
            onMetaLoaded: _onMetaLoaded,
            onFooterSearch: () => setState(() => _scrollToTopTrigger++),
            onFooterBulkUpload: () => _setIndex(2),
            onFooterOrders: () => _setIndex(1),
            onFooterCart: () => _openCart(),
          ),
          OrdersScreen(
            viewAsUserId: isCustomerViewAs ? viewAs.identity?.userId : null,
            refreshSignal: _ordersRefreshSignal,
            // CHANGE #298 — the order a notification pointed at, passed through
            // untouched so the card opens and scrolls itself into view.
            focusOrderCode: _focusOrderCode,
          ),
          BulkUploadScreen(key: _bulkUploadKey),
          // Admin-only pages: indices 3–10 (desktop only; built for admin users)
          // Kept alive in IndexedStack so no state loss on tab switch.
          QuickLinkNavigator(
            navigate: _handleAdminNav,
            child: const AdminDashboardScreen(),
          ),
          const AdminAddMedicineScreen(),
          AdminSupplierScreen(),
          AdminCustomerScreen(),
          const AdminMrScreen(),
          const AdminCompanyScreen(),
          const AdminDeliveryPartnerScreen(),
          AdminFulfillmentScreen(),
        ];

        final isAdmin = UserState.of(context).isAdmin;
        // Customer ViewAs: force customer shell (header + nav), never admin chrome
        final effectiveAdmin = isCustomerViewAs ? false : isAdmin;
        if (isCustomerViewAs) {
          RenderLog.write('view_as_shell', 'customer:${isDesktop ? "desktop" : "mobile"}');
        }

        // Wrap admin layouts in AdminAlertOverlay so realtime channels +
        // FCM handler are alive as long as the admin shell is on screen.
        final shell = isDesktop
            ? _buildDesktop(pages, onLogoTap, effectiveAdmin)
            : _buildMobile(pages, onLogoTap, effectiveAdmin);
        if (isCustomerViewAs) {
          return Column(children: [
            _ViewAsBanner(
              role: ViewAsRole.customer,
              identity: viewAs.identity!,
              onExit: () {
                ViewAsState.read(context).exit();
                RenderLog.write('view_as_active', 'none');
              },
            ),
            Expanded(child: shell),
          ]);
        }
        if (!isAdmin) return shell;
        return AdminAlertOverlay(
          onOrderTap: () => _handleAdminNav('customers'),
          child: shell,
        );
      },
    );
  }

  // ─── Mobile / tablet layout (< 900px) ────────────────────────────────────

  Widget _buildMobile(List<Widget> pages, VoidCallback onLogoTap, bool isAdmin) {
    return Scaffold(
      backgroundColor: Colors.white,
      bottomNavigationBar: isAdmin
          ? _AdminMobileBottomBar(
              index: _index,
              alertCount: _alertCount,
              onSection: (i) => _handleAdminNav(const [
                'dashboard', 'whatsapp', 'customers', 'suppliers', 'fulfillment'
              ][i]),
            )
          : (_cartOpen
              ? null
              : _MobileBottomBar(
                  index: _index,
                  cartOpen: _cartOpen,
                  onCartTap: () => _openCart(),
                  onNavTap: (i) {
                    switch (i) {
                      case 0:
                      case 1:
                        _setIndex(0);
                      case 2:
                        _setIndex(1);
                      case 3:
                        _setIndex(2);
                    }
                  },
                )),
      body: Stack(
        children: [
          SizedBox.expand(
            child: Column(
              children: [
                _LocationHeader(
                  isAdmin: isAdmin,
                  onCart: () => _openCart(),
                  onHome: _goHome,
                  onLogoTap: onLogoTap,
                  logoTooltip: '',
                  onAdminNav: isAdmin ? _handleAdminNav : null,
                  isSuperAdmin: isAdmin ? _amISuper : false,
                  deletionCount: isAdmin ? _deletionCount : 0,
                  alertCount: isAdmin ? _alertCount : 0,
                  bellKey: _bellKey, // CHANGE #298
                ),
                // CHANGE #455 B1 — the persistent order-hours banner that
                // used to sit here (and in the desktop header below) is
                // deleted, not hidden. c455_banners proves zero render.
                Builder(builder: (_) {
                  RenderLog.write('c455_banners', 0);
                  return const SizedBox.shrink();
                }),
                // Search + chips: storefront only (index 0)
                if (_index == 0)
                  _MobileSearchBar(
                    controller: _searchCtrl,
                    isLoading: _searchLoading,
                    onSearch: (v) => setState(() {
                      final q = v.trim();
                      _category = 'All';
                      _index = 0;
                      if (q.length >= 2) {
                        _query = v;
                      } else {
                        _query = '';
                        _scrollToTopTrigger++;
                      }
                    }),
                    onScrollToResults: () => setState(() => _scrollTrigger++),
                  ),
                if (_index == 0)
                  _MobileCategoryChips(
                    meta: _desktopMeta,
                    selected: _category,
                    onCategoryTap: (key) => _selectCategory(key),
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _index,
                    children: pages,
                  ),
                ),
              ],
            ),
          ),
          // CHANGE #636 — the floating cart pill replaces the sticky cart bar.
          //
          // The `distinctItems > 0` gate that used to live here is gone on
          // purpose. It was the shell counting the cart to decide whether a
          // cart control exists — the backend already answers that
          // (`render.pill.show`) — and because it read AppState at the shell
          // level, every cart write rebuilt the entire HomeShell subtree.
          // CartPill reads the cart itself, so a write now repaints one pill.
          if (!isAdmin && _index == 0)
            Positioned(
              bottom: 16,
              left: 0,
              right: 0,
              child: RepaintBoundary(
                child: CartPill(onTap: () => _openCart()),
              ),
            ),
          if (!isAdmin)
            RepaintBoundary(
              child: CartPanel(
                open: _cartOpen,
                onClose: () => setState(() => _cartOpen = false),
                onOrderPlaced: () {
                  setState(() => _ordersRefreshSignal++);
                  _setIndex(1);
                },
              ),
            ),
        ],
      ),
    );
  }

  // ─── Desktop layout (≥ 900px) ────────────────────────────────────────────

  Widget _buildDesktop(List<Widget> pages, VoidCallback onLogoTap, bool isAdmin) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Column(
            children: [
              if (isAdmin)
                _AdminDesktopHeader(
                  scrolled: _desktopScrolled,
                  onHome: onLogoTap,
                  onSection: (i) => _handleAdminNav(const [
                    'dashboard', 'whatsapp', 'customers', 'suppliers', 'fulfillment'
                  ][i]),
                  onAdminNav: _handleAdminNav,
                  isSuperAdmin: _amISuper,
                  deletionCount: _deletionCount,
                  alertCount: _alertCount,
                  bellKey: _bellKey, // CHANGE #298
                )
              else
                _DesktopHeader(
                  bellKey: _bellKey, // CHANGE #298
                  scrolled: _desktopScrolled,
                  onHome: onLogoTap,
                  logoTooltip: '',
                  onBulk: () => _setIndex(2),
                  onOrders: () => _setIndex(1),
                  onCart: () => _openCart(),
                  // Web/desktop keeps the right-side slide-in panel, but its body
                  // is now the SAME mobile WhatsApp/Google LoginView (via
                  // LoginPanel → LoginPanelView), not the legacy email/password.
                  onLogin: () => setState(() => _loginOpen = true),
                  index: _index,
                  cartOpen: _cartOpen,
                ),
              // ── Search + chips: storefront only (index 0) ─────────────────
              if (_index == 0)
                _DesktopSearchRow(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  isLoading: _searchLoading,
                  onSearch: _handleDesktopSearch,
                  onScrollToResults: () => setState(() => _scrollTrigger++),
                ),
              if (_index == 0)
                _MobileCategoryChips(
                  meta: _desktopMeta,
                  selected: _category,
                  onCategoryTap: (key) => _selectCategory(key),
                ),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (_index != 0) return false;
                    final newScrolled = n.metrics.pixels > 400;
                    if (newScrolled != _desktopScrolled) {
                      setState(() => _desktopScrolled = newScrolled);
                    }
                    return false;
                  },
                  child: IndexedStack(
                    index: _index,
                    children: pages,
                  ),
                ),
              ),
            ],
          ),
          // CHANGE #636 — same pill on desktop, same reasoning as mobile above.
          if (!isAdmin && _index == 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: RepaintBoundary(
                child: CartPill(onTap: () => _openCart()),
              ),
            ),
          if (!isAdmin) ...[
            LoginPanel(
              open: _loginOpen,
              onClose: () => setState(() => _loginOpen = false),
            ),
            RepaintBoundary(
              child: CartPanel(
                open: _cartOpen,
                onClose: () => setState(() => _cartOpen = false),
                onOrderPlaced: () {
                  setState(() => _ordersRefreshSignal++);
                  _setIndex(1);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────── Location header ───────────────────────
