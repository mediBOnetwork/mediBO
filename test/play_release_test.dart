// CHANGE #280 — the Play Store screen prints the backend, and nothing else.
//
// What this pins down (each was a real way to get it wrong):
//   • every heading, caption and button caption comes from play_state(); a Dart
//     literal for any of them would fail these expectations
//   • the status chip's LABEL and TONE are the payload's, never derived from
//     the status enum in Dart
//   • Google Play's error body is rendered VERBATIM — not summarised, not
//     re-worded, not "Something went wrong"
//   • `can_publish` is the backend's decision: false disables the button, and
//     the button then wears the backend's "publishing" caption
//   • history renders in payload order (the fixture is deliberately not sorted)
//   • the release-notes field is pre-filled from draft_notes and what Om types
//     is what gets sent

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/dev_queue/dev_queue_service.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/play_store_screen.dart';

/// A DevQueueService whose two Play calls answer from fixtures.
class _FakeSvc implements DevQueueService {
  _FakeSvc(this.state);
  final Map<String, dynamic> state;
  Map<String, dynamic>? sent;

  @override
  Future<Map<String, dynamic>> playState({int limit = 20}) async => state;

  @override
  Future<Map<String, dynamic>> playPublishRequest(
      {String track = 'production', String? notes}) async {
    sent = {'track': track, 'notes': notes};
    return {'ok': true, 'id': 1, 'message': 'Queued for the builder.'};
  }

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('the Play screen must call nothing else: '
          '${i.memberName}');
}

Map<String, dynamic> _state({
  bool canPublish = true,
  Map<String, dynamic>? active,
  List<Map<String, dynamic>>? history,
}) =>
    {
      'ok': true,
      'title': 'Play Store',
      'subtitle': 'Build, upload and submit to Google Play — no manual steps.',
      'live_heading': 'Live on Google Play',
      'next_heading': 'Next release',
      'history_heading': 'Recent publishes',
      'notes_heading': 'Release notes (en-US)',
      'notes_hint': 'Written automatically from what changed.',
      'error_heading': 'Google Play said',
      'empty_history': 'Nothing published from here yet.',
      'publish_button': 'Publish to Play',
      'publishing_button': 'Publishing…',
      'can_publish': canPublish,
      'live': {
        'has': true,
        'version_label': '1.3.10 (23)',
        'when_label': '19 Aug 2026, 10:48 PM IST',
        'notes': '• Speed and reliability improvements throughout the app.',
      },
      'active': active ?? {'has': false},
      'draft_notes': '• Faster, clearer browsing — product pages, search and cart.',
      'history': history ?? const [],
    };

Future<void> _pump(WidgetTester t, _FakeSvc svc) async {
  // A tall surface: the screen is one scrolling column and a ListView does not
  // build children below the fold, so the default 800×600 viewport would hide
  // the history section and make "is it rendered?" unanswerable.
  t.view.physicalSize = const Size(1200, 3200);
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
    final svc = _FakeSvc(_state());
    await _pump(t, svc);

    expect(find.text('Play Store'), findsOneWidget);
    expect(find.text('Build, upload and submit to Google Play — no manual steps.'),
        findsOneWidget);
    expect(find.text('Live on Google Play'), findsOneWidget);
    expect(find.text('1.3.10 (23)'), findsOneWidget);
    expect(find.text('19 Aug 2026, 10:48 PM IST'), findsOneWidget);
    expect(find.text('Next release'), findsOneWidget);
    expect(find.text('Release notes (en-US)'), findsOneWidget);
    expect(find.text('Recent publishes'), findsOneWidget);
    expect(find.text('Publish to Play'), findsOneWidget);
  });

  testWidgets('empty history shows the backend empty state, not a blank page',
      (t) async {
    await _pump(t, _FakeSvc(_state()));
    expect(find.text('Nothing published from here yet.'), findsOneWidget);
  });

  testWidgets('draft notes pre-fill the field and are sent as typed', (t) async {
    final svc = _FakeSvc(_state());
    await _pump(t, svc);

    final field = find.byType(TextField);
    expect(
        (t.widget<TextField>(field).controller!).text,
        '• Faster, clearer browsing — product pages, search and cart.');

    await t.enterText(field, '• Sign-in fixes.');
    await t.tap(find.text('Publish to Play'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    expect(svc.sent, isNotNull);
    expect(svc.sent!['notes'], '• Sign-in fixes.');
    expect(svc.sent!['track'], 'production');
  });

  testWidgets('can_publish:false disables the button and shows the busy caption',
      (t) async {
    final svc = _FakeSvc(_state(
      canPublish: false,
      active: {
        'has': true,
        'id': 7,
        'status': 'uploading',
        'status_label': 'Uploading to Play',
        'status_tone': 'info',
        'track_label': 'Production',
        'release_notes': '• Speed and reliability improvements.',
      },
    ));
    await _pump(t, svc);

    // The chip label is the payload's words — not derived from 'uploading'.
    expect(find.text('Uploading to Play'), findsOneWidget);
    expect(find.text('Production'), findsOneWidget);
    expect(find.text('Publishing…'), findsOneWidget);
    expect(find.text('Publish to Play'), findsNothing);

    final btn = t.widget<FilledButton>(find.byType(FilledButton));
    expect(btn.onPressed, isNull, reason: 'the backend said we cannot publish');
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
  });

  testWidgets('history renders in payload order, never re-sorted', (t) async {
    await _pump(
      t,
      _FakeSvc(_state(history: [
        {
          'id': 1,
          'version_label': '1.3.12 (25)',
          'track_label': 'Production',
          'when_label': 'b',
          'status': 'submitted',
          'status_label': 'Submitted for review',
          'status_tone': 'success',
          'review_status': 'inProgress: 25 (1.3.12)',
        },
        {
          'id': 2,
          'version_label': '1.3.11 (24)',
          'track_label': 'Internal',
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
