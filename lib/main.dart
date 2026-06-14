import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';
import 'utils/render_log.dart';
import 'view_as_state.dart';
import 'models/cart_model.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_shell.dart';
import 'screens/about_screen.dart';
import 'screens/public/inquiry_form_screen.dart';
import 'screens/contact_screen.dart';
import 'screens/legal_pages.dart';
import 'supabase_config.dart';
import 'theme.dart';
import 'user_state.dart';
import 'widgets/animations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  usePathUrlStrategy(); // clean URLs — no # in the address bar
  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );

  // Boot render-log: fetch version.json (already live, ~0ms) and record build hash.
  try {
    final raw = await html.HttpRequest.getString('/version.json');
    final info = jsonDecode(raw) as Map<String, dynamic>;
    RenderLog.setBuildHash(info['commit'] as String? ?? 'unknown');
  } catch (_) {
    RenderLog.setBuildHash('unknown');
  }
  RenderLog.write('screen', 'boot');

  runApp(const PharmaB2BApp());
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
  bool _authWasLoading = true;

  @override
  void initState() {
    super.initState();
    _viewAs.addListener(_onViewAsChanged);
    _auth.addListener(_onAuthChanged);
  }

  void _onViewAsChanged() {
    if (_viewAs.isActive &&
        _viewAs.role == ViewAsRole.customer &&
        _viewAs.identity?.userId != null) {
      _cart.enterViewAs(_viewAs.identity!.userId!);
    } else {
      _cart.exitViewAs();
    }
  }

  void _onAuthChanged() {
    if (_authWasLoading && !_auth.loading) {
      _authWasLoading = false;
      if (_auth.isSuperAdmin && kEnableViewAs) {
        _tryRestoreViewAs();
      } else if (!_auth.loading) {
        // Non-super-admin (or signed out): clear any leftover descriptor so
        // a later super-admin login doesn't inherit a stale impersonation.
        ViewAsNotifier.clearPersisted();
      }
    }
  }

  Future<void> _tryRestoreViewAs() async {
    final desc = ViewAsNotifier.readPersistedDescriptor();
    if (desc == null) {
      RenderLog.write('view_as_restore', 'no_persisted');
      return;
    }
    final roleStr = desc['role'] as String?;
    final id = desc['id'] as String?;
    final name = desc['name'] as String?;
    final email = desc['email'] as String?;
    final userId = desc['userId'] as String?;
    if (roleStr == null || id == null || name == null || email == null) {
      ViewAsNotifier.clearPersisted();
      RenderLog.write('view_as_restore', 'invalid_descriptor');
      return;
    }
    ViewAsRole? role;
    try { role = ViewAsRole.values.byName(roleStr); } catch (_) {}
    if (role == null) {
      ViewAsNotifier.clearPersisted();
      RenderLog.write('view_as_restore', 'unknown_role:$roleStr');
      return;
    }
    // Validate the account still exists in DB before restoring.
    try {
      final res = await Supabase.instance.client
          .from('pharmacy_profiles')
          .select('id')
          .eq('id', id)
          .maybeSingle();
      if (res == null) {
        ViewAsNotifier.clearPersisted();
        RenderLog.write('view_as_restore', 'account_not_found:$id');
        return;
      }
    } catch (e) {
      // Network/auth error — skip restore but keep descriptor for next boot.
      RenderLog.write('view_as_restore', 'validation_error:$e');
      return;
    }
    final identity = ViewAsIdentity(id: id, name: name, email: email, userId: userId);
    _viewAs.activate(role, identity);
    RenderLog.write('view_as_restore', '${role.name}:$id:$name');
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
              '/about':        (_) => const AboutScreen(),
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

/// Root widget: switches between loading, business setup, and the main shell.
class _AppRoot extends StatelessWidget {
  final AuthNotifier auth;
  const _AppRoot({required this.auth});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        // Show splash only during the very first session check, not on subsequent sign-ins
        if (auth.loading) {
          return const _SplashScreen();
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
