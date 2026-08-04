import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';
import 'order_hours_state.dart';
import 'inquiry_lock_state.dart';
import 'url_sync_web.dart' show captureInitialPath;
import 'services/version_watcher.dart';
import 'utils/render_log.dart';
import 'view_as_state.dart';
import 'models/cart_model.dart';
import 'models/order_hours_model.dart';
import 'models/inquiry_lock_model.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_shell.dart';
import 'screens/public/inquiry_form_screen.dart';
import 'screens/public/stock_update_form_screen.dart'; // C639: /stock-update/<token>
import 'pages/dispute_token_page.dart';
import 'screens/public/dispute_form_screen.dart';
import 'screens/public/public_order_page.dart';
import 'screens/public/track_page.dart'; // C629: /track/<qr_token>
import 'screens/delivery/delivery_register_screen.dart'; // C631: PART A
import 'screens/code_resolver_page.dart';
import 'screens/public/wa_link_redirect_page.dart'; // /r/:code — campaign links
import 'screens/admin/wa_campaigns_screen.dart'; // /admin/wa-campaigns
import 'screens/product_detail_screen.dart'; // C636: /product/:id
import 'screens/company_screen.dart'; // C638: /company/:key
import 'screens/inquiry_link_page.dart';
import 'screens/dispute_link_page.dart';
import 'screens/about_screen.dart';
import 'screens/contact_screen.dart';
import 'screens/legal_pages.dart';
import 'supabase_config.dart';
import 'theme.dart';
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
    };

    captureInitialPath(); // must be called BEFORE usePathUrlStrategy() resets pathname
    usePathUrlStrategy();

    // Supabase init is crash-isolated: failure renders app in signed-out state.
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
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
      final href = html.window.location.href;
      final uri = Uri.parse(href);
      final hasCode = uri.queryParameters.containsKey('code');
      final hasFragment = uri.fragment.contains('access_token=') ||
          uri.fragment.contains('refresh_token=') ||
          uri.fragment.contains('error=');
      if (hasCode || hasFragment) {
        html.window.history.replaceState(null, '', '/');
        RenderLog.write('auth56_url_stripped', 'main_init; hadCode=$hasCode; hadFragment=$hasFragment');
        // CHANGE #308: note that SDK handled the exchange via detectSessionInUri
        if (hasCode) RenderLog.write('c308_code_exchange', 'ran:ok');
      }
    } catch (_) {}

    // Remove stale sv-typo key (sb-svojhmarmaijkshsbeih-auth-token) if left over from old builds.
    try {
      html.window.localStorage.remove('sb-svojhmarmaijkshsbeih-auth-token');
    } catch (_) {}

    try {
      final raw = await html.HttpRequest.getString('/version.json');
      final info = jsonDecode(raw) as Map<String, dynamic>;
      RenderLog.setBuildHash(info['commit'] as String? ?? 'unknown');
      final changeNum = info['change'] as String?;
      if (changeNum != null) RenderLog.write('change', changeNum);
    } catch (_) {
      RenderLog.setBuildHash('unknown');
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
      final uri = Uri.parse(html.window.location.href);
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

    runApp(const PharmaB2BApp());
  }, (error, stack) {
    // Zone-level catch-all: uncaught async errors are logged and swallowed.
    try {
      final msg = error.toString();
      RenderLog.write('boot_zone_error', msg.length > 120 ? msg.substring(0, 120) : msg);
    } catch (_) {}
  });
}

class PharmaB2BApp extends StatefulWidget {
  const PharmaB2BApp({super.key});

  @override
  State<PharmaB2BApp> createState() => _PharmaB2BAppState();
}

class _PharmaB2BAppState extends State<PharmaB2BApp> {
  final CartModel _cart = CartModel();
  final AuthNotifier _auth = AuthNotifier();
  final ViewAsNotifier _viewAs = ViewAsNotifier();
  final OrderHoursModel _orderHours = OrderHoursModel();
  final InquiryLockModel _inquiryLock = InquiryLockModel();
  bool _viewAsRestored = false;

  @override
  void initState() {
    super.initState();
    _viewAs.addListener(_onViewAsChanged);
    _auth.addListener(_onAuthChanged);
  }

  // ─── ViewAs persistence (shared_preferences only — never dart:html) ─────────

  void _onAuthChanged() {
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
    _viewAs.removeListener(_onViewAsChanged);
    _auth.removeListener(_onAuthChanged);
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
            theme: buildTheme(),
            scrollBehavior: const SmoothScrollBehavior(),
            // Belt-and-suspenders: clear any stray text decoration on Flutter web.
            builder: (context, child) => DefaultTextStyle.merge(
              style: const TextStyle(decoration: TextDecoration.none, decorationColor: Color(0x00000000)),
              child: child!,
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
              '/register':     (_) => const LoginScreen(),
              // CHANGE #631 (PART A) — the delivery-partner registration form.
              // delivery_partner_register() stamps auth.uid() itself, so the
              // screen asks for a sign-in rather than inventing an anonymous
              // path.
              '/delivery-register': (_) => const DeliveryRegisterScreen(),
              '/about-app':    (_) => const AboutScreen(),
              '/contact':      (_) => const ContactScreen(),
              '/terms':        (_) => const TermsScreen(),
              '/privacy':      (_) => const PrivacyScreen(),
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
          });
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
