// CHANGE #297 — the Notification Centre renders one payload and computes
// nothing.
//
// What these tests pin down, in the order they bit us before:
//   • every sentence on the screen is a backend string — the summary verdict,
//     the pending count line, the per-event count line and the two action
//     captions are printed, never assembled in Dart from the numbers beside
//     them;
//   • the route's state word comes from `state_label`, not from `enabled` +
//     `template_id` re-derived here;
//   • rows keep payload order and are only SLICED into audience sections;
//   • the retry button appears only when the backend says something is
//     waiting, and it is the one filled action on the screen;
//   • the test-send action carries no recipient anywhere in the widget tree —
//     the backend resolves the caller's own number, so there is nothing here
//     that could aim a test at a supplier;
//   • a refusal (not_authorized, or "that number belongs to a supplier") is
//     rendered verbatim rather than translated into a Dart sentence.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/notify_center_screen.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _payload({
  int pending = 2,
  int dead = 0,
  List<Map<String, dynamic>> alerts = const [],
  List<Map<String, dynamic>>? events,
}) =>
    {
      'ok': true,
      'heading': 'Notification Centre',
      'subheading': 'One dispatcher. WhatsApp only, for now.',
      'range_label': 'Last 24 hours',
      'summary_label': '9 sent · 1 failed · 2 waiting',
      'summary_tone': 'warn',
      'pending_label': '$pending waiting to be retried',
      'pending_count': pending,
      'dead_label': '$dead gave up after every retry',
      'dead_count': dead,
      'threshold_label':
          'An alert is raised when more than 40% of an event fails within an hour',
      'alerts_heading': 'Needs attention',
      'alerts': alerts,
      'alerts_empty': 'No event is failing right now.',
      'events_heading': 'Events',
      'events': events ??
          [
            {
              'event_key': 'order_placed',
              'title': 'Order placed',
              'audience': 'customer',
              'subtitle': 'order_placed',
              'state_label': 'Live',
              'state_tone': 'good',
              'count_label': '9 sent · 1 not delivered',
              'preview_label': 'Preview',
              'test_label': 'Send me a test',
            },
            {
              'event_key': 'sec_freeze',
              'title': 'Break-glass freeze',
              'audience': 'admin',
              'subtitle': 'Security: system frozen',
              'state_label': 'On — no template',
              'state_tone': 'warn',
              'count_label': '0 sent · 0 not delivered',
              'preview_label': 'Preview',
              'test_label': 'Send me a test',
            },
          ],
      'events_empty': 'No notification routes are configured yet.',
      'retry_label': 'Retry waiting messages',
      'channels_label': 'WhatsApp',
    };

Widget _app(Widget child) => MaterialApp(home: child);

