// PROTECTED — CHANGE #687 · feature_gaps #68.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes response-deadline behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the response countdown is the backend's, entirely:
//
//   1. **ABSENCE IS A FLAG, NOT A MISSING TIMESTAMP.** `has:false` draws
//      nothing at all. That single field covers three different real states —
//      the order was already answered, the inquiry is settled, and the row
//      predates #687 and therefore carries no clock (accept_due_at NULL on all
//      48 historical supplier_orders). The widget must never look at
//      deadline_at, compare it to DateTime.now(), or infer "no deadline" from
//      an empty string.
//
//   2. **NO DURATION MATHS IN DART.** `value_label` ("7m 11s") and
//      `deadline_label` ("Reply by 10:29 AM") arrive finished and IST-correct
//      and are printed verbatim. seconds_left is carried for diagnostics only:
//      a build that renders `seconds_left` formatted by Dart, or that ticks a
//      local Timer down and repaints its own mm:ss, is the bug this file
//      exists to catch. The precedent is order_hours_card.dart, which prints
//      "Auto-opens in 5h 30m" the same way.
//
//   3. **THE TONE IS SENT, NEVER DERIVED.** amber-under-two-minutes and
//      red-when-late are decisions made in deadline_block(). A payload that
//      says tone:'info' with two seconds left renders info. Nothing here reads
//      `expired` or `seconds_left` to pick a colour.
//
//   4. **THE POLL RATE IS SENT TOO.** `refresh_s` is how often the surface
//      re-asks (10s near the wire, 60s when idle). A payload without one arms
//      no timer at all rather than falling back to a constant typed here — an
//      app that invents its own poll interval is an app that will hammer the
//      1 GB instance the day someone widens the window.
//
//   5. **THE EXPIRED LINE IS BACKEND COPY.** When the deadline passes, the
//      label flips to the payload's own "Overdue by" and the note under it is
//      `expired_note`. Dart never types "Time up", "expired", or "moved to the
//      next supplier".
//
//   6. **THE RESPONSE RECORD PRINTS, IT DOES NOT COMPUTE.** rate_value ("67%")
//      and median_value ("4m 12s") are strings from supplier_response_stats().
//      has:false renders nothing — a supplier who has never been asked shows
//      no rate, not "0%".
//
// Fixtures mirror deadline_block() / supplier_response_stats() exactly. No
// network, no Supabase, no timers left running past the test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/response_deadline.dart';

