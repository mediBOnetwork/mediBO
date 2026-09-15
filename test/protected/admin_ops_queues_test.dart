import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/c459_ops_queues.dart';
import 'package:pharma_b2b/screens/admin/admin_ops_queues_screen.dart';
import 'package:pharma_b2b/screens/admin/feature_gaps_screen.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/backend_error_view.dart';

/// CHANGE #459 — the Ops queues screen and the shared error state.
///
/// What this file holds down: the screen computes NOTHING. Section order, row
/// order, counts, labels, tones and which buttons exist are all backend
/// strings; an unknown layout is skipped in silence; a refusal renders the
/// backend's copy for the driver CODE and never the driver's own sentence
/// (GAP 179); and each row action fires exactly one RPC with the row's own id.
void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(const {
      'ops.title': 'Ops queues',
      'ops.refresh': 'Refresh',
      'error.42501.title': 'Admins only',
      'error.42501.body': 'This screen is for signed-in mediBO admins.',
      'error.42501.action': 'Sign in',
      'error.generic.title': 'Could not load this',
      'error.generic.body': 'Something went wrong on our side.',
      'error.generic.action': 'Try again',
      'error.network.title': 'No connection',
      'error.network.body': 'mediBO could not reach the server.',
      'error.network.action': 'Try again',
      'error.pgrst301.title': 'Session expired',
      'error.pgrst301.body': 'Your sign-in has expired.',
      'error.pgrst301.action': 'Sign in',
    });
  });

  Map<String, dynamic> payload({List<Object?>? sections}) => {
        'ok': true,
        'title': 'Ops queues',
        'subtitle': 'Everything waiting on someone, in one place.',
        'refresh_label': 'Refresh',
        'sections': sections ??
            [
              {
                'layout': 'queue',
                'key': 'open_alerts',
                'title': 'Notification failures',
                'count': 1,
                'count_label': '1 waiting',
                'tone': 'danger',
                'empty_label': 'Nothing waiting here.',
                'rows': [
                  {
                    'id': '75',
                    'title': 'order_alert_new · push',
                    'subtitle': '68% of 25 failed',
                    'age_label': 'Open since 01 Sep, 03:32 PM',
                    'state_label': 'Open',
                    'state_tone': 'warning',
                    'quiet_label': 'No sends in the last window — still open',
                    'can_ack': true,
                    'ack_label': 'Acknowledge',
                  },
                ],
              },
              {
                'layout': 'queue',
                'key': 'oos_followups',
                'title': 'Out-of-stock follow-ups',
                'count': 2,
                'count_label': '2 waiting',
                'tone': 'warning',
                'empty_label': 'Nothing waiting here.',
                'rows': [
                  {
                    'id': '544',
                    'title': 'Jolavi Tablet',
                    'subtitle': 'ANAND PHARMA',
                    'age_label': '21 days overdue',
                    'ask_label': 'Asked 1×, last on 11 Aug',
                    'state_label': 'Asked, no reply',
                    'state_tone': 'warning',
                    'can_resend': true,
                    'resend_label': 'Ask again',
                    'close_label': 'Close follow-up',
                  },
                  {
                    'id': '538',
                    'title': 'Telmed-AH Tablet',
                    'age_label': '21 days overdue',
                    'state_label': 'Asked, no reply',
                    'state_tone': 'warning',
                  },
                ],
              },
              {
                'layout': 'strip',
                'key': 'po_integrity',
                'title': 'Inquiry → PO date integrity',
                'banner_label': 'Every linked line sits on a PO for its own date',
                'banner_tone': 'success',
                'rows': [
                  {
                    'label': 'Cross-date pointers',
                    'value': '0',
                    'tone': 'success',
                    'detail': 'Must always be zero.',
                  },
                ],
              },
            ],
      };

  Widget host(
    Future<Map<String, dynamic>> Function() load, {
    Future<Map<String, dynamic>> Function(String, String)? act,
  }) =>
      MaterialApp(
        home: AdminOpsQueuesScreen(
          loadRpc: load,
          actionRpc: act ?? (a, i) async => const {'ok': true, 'message': ''},
        ),
      );

  testWidgets('sections render in PAYLOAD order, not alphabetical',
      (tester) async {
    // A tall surface so all three sections are laid out at once — the point of
    // the test is their ORDER, not the ListView's lazy build.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(() async => payload()));
    await tester.pumpAndSettle();

    final alerts = tester.getTopLeft(find.text('Notification failures')).dy;
    final oos = tester.getTopLeft(find.text('Out-of-stock follow-ups')).dy;
    final po = tester.getTopLeft(find.text('Inquiry → PO date integrity')).dy;
    // The fixture is deliberately NOT alphabetical: I < N < O would invert it.
    expect(alerts < oos, isTrue);
    expect(oos < po, isTrue);
  });

  testWidgets('rows render in payload order and print backend labels verbatim',
      (tester) async {
    await tester.pumpWidget(host(() async => payload()));
    await tester.pumpAndSettle();

    expect(find.text('1 waiting'), findsOneWidget);
    expect(find.text('2 waiting'), findsOneWidget);
    expect(find.text('21 days overdue'), findsNWidgets(2));
    expect(find.text('Asked 1×, last on 11 Aug'), findsOneWidget);
    expect(find.text('No sends in the last window — still open'), findsOneWidget);

    final first = tester.getTopLeft(find.text('Jolavi Tablet')).dy;
    final second = tester.getTopLeft(find.text('Telmed-AH Tablet')).dy;
    expect(first < second, isTrue);
  });

  testWidgets('a button exists only when the payload sent its flag AND label',
      (tester) async {
    await tester.pumpWidget(host(() async => payload()));
    await tester.pumpAndSettle();

    // Row 544 carries can_resend + both labels; row 538 carries neither.
    expect(find.text('Ask again'), findsOneWidget);
    expect(find.text('Close follow-up'), findsOneWidget);
    expect(find.text('Acknowledge'), findsOneWidget);
    // Nothing invented for the bare row.
    expect(find.text('Rescan'), findsNothing);
  });

  testWidgets('an action fires ONE rpc carrying that row own id', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(host(
      () async => payload(),
      act: (action, id) async {
        calls.add('$action:$id');
        return {'ok': true, 'message': 'A fresh form was sent to ANAND PHARMA.'};
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ask again'));
    await tester.pumpAndSettle();

    expect(calls, ['resend:544']);
    // The toast is the backend's sentence, not a Dart one.
    expect(find.text('A fresh form was sent to ANAND PHARMA.'), findsOneWidget);
  });

  testWidgets('a layout this build has never heard of is skipped in silence',
      (tester) async {
    await tester.pumpWidget(host(() async => payload(sections: [
          {'layout': 'hologram', 'key': 'future', 'title': 'From the future'},
          {
            'layout': 'queue',
            'key': 'oos_followups',
            'title': 'Out-of-stock follow-ups',
            'count_label': '0',
            'empty_label': 'Nothing waiting here.',
            'rows': const [],
          },
        ])));
    await tester.pumpAndSettle();

    expect(find.text('From the future'), findsNothing);
    expect(find.text('Out-of-stock follow-ups'), findsOneWidget);
    expect(find.text('Nothing waiting here.'), findsOneWidget);
  });

  testWidgets('ok:false renders the backend copy for the code, and no retry',
      (tester) async {
    await tester.pumpWidget(host(() async => {
          'ok': false,
          'error': 'admin_only',
          'code': '42501',
          'message': 'This screen is for signed-in mediBO admins.',
        }));
    await tester.pumpAndSettle();

    expect(find.text('Admins only'), findsOneWidget);
    expect(find.text('This screen is for signed-in mediBO admins.'),
        findsOneWidget);
    // A refusal is not retryable, so the screen offers no action at all.
    expect(find.text('Sign in'), findsNothing);
    expect(find.text('Try again'), findsNothing);
  });

  testWidgets('GAP 179 — a thrown PostgrestException never reaches the screen',
      (tester) async {
    await tester.pumpWidget(host(() async {
      throw _FakePostgrestException(
        'permission denied for function feature_gaps_list',
        '42501',
      );
    }));
    await tester.pumpAndSettle();

    expect(find.text('Admins only'), findsOneWidget);
    // The exact string the register row screenshotted must appear nowhere.
    expect(
      find.textContaining('permission denied for function'),
      findsNothing,
    );
    expect(find.textContaining('PostgrestException'), findsNothing);
  });

  testWidgets('a transient failure is retryable and re-calls the rpc',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(host(() async {
      attempts++;
      if (attempts == 1) throw _FakePostgrestException('boom', 'XX000');
      return payload();
    }));
    await tester.pumpAndSettle();

    expect(find.text('Could not load this'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.text('Notification failures'), findsOneWidget);
  });

  testWidgets(
      'GAP 179 at its own site — /admin/feature-gaps prints backend copy, '
      'not the driver sentence it was screenshotted printing', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FeatureGapsScreen(
        listRpc: (params) async => throw _FakePostgrestException(
          'permission denied for function feature_gaps_list',
          '42501',
        ),
        statusRpc: (id, status) async => const {'ok': true},
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Admins only'), findsOneWidget);
    // The literal string the register's headless capture found centred on the
    // page must appear nowhere, in any form.
    expect(find.textContaining('permission denied for function'), findsNothing);
    expect(find.textContaining('PostgrestException'), findsNothing);
    expect(find.textContaining('42501'), findsNothing);
  });

  group('BackendError — the code decides the copy, never the message', () {
    test('42501 is a refusal; an unknown code is generic', () {
      expect(BackendError.fromCode('42501').keyPrefix, 'error.42501');
      expect(BackendError.fromCode('42501').isRefusal, isTrue);
      expect(BackendError.fromCode('XX000').keyPrefix, 'error.generic');
      expect(BackendError.fromCode('XX000').isRefusal, isFalse);
      expect(BackendError.fromCode(null).keyPrefix, 'error.generic');
    });

    test('an expired session is its own family', () {
      expect(BackendError.fromCode('PGRST301').keyPrefix, 'error.pgrst301');
      expect(BackendError.fromCode('401').keyPrefix, 'error.pgrst301');
    });

    test('the code is read off any object, with no supabase import', () {
      expect(
        BackendError.from(_FakePostgrestException('denied', '42501')).keyPrefix,
        'error.42501',
      );
      expect(BackendError.from(Exception('plain')).keyPrefix, 'error.generic');
    });
  });

  group('OpsSection — parsing decides nothing', () {
    test('detail lines keep payload order and drop the empties', () {
      final r = OpsRow.fromJson(const {
        'id': '1',
        'title': 't',
        'subtitle': 'ANAND PHARMA',
        'qty_label': '',
        'ask_label': 'Asked 1×',
        'next_label': 'Next: pack it',
      });
      expect(r.detailLines, ['ANAND PHARMA', 'Asked 1×', 'Next: pack it']);
    });

    test('a strip section never invents queue rows, and vice versa', () {
      final strip = OpsSection.tryParse(const {
        'layout': 'strip',
        'key': 'po_integrity',
        'rows': [
          {'label': 'Linked lines', 'value': '70', 'tone': 'info'}
        ],
      })!;
      expect(strip.stripRows.single.value, '70');
      expect(strip.rows, isEmpty);

      final queue = OpsSection.tryParse(const {
        'layout': 'queue',
        'key': 'oos_followups',
        'rows': [
          {'id': '1', 'title': 'x'}
        ],
      })!;
      expect(queue.rows.single.title, 'x');
      expect(queue.stripRows, isEmpty);
    });

    test('an unknown layout parses to nothing rather than throwing', () {
      expect(OpsSection.tryParse(const {'layout': 'hologram'}), isNull);
      expect(OpsSection.tryParse('not a map'), isNull);
    });
  });
}

/// Stands in for `PostgrestException` — same duck-typed `code`/`message`, no
/// supabase import, so the suite stays on the Dart VM.
class _FakePostgrestException implements Exception {
  final String message;
  final String code;
  _FakePostgrestException(this.message, this.code);
  @override
  String toString() =>
      'PostgrestException(message: $message, code: $code, details: , hint: null)';
}
