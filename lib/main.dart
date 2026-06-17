import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';
import 'utils/render_log.dart';
import 'view_as_state.dart';
import 'models/cart_model.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_shell.dart';
import 'screens/public/inquiry_form_screen.dart';
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

    usePathUrlStrategy();

    // Supabase init is crash-isolated: failure renders app in signed-out state.
    try {
      await Supabase.initialize(
        url: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        authOptions: const FlutterAuthClientOptions(
          authFlowType: AuthFlowType.implicit,
          autoRefreshToken: true,
          detectSessionInUri: true,
        ),
      );
    } catch (e) {
      try { RenderLog.write('boot_error', 'supabase_init_failed'); } catch (_) {}
    }

    try {
      final raw = await html.HttpRequest.getString('/version.json');
      final info = jsonDecode(raw) as Map<String, dynamic>;
      RenderLog.setBuildHash(info['commit'] as String? ?? 'unknown');
    } catch (_) {
      RenderLog.setBuildHash('unknown');
    }
    RenderLog.write('screen', 'boot');

    // Session recovery moved to AuthNotifier._onAuthChange(initialSession):
    // it fires after SDK restore attempt and retries if lskeys found but session null.

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
          child: MaterialApp(
            title: 'mediBO',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            scrollBehavior: const SmoothScrollBehavior(),
            // Belt-and-suspenders: clear any stray text decoration on Flutter web.
            builder: (context, child) => DefaultTextStyle.merge(
              style: const TextStyle(decoration: TextDecoration.none, decorationColor: Color(0x00000000)),
              child: child!,
            ),
            home: _AppRoot(auth: _auth),
            // Public inquiry form — no auth required, handles /inquiry/<token>
            onGenerateRoute: (settings) {
              final name = settings.name ?? '';
              if (name.startsWith('/inquiry/')) {
                final token = name.substring('/inquiry/'.length).split('?').first;
                if (token.isNotEmpty) {
                  return MaterialPageRoute(
                    settings: settings,
                    builder: (_) => InquiryFormScreen(token: token),
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
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try { RenderLog.write('boot_status', 'painted'); } catch (_) {}
          });
        }
        return const HomeShell();
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
