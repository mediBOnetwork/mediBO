// lib/services/crash_reporting.dart — CHANGE #473
//
// Backend errors were visible; the crash on a pharmacist's phone was not. This
// is the one place the app reports a client crash, on web and on Android.
//
// THE APP RENDERS, IT NEVER DECIDES. Every knob below — whether Sentry runs at
// all, the DSN, the environment, the sample rates, the breadcrumb switches, the
// release template, what counts as PII — arrives from `crash_config_get()`.
// Turning Sentry on is an UPDATE (paste SENTRY_DSN into the vault); it is not a
// deploy. Nothing here has a Dart fallback for any of those values, because a
// fallback is a second copy of the answer and one of the two is always stale.
//
// THE NO-DSN PATH IS A FEATURE, NOT A STUB. With no DSN the SDK is never
// initialised, and every crash still goes somewhere Om can read it: the backend
// queue behind `crash_report_client()`, plus a small on-device buffer in
// shared_preferences for events raised while offline, flushed on the next boot.
// So crash capture is live today and Sentry is an additional destination.
//
// PRIVACY. Identity is role + uid, never a name, a number or anything medical.
// Every event passes through [CrashScrubber] in `beforeSend` before it can
// leave the device, and the backend scrubs a second time on the way into the
// queue. `sendDefaultPii` is a backend boolean and is off.
//
// DEFENSIVE IMPORT RULE: no dart:html / dart:js here — this file is reachable
// from the widget tree, and a web-only library in that position white-screens
// the dart2js build.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';
import 'crash_scrub.dart';

class CrashReporting {
  CrashReporting._();

  // ── What the backend told us ───────────────────────────────────────────────
  static Map<String, dynamic> _cfg = const <String, dynamic>{};
  static CrashScrubber _scrubber = CrashScrubber.empty;
  static bool _sentryOn = false;
  static bool _loaded = false;

  /// True once Sentry itself is initialised. False is the normal, healthy state
  /// until a DSN exists — crashes still reach the backend queue.
  static bool get sentryEnabled => _sentryOn;

  /// True once crash_config_get() has answered. Before that nothing is sent
  /// anywhere: an unconfigured scrubber must never be trusted with a payload.
  static bool get ready => _loaded;

  /// Release / dist, stamped at BUILD time by scripts/deploy.sh from the same
  /// CHANGE number it writes into version.json, so a crash maps to its change.
  /// Empty on a local `flutter run`, which is correct — that build shipped to
  /// nobody and has no change number to claim.
  static const String _buildRelease =
      String.fromEnvironment('SENTRY_RELEASE', defaultValue: '');
  static const String _buildDist =
      String.fromEnvironment('SENTRY_DIST', defaultValue: '');

  /// The commit version.json reported at boot. A TAG, never part of the release
  /// id — the release is the change number, which is what Om reads.
  static String _buildCommit = '';
  static String _release = '';
  static String _dist = '';

  static String get release => _release;
  static String get dist => _dist;

  // ── Identity: role + uid, nothing else ─────────────────────────────────────
  static String _role = '';

  /// Called from the auth listener. The ROLE only — never a name, a shop, or a
  /// phone number. uid is read from the live session at capture time.
  static void setRole(String role) {
    _role = role;
    if (!_sentryOn) return;
    unawaited(_applyUser());
  }

