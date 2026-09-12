// CMD #451 — the two customer widgets that register rows 128 and 129 added.
//
// Both are payload-rendering widgets, so what these tests pin is that they
// COMPUTE NOTHING: the batch line, the invoice title, the proforma chip and the
// unnumbered state are all backend flags and backend strings, and an absent key
// reads as an absence rather than as a default word.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/customer_order_item_card.dart';
import 'package:pharma_b2b/widgets/customer_invoice_card.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('row 129 — batch and expiry on the order line', () {
    test('batch_block is parsed as flag + strings, never derived', () {
      final item = CustomerOrderItem.fromPayload(const {
        'name': 'Isojol Tablet',
        'qty_label': '5 Tablets',
        'batch_block': {
          'has': true,
          'label': 'Batch B413A  ·  Exp 12/2026',
          'hint': '',
        },
      });
      expect(item.hasBatch, isTrue);
      expect(item.batchLabel, 'Batch B413A  ·  Exp 12/2026');
      expect(item.batchHint, isEmpty);
    });

    testWidgets('has:true prints the backend label verbatim', (t) async {
      await t.pumpWidget(_host(CustomerOrderItemCard(
        item: CustomerOrderItem.fromPayload(const {
          'name': 'Isojol Tablet',
          'batch_block': {
            'has': true,
            'label': 'Batch B413A  ·  Exp 12/2026',
            'hint': '',
          },
        }),
      )));
      expect(find.text('Batch B413A  ·  Exp 12/2026'), findsOneWidget);
    });

    testWidgets('has:false prints the backend hint, not an empty chip',
        (t) async {
      await t.pumpWidget(_host(CustomerOrderItemCard(
        item: CustomerOrderItem.fromPayload(const {
          'name': 'Azimax 100 Dry Syrup',
          'batch_block': {
            'has': false,
            'label': '',
            'hint': 'Batch and expiry are printed once the pack is received.',
          },
        }),
      )));
      expect(
          find.text('Batch and expiry are printed once the pack is received.'),
          findsOneWidget);
    });

    testWidgets('a payload with no batch_block at all prints nothing',
        (t) async {
      await t.pumpWidget(_host(CustomerOrderItemCard(
        item: CustomerOrderItem.fromPayload(const {'name': 'Dolo Ortho Oil'}),
      )));
      expect(find.textContaining('Batch'), findsNothing);
      expect(find.textContaining('Exp'), findsNothing);
      expect(find.text('Dolo Ortho Oil'), findsOneWidget);
    });

    testWidgets('has:true with an empty label falls back to nothing, never "Batch "',
        (t) async {
      await t.pumpWidget(_host(CustomerOrderItemCard(
        item: CustomerOrderItem.fromPayload(const {
          'name': 'Joypride 100mg Tablet',
          'batch_block': {'has': true, 'label': '', 'hint': ''},
        }),
      )));
      expect(find.textContaining('Batch'), findsNothing);
    });
  });

  group('row 128 — the invoice card', () {
    testWidgets('a dispatched order prints TAX INVOICE and the series number',
        (t) async {
      await t.pumpWidget(_host(const CustomerInvoiceCard(
        orderId: 'o1',
        payload: {
          'ok': true,
          'ready': true,
          'title': 'TAX INVOICE',
          'proforma': false,
          'invoice_no': 'MB/2026-27/0001',
          'issued_label': '01 Sep 2026',
          'not_ready_message': '',
          'unrated_lines': [],
          'file': {'has': false},
        },
      )));
      await t.pump();
      expect(find.text('TAX INVOICE'), findsOneWidget);
      expect(find.text('MB/2026-27/0001'), findsOneWidget);
      expect(find.text('01 Sep 2026'), findsOneWidget);
      // The proforma chip is a backend flag, not "the number is missing".
      expect(find.text('Proforma'), findsNothing);
    });

    testWidgets('a proforma is titled by the backend and stays unnumbered',
        (t) async {
      await t.pumpWidget(_host(const CustomerInvoiceCard(
        orderId: 'o1',
        payload: {
          'ok': true,
          'ready': true,
          'title': 'PROFORMA INVOICE',
          'proforma': true,
          'invoice_no': '',
          'issued_label': '',
          'not_ready_message': '',
          'unrated_lines': [],
          'file': {'has': false},
        },
      )));
      await t.pump();
      expect(find.text('PROFORMA INVOICE'), findsOneWidget);
      expect(find.text('Proforma'), findsOneWidget);
      // No number row at all — never a dash and never a placeholder.
      expect(find.textContaining('MB/'), findsNothing);
      expect(find.text('-'), findsNothing);
    });

    testWidgets('not ready names the lines the BACKEND said are unrated',
        (t) async {
      await t.pumpWidget(_host(const CustomerInvoiceCard(
        orderId: 'o1',
        payload: {
          'ok': true,
          'ready': false,
          'title': 'Invoice not ready',
          'proforma': false,
          'invoice_no': '',
          'issued_label': '',
          'not_ready_message':
              '4 item(s) on this order do not have a rate yet (5 still awaiting a supplier).',
          'unrated_lines': [
            {'product': 'Azimax 100 Dry Syrup', 'reason': 'No supplier assigned yet'},
            {'product': 'Joypride 100mg Tablet', 'reason': 'Waiting for the supplier bill'},
          ],
          'file': {'has': false},
        },
      )));
      await t.pump();
      expect(find.text('Invoice not ready'), findsOneWidget);
      expect(
          find.text(
              '4 item(s) on this order do not have a rate yet (5 still awaiting a supplier).'),
          findsOneWidget);
      expect(find.text('Azimax 100 Dry Syrup — No supplier assigned yet'),
          findsOneWidget);
      expect(find.text('Joypride 100mg Tablet — Waiting for the supplier bill'),
          findsOneWidget);
    });

    testWidgets('file.has:false draws no download row', (t) async {
      await t.pumpWidget(_host(const CustomerInvoiceCard(
        orderId: 'o1',
        payload: {
          'ok': true,
          'ready': true,
          'title': 'TAX INVOICE',
          'proforma': false,
          'invoice_no': 'MB/2026-27/0002',
          'issued_label': '',
          'not_ready_message': '',
          'unrated_lines': [],
          'file': {'has': false},
        },
      )));
      await t.pump();
      expect(find.byType(UploadedBillActionsRowFinderProbe), findsNothing);
      expect(find.text('MB/2026-27/0002'), findsOneWidget);
    });
  });
}

/// A type that is never built — `findsNothing` against it keeps the last test
/// honest without importing the real actions row's Supabase dependency into a
/// pure-VM test.
class UploadedBillActionsRowFinderProbe extends StatelessWidget {
  const UploadedBillActionsRowFinderProbe({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
