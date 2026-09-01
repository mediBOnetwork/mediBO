// PROTECTED — CHANGE #404.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes masked-calling behaviour.
//
// The one thing this file exists to stop coming back: a counterparty's real
// phone number reaching a device. Before #404 the rider's stop card carried
// `actions.call_number` straight off orders.phone and dialled it. So:
//
//   1. A masked-call button is built ONLY from a backend descriptor, and it
//      carries no number. `has:false`, a missing label and a missing role each
//      produce NO button — absence is the backend's answer, never a disabled
//      control Dart decided to grey out.
//
//   2. The label is the BACKEND's. The widget prints `label` verbatim and has
//      no word of its own for any role.
//
//   3. `user_dials` dials the DID — the masking number — and nothing else.
//      The number the app receives is the one both parties are meant to see.
//
//   4. `provider_dials` dials NOTHING. The provider rings both legs; a screen
//      that also opened a dialler would be a second call.
//
//   5. A refusal shows the backend's `message` verbatim and dials nothing.
//      There is no Dart fallback wording, so the screen can never disagree
//      with the server about why a call was refused.
//
//   6. The targets map is read in payload shape: orders with no permitted
//      counterparty are absent, and a malformed entry is skipped rather than
//      thrown on.
//
// No network, no Supabase, no goldens — the service's two seams are injected.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/services/masked_call_service.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/masked_call_button.dart';

const _orderId = '11111111-1111-1111-1111-111111111111';

MaskedCallTarget _target({String role = 'customer', String label = 'Call pharmacy'}) =>
    MaskedCallTarget(
      orderId: _orderId,
      targetRole: role,
      label: label,
      privacyNote: 'Numbers are masked. Neither side sees the other.',
    );

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  tearDown(() {
    MaskedCallService.targetsFn = null;
    MaskedCallService.placeFn = null;
  });

  group('the descriptor is the button', () {
    test('has:false is not a button', () {
      expect(MaskedCallTarget.from(_orderId, {'has': false, 'label': 'Call', 'target_role': 'customer'}),
          isNull);
    });

    test('a descriptor with no label and one with no role are both nothing', () {
      expect(MaskedCallTarget.from(_orderId, {'has': true, 'target_role': 'customer'}), isNull);
      expect(MaskedCallTarget.from(_orderId, {'has': true, 'label': 'Call'}), isNull);
      expect(MaskedCallTarget.from(_orderId, 'not a map'), isNull);
    });

    test('a real descriptor keeps the backend label and role verbatim', () {
      final t = MaskedCallTarget.from(_orderId, {
        'has': true,
        'label': 'Call rider',
        'target_role': 'delivery',
        'order_id': _orderId,
        'privacy_note': 'Numbers are masked.',
      });
      expect(t, isNotNull);
      expect(t!.label, 'Call rider');
      expect(t.targetRole, 'delivery');
      expect(t.orderId, _orderId);
    });
  });

  group('call_mask_targets is read, not interpreted', () {
    test('an order with no permitted counterparty is simply absent', () async {
      MaskedCallService.targetsFn = (_) async => {
            'ok': true,
            'orders': {
              _orderId: [
                {'has': true, 'label': 'Call pharmacy', 'target_role': 'customer'},
                // malformed — skipped, never thrown on
                {'has': true, 'target_role': 'partner'},
              ],
              '22222222-2222-2222-2222-222222222222': <dynamic>[],
            },
          };
      final out = await MaskedCallService.targets([_orderId, '22222222-2222-2222-2222-222222222222']);
      expect(out.keys, [_orderId]);
      expect(out[_orderId]!.single.label, 'Call pharmacy');
    });

    test('an empty id list never reaches the backend', () async {
      var called = false;
      MaskedCallService.targetsFn = (_) async {
        called = true;
        return {'ok': true, 'orders': {}};
      };
      expect(await MaskedCallService.targets(const []), isEmpty);
      expect(called, isFalse);
    });
  });

  group('what the button dials', () {
    testWidgets('user_dials opens tel: on the DID and nothing else', (tester) async {
      MaskedCallService.placeFn = (order, role) async => {
            'ok': true,
            'mode': 'user_dials',
            'did': '+919000000000',
            'message': 'Dial the number shown. Both sides stay private.',
            'privacy_note': 'Numbers are masked.',
            'stub_notice': 'Test mode — no real call is placed.',
            'target_name': 'Test Pharmacy',
          };

      final dialled = <String>[];
      await _pump(tester,
          MaskedCallButton(target: _target(), launch: (u) async => dialled.add(u)));

      expect(find.text('Call pharmacy'), findsOneWidget);
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();

      expect(dialled, ['tel:+919000000000']);
    });

    testWidgets('provider_dials dials nothing — the provider rings both legs', (tester) async {
      MaskedCallService.placeFn = (order, role) async => {
            'ok': true,
            'mode': 'provider_dials',
            'did': '+918000000001',
            'message': 'Connecting — your phone will ring first.',
            'privacy_note': 'Numbers are masked.',
            'stub_notice': '',
            'target_name': 'Test Pharmacy',
          };

      final dialled = <String>[];
      await _pump(tester,
          MaskedCallButton(target: _target(), launch: (u) async => dialled.add(u)));
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();

      expect(dialled, isEmpty);
      expect(find.text('Connecting — your phone will ring first.'), findsOneWidget);
    });

    testWidgets('a refusal prints the backend message and dials nothing', (tester) async {
      MaskedCallService.placeFn = (order, role) async => {
            'ok': false,
            'error': 'not_allowed',
            'message': 'This call is not permitted.',
          };

      final dialled = <String>[];
      await _pump(tester,
          MaskedCallButton(target: _target(role: 'supplier', label: 'Call supplier'),
              launch: (u) async => dialled.add(u)));
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();

      expect(dialled, isEmpty);
      expect(find.text('This call is not permitted.'), findsOneWidget);
    });

    test('shouldDial is false for every shape that is not a live user_dials', () {
      MaskedCallResult r(Map<String, dynamic> m) => MaskedCallResult.from(m);
      expect(r({'ok': true, 'mode': 'user_dials', 'did': '+919000000000'}).shouldDial, isTrue);
      expect(r({'ok': false, 'mode': 'user_dials', 'did': '+919000000000'}).shouldDial, isFalse);
      expect(r({'ok': true, 'mode': 'provider_dials', 'did': '+919000000000'}).shouldDial, isFalse);
      expect(r({'ok': true, 'mode': 'user_dials', 'did': ''}).shouldDial, isFalse);
      expect(r(const {}).shouldDial, isFalse);
    });
  });

  group('the row', () {
    testWidgets('no permitted counterparty renders no row at all', (tester) async {
      await _pump(tester, const MaskedCallRow(targets: []));
      expect(find.byType(MaskedCallButton), findsNothing);
    });

    testWidgets('every target the backend sent gets exactly one button', (tester) async {
      await _pump(tester, MaskedCallRow(targets: [
        _target(),
        _target(role: 'delivery', label: 'Call rider'),
      ]));
      expect(find.byType(MaskedCallButton), findsNWidgets(2));
      expect(find.text('Call pharmacy'), findsOneWidget);
      expect(find.text('Call rider'), findsOneWidget);
    });
  });
}
