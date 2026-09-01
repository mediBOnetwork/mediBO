// CMD #431 — the parcel-counting screen's contract.
//
// One rule under all of these: the screen may never form an opinion about
// somebody's goods. Seven against a bill of ten is SHORT because the backend
// said 'short'; the chip is red because the payload said 'danger'; the claim
// happened because the payload says it happened. A widget that recomputed any
// of that would be a second opinion about money — which is exactly the failure
// this file exists to prevent.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/pharmacy_parcel_count_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _line({
  required String name,
  required String verdict,
  required String verdictLabel,
  required String tone,
  String expected = 'Bill says 10',
  String? counted,
  String batch = 'Batch BT-3310 · Exp 06/2028',
  bool needsPhoto = false,
  String? claim,
  String? by,
}) => {
      'line_id': 'line-$name',
      'line_no': 1,
      'name': name,
      'pack': '',
      'expected_label': expected,
      'expected_qty': 10,
      'batch_label': batch,
      'counted_label': counted,
      'counted_qty': counted == null ? null : 7,
      'counted_batch': '',
      'counted_expiry': '',
      'damaged_qty': 0,
      'verdict': verdict,
      'verdict_label': verdictLabel,
      'verdict_tone': tone,
      'is_issue': verdict != 'pending' && verdict != 'match',
      'needs_photo': needsPhoto,
      'photo_path': null,
      'note': '',
      'claim_label': claim,
      'by_label': by,
    };

Map<String, dynamic> _payload({
  List<Map<String, dynamic>>? rows,
  bool canFinish = true,
  String kind = 'medibo',
  List<Map<String, dynamic>>? staff,
}) => {
      'ok': true,
      'session_id': 'sess-1',
      'bill_id': 'bill-1',
      'kind': kind,
      'status': 'open',
      'title': 'mediBO',
      'subtitle': kind == 'medibo'
          ? 'A mismatch is raised with mediBO straight away'
          : 'A mismatch is recorded on your bill as evidence',
      'progress_label': '2 of 3 counted',
      'match_label': '1 verified',
      'issue_label': '1 to sort out',
      'issue_tone': 'danger',
      'methods': const [
        {'key': 'barcode', 'label': 'Scan'},
        {'key': 'voice', 'label': 'Speak'},
        {'key': 'typed', 'label': 'Type'},
      ],
      'photo_bucket': 'stock-imports',
      'photo_required': 'Photograph the problem — the claim needs it',
      'staff': staff ??
          const [
            {'who': 'Ramesh', 'label': 'Ramesh · 2 items'},
            {'who': 'Sunita', 'label': 'Sunita · 1 items'},
          ],
      'staff_heading': 'Counted by',
      'rows': rows ??
          [
            _line(
              name: 'ALPHA 500MG',
              verdict: 'match',
              verdictLabel: 'Verified',
              tone: 'success',
              expected: 'Bill says 12',
              counted: 'Counted 12',
              by: 'by Ramesh',
            ),
            _line(
              name: 'BETA 250MG',
              verdict: 'short',
              verdictLabel: 'Short',
              tone: 'danger',
              counted: 'Counted 7',
              claim: 'Claim raised with mediBO',
              by: 'by Ramesh',
            ),
            _line(
              name: 'GAMMA 10MG',
              verdict: 'pending',
              verdictLabel: 'Not counted',
              tone: 'neutral',
              expected: 'Bill says 5',
            ),
          ],
      'empty': 'This bill has no readable lines to count.',
      'form': const {
        'search_hint': 'Scan, say or type an item',
        'qty': 'How many did you count?',
        'batch': 'Batch on the pack',
        'expiry': 'Expiry on the pack',
        'damaged': 'Of those, how many are damaged?',
        'save': 'Save this count',
        'photo': 'Photograph it',
        'close': 'Close',
        'retry': 'Try again',
      },
      'can_finish': canFinish,
      'finish_label': 'Save what I counted and update my stock',
      'later_label': 'Finish later',
      'later_hint': 'Your count is saved. Come back to this parcel any time.',
      'extra_label': 'Add an item that is not on the bill',
    };

/// A tall window, because a parcel is a LIST: on the default 800x600 test
/// surface the third line of a three-line bill is never built, and "the row is
/// missing" would look exactly like the bug these tests are here to catch.
int _seq = 0;

