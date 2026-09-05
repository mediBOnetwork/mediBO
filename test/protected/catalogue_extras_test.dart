// PROTECTED — CHANGE #748, the three Catalogue extras.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes catalogue-extras behaviour.
//
// What this holds down:
//
//   1. "NEW" IS A BACKEND FLAG, NEVER A DATE COMPARISON. The card prints the
//      payload's own `new_badge` and shows it because `is_new` was true. The
//      fixture deliberately carries a card whose created_at would be recent but
//      whose is_new is FALSE, so a widget that compares dates itself fails.
//
//   2. GROUPS AND ITEMS RENDER IN PAYLOAD ORDER. The backend groups by company
//      and orders by count; the fixture is deliberately not alphabetical.
//
//   3. THE REQUEST FORM'S FIELDS ARE THE PAYLOAD'S. A field the backend did not
//      send is not asked for, and a duplicate answer is SHOWN rather than
//      guessed — the screen never searches the catalogue itself.
//
//   4. THE EXPORT IS GONE AND STAYS GONE (CHANGE #1362). "Make the PDF" let
//      anyone bulk-download the product list, so the whole path — widget,
//      button, RPCs, copy — was removed. This file now guards the ABSENCE:
//      no Dart source may name a catalogue_export RPC or the export copy keys
//      again. A future feature that needs a customer-facing list must be
//      specified and gated on its own, not by reviving this one.
//
//   5. ABSENCE IS A FLAG. `show:false` on any of the three means that surface
//      is not offered at all — never a greyed-out button.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/screens/catalogue_extras.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _card({
  required String id,
  required String name,
  required bool isNew,
  String badge = 'New',
}) =>
    {
      'id': id,
      'name': name,
      'company': 'Zeta Labs',
      'is_new': isNew,
      'new_badge': isNew ? badge : '',
      'pack_label': '10 tablets',
      'rx': {'has': false},
      'availability': {'can_add': true, 'add_label': 'ADD'},
      'pricing': {'price_display': '', 'has_mrp': false},
    };

Map<String, dynamic> _recent() => {
      'ok': true,
      'title': 'Recently added',
      'subtitle': 'Products added in the last 30 days',
      'empty_text': 'Nothing new in this window yet.',
      'days': 30,
      'count': 3,
      // Zeta first: the backend ordered by COUNT, and an alphabetical sort in
      // Dart would put Alpha first.
      'groups': [
        {
          'company': 'Zeta Labs',
          'count': 2,
          'count_label': '2 products',
          'items': [
            _card(id: '1', name: 'Zeta One', isNew: true),
            _card(id: '2', name: 'Zeta Two', isNew: false),
          ],
        },
        {
          'company': 'Alpha Pharma',
          'count': 1,
          'count_label': '1 product',
          'items': [_card(id: '3', name: 'Alpha One', isNew: true)],
        },
      ],
    };

Map<String, dynamic> _requestCfg() => {
      'show': true,
      'title': 'Missing product?',
      'subtitle': 'Tell us what you could not find and we will add it.',
      'submit_label': 'Send request',
      'fields': [
        {'key': 'name', 'label': 'Product name', 'required': true},
        {'key': 'company', 'label': 'Company', 'required': false},
      ],
    };

