import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/render_log.dart';
import '../widgets/update_bar.dart';
import 'android_update_check.dart' show kAndroidVersionCode;
import 'app_update_feed.dart';
import 'play_update_channel.dart';

/// CMD #2028 — the Android half of the floating update pill.
///
/// The SAME bar the web watcher raises, driven by the SAME RPC. This service
/// only supplies the one fact the backend cannot know (the running
/// versionCode) and performs the one action a database cannot perform
/// (starting Play's in-app update flow).
///
/// Flow selection is NOT a decision made here: `app_update_bar()` returns
/// 'flexible' or 'immediate' — immediate when the running build is below the
/// minimum version in app_settings — and it is passed through untouched.
///
/// If Play cannot serve the update in-app (a sideloaded build, no Play Store,
/// an outage) the button falls back to opening the store listing, so the
/// customer is never left with a button that does nothing.
class AndroidUpdateBar with WidgetsBindingObserver {
  AndroidUpdateBar._();
  static final AndroidUpdateBar instance = AndroidUpdateBar._();

  static const Duration _fallbackInterval = Duration(minutes: 5);

  Timer? _timer;
  bool _started = false;
  Map<String, dynamic>? _payload;

  /// Start checking. No-op on web/iOS: the RPC is never called and no observer
  /// is installed.
  Future<void> start() async {
    if (_started || !AppUpdateFeed.isAndroid) return;
    _started = true;
    PlayUpdateChannel.instance
      ..onDownloaded = () {
        appUpdateBar.markDownloaded();
        try {
          RenderLog.write('c2028_play_downloaded', 1);
        } catch (_) {}
      }
      ..onFailed = appUpdateBar.markIdle
      ..listen();
    WidgetsBinding.instance.addObserver(this);
    await _check();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer.periodic(
      AppUpdateFeed.pollInterval(_payload, _fallbackInterval),
      (_) => _check(),
    );
  }

  /// Foreground: re-ask, and apply a flexible download that finished while the
  /// app was away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_onResume());
  }

  Future<void> _onResume() async {
    final play = await PlayUpdateChannel.instance.check();
    if (play['downloaded'] == true) {
      appUpdateBar.markDownloaded();
      await PlayUpdateChannel.instance.complete();
      return;
    }
    await _check();
  }

  Future<void> _check() async {
    final res = await AppUpdateFeed.fetch(
      platform: 'android',
      versionCode: kAndroidVersionCode,
    );
    if (res == null) return; // a failed check never puts a bar on screen
    _payload = res;
    if (res[AppUpdateFeed.kShow] != true) return;
    try {
      RenderLog.write('c2028_update_bar_android',
          'flow=${res[AppUpdateFeed.kFlow]};code=${res['target_code']}');
    } catch (_) {}
    appUpdateBar.show(payload: res, onUpdate: _update);
    _arm();
  }

  Future<void> _update() async {
    final flow = (_payload?[AppUpdateFeed.kFlow] as String?) ?? 'flexible';
    appUpdateBar.markUpdating();
    final ok = await PlayUpdateChannel.instance.start(flow);
    if (ok) return;
    // Play could not run the in-app flow — open the listing instead. The bar
    // stays up (the update has not happened yet) and becomes tappable again.
    appUpdateBar.markIdle();
    final url = (_payload?['action_url'] as String?) ?? '';
    if (url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {/* nothing more we can do */}
  }
}
