import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../design_tokens.dart';
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

  /// Test/proof seam: renders the banner without waiting 45 s for a real
  /// version transition, so the redesigned strip can be captured as evidence.
  @visibleForTesting
  void debugShowBanner() => _showBanner();

  /// CHANGE #282 — the web half of the redesigned update prompt.
  ///
  /// This used to be a bare MaterialBanner with three hardcoded colours and a
  /// text button. It is now the same visual language as the Android update
  /// sheet: brand-tinted circular badge, a title over a quiet sub-line, and one
  /// filled brand action — painted entirely from the Ds token layer, so
  /// `ui_design_set()` recolours it with the rest of the app and no literal
  /// lives here. Both strings stay backend copy (ui_copy), so rewording is an
  /// UPDATE, not a deploy.
  void _showBanner() {
    final m = messengerKey.currentState;
    if (m == null) return;
    m.clearMaterialBanners();
    m.showMaterialBanner(
      MaterialBanner(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        dividerColor: Ds.c.divider,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        leadingPadding: EdgeInsets.only(right: Ds.space.x12),
        leading: Container(
          width: Ds.touch.minTarget,
          height: Ds.touch.minTarget,
          decoration: BoxDecoration(
            color: Ds.c.brandSoft,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.system_update_alt_rounded,
              color: Ds.c.brand, size: Ds.t.subtitleSize),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c('version_watcher.new_version_title'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Text(c('version_watcher.new_version_banner'),
                style: Ds.t.caption),
          ],
        ),
        actions: [
          Padding(
            padding: EdgeInsets.only(right: Ds.space.x8),
            child: FilledButton(
              onPressed: _reload,
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                foregroundColor: Ds.c.surface,
                minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: Text(
                c('version_watcher.update_now'),
                style: Ds.t.body.copyWith(color: Ds.c.surface),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
