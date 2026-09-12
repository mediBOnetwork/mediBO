// PROTECTED — CHANGE #320.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes GST rendering.
//
// GST is the one screen where a number invented in Dart becomes a number filed
// with the government. So what this holds down is that the screen invents
// nothing:
//
//   1. Every rupee string is printed VERBATIM from the payload. `inr_money()`
//      in Postgres formats it; Dart never adds up, re-rounds or re-formats a
//      figure — not the output tax, not the credit, not the net.
//   2. The net line's WORD is the backend's. A month in credit says "Credit
//      carried forward", a month in debit says "Cash payable" — Dart never
//      picks between them from the sign of a number it computed.
//   3. Table columns, their labels, their ORDER and their alignment all arrive
//      in the payload. A return whose column order is decided in Dart is a
//      return that silently stops matching the portal.
//   4. Absence is explicit. A section that sent `empty` renders the backend's
//      sentence, never a Dart default and never a bare zero.
//   5. The GSTR-2B verdict is the backend's `status_label` + `tone`, printed as
//      given — the screen never re-derives "matched" from the numbers.
//   6. Credit is grouped by the SOURCE the backend grouped it by, invoice
//      numbers and dates included, in payload order.
//
// No network, no Supabase, no goldens — the screen is pumped through its
// `rpc` test seam against a fixture.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_gst_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// A month in DEBIT: output 131.67, credit 61.67, so 70.00 is payable.
Map<String, dynamic> _payload({bool inCredit = false}) => {
      'ok': true,
      'title': 'GST',
      'subtitle': 'Input credit, monthly position and GSTR exports',
      'seller_label': '22BXXPJ8518F1Z4  ·  Chhattisgarh (22)',
      'period_key': '2026-08-01',
      'period_label': 'August 2026',
      'periods': [
        {'key': '2026-08-01', 'label': 'August 2026', 'selected': true},
        {'key': '2026-07-01', 'label': 'July 2026', 'selected': false},
      ],
      'tabs': [
        {'key': 'position', 'label': 'Position'},
        {'key': 'credit', 'label': 'Input credit'},
        {'key': 'exports', 'label': 'Exports'},
        {'key': 'recon', 'label': 'GSTR-2B'},
      ],
      'rebuild_label': 'Rebuild ledger',
      'retry_label': 'Retry',
      'position': {
        'heading': 'How this month is worked out',
        'note': 'Output tax minus input credit.',
        'empty': null,
        'rows': [
          {
            'label': 'Output tax on sales',
            'sub': 'on ₹1,233.31 taxable',
            'value_label': '₹131.67',
            'tone': 'neutral',
          },
          {
            'label': 'Less: input credit on purchases',
            'sub': 'on ₹900.00 taxable',
            'value_label': '- ₹61.67',
            'tone': 'success',
          },
        ],
        // The backend chose both the word and the figure.
        'net_label': inCredit ? 'Credit carried forward' : 'Cash payable',
        'net_value_label': '₹70.00',
        'net_is_payable': !inCredit,
        'net_tone': inCredit ? 'success' : 'warning',
        'head_columns': [
          {'key': 'label', 'label': 'Head', 'align': 'left'},
          {'key': 'output_label', 'label': 'Output', 'align': 'right'},
          {'key': 'input_label', 'label': 'Credit', 'align': 'right'},
          {'key': 'net_label', 'label': 'Net', 'align': 'right'},
        ],
        'heads': [
          {
            'label': 'CGST',
            'output_label': '₹65.84',
            'input_label': '₹30.84',
            'net_label': '₹35.00',
          },
          {
            'label': 'SGST',
            'output_label': '₹65.83',
            'input_label': '₹30.83',
            'net_label': '₹35.00',
          },
          {
            'label': 'IGST',
            'output_label': '₹0.00',
            'input_label': '₹0.00',
            'net_label': '₹0.00',
          },
        ],
      },
      'credit': {
        'heading': 'Where the credit came from',
        'empty': null,
        'total_label': '₹61.67',
        'suppliers': [
          {
            'name': 'BHARAT SALES',
            'gstin_label': '22ABCDE1234F1Z5  ·  Chhattisgarh (22)',
            'has_gstin': true,
            'credit_label': '₹50.00',
            'taxable_label': '₹900.00',
            'count_label': '2 invoices',
            'invoices': [
              {
                'invoice_no': 'INV/LOC/1',
                'date_label': '05/08/2026',
                'taxable_label': '₹900.00',
                'tax_label': '₹50.00',
              },
            ],
          },
          {
            'name': 'PROBE NO-GSTIN SUP',
            'gstin_label': 'Supplier GSTIN missing',
            'has_gstin': false,
            'credit_label': '₹11.67',
            'taxable_label': '₹233.31',
            'count_label': '1 invoice',
            'invoices': const [],
          },
        ],
      },
      'exports': {
        'heading': 'Returns',
        'copy_hint': 'Copy the table and hand it to your CA.',
        'empty': null,
        'blocks': [
          {
            'key': 'gstr3b',
            'title': 'GSTR-3B · summary',
            'columns': [
              {'key': 'row', 'label': 'Row', 'align': 'left'},
              {'key': 'label', 'label': 'Description', 'align': 'left'},
              {'key': 'taxable', 'label': 'Taxable', 'align': 'right'},
            ],
            'rows': [
              {
                'row': '3.1(a)',
                'label': 'Outward taxable supplies',
                'taxable': '₹1,233.31',
              },
            ],
            'csv_header': 'row,description,taxable',
            'csv': '3.1(a),Outward taxable supplies,1233.31',
          },
        ],
      },
      'recon': {
        'heading': 'Credit that has not shown up',
        'note': 'A supplier who has not filed leaves you without the credit.',
        'empty': null,
        'rows': [
          {
            'supplier': 'BHARAT SALES',
            'gstin': '22ABCDE1234F1Z5',
            'invoice_no': 'INV/LOC/1',
            'date_label': '05/08/2026',
            'taxable_label': '₹900.00',
            'tax_label': '₹50.00',
            'status': 'pending',
            'status_label': 'Not in GSTR-2B',
            'tone': 'warning',
          },
        ],
        'at_risk_label': '₹50.00',
        'summary_label': '1 invoice  ·  ₹50.00 of credit not confirmed',
        'has_2b': false,
        'source_label': 'No GSTR-2B loaded for this month',
        'excluded_label': '3 purchase lines held back until the bill is fixed',
        'import_label': 'Paste GSTR-2B',
        'import_hint': 'One row per line: GSTIN, invoice no, date, taxable, tax.',
      },
    };

