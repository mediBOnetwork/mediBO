// CHANGE #282 — the in-app update prompt.
//
// Replaces the plain AlertDialog that shipped with the APK-only update check.
// Two faults were live at once:
//
//  1. It always sent the user to `apk_url` — a Supabase storage APK. mediBO is
//     on Google Play now, so a Play-installed pharmacy got Chrome's "this file
//     might be harmful" and then a signature clash (Play re-signs the upload
//     with its own app-signing key) that BLOCKS the install. Android already
//     knows where the app came from; the app reports that VERBATIM and the
//     BACKEND decides the destination. A Play install is never even sent the
//     APK string — `apk_url` is absent from its payload.
//
//  2. It printed `app_releases.notes` — the internal changelog. Om watched a
//     pharmacy being told about "the exact signing certificate this build
//     carries and the client id it sent". The backend now renders
//     `public_notes` (or its own fallback copy) and never the internal text.
//
// Everything visible here — eyebrow, title, body, both button labels, the
// version line — arrives in the payload. This file positions and paints; it
// coins no sentence and picks no destination. Rewording the prompt is an
// UPDATE on ui_copy / app_releases.public_notes, not a deploy.
//
// Dismissal: the backend names the prompt (`dismiss_key`, e.g.
// "app_update:android:24"). "Not now" stores that key, and the prompt stays
// quiet while the backend keeps sending the same one — so it does not reappear
// on every launch. A new release sends a new key and the prompt returns by
// itself. When the update is actually installed the backend answers
// update_available:false and the stored key is dropped, so nothing lingers.

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design_tokens.dart';
import '../services/android_update_check.dart' show kAndroidVersionCode;
import '../services/signin_diag.dart';
import '../utils/render_log.dart';

/// Injectable seams for the widget test: no network, no platform channel,
/// no browser.
typedef UpdateRpc = Future<Map<String, dynamic>?> Function(String? installSource);
typedef UpdateUrlOpener = Future<void> Function(String url);

/// The one shared-preferences key. It holds the backend's `dismiss_key`, so
/// "what did the user dismiss" is the backend's own identity string, never a
/// version number this file worked out.
const String kUpdateDismissedPref = 'app_update_dismissed_key';

bool _runningOnAndroid() =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Asks the backend whether an update exists and, if so, shows the sheet.
///
/// Returns the payload it acted on (or null when it never asked / got nothing),
/// which is what the test asserts against.
Future<Map<String, dynamic>?> showAppUpdatePromptIfAny(
  BuildContext context, {
  bool? isAndroidOverride,
  UpdateRpc? rpcOverride,
  UpdateUrlOpener? openUrlOverride,
  String? installSourceOverride,
}) async {
  final isAndroid = isAndroidOverride ?? _runningOnAndroid();
  if (!isAndroid) return null; // web / iOS: never ask, never show

  Map<String, dynamic>? res;
  try {
    final source =
        installSourceOverride ?? await SignInDiag.installSource();
    res = rpcOverride != null
        ? await rpcOverride(source)
        : await _defaultRpc(source);
  } catch (_) {
    return null; // a failed update check must never be visible to the user
  }
  if (res == null) return null;

  final prefs = await _prefs();

  if (res['update_available'] != true) {
    // Right after an install this is the branch that runs: drop the dismissal
    // so a LATER release is never silenced by a key the user tapped away
    // months ago.
    await prefs?.remove(kUpdateDismissedPref);
    return res;
  }

  final dismissKey = res['dismiss_key'] as String?;
  if (dismissKey != null &&
      dismissKey.isNotEmpty &&
      prefs?.getString(kUpdateDismissedPref) == dismissKey) {
    return res; // already dismissed THIS prompt — stay quiet
  }

  if (!context.mounted) return res;

  final mandatory = res['mandatory'] == true;
  final opener = openUrlOverride ?? _defaultOpen;
  final actionUrl = (res['action_url'] as String?) ?? '';

  try {
    RenderLog.write('c282_update_prompt',
        'channel=${res['channel']};mandatory=$mandatory;apk_offered=${res['apk_url'] != null}');
  } catch (_) {}

  var dismissed = false;
  await showModalBottomSheet<void>(
    context: context,
    isDismissible: !mandatory,
    enableDrag: !mandatory,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (ctx) => AppUpdateSheet(
      payload: res!,
      onAction: () {
        Navigator.of(ctx).pop();
        opener(actionUrl);
      },
      onDismiss: () {
        dismissed = true;
        Navigator.of(ctx).pop();
      },
    ),
  );

  if (dismissed && dismissKey != null && dismissKey.isNotEmpty) {
    await prefs?.setString(kUpdateDismissedPref, dismissKey);
  }
  return res;
}