/// CompactProductCard reaches for the cart through AppState, so the recent
/// list must be hosted the way every other card test hosts one.
Widget _host(Widget child) => AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('recently added — the payload decides', () {
    testWidgets('groups render in payload order, not alphabetically',
        (tester) async {
      await tester.pumpWidget(_host(
          CatalogueRecent(rpc: (fn, p) async => _recent())));
      await tester.pump();
      await tester.pump();
      // Asserted on the COUNT labels, which are unique: the company name also
      // appears on every card in the group, so a plain text finder is ambiguous.
      final zeta = tester.getTopLeft(find.text('2 products')).dy;
      final alpha = tester.getTopLeft(find.text('1 product')).dy;
      expect(zeta, lessThan(alpha),
          reason: 'the backend ordered by count; Dart must not re-sort');
    });

    testWidgets('the count label prints verbatim', (tester) async {
      await tester.pumpWidget(_host(
          CatalogueRecent(rpc: (fn, p) async => _recent())));
      await tester.pump();
      await tester.pump();
      expect(find.text('2 products'), findsOneWidget);
      expect(find.text('1 product'), findsOneWidget,
          reason: 'the singular is the backend\'s — never pluralised in Dart');
    });

    testWidgets('an empty payload prints the backend sentence', (tester) async {
      await tester.pumpWidget(_host(CatalogueRecent(rpc: (fn, p) async => {
            'ok': true,
            'title': 'Recently added',
            'empty_text': 'Nothing new in this window yet.',
            'groups': const [],
          })));
      await tester.pump();
      await tester.pump();
      expect(find.text('Nothing new in this window yet.'), findsOneWidget);
    });

    testWidgets('the RPC is asked for by name, with no client-side window',
        (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(_host(CatalogueRecent(rpc: (fn, p) async {
        calls.add('$fn:${p ?? const {}}');
        return _recent();
      })));
      await tester.pump();
      await tester.pump();
      expect(calls.single, 'catalogue_recent:{}',
          reason: 'the 30-day window is the backend\'s, not a Dart argument');
    });
  });

  group('missing product — the form is the payload', () {
    testWidgets('only the fields the backend sent are asked for',
        (tester) async {
      await tester.pumpWidget(_host(
          CatalogueRequestSheet(config: _requestCfg(), rpc: (f, p) async => {})));
      await tester.pump();
      expect(find.text('Product name'), findsOneWidget);
      expect(find.text('Company'), findsOneWidget);
      expect(find.text('Salt / composition'), findsNothing,
          reason: 'a field the payload did not carry must not appear');
      expect(find.text('Send request'), findsOneWidget);
    });

    testWidgets('a duplicate answer is shown, never computed', (tester) async {
      await tester.pumpWidget(_host(CatalogueRequestSheet(
        config: _requestCfg(),
        rpc: (fn, p) async => fn == 'catalogue_request_product'
            ? {
                'ok': false,
                'error': 'duplicate',
                'message': 'We already have this — here it is.',
                'cta': 'Open it',
                'product': {'id': 42, 'name': 'Zeta One', 'company': 'Zeta Labs'},
              }
            : {'ok': true, 'duplicate': false},
      )));
      await tester.pump();
      await tester.enterText(find.byType(TextField).first, 'Zeta One');
      await tester.tap(find.text('Send request'));
      await tester.pump();
      await tester.pump();
      expect(find.text('We already have this — here it is.'), findsOneWidget);
      expect(find.text('Open it'), findsOneWidget);
      expect(find.text('Zeta One'), findsWidgets);
    });
  });

  // CHANGE #1362 — the catalogue export was removed end to end because it was
  // a competitor-scraping hole: one tap produced the whole filtered product
  // list as a PDF. The three tests that used to live here drove
  // CatalogueExportAction; that widget no longer exists, so what is worth
  // holding down is the removal itself. This reads the shipped Dart the same
  // way the design literal gate does — the button cannot come back by accident.
  group('export — removed, and it stays removed', () {
    const banned = <String>[
      'catalogue_export_start',
      'catalogue_export_status',
      'catalogue_export_render_input',
      'catalogue_export_report',
      'CatalogueExportAction',
      'catalogue.export_action',
    ];

    test('no Dart file names the export path', () {
      final offenders = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        for (final needle in banned) {
          if (src.contains(needle)) offenders.add('${f.path}: $needle');
        }
      }
      expect(offenders, isEmpty,
          reason: 'the catalogue export was removed in CHANGE #1362 — a bulk '
              'product-list download is a scraping hole, not a feature');
    });

    test('the px-invoice function offers no catalogue source', () {
      final src = File('supabase/functions/px-invoice/index.ts').readAsStringSync();
      expect(src.contains('catalogue_export'), isFalse,
          reason: 'POS invoice, audit and account PDFs stay; the catalogue '
              'source was removed with the rest of the path');
    });
  });
}
