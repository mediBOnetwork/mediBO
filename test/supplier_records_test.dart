// CHANGE #403 — the supplier records layer.
//
// What this holds down:
//
//   1. THE TAB LIST IS THE PAYLOAD'S. supplier_records_home() names the tabs
//      and their order; the screen prints them and nothing else. A tab_key
//      this build has never heard of renders an empty body instead of
//      throwing, so the office can add a fifth record type before the app
//      ships one.
//
//   2. NOTHING ON THESE FOUR SURFACES IS COMPUTED IN DART. Every rupee, every
//      percentage, every quantity, every date, every plural and every empty
//      state is printed exactly as it arrived. The growth tile prints
//      '-18.4%' because the BACKEND sent '-18.4%' — the widget never sees the
//      two months it was derived from.
//
//   3. A DOCUMENT IS ASKED FOR, POLLED ON THE BACKEND'S OWN INTERVAL, AND
//      OPENED AT THE BACKEND'S OWN bucket+path. The screen never invents a
//      poll interval, never decides a render has failed, and never builds a
//      URL — it signs exactly the pair it was handed.
//
//   4. A DEBIT'S TONE AND ITS PROOF ARE FLAGS, NOT INFERENCES. status_tone
//      comes from the payload; the photo line appears only when has_photo is
//      true. A deduction with no photo shows no photo affordance at all.
//
//   5. AN EMPTY FILTER BOX IS AN ABSENT PARAMETER. The bill search sends only
//      the filters the supplier actually filled — never an empty string the
//      backend would have to interpret as "match everything with ''".
//
// Fixtures mirror the real supplier_records_home() / supplier_documents_list()
// / supplier_debits_list() / supplier_sales_summary() / supplier_bill_search()
// shapes. No network, no Supabase, no timers left running.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/supplier/supplier_records_screen.dart';
import 'package:pharma_b2b/services/supplier_records_api.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Map<String, dynamic> _home({List<Map<String, dynamic>>? tabs}) => {
      'ok': true,
      'title': 'My records',
      'subtitle': 'Your documents, deductions, sales and old bills.',
      'supplier_name': 'Sagar Medicals',
      'tabs': tabs ??
          const [
            {'key': 'documents', 'label': 'Documents', 'icon': 'description'},
            {'key': 'debits', 'label': 'Deductions', 'icon': 'remove_circle'},
            {'key': 'sales', 'label': 'Sales', 'icon': 'insights'},
            {'key': 'bills', 'label': 'Bills', 'icon': 'search'},
          ],
    };

Map<String, dynamic> _documents() => {
      'ok': true,
      'title': 'Documents',
      'subtitle': 'Download a purchase order, a bill copy, or a statement.',
      'download_label': 'Download',
      'building_label': 'Preparing…',
      'groups': [
        {
          'key': 'statements',
          'heading': 'Monthly statements',
          'empty_label': 'No months to report yet.',
          'rows': [
            {
              'kind': 'monthly_statement',
              'ref': '2026-09',
              'title': 'September 2026',
              'subtitle': 'Orders, bills, deductions, payments and balance',
              'ready': false,
            },
          ],
        },
        {
          'key': 'purchase_orders',
          'heading': 'Purchase orders',
          'empty_label': 'No purchase orders yet.',
          'rows': const [],
        },
        {
          'key': 'bills',
          'heading': 'Bills you sent us',
          'empty_label': 'No bills received from you yet.',
          'rows': [
            {
              'kind': 'bill_copy',
              'ref': 'bill-1',
              'title': 'INV/2026/4471',
              'subtitle': '18/08/2026 · imported',
              'ready': true,
              'source_bucket': 'supplier-bills',
              'source_path': 'sup/INV4471.jpg',
              'source_label': 'Original',
            },
          ],
        },
      ],
    };

