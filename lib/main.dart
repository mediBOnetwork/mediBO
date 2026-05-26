import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';
import 'models/cart_model.dart';
import 'screens/home_shell.dart';
import 'supabase_config.dart';
import 'theme.dart';
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

  @override
  void dispose() {
    _cart.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppState(
      cart: _cart,
      child: MaterialApp(
        title: 'MediCare',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        scrollBehavior: const SmoothScrollBehavior(),
        home: const HomeShell(),
      ),
    );
  }
}
