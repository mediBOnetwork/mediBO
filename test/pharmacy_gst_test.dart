// CMD #416 — the GST pack renders the backend's return and computes no tax.
//
// The pinned contract, on the surface where getting it wrong has a legal
// deadline attached:
//   * every rupee on the position is the payload's string — the screen never
//     nets output against input for itself
//   * an export table is drawn from the payload's OWN columns[], so a new
//     column is a backend change and an unknown one cannot crash the page
//   * Copy puts the BACKEND's csv on the clipboard, header included — never a
//     table this screen re-serialised
//   * the month chips send the backend's own period string back
//   * the filing banner prints the backend's sentence and there is no button
//     anywhere that claims a return was filed
//   * a refusal renders the backend's message with no Retry
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/pharmacy/pharmacy_gst_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _home() => {
  'ok': true,
  'title': 'GST pack',
  'subtitle': 'Your purchase and sales registers, ready for your CA',
  'period': '2026-09-01',
  'period_label': 'Sep 2026',
  'months': [
    {'period': '2026-09-01', 'label': 'Sep 2026', 'selected': true},
    {'period': '2026-08-01', 'label': 'Aug 2026', 'selected': false},
  ],
  'gstin_label': 'Filing as 22AAATE1234T1Z5',
  'has_gstin': true,
  'position': {
    'heading': 'This month',
    'tiles': [
      {'key': 'output', 'label': 'Tax you collected', 'value': '₹5.01', 'tone': 'warning'},
      {'key': 'input', 'label': 'Credit you can claim', 'value': '₹52.62', 'tone': 'ok'},
      {'key': 'net', 'label': 'Net payable', 'value': '₹0.00', 'tone': 'ok'},
    ],
    'note': 'Counter sales carry the tax you collected.',
  },
  'tabs': [
    {'key': 'position', 'label': 'Position'},
    {'key': 'purchase', 'label': 'Purchases'},
    {'key': 'sales', 'label': 'Sales'},
    {'key': 'exports', 'label': 'Returns'},
  ],
  'purchase': {
    'heading': 'Purchase register',
    'add_label': 'Add outside bill',
    'total_label': '₹333.50',
    'tax_label': '₹52.62',
    'empty': null,
    'rows': [
      {
        'invoice_no': 'SM/2026/1187',
        'date_label': '01 Sep',
        'party': 'Sharma Medicos',
        'gstin': '22AAACS1429B1ZG',
        'has_gstin': true,
        'source_label': 'Outside',
        'taxable_label': '₹333.50',
        'tax_label': '₹52.62',
        'lines_label': '3 items',
      },
    ],
  },
  'sales': {
    'heading': 'Sales register',
    'total_label': '₹646.62',
    'tax_label': '₹5.01',
    'empty': null,
    'rows': [
      {
        'invoice_no': 'INV/2026-27/00001',
        'date_label': '01 Sep',
        'party': 'Counter sale',
        'taxable_label': '₹41.82',
        'tax_label': '₹5.01',
        'lines_label': '2 items',
      },
    ],
  },
  'exports': {
    'heading': 'Returns',
    'note': 'These are the GSTR-1 and GSTR-3B tables in the shape the portal expects.',
    'blocks': [
      {
        'key': 'gstr3b',
        'title': 'GSTR-3B · summary',
        'columns': [
          {'key': 'row', 'label': 'Row', 'align': 'left'},
          {'key': 'label', 'label': 'Description', 'align': 'left'},
          {'key': 'cgst', 'label': 'CGST', 'align': 'right'},
        ],
        'rows': [
          {'row': '3.1(a)', 'label': 'Outward taxable supplies', 'cgst': '2.51'},
          {'row': '4(A)(5)', 'label': 'ITC available', 'cgst': '26.31'},
        ],
        'csv_header': 'row,description,cgst',
        'csv': '3.1(a),Outward taxable supplies,2.51\n4(A)(5),ITC available,26.31',
      },
    ],
  },
  'filing': {
    'mode': 'download',
    'can_file': false,
    'label': 'Download for filing',
    'note': 'mediBO prepares the return; it does not file it. Filing happens on the GST portal.',
  },
  'copy': {
    'pack_button': 'Monthly pack for your CA',
    'pack_working': 'Preparing the pack…',
    'copy_button': 'Copy table',
    'copied': 'Copied',
    'retry': 'Retry',
    'error_generic': 'Could not load the GST pack.',
    'save': 'Save',
    'saving': 'Saving…',
    'add_title': 'Outside purchase bill',
    'f_supplier': 'Supplier',
    'f_gstin': 'Supplier GSTIN',
    'f_invoice': 'Invoice number',
    'f_date': 'Invoice date',
    'f_taxable': 'Taxable value',
    'f_rate': 'GST %',
    'f_hsn': 'HSN',
  },
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  Future<List<List<Object?>>> pump(
    WidgetTester tester,
    Map<String, dynamic> Function(String fn, Map<String, dynamic> p) answer,
  ) async {
    final calls = <List<Object?>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PharmacyGstScreen(
          rpc: (fn, p) async {
            calls.add([fn, p]);
            return answer(fn, p);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return calls;
  }

  testWidgets('the position is the payload\'s rupees, never a Dart subtraction',
      (t) async {
    await pump(t, (fn, p) => _home());

    expect(find.text('₹5.01'), findsOneWidget);
    expect(find.text('₹52.62'), findsOneWidget);
    // 5.01 - 52.62 would be negative; the BACKEND floored it at zero and sent
    // that string. A screen doing its own arithmetic would print something else.
    expect(find.text('₹0.00'), findsOneWidget);
    expect(find.text('Tax you collected'), findsOneWidget);
  });

  testWidgets('the filing banner is honest and nothing offers to file', (t) async {
    await pump(t, (fn, p) => _home());

    expect(
      find.textContaining('does not file it'),
      findsOneWidget,
      reason: 'there is no GSP behind this build; the screen must say so',
    );
    expect(find.textContaining('Filed'), findsNothing);
    expect(find.textContaining('File now'), findsNothing);
  });

  testWidgets('an export table is drawn from the payload\'s own columns', (t) async {
    await pump(t, (fn, p) => _home());
    await t.tap(find.text('Returns').last);
    await t.pumpAndSettle();

    expect(find.text('GSTR-3B · summary'), findsOneWidget);
    // Header labels come from columns[], values from rows[] keyed by column key.
    expect(find.text('Description'), findsOneWidget);
    expect(find.text('CGST'), findsOneWidget);
    expect(find.text('3.1(a)'), findsOneWidget);
    expect(find.text('26.31'), findsOneWidget);
    // A column the payload did NOT send is not drawn.
    expect(find.text('IGST'), findsNothing);
  });

  testWidgets('Copy puts the backend\'s own CSV on the clipboard', (t) async {
    String? copied;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );

    await pump(t, (fn, p) => _home());
    await t.tap(find.text('Returns').last);
    await t.pumpAndSettle();
    await t.tap(find.text('Copy table'));
    await t.pumpAndSettle();

    expect(copied, isNotNull);
    expect(copied, startsWith('row,description,cgst\n'));
    expect(copied, contains('4(A)(5),ITC available,26.31'));
  });

  testWidgets('a month chip sends the backend\'s own period string', (t) async {
    final calls = await pump(t, (fn, p) => _home());
    calls.clear();

    await t.tap(find.text('Aug 2026'));
    await t.pumpAndSettle();

    final home = calls.firstWhere((c) => c[0] == 'pharmacy_gst_home');
    expect((home[1] as Map<String, dynamic>)['p_period'], '2026-08-01');
  });

  testWidgets('the registers print verbatim, including the source and plural',
      (t) async {
    await pump(t, (fn, p) => _home());
    await t.tap(find.text('Purchases').last);
    await t.pumpAndSettle();

    expect(find.text('Sharma Medicos'), findsOneWidget);
    expect(find.text('₹333.50'), findsWidgets);
    expect(find.textContaining('SM/2026/1187'), findsOneWidget);
    expect(find.textContaining('3 items'), findsOneWidget);
    expect(find.textContaining('Outside'), findsOneWidget);
  });

  testWidgets('a refusal shows the backend message and offers no Retry', (t) async {
    await pump(t, (fn, p) => {
      'ok': false,
      'error': 'not_a_pharmacy',
      'message': 'The GST pack is for a pharmacy account.',
    });

    expect(find.text('The GST pack is for a pharmacy account.'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
