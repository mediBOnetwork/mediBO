// PROTECTED — CHANGE #695, the GST tax invoice raised on every settled period.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes settlement-invoice behaviour, never to make an unrelated
// change go green.
//
// What this holds down:
//
//   1. NO TAX IS COMPUTED IN DART. The rupees, the CGST/SGST-versus-IGST line,
//      the direction sentence, the status word AND its tone all print exactly
//      as the payload sent them. The fixture's `total_value` deliberately does
//      NOT equal taxable + the tax heads, so a widget that adds anything up
//      fails here rather than on a filed return.
//
//   2. THE BUTTONS ARE BACKEND FLAGS, NOT STATUS COMPARISONS. can_download,
//      can_wa and can_credit_note decide what exists. A partner's payload
//      carries none of them and the row offers no action, even though the
//      invoice is plainly "issued" — because permission is the server's answer
//      and not something the screen infers from a word it recognises.
//
//   3. ROWS RENDER IN PAYLOAD ORDER. The backend sorts by invoice date; the
//      fixture is deliberately not alphabetical so a client-side sort shows up.
//
//   4. THE TILE HAS A DOOR THE SHELL ACTUALLY OPENS. shellExtraRouteScreen()
//      resolves the route, not just partnerDestination(): #710 shipped a
//      registry tile whose route the shell could not open because #653 retired
//      that resolver's last caller, and it reached live before anyone noticed.
//
//   5. AN EMPTY LIST IS THE BACKEND'S SENTENCE, and a refusal renders the
//      backend's own copy instead of throwing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/settlement_invoices_screen.dart';
import 'package:pharma_b2b/screens/shell/shell_extra_routes.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// Two invoices and a credit note. The money is deliberately inconsistent with
/// the tax heads: nothing here may be recomputed.
Map<String, dynamic> _payload({bool admin = true}) => {
      'ok': true,
      'heading': 'GST tax invoices',
      'empty_text': 'No tax invoice has been issued yet.',
      'is_admin': admin,
      'count': 2,
      'has_more': false,
      'register_label': 'Download register',
      'rows': [
        {
          'invoice_id': 'inv-1',
          'invoice_no': 'MBS/2026-27/0007',
          'date_label': '03 Sep 2026',
          'kind_label': 'Tax invoice',
          'doc_kind': 'tax_invoice',
          'direction_label': 'mediBO to partner',
          'partner_name': 'Raipur',
          'taxable_value': '₹7,500.00',
          // Deliberately NOT 7500 + 675 + 675. The screen prints it anyway.
          'total_value': '₹9,999.00',
          'tax_label': 'CGST ₹675.00  ·  SGST ₹675.00',
          'status_label': 'Issued',
          'status_tone': 'success',
          'pdf_status': 'ready',
          'can_download': admin,
          'download_label': 'Download PDF',
          'can_wa': admin,
          'wa_label': 'Send on WhatsApp',
          'can_credit_note': admin,
          'credit_note_label': 'Raise credit note',
          'period_id': 11,
        },
        {
          'invoice_id': 'cn-1',
          'invoice_no': 'AAA-first-alphabetically/0001',
          'date_label': '01 Sep 2026',
          'kind_label': 'Credit note',
          'doc_kind': 'credit_note',
          'direction_label': 'Partner to mediBO',
          'partner_name': 'Raipur',
          'taxable_value': '₹2,500.00',
          'total_value': '₹2,950.00',
          'tax_label': 'IGST ₹450.00',
          'status_label': 'Cancelled',
          'status_tone': 'danger',
          'pdf_status': 'idle',
          'can_download': false,
          'download_label': 'Download PDF',
          'can_wa': false,
          'wa_label': 'Sent on WhatsApp',
          'can_credit_note': false,
          'credit_note_label': 'Raise credit note',
          'period_id': 12,
        },
      ],
    };

