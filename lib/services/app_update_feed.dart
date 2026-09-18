import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// versionCode of THIS build. MUST stay in lockstep with
/// android/app/build.gradle.kts (`versionCode = …`). It is a FACT about the
/// running binary, which is why it lives in Dart at all — the backend is told
/// it, it is never decided here.
const int kAndroidVersionCode = 51;

/// CMD #2028 → CMD #2065 — the one answer the update bar renders, on all three
/// platforms.
///
/// `app_update_check()` decides EVERYTHING: whether a bar exists at all, the
/// sentence on it, the button's word, whether it can be dismissed, which Play
/// flow to run and how often to look again. The app contributes only facts it
/// alone can know:
///
///   web      the build this tab booted on, and the build version.json serves
///            right now (that file is on the CDN; the database cannot read it)
///   pwa      whether a new service worker is sitting in `waiting`
///   android  the running versionCode, and PLAY'S OWN VERDICT
///
/// That last one is the whole of CMD #2065. Android used to be decided from
/// `app_releases` — our table — so the bar went up whenever WE thought a newer
/// build existed, including while the Play release was still in review. Play
/// had nothing to install, so Update Now did nothing. Play is asked first now,
/// and 'unknown' is never an update.
///
/// Nothing here compares versions. Facts go out, a decision comes back.
class AppUpdateFeed {
  const AppUpdateFeed._();

  /// Payload keys, so the widget, the services and the tests name them once.
  static const String kShow = 'show';
  static const String kTitle = 'title';
  static const String kCta = 'cta';
  static const String kAction = 'action';
  static const String kUpdating = 'updating_label';
  static const String kDownloaded = 'downloaded_label';
  static const String kDismissLabel = 'dismiss_label';
  static const String kDismissible = 'dismissible';
  static const String kForced = 'forced';
  static const String kFlow = 'flow';
  static const String kPollSeconds = 'poll_seconds';
  static const String kReason = 'reason';

  /// The three platform strings the backend knows. They are also the keys the
  /// 24 h dismissal is stored under — "per platform" is literally this.
  static const String pWeb = 'web';
  static const String pPwa = 'pwa';
  static const String pAndroid = 'android';

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Ask the backend. Returns null on ANY failure — a broken update check must
  /// never put a bar on the screen, and must never throw into a build.
  static Future<Map<String, dynamic>?> fetch({
    required String platform,
    String? installedVersion,
    String? liveVersion,
    String? platformState,
    String? platformVersion,
  }) async {
    try {
      final res = await Supabase.instance.client.rpc(
        'app_update_check',
        params: {
          'p_platform': platform,
          'p_installed_version': installedVersion,
          'p_live_version': liveVersion,
          'p_platform_state': platformState,
          'p_platform_version': platformVersion,
          'p_dismissed_at': (await dismissedAt(platform))?.toIso8601String(),
        },
      );
      if (res is Map) return Map<String, dynamic>.from(res);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// The backend's poll cadence, as a Duration. Never faster than 30 s, so a
  /// bad config cannot turn the app into a polling loop.
  static Duration pollInterval(Map<String, dynamic>? payload, Duration fallback) {
    final n = (payload?[kPollSeconds] as num?)?.toInt();
    if (n == null || n < 30) return fallback;
    return Duration(seconds: n);
  }

  // ── The 24 h dismissal ────────────────────────────────────────────────────
  //
  // Stored on the DEVICE because that is the only place it exists: one phone
  // tapping Later says nothing about the next one. It is a fact, not a
  // decision — how long it lasts (`dismiss_hours`), and whether a forced
  // update ignores it, are both the backend's, which is why what goes over the
  // wire is a timestamp and never a boolean.

  static String _key(String platform) => 'app_update_dismissed_$platform';

  /// Test seam — SharedPreferences has no reset of its own between tests.
  static Map<String, DateTime>? debugStore;

  static Future<DateTime?> dismissedAt(String platform) async {
    final store = debugStore;
    if (store != null) return store[platform];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(platform));
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<void> markDismissed(String platform, {DateTime? at}) async {
    final when = (at ?? DateTime.now()).toUtc();
    final store = debugStore;
    if (store != null) {
      store[platform] = when;
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(platform), when.toIso8601String());
    } catch (_) {/* a device that cannot remember simply asks again */}
  }
}
