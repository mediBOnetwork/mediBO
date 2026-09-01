// cmd #435 — the admin close/reopen control decides NOTHING.
//
// The backend (`admin_supplier_closure_panel` / `admin_supplier_closure_states`)
// composes the chip, the status line, the reason line, the 90-day history line,
// both button captions and every history row. These tests pin that the widget
// prints those strings verbatim, that an absent string renders zero pixels
// instead of a Dart default, and that WHICH form appears is the payload's
// `closed` flag rather than a deduction from an end date.
//
// Fixtures are the real shapes returned by the RPCs (captured from the live
// database while building this command), deliberately worded oddly in places so
// a Dart re-render would be visible.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/supplier_closure_control.dart';

Map<String, dynamic> _openPanel() => {
      'ok': true,
      'closed': false,
      'supplier_name': 'BHARAT SALES',
      'audience': 'admin',
      'chip': {
        'value': 'open',
        'label': 'Availability',
        'bg': '#FFFFFF',
        'fg': '#374151',
        'border': '#D1D5DB',
        'show': true,
      },
      'screen_title': 'Shop availability — BHARAT SALES',
      'intro': 'Closing a shop stops every inquiry reaching it until it reopens.',
      'status_label': 'Open — receiving inquiries',
      'status_tone': 'success',
      'history_label': 'No closures in the last 90 days',
      'history_title': 'Closures in the last 90 days',
      'history_empty': 'No closures in the last 90 days',
      'close_button': 'Mark this shop closed',
      'reopen_button': 'Reopen this shop',
      'reason_hint': 'Reason (optional) — e.g. holiday, stock-taking',
      'until_hint': 'Closed until (leave blank if you do not know yet)',
      'until_pick_label': 'Pick a reopening date and time',
      'until_clear_label': 'Clear',
      'history': const [],
    };

