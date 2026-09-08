// PROTECTED — CHANGE #710, the return-to-supplier flow and its debit note.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes return-to-supplier behaviour, never to make an unrelated
// change go green.
//
// What this holds down:
//
//   1. NO MONEY, NO STATUS AND NO CEILING IS COMPUTED IN DART. Every rupee, the
//      status word AND its colour, the "reduces your bill by …" sentence, the
//      GST percentage and the "up to N" ceiling are printed exactly as the
//      payload sent them. The fixtures deliberately carry a total that does NOT
//      equal the sum of the lines, so a widget that adds anything up fails.
//
//   1b. THE TILE HAS A DOOR THE SHELL ACTUALLY OPENS. The route_key resolves
//      through shellExtraRouteScreen(), not only through partnerDestination():
//      #653 retired the last caller of that resolver, so a route wired only
//      there is a tile that does nothing on tap — which is how #710 first
//      reached live (change #1074) with an unreachable returns console.
//
//   2. THE ACKNOWLEDGE BUTTON IS A BACKEND FLAG, NOT A STATUS COMPARISON.
//      can_ack decides whether it exists; an acknowledged return prints the
//      backend's own `ack_done_label` sentence and offers no button. The two
//      strings are separate keys precisely because one object once carried both
//      under one name and the sentence was lost.
//
//   3. ROWS AND LINES RENDER IN PAYLOAD ORDER. Both fixtures are deliberately
//      non-alphabetical and non-chronological.
//
//   4. A REFUSAL IS RENDERED, NEVER THROWN. ok:false on the supplier tab and an
//      unknown token on the public page both print the backend's own copy.
//
//   5. THE PUBLIC PAGE IS ANONYMOUS AND STATELESS. /return-ack/<token> asks
//      supplier_return_ack_form and submits supplier_return_ack_submit with the
//      token it was routed with, and `already:true` shows the already-note
//      rather than the fresh success note.
//
//   6. THE PARTNER EDITOR OBEYS ITS FLAGS. can_edit:false offers no Remove,
//      can_send:false offers no Send, can_doc gates the PDF button, and the
//      route_key 'supplier_returns' resolves to the returns screen while an
//      unknown key still resolves to nothing.
//
// No network, no Supabase, no timers.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/partner/partner_home_screen.dart';
import 'package:pharma_b2b/screens/partner/partner_returns_screen.dart';
import 'package:pharma_b2b/screens/public/supplier_return_ack_screen.dart';
import 'package:pharma_b2b/screens/supplier/supplier_records_screen.dart';
import 'package:pharma_b2b/screens/shell/shell_extra_routes.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// supplier_returns_list(). Two returns, newest FIRST in the payload and
/// deliberately not in alphabetical order; the first is still open for
/// acknowledgement, the second is already credited.
Map<String, dynamic> _supplierList() => {
      'ok': true,
      'title': 'Returns raised on you',
      'subtitle': 'Stock sent back by mediBO, and the debit note against your bill',
      'empty_label': 'No returns raised on you.',
      'doc_label': 'Debit note PDF',
      'payable_note': 'Debit notes reduce this bill by ₹1,240.00.',
      'summary': [
        {'label': 'Lines', 'value': '2'},
        {'label': 'Debit note total', 'value': '₹1,240.00', 'tone': 'danger'},
      ],
      'rows': [
        {
          'id': 'r-zulu',
          'supplier_name': 'Sagar Medicals',
          'debit_no': 'DN/Z1/2026-27/0009',
          'status': 'sent',
          'status_label': 'Sent',
          'status_tone': 'warning',
          'order_label': 'SPO0909',
          'count_label': 'Lines',
          'count_value': '2',
          // deliberately NOT 180.00 + 60.00 — a widget that sums fails here
          'total_value': '₹999.00',
          'effect_label': 'Reduces your bill by ₹999.00',
          'at_label': '09/09/2026 11:20',
          'acknowledged': false,
          'ack_done_label': '',
          'can_ack': true,
          'ack_label': 'Acknowledge',
          'can_doc': true,
          'carry_label': '',
          'carry_value': '',
          'items': [
            {
              'product_name': 'Zebeta 5',
              'qty_value': '3',
              'reason_label': 'Damaged on receipt',
              'amount_value': '₹180.00',
            },
            {
              'product_name': 'Almox 500',
              'qty_value': '1',
              'reason_label': 'Near expiry',
              'amount_value': '₹60.00',
            },
          ],
        },
        {
          'id': 'r-alpha',
          'supplier_name': 'Sagar Medicals',
          'debit_no': 'DN/Z1/2026-27/0008',
          'status': 'credited',
          'status_label': 'Credited',
          'status_tone': 'success',
          'order_label': 'SPO0808',
          'count_label': 'Lines',
          'count_value': '1',
          'total_value': '₹241.00',
          'effect_label': 'Reduces your bill by ₹241.00',
          'at_label': '08/09/2026 09:05',
          'acknowledged': true,
          'ack_done_label': 'Acknowledged on 08/09/2026 10:00',
          'can_ack': false,
          'ack_label': 'Acknowledge',
          'can_doc': true,
          'carry_label': 'Carried to your next bill',
          'carry_value': '₹41.00',
          'items': [
            {
              'product_name': 'Pan 40',
              'qty_value': '2',
              'reason_label': 'Wrong item sent',
              'amount_value': '₹241.00',
            },
          ],
        },
      ],
    };