  static Future<void> _applyUser() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      await Sentry.configureScope((scope) {
        scope.setUser(SentryUser(id: uid, data: <String, String>{'role': _role}));
      });
    } catch (_) {}
  }

  // ── Boot ───────────────────────────────────────────────────────────────────

  /// Reads the config, initialises Sentry when the backend says it is on, and
  /// flushes anything the device buffered while offline.
  ///
  /// Crash-isolated end to end: crash reporting must never be the reason the
  /// app fails to boot. Every failure path leaves the app running with the
  /// local queue, which is exactly the no-DSN path.
  static Future<void> init({String platform = 'web', String buildCommit = ''}) async {
    if (_initOnce != null) return _initOnce!;
    return _initOnce = _init(platform: platform, buildCommit: buildCommit);
  }

  static Future<void>? _initOnce;

  /// Idempotent boot for callers that may run BEFORE main()'s own init — the
  /// Crashes card is one, since its test button must scrub with the real rules
  /// whether or not boot got there first. Concurrent callers share one future,
  /// so the SDK is never initialised twice.
  static Future<void> ensureReady({String buildCommit = ''}) =>
      init(platform: kIsWeb ? 'web' : defaultTargetPlatform.name, buildCommit: buildCommit);

  static Future<void> _init({required String platform, required String buildCommit}) async {
    _buildCommit = buildCommit;
    try {
      final raw = await Supabase.instance.client
          .rpc('crash_config_get', params: {'p_platform': platform})
          .timeout(const Duration(seconds: 6));
      _cfg = Map<String, dynamic>.from(raw as Map);
    } catch (_) {
      _cfg = const <String, dynamic>{};
    }

    _scrubber = CrashScrubber.fromConfig(
      scrubKeys: (_cfg['scrub_keys'] as List?) ?? const [],
      scrubPatterns: (_cfg['scrub_patterns'] as List?) ?? const [],
      mask: _cfg['redaction_mask']?.toString() ?? '',
    );

    // The release id: the build-time stamp when there is one, otherwise the
    // backend's template filled with what this build knows. Both are data.
    _release = _buildRelease.isNotEmpty
        ? _buildRelease
        : _fill(_cfg['release_template']?.toString() ?? '');
    _dist = _buildDist.isNotEmpty
        ? _buildDist
        : _fill(_cfg['dist_template']?.toString() ?? '');

    _loaded = _cfg['ok'] == true;
    final wantSentry = _cfg['enabled'] == true &&
        (_cfg['dsn']?.toString() ?? '').isNotEmpty &&
        _scrubber.hasRules;

    if (wantSentry) {
      try {
        await SentryFlutter.init(_configure);
        _sentryOn = true;
        await _applyUser();
      } catch (_) {
        _sentryOn = false;
      }
    }

    RenderLog.write('c473_crash_reporting', _sentryOn ? 'sentry' : 'local_queue');
    RenderLog.write('c473_crash_release', _release.isEmpty ? 'unstamped' : _release);
    RenderLog.write('c473_crash_scrub_rules', _scrubber.hasRules ? 1 : 0);

    unawaited(_flushBuffer());
  }

  static void _configure(SentryFlutterOptions o) {
    o.dsn = _cfg['dsn']?.toString() ?? '';
    o.environment = _cfg['environment']?.toString() ?? '';
    o.release = _release;
    o.dist = _dist;
    o.tracesSampleRate = _num(_cfg['traces_sample_rate']);
    // Experimental in the SDK, deliberate here: performance/profiling sampling
    // is a knob the spec asks to keep minimal, and the value is the backend's.
    // ignore: experimental_member_use
    o.profilesSampleRate = _num(_cfg['profiles_sample_rate']);
    o.maxBreadcrumbs = _int(_cfg['max_breadcrumbs'], 50);
    o.sendDefaultPii = _cfg['send_default_pii'] == true;
    o.attachStacktrace = _cfg['attach_stacktrace'] == true;
    o.attachScreenshot = _cfg['attach_screenshot'] == true;
    // ignore: experimental_member_use
    o.attachViewHierarchy = _cfg['attach_view_hierarchy'] == true;
    o.debug = _cfg['debug'] == true;
    // The last gate before anything leaves the device.
    o.beforeSend = (event, hint) => scrubEvent(event);
    o.beforeBreadcrumb = (crumb, hint) => scrubBreadcrumb(crumb);
  }

  /// The `beforeSend` body, split out so it is reachable without an SDK.
  @visibleForTesting
  static SentryEvent? scrubEvent(SentryEvent event) {
    // No rules loaded means "I have not been told what is sensitive". Dropping
    // the event is the only safe answer; a guessed rule list is not.
    if (!_scrubber.hasRules) return null;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    // Identity is rebuilt here rather than trusted from the scope, so an event
    // assembled anywhere in the SDK still carries role + uid only.
    event.user = SentryUser(id: uid, data: <String, String>{'role': _role});
    final msg = event.message;
    if (msg != null) {
      event.message =
          SentryMessage(_scrubber.text(msg.formatted), template: msg.template);
    }
    // A URL can carry a token or a phone number in its query string.
    event.request = null;
    event.contexts['medibo'] = <String, dynamic>{
      'role': _role,
      'build_commit': _buildCommit,
      'breadcrumb_count': _crumbs.length,
    };
    if (_buildCommit.isNotEmpty) {
      event.tags = <String, String>{...?event.tags, 'build_commit': _buildCommit};
    }
    return event;
  }

  @visibleForTesting
  static Breadcrumb? scrubBreadcrumb(Breadcrumb? crumb) {
    if (crumb == null) return null;
    if (!_scrubber.hasRules) return null;
    crumb.message = _scrubber.text(crumb.message);
    crumb.data = _scrubber.map(crumb.data?.cast<String, dynamic>());
    return crumb;
  }

  // ── Capture ────────────────────────────────────────────────────────────────

  /// A framework error from FlutterError.onError.
  static Future<void> captureFlutterError(FlutterErrorDetails details) =>
      _capture(details.exception, details.stack,
          kind: 'flutter_error',
          culprit: details.library ?? '',
          hint: details.exceptionAsString());

  /// An uncaught async error from the boot zone.
  static Future<void> captureError(Object error, StackTrace? stack,
          {String kind = 'zone_error'}) =>
      _capture(error, stack, kind: kind, hint: error.toString());

  static Future<void> _capture(Object error, StackTrace? stack,
      {required String kind, String culprit = '', String hint = ''}) async {
    if (_sentryOn) {
      try {
        await Sentry.captureException(error, stackTrace: stack);
        return;
      } catch (_) {
        // fall through to the local queue — a crash is never dropped silently
      }
    }
    await _queueLocal(
      kind: kind,
      message: hint.isEmpty ? error.toString() : hint,
      stack: stack?.toString() ?? '',
      culprit: culprit,
    );
  }

  /// The debug-screen button. Raises a REAL exception (not a synthetic string)
  /// so the whole path — capture, scrub, transport — is what a production crash
  /// would take. Returns true when it was recorded somewhere.
  static Future<bool> sendTestCrash() async {
    try {
      throw StateError(
          'mediBO test crash (CHANGE #473) — deliberate, raised from the Crashes card');
    } catch (e, st) {
      if (_sentryOn) {
        try {
          final id = await Sentry.captureException(e, stackTrace: st);
          return id != const SentryId.empty();
        } catch (_) {}
      }
      return _queueLocal(
        kind: 'test',
        message: e.toString(),
        stack: st.toString(),
        culprit: 'crash_reporting.sendTestCrash',
      );
    }
  }

  // ── The local queue ────────────────────────────────────────────────────────

  static const _bufKey = 'crash_local_buffer_v1';

  static Future<bool> _queueLocal({
    required String kind,
    required String message,
    required String stack,
    String culprit = '',
  }) async {
    final body = <String, dynamic>{
      'kind': kind,
      'level': kind == 'test' ? 'info' : 'error',
      'release': _release,
      'dist': _dist,
      'environment': _cfg['environment']?.toString() ?? '',
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      'build_commit': _buildCommit,
      // Scrubbed here as well as server-side: the string never leaves the
      // device un-redacted, even on the wire.
      'culprit': _scrubber.text(culprit),
      'message': _scrubber.text(message),
      'stack': _scrubber.text(stack),
      'breadcrumbs': _scrubber.value(_crumbs),
      'sent_to_sentry': false,
    };
    try {
      final res = await Supabase.instance.client
          .rpc('crash_report_client', params: {'p_payload': body})
          .timeout(const Duration(seconds: 8));
      if (res is Map && res['ok'] == true) return true;
      if (res is Map && res['throttled'] == true) return false;
    } catch (_) {
      // Offline / signed-out-and-refused: hold it on the device and retry on
      // the next boot. This is the "queues locally" the spec asks to prove.
    }
    await _buffer(body);
    return true;
  }

  static Future<void> _buffer(Map<String, dynamic> body) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_bufKey) ?? <String>[];
      list.add(jsonEncode(body));
      final max = _int(_cfg['local_queue_max'], 50);
      while (list.length > max) {
        list.removeAt(0);
      }
      await prefs.setStringList(_bufKey, list);
      RenderLog.write('c473_crash_buffered', list.length);
    } catch (_) {}
  }

  /// Replays whatever the device is holding, oldest first. Anything that still
  /// will not send stays buffered for the boot after this one.
  static Future<void> _flushBuffer() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_bufKey) ?? <String>[];
      if (list.isEmpty) return;
      final left = <String>[];
      for (final raw in list) {
        try {
          final body = jsonDecode(raw) as Map<String, dynamic>;
          final res = await Supabase.instance.client
              .rpc('crash_report_client', params: {'p_payload': body})
              .timeout(const Duration(seconds: 8));
          if (!(res is Map && res['ok'] == true)) left.add(raw);
        } catch (_) {
          left.add(raw);
        }
      }
      await prefs.setStringList(_bufKey, left);
      RenderLog.write('c473_crash_flushed', list.length - left.length);
    } catch (_) {}
  }

  /// How many events this device is still holding. Read by the Crashes card so
  /// "queued locally" is a number Om can see, not a claim.
  static Future<int> bufferedCount() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_bufKey) ?? const <String>[]).length;
    } catch (_) {
      return 0;
    }
  }

  // ── Breadcrumbs ────────────────────────────────────────────────────────────
  //
  // Kept locally too, so a crash on the local-queue path carries the same trail
  // a Sentry event would. Bounded by the backend's max_breadcrumbs.

  static final List<Map<String, dynamic>> _crumbs = <Map<String, dynamic>>[];

  static void _crumb(String category, String message, Map<String, dynamic> data) {
    final entry = <String, dynamic>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'category': category,
      'message': message,
      'data': data,
    };
    _crumbs.add(entry);
    while (_crumbs.length > _int(_cfg['max_breadcrumbs'], 50)) {
      _crumbs.removeAt(0);
    }
    if (!_sentryOn) return;
    try {
      Sentry.addBreadcrumb(Breadcrumb(
        category: category,
        message: message,
        data: data,
        level: SentryLevel.info,
      ));
    } catch (_) {}
  }

  /// A navigation breadcrumb. Route NAMES only — a route's arguments can carry
  /// an order id, a phone number or a customer name, so they are never read.
  static void navBreadcrumb(String action, String? from, String? to) {
    if (_cfg['breadcrumb_nav'] != true) return;
    _crumb('navigation', action,
        <String, dynamic>{'from': from ?? '', 'to': to ?? ''});
  }

  /// An RPC breadcrumb: the function name, the status and how long it took.
  /// Never the request body and never the response — both are full of trade
  /// data and customer detail.
  static void rpcBreadcrumb(String fn, int status, int ms) {
    if (_cfg['breadcrumb_rpc'] != true) return;
    _crumb('rpc', fn, <String, dynamic>{'status': status, 'ms': ms});
  }

  /// The NavigatorObserver that feeds [navBreadcrumb]. Handed to MaterialApp in
  /// main.dart — one observer, every route in the app.
  static final NavigatorObserver navigatorObserver = _CrashNavObserver();

  /// The http.Client handed to Supabase.initialize. Wrapping the ONE client
  /// every RPC already goes through is what makes RPC breadcrumbs universal
  /// without touching a single call site.
  static http.Client breadcrumbHttpClient([http.Client? inner]) =>
      _BreadcrumbHttpClient(inner ?? http.Client());

  // ── small helpers (parsing, not deciding) ─────────────────────────────────

  static String _fill(String template) {
    if (template.isEmpty) return '';
    return template
        .replaceAll('{change}', _buildDist)
        .replaceAll('{commit}', _buildCommit);
  }

  static double _num(dynamic v) =>
      v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

  static int _int(dynamic v, int fallback) =>
      v is num ? v.toInt() : (int.tryParse('$v') ?? fallback);

  @visibleForTesting
  static void debugConfigure({
    required Map<String, dynamic> config,
    bool sentryOn = false,
  }) {
    _cfg = config;
    _sentryOn = sentryOn;
    _loaded = true;
    _scrubber = CrashScrubber.fromConfig(
      scrubKeys: (config['scrub_keys'] as List?) ?? const [],
      scrubPatterns: (config['scrub_patterns'] as List?) ?? const [],
      mask: config['redaction_mask']?.toString() ?? '',
    );
  }

  @visibleForTesting
  static CrashScrubber get scrubber => _scrubber;

  @visibleForTesting
  static List<Map<String, dynamic>> get debugCrumbs =>
      List<Map<String, dynamic>>.unmodifiable(_crumbs);

  @visibleForTesting
  static void debugClearCrumbs() => _crumbs.clear();
}

