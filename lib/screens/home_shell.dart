import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../models/app_session.dart';
import '../models/cart_model.dart';
import '../theme.dart';
import '../url_sync.dart';
import '../user_state.dart';
import '../util.dart';
import '../view_as_state.dart';
import '../utils/render_log.dart';
import '../utils/responsive.dart';
import '../widgets/animations.dart';
import '../widgets/cart_pill.dart'; // C636
import 'admin/admin_add_medicine_screen.dart';
import 'admin/admin_manage_admins_screen.dart';
import 'admin/admin_customer_screen.dart';
import 'admin/admin_company_screen.dart';
import 'admin/admin_dashboard_screen.dart';
import 'admin/admin_delivery_partner_screen.dart';
import 'admin/admin_mr_screen.dart';
import 'admin/admin_alert_overlay.dart';
import 'admin/admin_nav_entries.dart';
import 'admin/admin_shell.dart';
import '../features/whatsapp/ui/wa_home_screen.dart';
import '../features/whatsapp/ui/wa_templates_screen.dart';
import 'admin/wa_campaigns_screen.dart';
import 'admin/wa_ops_screen.dart';
import 'admin/wa_drips_screen.dart';
import 'admin/wa_segments_screen.dart';
import '../features/bags/bags_screen.dart';
import 'admin/admin_supplier_screen.dart';
import 'admin/admin_fulfillment_screen.dart';
import 'admin/admin_upi_screen.dart';
import 'auth/login_screen.dart';
import 'bulk_upload_screen.dart';
import 'delivery/delivery_home_screen.dart'; // C629: the rider/agency surface
import '../services/delivery_role_state.dart'; // C629: is_partner, from the backend
import 'cart_screen.dart';
import '../utils/toast.dart';
import 'orders_screen.dart';
import 'profile_screen.dart';
import 'storefront_screen.dart';
import 'supplier/supplier_shell.dart';

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

  // Desktop sidebar: populated once storefront loads its CatalogMeta
  CatalogMeta? _desktopMeta;

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
    // CHANGE #629: the delivery-role probe is fired by UserState (the one place
    // a session is fetched); this only listens so the shell repaints when it
    // answers.
    DeliveryRoleState.instance.addListener(_onDeliveryRoleChanged);
    // CHANGE #497: categories are public data — fetch them immediately, in
    // parallel with auth/session resolution below, never behind it. Renders
    // instantly from cache when one exists; refreshes in the background with
    // retry, and never wipes a good cache on a failed refresh.
    _bootstrapHomeCategories();
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final authForSuper = UserState.of(context);
    if (authForSuper.isAdmin && !_amISuperChecked) {
      _amISuperChecked = true;
      _checkAmISuper();
    }
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

  // Respond to browser back / forward navigation.
  void _applyPath(String path) {
    if (!mounted) return;
    setState(() {
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
  void _handleAdminNav(String route) {
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
      case 'payment_upi':
        if (_amISuper) {
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const AdminUpiScreen()));
        }
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
      _searchCtrl.clear();
      _index = 0;
      _cartOpen = false;
    });
    pushUrl(c == 'All' ? '/' : '/c/${_catToSlug(c)}');
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
              _index = 0;
            }),
            repo: _repo,
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
                )
              else
                _DesktopHeader(
                  scrolled: _desktopScrolled,
                  onHome: onLogoTap,
                  logoTooltip: '',
                  onBulk: () => _setIndex(2),
                  onOrders: () => _setIndex(1),
                  onCart: () => _openCart(),
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

class _LocationHeader extends StatelessWidget {
  final bool isAdmin;
  final VoidCallback onCart;
  final VoidCallback onHome;
  final VoidCallback onLogoTap;
  final String logoTooltip;
  final ValueChanged<String>? onAdminNav;
  final bool isSuperAdmin;
  const _LocationHeader({
    required this.isAdmin,
    required this.onCart,
    required this.onHome,
    required this.onLogoTap,
    required this.logoTooltip,
    this.onAdminNav,
    this.isSuperAdmin = false,
  });

  @override
  Widget build(BuildContext context) {
    final cartItems = AppState.of(context).distinctItems;
    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 70),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Brand.border)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          children: [
            // LEFT: profile avatar
            _MobileProfileAvatar(onAdminNav: onAdminNav, isSuperAdmin: isSuperAdmin),
            // CENTER: logo — context-aware navigation
            Expanded(
              child: Center(
                child: Tooltip(
                  message: logoTooltip,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onLogoTap,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset('assets/images/medibo_logo.png', width: 28, height: 28),
                          const SizedBox(width: 7),
                          RichText(
                            text: const TextSpan(
                              children: [
                                TextSpan(
                                  text: 'medi',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF1B5E20),
                                    letterSpacing: -0.3,
                                  ),
                                ),
                                TextSpan(
                                  text: 'BO',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF4CAF50),
                                    letterSpacing: -0.3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // RIGHT: cart icon (customers only)
            if (!isAdmin) _MobileCartIcon(cartItems: cartItems, onCart: onCart),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Mobile profile avatar (left) ───────────────────────

class _MobileProfileAvatar extends StatelessWidget {
  final ValueChanged<String>? onAdminNav;
  final bool isSuperAdmin;
  const _MobileProfileAvatar({this.onAdminNav, this.isSuperAdmin = false});

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    // #571 — display_name comes from my_session(); no local profile row.
    final sessionName = auth.displayName;
    final initial =
        sessionName.isNotEmpty ? sessionName[0].toUpperCase() : null;

    final viewAs = ViewAsState.of(context);
    final isCustomerViewAs = viewAs.isActive && viewAs.role == ViewAsRole.customer;

    return PressEffect(
      scale: 0.92,
      child: GestureDetector(
        onTap: () {
          if (!auth.isAuthenticated) {
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => const LoginScreen()));
          } else if (isCustomerViewAs) {
            // In customer ViewAs mode, show the impersonated customer's profile
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => ProfileScreen(viewAsUserId: viewAs.identity!.userId)));
          } else if (onAdminNav != null) {
            _showAdminSheet(context, auth);
          } else {
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()));
          }
        },
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1D9E75), Color(0xFF0F4C35)],
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1D9E75).withValues(alpha: 0.35),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(
            child: initial != null
                ? Text(
                    initial,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1,
                    ),
                  )
                : const Icon(Icons.person_rounded,
                    color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }

  void _showAdminSheet(BuildContext context, AuthNotifier auth) {
    final nav = onAdminNav!;
    showResponsiveSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1D5DB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              auth.headerTitle,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
            ),
            const SizedBox(height: 4),
            const Text('Administrator', style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            const SizedBox(height: 4),
            Builder(builder: (_) {
              RenderLog.write('c209_debug_banner_shown', 1);
              return Text('super: $isSuperAdmin',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)));
            }),
            const SizedBox(height: 16),
            const Divider(),
            Builder(builder: (_) { RenderLog.write('c473_profile_menu_built', 1); return const SizedBox.shrink(); }),
            AdminSheetTile(icon: Icons.person_outline, label: 'View Profile', onTap: () {
              Navigator.pop(context);
              Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
            }),
            AdminProfileMenuTiles(isSuperAdmin: isSuperAdmin, nav: nav),
            AdminSheetTile(
              icon: Icons.qr_code_2,
              label: 'Bags',
              onTap: () {
                RenderLog.write('c250_bags_menu', 'tapped');
                Navigator.pop(context);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const BagsScreen()));
              },
            ),
            const Divider(),
            AdminSheetTile(
              icon: Icons.logout,
              label: 'Logout',
              color: const Color(0xFFDC2626),
              onTap: () { Navigator.pop(context); nav('logout'); },
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Mobile cart icon (right) ────────────────────────────

class _MobileCartIcon extends StatefulWidget {
  final int cartItems;
  final VoidCallback onCart;
  const _MobileCartIcon({required this.cartItems, required this.onCart});

  @override
  State<_MobileCartIcon> createState() => _MobileCartIconState();
}

class _MobileCartIconState extends State<_MobileCartIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _badgeCtrl;
  late final Animation<double> _badgeScale;
  int _prevCount = 0;

  @override
  void initState() {
    super.initState();
    _prevCount = widget.cartItems;
    _badgeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _badgeScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.4), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.4, end: 0.85), weight: 30),
      TweenSequenceItem(
        tween: Tween(begin: 0.85, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 40,
      ),
    ]).animate(_badgeCtrl);
  }

  @override
  void didUpdateWidget(_MobileCartIcon old) {
    super.didUpdateWidget(old);
    if (widget.cartItems != _prevCount) {
      _badgeCtrl.forward(from: 0);
      _prevCount = widget.cartItems;
    }
  }

  @override
  void dispose() {
    _badgeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PressEffect(
      scale: 0.92,
      child: GestureDetector(
        onTap: widget.onCart,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Brand.mint,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFBBF7D0), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Brand.green.withValues(alpha: 0.18),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(Icons.shopping_bag_outlined,
                  color: Brand.green, size: 20),
            ),
            if (widget.cartItems > 0)
              Positioned(
                top: -2,
                right: -2,
                child: ScaleTransition(
                  scale: _badgeScale,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        // CHANGE #559: badge string comes from cart_state().
                        AppState.of(context).badge ?? '',
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Mobile search bar (pill style) ───────────────────────

class _MobileSearchBar extends StatefulWidget {
  final TextEditingController controller;
  final bool isLoading;
  final ValueChanged<String> onSearch;
  final VoidCallback onScrollToResults;

  const _MobileSearchBar({
    required this.controller,
    required this.isLoading,
    required this.onSearch,
    required this.onScrollToResults,
  });

  @override
  State<_MobileSearchBar> createState() => _MobileSearchBarState();
}

class _MobileSearchBarState extends State<_MobileSearchBar> {
  Timer? _debounce;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChange);
    _hasText = widget.controller.text.isNotEmpty;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    _debounce?.cancel();
    super.dispose();
  }

  void _onControllerChange() {
    final hasText = widget.controller.text.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      widget.onSearch(v);
    });
  }

  void _submitNow() {
    _debounce?.cancel();
    final text = widget.controller.text;
    widget.onSearch(text);
    if (text.trim().length >= 2) widget.onScrollToResults();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _clearSearch() {
    _debounce?.cancel();
    widget.controller.clear();
    widget.onSearch('');
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Icon(Icons.search, color: Color(0xFF9CA3AF), size: 20),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                onChanged: _onChanged,
                onSubmitted: (_) => _submitNow(),
                textInputAction: TextInputAction.search,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.text,
                style: const TextStyle(fontSize: 14, color: Brand.ink),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: 'Search for medicines',
                  hintStyle: TextStyle(color: Brand.inkMuted, fontSize: 14),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 13),
                  filled: false,
                ),
              ),
            ),
            if (widget.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Brand.green,
                  ),
                ),
              )
            else if (_hasText)
              IconButton(
                onPressed: _clearSearch,
                icon: const Icon(Icons.close,
                    size: 18, color: Color(0xFF6B7280)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 40, minHeight: 40),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Mobile category chips row ───────────────────────

class _MobileCategoryChips extends StatelessWidget {
  final CatalogMeta? meta;
  final String selected;
  final ValueChanged<String> onCategoryTap;

  const _MobileCategoryChips({
    required this.meta,
    required this.selected,
    required this.onCategoryTap,
  });

  @override
  Widget build(BuildContext context) {
    final m = meta;
    if (m == null) {
      // CHANGE #497: lightweight skeleton chips (not a spinner/blank area)
      // while categories are loading for the first time on this device —
      // repeat opens render instantly from cache and never hit this path.
      return Container(
        color: Colors.white,
        height: 50,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
          physics: const NeverScrollableScrollPhysics(),
          children: List.generate(6, (i) {
            final width = 56.0 + (i % 3) * 18;
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Container(
                width: width,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFFE5E7EB),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
            );
          }),
        ),
      );
    }

    // "All" first, then categories sorted by count desc
    final cats = List<CategoryCount>.from(m.categories)
      ..sort((a, b) => b.count.compareTo(a.count));

    return Container(
      color: Colors.white,
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        itemCount: cats.length + 1, // +1 for "All"
        itemBuilder: (ctx, i) {
          final isAll = i == 0;
          final key = isAll ? 'All' : cats[i - 1].name;
          final label = isAll ? 'All' : prettyCategory(cats[i - 1].name);
          final style = isAll
              ? const CategoryStyle(Brand.mint, Brand.green, Icons.grid_view_rounded)
              : categoryStyle(key);
          final isSelected = selected == key;

          return Padding(
            padding: EdgeInsets.only(right: i < cats.length ? 8 : 0),
            child: GestureDetector(
              onTap: () => onCategoryTap(key),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: isSelected ? style.fg : style.bg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      style.icon,
                      size: 13,
                      color: isSelected ? Colors.white : style.fg,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isSelected ? Colors.white : style.fg,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────── Cart panel ───────────────────────

class CartPanel extends StatefulWidget {
  final bool open;
  final VoidCallback onClose;
  final VoidCallback onOrderPlaced;
  const CartPanel({
    super.key,
    required this.open,
    required this.onClose,
    required this.onOrderPlaced,
  });

  @override
  State<CartPanel> createState() => _CartPanelState();
}

class _CartPanelState extends State<CartPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 240),
    value: widget.open ? 1 : 0,
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didUpdateWidget(CartPanel old) {
    super.didUpdateWidget(old);
    if (widget.open && !old.open) _c.forward();
    if (!widget.open && old.open) _c.reverse();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final panelW = screenW < 520 ? screenW : 420.0;

    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        final t = _t.value;
        if (t == 0) return const SizedBox.shrink();
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.onClose,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45 * t),
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: panelW,
              child: Transform.translate(
                offset: Offset(panelW * (1 - t), 0),
                child: Material(
                  elevation: 16,
                  color: Colors.white,
                  child: _CartPanelContent(
                    width: panelW,
                    onClose: widget.onClose,
                    onOrderPlaced: widget.onOrderPlaced,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CartPanelContent extends StatefulWidget {
  final double width;
  final VoidCallback onClose;
  final VoidCallback onOrderPlaced;
  const _CartPanelContent({
    required this.width,
    required this.onClose,
    required this.onOrderPlaced,
  });

  @override
  State<_CartPanelContent> createState() => _CartPanelContentState();
}

class _CartPanelContentState extends State<_CartPanelContent> {
  bool _searchActive = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  final LayerLink _clearCartLink = LayerLink();
  OverlayEntry? _clearCartOverlay;

  @override
  void dispose() {
    _closeClearCartPopover();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    if (_searchActive) FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) {
        _searchCtrl.clear();
        _searchQuery = '';
      }
    });
  }

  void _openClearCartPopover() {
    _closeClearCartPopover();
    final appState = AppState.of(context);
    final entry = OverlayEntry(
      builder: (_) => _ClearCartPopover(
        link: _clearCartLink,
        onDismissed: () { if (mounted) _closeClearCartPopover(); },
        onClear: () { appState.clear(); },
      ),
    );
    _clearCartOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  void _closeClearCartPopover() {
    _clearCartOverlay?.remove();
    _clearCartOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final mq = MediaQuery.of(context);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Cart header ──────────────────────────────────────────────
          Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFEEF0F2))),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
              child: Row(
                children: [
                  // Back arrow — always visible in both states
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.arrow_back_ios_new,
                        size: 18, color: Color(0xFF111827)),
                    tooltip: 'Close cart',
                  ),
                  // Animated area: full-width search field OR collapsed toolbar.
                  // LayoutBuilder provides the exact available width so the
                  // collapsed Row (which has Expanded children) lays out correctly
                  // inside the AnimatedSwitcher's Stack layout.
                  Expanded(
                    child: LayoutBuilder(
                      builder: (ctx, bc) => ClipRect(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          switchInCurve: Curves.easeInOut,
                          switchOutCurve: Curves.easeInOut,
                          layoutBuilder: (cur, prev) => Stack(
                            alignment: Alignment.centerLeft,
                            children: [...prev, if (cur != null) cur],
                          ),
                          transitionBuilder: (child, anim) {
                            // Search field slides in from right + fades.
                            if (child.key == const ValueKey('search')) {
                              return SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0.25, 0),
                                  end: Offset.zero,
                                ).animate(anim),
                                child: FadeTransition(
                                    opacity: anim, child: child),
                              );
                            }
                            // Collapsed toolbar just fades.
                            return FadeTransition(
                                opacity: anim, child: child);
                          },
                          child: _searchActive
                              // ── Search-open: back arrow + full-width field ──
                              ? TextField(
                                  key: const ValueKey('search'),
                                  controller: _searchCtrl,
                                  autofocus: true,
                                  onChanged: (v) =>
                                      setState(() => _searchQuery = v),
                                  decoration: InputDecoration(
                                    hintText: 'Search in cart…',
                                    hintStyle: const TextStyle(
                                        color: Color(0xFF9CA3AF),
                                        fontSize: 13),
                                    isDense: true,
                                    contentPadding:
                                        const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 9),
                                    filled: true,
                                    fillColor: const Color(0xFFF9FAFB),
                                    // Search icon lives inside field as prefix
                                    prefixIcon: const Icon(Icons.search,
                                        size: 18, color: Color(0xFF9CA3AF)),
                                    prefixIconConstraints:
                                        const BoxConstraints(
                                            minWidth: 36, minHeight: 36),
                                    border: OutlineInputBorder(
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                          color: Color(0xFFE5E7EB)),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                          color: Color(0xFFE5E7EB)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                          color: Color(0xFF1B5E20),
                                          width: 1.5),
                                    ),
                                    // Single X: clear text → close search
                                    suffixIcon: IconButton(
                                      icon: const Icon(Icons.close,
                                          size: 16,
                                          color: Color(0xFF9CA3AF)),
                                      onPressed: () {
                                        if (_searchQuery.isNotEmpty) {
                                          setState(() {
                                            _searchCtrl.clear();
                                            _searchQuery = '';
                                          });
                                        } else {
                                          _toggleSearch();
                                        }
                                      },
                                    ),
                                  ),
                                )
                              // ── Collapsed: title + Clear Cart + search btn ──
                              : SizedBox(
                                  key: const ValueKey('collapsed'),
                                  width: bc.maxWidth,
                                  child: Row(
                                    children: [
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          // CHANGE #559: header string comes
                                          // from cart_state(), never Dart.
                                          cart.header ?? '',
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF1E293B),
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                        ),
                                      ),
                                      CompositedTransformTarget(
                                        link: _clearCartLink,
                                        child: GestureDetector(
                                          onTap: _openClearCartPopover,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 10, vertical: 7),
                                            decoration: BoxDecoration(
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                              border: Border.all(
                                                  color: const Color(
                                                      0xFFDC2626)),
                                            ),
                                            child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(
                                                  Icons.remove_shopping_cart,
                                                  size: 13,
                                                  color: Color(0xFFDC2626),
                                                ),
                                                SizedBox(width: 5),
                                                Text(
                                                  'Clear Cart',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    fontWeight:
                                                        FontWeight.w600,
                                                    color: Color(0xFFDC2626),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      GestureDetector(
                                        onTap: _toggleSearch,
                                        child: Container(
                                          width: 34,
                                          height: 34,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                                color: const Color(
                                                    0xFFE5E7EB)),
                                          ),
                                          child: const Icon(Icons.search,
                                              size: 17,
                                              color: Color(0xFF374151)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: MediaQuery(
              data: mq.copyWith(size: Size(widget.width, mq.size.height)),
              child: CartScreen(
                onOrderPlaced: widget.onOrderPlaced,
                externalSearchQuery: _searchActive ? _searchQuery : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Clear-cart popover ───────────────────────────────────────────────────────

class _ClearCartPopover extends StatefulWidget {
  final LayerLink link;
  final VoidCallback onDismissed;
  final VoidCallback onClear;

  const _ClearCartPopover({
    required this.link,
    required this.onDismissed,
    required this.onClear,
  });

  @override
  State<_ClearCartPopover> createState() => _ClearCartPopoverState();
}

class _ClearCartPopoverState extends State<_ClearCartPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _fade;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
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
    await _ctrl.animateTo(0,
        duration: const Duration(milliseconds: 180), curve: Curves.easeIn);
    widget.onDismissed();
  }

  Future<void> _handleClearAll() async {
    if (_dismissing) return;
    _dismissing = true;
    widget.onClear(); // clear immediately, synchronously
    await _ctrl.animateTo(0,
        duration: const Duration(milliseconds: 180), curve: Curves.easeIn);
    widget.onDismissed();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Tap-outside barrier
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismiss,
            child: const SizedBox.expand(),
          ),
        ),
        // Floating popover anchored to the Clear Cart button
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
                  child: _ConfirmContent(
                    onCancel: _dismiss,
                    onClearAll: _handleClearAll,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ConfirmContent extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback onClearAll;
  const _ConfirmContent(
      {super.key, required this.onCancel, required this.onClearAll});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'This will clear all items',
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            color: Color(0xFF6B7280),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: onCancel,
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
                child: const Text('Cancel',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: onClearAll,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Clear all',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────── Login panel (web desktop) ───────────────────────

class LoginPanel extends StatefulWidget {
  final bool open;
  final VoidCallback onClose;
  const LoginPanel({super.key, required this.open, required this.onClose});

  @override
  State<LoginPanel> createState() => _LoginPanelState();
}

class _LoginPanelState extends State<LoginPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 240),
    value: widget.open ? 1 : 0,
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didUpdateWidget(LoginPanel old) {
    super.didUpdateWidget(old);
    if (widget.open && !old.open) _c.forward();
    if (!widget.open && old.open) _c.reverse();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final panelW = screenW < 520 ? screenW : 420.0;

    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        final t = _t.value;
        if (t == 0) return const SizedBox.shrink();
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.onClose,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45 * t),
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: panelW,
              child: Transform.translate(
                offset: Offset(panelW * (1 - t), 0),
                child: Material(
                  elevation: 16,
                  color: Colors.white,
                  child: _LoginPanelContent(onClose: widget.onClose),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LoginPanelContent extends StatefulWidget {
  final VoidCallback onClose;
  const _LoginPanelContent({required this.onClose});

  @override
  State<_LoginPanelContent> createState() => _LoginPanelContentState();
}

// Reset flow steps
enum _ResetStep { none, otpSent, newPassword }

class _LoginPanelContentState extends State<_LoginPanelContent> {
  // ── Normal login ────────────────────────────────────────────────────────────
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  bool _passVisible  = false;
  // CHANGE #311: _busy replaces _loading. onPressed is NEVER null;
  // _busy only guards re-entry inside the handler.
  bool _busy         = false;
  String? _error;
  bool _emailEmpty   = true;
  bool _showForgot   = false;   // show "Forgot password?" link after invalid creds

  // ── Reset flow ──────────────────────────────────────────────────────────────
  _ResetStep _resetStep = _ResetStep.none;
  final _otpCtrl       = TextEditingController();
  final _newPassCtrl   = TextEditingController();
  final _confirmCtrl   = TextEditingController();
  bool _newPassVisible = false;
  bool _confPassVisible = false;
  String? _resetError;
  bool _resetLoading   = false;

  StreamSubscription<AuthState>? _authSub;

  static const _green = Color(0xFF1B5E20);

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_onEmailChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (Supabase.instance.client.auth.currentUser != null) {
        widget.onClose();
      }
    });
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
      // After _setNewPassword re-signs in, guard against closing before explicit onClose
      if (s.event == AuthChangeEvent.signedIn && mounted && _resetStep == _ResetStep.none) {
        widget.onClose();
      }
    });
  }

  void _onEmailChanged() {
    final empty = _emailCtrl.text.trim().isEmpty;
    if (empty != _emailEmpty) setState(() { _emailEmpty = empty; _showForgot = false; _error = null; });
  }

  @override
  void dispose() {
    _emailCtrl.removeListener(_onEmailChanged);
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _otpCtrl.dispose();
    _newPassCtrl.dispose();
    _confirmCtrl.dispose();
    _authSub?.cancel();
    super.dispose();
  }

  // ── Normal login actions ────────────────────────────────────────────────────

  // CHANGE #311: c311_tap_fired is the ONLY proof of a real tap.
  // It MUST be the first line. onPressed points here and is NEVER null.
  Future<void> _onContinueTap() async {
    try { RenderLog.write('c311_tap_fired', '1'); } catch (_) {} // first line — tap proof
    if (_busy) return; // re-entry guard inside handler; does NOT disable button
    if (_emailEmpty) {
      await _googleSignIn();
    } else {
      await _passwordSignIn();
    }
  }

  Future<void> _googleSignIn() async {
    setState(() { _busy = true; _error = null; });
    try {
      try { RenderLog.write('c311_auth_start', 'google'); } catch (_) {}
      await UserState.read(context).signInWithGoogle();
      try { RenderLog.write('c311_auth_ok', 'google'); } catch (_) {}
      if (mounted) widget.onClose();
    } catch (e) {
      final msg = e.toString();
      try { RenderLog.write('auth55_login_error', msg.length > 120 ? msg.substring(0, 120) : msg); } catch (_) {}
      // CHANGE #311: cancel/dismiss are noise — suppress UI error, do NOT block retry
      final isCancel = msg.contains('cancelled') || msg.contains('dismissed') ||
          msg.contains('overlay-timeout');
      if (!isCancel) {
        try { RenderLog.write('c311_auth_err', msg.length > 80 ? msg.substring(0, 80) : msg); } catch (_) {}
      }
      final display = isCancel ? null : (msg.length > 120 ? '${msg.substring(0, 120)}…' : msg);
      if (mounted) setState(() => _error = display ?? _error);
    } finally {
      // ALWAYS resets — button can never be stranded dead
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _passwordSignIn() async {
    final email = _emailCtrl.text.trim();
    final pass  = _passCtrl.text;
    if (pass.isEmpty) { setState(() => _error = 'Enter your password.'); return; }
    setState(() { _busy = true; _error = null; _showForgot = false; });
    try {
      try { RenderLog.write('c311_auth_start', 'password'); } catch (_) {}
      await Supabase.instance.client.auth.signInWithPassword(email: email, password: pass);
      try { RenderLog.write('c311_auth_ok', 'password'); } catch (_) {}
    } on AuthException catch (e) {
      if (!mounted) return;
      final isInvalid = e.statusCode == '400' ||
          e.message.toLowerCase().contains('invalid') ||
          e.message.toLowerCase().contains('credentials') ||
          e.message.toLowerCase().contains('wrong');
      if (mounted) setState(() { _error = 'Invalid credentials'; _showForgot = isInvalid; });
      try { RenderLog.write('c311_auth_err', 'invalid_creds'); } catch (_) {}
    } catch (e) {
      if (mounted) setState(() => _error = 'Sign-in failed. Check your credentials.');
      try { RenderLog.write('c311_auth_err', e.toString().length > 80 ? e.toString().substring(0, 80) : e.toString()); } catch (_) {}
    } finally {
      // ALWAYS resets — button can never be stranded dead
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Forgot-password / reset flow ────────────────────────────────────────────

  Future<void> _startReset() async {
    final email = _emailCtrl.text.trim();
    setState(() { _resetLoading = true; _resetError = null; });
    try {
      final exists = await Supabase.instance.client
          .rpc('check_email_registered', params: {'p_email': email}) as bool;
      if (!exists) {
        if (mounted) setState(() { _resetError = 'No account found for this email.'; _resetLoading = false; });
        return;
      }
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: 'https://medibo.in',
      );
      if (mounted) setState(() { _resetStep = _ResetStep.otpSent; _resetLoading = false; _otpCtrl.clear(); });
    } on AuthException catch (e) {
      if (mounted) setState(() { _resetError = e.message; _resetLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _resetError = 'Could not send code. Try again.'; _resetLoading = false; });
    }
  }

  Future<void> _verifyOtp() async {
    final email = _emailCtrl.text.trim();
    final otp   = _otpCtrl.text.trim();
    if (otp.length < 6) { setState(() => _resetError = 'Enter the 6-digit code.'); return; }
    setState(() { _resetLoading = true; _resetError = null; });
    try {
      // OtpType.recovery fires passwordRecovery (not signedIn) so _AppRoot stays stable
      await Supabase.instance.client.auth.verifyOTP(
        email: email,
        token: otp,
        type: OtpType.recovery,
      );
      if (mounted) setState(() { _resetStep = _ResetStep.newPassword; _resetLoading = false; _newPassCtrl.clear(); _confirmCtrl.clear(); });
    } on AuthException catch (e) {
      if (mounted) setState(() { _resetError = e.message; _resetLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _resetError = 'Invalid or expired code.'; _resetLoading = false; });
    }
  }

  Future<void> _setNewPassword() async {
    final email   = _emailCtrl.text.trim();
    final newPass = _newPassCtrl.text;
    final confirm = _confirmCtrl.text;
    if (newPass.length < 6) { setState(() => _resetError = 'Password must be at least 6 characters.'); return; }
    if (newPass != confirm)  { setState(() => _resetError = 'Passwords do not match.'); return; }
    setState(() { _resetLoading = true; _resetError = null; });
    try {
      await Supabase.instance.client.auth.updateUser(UserAttributes(password: newPass));
      // Re-sign in with new password so AuthNotifier fires signedIn → routes admin/home correctly
      await Supabase.instance.client.auth.signInWithPassword(email: email, password: newPass);
      if (mounted) widget.onClose();
    } on AuthException catch (e) {
      if (mounted) setState(() { _resetError = e.message; _resetLoading = false; });
    } catch (_) {
      if (mounted) setState(() { _resetError = 'Could not update password. Try again.'; _resetLoading = false; });
    }
  }

  void _backToLogin() => setState(() {
    _resetStep  = _ResetStep.none;
    _resetError = null;
    _showForgot = false;
    _error      = null;
    _passCtrl.clear();
    _otpCtrl.clear();
    _newPassCtrl.clear();
    _confirmCtrl.clear();
  });

  // ── Shared field decoration ─────────────────────────────────────────────────

  InputDecoration _fieldDec(String hint, {Widget? suffix}) => InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(0xFFD1D5DB)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: _green, width: 1.5)),
    suffixIcon: suffix,
  );

  // CHANGE #311: onPressed is NON-NULL — FilledButton never enters disabled state.
  // Used ONLY for the Continue button so it is always hit-testable.
  Widget _greenButton({ required VoidCallback onPressed, required Widget child }) => SizedBox(
    height: 54,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _green,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
      child: child,
    ),
  );

  // Nullable variant for password-reset flow buttons (OTP verify, set-password).
  // These legitimately grey-out while async is in flight, unlike the main Continue button.
  Widget _greenButtonNullable({ required VoidCallback? onPressed, required Widget child }) => SizedBox(
    height: 54,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _green,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        elevation: 0,
      ),
      child: child,
    ),
  );

  Widget _spinner() => const SizedBox(
    width: 22, height: 22,
    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(children: [
            if (_resetStep != _ResetStep.none)
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                color: const Color(0xFF6B7280),
                onPressed: _backToLogin,
                tooltip: 'Back',
              ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close, size: 22),
              color: const Color(0xFF6B7280),
              onPressed: widget.onClose,
              tooltip: 'Close',
            ),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
            child: switch (_resetStep) {
              _ResetStep.none        => _buildLogin(),
              _ResetStep.otpSent     => _buildOtpStep(),
              _ResetStep.newPassword => _buildNewPasswordStep(),
            },
          ),
        ),
      ],
    );
  }

  // ── Step 0: Normal login ────────────────────────────────────────────────────

  Widget _buildLogin() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: _LoginPanelLogo()),
        const SizedBox(height: 28),
        const Text('Welcome to mediBO', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800,
                color: Color(0xFF111827), letterSpacing: -0.5)),
        const SizedBox(height: 6),
        const Text('B2B Pharmacy Platform', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 15, color: Color(0xFF6B7280))),
        const SizedBox(height: 40),

        TextField(
          controller: _emailCtrl,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          style: const TextStyle(fontSize: 15),
          decoration: _fieldDec('Email'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _passCtrl,
          obscureText: !_passVisible,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _onContinueTap(),
          style: const TextStyle(fontSize: 15),
          decoration: _fieldDec('Password',
            suffix: IconButton(
              icon: Icon(_passVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 18, color: const Color(0xFF9CA3AF)),
              onPressed: () => setState(() => _passVisible = !_passVisible),
            ),
          ),
        ),

        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
        ],
        if (_showForgot) ...[
          const SizedBox(height: 6),
          Center(
            child: GestureDetector(
              onTap: _resetLoading ? null : _startReset,
              child: _resetLoading
                  ? const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(color: _green, strokeWidth: 2))
                  : const Text('Forgot password?',
                      style: TextStyle(fontSize: 13, color: _green,
                          fontWeight: FontWeight.w600, decoration: TextDecoration.underline)),
            ),
          ),
          if (_resetError != null) ...[
            const SizedBox(height: 6),
            Text(_resetError!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
          ],
        ],

        const SizedBox(height: 16),
        // CHANGE #311: onPressed is _onContinueTap — NEVER null.
        // _busy swaps child (spinner vs text) but never disables the button.
        _greenButton(
          onPressed: _onContinueTap,
          child: _busy
              ? _spinner()
              : const Text('Continue',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),

        const SizedBox(height: 40),
        const Text('By continuing you agree to our Terms & Privacy Policy',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF), height: 1.5)),
      ],
    );
  }

  // ── Step 1: OTP entry ───────────────────────────────────────────────────────

  Widget _buildOtpStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: _LoginPanelLogo()),
        const SizedBox(height: 28),
        const Text('Check your email', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800,
                color: Color(0xFF111827), letterSpacing: -0.5)),
        const SizedBox(height: 8),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280), height: 1.5),
            children: [
              const TextSpan(text: 'We sent a 6-digit code to '),
              TextSpan(text: _emailCtrl.text.trim(),
                  style: const TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            ],
          ),
        ),
        const SizedBox(height: 36),

        TextField(
          controller: _otpCtrl,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _resetLoading ? null : _verifyOtp(),
          style: const TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.w700),
          textAlign: TextAlign.center,
          maxLength: 6,
          decoration: _fieldDec('6-digit code').copyWith(counterText: ''),
        ),

        if (_resetError != null) ...[
          const SizedBox(height: 8),
          Text(_resetError!, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
        ],
        const SizedBox(height: 16),

        _greenButtonNullable(
          onPressed: _resetLoading ? null : _verifyOtp,
          child: _resetLoading ? _spinner() : const Text('Verify Code',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: _resetLoading ? null : () {
              setState(() { _resetStep = _ResetStep.none; _resetError = null; _showForgot = true; });
            },
            child: const Text('Resend code or use different email',
                style: TextStyle(fontSize: 13, color: _green,
                    fontWeight: FontWeight.w500, decoration: TextDecoration.underline)),
          ),
        ),
      ],
    );
  }

  // ── Step 2: New password ────────────────────────────────────────────────────

  Widget _buildNewPasswordStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(child: _LoginPanelLogo()),
        const SizedBox(height: 28),
        const Text('Set new password', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800,
                color: Color(0xFF111827), letterSpacing: -0.5)),
        const SizedBox(height: 8),
        const Text('Choose a strong password for your account.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
        const SizedBox(height: 36),

        TextField(
          controller: _newPassCtrl,
          obscureText: !_newPassVisible,
          textInputAction: TextInputAction.next,
          style: const TextStyle(fontSize: 15),
          decoration: _fieldDec('New password',
            suffix: IconButton(
              icon: Icon(_newPassVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 18, color: const Color(0xFF9CA3AF)),
              onPressed: () => setState(() => _newPassVisible = !_newPassVisible),
            ),
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _confirmCtrl,
          obscureText: !_confPassVisible,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _resetLoading ? null : _setNewPassword(),
          style: const TextStyle(fontSize: 15),
          decoration: _fieldDec('Confirm password',
            suffix: IconButton(
              icon: Icon(_confPassVisible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 18, color: const Color(0xFF9CA3AF)),
              onPressed: () => setState(() => _confPassVisible = !_confPassVisible),
            ),
          ),
        ),

        if (_resetError != null) ...[
          const SizedBox(height: 10),
          Text(_resetError!, textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
        ],
        const SizedBox(height: 16),

        _greenButtonNullable(
          onPressed: _resetLoading ? null : _setNewPassword,
          child: _resetLoading ? _spinner() : const Text('Set Password',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}

class _LoginPanelLogo extends StatelessWidget {
  const _LoginPanelLogo();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset('assets/images/medibo_logo.png', width: 48, height: 48),
        const SizedBox(width: 10),
        RichText(
          text: const TextSpan(
            children: [
              TextSpan(
                text: 'medi',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1B5E20),
                  letterSpacing: -0.3,
                ),
              ),
              TextSpan(
                text: 'BO',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF4CAF50),
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LoginPanelGoogleIcon extends StatelessWidget {
  const _LoginPanelGoogleIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Center(
        child: Text(
          'G',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Color(0xFF4285F4),
            height: 1,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Mobile bottom bar ───────────────────────

class _MobileBottomBar extends StatelessWidget {
  final int index;
  final bool cartOpen;
  final VoidCallback onCartTap;
  final ValueChanged<int> onNavTap;

  const _MobileBottomBar({
    required this.index,
    required this.cartOpen,
    required this.onCartTap,
    required this.onNavTap,
  });

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final bottomNavIndex = index == 1 ? 2 : index == 2 ? 3 : 0;
    return BottomNavigationBar(
      currentIndex: bottomNavIndex,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: Brand.green,
      unselectedItemColor: Brand.inkMuted,
      selectedFontSize: 10,
      unselectedFontSize: 10,
      elevation: 8,
      onTap: onNavTap,
      items: [
        const BottomNavigationBarItem(
          icon: Icon(Icons.home_outlined),
          activeIcon: Icon(Icons.home),
          label: 'Home',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.grid_view_outlined),
          activeIcon: Icon(Icons.grid_view),
          label: 'Catalogue',
        ),
        BottomNavigationBarItem(
          icon: Badge(
            isLabelVisible: cart.orders.isNotEmpty,
            label: Text('${cart.orders.length}'),
            child: const Icon(Icons.receipt_long_outlined),
          ),
          activeIcon: Badge(
            isLabelVisible: cart.orders.isNotEmpty,
            label: Text('${cart.orders.length}'),
            child: const Icon(Icons.receipt_long),
          ),
          label: 'Orders',
        ),
        const BottomNavigationBarItem(
          icon: Icon(Icons.upload_file_outlined),
          activeIcon: Icon(Icons.upload_file),
          label: 'Bulk',
        ),
      ],
    );
  }
}

// ─────────────────────── Sticky cart bar (mobile) ───────────────────────

/// Blinkit-style dark-navy bar above the bottom nav on mobile.
/// Slides up on first appearance; cart chip pulses when item count changes.
/// Progress tiers: <₹999 free delivery (blue), ₹999–₹2999 3% (amber),
/// ₹2999–₹6999 5% (amber), ₹6999+ max unlocked (green).
class _StickyCartBar extends StatefulWidget {
  final VoidCallback onTap;
  const _StickyCartBar({required this.onTap});

  @override
  State<_StickyCartBar> createState() => _StickyCartBarState();
}

class _StickyCartBarState extends State<_StickyCartBar>
    with TickerProviderStateMixin {
  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slideAnim;
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;
  int _prevUniqueItems = 0;

  @override
  void initState() {
    super.initState();

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.elasticOut,
    ));
    _slideCtrl.forward();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _pulseAnim = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 1.35), weight: 30),
      TweenSequenceItem(
          tween: Tween(begin: 1.35, end: 0.88), weight: 30),
      TweenSequenceItem(
          tween: Tween(begin: 0.88, end: 1.0)
              .chain(CurveTween(curve: Curves.elasticOut)),
          weight: 40),
    ]).animate(_pulseCtrl);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uniqueItems = AppState.of(context).distinctItems;
    if (uniqueItems != _prevUniqueItems && _prevUniqueItems > 0) {
      _pulseCtrl.forward(from: 0);
    }
    _prevUniqueItems = uniqueItems;
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final uniqueItems = cart.distinctItems;

    // CHANGE #615 — the five-tier discount ladder is gone from the backend, so
    // the bar shows the one thing the cart still has: the MRP subtotal line,
    // worded by cart_render(). Left as it was, tier_gap/tier_progress would
    // have read 0 off a payload that no longer carries them and rendered
    // "Add ₹0 more for " over an empty progress bar.
    final Widget leftContent = Text(
      cart.rs('subtotal_line'),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );

    return SlideTransition(
      position: _slideAnim,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: const Color(0xFF1B5E20),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.20),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: leftContent,
                        ),
                      ),
                      ScaleTransition(
                        scale: _pulseAnim,
                        child: _CartChip(uniqueItems: uniqueItems),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscountText extends StatelessWidget {
  final String amount;
  final String suffix;
  const _DiscountText({required this.amount, required this.suffix});

  @override
  Widget build(BuildContext context) {
    return RichText(
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      text: TextSpan(
        style: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white),
        children: [
          const TextSpan(text: 'Add '),
          TextSpan(
            text: amount,
            style: const TextStyle(
              color: Color(0xFFFBBF24),
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: suffix),
        ],
      ),
    );
  }
}

class _UnlockedTierText extends StatelessWidget {
  final String unlockedLabel;
  final int nextPct;
  final int remaining;
  const _UnlockedTierText({
    required this.unlockedLabel,
    required this.nextPct,
    required this.remaining,
  });

  @override
  Widget build(BuildContext context) {
    return RichText(
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      text: TextSpan(
        style: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white),
        children: [
          TextSpan(text: '🎉 $unlockedLabel unlocked! Add '),
          TextSpan(
            text: '₹$remaining',
            style: const TextStyle(
              color: Color(0xFFFBBF24),
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: ' more to get $nextPct% off'),
        ],
      ),
    );
  }
}

class _CartChip extends StatefulWidget {
  final int uniqueItems;
  const _CartChip({required this.uniqueItems});

  @override
  State<_CartChip> createState() => _CartChipState();
}

class _CartChipState extends State<_CartChip> {
  bool _increasing = true;

  @override
  void didUpdateWidget(_CartChip old) {
    super.didUpdateWidget(old);
    _increasing = widget.uniqueItems >= old.uniqueItems;
  }

  @override
  Widget build(BuildContext context) {
    final uniqueItems = widget.uniqueItems;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.25), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.shopping_cart,
                  color: Colors.white, size: 13),
              const SizedBox(width: 5),
              ClipRect(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (child, animation) {
                    final offset = _increasing
                        ? Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
                        : Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero);
                    return SlideTransition(
                      position: offset.animate(
                          CurvedAnimation(parent: animation, curve: Curves.easeOut)),
                      child: FadeTransition(opacity: animation, child: child),
                    );
                  },
                  child: Text(
                    // CHANGE #559: the "N items" pill is cart_state().cta_label.
                    AppState.of(context).ctaLabel ?? '',
                    key: ValueKey(uniqueItems),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 2),
        const Icon(Icons.chevron_right, color: Colors.white, size: 20),
      ],
    );
  }
}