/// supplier_return_ack_form(). Lines are deliberately NOT alphabetical.
Map<String, dynamic> _ackForm({bool already = false}) => {
      'ok': true,
      'kind': 'supplier_return_ack',
      'supplier_name': 'Sagar Medicals',
      'status': already ? 'acknowledged' : 'sent',
      'already': already,
      'eyebrow': 'mediBO · Return to supplier',
      'title': 'Debit note DN/Z1/2026-27/0009',
      'intro': 'These goods have been sent back. Please acknowledge the debit note.',
      'date_label': '9 Sep 2026',
      'items': [
        {
          'product_name': 'Zebeta 5',
          'qty_value': '3',
          'reason_label': 'Damaged on receipt',
          'amount_value': '₹180.00',
        },
        {
          'product_name': 'Almox 500',
          'qty_value': '1',
          'reason_label': 'Near expiry',
          'amount_value': '₹60.00',
        },
      ],
      'empty_text': 'No lines on this debit note.',
      'taxable_label': 'Taxable',
      'taxable_value': '₹214.29',
      'gst_label': 'GST',
      'gst_value': '₹25.71',
      'total_label': 'Debit note total',
      'total_value': '₹999.00',
      'effect_label': 'Reduces your bill by ₹999.00',
      'note_hint': 'Add a note (optional)',
      'submit_label': 'Acknowledge',
      'submitting_label': 'Submitting…',
      'success_title': 'Thank you — acknowledgement received',
      'success_note': 'Your bill has been adjusted by this debit note.',
      'already_note': 'You have already acknowledged this debit note.',
      'submit_error': 'Submission failed. Please try again.',
    };

Map<String, dynamic> _console() => {
      'ok': true,
      'access': 'write',
      'can_write': true,
      'zone_id': 1,
      'title': 'Returns to supplier',
      'subtitle': 'Stock sent back, and the debit note it raised',
      'empty_text': 'No returns raised yet.',
      'new_label': 'New return',
      'pick_order_label': 'Pick the supplier collection',
      'pick_order_empty': 'No supplier collection in this zone yet.',
      'orders': [
        {
          'supplier_order_id': 'so-1',
          'supplier_name': 'Sagar Medicals',
          'order_label': 'SPO0909',
          'date_label': '9 Sep, 11:20 AM',
        },
      ],
      'rows': [
        {
          'id': 'r-zulu',
          'supplier_name': 'Sagar Medicals',
          'debit_no': 'DN/Z1/2026-27/0009',
          'status': 'sent',
          'status_label': 'Sent',
          'status_tone': 'warning',
          'order_label': 'SPO0909',
          'count_label': 'Lines',
          'count_value': '2',
          'total_value': '₹999.00',
          'at_label': '09/09/2026 11:20',
        },
      ],
    };

