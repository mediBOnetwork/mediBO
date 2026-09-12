// CMD #429 — the paper sale pad renders the backend's reading and judges nothing.
//
// The pinned contract, on a surface where getting it wrong invents a sale:
//   * what the counter WROTE is what is shown. The matched product name appears
//     UNDER the handwriting, never instead of it — a pharmacist checking a line
//     must see their own words
//   * an unreadable line is drawn with the backend's own flag and its own tone.
//     Hiding it is the failure this pad exists to prevent
//   * an assumed quantity says it is assumed; nothing silently defaults
//   * a line already counted from an earlier photo of the same running page is
//     labelled as such by the BACKEND (`is_new:false`) — Dart never dedupes
//   * `can_confirm` is a backend flag: a page still in review offers no button
//     that would move stock
//   * the "this is not a bill" sentence is on both surfaces, verbatim
//   * the closing nudge switch reflects the payload and sends the toggle back
//   * a refusal renders the backend's message
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/paper_sale_screen.dart';
import 'package:pharma_b2b/services/paper_sale_api.dart';
import 'package:pharma_b2b/utils/render_log.dart';

const _notInvoice =
    'A paper sale updates your stock only. It is not a bill and it does not '
    'go into your GST return — use the counter app for that.';

Map<String, dynamic> _home() => {
  'ok': true,
  'title': 'Paper sales',
  'subtitle': 'Photograph the page you already write on',
  'today': {
    'label': 'Today',
    'lines': '5',
    'units': '11',
    'summary': '5 lines · 11 units today',
  },
  'actions': [
    {'key': 'page', 'label': 'Photograph the page', 'primary': true},
    {'key': 'tally', 'label': 'Re-shoot a running page'},
    {'key': 'typed', 'label': 'Type it instead'},
  ],
  'sheets': [
    {
      'sheet_id': 's-review',
      'date_label': '01 Sep 2026',
      'status': 'review',
      'chip': {'label': 'Check this', 'tone': 'warning'},
      'lines_label': '6 lines',
      'new_label': null,
      'reason': '4 lines need your eyes',
      'mode': 'page',
    },
    {
      'sheet_id': 's-tally',
      'date_label': '01 Sep 2026',
      'status': 'confirmed',
      'chip': {'label': 'Stock updated', 'tone': 'success'},
      'lines_label': '2 lines',
      'new_label': '1 new since the last photo',
      'mode': 'tally',
    },
  ],
  'empty': null,
  'settings': {
    'nudge_enabled': false,
    'nudge_at': '21:00',
    'nudge_label': 'Remind me to close the day',
    'nudge_help':
        'One reminder, only on a day you have not closed. Off unless you turn it on.',
  },
  'graduation': null,
  'not_an_invoice': _notInvoice,
};