Future<SharedPreferences?> _prefs() async {
  try {
    return await SharedPreferences.getInstance();
  } catch (_) {
    return null; // storage unavailable: prompt still works, just not silenced
  }
}

Future<Map<String, dynamic>?> _defaultRpc(String? installSource) async {
  final res = await Supabase.instance.client.rpc(
    'app_update_check',
    params: {
      'p_platform': 'android',
      'p_version_code': kAndroidVersionCode,
      'p_install_source': installSource,
    },
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

/// The sheet itself. Public so the widget test can pump it directly with a
/// fixture payload.
class AppUpdateSheet extends StatelessWidget {
  final Map<String, dynamic> payload;
  final VoidCallback onAction;
  final VoidCallback onDismiss;

  const AppUpdateSheet({
    super.key,
    required this.payload,
    required this.onAction,
    required this.onDismiss,
  });

  String _s(String key) {
    final v = payload[key];
    return v is String ? v : '';
  }

  @override
  Widget build(BuildContext context) {
    final mandatory = payload['mandatory'] == true;
    final eyebrow = _s('eyebrow');
    final title = _s('title');
    final message = _s('message');
    final versionLabel = _s('version_label');
    final actionLabel = _s('action_label');
    final dismissLabel = payload['dismiss_label'] as String?;

    return PopScope(
      // A mandatory update must survive the Android back gesture too.
      canPop: !mandatory,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x24, Ds.space.x12, Ds.space.x24, Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: Ds.space.x48,
                  height: Ds.space.x4,
                  decoration: BoxDecoration(
                    color: Ds.c.divider,
                    borderRadius: BorderRadius.circular(Ds.space.x4),
                  ),
                ),
              ),
              SizedBox(height: Ds.space.x24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: Ds.touch.minTarget,
                    height: Ds.touch.minTarget,
                    decoration: BoxDecoration(
                      color: Ds.c.brandSoft,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.system_update_alt_rounded,
                        color: Ds.c.brand, size: Ds.t.subtitleSize),
                  ),
                  SizedBox(width: Ds.space.x16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (eyebrow.isNotEmpty)
                          Text(eyebrow,
                              style: Ds.t.caption.copyWith(color: Ds.c.brand)),
                        if (eyebrow.isNotEmpty) SizedBox(height: Ds.space.x4),
                        Text(title, style: Ds.t.title),
                      ],
                    ),
                  ),
                ],
              ),
              if (message.isNotEmpty) ...[
                SizedBox(height: Ds.space.x16),
                Text(message, style: Ds.t.bodySecondary),
              ],
              if (versionLabel.isNotEmpty) ...[
                SizedBox(height: Ds.space.x16),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                    color: Ds.c.brandSoft,
                    borderRadius: Ds.r.rChip,
                  ),
                  child: Text(versionLabel,
                      style: Ds.t.caption.copyWith(color: Ds.c.brand)),
                ),
              ],
              SizedBox(height: Ds.space.x24),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  foregroundColor: Ds.c.surface,
                  minimumSize: Size.fromHeight(Ds.touch.minTarget),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(actionLabel,
                    style: Ds.t.subtitle.copyWith(color: Ds.c.surface)),
              ),
              // No dismiss control on a mandatory release, and none when the
              // backend sent no label — the payload decides, not this file.
              if (!mandatory && dismissLabel != null && dismissLabel.isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                TextButton(
                  onPressed: onDismiss,
                  style: TextButton.styleFrom(
                    minimumSize: Size.fromHeight(Ds.touch.minTarget),
                    foregroundColor: Ds.c.textSecondary,
                  ),
                  child: Text(dismissLabel,
                      style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
