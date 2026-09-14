// PROTECTED — CMD #1989.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the new-order popup, never to make an unrelated change
// go green.
//
// What this holds down — the popup Om asked for on 14 Sep, which replaced "a
// grey centre dialog with flat chips":
//
//   1. IT IS A SHEET, NOT A DIALOG. The popup is bottom-anchored, it has a drag
//      handle, and it can be swiped away. #1988's rule survives inside it:
//      Accept and Reject are nowhere on this surface.
//
//   2. THE RAIL AND THE PILL ARE ONE DECISION, AND IT IS THE BACKEND'S. The
//      left rail and the status pill both paint `rail_tone` / `status_tone`.
//      Dart never re-reads `paid` to pick a colour — amber unpaid, green paid
//      arrives as a word.
//
//   3. THE SHEET COMPUTES NOTHING. Shop name, order code, amount, item count,
//      the three-item preview, the age and both button/pill words are printed
//      verbatim. Nothing here formats money, counts items, joins names or
//      subtracts two clocks.
//
//   4. EXACTLY ONE ACTION. One full-width primary button, its word the
//      backend's, and no second button competing with it.
//
//   5. ABSENCE IS ABSENCE. An empty string draws nothing — never "₹", never
//      "ago" on its own, never an empty pill.
//
//   6. IT FITS A PHONE. 320 / 360 / 412 / 480 with no overflow, and the
//      primary button clears 44px.
//
// Fixtures mirror order_alert_sheet() verbatim. No network, no Supabase.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/admin/order_alert_sheet.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// A fabricated order_alert_sheet() payload — the exact shape the RPC sends.
Map<String, dynamic> _sheet({
  bool paid = false,
  String more = '',
  String preview = 'Azithral 500 Tablet, Dolo 650mg Tablet, Pan-D Capsule +2 more',
  String age = '2 minutes ago',
  String code = 'CPO140926CHA101O1',
  String amount = '₹4,820.00',
  String items = '5 items',
}) =>
    {
      'ok': true,
      'show': true,
      'count': 1,
      'alert_id': 1,
      'order_id': 'ord-1989',
      'shop_name': 'Chandra Medicals',
      'order_code': code,
      'amount_display': amount,
      'items_label': items,
      'item_count': 5,
      'items_preview': preview,
      'age_label': age,
      'status_label': paid ? 'Paid' : 'Unpaid',
      'status_tone': paid ? 'success' : 'warning',
      'rail_tone': paid ? 'success' : 'warning',
      'paid': paid,
      'primary_label': 'Open order',
      'more_label': more,
      'ring': true,
      'opened': false,
      'refresh_s': 30,
      'poll_s': 20,
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> s,
    {VoidCallback? onOpen, double width = 360, Brightness? brightness}) async {
  if (brightness != null) Ds.setBrightness(brightness);
  tester.view.physicalSize = Size(width, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => Ds.setBrightness(Brightness.light));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: OrderAlertSheet(sheet: s, onOpen: onOpen ?? () {}),
      ),
    ),
  ));
}

