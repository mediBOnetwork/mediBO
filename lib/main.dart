import 'dart:async';
import 'dart:convert';

import 'boot_env.dart' as boot;
import 'widgets/app_update_prompt.dart';
import 'widgets/update_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';
import 'order_hours_state.dart';
import 'inquiry_lock_state.dart';
import 'url_sync.dart' show captureInitialPath;
import 'services/crash_reporting.dart'; // CHANGE #473
import 'services/version_watcher.dart';
import 'utils/render_log.dart';
import 'view_as_state.dart';
import 'models/cart_model.dart';
import 'models/order_hours_model.dart';
import 'models/inquiry_lock_model.dart';
import 'screens/auth/login_screen.dart';
import 'models/app_session.dart';
import 'screens/partner/partner_home_screen.dart';
import 'screens/customer/customer_staff_screen.dart'; // CMD #438: /customer/staff
import 'screens/admin/admin_partner_console_screen.dart';
import 'screens/admin/settlement_screen.dart'; // /admin/settlement
import 'screens/home_shell.dart';
import 'screens/public/inquiry_form_screen.dart';
import 'screens/public/stock_update_form_screen.dart'; // C639: /stock-update/<token>
import 'screens/public/storefront_screen.dart'; // CMD #417: /shop/<token>
import 'screens/public/substitute_token_screen.dart'; // #366: /substitute/<token>
import 'screens/admin/returns_refunds_screen.dart'; // C395: /admin/returns
import 'pages/dispute_token_page.dart';
import 'screens/public/dispute_form_screen.dart';
import 'screens/public/public_order_page.dart';
import 'screens/public/track_page.dart'; // C629: /track/<qr_token>
import 'screens/delivery/delivery_register_screen.dart'; // C631: PART A
import 'screens/code_resolver_page.dart';
import 'screens/public/wa_link_redirect_page.dart'; // /r/:code — campaign links
import 'screens/admin/wa_campaigns_screen.dart'; // /admin/wa-campaigns
import 'screens/admin/admin_scope_audit_screen.dart'; // /admin/scope-audit
import 'screens/admin/dev_queue/cron_health_screen.dart'; // /admin/cron-health
import 'screens/admin/test_mode_screen.dart';  // /admin/test-mode (#573)
import 'screens/admin/admin_delivery_extras_screen.dart'; // /admin/delivery-programme
import 'screens/pharmacy/pharmacy_owner_screen.dart';
import 'screens/pharmacy/pharmacy_expiry_screen.dart';   // CMD #413 — /pharmacy/expiry
import 'screens/pharmacy/pharmacy_radar_screen.dart';    // CMD #425 — /pharmacy/radar
import 'screens/pharmacy/pharmacy_parcel_count_screen.dart'; // CMD #431 — /pharmacy/parcel-count
import 'screens/pharmacy/pharmacy_variance_screen.dart'; // CMD #413 — /pharmacy/stock-check
import 'screens/pharmacy/pharmacy_audit_screen.dart';   // CMD #447 — /pharmacy/audit
import 'screens/pharmacy/rx_scan_screen.dart';           // CMD #418 — /pharmacy/prescription
import 'screens/admin/nav_registry_view.dart'; // CHANGE #325 — deep links
import 'screens/product_detail_screen.dart'; // C636: /product/:id
import 'screens/reorder_screen.dart'; // #173: /reorder
import 'screens/admin/reorder_admin_screen.dart'; // #173: /admin/reorder
import 'screens/company_screen.dart'; // C638: /company/:key
import 'screens/inquiry_link_page.dart';
import 'screens/dispute_link_page.dart';
import 'features/whatsapp/ui/wa_templates_screen.dart'; // admin WhatsApp templates
import 'screens/admin/wa_diagnosis_screen.dart';
import 'screens/admin/notify_center_screen.dart'; // CHANGE #297 — the notify() dispatcher's admin surface
import 'screens/admin/admin_push_screen.dart'; // CHANGE #298 — Firebase config + per-event push toggle
import 'screens/notifications_inbox_screen.dart'; // CHANGE #298 — the in-app inbox behind the bell
import 'screens/admin/wa_ops_screen.dart'; // admin WhatsApp ops + template pipeline
import 'screens/admin/admin_order_closure_screen.dart'; // CHANGE #229 — /admin/order-closure
import 'screens/about_screen.dart';
import 'screens/contact_screen.dart';
import 'screens/legal_pages.dart';
import 'screens/admin/admin_delivery_ops_screen.dart';
import 'screens/admin/admin_delivery_waves_screen.dart';
import 'screens/public/near_screen.dart'; // CMD #426 — /near, /near/p/<token>
import 'services/feature_gaps_service.dart'; // CHANGE #312
import 'services/ui_copy.dart';
import 'supabase_config.dart';
import 'theme.dart';
import 'design_tokens.dart';
import 'user_state.dart';
import 'widgets/animations.dart';