Widget _host() => const MaterialApp(home: SettlementInvoicesScreen());

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => SettlementInvoicesScreen.rpcTransport = null);

  Future<void> pumpWith(WidgetTester tester, Map<String, dynamic> p) async {
    SettlementInvoicesScreen.rpcTransport = (fn, params) async => p;
    await tester.pumpWidget(_host());
    await tester.pump();
    await tester.pump();
  }

  group('settlement invoices — every figure is the backend\'s', () {
    testWidgets('rupees and the tax line print verbatim', (tester) async {
      await pumpWith(tester, _payload());
      // The inconsistent total is printed, not corrected.
      expect(find.text('₹9,999.00'), findsOneWidget);
      expect(find.text('CGST ₹675.00  ·  SGST ₹675.00'), findsOneWidget);
      // Interstate prints one head, not two zeroes.
      expect(find.text('IGST ₹450.00'), findsOneWidget);
      expect(find.textContaining('₹450.00'), findsOneWidget);
    });

    testWidgets('the direction sentence is a payload string', (tester) async {
      await pumpWith(tester, _payload());
      expect(find.text('mediBO to partner'), findsOneWidget);
      expect(find.text('Partner to mediBO'), findsOneWidget);
    });

    testWidgets('status word and tone come from the payload', (tester) async {
      await pumpWith(tester, _payload());
      expect(find.text('Issued'), findsOneWidget);
      expect(find.text('Cancelled'), findsOneWidget);
    });

    testWidgets('rows render in payload order, never sorted here',
        (tester) async {
      await pumpWith(tester, _payload());
      final first = tester.getTopLeft(find.text('MBS/2026-27/0007')).dy;
      final second =
          tester.getTopLeft(find.text('AAA-first-alphabetically/0001')).dy;
      expect(first, lessThan(second),
          reason: 'the backend ordered these by date; an alphabetical sort in '
              'Dart would put AAA first');
    });
  });

  group('settlement invoices — the actions are flags', () {
    testWidgets('an admin gets the three the payload allowed', (tester) async {
      await pumpWith(tester, _payload());
      expect(find.text('Download PDF'), findsOneWidget);
      expect(find.text('Send on WhatsApp'), findsOneWidget);
      expect(find.text('Raise credit note'), findsOneWidget);
    });

    testWidgets('a partner payload offers no action at all', (tester) async {
      await pumpWith(tester, _payload(admin: false));
      expect(find.text('Download PDF'), findsNothing);
      expect(find.text('Send on WhatsApp'), findsNothing);
      expect(find.text('Raise credit note'), findsNothing);
      // ...and the register button is the admin's too.
      expect(find.text('Download register'), findsNothing);
    });

    testWidgets('an issued invoice with can_download:false offers no download',
        (tester) async {
      final p = _payload();
      (p['rows'] as List)[0]['can_download'] = false;
      await pumpWith(tester, p);
      expect(find.text('Issued'), findsOneWidget);
      expect(find.text('Download PDF'), findsNothing,
          reason: 'the button is can_download, never "status == issued"');
    });
  });

  group('settlement invoices — absence and refusal', () {
    testWidgets('an empty list prints the backend sentence', (tester) async {
      await pumpWith(tester, {
        'ok': true,
        'heading': 'GST tax invoices',
        'empty_text': 'No tax invoice has been issued yet.',
        'is_admin': true,
        'count': 0,
        'rows': const [],
      });
      expect(find.text('No tax invoice has been issued yet.'), findsOneWidget);
    });

    testWidgets('a refusal renders its own copy instead of throwing',
        (tester) async {
      await pumpWith(tester, {
        'ok': false,
        'heading': 'Partner settlement',
        'empty_text': 'Admins only.',
        'rows': const [],
      });
      expect(find.text('Admins only.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('routing — the door the shell opens', () {
    test('settlement_invoices opens the invoices screen from the SHELL', () {
      expect(shellExtraRouteScreen('settlement_invoices'),
          isA<SettlementInvoicesScreen>(),
          reason: 'a route the shell cannot open is a tile that does nothing, '
              'however well every RPC behind it answers (#710)');
    });

    test('an unknown route_key still opens nothing', () {
      expect(shellExtraRouteScreen('settlement_invoices_v2'), isNull);
    });
  });
}
