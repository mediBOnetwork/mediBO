// PROTECTED — CHANGE #708. Order hold / park.
//
// What this file holds down, on the three widgets a hold is visible through:
//
//   * the sheet computes nothing — chips arrive in PAYLOAD order, Submit stays
//     closed until a reason is picked, a chip that says needs_note keeps it
//     closed until the note is typed, and a held order is offered exactly one
//     button whose word is the backend's;
//   * the customer card prints hold.badge VERBATIM and offers a door only when
//     the payload allows one (held -> Resume, can_hold -> the sheet's title,
//     otherwise nothing at all — never a disabled button to be refused by);
//   * the ops panel treats can_release as a FLAG, not a role guess: no release
//     button without it, and no release without a typed reason.
//
// No network, no Supabase: every RPC is a mocked payload.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/ops_board_view.dart';
import 'package:pharma_b2b/screens/orders/order_hold_sheet.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/order_card_lean.dart';

Map<String, dynamic> _sheetPayload({
  bool canHold = true,
  bool held = false,
  String message = '',
}) =>
    {
      'ok': true,
      'order_id': 'o-1',
      'order_code': 'CPO-1',
      'actor_kind': 'customer',
      'title': 'Hold my order',
      'subtitle': 'We will keep everything as it is.',
      'reason_label': 'Why are we holding it?',
      'note_label': 'Anything we should know?',
      'note_hint': 'Optional',
      'note_max': 240,
      'resume_label': 'Start again on',
      'resume_hint': 'We will resume it for you on this date',
      'submit_label': 'Hold this order',
      'resume_submit_label': 'Resume now',
      'billing_note': 'Nothing is billed while an order is on hold.',
      'max_resume_days': 60,
      'stage_key': 'supplier_order',
      'stage_label': 'Supplier order',
      'can_hold': canHold,
      'can_resume': held,
      'blocked_reason': canHold ? '' : 'stage',
      'message': message,
      // Deliberately NOT alphabetical: payload order is the render order, and
      // 'other' is the one that needs a note.
      'reasons': const [
        {'code': 'shop_closed', 'label': 'Shop closed', 'needs_note': false},
        {'code': 'cash_later', 'label': 'Will pay later', 'needs_note': false},
        {'code': 'other', 'label': 'Something else', 'needs_note': true},
      ],
      'state': held
          ? {
              'held': true,
              'badge': 'On hold until 6 Sep',
              'reason': 'Shop closed',
              'note': 'back on Monday',
              'auto_cancel_note': 'If it is still on hold on 17 Sep 2026 we will cancel it.',
            }
          : {'held': false, 'badge': ''},
    };