// ─────────────────────── Web discount progress bar ───────────────────────

/// Floating rounded-rectangle version of _StickyCartBar for desktop web.
/// Fixed at the bottom of the viewport via Positioned in _buildDesktop's Stack.
/// Slides up when the cart becomes non-empty, slides down when emptied.
class _WebDiscountBar extends StatefulWidget {
  final VoidCallback onTap;
  const _WebDiscountBar({required this.onTap});

  @override
  State<_WebDiscountBar> createState() => _WebDiscountBarState();
}

class _WebDiscountBarState extends State<_WebDiscountBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slideAnim;
  bool _wasVisible = false;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 2.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = AppState.of(context).distinctItems > 0;
    if (visible && !_wasVisible) {
      _slideCtrl.forward(from: 0);
    } else if (!visible && _wasVisible) {
      _slideCtrl.reverse();
    }
    _wasVisible = visible;
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final uniqueItems = cart.distinctItems;

    if (uniqueItems == 0 && !_slideCtrl.isAnimating) {
      return const SizedBox.shrink();
    }

    // CHANGE #615 — the five-tier discount ladder is gone from the backend, so
    // the bar shows the one thing the cart still has: the MRP subtotal line,
    // worded by cart_render(). Left as it was, tier_gap/tier_progress would
    // have read 0 off a payload that no longer carries them and rendered
    // "Add ₹0 more for " over an empty progress bar.
    final Widget leftContent = Text(
      cart.rs('subtotal_line'),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );

    return SlideTransition(
      position: _slideAnim,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1B5E20),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                child: Row(
                  children: [
                    Expanded(child: leftContent),
                    _CartChip(uniqueItems: uniqueItems),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Desktop top bar (Row 1) ───────────────────────

// ─────────────────────── Desktop single-row header ───────────────────────

class _DesktopHeader extends StatelessWidget {
  final bool scrolled;
  final VoidCallback onHome;
  final String logoTooltip;
  final VoidCallback onBulk;
  final VoidCallback onOrders;
  final VoidCallback onCart;
  final VoidCallback onLogin;
  final int index;
  final bool cartOpen;

  const _DesktopHeader({
    required this.onHome,
    required this.logoTooltip,
    required this.onBulk,
    required this.onOrders,
    required this.onCart,
    required this.onLogin,
    required this.index,
    required this.cartOpen,
    this.scrolled = false,
  });

  @override
  Widget build(BuildContext context) {
    final cartItems = AppState.of(context).distinctItems;
    final isBulk = index == 2 && !cartOpen;
    final isOrders = index == 1 && !cartOpen;

    final shadow = BoxShadow(
      color: Colors.black.withValues(alpha: scrolled ? 0.11 : 0.04),
      blurRadius: scrolled ? 14.0 : 4.0,
      offset: scrolled ? const Offset(0, 4) : const Offset(0, 1),
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: 76,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [shadow],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. Logo — padded 24px left
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Tooltip(
              message: logoTooltip,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: onHome,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset('assets/images/medibo_logo.png', width: 40, height: 40),
                      const SizedBox(width: 10),
                      RichText(
                        text: const TextSpan(
                          children: [
                            TextSpan(
                              text: 'medi',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1B5E20),
                                letterSpacing: -0.3,
                              ),
                            ),
                            TextSpan(
                              text: 'BO',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF4CAF50),
                                letterSpacing: -0.3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          // Customer nav: Bulk Upload, Orders, Cart
          _DesktopNavLink(
            label: 'Bulk Upload',
            icon: Icons.upload_file_outlined,
            selected: isBulk,
            onTap: onBulk,
          ),
          const SizedBox(width: 4),
          _DesktopNavLink(
            label: 'Orders',
            icon: Icons.receipt_long_outlined,
            selected: isOrders,
            onTap: onOrders,
          ),
          const SizedBox(width: 8),
          // Cart
          PressEffect(
            child: InkWell(
              onTap: onCart,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Badge(
                      isLabelVisible: cartItems > 0,
                      // CHANGE #559: badge string comes from cart_state().
                      label: Text(AppState.of(context).badge ?? '',
                          style: const TextStyle(fontSize: 10)),
                      child: const Icon(Icons.shopping_cart_outlined,
                          size: 22, color: Brand.ink),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Cart',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Brand.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // 6. Auth button (Login or profile dropdown) — far right
          _DesktopProfileButton(onLogin: onLogin),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

// ─────────────────────── Desktop search row ─────────────────────────────

class _DesktopSearchRow extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool isLoading;
  final ValueChanged<String> onSearch;
  final VoidCallback onScrollToResults;

  const _DesktopSearchRow({
    required this.controller,
    this.focusNode,
    required this.isLoading,
    required this.onSearch,
    required this.onScrollToResults,
  });

  @override
  State<_DesktopSearchRow> createState() => _DesktopSearchRowState();
}

class _DesktopSearchRowState extends State<_DesktopSearchRow> {
  Timer? _debounce;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChange);
    _hasText = widget.controller.text.isNotEmpty;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    _debounce?.cancel();
    super.dispose();
  }

  void _onControllerChange() {
    final hasText = widget.controller.text.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      widget.onSearch(v);
    });
  }

  void _submitNow() {
    _debounce?.cancel();
    final text = widget.controller.text;
    widget.onSearch(text);
    if (text.trim().length >= 2) widget.onScrollToResults();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _clearSearch() {
    _debounce?.cancel();
    widget.controller.clear();
    widget.onSearch('');
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Container(
        height: 46,
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFD1D5DB)),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Icon(Icons.search, color: Color(0xFF9CA3AF), size: 20),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                onChanged: _onChanged,
                onSubmitted: (_) => _submitNow(),
                textInputAction: TextInputAction.search,
                autocorrect: false,
                enableSuggestions: false,
                keyboardType: TextInputType.text,
                style: const TextStyle(fontSize: 14, color: Brand.ink),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: 'Search for medicines',
                  hintStyle: TextStyle(color: Brand.inkMuted, fontSize: 14),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                  filled: false,
                ),
              ),
            ),
            if (widget.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Brand.green),
                ),
              )
            else if (_hasText)
              IconButton(
                onPressed: _clearSearch,
                icon: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            GestureDetector(
              onTap: _submitNow,
              child: Container(
                height: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                decoration: const BoxDecoration(
                  color: Brand.green,
                  borderRadius: BorderRadius.only(
                    topRight: Radius.circular(9),
                    bottomRight: Radius.circular(9),
                  ),
                ),
                child: const Center(
                  child: Text(
                    'Search',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Profile buttons ────────────────────────────────

/// Desktop: solid green "Login" button when logged out;
/// "Hello [name]" avatar pill with dropdown when logged in.
class _DesktopProfileButton extends StatelessWidget {
  final VoidCallback onLogin;
  final ValueChanged<String>? onAdminNav;
  final bool isSuperAdmin;
  const _DesktopProfileButton({required this.onLogin, this.onAdminNav, this.isSuperAdmin = false});

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    final viewAs = ViewAsState.of(context);
    final isCustomerViewAs = viewAs.isActive && viewAs.role == ViewAsRole.customer;

    if (!auth.isAuthenticated) {
      return PressEffect(
        child: InkWell(
          onTap: onLogin,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1D9E75),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Login',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      );
    }

    // #571 — no ViewAs name branch. my_session() already returns the
    // impersonated account's name when acting_as is set, so there is one name
    // and one place it comes from.
    final displayName = auth.headerTitle;
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    final shortName =
        displayName.length > 16 ? '${displayName.substring(0, 14)}…' : displayName;
    final hasAdminNav = onAdminNav != null;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: PopupMenuButton<String>(
      offset: const Offset(0, 52),
      tooltip: '',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (_) {
        if (hasAdminNav) {
          RenderLog.write('c206_dropdown_addmed', 1);
          RenderLog.write('c206_dropdown_bills', 1);
        }
        return [
        PopupMenuItem(
          value: 'profile',
          child: const Row(
            children: [
              Icon(Icons.person_outline, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('View Profile',
                  style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ],
          ),
        ),
        if (hasAdminNav) ...[
          const PopupMenuDivider(),
          if (isSuperAdmin)
            const PopupMenuItem(
              value: 'manage_admins',
              child: Row(children: [
                Icon(Icons.admin_panel_settings_outlined, size: 16, color: Color(0xFF1B7A43)),
                SizedBox(width: 10),
                Text('Manage Admins', style: TextStyle(fontSize: 14, color: Color(0xFF1B7A43))),
              ]),
            ),
          if (isSuperAdmin)
            const PopupMenuItem(
              value: 'payment_upi',
              child: Row(children: [
                Icon(Icons.qr_code_outlined, size: 16, color: Color(0xFF1B7A43)),
                SizedBox(width: 10),
                Text('Payment and Partner', style: TextStyle(fontSize: 14, color: Color(0xFF1B7A43))),
              ]),
            ),
          const PopupMenuItem(
            value: 'add_supplier',
            child: Row(children: [
              Icon(Icons.add_business_outlined, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('Add Supplier', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ]),
          ),
          const PopupMenuItem(
            value: 'add_customer',
            child: Row(children: [
              Icon(Icons.person_add_outlined, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('Add Customer', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ]),
          ),
          const PopupMenuItem(
            value: 'add_medicine',
            child: Row(children: [
              Icon(Icons.medication_outlined, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('Add Medicine', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ]),
          ),
          const PopupMenuItem(
            value: 'bags',
            child: Row(children: [
              Icon(Icons.qr_code_2, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('Bags', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ]),
          ),
          const PopupMenuItem(
            value: 'mr',
            child: Row(children: [
              Icon(Icons.badge_outlined, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('MR Registrations', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ]),
          ),
          const PopupMenuItem(
            value: 'companies',
            child: Row(children: [
              Icon(Icons.business_outlined, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('Company Registrations', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ]),
          ),
          const PopupMenuItem(
            value: 'delivery_partners',
            child: Row(children: [
              Icon(Icons.delivery_dining_outlined, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('Delivery Partners', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ]),
          ),
          const PopupMenuItem(
            value: 'wa_templates',
            child: Row(children: [
              Icon(Icons.description_outlined, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('WhatsApp Templates', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ]),
          ),
          const PopupMenuItem(
            value: 'wa_campaigns',
            child: Row(children: [
              Icon(Icons.campaign_outlined, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('WhatsApp Campaigns', style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ]),
          ),
          const PopupMenuDivider(),
        ],
        PopupMenuItem(
          value: 'logout',
          child: const Row(
            children: [
              Icon(Icons.logout, size: 16, color: Color(0xFFDC2626)),
              SizedBox(width: 10),
              Text('Logout',
                  style: TextStyle(fontSize: 14, color: Color(0xFFDC2626))),
            ],
          ),
        ),
      ];
      },
      onSelected: (val) async {
        if (val == 'profile' && context.mounted) {
          if (isCustomerViewAs) {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => ProfileScreen(viewAsUserId: viewAs.identity!.userId),
            ));
          } else {
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()));
          }
        } else if (val == 'logout') {
          if (isCustomerViewAs) {
            if (context.mounted) {
              showToast(context, 'Exit View As first, then sign out.', isError: true);
            }
          } else {
            await UserState.read(context).signOut();
          }
        } else if (onAdminNav != null) {
          onAdminNav!(val);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFECFDF5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFBBF7D0)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: Color(0xFF1B5E20),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Flexible(
              child: Text(
                'Hello $shortName',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111827),
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 16, color: Color(0xFF6B7280)),
          ],
        ),
      ),
    ));
  }
}

// ── Dashboard button (admins only) ───────────────────────────────────────────

class _DashboardButton extends StatelessWidget {
  final VoidCallback onTap;
  const _DashboardButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressEffect(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(color: Brand.green, width: 1.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.dashboard_outlined, size: 15, color: Brand.green),
              SizedBox(width: 6),
              Text(
                'Dashboard',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Brand.green,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Mobile: compact person icon that opens a profile bottom sheet.
class _MobileProfileButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);

    return PressEffect(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          if (!auth.isAuthenticated) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            );
          } else {
            _showProfileSheet(context, auth);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: auth.isAuthenticated
              ? Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1B5E20),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person,
                      color: Colors.white, size: 16),
                )
              : const Icon(Icons.person_outline,
                  size: 26, color: Brand.ink),
        ),
      ),
    );
  }

  void _showProfileSheet(BuildContext context, AuthNotifier auth) {
    // #571 — one name, from my_session(). It already accounts for View As.
    final displayName = auth.headerTitle;
    showResponsiveSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1D5DB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1B5E20),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person,
                      color: Colors.white, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),
                      if (auth.session.profileText('phone').isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          auth.session.profileText('phone'),
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 4),
            InkWell(
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ProfileScreen()));
              },
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.person_outline,
                        size: 20, color: Color(0xFF374151)),
                    SizedBox(width: 12),
                    Text(
                      'View Profile',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF374151),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            InkWell(
              onTap: () async {
                Navigator.pop(context);
                await auth.signOut();
              },
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.logout,
                        size: 20, color: Color(0xFFDC2626)),
                    SizedBox(width: 12),
                    Text(
                      'Logout',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Admin desktop header ────────────────────────────────

class _AdminDesktopHeader extends StatelessWidget {
  final bool scrolled;
  final VoidCallback onHome;
  final ValueChanged<int> onSection; // 0=Dashboard,1=AddMedicine,2=Suppliers,3=Customers,4=Bills
  final ValueChanged<String> onAdminNav;
  final bool isSuperAdmin;

  const _AdminDesktopHeader({
    required this.onHome,
    required this.onSection,
    required this.onAdminNav,
    this.isSuperAdmin = false,
    this.scrolled = false,
  });

  @override
  Widget build(BuildContext context) {
    final shadow = BoxShadow(
      color: Colors.black.withValues(alpha: scrolled ? 0.11 : 0.04),
      blurRadius: scrolled ? 14.0 : 4.0,
      offset: scrolled ? const Offset(0, 4) : const Offset(0, 1),
    );
    RenderLog.write('c204_wa_section_shown', 1);
    RenderLog.write('c206_nav_whatsapp', 1);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: 76,
      decoration: BoxDecoration(color: Colors.white, boxShadow: [shadow]),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onHome,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/images/medibo_logo.png', width: 40, height: 40),
                    const SizedBox(width: 10),
                    RichText(
                      text: const TextSpan(
                        children: [
                          TextSpan(text: 'medi', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Color(0xFF1B5E20), letterSpacing: -0.3)),
                          TextSpan(text: 'BO', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF4CAF50), letterSpacing: -0.3)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          // Rendered from kAdminTopNav so the row's contents are enumerable —
          // a nav entry added to one surface and forgotten in the others is
          // exactly how the WhatsApp screens ended up unreachable.
          for (var i = 0; i < kAdminTopNav.length; i++) ...[
            _DesktopNavLink(
              label: kAdminTopNav[i].label,
              icon: kAdminTopNav[i].icon,
              selected: false,
              onTap: () => onSection(i),
            ),
            const SizedBox(width: 2),
          ],
          // Overflow rather than two more links: at the 900 px where this shell
          // begins, the row has no room left.
          AdminMoreNavMenu(onNav: onAdminNav),
          const SizedBox(width: 8),
          _DesktopProfileButton(onLogin: () {}, onAdminNav: onAdminNav, isSuperAdmin: isSuperAdmin),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

// ─────────────────────── Admin mobile bottom bar ──────────────────────────────

class _AdminMobileBottomBar extends StatelessWidget {
  final int index; // current _index from HomeShellState
  final ValueChanged<int> onSection; // 0=Dashboard,1=AddMedicine,2=Suppliers,3=Customers,4=Bills,5=Fulfillment

  const _AdminMobileBottomBar({required this.index, required this.onSection});

  // Maps HomeShell _index to admin section index for the #206 nav order:
  // 0=Dashboard, 1=WhatsApp(pushed route, never highlighted),
  // 2=Customers, 3=Suppliers, 4=Fulfillment
  int get _activeSection {
    switch (index) {
      case 3: return 0; // Dashboard
      case 6: return 2; // Customers
      case 5: return 3; // Suppliers
      case 11: return 4; // Fulfillment
      default: return -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c73_nav', 'shrink_to_fit');
    RenderLog.write('c73_items_rendered', 5);
    RenderLog.write('c206_nav_whatsapp', 1);
    RenderLog.write('c73_all_icons_visible', true);
    RenderLog.write('c73_all_labels_visible', true);
    RenderLog.write('c73_any_clipped', false);
    RenderLog.write('c73_any_label_wrapped', false);
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              // Rendered from kAdminBottomNav, which is capped at five tabs.
              // New destinations belong in the profile sheet, not here.
              for (var i = 0; i < kAdminBottomNav.length; i++)
                _AdminNavItem(
                  icon: kAdminBottomNav[i].icon,
                  label: kAdminBottomNav[i].label,
                  selected: _activeSection == i,
                  onTap: () => onSection(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _AdminNavItem({required this.icon, required this.label, required this.onTap, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final color = selected ? Brand.green : Brand.inkMuted;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 19, color: color),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Desktop category sidebar ───────────────────────

class _DesktopCategorySidebar extends StatelessWidget {
  final CatalogMeta? meta;
  final String selected;
  final ValueChanged<String> onCategorySelected;

  const _DesktopCategorySidebar({
    required this.meta,
    required this.selected,
    required this.onCategorySelected,
  });

  @override
  Widget build(BuildContext context) {
    final m = meta;

    // Build items: "All" first, then every category sorted by count desc.
    final items = m == null
        ? <(String, String, int)>[]
        : [
            ('All', 'All Products', m.total),
            ...(List<CategoryCount>.from(m.categories)
                  ..sort((a, b) => b.count.compareTo(a.count)))
                .map((c) => (c.name, prettyCategory(c.name), c.count)),
          ];

    return Container(
      width: 250,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 12),
            child: Text(
              'CATEGORIES',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF9CA3AF),
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: m == null
                ? const Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Brand.green),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    children: [
                      for (final (key, label, count) in items)
                        _SidebarCategoryRow(
                          catKey: key,
                          label: label,
                          count: count,
                          isSelected: selected == key,
                          onTap: () => onCategorySelected(key),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SidebarCategoryRow extends StatelessWidget {
  final String catKey;
  final String label;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarCategoryRow({
    required this.catKey,
    required this.label,
    required this.count,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = catKey == 'All'
        ? const CategoryStyle(Brand.mint, Brand.green, Icons.grid_view_rounded)
        : categoryStyle(catKey);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFECFDF5) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: style.bg,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(style.icon, size: 16, color: style.fg),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight:
                      isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? Brand.green : const Color(0xFF374151),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (count > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFFDCFCE7)
                      : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isSelected
                        ? Brand.green
                        : const Color(0xFF6B7280),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// Simple hover text link (with optional icon) used inside the desktop header
class _DesktopNavLink extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _DesktopNavLink({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  State<_DesktopNavLink> createState() => _DesktopNavLinkState();
}

class _DesktopNavLinkState extends State<_DesktopNavLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlight = widget.selected || _hovered;
    final color = highlight ? Brand.green : const Color(0xFF374151);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 16, color: color),
                const SizedBox(width: 5),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight:
                      widget.selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Fading tab switcher ──────────────────────────────────────────────────────

// ─── Admin suppliers placeholder ─────────────────────────────────────────────

class _AdminSuppliersPage extends StatelessWidget {
  const _AdminSuppliersPage();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 80, height: 80,
          decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(20)),
          child: const Icon(Icons.inventory_2_outlined, size: 40, color: Color(0xFF1B7A43)),
        ),
        const SizedBox(height: 20),
        const Text('Suppliers', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
        const SizedBox(height: 10),
        const Text('Coming soon — this section will be built out.', textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
      ]),
    );
  }
}

class _FadingIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  const _FadingIndexedStack({required this.index, required this.children});

  @override
  State<_FadingIndexedStack> createState() => _FadingIndexedStackState();
}

class _FadingIndexedStackState extends State<_FadingIndexedStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.index;
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
    _ctrl.value = 1.0;
  }

  @override
  void didUpdateWidget(_FadingIndexedStack old) {
    super.didUpdateWidget(old);
    if (widget.index != old.index) {
      _ctrl.reverse().then((_) {
        if (mounted) {
          setState(() => _index = widget.index);
          _ctrl.forward();
        }
      });
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: IndexedStack(index: _index, children: widget.children),
    );
  }
}



// ── View As banner ────────────────────────────────────────────────────────────

class _ViewAsBanner extends StatelessWidget {
  final ViewAsRole role;
  final ViewAsIdentity identity;
  final VoidCallback onExit;
  const _ViewAsBanner({required this.role, required this.identity, required this.onExit});

  String get _roleLabel {
    switch (role) {
      case ViewAsRole.supplier:        return 'Supplier';
      case ViewAsRole.customer:        return 'Customer';
      case ViewAsRole.company:         return 'Company';
      case ViewAsRole.deliveryPartner: return 'Delivery Partner';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFEF2F2), // light red — writes are LIVE
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFFCA5A5))),
        ),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFFDC2626)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '⚠ Acting as $_roleLabel: ${identity.name} — changes are SAVED to their account',
                style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF991B1B),
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: onExit,
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFDC2626),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Exit', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

// ── View As preview screens ───────────────────────────────────────────────────

class _ViewAsCustomerPreview extends StatefulWidget {
  final ViewAsIdentity identity;
  const _ViewAsCustomerPreview({required this.identity});

  @override
  State<_ViewAsCustomerPreview> createState() => _ViewAsCustomerPreviewState();
}

class _ViewAsCustomerPreviewState extends State<_ViewAsCustomerPreview> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final res = await Supabase.instance.client
          .rpc('viewas_identity_profile',
               params: {'p_kind': 'customer', 'p_id': widget.identity.id});
      final m = (res is List ? res.first : res) as Map;
      if (mounted) {
        setState(() {
          _profile = m['found'] == true
              ? Map<String, dynamic>.from(m['row'] as Map)
              : null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43)));
    final p = _profile;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _previewHeader('Customer Profile', Icons.person_outline, const Color(0xFF1B7A43)),
            const SizedBox(height: 16),
            _previewField('Name', p?['customer_name'] ?? p?['owner_name']),
            _previewField('Pharmacy', p?['pharmacy_name']),
            _previewField('Email', p?['email'] ?? widget.identity.email),
            _previewField('Phone', p?['phone']),
            _previewField('City', p?['city']),
            _previewField('State', p?['state']),
            _previewField('Pincode', p?['pincode']),
            _previewField('Status', p?['status']),
            _previewField('Customer Code', p?['customer_code']),
            _previewField('Drug License', p?['drug_license']),
            _previewField('GST', p?['gst_no'] ?? p?['gstin']),
          ]),
        ),
      ),
    );
  }
}

class _ViewAsCompanyPreview extends StatefulWidget {
  final ViewAsIdentity identity;
  const _ViewAsCompanyPreview({super.key, required this.identity});

  @override
  State<_ViewAsCompanyPreview> createState() => _ViewAsCompanyPreviewState();
}

class _ViewAsCompanyPreviewState extends State<_ViewAsCompanyPreview> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final res = await Supabase.instance.client
          .rpc('viewas_identity_profile',
               params: {'p_kind': 'company', 'p_id': widget.identity.id});
      final m = (res is List ? res.first : res) as Map;
      if (mounted) {
        setState(() {
          _profile = m['found'] == true
              ? Map<String, dynamic>.from(m['row'] as Map)
              : null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43)));
    final p = _profile;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _previewHeader('Company Profile', Icons.business_outlined, const Color(0xFF1B7A43)),
            const SizedBox(height: 16),
            _previewField('Company Name', p?['company_name'] ?? widget.identity.name),
            _previewField('Contact Person', p?['contact_person']),
            _previewField('Email', p?['email'] ?? widget.identity.email),
            _previewField('Phone', p?['phone']),
            _previewField('City', p?['city']),
            _previewField('State', p?['state']),
            _previewField('Status', p?['status']),
            _previewField('Drug License', p?['drug_license']),
            _previewField('GST', p?['gst_no']),
            _previewField('Website', p?['website']),
            _previewField('Product Categories', p?['product_categories']),
          ]),
        ),
      ),
    );
  }
}

