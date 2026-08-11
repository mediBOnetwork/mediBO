import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// versionCode of THIS build. MUST stay in lockstep with
/// android/app/build.gradle.kts (`versionCode = 16`). The backend compares its
/// latest published version_code against this to decide if an update exists.
const int kAndroidVersionCode = 16;

/// Injectable seams for the widget test (no network, no home_shell import).
typedef UpdateRpc = Future<Map<String, dynamic>?> Function();
typedef UrlOpener = Future<void> Function(String url);

bool _runningOnAndroid() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Android-only "is there a newer APK?" check, called once on app start.
///
/// Contract (backend `app_update_check`):
///   { update_available, version_name, version_code, apk_url, mandatory,
///     title, message, action_label, dismiss_label }
///
/// Behaviour:
///  • Not Android (web/iOS)      → returns immediately, RPC never called.
///  • Any error / null response  → does nothing at all (no dialog).
///  • update_available != true   → no dialog.
///  • update_available == true   → dialog with title / message / action_label;
///                                 tapping the action opens apk_url.
///  • mandatory == true          → no dismiss control and the dialog cannot be
///                                 dismissed (barrier + back both blocked).
///  • dismiss_label == null      → no dismiss control (even when not mandatory).
Future<void> checkAndroidUpdate(
  BuildContext context, {
  bool? isAndroidOverride,
  UpdateRpc? rpcOverride,
  UrlOpener? openUrlOverride,
}) async {
  final isAndroid = isAndroidOverride ?? _runningOnAndroid();
  if (!isAndroid) return; // web / iOS: never call the RPC, never show anything

  Map<String, dynamic>? res;
  try {
    res = rpcOverride != null ? await rpcOverride() : await _defaultRpc();
  } catch (_) {
    return; // any error → do nothing at all
  }
  if (res == null) return;
  if (res['update_available'] != true) return;
  if (!context.mounted) return;

  final title = (res['title'] as String?) ?? '';
  final message = (res['message'] as String?) ?? '';
  final actionLabel = (res['action_label'] as String?) ?? '';
  final dismissLabel = res['dismiss_label'] as String?;
  final mandatory = res['mandatory'] == true;
  final apkUrl = (res['apk_url'] as String?) ?? '';
  final opener = openUrlOverride ?? _defaultOpen;

  await showDialog<void>(
    context: context,
    barrierDismissible: !mandatory,
    builder: (ctx) => PopScope(
      // Mandatory update: Android back gesture must not close the dialog.
      canPop: !mandatory,
      child: AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          // Dismiss only when allowed AND the backend supplied a label.
          if (!mandatory && dismissLabel != null)
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(dismissLabel),
            ),
          TextButton(
            onPressed: () {
              opener(apkUrl);
            },
            child: Text(actionLabel),
          ),
        ],
      ),
    ),
  );
}

Future<Map<String, dynamic>?> _defaultRpc() async {
  final res = await Supabase.instance.client.rpc(
    'app_update_check',
    params: {'p_platform': 'android', 'p_version_code': kAndroidVersionCode},
  );
  if (res is Map) return Map<String, dynamic>.from(res);
  return null;
}

Future<void> _defaultOpen(String url) async {
  if (url.isEmpty) return;
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {/* nothing more we can do */}
}
