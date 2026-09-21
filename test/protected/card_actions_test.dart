// CMD #2124 — the card's action states, held down.
//
//  1. `card.action` absent (a payload built before #2124) → CardAction is null
//     and the card keeps its older controls.
//  2. The pill is the backend's template with the cart's number ("5 strip").
//  3. The foot re-picks between the BACKEND's lines: in cart → the tap-to-
//     change line, back to 0 → foot_idle, unavailable → the unavailable line,
//     notified (payload OR this session) → the WhatsApp line.
//  4. Notify → Notified flips ONLY when stock_notify_request says subscribed,
//     and the toast is the RPC's own.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/product_card_view.dart';
import 'package:pharma_b2b/models/storefront_p3.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';

Map<String, dynamic> _card({int qty = 0, bool notified = false}) => {
      'qty_in_cart': qty,
      'notified': notified,
      'foot': {'has': true, 'label': 'ZZ foot now', 'tone': {'name': 'brand'}},
      'foot_idle': {'has': true, 'label': 'ZZ idle foot', 'tone': {'name': 'muted'}},
      'action': {
        'picker': {'rpc': 'card_qty_picker', 'pack_type': 'strip'},
        'qty_tpl': '{qty} zzstrip',
        'qty_foot_tpl': '{qty} zzstrip in cart · tap',
        'notify': {
          'notified': notified,
          'label': 'ZZNotify',
          'done_label': 'ZZNotified',
          'idle_line': 'ZZ unavailable',
          'done_line': 'ZZ whatsapp line',
        },
      },
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  setUp(() => CardNotifyLedger.notified.value = <String>{});

  final view = ProductCardView.fromCard(_card());

  test('no action block → null (older controls stay)', () {
    expect(CardAction.of({'qty_in_cart': 2}), isNull);
    expect(CardAction.of(null), isNull);
  });

  test('pill is the backend template filled with the cart qty', () {
    final a = CardAction.of(_card())!;
    expect(a.pillLabel(5), '5 zzstrip');
    expect(a.pickerRpc, 'card_qty_picker');
    expect(a.packType, 'strip');
  });

  test('foot re-picks between backend lines only', () {
    final a = CardAction.of(_card(qty: 3))!;
    expect(a.foot(view: view, soldOut: false, notifiedNow: false, qty: 7),
        ('7 zzstrip in cart · tap', 'brand'));
    expect(a.foot(view: view, soldOut: false, notifiedNow: false, qty: 0),
        ('ZZ idle foot', 'muted'));
    final fresh = CardAction.of(_card())!;
    expect(fresh.foot(view: view, soldOut: false, notifiedNow: false, qty: 0),
        ('ZZ foot now', 'brand'));
    expect(fresh.foot(view: view, soldOut: true, notifiedNow: false, qty: 0),
        ('ZZ unavailable', 'danger'));
    expect(fresh.foot(view: view, soldOut: true, notifiedNow: true, qty: 0),
        ('ZZ whatsapp line', 'muted'));
    final paid = CardAction.of(_card(notified: true))!;
    expect(paid.foot(view: view, soldOut: true, notifiedNow: false, qty: 0),
        ('ZZ whatsapp line', 'muted'));
  });

  Future<void> pump(WidgetTester t, NotifyResult res, List<String> calls) =>
      t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: CardNotifyButton(
              productId: '42',
              action: CardAction.of(_card())!,
              request: (id) async {
                calls.add(id);
                return res;
              },
            ),
          ),
        ),
      ));

  testWidgets('Notify flips to Notified when the RPC subscribes', (t) async {
    final calls = <String>[];
    await pump(
        t,
        const NotifyResult(ok: true, subscribed: true, toast: 'ZZ toast', error: ''),
        calls);
    expect(find.text('ZZNotify'), findsOneWidget);
    await t.tap(find.text('ZZNotify'));
    await t.pump();
    expect(calls, ['42']);
    expect(find.text('ZZNotified'), findsOneWidget);
    expect(CardNotifyLedger.notified.value, contains('42'));
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('Notify stays when the RPC does not subscribe', (t) async {
    final calls = <String>[];
    await pump(
        t,
        const NotifyResult(ok: true, subscribed: false, toast: 'ZZ avail', error: ''),
        calls);
    await t.tap(find.text('ZZNotify'));
    await t.pump();
    expect(find.text('ZZNotify'), findsOneWidget);
    expect(find.text('ZZNotified'), findsNothing);
    await t.pump(const Duration(seconds: 5));
  });
}
