import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'page_reload.dart';
import 'ui_copy.dart';
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

  // CHANGE #415: sentinel proving the seed-retry hardening below is in the
  // live bundle.
  static const String kC415 = 'c415_version_watcher_seed_retry';

  // CHANGE #415: true once _bootCommit has been set from an actual
  // successful fetch (either the initial seed, a background retry, or —
  // as a last-resort fallback — the first poll). Distinct from checking
  // `_bootCommit == null` so the intent ("do we have a real baseline yet?")
  // stays explicit even while a background retry may be racing a poll.
  bool _seeded = false;

  // Backoff between initial-seed retry attempts if the very first fetch
  // fails (e.g. a transient network hiccup right at page load). 5 attempts
  // total: the immediate one in init(), plus 4 retries at these gaps —
  // covering ~4.5s, comfortably before the first poll at _firstDelay (5s).
  static const List<Duration> _seedRetryDelays = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];

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
  ///
  /// CHANGE #415: the initial fetch used to be a single, unretried attempt —
  /// if it failed (transient network hiccup right at load), _bootCommit
  /// stayed null and the FIRST successful poll would silently adopt
  /// whatever was live as the baseline instead of comparing, swallowing any
  /// version transition that happened in that window. Now: try once
  /// immediately (unchanged fast path for the common case), and if that
  /// fails, kick off a short background retry loop WITHOUT awaiting it here
  /// — so init() itself still returns promptly and never delays start() or
  /// blocks the caller/UI.
  Future<void> init() async {
    try {
      RenderLog.write(kC415, 'init_start');
    } catch (_) {}
    final first = await _fetchCommit();
    if (first != null) {
      _bootCommit = first;
      _seeded = true;
      try {
        RenderLog.write('c241_vw_init', 'boot=$first');
      } catch (_) {}
      return;
    }
    try {
      RenderLog.write('c241_vw_init', 'boot=null');
    } catch (_) {}
    // ignore: unawaited_futures
    _retrySeed();
  }

  /// Background retry loop for the initial seed, only entered when the
  /// first attempt in init() failed. Stops early if a poll (or an earlier
  /// retry) has already seeded the baseline in the meantime.
  Future<void> _retrySeed() async {
    for (final delay in _seedRetryDelays) {
      if (_seeded) return;
      await Future.delayed(delay);
      if (_seeded) return;
      final commit = await _fetchCommit();
      if (commit != null) {
        _bootCommit = commit;
        _seeded = true;
        try {
          RenderLog.write(kC415, 'retry_success:boot=$commit');
        } catch (_) {}
        return;
      }
    }
    try {
      RenderLog.write(kC415, 'retry_exhausted');
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
    // CHANGE #415: last-resort fallback — only reached if init()'s immediate
    // attempt AND every background retry (_retrySeed) failed, i.e. a
    // genuinely prolonged outage. Legitimate "no baseline yet" case, so
    // adopt it without a false popup. In the normal/common case _seeded is
    // already true well before the first poll (5s), via the retries above,
    // so this branch is rarely taken — that's the whole point of the fix.
    if (!_seeded) {
      _bootCommit = live;
      _seeded = true;
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
    reloadPage();
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
        content: Text(c('version_watcher.new_version_banner')),
        actions: [
          TextButton(
            onPressed: _reload,
            child: Text(
              c('version_watcher.update_now'),
              style: const TextStyle(
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
