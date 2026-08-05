import 'package:flutter/material.dart';
import '../platform_unavailable.dart';

class AdminCustomerScreen extends StatelessWidget {
  AdminCustomerScreen({super.key});
  static void triggerFocus() {}
  static bool triggerOptimizeAllRoutes() => false;
  @override
  Widget build(BuildContext context) => const PlatformUnavailableScreen();
}
