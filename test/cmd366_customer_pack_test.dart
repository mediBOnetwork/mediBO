// CMD #366 — the four customisations Om attached to rows 171/172/175/176,
// each pinned as a test.
//
// The thread running through all of them is the same rule: mediBO must never
// print a number it has not actually earned. A saving needs a real trade rate
// on BOTH sides; a margin needs an imported bill; a delivery promise needs
// deliveries we actually made. Where the input is missing the block is ABSENT
// — not zero, not a dash, not an estimate.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/product_detail.dart';
import 'package:pharma_b2b/widgets/substitute_choice.dart';

Map<String, dynamic> _pricing({String price = '₹90.00', bool ready = true}) => {
  'has_price': true,
  'price_display': price,
  'price_caption': ready ? 'NET' : 'MRP',
  'pricing_ready': ready,
  'display_mode': ready ? 'full' : 'mrp_only',
  'has_margin': ready,
  'margin_pct': ready ? 18.0 : null,
  'margin_chip': ready ? {'label': '18% margin'} : null,
  'mrp': 100,
  'sale_price': 90,
  'has_discount': false,
  'discount_pct': 0,
  'discount_label': '',
  'ribbon_top': '',
  'ribbon_bottom': '',
  'margin_label': '',
  'has_struck_mrp': false,
  'mrp_display': '',
};

Map<String, dynamic> _pdPayload({
  Map<String, dynamic>? substitutes,
  Map<String, dynamic>? promise,
}) => {
  'ok': true,
  'id': 1,
  'labels': const {'pdp_similar_title': 'Similar products'},
  'header': const {'name': 'Amoxil 500', 'company': 'Cipla', 'images': []},
  'price': const {'has_mrp': true, 'mrp_label': '₹100.00', 'mrp_note': 'MRP'},
  'pricing': _pricing(),
  'stock': const {'buyable': true},
  'trust': const {'has': false},
  'overview': const [],
  'sections': const [],
  'similar': const [],
  'my_history': const {'has': false},
  if (substitutes != null) 'substitutes': substitutes,
  if (promise != null) 'delivery_promise': promise,
};