/// The rail is the only full-height coloured box on the sheet, and it is thin.
Color? _railColour(WidgetTester tester) {
  final boxes = tester.widgetList<Container>(find.descendant(
      of: find.byType(OrderAlertSheet), matching: find.byType(Container)));
  for (final c in boxes) {
    if (c.color != null) return c.color;
  }
  return null;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('CMD #1989 — the new-order popup is a designed bottom sheet', () {
    testWidgets('1. it is a sheet with a drag handle, and Accept / Reject are '
        'nowhere on it', (tester) async {
      // The payload deliberately carries the order screen's words, to prove the
      // sheet ignores them rather than simply never seeing them.
      final s = _sheet()
        ..['accept_label'] = 'Accept'
        ..['reject_label'] = 'Reject';
      await _pump(tester, s);
      expect(find.byType(OrderAlertSheet), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Reject'), findsNothing);
      // The handle: a short, wide, rounded bar above everything else.
      final sheetBox = tester.getRect(find.byType(OrderAlertSheet));
      final handle = tester.widgetList<Container>(find.descendant(
          of: find.byType(OrderAlertSheet),
          matching: find.byType(Container)));
      expect(
          handle.any((c) =>
              c.constraints == null &&
              (c.decoration is BoxDecoration) &&
              ((c.decoration as BoxDecoration).borderRadius != null)),
          isTrue,
          reason: 'no drag handle on the sheet');
      expect(sheetBox.width, lessThanOrEqualTo(360.0));
    });

    testWidgets('2. the rail is the backend tone — amber unpaid, green paid',
        (tester) async {
      await _pump(tester, _sheet());
      expect(_railColour(tester), Ds.c.warning);

      await _pump(tester, _sheet(paid: true));
      expect(_railColour(tester), Ds.c.success);
    });

    testWidgets('2b. an unknown tone falls back rather than throwing',
        (tester) async {
      final s = _sheet()
        ..['rail_tone'] = 'chartreuse'
        ..['status_tone'] = 'chartreuse';
      await _pump(tester, s);
      expect(tester.takeException(), isNull);
      expect(find.byType(OrderAlertSheet), findsOneWidget);
    });

    testWidgets('3. every string is the backend\'s, printed verbatim',
        (tester) async {
      await _pump(tester, _sheet(more: '2 more waiting'));
      expect(find.text('Chandra Medicals'), findsOneWidget);
      expect(find.text('CPO140926CHA101O1'), findsOneWidget);
      expect(find.text('₹4,820.00'), findsOneWidget);
      expect(find.text('5 items'), findsOneWidget);
      expect(
          find.text('Azithral 500 Tablet, Dolo 650mg Tablet, Pan-D Capsule +2 more'),
          findsOneWidget);
      expect(find.text('2 minutes ago'), findsOneWidget);
      expect(find.text('Unpaid'), findsOneWidget);
      expect(find.text('2 more waiting'), findsOneWidget);
    });

    testWidgets('3b. the order code is monospace, the shop name is not',
        (tester) async {
      await _pump(tester, _sheet());
      final code = tester.widget<Text>(find.text('CPO140926CHA101O1'));
      expect(code.style?.fontFamily, 'monospace');
      final shop = tester.widget<Text>(find.text('Chandra Medicals'));
      expect(shop.style?.fontFamily, isNot('monospace'));
    });

    testWidgets('4. exactly ONE button, and its word is the backend\'s',
        (tester) async {
      var opened = 0;
      await _pump(tester, _sheet(), onOpen: () => opened++);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      expect(find.text('Open order'), findsOneWidget);
      await tester.tap(find.text('Open order'));
      await tester.pump();
      expect(opened, 1);
    });

    testWidgets('5. an absent field draws nothing at all', (tester) async {
      await _pump(tester,
          _sheet(preview: '', age: '', code: '', amount: '', items: ''));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('ago'), findsNothing);
      expect(find.text('₹'), findsNothing);
      // What remains is still a usable popup: the shop, the pill, the action.
      expect(find.text('Chandra Medicals'), findsOneWidget);
      expect(find.text('Open order'), findsOneWidget);
    });

    testWidgets('6. it fits 320 / 360 / 412 / 480 and the button clears 44px',
        (tester) async {
      for (final w in [320.0, 360.0, 412.0, 480.0]) {
        await _pump(tester, _sheet(more: '3 more waiting'), width: w);
        expect(tester.takeException(), isNull, reason: 'overflow at ${w}px');
        final btn = tester.getSize(find.byType(FilledButton));
        expect(btn.height, greaterThanOrEqualTo(44.0),
            reason: 'primary button under 44px at ${w}px');
        expect(btn.width, greaterThan(w / 2),
            reason: 'primary button is not full-width at ${w}px');
      }
    });

    testWidgets('7. dark mode is the same sheet on the dark palette — no '
        'hardcoded colour survives the switch', (tester) async {
      await _pump(tester, _sheet(), brightness: Brightness.dark);
      expect(tester.takeException(), isNull);
      expect(find.text('Chandra Medicals'), findsOneWidget);
      // The rail follows the DARK token, which is a different value from light.
      expect(_railColour(tester), Ds.c.warning);
      final material = tester.widget<Material>(find
          .descendant(of: find.byType(OrderAlertSheet), matching: find.byType(Material))
          .first);
      expect(material.color, Ds.c.surface);
    });
  });
}
