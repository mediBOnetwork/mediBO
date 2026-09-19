import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../build_info.dart';
import '../utils/render_log.dart';
import '../widgets/update_bar.dart';
import 'app_update_feed.dart';
import 'play_update_channel.dart';

/// CMD #2028 → CMD #2065 — the Android half of the ONE update bar.
///
/// WHAT CHANGED, AND WHY IT MATTERED
/// The bar used to be raised by `app_update_bar()`, which compared the running
/// versionCode against a row in OUR database. That row moves when we publish —
/// not when Play starts serving. So during a review, or a staged rollout, or
/// any hour when our table ran ahead of the Play Store, every Android customer
/// saw "App update available" over a button that could do nothing: the in-app
/// flow has no update to start, and it returns straight away.
///
/// Play is now asked FIRST — on launch and on every resume — and the bar goes
/// up only for `UPDATE_AVAILABLE`. Anything else (in review, already current,
/// sideloaded, no Play Store, Play unreachable) shows no bar at all. The RPC is
/// still what decides and still what writes every word; this service only
/// carries Play's verdict to it.
class AndroidUpdateBar with WidgetsBindingObserver {
  AndroidUpdateBar._();
  static final AndroidUpdateBar instance = AndroidUpdateBar._();

  static const Duration _fallbackInterval = Duration(minutes: 5);

  Timer? _timer;
  bool _started = false;
  Map<String, dynamic>? _payload;

  /// Start checking. No-op on web/iOS: neither Play nor the RPC is asked and
  /// no observer is installed.
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

  /// Foreground: ask Play again, and apply a flexible download that finished
  /// while the app was away.
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

  /// CMD #2065 — Play's word, then the backend's words.
  ///
  /// `state` is reported verbatim and nothing here acts on it: 'none' and
  /// 'unknown' are two different facts, and which of them is an update is the
  /// backend's call, not this file's.
  Future<void> _check() async {
    final play = await PlayUpdateChannel.instance.check();
    final state = playState(play);
    final res = await AppUpdateFeed.fetch(
      platform: AppUpdateFeed.pAndroid,
      // CMD #2100 — each flavor reports ITS versionCode; the backend names the
      // matching release (platform 'android' or 'android_partner').
      installedVersion:
          '${isPartnerFlavor ? kPartnerAndroidVersionCode : kAndroidVersionCode}',
      platformState: state,
      platformVersion: play['versionCode']?.toString(),
    );
    if (res == null) return; // a failed check never puts a bar on screen
    _payload = res;
    try {
      RenderLog.write('c2065_android_play_state',
          'play=$state;show=${res[AppUpdateFeed.kShow]};reason=${res[AppUpdateFeed.kReason]}');
    } catch (_) {}
    if (res[AppUpdateFeed.kShow] != true) {
      _arm();
      return;
    }
    try {
      RenderLog.write('c2028_update_bar_android',
          'flow=${res[AppUpdateFeed.kFlow]};target=${res['target_version']}');
    } catch (_) {}
    appUpdateBar.show(
      payload: res,
      onUpdate: _update,
      onDismiss: () => _dismiss(),
    );
    _arm();
  }

  /// Play's answer, as the one word the backend reads. Pure, so the protected
  /// test can hold the mapping down without a device.
  @visibleForTesting
  static String playState(Map<String, dynamic> play) {
    if (play.isEmpty) return 'unknown';
    if (play['available'] == true) return 'update_available';
    if (play['inProgress'] == true) return 'in_progress';
    if (play.containsKey('available')) return 'none';
    return 'unknown';
  }

  Future<void> _dismiss() async {
    await AppUpdateFeed.markDismissed(AppUpdateFeed.pAndroid);
    appUpdateBar.hide();
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
