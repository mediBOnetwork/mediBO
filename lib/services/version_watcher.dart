import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../build_info.dart';
import '../widgets/update_bar.dart';
import 'app_update_feed.dart';
import 'page_reload.dart';
import '../utils/render_log.dart';

/// Polls /version.json and, when a newer build is live, raises the floating
/// update pill — no service worker, no auto-reload.
///
/// CMD #2028: the cadence and every string are the BACKEND's. The tab reports
/// the build it booted on and the build version.json serves now;
/// `app_update_bar()` decides whether that is an update and what the pill says.
/// Nothing reloads by itself any more — the old 6 s countdown could yank a
/// customer out of a half-filled cart. `Update Now` is the only way forward,
/// and it clears every cache before it reloads.
///
/// FIX (#287): Previously read map['change'] and parsed it as int, but the
/// 'change' value is "#286" (with a '#' prefix) so int.tryParse returns null,
/// causing boot=null and live=null forever. Now reads map['commit'] (e.g.
/// "18bb68a") which is a clean string that changes on every deploy.
class VersionWatcher {
  VersionWatcher._();
  static final VersionWatcher instance = VersionWatcher._();

  /// Attach to MaterialApp.scaffoldMessengerKey. Still owned here because the
  /// rest of the app (forced-logout snackbars) shows messages through it; the
  /// update prompt itself no longer uses it — see [updateBar].
  final GlobalKey<ScaffoldMessengerState> messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  /// CHANGE #286 — the slim bottom bar's state. `UpdateBarHost` (installed in
  /// MaterialApp.builder) watches this, so the prompt can be raised from a
  /// plain service with no BuildContext and, crucially, WITHOUT reflowing the
  /// page the way the old top MaterialBanner did.
  /// CMD #2028 — the app-wide singleton, shared with the Android driver so
  /// both platforms raise ONE pill.
  final UpdateBarController updateBar = appUpdateBar;

  String? _bootCommit;
  bool _handled = false;
  Timer? _firstPoll;
  Timer? _pollTimer;
  static const Duration _firstDelay = Duration(seconds: 5);

  /// CMD #2028 — the spec's cadence, and only the fallback: the live number is
  /// `poll_seconds` in the app_update_bar() payload.
  static const Duration _interval = Duration(minutes: 5);

  /// The last payload, so the pill's strings and the poll cadence are the
  /// backend's even on the second and third check.
  Map<String, dynamic>? _payload;

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

  /// CHANGE #657 — the live build's change number, from the last successful
  /// fetch. Compared against [kBuiltChange], which is compiled INTO this
  /// bundle, so a stale bundle is detectable even when the whole document it
  /// came with is stale too. Empty until the first successful fetch.
  String _liveChange = '';

