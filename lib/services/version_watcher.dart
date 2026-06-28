// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../utils/render_log.dart';

/// Polls /version.json every 45 s and, when a newer build is detected,
/// shows a top MaterialBanner and auto-reloads — but never while a text
/// field is focused (so mid-entry cash-payment data is never destroyed).
class VersionWatcher {
  VersionWatcher._();
  static final VersionWatcher instance = VersionWatcher._();

  /// Attach to MaterialApp.scaffoldMessengerKey so the banner can be shown
  /// from outside the widget tree.
  final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  int? _bootChange;
  bool _handled = false;
  Timer? _firstPoll;
  Timer? _pollTimer;
  Timer? _reloadLoop;

  static const Duration _firstDelay = Duration(seconds: 5);
  static const Duration _interval   = Duration(seconds: 45);
  static const Duration _idleStep   = Duration(seconds: 5);

  Future<int?> _fetchChange() async {
    try {
      final url = '/version.json?cb=${DateTime.now().millisecondsSinceEpoch}';
      final resp = await http.get(
        Uri.parse(url),
        headers: const {'cache-control': 'no-cache'},
      );
      if (resp.statusCode != 200) return null;
      final map = jsonDecode(resp.body) as Map<String, dynamic>;
      final c = map['change'];
      if (c is int) return c;
      if (c is String) return int.tryParse(c);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Call once after first paint (in _AppRootState postFrameCallback).
  /// Seeds the baseline change number so the first poll never false-fires.
  Future<void> init() async {
    _bootChange = await _fetchChange();
    try {
      RenderLog.write('c241_vw_init', 'boot=${_bootChange ?? "null"}');
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
    final live = await _fetchChange();
    try {
      RenderLog.write(
          'c241_vw_poll', 'live=${live ?? "null"} boot=${_bootChange ?? "null"}');
    } catch (_) {}
    if (live == null) return;
    if (_bootChange == null) {
      _bootChange = live;
      return;
    }
    if (live != _bootChange) {
      _handled = true;
      try {
        RenderLog.write(
            'c241_vw_new_detected', 'live=$live boot=$_bootChange');
      } catch (_) {}
      _showBanner();
      _scheduleAutoReload();
    }
  }

  /// Returns true if the user is actively typing in any DOM input/textarea.
  /// Flutter web routes key events through real DOM elements, so
  /// document.activeElement reliably reflects text-field focus.
  bool _isTyping() {
    try {
      final el = html.document.activeElement;
      if (el == null) return false;
      final tag = el.tagName?.toLowerCase() ?? '';
      if (tag == 'input' || tag == 'textarea') return true;
      final ce = el.getAttribute('contenteditable');
      if (ce == 'true' || ce == '') return true;
    } catch (_) {}
    return false;
  }

  void _scheduleAutoReload() {
    _reloadLoop?.cancel();
    _reloadLoop = Timer.periodic(_idleStep, (t) {
      if (!_isTyping()) {
        t.cancel();
        _reload();
      }
      // user is typing — re-check in _idleStep seconds
    });
  }

  void _reload() {
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
        content: const Text('A new version of mediBO is available. Updating…'),
        actions: [
          TextButton(
            onPressed: _reload,
            child: const Text(
              'UPDATE NOW',
              style: TextStyle(
                color: Color(0xFF1B5E20),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