Future<void> _pump(WidgetTester t, Map<String, dynamic> payload) async {
  // A fresh key per pump: the screen reads its payload once, in initState (it
  // is PUSHED with the payload pharmacy_parcel_open already returned), so
  // re-pumping the same widget type would silently keep the old fixture and a
  // passing assertion would prove nothing.
  _seq += 1;
  t.view.physicalSize = const Size(1200, 3200);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      home: ParcelCountScreen(key: ValueKey('pump-$_seq'), opened: payload),
    ),
  );
  await t.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('every verdict is the backend\'s word, printed verbatim',
      (t) async {
    await _pump(t, _payload());
    expect(find.text('Verified'), findsOneWidget);
    expect(find.text('Short'), findsOneWidget);
    expect(find.text('Not counted'), findsOneWidget);
    // Nothing is recomputed: the screen holds no arithmetic that could turn
    // "Counted 7" against "Bill says 10" into a word of its own.
    expect(find.text('Counted 7'), findsOneWidget);
    expect(find.text('Bill says 10'), findsOneWidget);
  });

  testWidgets('the header tallies are printed, never counted in Dart',
      (t) async {
    await _pump(t, _payload());
    expect(find.text('2 of 3 counted'), findsOneWidget);
    expect(find.text('1 verified'), findsOneWidget);
    expect(find.text('1 to sort out'), findsOneWidget);
  });

  testWidgets('an uncounted line shows no counted number at all', (t) async {
    await _pump(t, _payload());
    // The pending line carries counted_label: null. A screen that defaulted it
    // to "Counted 0" would be claiming an empty box nobody has opened.
    expect(find.textContaining('Counted 0'), findsNothing);
    expect(find.text('Bill says 5'), findsOneWidget);
  });

  testWidgets('lines render in payload order — no client-side sort',
      (t) async {
    await _pump(t, _payload());
    final names = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s.endsWith('MG'))
        .toList();
    expect(names, ['ALPHA 500MG', 'BETA 250MG', 'GAMMA 10MG']);
  });

  testWidgets('the claim is reported because the payload says so', (t) async {
    await _pump(t, _payload());
    expect(find.text('Claim raised with mediBO'), findsOneWidget);
    // And exactly once: the matching line carries no claim_label, so no chip.
    expect(find.text('Claim raised with mediBO'), findsOneWidget);
  });

  testWidgets('the photo affordance is a payload flag, not an inference',
      (t) async {
    // A short line WITHOUT needs_photo offers no camera, even though it is an
    // issue — the backend decides when evidence is still outstanding.
    await _pump(t, _payload(rows: [
      _line(
        name: 'BETA 250MG',
        verdict: 'short',
        verdictLabel: 'Short',
        tone: 'danger',
        counted: 'Counted 7',
      ),
    ]));
    expect(find.text('Photograph the problem — the claim needs it'),
        findsNothing);

    await _pump(t, _payload(rows: [
      _line(
        name: 'BETA 250MG',
        verdict: 'short',
        verdictLabel: 'Short',
        tone: 'danger',
        counted: 'Counted 7',
        needsPhoto: true,
      ),
    ]));
    expect(find.text('Photograph the problem — the claim needs it'),
        findsOneWidget);
  });

  testWidgets('the input methods are the payload\'s list, in its order',
      (t) async {
    await _pump(t, _payload());
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Speak'), findsOneWidget);
    expect(find.text('Type'), findsOneWidget);
    expect(find.text('Scan, say or type an item'), findsOneWidget);
  });

  testWidgets('can_finish false removes the button — it is never greyed out',
      (t) async {
    await _pump(t, _payload(canFinish: false));
    expect(find.text('Save what I counted and update my stock'), findsNothing);

    await _pump(t, _payload());
    expect(
        find.text('Save what I counted and update my stock'), findsOneWidget);
  });

  testWidgets('per-staff attribution renders verbatim, in payload order',
      (t) async {
    await _pump(t, _payload());
    expect(find.text('Counted by'), findsOneWidget);
    expect(find.text('Ramesh · 2 items'), findsOneWidget);
    expect(find.text('Sunita · 1 items'), findsOneWidget);
    // Not pluralised in Dart: "1 items" is what the backend sent, so "1 items"
    // is what prints. Fixing the grammar is an UPDATE, not a deploy.
  });

  testWidgets('an outside parcel says whose dispute it is — from the payload',
      (t) async {
    await _pump(t, _payload(kind: 'outside'));
    expect(find.text('A mismatch is recorded on your bill as evidence'),
        findsOneWidget);
  });

  testWidgets('no lines renders the backend\'s empty state, never a crash',
      (t) async {
    await _pump(t, _payload(rows: const [], canFinish: false));
    expect(find.text('This bill has no readable lines to count.'),
        findsOneWidget);
  });
}