int _pumpSeq = 0;

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload,
    {List<String>? calls}) async {
  // A fresh key per pump: without it Flutter reuses the State (same type, same
  // null key) and initState never re-runs, so the second payload is ignored.
  await tester.pumpWidget(MaterialApp(
    home: AdminGstScreen(
      key: ValueKey(_pumpSeq++),
      rpc: (fn, params) async {
        calls?.add(fn);
        return payload;
      },
    ),
  ));
  await tester.pumpAndSettle();
}

/// Taps a chip by its label — the tabs and the period picker are both chips.
Future<void> _tap(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    // RenderLog.write debounces 800 ms on a real Timer that would outlive the
    // test and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  testWidgets('the position prints the backend rupee strings verbatim',
      (tester) async {
    await _pump(tester, _payload());

    // The three figures of the working, exactly as Postgres formatted them.
    expect(find.text('₹131.67'), findsOneWidget);
    expect(find.text('- ₹61.67'), findsOneWidget);
    expect(find.text('₹70.00'), findsOneWidget);
    // ...and the sub-lines that say what each is charged on.
    expect(find.text('on ₹1,233.31 taxable'), findsOneWidget);
    expect(find.text('on ₹900.00 taxable'), findsOneWidget);

    // Nothing was re-derived: 131.67 - 61.67 is never recomputed and printed
    // with a different shape.
    expect(find.text('70.0'), findsNothing);
    expect(find.text('₹70'), findsNothing);
  });

  testWidgets('the net line takes its WORD from the backend, not the sign',
      (tester) async {
    await _pump(tester, _payload());
    expect(find.text('Cash payable'), findsOneWidget);
    expect(find.text('Credit carried forward'), findsNothing);

    // Same numbers, backend says it is credit — the screen must follow it.
    await _pump(tester, _payload(inCredit: true));
    expect(find.text('Credit carried forward'), findsOneWidget);
    expect(find.text('Cash payable'), findsNothing);
  });

  testWidgets('head columns render in payload order with payload labels',
      (tester) async {
    await _pump(tester, _payload());

    for (final label in ['Head', 'Output', 'Credit', 'Net']) {
      expect(find.text(label), findsOneWidget,
          reason: '\$label is the backend\'s column label');
    }
    // Left to right in the order the payload listed them — a return whose
    // column order is decided in Dart stops matching the portal silently.
    final xs = ['Head', 'Output', 'Credit', 'Net']
        .map((l) => tester.getTopLeft(find.text(l)).dx)
        .toList();
    expect(xs, orderedEquals(List.of(xs)..sort()));
    // The per-head split, verbatim — including the deliberate 65.84 / 65.83
    // asymmetry that makes CGST + SGST come to exactly the tax.
    expect(find.text('₹65.84'), findsOneWidget);
    expect(find.text('₹65.83'), findsOneWidget);
  });

  testWidgets('an empty section renders the backend sentence, not a zero',
      (tester) async {
    final p = _payload();
    (p['position'] as Map)['empty'] = 'Nothing billed in this month yet.';
    await _pump(tester, p);

    expect(find.text('Nothing billed in this month yet.'), findsOneWidget);
    // The working is gone entirely — no "₹0.00" row invented in its place.
    expect(find.text('How this month is worked out'), findsNothing);
    expect(find.text('₹0.00'), findsNothing);
  });

  testWidgets('credit is grouped by source, in payload order, with invoices',
      (tester) async {
    await _pump(tester, _payload());
    await _tap(tester, 'Input credit');

    expect(find.text('Where the credit came from'), findsOneWidget);
    expect(find.text('₹61.67'), findsOneWidget); // the total, backend-made

    // Both sources, and the invoice number + date the credit came on.
    expect(find.text('BHARAT SALES'), findsOneWidget);
    expect(find.text('INV/LOC/1'), findsOneWidget);
    expect(find.text('05/08/2026'), findsOneWidget);
    expect(find.text('2 invoices'), findsOneWidget);

    // A missing GSTIN is the backend's sentence, not a Dart fallback.
    expect(find.text('Supplier GSTIN missing'), findsOneWidget);

    // Payload order: BHARAT SALES is listed above the no-GSTIN supplier.
    final first = tester.getTopLeft(find.text('BHARAT SALES')).dy;
    final second = tester.getTopLeft(find.text('PROBE NO-GSTIN SUP')).dy;
    expect(first, lessThan(second));
  });

  testWidgets('a return renders the backend columns and rows verbatim',
      (tester) async {
    await _pump(tester, _payload());
    await _tap(tester, 'Exports');

    expect(find.text('GSTR-3B · summary'), findsOneWidget);
    for (final label in ['Row', 'Description', 'Taxable']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('3.1(a)'), findsOneWidget);
    expect(find.text('Outward taxable supplies'), findsOneWidget);
    expect(find.text('₹1,233.31'), findsOneWidget);
  });

  testWidgets('the GSTR-2B verdict is the backend label and tone', (tester) async {
    await _pump(tester, _payload());
    await _tap(tester, 'GSTR-2B');

    expect(find.text('Not in GSTR-2B'), findsOneWidget);
    expect(find.text('1 invoice  ·  ₹50.00 of credit not confirmed'),
        findsOneWidget);
    expect(find.text('No GSTR-2B loaded for this month'), findsOneWidget);
    // Lines held back are SURFACED, never silently dropped.
    expect(find.text('3 purchase lines held back until the bill is fixed'),
        findsOneWidget);
    // The screen never invents its own verdict word.
    expect(find.text('Matched'), findsNothing);
  });

  testWidgets('changing the period refetches from the backend', (tester) async {
    final calls = <String>[];
    await _pump(tester, _payload(), calls: calls);
    expect(calls, ['admin_gst_screen']);

    await _tap(tester, 'July 2026');
    expect(calls, ['admin_gst_screen', 'admin_gst_screen'],
        reason: 'a period is a new backend question, not a client-side filter');
  });
}