/// deadline_block(asked_at, deadline_at, kind, settled) — the real shape.
Map<String, dynamic> _block({
  bool has = true,
  bool expired = false,
  String tone = 'info',
  String label = 'Reply in',
  String value = '7m 11s',
  String deadlineLabel = 'Reply by 10:29 AM',
  String title = 'Response deadline',
  String expiredNote = '',
  int? refreshS = 30,
  int secondsLeft = 431,
}) =>
    <String, dynamic>{
      'has': has,
      'kind': 'inquiry',
      'title': title,
      'asked_at': '2026-09-03T04:49:17.436852+00:00',
      'deadline_at': '2026-09-03T04:59:28.436852+00:00',
      'seconds_left': secondsLeft,
      'expired': expired,
      'label': label,
      'value_label': value,
      'deadline_label': deadlineLabel,
      'expired_note': expiredNote,
      'tone': tone,
      if (refreshS != null) 'refresh_s': refreshS,
    };

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test
    // and try to reach Supabase. Same rule every protected test follows.
    RenderLog.flushEnabled = false;
  });

  group('ResponseDeadline — absence is a flag', () {
    testWidgets('has:false renders nothing at all', (t) async {
      await t.pumpWidget(_host(ResponseDeadline(block: _block(has: false))));
      expect(find.textContaining('Reply'), findsNothing);
      expect(find.byIcon(Icons.schedule), findsNothing);
    });

    testWidgets('an empty payload renders nothing — never a default clock',
        (t) async {
      await t.pumpWidget(_host(const ResponseDeadline(block: {})));
      expect(find.byIcon(Icons.schedule), findsNothing);
    });

    testWidgets('a settled order (answered) draws no countdown', (t) async {
      // supplier_po_deadline_block() returns has:false the moment accept_state
      // leaves 'pending'. The card must go quiet on that flag alone.
      await t.pumpWidget(_host(ResponseDeadline(
          block: <String, dynamic>{'has': false}, renderKey: 'po')));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('ResponseDeadline — the strings are printed, not built', () {
    testWidgets('label, value_label and deadline_label print verbatim',
        (t) async {
      await t.pumpWidget(_host(ResponseDeadline(block: _block())));
      expect(find.text('Reply in'), findsOneWidget);
      expect(find.text('7m 11s'), findsOneWidget);
      expect(find.text('Reply by 10:29 AM'), findsOneWidget);
      expect(find.text('Response deadline'), findsOneWidget);
    });

    testWidgets('seconds_left is never formatted or shown by Dart', (t) async {
      await t.pumpWidget(_host(ResponseDeadline(
          block: _block(value: 'SERVER SAID THIS', secondsLeft: 431))));
      // The one duration on screen is the backend's own string.
      expect(find.text('SERVER SAID THIS'), findsOneWidget);
      expect(find.textContaining('431'), findsNothing);
      expect(find.text('7:11'), findsNothing);
      expect(find.text('07:11'), findsNothing);
    });

    testWidgets('the value does not change on its own between frames',
        (t) async {
      // No local tick-down: pumping time forward must not repaint a new
      // duration, because this widget owns no countdown of its own.
      await t.pumpWidget(_host(ResponseDeadline(block: _block())));
      expect(find.text('7m 11s'), findsOneWidget);
      await t.pump(const Duration(seconds: 5));
      expect(find.text('7m 11s'), findsOneWidget);
    });

    testWidgets('expired flips to the backend label and prints expired_note',
        (t) async {
      await t.pumpWidget(_host(ResponseDeadline(
          block: _block(
        expired: true,
        tone: 'danger',
        label: 'Overdue by',
        value: '3m 04s',
        expiredNote: 'Time up — this item moves to the next supplier',
      ))));
      expect(find.text('Overdue by'), findsOneWidget);
      expect(find.text('3m 04s'), findsOneWidget);
      expect(find.text('Time up — this item moves to the next supplier'),
          findsOneWidget);
      // Nothing invented locally.
      expect(find.text('Expired'), findsNothing);
    });
  });

  group('ResponseDeadline — the poll rate is the backend\'s', () {
    testWidgets('refresh_s drives the re-fetch', (t) async {
      var calls = 0;
      await t.pumpWidget(_host(ResponseDeadline(
        block: _block(refreshS: 10),
        onRefresh: () async => calls++,
      )));
      expect(calls, 0);
      await t.pump(const Duration(seconds: 11));
      expect(calls, 1, reason: 'one refresh after the backend\'s own 10s');
      await t.pump(const Duration(seconds: 10));
      expect(calls, 2);
      // Tear the widget down so no Timer outlives the test.
      await t.pumpWidget(_host(const SizedBox.shrink()));
    });

    testWidgets('no refresh_s arms no timer — Dart never picks an interval',
        (t) async {
      var calls = 0;
      await t.pumpWidget(_host(ResponseDeadline(
        block: _block(refreshS: null),
        onRefresh: () async => calls++,
      )));
      await t.pump(const Duration(minutes: 5));
      expect(calls, 0);
      await t.pumpWidget(_host(const SizedBox.shrink()));
    });

    testWidgets('has:false arms no timer either', (t) async {
      var calls = 0;
      await t.pumpWidget(_host(ResponseDeadline(
        block: _block(has: false, refreshS: 5),
        onRefresh: () async => calls++,
      )));
      await t.pump(const Duration(minutes: 2));
      expect(calls, 0);
      await t.pumpWidget(_host(const SizedBox.shrink()));
    });
  });

  group('ResponseDeadlineChip — the admin row', () {
    testWidgets('prints the payload\'s own label and value', (t) async {
      await t.pumpWidget(_host(
          ResponseDeadlineChip(block: _block(label: 'Reply in', value: '2m 00s'))));
      expect(find.text('Reply in 2m 00s'), findsOneWidget);
    });

    testWidgets('has:false is an absent chip, not an empty one', (t) async {
      await t.pumpWidget(_host(ResponseDeadlineChip(block: _block(has: false))));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('ResponseStatsChip — the scorecard input', () {
    Map<String, dynamic> stats({
      bool has = true,
      String rate = '67%',
      String median = '4m 12s',
      String tone = 'warning',
    }) =>
        <String, dynamic>{
          'has': has,
          'rate_label': 'Answered in time',
          'rate_value': rate,
          'rate_tone': tone,
          'median_label': 'Typical reply time',
          'median_value': median,
        };

    testWidgets('rate and median print verbatim', (t) async {
      await t.pumpWidget(_host(ResponseStatsChip(stats: stats())));
      expect(find.text('Answered in time 67% · 4m 12s'), findsOneWidget);
    });

    testWidgets('showMedian:false drops the median, keeps the rate', (t) async {
      await t.pumpWidget(
          _host(ResponseStatsChip(stats: stats(), showMedian: false)));
      expect(find.text('Answered in time 67%'), findsOneWidget);
    });

    testWidgets('a supplier never asked shows nothing, not 0%', (t) async {
      await t.pumpWidget(_host(
          ResponseStatsChip(stats: stats(has: false, rate: '0%'))));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('deadlineOf — one reader for the key', () {
    test('pulls the block out of any payload that carries one', () {
      final accept = {'state': 'pending', 'deadline': _block()};
      expect(deadlineOf(accept)['value_label'], '7m 11s');
    });

    test('a payload without a deadline yields an empty map, never null', () {
      expect(deadlineOf({'state': 'accepted'}), isEmpty);
      expect(deadlineOf(null), isEmpty);
    });
  });
}
