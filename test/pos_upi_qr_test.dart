// CMD #432 — the POS UPI QR, pinned where it can actually go wrong.
//
// The failure this file exists to prevent is not a layout bug. It is Dart
// quietly acquiring an opinion about money: rebuilding the upi:// string with
// its own parameter order, formatting the amount itself, or deciding a bill is
// paid because the button was tapped. Every test below asserts that the widget
// printed what the backend sent, and nothing else.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/pos_upi_qr_card.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

const _qr =
    'upi://pay?pa=jaimahakal@okhdfcbank&pn=Jai Mahakal Medical'
    '&am=1250.00&cu=INR&tn=INV/2026-27/00042';

Map<String, dynamic> _qrBlock() => {
  'has': true,
  'title': 'Scan to pay',
  'sub': 'Any UPI app. The money goes straight to your bank.',
  'qr_string': _qr,
  'vpa': 'jaimahakal@okhdfcbank',
  'payee': 'Jai Mahakal Medical',
  'rows': [
    {'label': 'Amount', 'value': '₹1,250.00', 'strong': true},
    {'label': 'Invoice', 'value': 'INV/2026-27/00042', 'strong': false},
  ],
};

Map<String, dynamic> _panel({
  bool confirmed = false,
  Map<String, dynamic>? qr,
}) => {
  'show': true,
  'qr': qr ?? _qrBlock(),
  'ask_patient': 'Ask the patient to show you the success screen.',
  'confirm_label': 'Payment received',
  'confirm_busy': 'Recording…',
  'is_confirmed': confirmed,
  'can_confirm': !confirmed,
  'confirmed_label': confirmed
      ? 'Received — marked by Ramesh at 03:12 PM'
      : null,
  'pending_label': confirmed ? null : 'Not marked received yet',
  'tone': confirmed ? 'success' : 'warning',
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the QR string is the backend\'s, verbatim', () {
    test(
      'UpiQrView carries the string it was handed, character for character',
      () {
        final v = UpiQrView.fromPayload(_qrBlock());
        expect(v.qrString, _qr);
        expect(v.canDraw, isTrue);
      },
    );

    test(
      'has:true with no string cannot draw — it would paint an empty box',
      () {
        final v = UpiQrView.fromPayload({'has': true, 'qr_string': ''});
        expect(v.has, isTrue);
        expect(v.canDraw, isFalse);
      },
    );

    test(
      'a string with has:false cannot draw either — the backend said no',
      () {
        final v = UpiQrView.fromPayload({'has': false, 'qr_string': _qr});
        expect(v.canDraw, isFalse);
      },
    );

    testWidgets('the amount and invoice print exactly as sent, once each', (
      t,
    ) async {
      await t.pumpWidget(
        _host(UpiQrCard(view: UpiQrView.fromPayload(_qrBlock()))),
      );
      expect(find.text('₹1,250.00'), findsOneWidget);
      expect(find.text('INV/2026-27/00042'), findsOneWidget);
      // Never re-derived: no bare number leaks onto the card.
      expect(find.text('1250.00'), findsNothing);
      expect(find.text('1250'), findsNothing);
    });

    testWidgets('a row the payload did not send is simply absent', (t) async {
      final block = _qrBlock()
        ..['rows'] = [
          {'label': 'Paying', 'value': 'Jai Mahakal Medical', 'strong': false},
        ];
      await t.pumpWidget(_host(UpiQrCard(view: UpiQrView.fromPayload(block))));
      expect(find.text('Amount'), findsNothing);
      expect(find.text('Jai Mahakal Medical'), findsOneWidget);
    });
  });

  group('no VPA is an empty state with the backend\'s own words', () {
    testWidgets('the refusal copy is printed and the QR is not drawn', (
      t,
    ) async {
      var tapped = 0;
      await t.pumpWidget(
        _host(
          UpiQrCard(
            view: UpiQrView.fromPayload({
              'has': false,
              'reason': 'no_vpa',
              'title': 'Add your UPI ID to show a QR',
              'hint': 'Save and confirm the shop UPI ID once.',
              'cta': 'Set up UPI',
            }),
            onSetup: () => tapped++,
          ),
        ),
      );
      expect(find.text('Add your UPI ID to show a QR'), findsOneWidget);
      expect(find.byType(UpiQrImage), findsNothing);
      await t.tap(find.text('Set up UPI'));
      expect(tapped, 1);
    });

    testWidgets('an empty block renders nothing at all — never a bare box', (
      t,
    ) async {
      await t.pumpWidget(
        _host(
          UpiQrCard(view: UpiQrView.fromPayload(const <String, dynamic>{})),
        ),
      );
      expect(find.byType(UpiQrImage), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });
  });

  group(
    'confirmation is a person\'s word, and only the server says it landed',
    () {
      testWidgets('a cash bill draws no panel at all', (t) async {
        await t.pumpWidget(
          _host(
            PosUpiPanel(
              upi: const {'show': false},
              onConfirm: () async => const {},
            ),
          ),
        );
        expect(find.byType(UpiQrCard), findsNothing);
        expect(find.text('Payment received'), findsNothing);
      });

      testWidgets(
        'unconfirmed shows the prompt, the pending line and the button',
        (t) async {
          await t.pumpWidget(
            _host(PosUpiPanel(upi: _panel(), onConfirm: () async => const {})),
          );
          expect(find.text('Not marked received yet'), findsOneWidget);
          expect(
            find.text('Ask the patient to show you the success screen.'),
            findsOneWidget,
          );
          expect(find.text('Payment received'), findsOneWidget);
        },
      );

      testWidgets(
        'the tap calls the RPC and then renders the SERVER\'s attributed line',
        (t) async {
          var calls = 0;
          await t.pumpWidget(
            _host(
              PosUpiPanel(
                upi: _panel(),
                onConfirm: () async {
                  calls++;
                  return {
                    'ok': true,
                    'upi': _panel(confirmed: true),
                    'message': 'Marked received.',
                  };
                },
              ),
            ),
          );
          await t.tap(find.text('Payment received'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 50));
          expect(calls, 1);
          expect(
            find.text('Received — marked by Ramesh at 03:12 PM'),
            findsOneWidget,
          );
          // The button is gone because the SERVER said is_confirmed, not because
          // the widget remembered a tap.
          expect(find.text('Payment received'), findsNothing);
        },
      );

      testWidgets('a refused confirm leaves the bill exactly as it was', (
        t,
      ) async {
        await t.pumpWidget(
          _host(
            PosUpiPanel(
              upi: _panel(),
              onConfirm: () async => {'ok': false, 'message': 'Not found'},
            ),
          ),
        );
        await t.tap(find.text('Payment received'));
        await t.pump();
        await t.pump(const Duration(milliseconds: 50));
        expect(find.text('Not marked received yet'), findsOneWidget);
        expect(find.text('Payment received'), findsOneWidget);
      });

      testWidgets('a confirmed bill offers no second tap', (t) async {
        await t.pumpWidget(
          _host(
            PosUpiPanel(
              upi: _panel(confirmed: true),
              onConfirm: () async => const {},
            ),
          ),
        );
        expect(find.text('Payment received'), findsNothing);
        expect(
          find.text('Received — marked by Ramesh at 03:12 PM'),
          findsOneWidget,
        );
      });

      testWidgets('can_confirm:false hides the button even while unconfirmed', (
        t,
      ) async {
        final p = _panel()..['can_confirm'] = false;
        await t.pumpWidget(
          _host(PosUpiPanel(upi: p, onConfirm: () async => const {})),
        );
        expect(find.text('Payment received'), findsNothing);
        expect(find.text('Not marked received yet'), findsOneWidget);
      });
    },
  );

  group('the setup card obeys the backend on who may edit', () {
    Map<String, dynamic> data({
      bool canEdit = true,
      bool confirmed = false,
    }) => {
      'setup': {
        'title': 'UPI for the counter',
        'hint': 'Patients pay this UPI ID directly.',
        'vpa_label': 'UPI ID (VPA)',
        'name_label': 'Name shown to the payer',
        'save_label': 'Save UPI ID',
        'confirm_label': 'I sent myself ₹1 and it arrived',
        'vpa': 'jaimahakal@okhdfcbank',
        'name': 'Jai Mahakal Medical',
        'has_vpa': true,
        'confirmed': confirmed,
        'state_label': confirmed
            ? 'UPI ID confirmed.'
            : 'Saved, not confirmed yet',
        'state_tone': confirmed ? 'success' : 'warning',
        'can_edit': canEdit,
        'locked_hint': canEdit ? null : 'Only the owner login can change this.',
        'history_title': 'Change history',
        'history_empty': 'No changes yet.',
      },
      'shop_qr': {'has': false},
      'history': [
        {
          'action': 'save',
          'label': 'Changed to jaimahakal@okhdfcbank',
          'who': 'Ramesh',
          'at': '01 Sep 2026, 11:04 AM',
        },
      ],
    };

    testWidgets(
      'a staff login gets read-only fields, the lock line, no buttons',
      (t) async {
        await t.pumpWidget(
          _host(
            PharmacyUpiSetupCard(
              data: data(canEdit: false),
              onSave: (_, __) async => const {},
              onConfirm: (_) async => const {},
            ),
          ),
        );
        expect(
          find.text('Only the owner login can change this.'),
          findsOneWidget,
        );
        expect(find.text('Save UPI ID'), findsNothing);
        expect(
          t.widget<TextField>(find.byType(TextField).first).enabled,
          isFalse,
        );
      },
    );

    testWidgets('the owner can save, and the confirm step appears only while '
        'the VPA is unconfirmed', (t) async {
      await t.pumpWidget(
        _host(
          PharmacyUpiSetupCard(
            data: data(),
            onSave: (_, __) async => const {},
            onConfirm: (_) async => const {},
          ),
        ),
      );
      expect(find.text('Save UPI ID'), findsOneWidget);
      expect(find.text('I sent myself ₹1 and it arrived'), findsOneWidget);

      await t.pumpWidget(
        _host(
          PharmacyUpiSetupCard(
            data: data(confirmed: true),
            onSave: (_, __) async => const {},
            onConfirm: (_) async => const {},
          ),
        ),
      );
      expect(find.text('I sent myself ₹1 and it arrived'), findsNothing);
    });

    testWidgets('save passes the typed values through and re-renders the '
        'backend\'s new setup block', (t) async {
      String? sawVpa, sawName;
      await t.pumpWidget(
        _host(
          PharmacyUpiSetupCard(
            data: data(),
            onSave: (v, n) async {
              sawVpa = v;
              sawName = n;
              return {
                'ok': true,
                'setup': {
                  ...data(confirmed: true)['setup'] as Map<String, dynamic>,
                },
                'message': 'Saved.',
              };
            },
            onConfirm: (_) async => const {},
          ),
        ),
      );
      await t.enterText(find.byType(TextField).first, 'newshop@okaxis');
      await t.tap(find.text('Save UPI ID'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(sawVpa, 'newshop@okaxis');
      expect(sawName, 'Jai Mahakal Medical');
      // The confirm step vanished because the SERVER returned confirmed:true.
      expect(find.text('I sent myself ₹1 and it arrived'), findsNothing);
    });

    testWidgets('the history prints the backend\'s sentence, who and when', (
      t,
    ) async {
      await t.pumpWidget(
        _host(
          PharmacyUpiSetupCard(
            data: data(),
            onSave: (_, __) async => const {},
            onConfirm: (_) async => const {},
          ),
        ),
      );
      expect(find.text('Changed to jaimahakal@okhdfcbank'), findsOneWidget);
      expect(find.text('Ramesh · 01 Sep 2026, 11:04 AM'), findsOneWidget);
    });
  });
}
