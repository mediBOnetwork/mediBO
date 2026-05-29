import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';
import 'models/cart_model.dart';
import 'screens/auth/business_details_screen.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_shell.dart';
import 'screens/legal_pages.dart';
import 'supabase_config.dart';
import 'theme.dart';
import 'user_state.dart';
import 'widgets/animations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: SupabaseConfig.url,
    anonKey: SupabaseConfig.anonKey,
  );
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
          routes: {
            '/login':        (_) => const LoginScreen(),
            '/register':     (_) => const LoginScreen(),
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
        // Show splash while checking initial session or loading profile
        if (auth.loading || auth.profileLoading) {
          return const _SplashScreen();
        }

        final user = Supabase.instance.client.auth.currentUser;

        // Authenticated but no profile → business setup (mandatory)
        if (user != null && auth.needsProfile) {
          return BusinessDetailsScreen(
            userId: user.id,
            phone: user.phone ?? '',
          );
        }

        // Guests and logged-in users both land on home — login is not required to browse
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
