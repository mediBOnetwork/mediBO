import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';
import 'utils/render_log.dart';
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

  @override
  void dispose() {
    _cart.dispose();
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return UserState(
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
