// PROTECTED — CMD #1815.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how a missing KYC document is shown to a customer.
//
// mediBO verifies documents BY HAND before an account is approved, so approval
// is already the answer to "may this pharmacy buy?". #705 put a second,
// automatic answer on top of it and rendered the countdown in the cart:
// "Upload your drug licence before 17 Sep 2026 to keep ordering." This file
// holds down the rule that replaced it.
//
// What this holds down:
//
//   1. The chip PRINTS. Its label, its three tone colours, its action's label
//      and its action's destination are the payload's. The fixture's label
//      deliberately disagrees with its own `state` ("Licence expired" on a
//      state of 'missing'), so a chip that re-derived any word from the state
//      fails here.
//
//   2. Absence is `has:false` — nothing at all is drawn, not an empty chip and
//      not a placeholder. An empty label is the same absence.
//
//   3. A warning is never a full-width card. With `notice.has:false` the cart
//      draws the chip and the rx record line, and no C461Notice — no title, no
//      message, no yellow block. Nothing in Dart says "to keep ordering".
//
//   4. The action is handed back VERBATIM and exactly once: the descriptor the
//      backend sent (route_key / tab_key / section) is what the screen is
//      given, so every KYC chip in the app lands on the same upload section.
//      Dart never builds a path — '/account/kyc', the route #705 shipped, was
//      a route this app has never had.
//
//   5. There is ONE profile editor. `customerMenuScreen('cust_profile_edit')`
//      resolves to My Account on the profile tab, not to a second screen.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/cart_screen.dart';
import 'package:pharma_b2b/screens/customer/my_account_screen.dart';
import 'package:pharma_b2b/screens/customer/profile_account_menu.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// kyc_chip_block()'s answer for a pharmacy with nothing on file. The label is
/// deliberately NOT the one a Dart lookup on `state` would produce.
Map<String, dynamic> chipPayload({
  bool has = true,
  String state = 'missing',
  String label = 'Licence expired',
  bool action = true,
}) =>
    {
      'has': has,
      'state': state,
      'label': label,
      'tone': const {'bg': '#FEF3C7', 'fg': '#92400E', 'border': '#FDE68A'},
      'action': action
          ? const {
              'has': true,
              'label': 'View',
              'kind': 'customer_route',
              'route_key': 'cust_account',
              'tab_key': 'profile',
              'section': 'kyc',
            }
          : const {'has': false},
    };

/// cart_render().render, with the notice block the backend now sends: a chip,
/// the rx record line, and no card.
Map<String, dynamic> renderWithChip({
  Map<String, dynamic>? chip,
  String note = '2 prescription items in this order',
}) =>
    {
      'notice': {
        'has': false,
        'blocking': false,
        'title': '',
        'message': '',
        'note': note,
        'chip': chip ?? chipPayload(),
        'action': const {'has': false},
      },
    };

Future<void> pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the KYC chip is a printer', () {
    testWidgets('label, action label and tone come off the payload', (t) async {
      await pump(t, C1815KycChip(chip: chipPayload(), onAction: (_) {}));

      // The payload's word, not the state's.
      expect(find.text('Licence expired'), findsOneWidget);
      expect(find.text('View'), findsOneWidget);

      final box = t.widget<Container>(find.descendant(
        of: find.byType(C1815KycChip),
        matching: find.byType(Container),
      ));
      final dec = box.decoration as BoxDecoration;
      expect(dec.color, const Color(0xFFFEF3C7));

      final text = t.widget<Text>(find.text('Licence expired'));
      expect(text.style?.color, const Color(0xFF92400E));
    });

    testWidgets('has:false draws nothing at all', (t) async {
      await pump(t, C1815KycChip(chip: chipPayload(has: false)));
      expect(find.byType(Container), findsNothing);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('an empty label is absence, not an empty chip', (t) async {
      await pump(t, C1815KycChip(chip: chipPayload(label: '')));
      expect(find.byType(Container), findsNothing);
    });

    testWidgets('no action in the payload means no button', (t) async {
      await pump(t, C1815KycChip(chip: chipPayload(action: false)));
      expect(find.text('Licence expired'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('the tap hands back the backend descriptor, once', (t) async {
      final seen = <Map<String, dynamic>>[];
      await pump(
          t, C1815KycChip(chip: chipPayload(), onAction: (a) => seen.add(a)));
      await t.tap(find.text('View'));
      await t.pump();

      expect(seen.length, 1);
      expect(seen.single['route_key'], 'cust_account');
      expect(seen.single['tab_key'], 'profile');
      expect(seen.single['section'], 'kyc');
      // No path is built in Dart, and never the one #705 shipped.
      expect(seen.single.containsKey('route'), isFalse);
    });
  });

  group('the cart warns small — it never blocks', () {
    testWidgets('a warning is a chip plus the record line, no card', (t) async {
      await pump(t, C572CartNotice(render: renderWithChip(), onAction: (_) {}));

      expect(find.byType(C1815KycChip), findsOneWidget);
      expect(find.text('Licence expired'), findsOneWidget);
      expect(find.text('2 prescription items in this order'), findsOneWidget);
      // The full-width notice is not built at all.
      expect(find.byType(C461Notice), findsNothing);
    });

    testWidgets('no countdown wording is invented in Dart', (t) async {
      await pump(t, C572CartNotice(render: renderWithChip(), onAction: (_) {}));
      expect(find.textContaining('keep ordering'), findsNothing);
      expect(find.textContaining('before'), findsNothing);
    });

    testWidgets('no chip and no note draws nothing', (t) async {
      await pump(t, C572CartNotice(
        render: renderWithChip(chip: chipPayload(has: false), note: ''),
      ));
      expect(find.byType(C1815KycChip), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a chip with no note still renders', (t) async {
      await pump(t, C572CartNotice(
        render: renderWithChip(note: ''),
        onAction: (_) {},
      ));
      expect(find.byType(C1815KycChip), findsOneWidget);
    });
  });

  group('one profile screen', () {
    test('cust_profile_edit resolves to My Account, not a second editor', () {
      final w = customerMenuScreen('cust_profile_edit');
      expect(w, isA<MyAccountScreen>());
      final acct = w as MyAccountScreen;
      expect(acct.initialTab, 'profile');
      expect(acct.initialSection, 'profile');
    });

    test('cust_account is still the account page', () {
      expect(customerMenuScreen('cust_account'), isA<MyAccountScreen>());
    });

    test('a route this build has never heard of resolves to nothing', () {
      expect(customerMenuScreen('cust_something_new'), isNull);
    });
  });
}