Map<String, dynamic> _sheet({bool canConfirm = true}) => {
  'ok': true,
  'sheet': {
    'sheet_id': 's-review',
    'status': 'review',
    'mode': 'page',
    'date_label': '01 Sep 2026',
    'lines_label': '6 lines',
    'reason': '4 lines need your eyes',
    'can_confirm': canConfirm,
  },
  'confirm_label': 'Update my stock',
  'close_label': 'Close my day',
  'not_an_invoice': _notInvoice,
  'shots': [
    {'shot_no': 1, 'bucket': 'stock-imports', 'path': 'shop/p1.jpg'},
  ],
  'lines': [
    {
      'line_id': 'l1',
      'line_no': 1,
      'seen': 'Dolo 650',
      'product': 'Dolo 650 Tablet',
      'qty_label': '4',
      'qty_assumed': false,
      'chip': {'label': null, 'tone': 'success'},
      'flag': 'ok',
      'needs_review': false,
      'is_new': true,
      'match_label': 'Matched by alias · 100%',
    },
    {
      'line_id': 'l2',
      'line_no': 2,
      'seen': 'Could not read this line',
      'qty_label': '—',
      'chip': {'label': 'Could not read', 'tone': 'danger'},
      'flag': 'unreadable',
      'needs_review': true,
      'is_new': true,
    },
    {
      'line_id': 'l3',
      'line_no': 3,
      'seen': 'mtk lc',
      'qty_label': '2',
      'qty_assumed': true,
      'qty_note': 'Quantity assumed from what you usually sell — check it',
      'chip': {'label': 'Please check', 'tone': 'warning'},
      'flag': 'low_confidence',
      'needs_review': true,
      'is_new': true,
    },
    {
      'line_id': 'l4',
      'line_no': 4,
      'seen': 'Zerodol SP',
      'product': 'Zerodol SP Tablet',
      'qty_label': '8',
      'chip': {'label': 'More than the shelf holds', 'tone': 'warning'},
      'flag': 'over_ledger',
      'needs_review': true,
      'is_new': true,
      'on_hand_label': '3 on the shelf',
      'short_label': '5 more than the shelf knows about',
      'offer_opening': true,
      'offer_opening_label': 'Add it to my stock',
    },
    {
      'line_id': 'l5',
      'line_no': 5,
      'seen': 'Dolo 650',
      'product': 'Dolo 650 Tablet',
      'qty_label': '4',
      'chip': {'label': null, 'tone': 'success'},
      'flag': 'ok',
      'needs_review': false,
      'is_new': false,
      'counted_note': 'Already counted from an earlier photo',
    },
  ],
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  setUp(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    v.physicalSize = const Size(1200, 4000);
    v.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final v = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .views
        .first;
    v.resetPhysicalSize();
    v.resetDevicePixelRatio();
  });

  Future<List<List<Object?>>> pump(
    WidgetTester tester,
    Map<String, dynamic> Function(String fn, Map<String, dynamic> p) answer,
  ) async {
    final calls = <List<Object?>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PaperSaleScreen(
          rpc: (fn, p) async {
            calls.add([fn, p]);
            return answer(fn, p);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return calls;
  }

  testWidgets('the pad says what it is NOT, in the backend\'s words', (t) async {
    await pump(t, (fn, p) => _home());
    expect(find.text(_notInvoice), findsOneWidget);
  });

  testWidgets('today is the payload\'s sentence, never a Dart sum', (t) async {
    await pump(t, (fn, p) => _home());
    expect(find.text('5 lines · 11 units today'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('three ways in, in payload order, and the tally page says how '
      'many lines are new', (t) async {
    await pump(t, (fn, p) => _home());
    expect(find.text('Photograph the page'), findsOneWidget);
    expect(find.text('Re-shoot a running page'), findsOneWidget);
    expect(find.text('Type it instead'), findsOneWidget);
    expect(find.text('1 new since the last photo'), findsOneWidget);
  });

  testWidgets('the closing nudge is off in the payload and the toggle sends '
      'the backend the change', (t) async {
    final calls = await pump(t, (fn, p) => _home());
    final sw = t.widget<Switch>(find.byType(Switch));
    expect(sw.value, isFalse);
    calls.clear();
    await t.tap(find.byType(Switch));
    await t.pumpAndSettle();
    final call = calls.firstWhere((c) => c[0] == 'paper_sale_settings_set');
    expect(((call[1] as Map)['p_patch'] as Map)['nudge_enabled'], true);
  });

  testWidgets('what was WRITTEN is shown, with the matched product under it — '
      'never instead of it', (t) async {
    await pump(t, (fn, p) => fn == 'paper_sale_sheet_get' ? _sheet() : _home());
    await t.tap(find.text('01 Sep 2026').first);
    await t.pumpAndSettle();
    expect(find.text('mtk lc'), findsOneWidget);
    expect(find.text('Zerodol SP'), findsOneWidget);
    expect(find.text('Zerodol SP Tablet'), findsOneWidget);
  });

  testWidgets('an unreadable line is DRAWN with the backend\'s flag, and its '
      'quantity is the backend\'s dash — never a zero', (t) async {
    await pump(t, (fn, p) => fn == 'paper_sale_sheet_get' ? _sheet() : _home());
    await t.tap(find.text('01 Sep 2026').first);
    await t.pumpAndSettle();
    expect(find.text('Could not read this line'), findsOneWidget);
    expect(find.text('Could not read'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('an assumed quantity says so', (t) async {
    await pump(t, (fn, p) => fn == 'paper_sale_sheet_get' ? _sheet() : _home());
    await t.tap(find.text('01 Sep 2026').first);
    await t.pumpAndSettle();
    expect(
      find.text('Quantity assumed from what you usually sell — check it'),
      findsOneWidget,
    );
  });

  testWidgets('over-ledger shows the shortfall and offers the opening-stock '
      'correction, which sends the line id', (t) async {
    final calls = await pump(
      t,
      (fn, p) => fn == 'paper_sale_sheet_get' ? _sheet() : _home(),
    );
    await t.tap(find.text('01 Sep 2026').first);
    await t.pumpAndSettle();
    expect(find.text('3 on the shelf'), findsOneWidget);
    expect(find.text('5 more than the shelf knows about'), findsOneWidget);
    calls.clear();
    await t.tap(find.text('Add it to my stock'));
    await t.pumpAndSettle();
    final call = calls.firstWhere((c) => c[0] == 'paper_sale_seed_opening');
    expect((call[1] as Map)['p_line_id'], 'l4');
  });

  testWidgets('a line already counted from an earlier photo is labelled by the '
      'BACKEND — Dart dedupes nothing', (t) async {
    await pump(t, (fn, p) => fn == 'paper_sale_sheet_get' ? _sheet() : _home());
    await t.tap(find.text('01 Sep 2026').first);
    await t.pumpAndSettle();
    expect(find.text('Already counted from an earlier photo'), findsOneWidget);
    // Both "Dolo 650" lines are still drawn: the payload sent two, so two show.
    expect(find.text('Dolo 650'), findsNWidgets(2));
  });

  testWidgets('can_confirm:false offers no button that would move stock',
      (t) async {
    await pump(
      t,
      (fn, p) => fn == 'paper_sale_sheet_get'
          ? _sheet(canConfirm: false)
          : _home(),
    );
    await t.tap(find.text('01 Sep 2026').first);
    await t.pumpAndSettle();
    expect(find.text('Update my stock'), findsNothing);
    expect(find.text('Close my day'), findsNothing);
  });

  testWidgets('confirming sends the sheet id and shows the backend\'s message',
      (t) async {
    final seen = <List<Object?>>[];
    await t.pumpWidget(
      MaterialApp(
        home: PaperSaleScreen(
          rpc: (fn, p) async {
            seen.add([fn, p]);
            if (fn == 'paper_sale_sheet_get') return _sheet();
            if (fn == 'paper_sale_confirm') {
              return {
                'ok': true,
                'lines': 5,
                'units': 11,
                'message': '5 lines, 11 units off your shelf',
              };
            }
            return _home();
          },
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('01 Sep 2026').first);
    await t.pumpAndSettle();
    await t.tap(find.text('Update my stock'));
    await t.pumpAndSettle();
    final call = seen.lastWhere((c) => c[0] == 'paper_sale_confirm');
    expect((call[1] as Map)['p_sheet_id'], 's-review');
    expect(find.text('5 lines, 11 units off your shelf'), findsOneWidget);
  });

  testWidgets('an empty pad prints the backend\'s empty line', (t) async {
    await pump(t, (fn, p) => {
      ..._home(),
      'sheets': const [],
      'empty': 'No pages yet. Photograph today\'s sale sheet and your stock '
          'updates itself.',
    });
    expect(find.textContaining('No pages yet.'), findsOneWidget);
  });

  testWidgets('a refusal renders the backend\'s message', (t) async {
    await pump(t, (fn, p) => {
      'ok': false,
      'error': 'not_a_pharmacy',
      'message': 'Paper sales is for a pharmacy account.',
    });
    expect(find.text('Paper sales is for a pharmacy account.'), findsOneWidget);
  });

  test('the entry button exists only because the backend said show', () async {
    PaperSaleEntry.value.value = const {};
    await PaperSaleEntry.load(rpc: (fn, p) async => {'ok': false});
    expect(PaperSaleEntry.show, isFalse);

    await PaperSaleEntry.load(
      rpc: (fn, p) async => {
        'ok': true,
        'show': true,
        'label': 'Paper sales',
        'badge': '3',
        'route_key': 'paper_sale',
      },
    );
    expect(PaperSaleEntry.show, isTrue);
    expect(PaperSaleEntry.value.value['badge'], '3');
  });

  test('a thrown entry call is a button that is not drawn, never a crash',
      () async {
    PaperSaleEntry.value.value = const {};
    await PaperSaleEntry.load(rpc: (fn, p) async => throw Exception('offline'));
    expect(PaperSaleEntry.show, isFalse);
  });

  test('the page fingerprint is stable and distinguishes different bytes',
      () async {
    final a = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final b = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final c = Uint8List.fromList(List<int>.generate(64, (i) => 63 - i));
    // The same page photographed twice must hash the same, or the backend can
    // never refuse it as a duplicate.
    expect(PaperSaleApi.pageHash(a), PaperSaleApi.pageHash(b));
    expect(PaperSaleApi.pageHash(a), isNot(PaperSaleApi.pageHash(c)));
  });
}
