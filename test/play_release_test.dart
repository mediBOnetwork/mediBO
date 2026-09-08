// CHANGE #280/#281 — the Play Store screen prints the backend, and nothing else.
//
// What this pins down (each was a real way to get it wrong):
//   • every heading, caption and button caption comes from play_state(); a Dart
//     literal for any of them would fail these expectations
//   • the status chip's LABEL and TONE are the payload's, never derived from
//     the status enum in Dart
//   • Google Play's error body is rendered VERBATIM — not summarised, not
//     re-worded, not "Something went wrong"
//   • the per-track panel is the PLAY API's answer: version, review status and
//     rollout are printed as sent, an empty track prints the backend's own
//     empty line, and a track that was never read says so
//   • `can_test` / `can_promote` are the backend's decisions — the screen never
//     works out for itself whether a build exists to promote — and the greyed
//     button is explained by the backend's own sentence
//   • "Publish update" carries NO track and NO version: the backend picks the
//     tested bundle, so the client cannot ship something else by accident
//   • the auto-publish switch renders the stored flag and sends the flip
//   • history renders in payload order (the fixture is deliberately not sorted)
//   • the release-notes field is pre-filled from draft_notes and what Om types
//     is what gets sent, by BOTH buttons

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/play_store_screen.dart';

/// A DevQueueService whose Play calls answer from fixtures.
class _FakeSvc implements DevQueueService {
  _FakeSvc(this.state);
  final Map<String, dynamic> state;
  Map<String, dynamic>? tested;
  Map<String, dynamic>? promoted;
  bool? autoSetTo;
  int refreshes = 0;

  @override
  Future<Map<String, dynamic>> playState({int limit = 20}) async => state;

  @override
  Future<Map<String, dynamic>> playTestRequest({String? notes}) async {
    tested = {'notes': notes};
    return {'ok': true, 'id': 1, 'message': 'Queued for the builder.'};
  }

  @override
  Future<Map<String, dynamic>> playPromoteRequest({String? notes}) async {
    promoted = {'notes': notes};
    return {'ok': true, 'id': 2, 'version_code': 25, 'message': 'Queued.'};
  }

  @override
  Future<Map<String, dynamic>> playAutoPublishSet(bool on) async {
    autoSetTo = on;
    return {'ok': true, 'auto_publish': on, 'message': 'Auto-publish is on.'};
  }