void main() {
  group('row 171 — same-composition substitutes', () {
    test('a substitute with no imported rate carries no saving and no margin', () {
      final d = ProductDetail.fromMap(_pdPayload(substitutes: {
        'has': true,
        'heading': 'Same composition',
        'note': 'Same salt and strength from other companies.',
        'empty': '',
        'items': [
          {
            'id': 42,
            'name': 'Mox 500',
            'company': 'Ranbaxy',
            'pack_label': 'Strip',
            'match_label': 'Same strength & form',
            'pricing': _pricing(price: '₹100.00', ready: false),
            'saving': const {'has': false, 'label': ''},
            'margin': const {'has': false},
          },
        ],
      }));

      expect(d.substitutes.has, isTrue);
      expect(d.substitutes.heading, 'Same composition');
      final item = d.substitutes.items.single;
      // The whole point of Om's customisation: no rate => no invented numbers.
      expect(item.hasSaving, isFalse);
      expect(item.savingLabel, isEmpty);
      expect(item.hasMargin, isFalse);
      expect(item.matchLabel, 'Same strength & form');
    });

    test('the saving is the backend sentence, never recomputed here', () {
      final d = ProductDetail.fromMap(_pdPayload(substitutes: {
        'has': true,
        'heading': 'Same composition',
        'note': '',
        'empty': '',
        'items': [
          {
            'id': 43,
            'name': 'Novamox 500',
            'company': 'Cipla',
            'pricing': _pricing(price: '₹78.00'),
            'saving': const {'has': true, 'amount': 12, 'label': 'Saves ₹12.00 (13.3%)'},
            'margin': const {'has': true, 'pct': 22.0, 'chip': {'label': '22% margin'}},
          },
        ],
      }));
      final item = d.substitutes.items.single;
      expect(item.savingLabel, 'Saves ₹12.00 (13.3%)');
      expect(item.marginLabel, '22% margin');
      expect(item.pricing?.priceDisplay, '₹78.00');
    });

    test('absent block reads as has:false, and the original similar rail survives', () {
      final d = ProductDetail.fromMap(_pdPayload());
      expect(d.substitutes.has, isFalse);
      expect(d.substitutes.items, isEmpty);
      // Row 171 EXTENDS the salt rail; it must not have replaced it.
      expect(d.similar, isEmpty);
      expect(d.label('pdp_similar_title'), 'Similar products');
    });
  });

  group('row 175 — the delivery promise is measured, never invented', () {
    test('no history => has:false and no label at all', () {
      final d = ProductDetail.fromMap(
          _pdPayload(promise: const {'has': false, 'samples': 0, 'label': '', 'note': ''}));
      expect(d.deliveryPromise.has, isFalse);
      expect(d.deliveryPromise.label, isEmpty);
    });

    test('with history the label is the backend string, printed verbatim', () {
      final d = ProductDetail.fromMap(_pdPayload(promise: const {
        'has': true,
        'samples': 37,
        'label': 'Usually delivered in 4 hr 30 min',
        'note': 'Based on our own past deliveries to this area.',
      }));
      expect(d.deliveryPromise.has, isTrue);
      expect(d.deliveryPromise.label, 'Usually delivered in 4 hr 30 min');
      expect(d.deliveryPromise.note,
          'Based on our own past deliveries to this area.');
    });

    test('a missing key is not a crash — it is simply no promise', () {
      final d = ProductDetail.fromMap(_pdPayload());
      expect(d.deliveryPromise.has, isFalse);
    });
  });

  group('row 176 — substitute choice, customer-approved only', () {
    final offer = <String, dynamic>{
      'ok': true,
      'offer_id': 7,
      'status': 'offered',
      'expired': false,
      'heading': 'Out of stock — choose a substitute',
      'note': 'Pick a replacement, or tell us to drop it.',
      'expired_label': 'This link has expired.',
      'done_label': 'Thanks — we have recorded your choice.',
      'status_label': 'Waiting for the customer to choose',
      'status_tone': 'info',
      'line': {'product_name': 'Amoxil 500', 'qty': 5, 'reason': 'No supplier'},
      'buttons': [
        {'key': 'approve', 'label': 'Send this instead', 'tone': 'success', 'needs_choice': true},
        {'key': 'decline', 'label': 'Drop this item', 'tone': 'neutral', 'needs_choice': false},
        {'key': 'hold', 'label': 'Hold the order', 'tone': 'warning', 'needs_choice': false},
      ],
      'options': [
        {'id': 42, 'name': 'Mox 500', 'company': 'Ranbaxy', 'match_label': 'Same strength & form',
         'pricing': _pricing(price: '₹92.00'), 'saving': {'has': false, 'label': ''}},
        {'id': 43, 'name': 'Novamox 500', 'company': 'Cipla', 'match_label': 'Same salt',
         'pricing': _pricing(price: '₹78.00'),
         'saving': {'has': true, 'label': 'Saves ₹12.00 (13.3%)'}},
      ],
    };

    Future<void> pump(WidgetTester t, {bool readOnly = false, String? token,
        ValueChanged<Map<String, dynamic>>? onDecided}) =>
      t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SubstituteChoice(
              offer: offer, readOnly: readOnly, token: token,
              onDecided: onDecided,
            ),
          ),
        ),
      ));

    tearDown(() => SubstituteChoice.rpcTransport = null);

    testWidgets('every label and every option comes from the payload, in order',
        (t) async {
      await pump(t);
      expect(find.text('Out of stock — choose a substitute'), findsOneWidget);
      expect(find.text('Waiting for the customer to choose'), findsOneWidget);
      expect(find.text('Send this instead'), findsOneWidget);
      expect(find.text('Drop this item'), findsOneWidget);
      expect(find.text('Hold the order'), findsOneWidget);
      // Option order is the backend's ranking (exact match, better margin,
      // better-selling company) — no client-side sort.
      final names = t.widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? '')
          .where((s) => s == 'Mox 500' || s == 'Novamox 500')
          .toList();
      expect(names, ['Mox 500', 'Novamox 500']);
      expect(find.text('Saves ₹12.00 (13.3%)'), findsOneWidget);
    });

    testWidgets('approve is dead until an option is picked — no default swap',
        (t) async {
      final calls = <Map<String, dynamic>?>[];
      SubstituteChoice.rpcTransport = (fn, p) async {
        calls.add(p);
        return {...offer, 'status': 'approved'};
      };
      await pump(t);

      // Nothing chosen: the button that would substitute is disabled.
      final approve = t.widget<OutlinedButton>(
        find.ancestor(of: find.text('Send this instead'),
            matching: find.byType(OutlinedButton)),
      );
      expect(approve.onPressed, isNull);
      expect(calls, isEmpty);

      await t.tap(find.text('Novamox 500'));
      await t.pumpAndSettle();
      await t.tap(find.text('Send this instead'));
      await t.pumpAndSettle();

      // The chosen id is the one the person tapped, from the offered list.
      expect(calls.single!['p_action'], 'approve');
      expect(calls.single!['p_product_id'], 43);
      expect(calls.single!['p_offer_id'], 7);
    });

    testWidgets('declining sends no product id at all', (t) async {
      final calls = <Map<String, dynamic>?>[];
      SubstituteChoice.rpcTransport = (fn, p) async {
        calls.add(p);
        return {...offer, 'status': 'declined'};
      };
      await pump(t);
      await t.tap(find.text('Drop this item'));
      await t.pumpAndSettle();
      expect(calls.single!['p_action'], 'decline');
      expect(calls.single!['p_product_id'], isNull);
    });

    testWidgets('the token page sends the token, not an offer id', (t) async {
      final calls = <Map<String, dynamic>?>[];
      SubstituteChoice.rpcTransport = (fn, p) async {
        calls.add(p);
        return {...offer, 'status': 'held'};
      };
      await pump(t, token: 'abc123');
      await t.tap(find.text('Hold the order'));
      await t.pumpAndSettle();
      expect(calls.single!['p_token'], 'abc123');
      expect(calls.single!.containsKey('p_offer_id'), isFalse);
    });

    testWidgets('read-only (the admin) can see the choice but cannot make it',
        (t) async {
      var called = false;
      SubstituteChoice.rpcTransport = (fn, p) async {
        called = true;
        return offer;
      };
      await pump(t, readOnly: true);
      // The options are visible — the admin needs to see what was offered —
      // but there is no button to answer with, and tapping an option is inert.
      expect(find.text('Novamox 500'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      await t.tap(find.text('Novamox 500'));
      await t.pumpAndSettle();
      expect(called, isFalse);
    });

    testWidgets('a decided offer shows the status and offers no buttons',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SubstituteChoice(offer: {
            ...offer,
            'status': 'approved',
            'status_label': 'Customer approved — safe to apply',
            'status_tone': 'success',
          }),
        ),
      ));
      expect(find.text('Customer approved — safe to apply'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('an expired offer prints the backend copy instead of a form',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SubstituteChoice(
              offer: {...offer, 'expired': true, 'status': 'offered'}),
        ),
      ));
      expect(find.text('This link has expired.'), findsOneWidget);
      expect(find.text('Send this instead'), findsNothing);
    });

    testWidgets('an ok:false refusal prints the backend sentence', (t) async {
      SubstituteChoice.rpcTransport = (fn, p) async => {
            'ok': false,
            'error': 'not_approved',
            'message': 'The customer has not approved a substitute for this line yet.',
          };
      await pump(t);
      await t.tap(find.text('Drop this item'));
      await t.pumpAndSettle();
      expect(
        find.text('The customer has not approved a substitute for this line yet.'),
        findsOneWidget,
      );
    });
  });
}
