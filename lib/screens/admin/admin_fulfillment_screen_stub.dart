import 'package:flutter/material.dart';
import 'voice_count_android.dart';

/// Non-web (Android) fulfillment surface. The full Shop/Warehouse/Pack dashboard
/// is web-only (dart:html tooling), but realtime voice counting IS available on
/// Android — so this renders the lean voice-count home instead of a dead stub.
/// Same class name + static triggerFocus() the web build exposes, so home_shell
/// is unchanged.
class AdminFulfillmentScreen extends StatelessWidget {
  const AdminFulfillmentScreen({super.key});
  static void triggerFocus() {}
  @override
  Widget build(BuildContext context) => const VoiceCountAndroidHome();
}