  @override
  Future<Map<String, dynamic>> playRefreshRequest() async {
    refreshes++;
    return {'ok': true, 'message': 'Refreshing from Google Play.'};
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('the Play screen must call nothing else: '
          '${i.memberName}');
}

Map<String, dynamic> _track(String key, String label,
        {String? version, String? status, String? tone, String? rollout}) =>
    {
      'track': key,
      'track_label': label,
      'has': version != null,
      'version_label': version ?? '—',
      'status_label': status ?? '—',
      'status_tone': tone ?? 'info',
      'rollout_label': rollout,
      'empty_label': 'No release on this track.',
    };

Map<String, dynamic> _state({
  bool canTest = true,
  bool canPromote = false,
  bool autoPublish = false,
  String promoteNote = 'Nothing on internal testing yet. Tap Test now first.',
  List<Map<String, dynamic>>? tracks,
  String? tracksAsOf = 'As of 20 Aug, 01:02 AM IST',
  String? tracksError,
  Map<String, dynamic>? active,
  List<Map<String, dynamic>>? history,
}) =>
    {
      'ok': true,
      'title': 'Play Store',
      'subtitle': 'Build, upload and submit to Google Play — no manual steps.',
      'next_heading': 'Next release',
      'history_heading': 'Recent publishes',
      'notes_heading': 'Release notes for testers and Play (en-US)',
      'notes_hint': 'Written automatically from what changed.',
      'error_heading': 'Google Play said',
      'retry': 'Retry',
      'empty_history': 'Nothing published from here yet.',
      // the three buttons
      'test_button': 'Test now',
      'test_running': 'Building for testers…',
      'test_hint': 'Builds the current code onto Play internal testing.',
      'can_test': canTest,
      'promote_button': 'Publish update',
      'promote_running': 'Submitting…',
      'promote_hint': 'Sends the exact build you just tested to production.',
      'can_promote': canPromote,
      'promote_note': promoteNote,
      'auto_title': 'Auto-publish',
      'auto_publish': autoPublish,
      'auto_state_label': autoPublish ? 'On' : 'Off',
      'auto_hint': autoPublish
          ? 'ON — every successful build is submitted to production.'
          : 'OFF — builds stop at internal testing.',
      // the live per-track panel
      'tracks_heading': 'Live on Google Play',
      'tracks_hint': 'Read from the Google Play Developer API.',
      'tracks_never': 'Not read from Play yet.',
      'refresh_button': 'Refresh from Play',
      'tracks': tracks ??
          [
            _track('internal', 'Internal testing'),
            _track('production', 'Production',
                version: '1.3.11 (24)',
                status: 'Live',
                tone: 'success',
                rollout: 'Full rollout'),
          ],
      'tracks_asof': tracksAsOf,
      'tracks_error': tracksError,
      'active': active ?? {'has': false},
      'draft_notes': '• Faster, clearer browsing — product pages, search and cart.',
      'history': history ?? const [],
    };

Future<void> _pump(WidgetTester t, _FakeSvc svc) async {
  // A tall surface: the screen is one scrolling column and a ListView does not
  // build children below the fold, so the default 800×600 viewport would hide
  // the history section and make "is it rendered?" unanswerable.
  t.view.physicalSize = const Size(1200, 4000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: PlayStoreScreen(service: svc)));
  // pump(), never pumpAndSettle(): an in-flight release renders a spinning chip
  // whose animation never settles, and waiting for it would hang the test.
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('every visible string is the backend payload, verbatim',
      (t) async {
    await _pump(t, _FakeSvc(_state()));

    expect(find.text('Play Store'), findsOneWidget);
    expect(find.text('Build, upload and submit to Google Play — no manual steps.'),
        findsOneWidget);
    expect(find.text('Live on Google Play'), findsOneWidget);
    expect(find.text('Next release'), findsOneWidget);
    expect(find.text('Release notes for testers and Play (en-US)'), findsOneWidget);
    expect(find.text('Recent publishes'), findsOneWidget);
    expect(find.text('Auto-publish'), findsOneWidget);
    // all three controls are on the screen at once
    expect(find.text('Test now'), findsOneWidget);
    expect(find.text('Publish update'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('the track panel prints the Play API answer and its as-of time',
      (t) async {
    await _pump(t, _FakeSvc(_state()));

    expect(find.text('Internal testing'), findsOneWidget);
    expect(find.text('Production'), findsOneWidget);
    expect(find.text('1.3.11 (24)'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('Full rollout'), findsOneWidget);
    // an empty track prints the backend's line, never a blank or a guess
    expect(find.text('No release on this track.'), findsOneWidget);
    expect(find.text('As of 20 Aug, 01:02 AM IST'), findsOneWidget);
  });

  testWidgets('a rollout percentage is the backend string, not a number we format',
      (t) async {
    await _pump(
      t,
      _FakeSvc(_state(tracks: [
        _track('production', 'Production',
            version: '1.3.12 (25)',
            status: 'Rolling out',
            tone: 'info',
            rollout: '10% rollout'),
      ])),
    );
    expect(find.text('10% rollout'), findsOneWidget);
    expect(find.text('Rolling out'), findsOneWidget);
  });

  testWidgets('never read from Play says so, and a read error prints verbatim',
      (t) async {
    const body = 'HTTP 403\n{"error":{"message":"The caller does not have permission"}}';
    await _pump(
      t,
      _FakeSvc(_state(tracks: const [], tracksAsOf: null, tracksError: body)),
    );
    expect(find.text('Not read from Play yet.'), findsOneWidget);
    expect(find.text(body), findsOneWidget);
  });

  testWidgets('Refresh from Play asks the backend, it does not call Play itself',
      (t) async {
    final svc = _FakeSvc(_state());
    await _pump(t, svc);
    await t.tap(find.text('Refresh from Play'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(svc.refreshes, 1);
  });

  testWidgets('draft notes pre-fill the field and Test now sends them as typed',
      (t) async {
    final svc = _FakeSvc(_state());
    await _pump(t, svc);

    final field = find.byType(TextField);
    expect((t.widget<TextField>(field).controller!).text,
        '• Faster, clearer browsing — product pages, search and cart.');

    await t.enterText(field, '• Sign-in fixes.');
    await t.tap(find.text('Test now'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    expect(svc.tested, isNotNull);
    expect(svc.tested!['notes'], '• Sign-in fixes.');
    expect(svc.promoted, isNull, reason: 'Test now must never publish');
  });

  testWidgets('can_promote:false greys the button and prints the backend reason',
      (t) async {
    final svc = _FakeSvc(_state());
    await _pump(t, svc);

    expect(find.text('Nothing on internal testing yet. Tap Test now first.'),
        findsOneWidget);
    final btn = t.widget<OutlinedButton>(
        find.ancestor(of: find.text('Publish update'), matching: find.byType(OutlinedButton)));
    expect(btn.onPressed, isNull, reason: 'the backend said there is nothing to promote');
  });

  testWidgets('Publish update carries only the notes — the backend picks the build',
      (t) async {
    final svc = _FakeSvc(_state(
      canPromote: true,
      promoteNote: 'Ready to publish: 1.3.12 (25) from internal testing.',
    ));
    await _pump(t, svc);

    expect(find.text('Ready to publish: 1.3.12 (25) from internal testing.'),
        findsOneWidget);
    await t.enterText(find.byType(TextField), '• Tested build.');
    await t.tap(find.text('Publish update'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    expect(svc.promoted, isNotNull);
    expect(svc.promoted!['notes'], '• Tested build.');
    // No track and no version code crossed the wire: promoting the wrong
    // artifact must be impossible from the client.
    expect(svc.promoted!.keys, ['notes']);
    expect(svc.tested, isNull);
  });

  testWidgets('a release in flight disables Test now and wears the backend caption',
      (t) async {
    final svc = _FakeSvc(_state(
      canTest: false,
      promoteNote: 'A release is already running.',
      active: {
        'has': true,
        'id': 7,
        'status': 'uploading',
        'status_label': 'Uploading to Play',
        'status_tone': 'info',
        'track_label': 'Internal testing',
        'release_notes': '• Speed and reliability improvements.',
      },
    ));
    await _pump(t, svc);

    // The chip label is the payload's words — not derived from 'uploading'.
    expect(find.text('Uploading to Play'), findsOneWidget);
    expect(find.text('A release is already running.'), findsOneWidget);
    final btn = t.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull, reason: 'the backend said we cannot build now');
  });

  testWidgets('the auto-publish switch shows the stored flag and sends the flip',
      (t) async {
    final svc = _FakeSvc(_state(autoPublish: false));
    await _pump(t, svc);

    expect(find.text('Off'), findsOneWidget);
    expect(find.text('OFF — builds stop at internal testing.'), findsOneWidget);
    expect(t.widget<Switch>(find.byType(Switch)).value, isFalse);

    await t.tap(find.byType(Switch));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(svc.autoSetTo, isTrue);
  });

  testWidgets('an ON flag renders as ON — the screen keeps no opinion of its own',
      (t) async {
    await _pump(t, _FakeSvc(_state(autoPublish: true)));
    expect(find.text('On'), findsOneWidget);
    expect(t.widget<Switch>(find.byType(Switch)).value, isTrue);
  });

  testWidgets('empty history shows the backend empty state, not a blank page',
      (t) async {
    await _pump(t, _FakeSvc(_state()));
    expect(find.text('Nothing published from here yet.'), findsOneWidget);
  });

  testWidgets("Google Play's error body is rendered verbatim", (t) async {
    const body =
        'Version code 24 has already been used. Try another version code.';
    await _pump(
      t,
      _FakeSvc(_state(history: [
        {
          'id': 3,
          'version_label': '1.3.11 (24)',
          'track_label': 'Production',
          'kind_label': 'Promoted',
          'when_label': '19 Aug 2026, 11:20 PM IST',
          'status': 'failed',
          'status_label': 'Failed',
          'status_tone': 'error',
          'play_error': body,
        },
      ])),
    );

    expect(find.text('Google Play said'), findsOneWidget);
    expect(find.text(body), findsOneWidget);
    expect(find.text('Failed'), findsOneWidget);
    // the backend says how the release got there; Dart does not infer it
    expect(find.text('Promoted'), findsOneWidget);
  });

  testWidgets('history renders in payload order, never re-sorted', (t) async {
    await _pump(
      t,
      // No tracks: the default fixture already shows 1.3.11 (24) on production,
      // and this test needs each version label to appear exactly once.
      _FakeSvc(_state(tracks: const [], history: [
        {
          'id': 1,
          'version_label': '1.3.12 (25)',
          'track_label': 'Production',
          'kind_label': 'Promoted',
          'when_label': 'b',
          'status': 'submitted',
          'status_label': 'Submitted for review',
          'status_tone': 'success',
          'review_status': 'inProgress: 25 (1.3.12)',
        },
        {
          'id': 2,
          'version_label': '1.3.11 (24)',
          'track_label': 'Internal testing',
          'kind_label': 'Built',
          'when_label': 'a',
          'status': 'failed',
          'status_label': 'Failed',
          'status_tone': 'error',
        },
      ])),
    );

    final first = t.getTopLeft(find.text('1.3.12 (25)'));
    final second = t.getTopLeft(find.text('1.3.11 (24)'));
    expect(first.dy, lessThan(second.dy));
    // The review status is Play's own words, printed as sent.
    expect(find.text('inProgress: 25 (1.3.12)'), findsOneWidget);
  });
}