Map<String, dynamic> _editor({
  bool canEdit = true,
  bool canSend = true,
  bool canDoc = false,
}) =>
    {
      'ok': true,
      'access': 'write',
      'can_write': true,
      'title': 'Return to Sagar Medicals',
      'row': {
        'id': 'r-zulu',
        'supplier_name': 'Sagar Medicals',
        'debit_no': canDoc ? 'DN/Z1/2026-27/0009' : '',
        'status': canEdit ? 'drafted' : 'sent',
        'status_label': canEdit ? 'Draft' : 'Sent',
        'status_tone': canEdit ? 'info' : 'warning',
        'taxable_label': 'Taxable',
        'taxable_value': '₹214.29',
        'gst_label': 'GST',
        'gst_value': '₹25.71',
        'total_label': 'Debit note total',
        'total_value': '₹999.00',
        'can_edit': canEdit,
        'can_send': canSend,
        'can_cancel': true,
        'can_doc': canDoc,
      },
      'candidates_label': 'What came in',
      'candidates_empty': 'Nothing on this collection can be returned.',
      'candidates': [
        {
          'order_item_id': 'oi-1',
          'product_name': 'Zebeta 5',
          'max_qty': 4,
          'max_qty_label': 'Up to 4',
          'rate_label': '₹60.00',
          'order_label': 'ORD-1',
          'in_return': true,
        },
      ],
      'items_label': 'Going back',
      'items_empty': 'Add a line to raise a debit note.',
      'items': [
        {
          'id': 'i-1',
          'order_item_id': 'oi-1',
          'product_name': 'Zebeta 5',
          'reason_code': 'damaged_on_receipt',
          'reason_label': 'Damaged on receipt',
          'qty_value': '3',
          'rate_value': '₹60.00',
          'gst_value': '12%',
          'amount_value': '₹180.00',
        },
      ],
      'reason_label': 'Reason',
      'reasons': [
        {'code': 'damaged_on_receipt', 'label': 'Damaged on receipt', 'tone': 'danger'},
      ],
      'qty_label': 'Qty',
      'note_label': 'Note',
      'add_label': 'Add line',
      'remove_label': 'Remove',
      'send_label': 'Send & raise debit note',
      'cancel_label': 'Cancel return',
      'doc_label': 'Debit note PDF',
    };

