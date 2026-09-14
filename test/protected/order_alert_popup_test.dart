// PROTECTED — CMD #2016.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes new-order-alert behaviour, never to make an unrelated
// change go green. It replaces order_alert_view_only_test.dart (#1988's strip)
// and order_alert_sheet_test.dart (#1989's bottom sheet), because #2016 is the
// change that deliberately removed both surfaces.
//
// What this file holds down:
//
//   1. NO STRIP, ANYWHERE. The in-app banner above the header is deleted, and
//      so is the RPC that fed it. If anybody reintroduces OrderAlertStrip, or
//      calls order_alert_strip() / order_alert_sheet() from Dart again, this
//      file goes red — which is the only way "no banner on any screen" stays
//      true after the screen that had it is long forgotten.
//
//   2. ONE SURFACE, AND IT IS A CENTRE POPUP. A new order reaching an open app
//      is a modal in the middle of the screen with exactly two buttons: the
//      backend's primary word and the backend's secondary word. Accept and
//      Reject are NOT on it — a decision is taken on the order screen, next to
//      the items and the amount. That rule is #1988's and it stands.
//
//   3. THE POPUP COMPUTES NOTHING. Heading, customer, money, item count, age,
//      the pill's word, both button words and the "+N more" line all arrive
//      rendered. Nothing here pluralises, formats money, counts items or
//      decides from `paid` what colour to be — the one thing Dart reads off
//      the payload is which token a NAMED TONE maps to.
//
//   4. LATER IS A DISMISSAL, NOT A DECISION. Tapping it reports `later` and
//      nothing else: the caller sends that to order_alert_popup_later(), which
//      is per-device, so the order stays in Awaiting action and the badge
//      still counts it. The popup never removes an order from anything.
//
//   5. IT FITS A PHONE. 320 / 360 / 412 px with a long customer name and long
//      backend labels: no overflow, and both tap targets stay >= 44 px.
//
// Fixtures mirror order_alert_popup() verbatim. No network, no Supabase.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/admin/order_alert_popup.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// A fabricated order_alert_popup() payload — the exact shape the RPC sends.
Map<String, dynamic> _popup({
  bool paid = false,
  String more = '',
  String customer = 'Chandra Medicals',
  String age = '2 min ago',
  String amount = '₹4,820.00',
  String items = '5 items',
  int count = 1,
  bool show = true,
}) =>
    {
      'ok': true,
      'show': show,
      'count': count,
      'alert_id': 1,
      'order_id': 'ord-2016',
      'order_code': 'CPO140926CHA101O1',
      'title': count > 1 ? 'New orders' : 'New order',
      'customer_name': customer,
      'amount_display': amount,
      'amount_caption': 'Order value',
      'items_label': items,
      'item_count': 5,
      'age_label': age,
      'status_label': paid ? 'Paid' : 'Unpaid',
      'status_tone': paid ? 'success' : 'warning',
      'paid': paid,
      'primary_label': 'Open order',
      'secondary_label': 'Later',
      'more_label': more,
      'ring': true,
      'opened': false,
      'autoshow': true,
      'refresh_s': 30,
      'poll_s': 20,
    };

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> p, {
  VoidCallback? onOpen,
  VoidCallback? onLater,
  double width = 360,
}) async {
  tester.view.physicalSize = Size(width, 780);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: OrderAlertPopup(
          popup: p,
          onOpen: onOpen ?? () {},
          onLater: onLater ?? () {},
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('1 — the strip is gone from the product', () {
    test('no Dart file mentions the strip widget or its RPCs', () {
      final offenders = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final src = f.readAsStringSync();
        for (final banned in const [
          'OrderAlertStrip',
          'order_alert_strip',
          'order_alert_sheet',
          'OrderAlertSheet',
        ]) {
          if (src.contains(banned)) offenders.add('${f.path}: $banned');
        }
      }
      expect(offenders, isEmpty,
          reason: 'CMD #2016 deleted the in-app strip and the bottom sheet. '
              'The centre popup (order_alert_popup) is the only in-app surface '
              'a new order gets:\n${offenders.join('\n')}');
    });

    test('the sheet and strip widget files no longer exist', () {
      expect(File('lib/screens/admin/order_alert_sheet.dart').existsSync(),
          isFalse);
      expect(File('lib/screens/admin/order_alert_popup.dart').existsSync(),
          isTrue);
    });
  });

  group('2 — one centre popup, two backend words, no decision', () {
    testWidgets('both buttons carry the backend labels', (tester) async {
      await _pump(tester, _popup());
      expect(find.text('Open order'), findsOneWidget);
      expect(find.text('Later'), findsOneWidget);
    });

    testWidgets('Accept and Reject are not on it', (tester) async {
      // Even when a payload carries them — order_alert_card() still does for
      // the order screen — the popup must not render a decision.
      final p = _popup()
        ..['accept_label'] = 'Accept'
        ..['reject_label'] = 'Reject';
      await _pump(tester, p);
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Reject'), findsNothing);
    });

    testWidgets('Open reports open, Later reports later', (tester) async {
      var opened = 0, later = 0;
      await _pump(tester, _popup(),
          onOpen: () => opened++, onLater: () => later++);
      await tester.tap(find.text('Open order'));
      await tester.pump();
      expect(opened, 1);
      expect(later, 0);
      await tester.tap(find.text('Later'));
      await tester.pump();
      expect(later, 1);
      expect(opened, 1);
    });

    testWidgets('it is a modal in the centre, not a row above the shell',
        (tester) async {
      await _pump(tester, _popup());
      expect(find.byType(Dialog), findsOneWidget);
    });
  });

  group('3 — the popup computes nothing', () {
    testWidgets('every string is the payload, verbatim', (tester) async {
      await _pump(
          tester,
          _popup(
              customer: 'Sri Venkateswara Medical & General Stores',
              amount: '₹1,20,455.50',
              items: '23 items',
              age: '4 hr ago'));
      expect(find.text('New order'), findsOneWidget);
      expect(
          find.text('Sri Venkateswara Medical & General Stores'), findsOneWidget);
      expect(find.text('₹1,20,455.50'), findsOneWidget);
      expect(find.text('Order value'), findsOneWidget);
      expect(find.text('23 items'), findsOneWidget);
      expect(find.text('4 hr ago'), findsOneWidget);
      expect(find.text('Unpaid'), findsOneWidget);
    });

    testWidgets('an absent field draws nothing at all', (tester) async {
      final p = _popup(age: '', more: '');
      p['amount_caption'] = '';
      await _pump(tester, p);
      expect(find.text('Order value'), findsNothing);
      // The popup still renders — an absence is not an error.
      expect(find.text('Open order'), findsOneWidget);
    });

    testWidgets('"+N more" appears only when the backend sent it',
        (tester) async {
      await _pump(tester, _popup());
      expect(find.textContaining('more'), findsNothing);

      await _pump(tester, _popup(count: 3, more: '+2 more waiting'));
      expect(find.text('+2 more waiting'), findsOneWidget);
      // And the heading is the backend's plural, never one built here.
      expect(find.text('New orders'), findsOneWidget);
    });

    testWidgets('paid is the backend TONE, never re-derived from the flag',
        (tester) async {
      // paid:true with a warning tone must paint warning. If Dart ever reads
      // `paid` to pick a colour, this goes red.
      final p = _popup(paid: true);
      p['status_tone'] = 'warning';
      p['status_label'] = 'Paid';
      await _pump(tester, p);
      final pill = tester.widget<Container>(find.ancestor(
          of: find.text('Paid'), matching: find.byType(Container)).first);
      final deco = pill.decoration as BoxDecoration;
      expect(deco.color, Ds.c.warningSoft);

      p['status_tone'] = 'success';
      await _pump(tester, p);
      final pill2 = tester.widget<Container>(find.ancestor(
          of: find.text('Paid'), matching: find.byType(Container)).first);
      expect((pill2.decoration as BoxDecoration).color, Ds.c.successSoft);
    });
  });

  group('5 — it fits a phone', () {
    for (final w in const [320.0, 360.0, 412.0, 480.0]) {
      testWidgets('no overflow at ${w.toInt()}px', (tester) async {
        await _pump(
            tester,
            _popup(
                customer: 'Sri Venkateswara Medical & General Stores, Kukatpally',
                amount: '₹12,34,567.89',
                items: '128 items',
                more: '+9 more waiting'),
            width: w);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('both tap targets clear the 44px minimum', (tester) async {
      await _pump(tester, _popup(), width: 360);
      for (final label in const ['Open order', 'Later']) {
        final box = tester.getRect(find.text(label));
        final parent = tester.getRect(find
            .ancestor(of: find.text(label), matching: find.byType(SizedBox))
            .first);
        expect(parent.height, greaterThanOrEqualTo(Ds.touch.minTarget),
            reason: '$label is ${parent.height}px tall (${box.height} text)');
      }
    });
  });
}