Map<String, dynamic> _closedPanel() => {
      ..._openPanel(),
      'closed': true,
      'chip': {
        'value': 'closed',
        'label': 'Closed',
        'bg': '#FEF3C7',
        'fg': '#92400E',
        'border': '#FDE68A',
        'show': true,
      },
      'status_label': 'Closed until 03 Sep, 12:24 PM',
      'status_tone': 'warning',
      'reason_label': 'Reason: stock-taking',
      'history_label': '1 closure(s), 0 day(s) shut in the last 90 days',
      'history': const [
        {
          'id': 10,
          'label': '01 Sep – 03 Sep',
          'reason': 'stock-taking',
          'reason_label': 'Reason: stock-taking',
          'by': 'admin',
          'by_label': 'Closed by the office',
        },
      ],
    };

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Widget _panelView(Map<String, dynamic> panel,
        {DateTime? until,
        String untilDisplay = '',
        void Function(bool)? onSubmit,
        VoidCallback? onPick,
        VoidCallback? onClear}) =>
    _host(SupplierClosurePanelView(
      panel: panel,
      reason: TextEditingController(),
      until: until,
      untilDisplay: untilDisplay,
      saving: false,
      onPickUntil: onPick ?? () {},
      onClearUntil: onClear ?? () {},
      onSubmit: onSubmit ?? (_) {},
    ));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the row control is the backend chip', () {
    testWidgets('prints the chip label verbatim and is a real tap target',
        (tester) async {
      await tester.pumpWidget(_host(SupplierClosureControl(
        supplierName: 'BHARAT SALES',
        state: _closedPanel(),
        onChanged: () async {},
      )));

      expect(find.text('Closed'), findsOneWidget);
      // Not "CLOSED", not "Closed shop" — the payload's own word.
      expect(find.text('Availability'), findsNothing);
      final box = tester.getSize(find.byType(SupplierClosureControl));
      expect(box.height, greaterThanOrEqualTo(44));
    });

    testWidgets('an open shop shows the open chip, not a red state',
        (tester) async {
      await tester.pumpWidget(_host(SupplierClosureControl(
        supplierName: 'BHARAT SALES',
        state: _openPanel(),
        onChanged: () async {},
      )));
      expect(find.text('Availability'), findsOneWidget);
    });

    testWidgets('no state and a withheld chip both render nothing',
        (tester) async {
      await tester.pumpWidget(_host(Column(children: [
        SupplierClosureControl(
          supplierName: 'A',
          state: null,
          onChanged: () async {},
        ),
        SupplierClosureControl(
          supplierName: 'B',
          state: const {
            'chip': {'label': 'Closed', 'show': false}
          },
          onChanged: () async {},
        ),
      ])));
      // show:false is an ABSENCE, never a greyed-out button.
      expect(find.text('Closed'), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });
  });

  group('supplierClosureStatesOf', () {
    test('keys on the trimmed lower-case name the backend matches on', () {
      final map = supplierClosureStatesOf({
        'ok': true,
        'states': [
          {'supplier_name': '  BHARAT SALES ', 'closed': true},
          {'supplier_name': 'Shree Traders', 'closed': false},
        ],
      });
      expect(map[supplierClosureKey('bharat sales')]?['closed'], isTrue);
      expect(map[supplierClosureKey(' Shree Traders')]?['closed'], isFalse);
    });

    test('a malformed payload yields an empty map, never a throw', () {
      expect(supplierClosureStatesOf(null), isEmpty);
      expect(supplierClosureStatesOf({'states': 'nope'}), isEmpty);
      expect(supplierClosureStatesOf({'states': [
        {'supplier_name': '   '},
        'junk',
      ]}), isEmpty);
    });
  });

  group('the sheet renders the panel and nothing else', () {
    testWidgets('an OPEN shop offers the close form with backend captions',
        (tester) async {
      await tester.pumpWidget(_panelView(_openPanel()));

      expect(find.text('Shop availability — BHARAT SALES'), findsOneWidget);
      expect(find.text('Open — receiving inquiries'), findsOneWidget);
      expect(find.text('No closures in the last 90 days'), findsNWidgets(2));
      expect(find.text('Mark this shop closed'), findsOneWidget);
      expect(find.text('Pick a reopening date and time'), findsOneWidget);
      // The reopen caption exists in the payload — it must NOT be drawn while
      // the shop is open.
      expect(find.text('Reopen this shop'), findsNothing);
    });

    testWidgets('a CLOSED shop offers reopen only, with its reason and history',
        (tester) async {
      await tester.pumpWidget(_panelView(_closedPanel()));

      expect(find.text('Closed until 03 Sep, 12:24 PM'), findsOneWidget);
      expect(find.text('Reason: stock-taking'), findsNWidgets(2)); // status + history row
      expect(find.text('1 closure(s), 0 day(s) shut in the last 90 days'),
          findsOneWidget);
      expect(find.text('01 Sep – 03 Sep'), findsOneWidget);
      expect(find.text('Closed by the office'), findsOneWidget);
      expect(find.text('Reopen this shop'), findsOneWidget);
      // No reason box, no date picker, no close button while he is already shut.
      expect(find.text('Mark this shop closed'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('which form appears is `closed`, not the presence of an end date',
        (tester) async {
      // A payload that carries ends_at + a reason but says closed:false is an
      // OPEN shop with a closure in its past. The form must follow the flag.
      final p = _openPanel()
        ..['ends_at'] = '2026-09-03T06:54:45.866067+00:00'
        ..['reason'] = 'stock-taking';
      await tester.pumpWidget(_panelView(p));
      expect(find.text('Mark this shop closed'), findsOneWidget);
      expect(find.text('Reopen this shop'), findsNothing);
    });

    testWidgets('an absent string renders nothing — never a Dart default',
        (tester) async {
      final p = _openPanel()
        ..remove('intro')
        ..remove('history_label')
        ..remove('until_clear_label');
      await tester.pumpWidget(_panelView(p, until: DateTime(2026, 9, 3, 18)));

      expect(find.text('Shop availability — BHARAT SALES'), findsOneWidget);
      // The Clear button's caption was withheld: the button prints an empty
      // string rather than the word "Clear" invented here.
      expect(find.text('Clear'), findsNothing);
    });

    testWidgets('a picked reopening time replaces the picker caption',
        (tester) async {
      await tester.pumpWidget(_panelView(_openPanel(),
          until: DateTime(2026, 9, 3, 18), untilDisplay: '3 September 2026 6:00 PM'));
      expect(find.text('Pick a reopening date and time'), findsNothing);
      expect(find.text('3 September 2026 6:00 PM'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
    });

    testWidgets('the buttons submit the state the payload declared',
        (tester) async {
      final calls = <bool>[];
      await tester.pumpWidget(_panelView(_openPanel(), onSubmit: calls.add));
      await tester.tap(find.text('Mark this shop closed'));
      await tester.pump();

      await tester.pumpWidget(_panelView(_closedPanel(), onSubmit: calls.add));
      await tester.tap(find.text('Reopen this shop'));
      await tester.pump();

      expect(calls, [true, false]);
    });
  });
}