Map<String, dynamic> _debits() => {
      'ok': true,
      'title': 'Deductions',
      'subtitle': 'Every return or claim that came off a bill.',
      'empty_label': 'No deductions against you.',
      'payable_note': '₹102.00 has been deducted from what mediBO owes you.',
      'summary': const [
        {'label': 'Deductions', 'value': '2'},
        {'label': 'Total deducted', 'value': '₹102.00', 'tone': 'danger'},
        {'label': 'Not yet credited', 'value': '₹0.00', 'tone': 'warning'},
      ],
      'rows': const [
        {
          'id': 'd1',
          'source': 'dispute',
          'source_label': 'Short / damage claim',
          'ref_label': 'SPO170826UNP019O1',
          'ref_caption': 'Your order',
          'product_name': 'C403 PROOF TABLET',
          'qty_label': 'Qty 4',
          'amount_label': '₹102.00',
          'reason_label': 'Short supplied',
          'note': 'Four strips missing from the parcel.',
          'status': 'resolved',
          'status_label': 'Settled',
          'status_tone': 'danger',
          'effect_label': 'Reduces your payable by ₹102.00',
          'at_label': '01/09/2026 11:20',
          'has_photo': true,
          'photo_bucket': '',
          'photo_path': '',
          'photo_url': 'https://example.invalid/proof.jpg',
          'photo_label': 'Photo proof',
        },
        {
          'id': 'd2',
          'source': 'return',
          'source_label': 'Customer return',
          'ref_label': 'ORD-9912',
          'ref_caption': 'Customer order',
          'product_name': 'Cyblex S 60XR Tablet SR',
          'qty_label': 'Qty 1',
          'amount_label': '₹0.00',
          'reason_label': 'Damaged',
          'note': '',
          'status': 'approved',
          'status_label': 'Approved',
          'status_tone': 'warning',
          'effect_label': 'Reduces your payable by ₹0.00',
          'at_label': '31/08/2026 09:05',
          'has_photo': false,
          'photo_bucket': '',
          'photo_path': '',
          'photo_url': '',
          'photo_label': '',
        },
      ],
    };

Map<String, dynamic> _sales() => {
      'ok': true,
      'title': 'Monthly sales',
      'month_ref': '2026-09',
      'month_label': 'September 2026',
      'months': const [
        {'ref': '2026-09', 'label': 'Sep 2026', 'selected': true},
        {'ref': '2026-08', 'label': 'Aug 2026', 'selected': false},
      ],
      'tiles': const [
        {
          'key': 'total',
          'label': 'Sold to mediBO',
          'value': '₹1,42,905.00',
          'caption': '12 orders',
          'tone': 'info',
        },
        {
          'key': 'growth',
          'label': 'Vs last month',
          'value': '-18.4%',
          'caption': 'Aug 2026: ₹1,75,140.00',
          'tone': 'danger',
        },
        {
          'key': 'fill',
          'label': 'Fill rate',
          'value': '93.5%',
          'caption': '187 of 200 units supplied',
          'tone': 'success',
        },
      ],
      'top_heading': 'Your top products this month',
      'top_empty': 'Nothing ordered from you this month.',
      'top_products': const [
        {
          'product_name': 'Cyblex S 60XR Tablet SR',
          'qty_label': '48 units',
          'amount_label': '₹11,126.40',
        },
      ],
      'note': 'Amounts are trade value at the rate on the order — never MRP.',
    };

