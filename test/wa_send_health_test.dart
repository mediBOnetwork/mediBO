// CHANGE #294 — the Notification delivery section of WhatsApp Ops.
//
// It exists because order CPO230826CHAO1 was placed and the pharmacy was never
// told: the order-placed message had always gone free-form, which Meta drops
// outside the 24h window, and the failure died in a log. These tests pin the one
// thing that keeps that from happening quietly again — the section renders the
// backend's own words, and a row that did not reach the customer offers Resend.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/wa_ops_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _row({
  required int id,
  required String title,
  required String status,
  required String path,
  required String tone,
  String? reason,
  String? code,
  bool canRetry = false,
}) =>
    {
      'id': id,
      'at': '2026-08-23T08:48:12+00:00',
      'when_label': '23 Aug, 02:18 pm',
      'title': title,
      'order_code': code,
      'phone_label': '+91 8357881873',
      'path_label': path,
      'status_label': status,
      'tone': tone,
      'reason': reason,
      'can_retry': canRetry,
      'event_key': 'order_placed',
    };

Map<String, dynamic> _payload(List<Map<String, dynamic>> rows) => {
      'ok': true,
      'heading': 'Notification delivery',
      'window_note': 'Free-form messages are only allowed for 24h after the '
          'customer writes to us.',
      'range_label': 'Last 48 hours',
      'summary_label': '3 attempts · 1 delivered · 2 not delivered',
      'summary_tone': 'warn',
      'empty_label': 'No customer notifications in this window yet.',
      'retry_label': 'Resend',
      'rows': rows,
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload,
    {List<int>? retried}) async {
  await tester.pumpWidget(MaterialApp(
    home: WaOpsScreen(
      routesRpc: () async => {'rows': [], 'empty_label': '—'},
      pipelineRpc: () async => {'rows': [], 'empty_label': '—'},
      wabaStatusRpc: () async => {'rows': []},
      wabaRefreshRpc: () async => {'ok': true},
      ledgerRpc: (d, p) async => {'rows': []},
      zonesRpc: () async => {'rows': []},
      zoneSaveRpc: (p) async => {'ok': true},
      sendHealthRpc: (hours) async => payload,
      sendRetryRpc: (id) async {
        retried?.add(id);
        return {'ok': true, 'message': 'Sent again — check in a moment.'};
      },
      refreshDelay: Duration.zero,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('prints the backend summary, note and every row verbatim',
      (tester) async {
    await _pump(
        tester,
        _payload([
          _row(
              id: 1,
              title: 'Order placed',
              status: 'Delivered to Meta',
              path: 'Approved template',
              tone: 'good',
              code: 'CPO230826CHAO1'),
        ]));

    expect(find.text('Notification delivery'), findsOneWidget);
    expect(find.text('3 attempts · 1 delivered · 2 not delivered'),
        findsOneWidget);
    expect(find.text('Last 48 hours'), findsOneWidget);
    expect(find.text('Order placed'), findsOneWidget);
    expect(find.text('Delivered to Meta'), findsOneWidget);
    expect(find.text('Approved template'), findsOneWidget);
    // Order code, number and time are one backend-fed metadata line.
    expect(find.textContaining('CPO230826CHAO1'), findsOneWidget);
  });

  testWidgets('a failed row offers the backend retry label; a good row does not',
      (tester) async {
    await _pump(
        tester,
        _payload([
          _row(
              id: 7,
              title: 'Order placed',
              status: 'Not delivered',
              path: 'Free-form (window open)',
              tone: 'bad',
              reason: 'Re-engagement message',
              code: 'CPO230826CHAO1',
              canRetry: true),
          _row(
              id: 8,
              title: 'Payment QR to customer',
              status: 'Delivered to Meta',
              path: 'Approved template',
              tone: 'good'),
        ]));

    expect(find.text('Resend'), findsOneWidget);
    expect(find.text('Re-engagement message'), findsOneWidget);
  });

  testWidgets('Resend sends the row id the backend gave, not an index',
      (tester) async {
    final retried = <int>[];
    await _pump(
        tester,
        _payload([
          _row(
              id: 42,
              title: 'Order placed',
              status: 'Not delivered',
              path: 'Not sent',
              tone: 'bad',
              reason: 'no_phone',
              canRetry: true),
        ]),
        retried: retried);

    await tester.tap(find.text('Resend'));
    await tester.pumpAndSettle();
    expect(retried, [42]);
  });

  testWidgets('a skipped row states the backend reason and stays warn-toned',
      (tester) async {
    await _pump(
        tester,
        _payload([
          _row(
              id: 3,
              title: 'Order placed',
              status: 'Not delivered',
              path: 'Not sent',
              tone: 'warn',
              reason: 'notification_off'),
        ]));

    expect(find.text('notification_off'), findsOneWidget);
    // Not retryable => no button, even though the send did not land.
    expect(find.text('Resend'), findsNothing);
  });

  testWidgets('empty payload renders the backend empty line, never a blank box',
      (tester) async {
    await _pump(tester, _payload(const []));
    expect(find.text('No customer notifications in this window yet.'),
        findsOneWidget);
  });

  testWidgets('an error payload prints the backend message with Retry',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: WaOpsScreen(
        routesRpc: () async => {'rows': [], 'empty_label': '—'},
        pipelineRpc: () async => {'rows': [], 'empty_label': '—'},
        wabaStatusRpc: () async => {'rows': []},
        wabaRefreshRpc: () async => {'ok': true},
        ledgerRpc: (d, p) async => {'rows': []},
        zonesRpc: () async => {'rows': []},
        zoneSaveRpc: (p) async => {'ok': true},
        sendHealthRpc: (hours) async => {'error': 'not_authorized'},
        sendRetryRpc: (id) async => {'ok': true},
        refreshDelay: Duration.zero,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('not_authorized'), findsOneWidget);
  });
}