void main() {
  setUpAll(() {
    // The 800 ms debounce is a real Timer that would outlive the test and try
    // to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  tearDown(() => SupplierReturnAckScreen.rpcTransport = null);

  group('supplier records — the debit notes raised on you', () {
    testWidgets('every rupee, the status word and its tone are the payload\'s',
        (tester) async {
      await tester
          .pumpWidget(_host(SupplierReturnsView(payload: _supplierList())));
      await tester.pump();

      // the total is the backend's string, not the sum of the two lines
      expect(find.text('₹999.00'), findsOneWidget);
      expect(find.text('₹180.00'), findsOneWidget);
      expect(find.text('Reduces your bill by ₹999.00'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Credited'), findsOneWidget);
      expect(find.text('DN/Z1/2026-27/0009'), findsOneWidget);
    });

    testWidgets('rows render in payload order, newest first', (tester) async {
      await tester
          .pumpWidget(_host(SupplierReturnsView(payload: _supplierList())));
      await tester.pump();

      final first = tester.getTopLeft(find.text('DN/Z1/2026-27/0009')).dy;
      final second = tester.getTopLeft(find.text('DN/Z1/2026-27/0008')).dy;
      expect(first, lessThan(second));
    });

    testWidgets('Acknowledge is can_ack, and the done sentence is its own key',
        (tester) async {
      await tester
          .pumpWidget(_host(SupplierReturnsView(payload: _supplierList())));
      await tester.pump();

      // exactly one row offers the button — the one with can_ack:true
      expect(find.widgetWithText(FilledButton, 'Acknowledge'), findsOneWidget);
      // and the acknowledged row prints the backend's own sentence
      expect(find.text('Acknowledged on 08/09/2026 10:00'), findsOneWidget);
      expect(find.text('Carried to your next bill · ₹41.00'), findsOneWidget);
    });

    testWidgets('tapping Acknowledge hands the row id back untouched',
        (tester) async {
      String? sent;
      await tester.pumpWidget(_host(SupplierReturnsView(
        payload: _supplierList(),
        onAck: (id) => sent = id,
      )));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Acknowledge'));
      await tester.pump();
      expect(sent, 'r-zulu');
    });

    testWidgets('ok:false renders the backend refusal instead of throwing',
        (tester) async {
      await tester.pumpWidget(_host(const SupplierReturnsView(payload: {
        'ok': false,
        'error': 'not_authorized',
        'message': 'You do not have access to returns.',
      })));
      await tester.pump();
      expect(find.text('You do not have access to returns.'), findsOneWidget);
    });

    testWidgets('an empty list is the backend empty state', (tester) async {
      final p = _supplierList()
        ..['rows'] = <Map<String, dynamic>>[]
        ..['summary'] = <Map<String, dynamic>>[];
      await tester.pumpWidget(_host(SupplierReturnsView(payload: p)));
      await tester.pump();
      expect(find.text('No returns raised on you.'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Acknowledge'), findsNothing);
    });
  });

  group('/return-ack/<token> — anonymous, and it prints what it was sent', () {
    testWidgets('the whole page is the payload, in payload order',
        (tester) async {
      SupplierReturnAckScreen.rpcTransport = (fn, params) async {
        expect(fn, 'supplier_return_ack_form');
        expect(params?['p_token'], 'tok-710');
        return _ackForm();
      };
      await tester.pumpWidget(
          _host(const SupplierReturnAckScreen(token: 'tok-710')));
      await tester.pump();

      expect(find.text('Debit note DN/Z1/2026-27/0009'), findsOneWidget);
      expect(find.text('mediBO · Return to supplier'), findsOneWidget);
      expect(find.text('₹999.00'), findsOneWidget);
      expect(find.text('Reduces your bill by ₹999.00'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Acknowledge'), findsOneWidget);

      final zebeta = tester.getTopLeft(find.text('Zebeta 5')).dy;
      final almox = tester.getTopLeft(find.text('Almox 500')).dy;
      expect(zebeta, lessThan(almox));
    });

    testWidgets('submit carries the routed token and shows the success note',
        (tester) async {
      final calls = <String>[];
      SupplierReturnAckScreen.rpcTransport = (fn, params) async {
        calls.add(fn);
        if (fn == 'supplier_return_ack_form') return _ackForm();
        expect(params?['p_token'], 'tok-710');
        return {'ok': true, 'toast': 'Acknowledged.'};
      };
      await tester.pumpWidget(
          _host(const SupplierReturnAckScreen(token: 'tok-710')));
      await tester.pump();
      final button = find.widgetWithText(FilledButton, 'Acknowledge');
      await tester.ensureVisible(button);
      await tester.pump();
      await tester.tap(button);
      await tester.pump();
      await tester.pump();

      expect(calls, contains('supplier_return_ack_submit'));
      expect(find.text('Thank you — acknowledgement received'), findsOneWidget);
      expect(find.text('Your bill has been adjusted by this debit note.'),
          findsOneWidget);
    });

    testWidgets('already:true shows the already-note, not the fresh one',
        (tester) async {
      SupplierReturnAckScreen.rpcTransport =
          (fn, params) async => _ackForm(already: true);
      await tester.pumpWidget(
          _host(const SupplierReturnAckScreen(token: 'tok-710')));
      await tester.pump();

      expect(find.text('You have already acknowledged this debit note.'),
          findsOneWidget);
      expect(find.text('Your bill has been adjusted by this debit note.'),
          findsNothing);
      expect(find.widgetWithText(FilledButton, 'Acknowledge'), findsNothing);
    });

    testWidgets('an unknown token renders the backend refusal, not a crash',
        (tester) async {
      SupplierReturnAckScreen.rpcTransport = (fn, params) async => {
            'ok': false,
            'error': 'invalid',
            'error_title': 'This link is no longer valid',
            'error_note': 'Please contact mediBO for assistance.',
          };
      await tester
          .pumpWidget(_host(const SupplierReturnAckScreen(token: 'nope')));
      await tester.pump();

      expect(find.text('This link is no longer valid'), findsOneWidget);
      expect(find.text('Please contact mediBO for assistance.'), findsOneWidget);
    });
  });

  group('partner returns — the flags are the backend\'s', () {
    testWidgets('the console lists the returns and the collections verbatim',
        (tester) async {
      await tester.pumpWidget(_host(PartnerReturnsScreen(
        rpc: (fn, p) async => _console(),
      )));
      await tester.pump();
      await tester.pump();

      expect(find.text('Pick the supplier collection'), findsOneWidget);
      expect(find.text('New return'), findsOneWidget);
      expect(find.text('DN/Z1/2026-27/0009'), findsOneWidget);
      expect(find.text('₹999.00'), findsOneWidget);
    });

    testWidgets('opening a draft offers Send and Remove; a sent one offers neither',
        (tester) async {
      await tester.pumpWidget(_host(PartnerReturnsScreen(
        rpc: (fn, p) async =>
            fn == 'partner_returns_console' ? _console() : _editor(),
      )));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('DN/Z1/2026-27/0009').first);
      await tester.pump();
      await tester.pump();

      expect(find.text('Return to Sagar Medicals'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Remove'), findsOneWidget);
      // the ceiling is the backend's sentence, never a number worked out here
      expect(find.text('Up to 4'), findsOneWidget);
      // and no PDF button until the debit note exists
      expect(find.widgetWithText(OutlinedButton, 'Debit note PDF'), findsNothing);
      // the editor is a long list; the send row lives past the fold
      await tester.scrollUntilVisible(
          find.text('Send & raise debit note'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.widgetWithText(FilledButton, 'Send & raise debit note'),
          findsOneWidget);
    });

    testWidgets('can_edit:false hides Remove; can_doc:true shows the PDF button',
        (tester) async {
      await tester.pumpWidget(_host(PartnerReturnsScreen(
        rpc: (fn, p) async => fn == 'partner_returns_console'
            ? _console()
            : _editor(canEdit: false, canSend: false, canDoc: true),
      )));
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('DN/Z1/2026-27/0009').first);
      await tester.pump();
      await tester.pump();

      expect(find.widgetWithText(TextButton, 'Remove'), findsNothing);
      // the candidate picker is gone with the write flag
      expect(find.text('What came in'), findsNothing);
      await tester.scrollUntilVisible(find.text('Debit note PDF'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(
          find.widgetWithText(OutlinedButton, 'Debit note PDF'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Send & raise debit note'),
          findsNothing);
    });

    testWidgets('the console refusal is the backend sentence', (tester) async {
      await tester.pumpWidget(_host(PartnerReturnsScreen(
        rpc: (fn, p) async => {
          'ok': false,
          'error': 'not_authorized',
          'message': 'You do not have access to returns.',
        },
      )));
      await tester.pump();
      await tester.pump();
      expect(find.text('You do not have access to returns.'), findsOneWidget);
    });
  });

  group('routing — the route_key is the backend\'s', () {
    // The door the SHELL actually opens. This assertion is the one that
    // matters and it is deliberately first: #710 shipped to live change #1074
    // with the route wired ONLY into partnerDestination() below, and
    // /admin/go/supplier_returns silently rendered the storefront home. #653
    // retired the last caller of that resolver when it merged the partner
    // surface into the shared shell, so since then a partner route is reachable
    // only as an arm of shellExtraRouteScreen(), which home_shell reaches
    // through its one `case _ when shellExtraRouteScreen(route) != null`
    // lookup. A tile whose feature_registry row ships while this returns null
    // is a dead tap, however well every RPC behind it answers.
    test('supplier_returns opens the returns screen from the SHELL', () {
      expect(shellExtraRouteScreen('supplier_returns'),
          isA<PartnerReturnsScreen>(),
          reason: 'the shell opens partner routes through the shard — a route '
              'only partnerDestination() knows is a tile that does nothing');
    });

    test('an unknown route_key still opens nothing in the shell', () {
      expect(shellExtraRouteScreen('supplier_returns_v2'), isNull);
    });

    // partnerDestination() is kept in step so the resolver and the shard never
    // disagree about which screen the key means, but it is no longer the proof
    // of reachability — the assertion above is.
    test('partnerDestination agrees with the shard', () {
      expect(partnerDestination('supplier_returns'),
          isA<PartnerReturnsScreen>());
      expect(partnerDestination('supplier_returns_v2'), isNull);
    });
  });
}
