// CHANGE #527 — the supplier's PO acknowledgement layer (feature_gaps #50 and
// #61), pinned the way every other protected file pins its surface: the screen
// DECIDES NOTHING.
//
// Before #527 a purchase order had exactly two states, "created" and "packed",
// and no way for the supplier to say he could not serve it. The states, the
// button labels, the refusal sentence and the batch/expiry field captions are
// all backend strings now — so the thing worth holding down is that Dart prints
// them and never invents, pluralises or infers one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/supplier_po_ack.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// Exactly the shape supplier_po_accept_block() returns for an unanswered PO.
Map<String, dynamic> _pendingAccept() => <String, dynamic>{
      'state': 'pending',
      'label': 'Awaiting your reply',
      'tone': 'info',
      'title': 'Can you supply this order?',
      'hint': 'Tell us before you pack — we send the rest to the next supplier '
          'straight away.',
      'reason': null,
      'reason_label': "Why can't you supply it? (optional)",
      'needs_reply': true,
      'actions': <Map<String, dynamic>>[
        {'action': 'accept', 'label': 'Accept order', 'tone': 'brand'},
        {'action': 'partial', 'label': 'Accept part', 'tone': 'neutral'},
        {'action': 'decline', 'label': "Can't supply", 'tone': 'danger'},
      ],
      'can_pack': false,
      'pack_blocked_reason': 'Accept the order before you mark it packed',
    };

Map<String, dynamic> _answeredAccept(String state, String label,
        {String? reason}) =>
    <String, dynamic>{
      'state': state,
      'label': label,
      'tone': state == 'declined' ? 'danger' : 'success',
      'title': 'Can you supply this order?',
      'hint': '',
      'reason': reason,
      'reason_label': "Why can't you supply it? (optional)",
      'needs_reply': false,
      'actions': const <Map<String, dynamic>>[],
      'can_pack': state != 'declined',
      'pack_blocked_reason': null,
    };