class _CrashNavObserver extends NavigatorObserver {
  String _name(Route<dynamic>? r) => r?.settings.name ?? '';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previous) {
    CrashReporting.navBreadcrumb('push', _name(previous), _name(route));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previous) {
    CrashReporting.navBreadcrumb('pop', _name(route), _name(previous));
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    CrashReporting.navBreadcrumb('replace', _name(oldRoute), _name(newRoute));
  }
}

/// Records every Supabase RPC as a breadcrumb. It reads the URL's LAST PATH
/// SEGMENT (the function name) and the status code — never the request body,
/// never the response body.
class _BreadcrumbHttpClient extends http.BaseClient {
  final http.Client _inner;
  _BreadcrumbHttpClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final sw = Stopwatch()..start();
    try {
      final res = await _inner.send(request);
      _note(request, res.statusCode, sw.elapsedMilliseconds);
      return res;
    } catch (_) {
      _note(request, 0, sw.elapsedMilliseconds);
      rethrow;
    }
  }

  void _note(http.BaseRequest request, int status, int ms) {
    try {
      final segs = request.url.pathSegments;
      if (segs.length < 2) return;
      if (segs[segs.length - 2] != 'rpc') return; // /rest/v1/rpc/<fn>
      CrashReporting.rpcBreadcrumb(segs.last, status, ms);
    } catch (_) {}
  }

  @override
  void close() => _inner.close();
}