  /// CHANGE #657 — set once the stale-bundle path has fired, so a reload that
  /// does not fix the staleness (an edge node still serving the old document)
  /// cannot become a reload loop.
  bool _staleBundleHandled = false;

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
      _liveChange = map['change']?.toString() ?? '';
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
    _arm();
    // CMD #2028 — a tab that was in the background for an hour must not wait
    // out a whole poll interval before it learns a deploy happened.
    try {
      WidgetsBinding.instance.addObserver(_ForegroundHook(_check));
    } catch (_) {}
    try {
      RenderLog.write('c241_autoupdate_ready',
          'interval=${_interval.inSeconds}s;source=backend');
      RenderLog.write('c657_running_build',
          hasBuiltChange ? kBuiltChange : 'unstamped');
    } catch (_) {}
  }

  /// (Re)arm the periodic poll at whatever cadence the backend last named.
  void _arm() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
        AppUpdateFeed.pollInterval(_payload, _interval), (_) => _check());
  }

  Future<void> _check() async {
    if (_handled) return;
    final live = await _fetchCommit();
    try {
      RenderLog.write(
          'c241_vw_poll', 'live=${live ?? "null"} boot=${_bootCommit ?? "null"}');
    } catch (_) {}
    if (live == null) return;
    // CHANGE #657 — THE RUNNING BUNDLE vs THE LIVE BUILD.
    //
    // Everything below compares the live commit against the commit this TAB
    // first saw, which answers "did a deploy happen while I sat here?" — it
    // cannot answer "did I boot on an old bundle?", because a stale document
    // seeds a stale baseline and the two agree forever. `kBuiltChange` is
    // compiled into main.dart.js, so this comparison is the running JavaScript
    // against the live build, with no cached document in the path.
    //
    // Fires once (`_staleBundleHandled`): if the reload comes back on the same
    // old bundle — an edge node still serving the previous document — the user
    // gets one reload and the prompt, never a loop.
    if (!_staleBundleHandled &&
        hasBuiltChange &&
        _liveChange.isNotEmpty &&
        _liveChange != kBuiltChange) {
      _staleBundleHandled = true;
      _handled = true;
      try {
        RenderLog.write('c657_stale_bundle',
            'running=$kBuiltChange live=$_liveChange');
      } catch (_) {}
      await _raise(kBuiltChange, _liveChange);
      return;
    }
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
        RenderLog.write('c287_update_prompt', 'from=$from;to=$live;persistent=true');
      } catch (_) {}
      await _raise(from, live);
    }
  }

  /// CMD #2028 — the backend decides. The tab hands over both build strings
  /// and renders whatever comes back; if the RPC is unreachable the pill still
  /// goes up, on its ui_copy fallbacks, because a browser on a stale bundle is
  /// the one case where saying nothing is worse than saying it plainly.
  Future<void> _raise(String from, String to) async {
    final res = await AppUpdateFeed.fetch(
        platform: 'web', build: from, liveBuild: to);
    if (res != null) {
      _payload = res;
      _arm();
      if (res[AppUpdateFeed.kShow] != true) {
        // The backend says this is not an update after all (the bar is off, or
        // the two builds are the same). Do not raise anything.
        _handled = false;
        return;
      }
    }
    _showBanner();
  }

  void _reload() {
    // Swap the pill to the updating label and stop taking taps: one reload,
    // however many times the button is pressed.
    updateBar.markUpdating();
    try {
      RenderLog.write('c241_vw_reload', 'reloading to new build');
    } catch (_) {}
    // CMD #2028 — clear every cache and service worker first, so the reload
    // cannot come back on the bundle we are trying to leave.
    hardReloadPage();
  }

  /// Test/proof seam: raises the bar without waiting 45 s for a real version
  /// transition, so the redesigned strip can be captured as evidence.
  @visibleForTesting
  void debugShowBanner() => _showBanner();

  /// CHANGE #286 — the web half of the update prompt.
  ///
  /// It used to be a MaterialBanner. Flutter pins those to the TOP of the
  /// scaffold and PUSHES the app down while they show, so a badge + heading +
  /// sub-line + full-width button ate half a phone screen and shoved the logo
  /// and the search bar off it. It is now one slim bar pinned just above the
  /// bottom nav (see lib/widgets/update_bar.dart): round chip, one bold line,
  /// one compact pill. It overlays — it reflows nothing and it blocks no tap.
  ///
  /// Nothing visual lives here any more. Both strings are ui_copy keys and
  /// every token is read in the widget, so rewording or restyling the prompt
  /// stays an UPDATE, not a deploy.
  void _showBanner() {
    // Belt and braces: a MaterialBanner left over from a previous build (or a
    // hot reload across this change) must not linger at the top.
    messengerKey.currentState?.clearMaterialBanners();
    updateBar.show(onUpdate: _reload, payload: _payload);
    try {
      RenderLog.write('c286_update_prompt_shown', 'surface=bottom_bar');
    } catch (_) {}
  }
}

/// CMD #2028 — a lifecycle observer small enough to live beside the service
/// that owns it. A backgrounded tab (phone locked, app switched) re-checks the
/// moment it comes back rather than waiting out the poll interval.
class _ForegroundHook with WidgetsBindingObserver {
  _ForegroundHook(this._onResume);
  final Future<void> Function() _onResume;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onResume();
  }
}
