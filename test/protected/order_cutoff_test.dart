// PROTECTED — CMD #1847.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes cut-off behaviour, never to make an unrelated change go
// green.
//
// What this holds down — the cut-off clock card is a PRINTER, and the whole
// point of the rule is that the CLOCK lives in the backend:
//
//   1. The state word and its colour are `state_label` / `state_tone`. The
//      fixture below deliberately pairs the word "Auto-cancelled" with a state
//      key of `held`, so a card that re-derives the word (or the tone) from
//      `state` fails. A tone this build has never heard of stays neutral rather
//      than throwing.
//
//   2. The countdown is the payload's own sentence. The fixture's
//      `cutoff_label` (12:00 PM) and its `countdown` (3h 20m) deliberately
//      disagree with any wall clock the test machine has, because a card that
//      subtracts `now()` from a cut-off time is exactly the bug this file
//      exists to prevent. Same for the restoration window: `window_label` is
//      printed, never counted down in Dart.
//
//   3. A BUTTON EXISTS ONLY BECAUSE THE BACKEND SENT ITS FLAG. `can_restore`
//      is the whole of "the restoration window is still open" — once the
//      window shuts the backend stops sending it and the Restore button is
//      GONE, not disabled, and not hidden by a Dart comparison of two times.
//      A flag that arrives true with an empty label renders nothing, because a
//      button with no word on it is worse than no button.
//
//   4. Every rupee is a backend string (`due_label`), and an absent chip is
//      omitted rather than dashed or zeroed: `extended_label` is '' until the
//      admin actually extends, and the card must print no placeholder for it.
//
//   5. A tap calls the parent exactly once, carrying the backend's own action
//      key and nothing else — no phone-side minutes arithmetic, no optimistic
//      state, no second RPC name invented in Dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/admin/order_alerts_screen.dart';

/// A cancelled order whose restoration window is still open. Deliberately
/// self-inconsistent: `state` says held while `state_label` says
/// "Auto-cancelled", so anything re-derived from `state` is caught.
Map<String, dynamic> _row({
  bool canRestore = true,
  bool canExtendWindow = true,
  bool canExtend = false,
  bool canCancelNow = false,
  bool canExempt = false,
  String extended = '',
  String tone = 'danger',
  String restoreLabel = 'Restore',
}) =>
    <String, dynamic>{
      'order_id': '00000000-0000-0000-0000-0000000018f7',
      'order_code': 'CPO060926CHA101O1',
      'customer': 'Chandan Medical Stores',
      'state': 'held',
      'state_label': 'Auto-cancelled',
      'state_tone': tone,
      'cutoff_label': '12:00 PM',
      'countdown': '3h 20m',
      'extended_label': extended,
      'due_label': '₹1,240.00',
      'required_label': '₹1,240.00',
      'paid_label': '₹0.00',
      'advance_ok': false,
      'reason': 'advance_not_verified_by_cutoff',
      'window_open': true,
      'window_label': '18m 04s',
      'can_restore': canRestore,
      'can_extend_window': canExtendWindow,
      'can_extend': canExtend,
      'can_cancel_now': canCancelNow,
      'can_exempt': canExempt,
      'can_unexempt': false,
      'restore_label': restoreLabel,
      'extend_window_label': '+10 min',
      'extend_label': '+10 min',
      'cancel_now_label': 'Cancel now',
      'exempt_label': 'Exempt this order',
      'unexempt_label': 'Put back on the clock',
    };

Future<List<List<Object?>>> _pump(
  WidgetTester tester,
  Map<String, dynamic> row, {
  bool busy = false,
}) async {
  final taps = <List<Object?>>[];
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: CutoffClockCard(
          item: row,
          busy: busy,
          onAction: (a, m) => taps.add([a, m]),
        ),
      ),
    ),
  ));
  return taps;
}

void main() {
  testWidgets('the state word and the countdown are printed, never derived',
      (tester) async {
    await _pump(tester, _row());

    // state_label wins over state: the fixture's state is 'held'.
    expect(find.text('Auto-cancelled'), findsOneWidget);
    expect(find.text('Payment pending'), findsNothing);

    // Both clocks are the payload's sentences.
    expect(find.text('3h 20m'), findsOneWidget);
    expect(find.text('18m 04s'), findsOneWidget);
    expect(find.text('12:00 PM'), findsOneWidget);

    // The rupee is a backend string.
    expect(find.text('₹1,240.00'), findsOneWidget);

    expect(find.text('CPO060926CHA101O1'), findsOneWidget);
    expect(find.text('Chandan Medical Stores'), findsOneWidget);
  });

  testWidgets('an absent chip is omitted, never dashed or zeroed',
      (tester) async {
    await _pump(tester, _row());
    expect(find.text('-'), findsNothing);
    expect(find.text('—'), findsNothing);
    expect(find.text('+0 min'), findsNothing);

    await _pump(tester, _row(extended: '+20 min'));
    expect(find.text('+20 min'), findsOneWidget);
  });

  testWidgets('Restore exists only while the backend sends can_restore',
      (tester) async {
    await _pump(tester, _row());
    expect(find.text('Restore'), findsOneWidget);

    // The window shut: the button is GONE, not disabled.
    await _pump(tester, _row(canRestore: false, canExtendWindow: false));
    expect(find.text('Restore'), findsNothing);
    expect(find.text('+10 min'), findsNothing);
  });

  testWidgets('a flag with no label renders nothing', (tester) async {
    await _pump(tester, _row(restoreLabel: ''));
    expect(find.text('Restore'), findsNothing);
    // The other backed button is unaffected.
    expect(find.text('+10 min'), findsOneWidget);
  });

  testWidgets('every button is one flag, and only the sent ones appear',
      (tester) async {
    await _pump(tester, _row(
      canRestore: false,
      canExtendWindow: false,
      canExtend: true,
      canCancelNow: true,
      canExempt: true,
    ));
    expect(find.text('+10 min'), findsOneWidget);
    expect(find.text('Cancel now'), findsOneWidget);
    expect(find.text('Exempt this order'), findsOneWidget);
    expect(find.text('Put back on the clock'), findsNothing);
    expect(find.text('Restore'), findsNothing);
  });

  testWidgets('a tap carries the backend action key, once', (tester) async {
    final taps = await _pump(tester, _row());
    await tester.tap(find.text('Restore'));
    await tester.pump();
    expect(taps, hasLength(1));
    expect(taps.first.first, 'restore');
    // No minutes are invented on the phone for a restore.
    expect(taps.first.last, isNull);

    final taps2 = await _pump(tester, _row(
      canRestore: false, canExtendWindow: false, canCancelNow: true));
    await tester.tap(find.text('Cancel now'));
    await tester.pump();
    expect(taps2, hasLength(1));
    expect(taps2.first.first, 'cancel_now');
  });

  testWidgets('busy freezes every action', (tester) async {
    final taps = await _pump(tester, _row(), busy: true);
    await tester.tap(find.text('Restore'), warnIfMissed: false);
    await tester.pump();
    expect(taps, isEmpty);
  });

  testWidgets('an unknown tone stays neutral instead of throwing',
      (tester) async {
    await _pump(tester, _row(tone: 'ultraviolet'));
    expect(find.text('Auto-cancelled'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final chip = tester.widget<Container>(find
        .ancestor(of: find.text('Auto-cancelled'), matching: find.byType(Container))
        .first);
    expect((chip.decoration as BoxDecoration).color, Ds.c.bg);
  });
}