Map<String, dynamic> _bills({List<Map<String, dynamic>>? rows}) => {
      'ok': true,
      'title': 'Bill archive',
      'subtitle': 'Find any bill you sent us.',
      'search_hint': 'Invoice number or file name',
      'from_label': 'From',
      'to_label': 'To',
      'min_label': 'Min ₹',
      'max_label': 'Max ₹',
      'search_label': 'Search',
      'clear_label': 'Clear',
      'empty_label': 'No bills match that search.',
      'count_label': '${rows?.length ?? 0} bills',
      'rows': rows ?? const [],
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the surface is the payload', () {
    testWidgets('tabs render in payload order, and only those tabs',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SupplierRecordsScreen(rpc: (fn, _) async {
          if (fn == 'supplier_records_home') return _home();
          if (fn == 'supplier_documents_list') return _documents();
          return {'ok': true, 'rows': const []};
        }),
      ));
      await tester.pumpAndSettle();

      expect(find.text('My records'), findsOneWidget);
      final tabs = tester.widgetList<Tab>(find.byType(Tab)).toList();
      expect(tabs.map((t) => t.text).toList(),
          ['Documents', 'Deductions', 'Sales', 'Bills']);
    });

    testWidgets('a tab_key this build has never heard of renders nothing',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SupplierRecordsScreen(rpc: (fn, _) async {
          if (fn == 'supplier_records_home') {
            return _home(tabs: [
              {'key': 'credit_notes', 'label': 'Credit notes', 'icon': ''},
            ]);
          }
          return {'ok': true};
        }),
      ));
      await tester.pumpAndSettle();

      // The label still prints — the office named it — but the body is empty
      // rather than an exception.
      expect(find.text('Credit notes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a refusal prints the backend sentence, not a Dart one',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SupplierRecordsScreen(rpc: (fn, _) async => {
              'ok': false,
              'error': 'not_authorized',
              'message': 'You do not have access to records.',
            }),
      ));
      await tester.pumpAndSettle();
      expect(find.text('You do not have access to records.'), findsOneWidget);
    });
  });

  group('documents', () {
    testWidgets('groups and rows print verbatim; an empty group prints the '
        'backend empty label', (tester) async {
      await tester.pumpWidget(_host(SupplierDocumentsTab(
        rpc: (fn, _) async => _documents(),
        sign: (b, p) async => 'signed://$b/$p',
        open: (_) async {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Monthly statements'), findsOneWidget);
      expect(find.text('September 2026'), findsOneWidget);
      expect(find.text('Orders, bills, deductions, payments and balance'),
          findsOneWidget);
      expect(find.text('No purchase orders yet.'), findsOneWidget);
      expect(find.text('INV/2026/4471'), findsOneWidget);
      // Download is the payload's word, on every row.
      expect(find.text('Download'), findsNWidgets(2));
      // Only the bill row carried a source file, so only it offers the original.
      expect(find.text('Original'), findsOneWidget);
    });

    testWidgets('a request that is still building is polled on the BACKEND\'s '
        'interval, then opened at the backend\'s own bucket and path',
        (tester) async {
      final calls = <String>[];
      var statusHits = 0;
      String? opened;

      await tester.pumpWidget(_host(SupplierDocumentsTab(
        rpc: (fn, params) async {
          calls.add(fn);
          if (fn == 'supplier_documents_list') return _documents();
          if (fn == 'supplier_doc_request') {
            expect(params['p_kind'], 'monthly_statement');
            expect(params['p_ref'], '2026-09');
            return {
              'ok': true,
              'status': 'building',
              'doc_id': 'doc-1',
              'poll_ms': 20,
              'message': 'Preparing your document.',
            };
          }
          if (fn == 'supplier_doc_status') {
            statusHits++;
            if (statusHits < 2) {
              return {
                'ok': true,
                'status': 'building',
                'doc_id': 'doc-1',
                'poll_ms': 20,
              };
            }
            return {
              'ok': true,
              'status': 'ready',
              'doc_id': 'doc-1',
              'bucket': 'supplier-docs',
              'path': 'sup-uuid/monthly_statement/2026-09.pdf',
              'file_name': 'STATEMENT-2026-09.pdf',
              'expires_s': 300,
            };
          }
          return {'ok': true};
        },
        sign: (b, p) async => 'signed://$b/$p',
        open: (u) async => opened = u,
      )));
      await tester.pumpAndSettle();

      final state = tester.state<SupplierDocumentsTabState>(
          find.byType(SupplierDocumentsTab));
      // Start the download and let the test clock run: the wait between polls
      // is a real Duration, and only pump() advances it.
      final done = state.download('monthly_statement', '2026-09');
      await tester.pumpAndSettle();
      await done;
      await tester.pumpAndSettle();

      expect(statusHits, 2, reason: 'polled until the backend stopped saying building');
      expect(opened, 'signed://supplier-docs/sup-uuid/monthly_statement/2026-09.pdf');
      expect(calls.contains('supplier_doc_request'), isTrue);
    });

    testWidgets('the ORIGINAL file is signed at the payload\'s own pair',
        (tester) async {
      String? opened;
      await tester.pumpWidget(_host(SupplierDocumentsTab(
        rpc: (fn, _) async => _documents(),
        sign: (b, p) async => 'signed://$b/$p',
        open: (u) async => opened = u,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Original'));
      await tester.pumpAndSettle();
      expect(opened, 'signed://supplier-bills/sup/INV4471.jpg');
    });

    test('a payload that is not building is never polled', () {
      expect(SupplierDocPoll.from({'status': 'ready', 'doc_id': 'x'}), isNull);
      expect(SupplierDocPoll.from({'status': 'building'}), isNull);
      final poll = SupplierDocPoll.from(
          {'status': 'building', 'doc_id': 'x', 'poll_ms': 900});
      expect(poll!.pollMs, 900);
    });
  });

  group('deductions', () {
    testWidgets('every rupee, quantity and tone is the payload\'s',
        (tester) async {
      await tester.pumpWidget(_host(SupplierDebitsView(payload: _debits())));
      await tester.pumpAndSettle();

      expect(find.text('₹102.00'), findsNWidgets(2)); // the tile and the row
      expect(find.text('Qty 4'), findsOneWidget);
      expect(find.text('Short supplied'), findsOneWidget);
      expect(find.text('Reduces your payable by ₹102.00'), findsOneWidget);
      expect(find.text('₹102.00 has been deducted from what mediBO owes you.'),
          findsOneWidget);
      expect(find.text('Settled'), findsOneWidget);
      expect(find.text('Approved'), findsOneWidget);
      // Both sources are named by the backend, never derived from the id.
      expect(find.text('Short / damage claim'), findsOneWidget);
      expect(find.text('Customer return'), findsOneWidget);
    });

    testWidgets('the photo affordance follows has_photo, not a guess',
        (tester) async {
      await tester.pumpWidget(_host(SupplierDebitsView(payload: _debits())));
      await tester.pumpAndSettle();
      // Two rows, exactly one of which carried a photo.
      expect(find.text('Photo proof'), findsOneWidget);
      expect(find.byIcon(Icons.photo_outlined), findsOneWidget);
    });

    testWidgets('no deductions is the backend\'s empty sentence', (tester) async {
      final p = _debits();
      p['rows'] = const [];
      await tester.pumpWidget(_host(SupplierDebitsView(payload: p)));
      await tester.pumpAndSettle();
      expect(find.text('No deductions against you.'), findsOneWidget);
      // The payable note belongs to a list that HAS deductions.
      expect(find.text('₹102.00 has been deducted from what mediBO owes you.'),
          findsNothing);
    });
  });

  group('monthly sales', () {
    testWidgets('tiles print the backend\'s own numbers — no Dart arithmetic',
        (tester) async {
      await tester.pumpWidget(_host(SupplierSalesView(payload: _sales())));
      await tester.pumpAndSettle();

      expect(find.text('₹1,42,905.00'), findsOneWidget);
      expect(find.text('12 orders'), findsOneWidget);
      expect(find.text('-18.4%'), findsOneWidget);
      expect(find.text('Aug 2026: ₹1,75,140.00'), findsOneWidget);
      expect(find.text('93.5%'), findsOneWidget);
      expect(find.text('187 of 200 units supplied'), findsOneWidget);
      expect(find.text('Cyblex S 60XR Tablet SR'), findsOneWidget);
      expect(find.text('₹11,126.40'), findsOneWidget);
    });

    testWidgets('picking a month asks the backend for THAT month',
        (tester) async {
      String? asked;
      await tester.pumpWidget(_host(
          SupplierSalesView(payload: _sales(), onMonth: (m) => asked = m)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Aug 2026'));
      await tester.pumpAndSettle();
      expect(asked, '2026-08');
    });

    testWidgets('an empty month prints the backend empty line', (tester) async {
      final p = _sales();
      p['top_products'] = const [];
      await tester.pumpWidget(_host(SupplierSalesView(payload: p)));
      await tester.pumpAndSettle();
      expect(find.text('Nothing ordered from you this month.'), findsOneWidget);
    });
  });

  group('bill archive', () {
    testWidgets('an untouched filter box is an ABSENT parameter, never an '
        'empty string', (tester) async {
      Map<String, dynamic>? sent;
      await tester.pumpWidget(_host(SupplierBillsTab(rpc: (fn, params) async {
        if (fn == 'supplier_bill_search') {
          sent = params;
          return _bills();
        }
        return {'ok': true};
      })));
      await tester.pumpAndSettle();

      expect(sent, isEmpty);

      final state =
          tester.state<SupplierBillsTabState>(find.byType(SupplierBillsTab));
      await tester.enterText(find.byType(TextField).first, 'INV/2026');
      await state.search();
      await tester.pumpAndSettle();

      expect(sent!.keys.toList(), ['p_q']);
      expect(sent!['p_q'], 'INV/2026');
    });

    testWidgets('results print verbatim and an empty result is the backend\'s '
        'sentence', (tester) async {
      var withRows = true;
      await tester.pumpWidget(_host(SupplierBillsTab(rpc: (fn, _) async {
        if (fn != 'supplier_bill_search') return {'ok': true};
        return withRows
            ? _bills(rows: const [
                {
                  'id': 'bill-1',
                  'invoice_no': 'INV/2026/4471',
                  'title': 'INV/2026/4471',
                  'date_label': '18/08/2026',
                  'amount_label': '₹9,540.57',
                  'status': 'imported',
                  'status_label': 'Accepted',
                  'status_tone': 'success',
                },
              ])
            : _bills();
      })));
      await tester.pumpAndSettle();

      expect(find.text('INV/2026/4471'), findsOneWidget);
      expect(find.text('₹9,540.57'), findsOneWidget);
      expect(find.text('Accepted'), findsOneWidget);
      expect(find.text('1 bills'), findsOneWidget);

      withRows = false;
      final state =
          tester.state<SupplierBillsTabState>(find.byType(SupplierBillsTab));
      await state.search();
      await tester.pumpAndSettle();
      expect(find.text('No bills match that search.'), findsOneWidget);
    });

    testWidgets('the detail sheet prints the verify status and the linked '
        'payments the backend sent', (tester) async {
      await tester.pumpWidget(_host(SupplierBillDetailView(payload: const {
        'ok': true,
        'id': 'bill-1',
        'title': 'INV/2026/4471',
        'header': [
          {'label': 'Invoice no.', 'value': 'INV/2026/4471'},
          {'label': 'Received', 'value': '18/08/2026 10:41'},
        ],
        'verify_status': 'imported',
        'verify_label': 'Accepted',
        'verify_tone': 'success',
        'amount_label': '₹9,540.57',
        'lines_heading': 'What we read on this bill',
        'lines_empty': 'No lines matched on this bill yet.',
        'lines': [
          {
            'product_name': 'Cyblex S 60XR Tablet SR',
            'qty_label': 'Qty 3',
            'amount_label': '₹695.40',
            'verified': true,
            'verify_label': 'Verified',
            'verify_tone': 'success',
          },
        ],
        'payments_heading': 'Payments linked to this bill',
        'payments_empty': 'No payment recorded against this bill yet.',
        'payments': [
          {
            'id': 'p1',
            'amount_label': '₹5,000.00',
            'mode': 'upi',
            'utr': '4471X',
            'at_label': '20/08/2026 16:02',
            'note': '',
          },
        ],
        'paid_label': '₹5,000.00 paid against this bill',
      })));
      await tester.pumpAndSettle();

      expect(find.text('Accepted'), findsOneWidget);
      expect(find.text('₹9,540.57'), findsOneWidget);
      expect(find.text('Verified'), findsOneWidget);
      expect(find.text('₹5,000.00'), findsOneWidget);
      expect(find.text('₹5,000.00 paid against this bill'), findsOneWidget);
    });
  });
}