/// The screen is a long scroll. The default 800x600 test surface would put the
/// second event card (and the retry button) off-screen, so a `findsNothing`
/// there would be measuring the viewport, not the widget tree.
Future<void> _pumpTall(WidgetTester t, Widget child) async {
  await t.binding.setSurfaceSize(const Size(1200, 3000));
  addTearDown(() => t.binding.setSurfaceSize(null));
  // A fresh key on every pump: a test that pumps the screen twice with a
  // different stub is asking for a NEW mount, and without this the element
  // tree would reuse the first State and never re-read.
  await t.pumpWidget(_app(KeyedSubtree(key: UniqueKey(), child: child)));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet({
      'notify.test_action': 'Send me a test',
      'wa_diagnosis.retry': 'Try again',
    });
  });

  group('notifyGroupByAudience', () {
    test('slices the payload order into sections without re-sorting', () {
      final rows = [
        {'audience': 'admin', 'title': 'B'},
        {'audience': 'admin', 'title': 'A'},
        {'audience': 'customer', 'title': 'Z'},
      ];
      final groups = notifyGroupByAudience(rows.cast<Map<String, dynamic>>());
      expect(groups.map((g) => g.key).toList(), ['admin', 'customer']);
      // 'B' before 'A' — the BACKEND's order survived, no alphabetical sort.
      expect(groups.first.value.map((r) => r['title']).toList(), ['B', 'A']);
      expect(groups.last.value.single['title'], 'Z');
    });

    test('an audience that reappears later opens a new section rather than '
        'silently merging — the payload order is the only truth', () {
      final groups = notifyGroupByAudience(<Map<String, dynamic>>[
        {'audience': 'customer', 'title': 'one'},
        {'audience': 'admin', 'title': 'two'},
        {'audience': 'customer', 'title': 'three'},
      ]);
      expect(groups.length, 3);
    });
  });

  testWidgets('every sentence is the backend\'s, verbatim', (t) async {
    await _pumpTall(t, NotifyCenterScreen(
      centerRpc: (_) async => _payload(),
      previewRpc: (_) async => const {},
      testSendRpc: (_) async => const {},
      retryNowRpc: () async => const {},
    ));

    expect(find.text('Notification Centre'), findsOneWidget);
    expect(find.text('9 sent · 1 failed · 2 waiting'), findsOneWidget);
    expect(find.text('2 waiting to be retried'), findsOneWidget);
    expect(
        find.text(
            'An alert is raised when more than 40% of an event fails within an hour'),
        findsOneWidget);
    expect(find.text('9 sent · 1 not delivered'), findsOneWidget);
    // The state word is the payload's, not a re-derivation of enabled/template.
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('On — no template'), findsOneWidget);
    // No alert → the backend's empty line, not a blank gap.
    expect(find.text('No event is failing right now.'), findsOneWidget);
  });

  testWidgets('the retry button appears only while the backend says something '
      'is waiting, and it is the single filled action', (t) async {
    await _pumpTall(t, NotifyCenterScreen(
      centerRpc: (_) async => _payload(pending: 0),
      previewRpc: (_) async => const {},
      testSendRpc: (_) async => const {},
      retryNowRpc: () async => const {},
    ));
    expect(find.text('Retry waiting messages'), findsNothing);
    expect(find.byType(FilledButton), findsNothing);

    await _pumpTall(t, NotifyCenterScreen(
      centerRpc: (_) async => _payload(pending: 3),
      previewRpc: (_) async => const {},
      testSendRpc: (_) async => const {},
      retryNowRpc: () async => const {},
    ));
    expect(find.text('Retry waiting messages'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
  });

  testWidgets('a dead-letter count is only shown when there is one',
      (t) async {
    await _pumpTall(t, NotifyCenterScreen(
      centerRpc: (_) async => _payload(dead: 0),
      previewRpc: (_) async => const {},
      testSendRpc: (_) async => const {},
      retryNowRpc: () async => const {},
    ));
    expect(find.text('0 gave up after every retry'), findsNothing);

    await _pumpTall(t, NotifyCenterScreen(
      centerRpc: (_) async => _payload(dead: 4),
      previewRpc: (_) async => const {},
      testSendRpc: (_) async => const {},
      retryNowRpc: () async => const {},
    ));
    expect(find.text('4 gave up after every retry'), findsOneWidget);
  });

  testWidgets('test-send carries the event key and NOTHING else — there is no '
      'recipient field anywhere on the screen', (t) async {
    String? asked;
    await _pumpTall(t, NotifyCenterScreen(
      centerRpc: (_) async => _payload(pending: 0),
      previewRpc: (_) async => const {},
      testSendRpc: (k) async {
        asked = k;
        return {'ok': true, 'message': 'Sent — check your WhatsApp in a moment.'};
      },
      retryNowRpc: () async => const {},
    ));

    // The screen offers no text input at all: a test can only ever go to the
    // number the BACKEND resolves for the caller.
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(TextFormField), findsNothing);

    await t.tap(find.text('Send me a test').first);
    await t.pump();
    expect(asked, 'order_placed');
    await t.pumpAndSettle();
    expect(find.text('Sent — check your WhatsApp in a moment.'), findsOneWidget);
  });

  testWidgets('a backend refusal is printed, not translated', (t) async {
    await _pumpTall(t, NotifyCenterScreen(
      centerRpc: (_) async => _payload(pending: 0),
      previewRpc: (_) async => const {},
      testSendRpc: (_) async => const {
        'ok': false,
        'message':
            'That number belongs to a supplier. Test messages are never sent to suppliers.',
      },
      retryNowRpc: () async => const {},
    ));
    await t.tap(find.text('Send me a test').first);
    await t.pumpAndSettle();
    expect(
        find.text(
            'That number belongs to a supplier. Test messages are never sent to suppliers.'),
        findsOneWidget);
  });

  testWidgets('an unauthorised read renders the backend page, not a throw',
      (t) async {
    await _pumpTall(t, NotifyCenterScreen(
      centerRpc: (_) async => const {
        'ok': false,
        'error': 'not_authorized',
        'message': 'Only an admin can open the Notification Centre.',
      },
      previewRpc: (_) async => const {},
      testSendRpc: (_) async => const {},
      retryNowRpc: () async => const {},
    ));
    expect(find.text('Only an admin can open the Notification Centre.'),
        findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('the preview sheet prints the server-substituted body, and its '
      'own refusal when there is nothing to show', (t) async {
    await _pumpTall(t, NotifyCenterScreen(
      centerRpc: (_) async => _payload(pending: 0),
      previewRpc: (_) async => const {
        'ok': true,
        'title': 'Order placed',
        'channel_label': 'WhatsApp',
        'status_label': 'Approved by Meta',
        'status_tone': 'good',
        'body_preview':
            'Hi Sharma Medical Store, we have received your order MB-1042.',
        'sample_note': 'Sample values — nothing is sent.',
      },
      testSendRpc: (_) async => const {},
      retryNowRpc: () async => const {},
    ));
    await t.tap(find.text('Preview').first);
    await t.pumpAndSettle();
    expect(
        find.text(
            'Hi Sharma Medical Store, we have received your order MB-1042.'),
        findsOneWidget);
    expect(find.text('Sample values — nothing is sent.'), findsOneWidget);
    expect(find.text('Approved by Meta'), findsOneWidget);
  });

  testWidgets('an open alert renders the backend body verbatim', (t) async {
    await _pumpTall(t, NotifyCenterScreen(
      centerRpc: (_) async => _payload(alerts: const [
        {
          'id': 1,
          'title': 'Order placed',
          'body': '67% not delivered — 4 of 6 in the last hour',
          'tone': 'bad',
        }
      ]),
      previewRpc: (_) async => const {},
      testSendRpc: (_) async => const {},
      retryNowRpc: () async => const {},
    ));
    expect(find.text('67% not delivered — 4 of 6 in the last hour'),
        findsOneWidget);
    expect(find.text('No event is failing right now.'), findsNothing);
  });
}