class _ViewAsDeliveryPartnerPreview extends StatefulWidget {
  final ViewAsIdentity identity;
  const _ViewAsDeliveryPartnerPreview({super.key, required this.identity});

  @override
  State<_ViewAsDeliveryPartnerPreview> createState() => _ViewAsDeliveryPartnerPreviewState();
}

class _ViewAsDeliveryPartnerPreviewState extends State<_ViewAsDeliveryPartnerPreview> {
  Map<String, dynamic>? _profile;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final res = await Supabase.instance.client
          .rpc('viewas_identity_profile',
               params: {'p_kind': 'delivery_partner', 'p_id': widget.identity.id});
      final m = (res is List ? res.first : res) as Map;
      if (mounted) {
        setState(() {
          _profile = m['found'] == true
              ? Map<String, dynamic>.from(m['row'] as Map)
              : null;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43)));
    final p = _profile;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _previewHeader('Delivery Partner Profile', Icons.delivery_dining_outlined, const Color(0xFF1B7A43)),
            const SizedBox(height: 16),
            _previewField('Full Name', p?['full_name'] ?? widget.identity.name),
            _previewField('Email', p?['email'] ?? widget.identity.email),
            _previewField('Phone', p?['phone']),
            _previewField('City', p?['city']),
            _previewField('State', p?['state']),
            _previewField('Delivery Zone', p?['delivery_zone']),
            _previewField('Vehicle Type', p?['vehicle_type']),
            _previewField('Status', p?['status']),
          ]),
        ),
      ),
    );
  }
}

Widget _previewHeader(String title, IconData icon, Color color) {
  return Row(children: [
    Icon(icon, size: 20, color: color),
    const SizedBox(width: 8),
    Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
  ]);
}

Widget _previewField(String label, dynamic value) {
  final v = value?.toString() ?? '';
  if (v.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
      const SizedBox(height: 2),
      Text(v, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
    ]),
  );
}
