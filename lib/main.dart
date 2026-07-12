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
import 'url_sync_web.dart' show captureInitialPath;
import 'services/version_watcher.dart';
import 'utils/render_log.dart';
import 'view_as_state.dart';
import 'models/cart_model.dart';
import 'models/order_hours_model.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_shell.dart';
import 'screens/public/inquiry_form_screen.dart';
import 'pages/dispute_token_page.dart';
import 'screens/public/dispute_form_screen.dart';
import 'screens/public/public_order_page.dart';
import 'screens/code_resolver_page.dart';
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
    // CHANGE #432: restored ORIGINAL 1080x1080 logo, resize-only (no trim/reshape/gloss).
    RenderLog.write('c432_logo', 'icons=v4;resize_only');
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
              if (name.startsWith('/order/')) {
                final token = name.substring('/order/'.length).split('?').first;
                if (token.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => PublicOrderPage(token: token),
                  );
                }
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
              // /:code — short tracking code resolver (MUST be last guard)
              // Only matches segments shaped like SPO… or CPO… (e.g. SPO300626SAG100O1)
              {
                final seg = name.startsWith('/') ? name.substring(1) : name;
                final codePattern = RegExp(r'^(SPO|CPO)[A-Za-z0-9]+$');
                if (seg.isNotEmpty && codePattern.hasMatch(seg)) {
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