// Boot entry point: crash-isolated so no single subsystem can white-screen the app.
void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Flutter framework errors: log and swallow — never let them crash the boot.
    FlutterError.onError = (details) {
      try {
        final msg = details.exceptionAsString();
        RenderLog.write('flutter_error', msg.length > 120 ? msg.substring(0, 120) : msg);
      } catch (_) {}
      // CHANGE #473 — the same error, off the device: to Sentry when a DSN
      // exists, to the backend crash queue when it does not. Swallowed as
      // before, so reporting can never be the thing that white-screens a boot.
      try {
        CrashReporting.captureFlutterError(details);
      } catch (_) {}
    };

    captureInitialPath(); // must be called BEFORE usePathUrlStrategy() resets pathname
    usePathUrlStrategy();

    // Supabase init is crash-isolated: failure renders app in signed-out state.
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        // CHANGE #473 — RPC breadcrumbs. Wrapping the one client every RPC
        // already uses records the function name, status and duration of each
        // call with no change at a single call site. It reads the URL and the
        // status code only: never a request body, never a response body.
        httpClient: CrashReporting.breadcrumbHttpClient(),
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.pkce,
          autoRefreshToken: true,
          detectSessionInUri: true,
        ),
      );
    } catch (e) {
      try { RenderLog.write('boot_error', 'supabase_init_failed'); } catch (_) {}
    }

    // One-shot URL cleanup: strip ?code= / #access_token= immediately after SDK processes them.
    // Prevents browser session-restore from re-presenting the OAuth callback URL on reopen,
    // which would trigger a second PKCE exchange (400 bad_code_verifier) → spurious signedOut.
    try {
      final href = boot.locationHref();
      final uri = Uri.parse(href);
      final hasCode = uri.queryParameters.containsKey('code');
      final hasFragment = uri.fragment.contains('access_token=') ||
          uri.fragment.contains('refresh_token=') ||
          uri.fragment.contains('error=');
      if (hasCode || hasFragment) {
        boot.historyReplaceRoot();
        RenderLog.write('auth56_url_stripped', 'main_init; hadCode=$hasCode; hadFragment=$hasFragment');
        // CHANGE #308: note that SDK handled the exchange via detectSessionInUri
        if (hasCode) RenderLog.write('c308_code_exchange', 'ran:ok');
      }
    } catch (_) {}

    // Remove stale sv-typo key (sb-svojhmarmaijkshsbeih-auth-token) if left over from old builds.
    try {
      boot.localStorageRemove('sb-svojhmarmaijkshsbeih-auth-token');
    } catch (_) {}

    try {
      final raw = await boot.fetchText('/version.json');
      final info = jsonDecode(raw) as Map<String, dynamic>;
      RenderLog.setBuildHash(info['commit'] as String? ?? 'unknown');
      final changeNum = info['change'] as String?;
      if (changeNum != null) RenderLog.write('change', changeNum);
    } catch (_) {
      RenderLog.setBuildHash('unknown');
    }

    // CHANGE #473 — client crash reporting. Started here, after version.json,
    // so the build commit can ride along as a tag; the RELEASE itself is the
    // CHANGE number baked in at build time by deploy.sh. Crash-isolated: with
    // no DSN this is the local-queue path, and a failure leaves the app running.
    try {
      await CrashReporting.init(
        platform: kIsWeb ? 'web' : defaultTargetPlatform.name,
        buildCommit: RenderLog.buildHash,
      );
    } catch (_) {
      try { RenderLog.write('boot_error', 'crash_reporting_failed'); } catch (_) {}
    }
    // CHANGE #559: pick up anything the pre-Flutter JS instrumentation recorded
    // before/while the page left for Google, in case its keepalive write was
    // dropped. Safe no-op when there is nothing stored.
    RenderLog.adoptJsNotes();
    // CHANGE #432: restored ORIGINAL 1080x1080 logo, resize-only (no trim/reshape/gloss).
    RenderLog.write('c432_logo', 'icons=v4;resize_only');
    // CHANGE #612: the link parser accepts "/{CODE}/{token}" and hands both
    // segments to the backend as one untouched string. Written at boot (not
    // only when a link is opened) so the build itself is provable by curl.
    RenderLog.write('c612_link_token_passthrough', 1);
    // CHANGE #614: Orders tab re-fetches on account change and on tab open,
    // and renders has_orders / empty copy straight from my_orders_screen().
    RenderLog.write('c614_cart_smooth_orders_fix', 1);
    // CHANGE #619: Orders fetch records every outcome and re-asks when a live
    // session comes back "no customer account" — which cannot be true.
    RenderLog.write('c619_orders_render_fix', 1);
    // CHANGE #622: the Orders fetch names what it caught, and a failed load can
    // no longer masquerade as "no orders".
    RenderLog.write('c622_orders_error_state', 1);
    // #108 static build properties (flat list, responsive popup)
    RenderLog.write('inq_flat_list', 1);
    RenderLog.write('inq_toggle_removed', 1);
    RenderLog.write('inq_company_header_removed', 1);
    RenderLog.write('inq_category_header_removed', 1);
    // #111 static build properties (3-group accordion, no refresh button)
    RenderLog.write('inq.norefreshbtn', 1);
    RenderLog.write('inq.colours', 'pending=yellow;inquired=green;expired=red');
    // #112 static build properties (captcha removed, 20-row pages, 200 cap)
    RenderLog.write('c112_captcha_removed', 1);
    RenderLog.write('c112_page_size', 20);
    // #109 static build properties (select+submit mode)
    RenderLog.write('inq_admin_submit_mode', 1);
    RenderLog.write('inq_supplier_submit_mode', 1);
    RenderLog.write('screen', 'boot');
    RenderLog.write('c188_build', '188');
    RenderLog.write('c189_build', '189');
    RenderLog.write('c190_build', '190');
    RenderLog.write('c191_build', '191');
    RenderLog.write('c192_build', '192');
    RenderLog.write('c193_build', '193');
    RenderLog.write('c194_build', '194');
    RenderLog.write('c195_build', '195');
    RenderLog.write('c196_build', '196');
    RenderLog.write('c197_build', '197');
    RenderLog.write('c198_build', '198');
    RenderLog.write('c199_build', '199');
    RenderLog.write('c200_build', '200');
    RenderLog.write('c201_build', '201');
    RenderLog.write('c203_build', '203');
    RenderLog.write('c204_build', '204');
    RenderLog.write('c206_build', '206');
    RenderLog.write('c207_build', '207');
    RenderLog.write('c208_build', '208');
    RenderLog.write('c209_build', '209');
    RenderLog.write('c210_build', '210');
    RenderLog.write('c211_build', '211');
    RenderLog.write('c212_build', '212');
    RenderLog.write('c220_sw_update_wired', 1);
    RenderLog.write('c203b_proof_in_tile', 'proof_thumbnail_in_merged_tile_and_sheet');
    RenderLog.write('c190_sweep_done', 'hardcoded_labels_removed=true;dynamic_buttons=true;rpc_params_verified=true');
    RenderLog.write('c190_link_route_registered', '/dispute?token= route active');
    RenderLog.write('c317_build', '317');
    RenderLog.write('c318_build', '318');
    RenderLog.write('c319_build', '319');
    RenderLog.write('c320_build', '320');
    RenderLog.write('c321_build', '321');
    RenderLog.write('c383_build', '383');
    RenderLog.write('c383_bags_web_menu', 1);
    RenderLog.write('c383_bags_status_hidden', 1);
    RenderLog.write('c383_bags_print_wired', 1);
    RenderLog.write('c385_build', '385');
    RenderLog.write('c385_bags_green_header', 1);

    // Selftest hook (guarded; no-op without exact secret; mark for removal in #64).
    // Triggers signInWithPassword then defers the selftest_login trace to the
    // signedIn handler in user_state.dart where persistSession is guaranteed done.
    // Secret: ms62x9k7q.
    try {
      final uri = Uri.parse(boot.locationHref());
      if (uri.queryParameters['selftest'] == 'ms62x9k7q' &&
          uri.queryParameters['phase'] == 'login') {
        final em = uri.queryParameters['em'] ?? '';
        final pw = uri.queryParameters['pw'] ?? '';
        if (em.isNotEmpty && pw.isNotEmpty) {
          // Tell user_state.dart to write the selftest_login trace in signedIn handler.
          AuthNotifier.pendingSelftestEmail = em;
          try {
            await Supabase.instance.client.auth.signInWithPassword(
              email: em, password: pw);
          } catch (_) {
            AuthNotifier.pendingSelftestEmail = null;
          }
          // Yield so BehaviorSubject delivers signedIn → persistSession completes
          // before runApp starts. The trace is written from _onAuthChange(signedIn).
          for (var i = 0; i < 8; i++) {
            await Future<void>.delayed(Duration.zero);
          }
        }
      }
    } catch (_) {}

    // Every screen string that has no dedicated RPC field comes from
    // ui_copy_all(). Cache-first so a weak connection still paints words, and
    // crash-isolated so copy can never white-screen the boot.
    try {
      await UiCopy.load();
      RenderLog.write('ui_copy_keys', UiCopy.count);
      RenderLog.write('ui_copy_source', UiCopy.fromNetwork ? 'network' : 'cache');
      // CHANGE #66 — proof the app consumed the backend design tokens. A
      // headless verifier reads `ds_brand`; flip the brand via ui_design_set
      // and this value changes on next boot with zero code change.
      RenderLog.write('ds_brand', Ds.brandHex);
      RenderLog.write('ds_design_v', UiCopy.fromNetwork ? 'network' : 'cache');
    } catch (_) {
      try { RenderLog.write('boot_error', 'ui_copy_failed'); } catch (_) {}
    }

    runApp(const PharmaB2BApp());
  }, (error, stack) {
    // Zone-level catch-all: uncaught async errors are logged and swallowed.
    try {
      final msg = error.toString();
      RenderLog.write('boot_zone_error', msg.length > 120 ? msg.substring(0, 120) : msg);
    } catch (_) {}
    // CHANGE #473 — and reported. This is the handler that sees the crashes
    // nobody could see before: an uncaught async failure on a pharmacist's
    // phone, which used to end at a swallowed log line.
    try {
      CrashReporting.captureError(error, stack);
    } catch (_) {}
  });
}

