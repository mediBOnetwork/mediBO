// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../utils/render_log.dart';

/// Polls /version.json every 45 s and, when a newer build is detected,
/// shows a MaterialBanner and auto-reloads after 6 s — no service worker.
///
/// FIX (#287): Previously read map['change'] and parsed it as int, but the
/// 'change' value is "#286" (with a '#' prefix) so int.tryParse returns null,
/// causing boot=null and live=null forever. Now reads map['commit'] (e.g.
/// "18bb68a") which is a clean string that changes on every deploy.
class VersionWatcher {
  VersionWatcher._();
  static final VersionWatcher instance = VersionWatcher._();

  /// Attach to MaterialApp.scaffoldMessengerKey so the banner can be shown
  /// from outside the widget tree.
  final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  String? _bootCommit;
  bool _handled = false;
  Timer? _firstPoll;
  Timer? _pollTimer;
  Timer? _reloadTimer;

  static const Duration _firstDelay = Duration(seconds: 5);
  static const Duration _interval   = Duration(seconds: 45);
  static const Duration _autoReload = Duration(seconds: 6);

  Future<String?> _fetchCommit() async {
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final url = '/version.json?t=$ts';
      final resp = await http.get(
        Uri.parse(url),
        headers: const {'Cache-Control': 'no-cache', 'Pragma': 'no-cache'},
      );
      try {
        RenderLog.write('c287_vw_fetch',
            'url=version.json?t=...;cachebust=true;status=${resp.statusCode}');
      } catch (_) {}
      if (resp.statusCode != 200) return null;
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      final commit = map['commit']?.toString();
      final cleaned = (commit != null && commit.isNotEmpty && commit != 'dev')
          ? commit
          : null;
      try {
        RenderLog.write('c287_vw_field', 'reads=commit;sample=${cleaned ?? "null"}');
      } catch (_) {}
      return cleaned;
    } catch (_) {
      return null;
    }
  }

  /// Call once after first paint to seed the boot commit hash.
  Future<void> init() async {
    _bootCommit = await _fetchCommit();
    try {
      RenderLog.write('c241_vw_init', 'boot=${_bootCommit ?? "null"}');
    } catch (_) {}
  }

  /// Begin periodic polling. Call immediately after init().
  void start() {
    _firstPoll = Timer(_firstDelay, _check);
    _pollTimer = Timer.periodic(_interval, (_) => _check());
    try {
      RenderLog.write('c241_autoupdate_ready', 'interval=45s');
    } catch (_) {}
  }

  Future<void> _check() async {
    if (_handled) return;
    final live = await _fetchCommit();
    try {
      RenderLog.write(
          'c241_vw_poll', 'live=${live ?? "null"} boot=${_bootCommit ?? "null"}');
    } catch (_) {}
    if (live == null) return;
    if (_bootCommit == null) {
      _bootCommit = live;
      return;
    }
    if (live != _bootCommit) {
      _handled = true;
      final from = _bootCommit!;
      try {
        RenderLog.write('c241_vw_new_detected', 'live=$live boot=$from');
      } catch (_) {}
      try {
        RenderLog.write('c287_update_prompt', 'from=$from;to=$live;countdown=6s');
      } catch (_) {}
      _showBanner();
      _scheduleAutoReload();
    }
  }

  void _scheduleAutoReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(_autoReload, _reload);
  }

  void _reload() {
    _reloadTimer?.cancel();
    try {
      RenderLog.write('c241_vw_reload', 'reloading to new build');
    } catch (_) {}
    html.window.location.reload();
  }

  void _showBanner() {
    final m = messengerKey.currentState;
    if (m == null) return;
    m.clearMaterialBanners();
    m.showMaterialBanner(
      MaterialBanner(
        backgroundColor: const Color(0xFFE8F5E9),
        contentTextStyle: const TextStyle(
          color: Color(0xFF1B5E20),
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
        content: const Text('New version available — updating in 6 seconds…'),
        actions: [
          TextButton(
            onPressed: _reload,
            child: const Text(
              'Update now',
              style: TextStyle(
                color: Color(0xFF1B7A43),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
