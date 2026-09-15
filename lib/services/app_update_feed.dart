import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:supabase_flutter/supabase_flutter.dart';

/// CMD #2028 — the one answer the update pill renders, on both platforms.
///
/// `app_update_bar()` decides EVERYTHING: whether a bar exists at all, the
/// sentence on it, the button's word, which Play flow to run, how often to
/// look again and how far off the bottom of the screen the pill floats. The
/// app contributes only facts it alone can know — the running Android
/// versionCode, and (on web) the build this tab booted on plus the build
/// version.json serves right now, because that file lives on the CDN and the
/// database cannot read it.
///
/// Nothing here compares versions. Two build strings go out, a decision comes
/// back; that is the whole contract.
class AppUpdateFeed {
  const AppUpdateFeed._();

  /// Payload keys, so the widget and the tests name them once.
  static const String kShow = 'show';
  static const String kLabel = 'label';
  static const String kButton = 'button_label';
  static const String kUpdating = 'updating_label';
  static const String kDownloaded = 'downloaded_label';
  static const String kFlow = 'flow';
  static const String kPollSeconds = 'poll_seconds';
  static const String kBottomGap = 'bottom_gap';

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Ask the backend. Returns null on ANY failure — a broken update check must
  /// never put a bar on the screen, and must never throw into a build.
  static Future<Map<String, dynamic>?> fetch({
    required String platform,
    int versionCode = 0,
    String? build,
    String? liveBuild,
  }) async {
    try {
      final res = await Supabase.instance.client.rpc(
        'app_update_bar',
        params: {
          'p_platform': platform,
          'p_version_code': versionCode,
          'p_build': build,
          'p_live_build': liveBuild,
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
}
