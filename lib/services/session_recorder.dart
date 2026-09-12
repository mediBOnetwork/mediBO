import 'package:flutter/widgets.dart';

import '../utils/render_log.dart';

/// CHANGE #638 — the recorder behind "record Om's own manual walkthroughs".
///
/// It is OFF until somebody starts it from the Chaos lab, and it holds no
/// opinion of its own: it observes what the app already announces — the routes
/// the navigator pushes and the screens that report themselves through
/// [RenderLog] — and hands each one to the backend as a step. What a step
/// MEANS, whether the walkthrough passed, and what it becomes afterwards are
/// all the backend's calls, made in `recording_step_add` / `recording_stop` /
/// `recording_promote`.
///
/// The send function is injected by whoever started the recording, so this file
/// never touches Supabase and can be exercised on the Dart VM.
typedef RecorderSend = Future<void> Function({
  required String kind,
  required String screen,
  required String action,
  required bool ok,
});

class _Step {
  const _Step(this.kind, this.screen, this.action, this.ok);
  final String kind;
  final String screen;
  final String action;
  final bool ok;
}

class SessionRecorder {
  SessionRecorder._();

  static final SessionRecorder instance = SessionRecorder._();

  /// The backend caps a walkthrough too; this is only so a runaway screen
  /// cannot queue an unbounded list in memory before the cap is reached.
  static const int maxSteps = 400;

  int? _recordingId;
  RecorderSend? _send;
  final List<_Step> _queue = <_Step>[];
  bool _draining = false;
  int _captured = 0;

  bool get active => _recordingId != null;
  int? get recordingId => _recordingId;

  /// How many steps this recorder has handed over. The screen shows the
  /// BACKEND's count; this one exists only for the "still capturing" hint.
  int get captured => _captured;

  final NavigatorObserver _observer = _RecorderObserver();

  /// Registered once, in main.dart, beside the crash reporter's observer. It
  /// does nothing at all while [active] is false.
  NavigatorObserver get observer => _observer;

  void start(int recordingId, RecorderSend send) {
    _recordingId = recordingId;
    _send = send;
    _captured = 0;
    _queue.clear();
    RenderLog.onWrite = _onRender;
  }

  void stop() {
    _recordingId = null;
    _send = null;
    _queue.clear();
    RenderLog.onWrite = null;
  }

  /// One observed step. Never throws and never blocks the caller: a recorder
  /// that can break the screen it is watching is worse than no recorder.
  void note({
    required String kind,
    required String screen,
    required String action,
    bool ok = true,
  }) {
    if (!active) return;
    if (_captured >= maxSteps) return;
    if (action.trim().isEmpty && screen.trim().isEmpty) return;
    _captured++;
    _queue.add(_Step(kind, screen, action, ok));
    _drain();
  }

  void _onRender(String key, dynamic value) {
    if (key == 'build' || key == 'boot_status') return;
    note(kind: 'render', screen: key, action: 'rendered $key');
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final send = _send;
        if (send == null) {
          _queue.clear();
          return;
        }
        final step = _queue.removeAt(0);
        try {
          await send(
            kind: step.kind,
            screen: step.screen,
            action: step.action,
            ok: step.ok,
          );
        } catch (_) {
          // A dropped step is not worth breaking the walkthrough over.
        }
      }
    } finally {
      _draining = false;
    }
  }
}

class _RecorderObserver extends NavigatorObserver {
  void _push(Route<dynamic>? route, String action) {
    final name = route?.settings.name ?? '';
    if (name.isEmpty) return; // an unnamed route names nothing worth replaying
    SessionRecorder.instance.note(kind: 'nav', screen: name, action: action);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _push(route, 'opened');

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _push(previousRoute, 'went back to');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _push(newRoute, 'replaced with');
}