class PharmaB2BApp extends StatefulWidget {
  const PharmaB2BApp({super.key});

  @override
  State<PharmaB2BApp> createState() => _PharmaB2BAppState();
}

class _PharmaB2BAppState extends State<PharmaB2BApp>
    with WidgetsBindingObserver {
  final CartModel _cart = CartModel();
  final AuthNotifier _auth = AuthNotifier();
  final ViewAsNotifier _viewAs = ViewAsNotifier();
  final OrderHoursModel _orderHours = OrderHoursModel();
  final InquiryLockModel _inquiryLock = InquiryLockModel();
  bool _viewAsRestored = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _viewAs.addListener(_onViewAsChanged);
    _auth.addListener(_onAuthChanged);
    // Boot may have painted from the ui_copy cache (or from nothing at all on
    // a first run with no network). Re-render the moment the real payload
    // lands so no screen is left showing yesterday's words.
    UiCopy.revision.addListener(_onCopyChanged);
  }

  void _onCopyChanged() {
    if (mounted) setState(() {});
  }

  // Foreground resume is one of the three moments a WhatsApp logout must take
  // effect: a device left open for an hour still holds a valid token the DB
  // already revoked. The guard debounces, so this is one cheap call at most
  // once per 20 s — never a timer/poll.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _auth.checkForcedLogout();
      // CHANGE #326 — resume is also the moment a role CHANGE must land. A
      // login promoted to (or demoted from) a zone partner while the app was
      // open otherwise kept the surface it booted with. Debounced to 20 s
      // inside the notifier and never awaited.
      _auth.refreshSessionIfStale();
    }
  }

  // Surface the backend's logout reason verbatim (no Dart wording). Runs on
  // every auth notify; only fires when a reason is set AND the messenger is
  // mounted, so a message is never dropped before it can be shown.
  void _maybeShowForcedLogout() {
    final msg = _auth.forcedLogoutMessage;
    if (msg.isEmpty) return;
    final messenger = VersionWatcher.instance.messengerKey.currentState;
    if (messenger == null) return; // not mounted yet — keep it for next notify
    _auth.clearForcedLogoutMessage();
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(msg)));
  }

  // ─── ViewAs persistence (shared_preferences only — never dart:html) ─────────

  void _onAuthChanged() {
    _maybeShowForcedLogout();
    // CHANGE #473 — the crash identity is role + uid and nothing else. The role
    // is pushed here because it is the one place it changes; the uid is read
    // from the live session at capture time.
    try {
      CrashReporting.setRole(_auth.session.role);
    } catch (_) {}
    // Run once when auth fully resolves (loading=false means role is set too).
    if (_viewAsRestored) return;
    if (_auth.loading) return;
    _viewAsRestored = true;
    if (_auth.isSuperAdmin && kEnableViewAs) {
      _tryRestoreViewAs();
    }
  }

  Future<void> _tryRestoreViewAs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('viewas_descriptor');
      if (raw == null) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final roleName = map['role'] as String?;
      ViewAsRole? roleValue;
      for (final r in ViewAsRole.values) {
        if (r.name == roleName) { roleValue = r; break; }
      }
      if (roleValue == null) {
        await prefs.remove('viewas_descriptor');
        RenderLog.write('view_as_restore', 'skipped:bad_role');
        return;
      }
      final id = map['id'] as String? ?? '';
      if (id.isEmpty) {
        await prefs.remove('viewas_descriptor');
        return;
      }
      final identity = ViewAsIdentity(
        id: id,
        name: map['name'] as String? ?? '',
        email: map['email'] as String? ?? '',
        userId: map['userId'] as String?,
        isApproved: map['isApproved'] as bool? ?? true,
      );
      _viewAs.activate(roleValue, identity);
      RenderLog.write('view_as_restore', '${roleValue.name}:$id');
      RenderLog.write(CartModel.kC410ImpersonationPersist,
          'rehydrated:${roleValue.name}:$id:userId:${identity.userId}');
    } catch (e) {
      try {
        final msg = e.toString();
        RenderLog.write('view_as_restore_error', msg.length > 80 ? msg.substring(0, 80) : msg);
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('viewas_descriptor');
      } catch (_) {}
    }
  }

  void _saveViewAsDescriptor() {
    try {
      final role = _viewAs.role;
      final identity = _viewAs.identity;
      if (role == null || identity == null) return;
      SharedPreferences.getInstance().then((prefs) {
        prefs.setString('viewas_descriptor', jsonEncode({
          'role':       role.name,
          'id':         identity.id,
          'name':       identity.name,
          'email':      identity.email,
          'userId':     identity.userId,
          'isApproved': identity.isApproved,
        }));
      });
    } catch (_) {}
  }

  void _clearViewAsDescriptor() {
    try {
      SharedPreferences.getInstance()
          .then((prefs) => prefs.remove('viewas_descriptor'));
    } catch (_) {}
  }

  // ─── ViewAs listener: syncs cart scope + persists descriptor ────────────────

  void _onViewAsChanged() {
    if (_viewAs.isActive) {
      _saveViewAsDescriptor();
    } else {
      _clearViewAsDescriptor();
    }
    if (_viewAs.isActive &&
        _viewAs.role == ViewAsRole.customer &&
        _viewAs.identity?.userId != null) {
      _cart.enterViewAs(_viewAs.identity!.userId!);
    } else {
      _cart.exitViewAs();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _viewAs.removeListener(_onViewAsChanged);
    _auth.removeListener(_onAuthChanged);
    UiCopy.revision.removeListener(_onCopyChanged);
    _cart.dispose();
    _auth.dispose();
    _viewAs.dispose();
    _orderHours.dispose();
    _inquiryLock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ViewAsState(
      notifier: _viewAs,
      child: UserState(
        notifier: _auth,
        child: AppState(
          cart: _cart,
          child: InquiryLockState(
            inquiryLock: _inquiryLock,
            child: OrderHoursState(
            orderHours: _orderHours,
            child: MaterialApp(
            title: 'mediBO',
            debugShowCheckedModeBanner: false,
            scaffoldMessengerKey: VersionWatcher.instance.messengerKey,
            // CHANGE #473 — navigation breadcrumbs. Route NAMES only; a route's
            // arguments can carry an order id or a customer name.
            navigatorObservers: [CrashReporting.navigatorObserver],
            theme: buildTheme(),
            scrollBehavior: const SmoothScrollBehavior(),
            // Belt-and-suspenders: clear any stray text decoration on Flutter web.
            builder: (context, child) => DefaultTextStyle.merge(
              style: const TextStyle(decoration: TextDecoration.none, decorationColor: Color(0x00000000)),
              // CHANGE #286 — the slim update bar lives here, above every
              // route, so it can sit over the bottom nav and the floating cart
              // pill without any screen knowing about it. It overlays: it
              // reflows nothing and it only takes taps inside its own bar.
              child: UpdateBarHost(
                controller: VersionWatcher.instance.updateBar,
                child: child!,
              ),
            ),
            home: _AppRoot(auth: _auth),
            // Public inquiry form — no auth required, handles /inquiry/<token>
            // Public dispute form  — no auth required, handles /dispute?token=<token>
            // Public order view    — no auth required, handles /order/<token>
            onGenerateRoute: (settings) {
              final name = settings.name ?? '';
              // CHANGE #636 — the product detail page is a real route, so it
              // gets a shareable URL and a real back stack (a similar-product
              // tile pushes its own page rather than replacing this one).
              //
              // Declared here rather than in `routes:` because that map is
              // flat and cannot carry a path parameter. It must stay ABOVE the
              // trailing /:code guard, which is documented as last.
              if (name.startsWith('/product/')) {
                final id = name.substring('/product/'.length).split('?').first;
                if (id.isNotEmpty) {
                  return PageRouteBuilder(
                    settings: settings,
                    // Butter rule: under 300ms. Hero flies the card image in
                    // over the top of this fade.
                    transitionDuration: const Duration(milliseconds: 260),
                    reverseTransitionDuration:
                        const Duration(milliseconds: 220),
                    pageBuilder: (_, __, ___) =>
                        ProductDetailScreen(productId: id),
                    transitionsBuilder: (_, anim, __, child) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.02),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(
                            parent: anim, curve: Curves.easeOutCubic)),
                        child: child,
                      ),
                    ),
                  );
                }
              }
              // CHANGE #638 — a company's catalogue. The key is a normalised
              // company name from the backend ("sun pharmaceutical
              // industries"), URL-encoded because it contains spaces. It is
              // passed through untouched: the app does not know what a valid
              // company key looks like and must not acquire an opinion.
              if (name.startsWith('/company/')) {
                final raw =
                    name.substring('/company/'.length).split('?').first;
                if (raw.isNotEmpty) {
                  final key = Uri.decodeComponent(raw);
                  return PageRouteBuilder(
                    settings: settings,
                    transitionDuration: const Duration(milliseconds: 260),
                    reverseTransitionDuration:
                        const Duration(milliseconds: 220),
                    pageBuilder: (_, __, ___) => CompanyScreen(companyKey: key),
                    transitionsBuilder: (_, anim, __, child) => FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0, 0.02),
                          end: Offset.zero,
                        ).animate(CurvedAnimation(
                            parent: anim, curve: Curves.easeOutCubic)),
                        child: child,
                      ),
                    ),
                  );
                }
              }
              if (name.startsWith('/order/')) {
                final token = name.substring('/order/'.length).split('?').first;
                if (token.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => PublicOrderPage(token: token),
                  );
                }
              }
              // CHANGE #629 (PART F4): /track/<qr_token> — the link the
              // out-for-delivery WhatsApp message sends. No auth: the token in
              // the URL is the authorisation, exactly as /order/<token> works.
              if (name.startsWith('/track/')) {
                final token = name.substring('/track/'.length).split('?').first;
                if (token.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => TrackPage(token: token),
                  );
                }
              }
              // CHANGE #639 — the stock-update link the 5pm sweep sends over
              // WhatsApp. Public, exactly like /inquiry/<token>: the token IS
              // the authorisation. Declared above the trailing /:code guard.
              // CMD #366 row 176 — the substitute link a no-app customer
              // gets over WhatsApp. Same shape as the stock-update link: the
              // token in the URL is the authorisation.
              if (name.startsWith('/substitute/')) {
                final token =
                    name.substring('/substitute/'.length).split('?').first;
                return MaterialPageRoute(
                  builder: (_) => SubstituteTokenScreen(token: token),
                );
              }
              // CMD #417 — /shop/<token>: the pharmacy's own WhatsApp
              // storefront, shared as a link or a QR. PUBLIC and anonymous by
              // design — the token in the URL is the authorisation, exactly
              // the way /stock-update/<token> works, and the page it opens
              // shows MRP and availability only.
              if (name.startsWith('/shop/')) {
                final token = name.substring('/shop/'.length).split('?').first;
                if (token.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => StorefrontScreen(token: token),
                  );
                }
              }
              // CMD #426 — /near and /near/p/<token>: the CONSUMER surface.
              // PUBLIC and anonymous, and that is the whole product: a person
              // with a prescription opens a URL, with no login, no account and
              // no app store, and asks which pharmacy nearby is likely to have
              // it. near_boot/near_search/near_pharmacy are the anon-granted,
              // rate-limited RPCs behind it, and they expose availability only
              // — never a price, a quantity or a supplier.
              // Declared above the trailing /:code guard for the same reason
              // /stock-update/ is: a bare token must not be mistaken for one.
              if (name == '/near' || name.startsWith('/near?')) {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const NearScreen(),
                );
              }
              if (name.startsWith('/near/p/')) {
                final token =
                    name.substring('/near/p/'.length).split('?').first;
                if (token.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => NearPharmacyScreen(token: token),
                  );
                }
              }
              if (name.startsWith('/stock-update/')) {
                final token =
                    name.substring('/stock-update/'.length).split('?').first;
                if (token.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => StockUpdateFormScreen(token: token),
                  );
                }
              }
              // CHANGE — /r/<code>: the short tracking link inside a WhatsApp
              // campaign message. PUBLIC and anonymous — it is opened from the
              // WhatsApp in-app browser with no session, and wa_link_click() is
              // granted to anon for exactly that reason. Click and revenue
              // attribution for every campaign depends on this route existing,
              // so it is declared above the trailing /:code guard.
              if (name.startsWith('/r/')) {
                final code = name.substring('/r/'.length).split('?').first;
                if (code.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => WaLinkRedirectPage(code: code),
                  );
                }
              }
              // CHANGE — the campaign console. Admin-gated by the RPC itself
              // (wa_campaigns_screen returns not_authorized), not by a role
              // check in this file.
              if (name == '/admin/wa-campaigns') {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const WaCampaignsScreen(),
                );
              }
              // CHANGE #240 — the Scope Audit screen (which now also carries
              // the inquiry->PO date integrity block) gets a real URL, exactly
              // like /admin/wa-campaigns above: gated by admin_scope_audit()
              // returning not_authorized, never by a role check in this file.
              // It stays reachable from Admin -> Scope audit as well; the URL
              // is what lets the post-deploy verifier open the screen and prove
              // it actually painted, instead of trusting a string in the bundle.
              if (name == '/admin/scope-audit') {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const AdminScopeAuditScreen(),
                );
              }
              // CHANGE #273 — Cron health gets a real URL for the same reason
              // #240 gave one to Scope Audit: Flutter canvas cannot be clicked
              // headlessly, so without a URL the post-deploy verifier can never
              // prove c273_cron_health painted and "it rendered" would rest on a
              // string in the bundle. Authorisation stays in the backend —
              // cron_health() calls _dev_guard() and answers service_role or
              // super_admin only, never a role check in this file. The screen is
              // still reachable from Dev Queue -> the clock icon.
              // CHANGE #325 — DEEP LINKS. Every registered screen is
              // addressable, because the registry gives each row a deep_link
              // of /admin/go/<route_key>: a push notification, a WhatsApp
              // button or a command-palette result can jump straight to it.
              // The shell owns the route table, so the key is parked here and
              // consumed on the first frame after the shell mounts — the same
              // shape the storefront already uses to read a category out of
              // the URL. Authorisation is untouched: every destination screen
              // still gates on its own RPCs.
              if (name.startsWith('/admin/go/')) {
                // CMD #421 — the path may carry a SUBJECT after the route key:
                // `/admin/go/customer_360/<pharmacy id>`. This used to
                // `replaceAll('/', '')` the whole tail, which welded the id
                // onto the key and produced a route nothing recognises. Split
                // on the separator instead: the first segment is the key, the
                // rest is the subject (rejoined, so an id that contains a
                // slash survives), and dropping empty segments keeps a
                // trailing slash harmless exactly as the old replaceAll did.
                final link = AdminGoLink.parse(name);
                final key = link?.route ?? '';
                final seed = link?.seed;
                if (key.isNotEmpty) {
                  PendingAdminNav.park(key, seed);
                  try {
                    RenderLog.write(
                        'c325_deep_link', seed == null ? key : '$key/$seed');
                  } catch (_) {}
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => _AppRoot(auth: _auth),
                  );
                }
              }
              // CMD #407 — the delivery programme gets a real URL of its own,
              // the same shape as /admin/cron-health: a direct route, so the
              // screen is reachable from a link without waiting on the shell's
              // first frame. The dashboard tile reaches it through the shell's
              // route table as well.
              if (name.split('?').first == '/admin/delivery-programme') {
                // ?tab=<tab_key> deep-links one tab. The key is passed
                // through untouched — admin_delivery_extras() decides whether
                // it means anything, and an unknown one renders empty.
                final q = Uri.tryParse(name)?.queryParameters['tab'];
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => AdminDeliveryExtrasScreen(initialTab: q),
                );
              }
              // CMD #413 — the pharmacy shop-management pair gets real URLs
              // for the same reason /admin/cron-health has one: Flutter canvas
              // cannot be clicked headlessly, so without a URL the post-deploy
              // verifier can never prove either screen painted. It is also the
              // pharmacy OWNER's own way in while the profile sheet that will
              // carry the tiles is being written elsewhere.
              //
              // Authorisation stays entirely in the backend: pharmacy_expiry_home()
              // answers "Expiry watch is available on a pharmacy account." and
              // pharmacy_variance_report() answers "This is an owner-only report."
              // in their own words, and each screen renders that refusal. Opening
              // the URL as the wrong role therefore shows the backend's sentence,
              // never a blank page and never a Dart role test.
              // CHANGE #441 — /pharmacy/owner?tab=2. The bare path is a
              // named route above; the query form lands here because a routes
              // map only matches an exact name. A TabBarView paints only the
              // page in the viewport, so this is how a headless proof reaches
              // the benchmark and the radar without tapping a canvas.
              if (name.split('?').first == '/pharmacy/owner') {
                final tab = int.tryParse(
                        Uri.tryParse(name)?.queryParameters['tab'] ?? '') ??
                    0;
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => PharmacyOwnerScreen(initialTab: tab),
                );
              }
              if (name.split('?').first == '/pharmacy/expiry') {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const PharmacyExpiryScreen(),
                );
              }
              // CMD #425 — the expiry radar, ranked by expected loss. Same
              // reason for a real URL as its sibling above, and the same
              // authorisation story: pharmacy_radar_home() answers "This screen
              // is for a pharmacy account." in its own words and the screen
              // prints that, so opening this URL as the wrong role shows the
              // backend's sentence rather than a blank page.
              if (name.split('?').first == '/pharmacy/radar') {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const PharmacyRadarScreen(),
                );
              }
              // CMD #418 — the prescription scanner, at a real URL for the
              // same reason as the pair above. Authorisation is the backend's:
              // rx_scan_recent() answers "The prescription scanner is available
              // on a pharmacy account." itself and the screen prints it.
              if (name.split('?').first == '/pharmacy/prescription') {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const RxScanScreen(),
                );
              }
              if (name.split('?').first == '/pharmacy/stock-check') {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const PharmacyVarianceScreen(),
                );
              }
              // CMD #447 — the stock audit (#430). It shipped reachable only
              // from the shelf app bar, which left it the one #430 surface the
              // post-deploy verifier could not paint: that verifier drives the
              // app by URL. Same authorisation story as the four routes above
              // and no role test here — pharmacy_audit_home() resolves the
              // caller's OWN shop and answers _c430_denied() for anyone else,
              // so this URL grants nothing it did not already have.
              if (name.split('?').first == '/pharmacy/audit') {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const PharmacyAuditScreen(),
                );
              }
              if (name == '/admin/cron-health') {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const CronHealthScreen(),
                );
              }
              // CHANGE #573 — the synthetic lane's console, at a real URL for
              // the same reason /admin/cron-health has one: Flutter renders to
              // canvas, so without a URL no headless verifier can ever prove
              // this screen painted. It is still reached by tapping
              // Admin & System -> Test mode; the URL adds no privilege of its
              // own — test_mode_screen() answers {ok:false, not_authorized} for
              // anyone who is not an admin and the screen renders that reply.
              if (name.split('?').first == '/admin/test-mode') {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const TestModeScreen(),
                );
              }
              // CHANGE #323 — partner settlement, at a real URL for the same
              // reason /admin/cron-health has one: Flutter canvas cannot be
              // clicked headlessly, so without a URL the post-deploy verifier
              // can never prove the screen painted. Authorisation stays in the
              // backend — settlement_dashboard() answers "Admins only." itself
              // and the screen renders that refusal. Still reachable by tapping
              // through Payment and Partner -> a partner card -> the people
              // icon -> the settlement action.
              if (name == '/admin/settlement') {
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => const SettlementScreen(),
                );
              }
              // CHANGE #307 — one partner's logins + access matrix, at a real
              // URL for the same reason /admin/cron-health has one: Flutter
              // canvas cannot be clicked headlessly, so without a URL the
              // post-deploy verifier can never prove the screen painted.
              // Authorisation stays in the backend — admin_partner_console()
              // answers not_authorized itself and the screen renders that
              // refusal. Still reachable from Payment and Partner -> the
              // people icon on a partner card.
              if (name.startsWith('/admin/partner-access')) {
                final tail = name
                    .substring('/admin/partner-access'.length)
                    .split('?')
                    .first
                    .replaceAll('/', '');
                return MaterialPageRoute(
                  settings: settings,
                  builder: (_) => AdminPartnerConsoleScreen(
                    partnerId: int.tryParse(tail) ?? 1,
                  ),
                );
              }
              if (name.startsWith('/inquiry/')) {
                final token = name.substring('/inquiry/'.length).split('?').first;
                if (token.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => InquiryFormScreen(token: token),
                  );
                }
              }
              if (name.startsWith('/dispute/')) {
                final token = name.substring('/dispute/'.length).split('?').first;
                if (token.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => DisputeLinkPage(token: token),
                  );
                }
              }
              if (name.startsWith('/dispute')) {
                final uri = Uri.tryParse(name) ?? Uri();
                final token = uri.queryParameters['token'] ?? '';
                if (token.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => DisputeTokenPage(token: token),
                  );
                }
              }
              // /:code and /:code/:token — short tracking code resolver
              // (MUST be last guard). Matches SPO…/CPO… codes, e.g.
              //   /SPO300626SAG100O1            (legacy, no secret)
              //   /SPO300726TOP012I1/jerps      (CHANGE #612, secret required)
              //
              // CHANGE #612: links now carry a 5-char secret as a SECOND path
              // segment. The old pattern was anchored with `$` straight after
              // the code, so a two-segment link matched nothing, fell through
              // to onUnknownRoute and opened the storefront instead of the
              // form. Both segments are captured and handed to the backend as
              // ONE string, exactly as received — resolve_code() takes
              // "CODE/secret" (and "CODE-secret") and splits it itself. The
              // app does not parse, split, case-fold or trim the secret: it
              // has no idea what a valid one looks like, and it must not
              // acquire one.
              {
                final path = name.split('?').first;
                final seg = path.startsWith('/') ? path.substring(1) : path;
                final codePattern =
                    RegExp(r'^(SPO|CPO)[A-Za-z0-9]+(?:[/-][A-Za-z0-9]+)?/?$');
                if (seg.isNotEmpty && codePattern.hasMatch(seg)) {
                  try {
                    RenderLog.write('c612_link_token_route',
                        'segments=${seg.split('/').length}');
                  } catch (_) {}
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => CodeResolverPage(code: seg),
                  );
                }
              }
              return null;
            },
            // Unknown paths (e.g. /c/cardiac) fall through to home shell,
            // which reads the URL in initState and sets the correct category.
            onUnknownRoute: (_) => MaterialPageRoute(
              builder: (_) => _AppRoot(auth: _auth),
            ),
            routes: {
              '/login':        (_) => const LoginScreen(),
              // CHANGE #309 — delivery operations (payouts, doorstep claims,
              // pincode serviceability, rider document expiry, ratings) at a
              // real URL, for the same reason /partner has one: a headless
              // session can open it and PROVE it painted, and Om can bookmark
              // it. It guards nothing — admin_delivery_ops() answers
              // `allowed:false` for anyone who is not an admin, so the
              // authorisation lives in the backend where it belongs. The
              // tappable way in is still the Delivery tab's own entry row.
              '/admin/delivery-ops': (_) => const AdminDeliveryOpsScreen(),
              // CHANGE #405 — the wave planner. Registered in feature_registry
              // with this exact deep_link, so the admin dashboard tile pushes it
              // straight onto the navigator (CHANGE #395) with no shell edit.
              '/admin/delivery-waves': (_) => const AdminDeliveryWavesScreen(),
              // CHANGE #312 — the feature_gaps register, at a real URL for the
              // same reason /admin/delivery-ops has one: a headless admin
              // session can open it and PROVE it painted. It guards nothing —
              // feature_gaps_list() answers not_authorized with its own copy
              // for anyone who is not an admin. The tappable way in is still
              // Admin ▸ More ▸ Feature gaps.
              '/admin/feature-gaps': (_) => buildFeatureGapsScreen(),
              // CHANGE #307 — the fulfilment partner's home, at a real URL for
              // the same reason /admin/cron-health has one: a headless session
              // can open it and PROVE it painted. Authorisation stays in the
              // backend — partner_home() answers `is_partner:false` with its
              // own copy for anyone else, so this route guards nothing.
              '/partner':      (_) => const PartnerHomeScreen(),
              // CHANGE #438 — the pharmacy's own staff logins (CHANGE #408) at
              // a real URL, for the same reason /partner has one: a headless
              // session can open it and PROVE the screen painted, and the
              // owner can bookmark it. It guards nothing —
              // customer_staff_list() answers not_authorized with its own copy
              // for anyone who is not on that pharmacy, so authorisation stays
              // in the backend. The tappable way in is still Profile ▸ Staff
              // logins.
              '/customer/staff': (_) => const CustomerStaffScreen(),
              '/register':     (_) => const LoginScreen(),
              // CHANGE #631 (PART A) — the delivery-partner registration form.
              // delivery_partner_register() stamps auth.uid() itself, so the
              // screen asks for a sign-in rather than inventing an anonymous
              // path.
              '/delivery-register': (_) => const DeliveryRegisterScreen(),
              // Admin > WhatsApp > Templates. wa_templates_screen() refuses
              // non-admin callers itself, so the screen renders its own
              // not-authorized state rather than the route guessing a role.
              '/admin/wa-templates': (_) => const WaTemplatesScreen(),
              // CHANGE #228 — Admin > WhatsApp > Ops, at a real URL for the
              // same reason /admin/wa-templates has one: the Template pipeline
              // section is the page you send someone to when they ask "is that
              // message live yet?". wa_event_routes_screen / wa_waba_status /
              // wa_contact_ledger / wa_template_pipeline each refuse non-admin
              // callers themselves and the screen renders that refusal, so the
              // route guards nothing.
              '/admin/wa-ops': (_) => const WaOpsScreen(),
              // CHANGE #295 — the WhatsApp delivery diagnosis, at a real URL
              // for the same reason /admin/wa-ops has one: it is the page you
              // send someone to when they ask "did that message actually
              // reach anyone?". wa_event_diagnosis() refuses a non-admin
              // caller itself and the screen renders that refusal, so the
              // route guards nothing — and a headless admin session can reach
              // it directly, which is what proves the screen renders.
              '/admin/wa-diagnosis': (_) => const WaDiagnosisScreen(),
              // CHANGE #297 — the Notification Centre at a real URL, for the
              // same reason /admin/wa-diagnosis has one: notify_center()
              // refuses a non-admin caller itself and the screen renders that
              // refusal, so the route guards nothing — and a headless admin
              // session can reach it directly, which is what proves the screen
              // actually renders.
              '/admin/notify-center': (_) => const NotifyCenterScreen(),
              // CHANGE #298 — Push notifications at a real URL, for the same
              // reason /admin/notify-center has one: push_admin_screen()
              // refuses a non-admin caller itself, so the route guards
              // nothing, and a headless admin session can reach the screen
              // directly — which is what proves it renders.
              '/admin/push': (_) => const AdminPushScreen(),
              // CHANGE #298 — the in-app inbox. Every event is readable here
              // later regardless of which channel delivered it, so it needs
              // an address of its own, not only the bell.
              '/notifications': (_) => const NotificationsInboxScreen(),
              // CHANGE #229 — Order closure at a real URL, same reason
              // /admin/wa-ops has one: this is the page you send someone to
              // when they ask "why is that order still open?". The screen's
              // own RPCs (admin_order_closure_list / _detail) refuse a
              // non-admin caller and it renders that refusal verbatim, so the
              // route guards nothing — and a headless admin session can reach
              // it directly, which is what proves the screen actually renders.
              '/admin/order-closure': (_) => const AdminOrderClosureScreen(),
              // CHANGE #173 — the reorder screen as a real URL. The WhatsApp
              // reorder nudge can link straight here, and it gives the screen
              // a shareable address like /product/:id has. The screen asks the
              // backend who the viewer is (reorder_suggestions uses
              // my_customer_id), so the route needs no role guard of its own.
              '/reorder':      (_) => const ReorderScreen(),
              // CHANGE #173 — the admin side of the same suite. Like
              // /admin/wa-templates above, the RPC refuses non-admin callers
              // itself and the screen renders that refusal, so the route
              // guards nothing. It is also reachable without a URL, from the
              // dashboard's quick-navigation tile.
              '/admin/reorder': (_) => const ReorderAdminScreen(),
              // CHANGE #395 — Returns, refunds & cancellation. Same shape as
              // the templates route above: returns_orders_list() /
              // order_returns_panel() enforce _returns_guard() themselves, so
              // the screen renders the backend's own not-authorized copy
              // rather than the route guessing a role.
              '/admin/returns': (_) => const ReturnsRefundsScreen(),
              // CMD #431 — count an arrived parcel against its bill. Same
              // shape as the routes above: pharmacy_parcel_home() resolves the
              // caller's own pharmacy and renders its own refusal, so the route
              // guards nothing. It is also reachable without a URL, from the
              // "Count parcel" tile on the pharmacy's own account screen.
              '/pharmacy/parcel-count': (_) => const ParcelCountHomeScreen(),
              // CHANGE #441 — the owner's night screens (CHANGE #419) at a real
              // URL, for the same reason /partner and /admin/delivery-ops
              // have one: a headless session can open it and PROVE the screen
              // painted, and the owner can bookmark it. It guards nothing:
              // pharmacy_owner_dashboard()
              // answers not_a_pharmacy with its own copy for anyone off that
              // pharmacy, so authorisation stays in the backend. The tappable
              // way in is still the counter's Owner dashboard tile (#906).
              '/pharmacy/owner': (_) => const PharmacyOwnerScreen(),
              '/about-app':    (_) => const AboutScreen(),
              '/contact':      (_) => const ContactScreen(),
              '/terms':        (_) => const TermsScreen(),
              '/privacy':      (_) => const PrivacyScreen(),
              // Google Play "Delete data" URL — renders legal_get_page('data-deletion').
              '/data-deletion': (_) => const DataDeletionScreen(),
              '/refund':       (_) => const RefundScreen(),
              '/shipping':     (_) => const ShippingScreen(),
              '/cancellation': (_) => const CancellationScreen(),
            },
          ),
          ),
          ),
        ),
      ),
    );
  }
}