CustomerOrderCard _card({
  Map<String, dynamic> hold = const {},
  Map<String, dynamic> sheet = const {},
}) =>
    CustomerOrderCard(
      id: 'o-1',
      orderCode: 'CPO-1',
      dateLabel: '3 Sep',
      itemCountLabel: '4 items',
      amountLabel: '₹1,240.00',
      amountIsMoney: true,
      stageKey: 'supplier_order',
      stageLabel: 'Getting your stock together',
      progressShow: false,
      progressSteps: const [],
      actionKey: 'track',
      actionLabel: 'Track',
      actionTone: 'brand',
      situation: 'active',
      placedByAdmin: false,
      placedByAdminLabel: '',
      hold: hold,
      holdSheet: sheet,
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => OrderHoldSheet.rpcTransport = null);

  group('the hold sheet renders the payload and decides nothing', () {
    testWidgets('chips arrive in payload order and Submit starts closed',
        (t) async {
      OrderHoldSheet.rpcTransport = (fn, p) async {
        expect(fn, 'order_hold_sheet');
        expect(p?['p_order_id'], 'o-1');
        return _sheetPayload();
      };
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: OrderHoldSheet(orderId: 'o-1'))));
      await t.pumpAndSettle();

      expect(find.text('Hold my order'), findsOneWidget);
      expect(find.text('Nothing is billed while an order is on hold.'),
          findsOneWidget);

      final chips = t.widgetList<ChoiceChip>(find.byType(ChoiceChip)).toList();
      expect(chips.length, 3);
      expect((chips[0].label as Text).data, 'Shop closed');
      expect((chips[1].label as Text).data, 'Will pay later');
      expect((chips[2].label as Text).data, 'Something else');

      final submit = t.widget<FilledButton>(find.ancestor(
          of: find.text('Hold this order'), matching: find.byType(FilledButton)));
      expect(submit.onPressed, isNull, reason: 'no reason picked yet');
    });

    testWidgets('a chip that needs a note keeps Submit closed until it is typed',
        (t) async {
      OrderHoldSheet.rpcTransport = (fn, p) async => _sheetPayload();
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: OrderHoldSheet(orderId: 'o-1'))));
      await t.pumpAndSettle();

      await t.tap(find.text('Shop closed'));
      await t.pumpAndSettle();
      var submit = t.widget<FilledButton>(find.ancestor(
          of: find.text('Hold this order'), matching: find.byType(FilledButton)));
      expect(submit.onPressed, isNotNull, reason: 'a chip with no note needed');

      await t.tap(find.text('Something else'));
      await t.pumpAndSettle();
      submit = t.widget<FilledButton>(find.ancestor(
          of: find.text('Hold this order'), matching: find.byType(FilledButton)));
      expect(submit.onPressed, isNull, reason: 'needs_note and none typed');

      await t.enterText(find.byType(TextField), 'the shop is being painted');
      await t.pumpAndSettle();
      submit = t.widget<FilledButton>(find.ancestor(
          of: find.text('Hold this order'), matching: find.byType(FilledButton)));
      expect(submit.onPressed, isNotNull);
    });

    testWidgets('a held order is offered exactly one button, worded by the backend',
        (t) async {
      OrderHoldSheet.rpcTransport = (fn, p) async => _sheetPayload(held: true);
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: OrderHoldSheet(orderId: 'o-1'))));
      await t.pumpAndSettle();

      expect(find.text('On hold until 6 Sep'), findsOneWidget);
      expect(find.text('back on Monday'), findsOneWidget);
      expect(find.text('Resume now'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('Hold this order'), findsNothing);
    });

    testWidgets('a refusal prints the backend sentence and offers no form',
        (t) async {
      OrderHoldSheet.rpcTransport = (fn, p) async => _sheetPayload(
          canHold: false,
          message: 'This order is already at Pack — it is too far along to hold.');
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: OrderHoldSheet(orderId: 'o-1'))));
      await t.pumpAndSettle();

      expect(
          find.text(
              'This order is already at Pack — it is too far along to hold.'),
          findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.text('Hold this order'), findsNothing);
    });

    testWidgets('ok:false renders the backend page instead of throwing',
        (t) async {
      OrderHoldSheet.rpcTransport = (fn, p) async => {
            'ok': false,
            'error': 'not_yours',
            'title': 'Hold my order',
            'message': 'That order is not yours to hold.',
          };
      await t.pumpWidget(const MaterialApp(
          home: Scaffold(body: OrderHoldSheet(orderId: 'o-1'))));
      await t.pumpAndSettle();
      expect(find.text('That order is not yours to hold.'), findsOneWidget);
    });
  });

  group('the customer card', () {
    testWidgets('prints hold.badge verbatim and offers Resume', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OrderCardLean(
            card: _card(
              hold: const {'held': true, 'badge': 'On hold until 6 Sep'},
              sheet: const {
                'can_hold': false,
                'title': 'Hold my order',
                'resume_submit_label': 'Resume now',
              },
            ),
            onOpen: () {},
            onAction: (_) {},
            onHoldTap: (_) {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('On hold until 6 Sep'), findsOneWidget);
      expect(find.text('Resume now'), findsOneWidget);
      expect(find.text('Hold my order'), findsNothing);
    });

    testWidgets('offers the sheet only while the payload allows a hold',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OrderCardLean(
            card: _card(
              hold: const {'held': false},
              sheet: const {'can_hold': true, 'title': 'Hold my order'},
            ),
            onOpen: () {},
            onAction: (_) {},
            onHoldTap: (_) {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Hold my order'), findsOneWidget);
    });

    testWidgets('a stage that cannot be held shows no door at all', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OrderCardLean(
            card: _card(
              hold: const {'held': false},
              sheet: const {'can_hold': false, 'title': 'Hold my order'},
            ),
            onOpen: () {},
            onAction: (_) {},
            onHoldTap: (_) {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Hold my order'), findsNothing);
      expect(find.text('Resume now'), findsNothing);
    });

    testWidgets('no hold block at all renders no badge and no door', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OrderCardLean(
            card: _card(),
            onOpen: () {},
            onAction: (_) {},
            onHoldTap: (_) {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('On hold'), findsNothing);
    });
  });

  group('the ops hold panel', () {
    const stock = {
      'has': true,
      'heading': 'Stock reserved for this order',
      'total_label': '2 line(s) · 9 units reserved',
      'release_label': 'Release the stock',
      'release_reason_label': 'Why are you releasing it?',
      'release_note': 'Releasing puts the stock back on the shelf.',
      'can_release': true,
      'rows': [
        {'line': '4 × Amoxycillin 500', 'bag_label': 'Bag 3'},
        {'line': '5 × Paracetamol 650', 'bag_label': 'Bag 3'},
      ],
    };

    testWidgets('release stays shut until a reason is typed', (t) async {
      var released = '';
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OpsHoldPanel(
            hold: const {'held': true, 'badge': 'On hold — Shop closed'},
            sheet: const {'resume_submit_label': 'Resume now'},
            stock: stock,
            onHold: () {},
            onReleaseStock: (r) async => released = r,
          ),
        ),
      ));
      await t.pumpAndSettle();

      expect(find.text('On hold — Shop closed'), findsOneWidget);
      expect(find.text('2 line(s) · 9 units reserved'), findsOneWidget);
      expect(find.text('4 × Amoxycillin 500'), findsOneWidget);

      var btn = t.widget<OutlinedButton>(find.ancestor(
          of: find.text('Release the stock'),
          matching: find.byType(OutlinedButton)));
      expect(btn.onPressed, isNull);

      await t.enterText(find.byType(TextField), 'shelf space needed');
      await t.pumpAndSettle();
      btn = t.widget<OutlinedButton>(find.ancestor(
          of: find.text('Release the stock'),
          matching: find.byType(OutlinedButton)));
      expect(btn.onPressed, isNotNull);
      await t.tap(find.text('Release the stock'));
      await t.pumpAndSettle();
      expect(released, 'shelf space needed');
    });

    testWidgets('can_release:false offers no release, whatever the role',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: OpsHoldPanel(
            hold: const {'held': true, 'badge': 'On hold — Shop closed'},
            sheet: const {'resume_submit_label': 'Resume now'},
            stock: {...stock, 'can_release': false},
            onHold: () {},
            onReleaseStock: (r) async {},
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('2 line(s) · 9 units reserved'), findsOneWidget);
      expect(find.text('Release the stock'), findsNothing);
      expect(find.byType(TextField), findsNothing);
    });
  });
}
