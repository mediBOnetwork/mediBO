import 'package:flutter/services.dart';

import 'app_update_feed.dart';

/// CMD #2028 — the Dart half of the Play In-App Updates bridge
/// (android/app/src/main/kotlin/in/medibo/app/PlayUpdate.kt).
///
/// It starts the flow the BACKEND named and nothing else: `flow` arrives in the
/// `app_update_bar()` payload as 'flexible' or 'immediate' and is passed
/// straight through. Every call answers false rather than throwing, so a
/// sideloaded install, a device with no Play Store, or a Play outage leaves the
/// app exactly as it was.
class PlayUpdateChannel {
  PlayUpdateChannel._();
  static final PlayUpdateChannel instance = PlayUpdateChannel._();

  static const MethodChannel _ch = MethodChannel('in.medibo.app/play_update');

  /// Called by the native side the moment a flexible download lands (it then
  /// applies it, which restarts the app). The pill uses this to swap to its
  /// restarting label.
  void Function()? onDownloaded;

  /// Called when Play reports the download failed or the user cancelled.
  void Function()? onFailed;

  bool _listening = false;

  void listen() {
    if (_listening) return;
    _listening = true;
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'downloaded':
          onDownloaded?.call();
        case 'failed':
          onFailed?.call();
      }
      return null;
    });
  }

  Future<bool> available() async {
    if (!AppUpdateFeed.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// What Play itself says. Used only to decide whether the in-app flow can
  /// run — never to decide whether the bar shows.
  Future<Map<String, dynamic>> check() async {
    if (!AppUpdateFeed.isAndroid) return const {};
    try {
      final res = await _ch.invokeMethod<Map<Object?, Object?>>('check');
      if (res == null) return const {};
      return res.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return const {};
    }
  }

  /// Start the flow the backend chose. `false` means Play could not run it.
  Future<bool> start(String flow) async {
    if (!AppUpdateFeed.isAndroid) return false;
    listen();
    try {
      return await _ch.invokeMethod<bool>('start', {'flow': flow}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Apply a download already sitting on the device (the app comes back to the
  /// foreground after a background download finished).
  Future<bool> complete() async {
    if (!AppUpdateFeed.isAndroid) return false;
    try {
      return await _ch.invokeMethod<bool>('complete') ?? false;
    } catch (_) {
      return false;
    }
  }
}