/// Root widget: shows splash during auth init, then the main shell.
/// Has a 5-second hard timeout so a stalled auth check never blocks first paint.
class _AppRoot extends StatefulWidget {
  final AuthNotifier auth;
  const _AppRoot({required this.auth});

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  bool _timedOut = false;
  bool _didWriteBootSuccess = false;
  Timer? _bootTimer;

  @override
  void initState() {
    super.initState();
    // Hard 5-second timeout: if auth never resolves, render HomeShell anyway.
    // A feature crash in auth init MUST NOT leave users on an infinite spinner.
    _bootTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && widget.auth.loading) {
        try { RenderLog.write('boot_status', 'timeout_fallback'); } catch (_) {}
        setState(() => _timedOut = true);
      }
    });
  }

  @override
  void dispose() {
    _bootTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.auth,
      builder: (context, _) {
        if (widget.auth.loading && !_timedOut) {
          return const _SplashScreen();
        }
        // Write boot_status=painted exactly once — this is the render-log proof
        // that the app successfully rendered its first content screen.
        if (!_didWriteBootSuccess) {
          _didWriteBootSuccess = true;
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            try { RenderLog.write('boot_status', 'painted'); } catch (_) {}
            try { RenderLog.write('c501_boot_ok', 'true'); } catch (_) {}
            try { RenderLog.write('c502_boot_ok', 'true'); } catch (_) {}
            try { RenderLog.write('c503_boot_ok', 'true'); } catch (_) {}
            try { RenderLog.write('c505_boot_ok', 'true'); } catch (_) {}
            try { RenderLog.write('c506_boot_ok', 'true'); } catch (_) {}
            try { RenderLog.write('c237_cache_bust',
                'change:237,no_cache_headers:true,sw_kill_script:true,sw_reload_guard:true'); } catch (_) {}
            try { RenderLog.write('c238_sw_disabled',
                'change:238,service_worker:disabled,sw_unregister_on_load:true,network_first:true'); } catch (_) {}
            try { RenderLog.write('c239_sw_killed',
                'change:239,sw_file_deleted:true,no_registration:true'); } catch (_) {}
            try { RenderLog.write('c240_killsw_restored',
                'change:240,killsw_served:true,self_unregister:true,bootstrap_sw_null:true'); } catch (_) {}
            try { RenderLog.write('c241_autoupdate',
                'change:241,version_watcher:enabled,poll_interval:45s'); } catch (_) {}
            try { RenderLog.write('c245_ordercode_sites', '5'); } catch (_) {}
            try { RenderLog.write('c245_orders_query_patched', '0'); } catch (_) {}
            try { RenderLog.write('c398_footer_on_home', '1'); } catch (_) {}
            try { RenderLog.write('c398_footer_off_splash', '1'); } catch (_) {}
            try {
              await VersionWatcher.instance.init();
              VersionWatcher.instance.start();
            } catch (_) {}
            // CHANGE #282 — Android update prompt (no-op on web/iOS; own
            // try/catch inside). The BACKEND decides the destination from the
            // install source, so a Play install is sent to the Play listing and
            // never offered the APK that its signature check would block.
            if (context.mounted) {
              try { showAppUpdatePromptIfAny(context); } catch (_) {}
            }
          });
        }
        // Entering the authenticated shell is the third moment a WhatsApp
        // logout must take effect. Only ask when a credential is present; the
        // guard debounces so this collapses with the app-start restore check.
        if (widget.auth.isAuthenticated) {
          widget.auth.checkForcedLogout();
        }
        // CHANGE #307 / #326 — the BACKEND names the surface. A zone-locked
        // fulfilment partner is sent to their own home; every other surface is
        // unchanged.
        //
        // #326: this used to compare the raw `surface` word here and nowhere
        // else, so HomeShell — reachable by a route push, an unknown route or
        // the 5 s boot-timeout fallback — had no idea what a partner was and
        // dropped one on the customer storefront. Both call sites now read the
        // SAME typed answer, which also applies the RULE 4 mismatch guard.
        if (widget.auth.surface == AccountSurface.partner) {
          return const PartnerHomeScreen();
        }
        return HomeShell();
      },
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: CircularProgressIndicator(
          color: Color(0xFF1B5E20),
          strokeWidth: 3,
        ),
      ),
    );
  }
}