const _items = <Map<String, dynamic>>[
  {
    'product_id': '333871',
    'product_name': 'Moxiblu-LP Eye Drop',
    'quantity': 10,
    'batch_no': null,
    'expiry': null,
    'hsn': null,
  },
];

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('#50 — the acknowledgement is the backend\'s, verbatim', () {
    testWidgets('an unanswered PO offers exactly the actions the payload sent',
        (tester) async {
      await tester.pumpWidget(_host(SupplierPoAck(
        accept: _pendingAccept(),
        items: _items,
        orderCode: 'SPO1',
        onAnswered: () async {},
      )));

      // the question, not a Dart-authored heading
      expect(find.text('Can you supply this order?'), findsOneWidget);
      expect(
          find.text('Tell us before you pack — we send the rest to the next '
              'supplier straight away.'),
          findsOneWidget);

      // three actions, each label printed exactly as the backend wrote it
      expect(find.text('Accept order'), findsOneWidget);
      expect(find.text('Accept part'), findsOneWidget);
      expect(find.text("Can't supply"), findsOneWidget);
    });

    testWidgets('an action the backend did not send is not offered',
        (tester) async {
      final accept = _pendingAccept();
      // a deployment that only allows accept/decline — no part-accept
      accept['actions'] = <Map<String, dynamic>>[
        {'action': 'accept', 'label': 'Accept order', 'tone': 'brand'},
        {'action': 'decline', 'label': "Can't supply", 'tone': 'danger'},
      ];

      await tester.pumpWidget(_host(SupplierPoAck(
        accept: accept,
        items: _items,
        orderCode: 'SPO1',
        onAnswered: () async {},
      )));

      expect(find.text('Accept order'), findsOneWidget);
      expect(find.text("Can't supply"), findsOneWidget);
      expect(find.text('Accept part'), findsNothing);
    });

    testWidgets('an answered PO shows its state and stops asking',
        (tester) async {
      await tester.pumpWidget(_host(SupplierPoAck(
        accept: _answeredAccept('partial', 'Partly accepted'),
        items: _items,
        orderCode: 'SPO1',
        onAnswered: () async {},
      )));

      expect(find.text('Partly accepted'), findsOneWidget);
      expect(find.text('Accept order'), findsNothing);
      expect(find.text('Accept part'), findsNothing);
      expect(find.text("Can't supply"), findsNothing);
    });

    testWidgets('a decline prints the reason the supplier gave, verbatim',
        (tester) async {
      await tester.pumpWidget(_host(SupplierPoAck(
        accept: _answeredAccept('declined', 'Declined',
            reason: 'Stock finished today'),
        items: _items,
        orderCode: 'SPO1',
        onAnswered: () async {},
      )));

      expect(find.text('Declined'), findsOneWidget);
      expect(find.text('Stock finished today'), findsOneWidget);
    });

    testWidgets('no accept block in the payload renders nothing at all',
        (tester) async {
      await tester.pumpWidget(_host(SupplierPoAck(
        accept: const <String, dynamic>{},
        items: _items,
        orderCode: 'SPO1',
        onAnswered: () async {},
      )));

      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  group('#50 — the pack gate is a backend flag, never an inference', () {
    test('enabled:false blocks, and the reason is the backend sentence', () {
      const pb = <String, dynamic>{
        'label': 'Mark Packed',
        'enabled': false,
        'blocked_reason': 'Accept the order before you mark it packed',
      };
      expect(PoPackGate.enabled(pb), isFalse);
      expect(PoPackGate.blockedReason(pb),
          'Accept the order before you mark it packed');
    });

    test('enabled:true allows, with no reason to show', () {
      const pb = <String, dynamic>{
        'label': 'Mark Packed',
        'enabled': true,
        'blocked_reason': null,
      };
      expect(PoPackGate.enabled(pb), isTrue);
      expect(PoPackGate.blockedReason(pb), '');
    });

    test('a payload with no enabled key keeps the pre-#527 behaviour', () {
      // Forward/backward compatibility: an older backend never blocks the
      // button, exactly as it did before this change existed.
      const pb = <String, dynamic>{'label': 'Mark Packed'};
      expect(PoPackGate.enabled(pb), isTrue);
      expect(PoPackGate.blockedReason(pb), '');
    });
  });

  group('#61 — batch / expiry / HSN captions come from the payload', () {
    Map<String, dynamic> block({bool complete = false}) => <String, dynamic>{
          'title': 'Batch & expiry',
          'hint': 'Required on the purchase bill',
          'batch_label': 'Batch no.',
          'expiry_label': 'Expiry (MM/YY)',
          'hsn_label': 'HSN',
          'save_label': 'Save batch & expiry',
          'status_label': complete
              ? 'Batch and expiry filled'
              : 'Batch and expiry not filled',
          'complete': complete,
        };

    testWidgets('the collapsed row prints the backend title and status',
        (tester) async {
      await tester.pumpWidget(_host(SupplierPoLineDetails(
        block: block(),
        items: _items,
        orderCode: 'SPO1',
        onSaved: () async {},
      )));

      expect(find.text('Batch & expiry'), findsOneWidget);
      expect(find.text('Batch and expiry not filled'), findsOneWidget);
      // collapsed: the fields are not built yet
      expect(find.text('Batch no.'), findsNothing);
    });

    testWidgets('expanding shows one field per caption the backend sent',
        (tester) async {
      await tester.pumpWidget(_host(SupplierPoLineDetails(
        block: block(),
        items: _items,
        orderCode: 'SPO1',
        onSaved: () async {},
      )));

      await tester.tap(find.text('Batch & expiry'));
      await tester.pump();

      expect(find.text('Required on the purchase bill'), findsOneWidget);
      expect(find.text('Batch no.'), findsOneWidget);
      expect(find.text('Expiry (MM/YY)'), findsOneWidget);
      expect(find.text('HSN'), findsOneWidget);
      expect(find.text('Save batch & expiry'), findsOneWidget);
      expect(find.text('Moxiblu-LP Eye Drop'), findsOneWidget);
    });

    testWidgets('a filled line arrives pre-filled from the payload',
        (tester) async {
      const filled = <Map<String, dynamic>>[
        {
          'product_id': '333871',
          'product_name': 'Moxiblu-LP Eye Drop',
          'quantity': 10,
          'batch_no': 'KX-4471',
          'expiry': '09/2027',
          'hsn': '30049099',
        },
      ];

      await tester.pumpWidget(_host(SupplierPoLineDetails(
        block: block(complete: true),
        items: filled,
        orderCode: 'SPO1',
        onSaved: () async {},
      )));

      expect(find.text('Batch and expiry filled'), findsOneWidget);
      await tester.tap(find.text('Batch & expiry'));
      await tester.pump();

      // the stored values, not blanks the screen would have to re-ask for
      expect(find.text('KX-4471'), findsOneWidget);
      expect(find.text('09/2027'), findsOneWidget);
      expect(find.text('30049099'), findsOneWidget);
    });

    testWidgets('an empty block renders nothing', (tester) async {
      await tester.pumpWidget(_host(SupplierPoLineDetails(
        block: const <String, dynamic>{},
        items: _items,
        orderCode: 'SPO1',
        onSaved: () async {},
      )));

      expect(find.byType(TextField), findsNothing);
    });
  });

  group('tone is looked up, never guessed from the state name', () {
    testWidgets('the backend can call an accepted PO a warning', (tester) async {
      final accept = _answeredAccept('accepted', 'Accepted');
      accept['tone'] = 'warning';

      await tester.pumpWidget(_host(SupplierPoAck(
        accept: accept,
        items: _items,
        orderCode: 'SPO1',
        onAnswered: () async {},
      )));

      final chip = tester.widget<Text>(find.text('Accepted').last);
      expect(chip.style?.color, Ds.c.warning);
    });
  });
}
