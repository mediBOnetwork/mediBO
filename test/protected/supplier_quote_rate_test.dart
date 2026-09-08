// PROTECTED — CHANGE #353. feature_gaps #59 + #29 (one root cause).
//
// THE BUG THIS RETIRES
//   submit_inquiry_form() validated a supplier's answer against exactly three
//   strings — 'Available', 'Out of Stock', "We don't stock this product" — and
//   there was no rate, PTR, discount or scheme field anywhere in the answer
//   path (#59). With no quote to price from, the purchase order fell back to
//   MRP: supplier_orders.items[] carried {mrp, quantity, ...} and total_amount
//   was SUM(mrp * qty) (#29). legal_get_page('about') is explicit — MRP is the
//   legal ceiling and a display field, NEVER the selling price, and any build
//   that prices or reports on MRP is wrong.
//
// The backend half is pinned by the rg behaviour test
// `supplier_quote_prices_the_po` (4 units quoted at 62.50 must total 250.00,
// not the 400.00 MRP figure) — and rg_check red blocks every dev_cmd_complete.
// This file holds the half a migration cannot: the supplier-facing PO renders
// the backend's own pricing words and NUMBERS, and computes nothing.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/po_pricing.dart';
import 'package:pharma_b2b/utils/render_log.dart';

String _read(String path) {
  final f = File(path);
  if (!f.existsSync()) throw StateError('$path is missing — did it move?');
  return f.readAsStringSync();
}

/// Strips comments so a phrase quoted in a comment cannot satisfy a scan.
String _code(String src) {
  src = src.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  final out = StringBuffer();
  for (final line in src.split('\n')) {
    final i = line.indexOf('//');
    out.writeln(i >= 0 ? line.substring(0, i) : line);
  }
  return out.toString();
}

const _migration =
    'supabase/migrations/20260831_cmd353_supplier_critical.sql';

/// A pricing block shaped exactly like po_pricing_block(). The strings are
/// deliberately NOT the production copy: if the widget ever hardcodes the real
/// wording instead of printing what it was handed, these fail.
Map<String, dynamic> _pricing({
  String basis = 'quote',
  String tone = 'success',
}) =>
    {
      'has': true,
      'basis': basis,
      'tone': tone,
      'label': 'BASIS-LABEL-FROM-BACKEND',
      'rate_pending': 0,
      'payable_total': 250.0,
      'payable_display': 'PAYABLE-DISPLAY-FROM-BACKEND',
      'payable_label': 'PAYABLE-LABEL-FROM-BACKEND',
      'mrp_total': 400.0,
      'mrp_display': 'MRP-DISPLAY-FROM-BACKEND',
      'mrp_note': 'MRP-NOTE-FROM-BACKEND',
    };

Map<String, dynamic> _line() => {
      'product_id': '181726',
      'product_name': 'PROBE',
      'quantity': 4,
      'rate': 62.5,
      'rate_source': 'quote',
      'rate_display': 'RATE-DISPLAY-FROM-BACKEND',
      'line_total': 250.0,
      'line_total_display': 'LINE-TOTAL-FROM-BACKEND',
      'mrp_display': 'MRP-LINE-FROM-BACKEND',
      'price_basis_label': 'LINE-BASIS-FROM-BACKEND',
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('the PO prints the backend\'s pricing — it never re-derives it', () {
    testWidgets('banner renders label, payable and the MRP note verbatim',
        (tester) async {
      await _pump(tester, PoPricingBanner(pricing: _pricing()));

      expect(find.text('BASIS-LABEL-FROM-BACKEND'), findsOneWidget);
      expect(find.text('PAYABLE-LABEL-FROM-BACKEND'), findsOneWidget);
      expect(find.text('PAYABLE-DISPLAY-FROM-BACKEND'), findsOneWidget);
      expect(find.text('MRP-NOTE-FROM-BACKEND'), findsOneWidget);
    });

    testWidgets('the payable figure is the backend string, never a rebuild '
        'of payable_total in Dart', (tester) async {
      await _pump(tester, PoPricingBanner(pricing: _pricing()));

      // 250.0 is in the payload as a number. If it ever appears on screen the
      // widget has formatted money itself — which is exactly how the PO ended
      // up quoting MRP figures nobody had priced.
      expect(find.textContaining('250'), findsNothing);
      expect(find.textContaining('₹'), findsNothing);
      expect(find.textContaining('400'), findsNothing);
    });

    testWidgets('no pricing block at all → the banner is ABSENT, not a default',
        (tester) async {
      await _pump(tester, const PoPricingBanner(pricing: null));
      expect(find.byType(Text), findsNothing);

      await _pump(tester, const PoPricingBanner(pricing: {'has': false}));
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('a line prints its rate, its source label and its line total',
        (tester) async {
      await _pump(tester, PoRateLine(item: _line()));

      expect(find.text('LINE-BASIS-FROM-BACKEND'), findsOneWidget);
      expect(find.text('RATE-DISPLAY-FROM-BACKEND'), findsOneWidget);
      expect(find.text('LINE-TOTAL-FROM-BACKEND'), findsOneWidget);
      // the raw numbers stay raw
      expect(find.textContaining('62.5'), findsNothing);
    });

    testWidgets('a line the backend priced nothing on renders nothing',
        (tester) async {
      await _pump(tester, PoRateLine(item: const {
            'product_id': '1',
            'product_name': 'PROBE',
            'quantity': 4,
          }));
      expect(find.byType(Text), findsNothing);
    });
  });

  group('the migration keeps the rules it was written for', () {
    final sql = _code(_read(_migration));

    test('the PO is priced by ONE function, used by every writer', () {
      expect(sql, contains('create or replace function public.po_retotal'));
      for (final writer in const [
        '_po_merge_inquiry_lines',
        'inquiry_to_supplier_orders',
        'rebuild_all_supplier_orders',
      ]) {
        final body = sql.substring(sql.indexOf('function public.$writer'));
        final end = body.indexOf(r'$function$;');
        expect(body.substring(0, end), contains('po_retotal'),
            reason: '$writer must price through po_retotal, never sum(mrp*qty)');
      }
    });

    test('the supplier can quote: the answer path stores a rate', () {
      expect(sql, contains('create table if not exists public.supplier_quote'));
      expect(sql.toLowerCase(), contains('insert into supplier_quote'));
      // and the rate is only meaningful with stock
      expect(sql, contains('a rate is meaningless without stock'));
    });

    test('MRP stays a reference, never the price', () {
      // the fallback exists, but it is FLAGGED, never silent
      expect(sql, contains("'pending'"));
      expect(sql, contains('rate_source'));
      expect(sql, contains('mrp_total'));
    });

    test('the takeover fallback is gone (#24)', () {
      expect(sql, contains('public.identity_norm(p_email) = any (v_keys)'));
    });

    test('the bill panel checks ownership and drops anon (#25)', () {
      expect(sql, contains('OWNERSHIP GATE'));
      expect(sql,
          contains('revoke execute on function public.sup_order_bill_panel(uuid) from public, anon'));
    });

    test('the timeout keys off the dispatch stamp (#34)', () {
      final body = sql.substring(sql.indexOf('function public.timeout_advance'));
      final end = body.indexOf(r'$function$;');
      expect(body.substring(0, end), contains('asked_at IS NOT NULL'));
      expect(body.substring(0, end), contains("coalesce(current_status,'')"));
    });
  });
}
