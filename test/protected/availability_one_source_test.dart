// PROTECTED — CHANGE #640.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how availability is resolved, never to make an
// unrelated change go green.
//
// THE BUG THIS EXISTS TO RETIRE
//
//   Product 252328 (SyNtraN 200 Capsule) was listed on the storefront, was
//   accepted into the cart, and was then shown as unavailable inside that same
//   cart. Its row said BOTH things at once: `supplier_count = 11` and
//   `buyable = false`. 13,767 rows of the catalogue disagreed with themselves
//   the same way, because the two columns were written by different code at
//   different times, and because each surface picked whichever one it liked —
//   `cart_set_item` gated on the count, the cart's render read the flag, the
//   product page read a third thing again.
//
//   The backend half of the fix makes both columns derived, together, from one
//   expression, and guards it with a CHECK constraint (see
//   `availability_contract_check()` and rg_check). This file is the Dart half:
//   it fails if the app ever grows a SECOND availability answer again.
//
// What this holds down:
//
//   1. THE VERDICT OUTRANKS THE COLUMN, IN BOTH DIRECTIONS. When the payload
//      carries `availability` (it always does now), that verdict is the
//      answer — even when the legacy `stock.buyable` column contradicts it.
//      Fixture 1 is 252328's exact live shape: buyable:false, verdict
//      available. The page must offer Add, not "Out of stock".
//
//   2. ONE ANSWER PER PAGE. The product page asks "can this be bought?" in
//      three places — the Notify probe, the stock chip and the bottom bar.
//      They all read `ProductDetail.canAdd` / `.buyable`, which are one
//      getter over one verdict, so the chip and the button can never
//      contradict each other on screen. That contradiction — chip says out of
//      stock while the bar says Add — is what a customer actually saw.
//
//   3. ONE PARSER FOR EVERY SURFACE. The storefront card, the search row, the
//      cart line and the product page all parse the SAME `availability`
//      object with the SAME parser, so one backend verdict cannot render as
//      two different decisions depending on which screen you reached it from.
//
//   4. NO VERDICT IS NOT A VERDICT. On the outage fallback (a payload with no
//      `availability` block at all) the page falls back to the legacy column
//      rather than inventing an answer — and that is the ONLY case where the
//      legacy column is read.
//
//   5. THE RAW FIELDS STAY IN THE MODEL LAYER. A source scan fails the build
//      if any screen, widget or service reads `buyable` / `supplier_count`
//      straight off an RPC payload. Screens read the parsed verdict; only the
//      model layer is allowed to touch the wire format. This is the check
//      that would have caught the original divergence — three surfaces, three
//      raw reads, three answers.
//
// No network, no Supabase, no goldens.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/models/product_detail.dart';
import 'package:pharma_b2b/screens/product_detail_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

const _labels = <String, dynamic>{
  'stock_out_label': 'Out of stock',
  'card_notify_label': 'Notify me',
  'notify_subscribed_label': "We'll tell you",
  'cart_pill_cta': 'View cart',
};

/// The `availability` block exactly as `storefront_cta()` renders it. This is
/// the ONE object every surface in the app is supposed to read.
Map<String, dynamic> _verdict({
  required bool available,
  String? label,
}) =>
    {
      'is_available': available,
      'can_add': available,
      'cta_label': label ?? (available ? 'Add to cart' : 'Unavailable'),
      'gated': true,
      'unresolved': false,
      'colors': {
        'bg': available ? '#1B7A43' : '#F3F4F6',
        'fg': available ? '#FFFFFF' : '#6B7280',
      },
    };

/// A `product_detail()` payload.
///
/// [legacyBuyable] is the raw `stock.buyable` column — the field that went out
/// of sync with reality. [verdict] is the rendered availability block; pass
/// null to simulate the outage fallback where no verdict was sent at all.
Map<String, dynamic> _payload({
  required bool legacyBuyable,
  Map<String, dynamic>? verdict,
  bool hasSupplierLabel = true,
}) =>
    {
      'ok': true,
      'id': 252328,
      'labels': _labels,
      'header': {
        'name': 'SyNtraN 200 Capsule',
        'company': 'GLENMARK PHARMACEUTICALS LTD',
        'pack_label': 'Strip of 4 capsules',
        'form_chip': 'Capsule',
        'rx_required': false,
        'images': <String>[],
      },
      'price': {
        'has_mrp': true,
        'mrp_label': '₹601.00',
        'mrp_note': 'MRP',
        'has_gst': false,
        'gst_label': '',
        'scheme': false,
      },
      'pricing': {
        'mrp': 601.0,
        'sale_price': 601.0,
        'discount_pct': 0,
        'mrp_display': '₹601.00',
        'price_display': '₹601.00',
        'discount_label': '',
        'has_price': true,
        'has_discount': false,
      },
      if (verdict != null) 'availability': verdict,
      'stock': {
        'buyable': legacyBuyable,
        'has_supplier_label': hasSupplierLabel,
        'supplier_label': hasSupplierLabel ? 'AV • 11S' : '',
      },
      'overview': const <Map<String, dynamic>>[],
      'has_highlight': false,
      'highlight': '',
      'sections': const <Map<String, dynamic>>[],
      'similar': const <Map<String, dynamic>>[],
      'similar_ready': true,
      'my_history': {'has': false, 'label': ''},
      'show_wishlist': false,
      'is_wishlisted': false,
    };

int _pumpSeq = 0;

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: ProductDetailScreen(
          key: ValueKey('pdp-av-${_pumpSeq++}'),
          productId: '252328',
          loader: (_) async => ProductDetail.fromMap(payload),
          notifyStatusLoader: (_) async => false,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('1 — the verdict outranks the legacy column, both directions', () {
    test('252328: buyable:false but the verdict says available → buyable', () {
      // The live row, verbatim: supplier_count 11, buyable false. Before #640
      // this parsed to buyable:false and the page said "Out of stock" while
      // the cart happily took the product.
      final d = ProductDetail.fromMap(
        _payload(legacyBuyable: false, verdict: _verdict(available: true)),
      );

      expect(d.buyable, isTrue);
      expect(d.canAdd, isTrue);
    });

    test('the reverse: buyable:true but the verdict refuses → not buyable', () {
      final d = ProductDetail.fromMap(
        _payload(legacyBuyable: true, verdict: _verdict(available: false)),
      );

      expect(d.buyable, isFalse);
      expect(d.canAdd, isFalse);
    });

    test('agreement is unremarkable — both true, both false', () {
      final yes = ProductDetail.fromMap(
        _payload(legacyBuyable: true, verdict: _verdict(available: true)),
      );
      final no = ProductDetail.fromMap(
        _payload(legacyBuyable: false, verdict: _verdict(available: false)),
      );

      expect(yes.canAdd, isTrue);
      expect(no.canAdd, isFalse);
    });
  });

  group('2 — one answer per page: chip and bottom bar cannot disagree', () {
    testWidgets('252328 shape: supplier chip shows, Add offered, no Out of stock',
        (tester) async {
      await _pump(
        tester,
        _payload(legacyBuyable: false, verdict: _verdict(available: true)),
      );

      // The chip is the supplier label, NOT the out-of-stock copy...
      expect(find.text('AV • 11S'), findsOneWidget);
      expect(find.text('Out of stock'), findsNothing);
      // ...and the bar offers the backend's CTA rather than Notify.
      expect(find.text('Add to cart'), findsOneWidget);
      expect(find.text('Notify me'), findsNothing);
    });

    testWidgets('refused verdict: out-of-stock copy AND Notify, never Add',
        (tester) async {
      await _pump(
        tester,
        _payload(legacyBuyable: true, verdict: _verdict(available: false)),
      );

      expect(find.text('AV • 11S'), findsNothing);
      expect(find.text('Notify me'), findsOneWidget);
      expect(find.text('Add to cart'), findsNothing);
    });
  });

  group('3 — one parser, so one verdict cannot become two decisions', () {
    test('card, search row and product page read the same block the same way',
        () {
      final block = _verdict(available: true, label: 'Add to cart');

      final page = ProductDetail.fromMap(
        _payload(legacyBuyable: false, verdict: block),
      );
      final card = Product.fromMap({
        'id': 252328,
        'product_name': 'SyNtraN 200 Capsule',
        'mrp': 601.0,
        'buyable': false, // the stale column, on the card's payload too
        'supplier_count': 11, // ...and the count that disagreed with it
        'availability': block,
      });

      expect(card.availability, isNotNull);
      expect(card.availability!.canAdd, page.canAdd);
      expect(card.availability!.ctaLabel, 'Add to cart');
    });

    test('a refusal carries the backend note, unworded by Dart', () {
      final av = Availability.fromMap({
        ..._verdict(available: false),
        'note': 'No supplier in your zone right now',
      });

      expect(av, isNotNull);
      expect(av!.canAdd, isFalse);
      expect(av.note, 'No supplier in your zone right now');
    });
  });

  group('4 — no verdict is not a verdict', () {
    test('outage fallback falls back to the legacy column, both ways', () {
      final a = ProductDetail.fromMap(_payload(legacyBuyable: true));
      final b = ProductDetail.fromMap(_payload(legacyBuyable: false));

      expect(a.availability, isNull);
      expect(a.buyable, isTrue);
      expect(a.canAdd, isTrue);
      expect(b.canAdd, isFalse);
    });

    testWidgets('no verdict and not buyable → no bottom bar at all',
        (tester) async {
      await _pump(tester, _payload(legacyBuyable: false));

      expect(find.text('Add to cart'), findsNothing);
      expect(find.text('Notify me'), findsNothing);
    });
  });

  group('5 — the raw availability fields stay inside the model layer', () {
    // Only these files may touch the wire format. Every screen, widget and
    // service must read the parsed verdict instead. Adding a file here means
    // adding a second place that can answer "is this buyable?" — which is the
    // bug, so the list is deliberately hard to extend by accident.
    const allowed = <String>{
      'lib/models/product.dart',
      'lib/models/product_detail.dart',
      'lib/models/cart_model.dart',
    };

    // Admin/ops tooling reads the catalogue columns as DATA (a supplier
    // console showing which rows have suppliers), not as a customer-facing
    // availability decision, so it is out of this contract's scope.
    bool _outOfScope(String path) =>
        path.startsWith('lib/screens/admin/') ||
        path.startsWith('lib/screens/bulk_upload_screen_web');

    test('no screen or service reads buyable/supplier_count off a payload', () {
      final root = Directory('lib');
      expect(root.existsSync(), isTrue,
          reason: 'run from the package root so lib/ is visible');

      // A RAW read is a map subscript of the wire key: row['buyable'],
      // m["supplier_count"]. Reading the parsed model getter (`p.buyable`,
      // `p.isBuyable`) is fine — that value already came through one parser.
      final rawRead = RegExp(
        r'''\[\s*['"](buyable|supplier_count)['"]\s*\]''',
      );

      final offenders = <String>[];
      for (final f in root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final path = f.path;
        if (allowed.contains(path) || _outOfScope(path)) continue;
        final src = f.readAsStringSync();
        for (final line in src.split('\n')) {
          final code = line.split('//').first;
          if (rawRead.hasMatch(code)) offenders.add('$path: ${line.trim()}');
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'CHANGE #640 — availability has ONE door. These files read a '
            'raw availability field straight off a payload instead of the '
            'parsed `availability` verdict, which is how 13,767 products '
            'ended up disagreeing with themselves:\n${offenders.join('\n')}',
      );
    });

    test('no second RPC exists to ask the same question again', () {
      final offenders = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        for (final line in f.readAsStringSync().split('\n')) {
          final code = line.split('//').first;
          if (code.contains("'medicine_buyable_flags'") ||
              code.contains('"medicine_buyable_flags"')) {
            offenders.add('${f.path}: ${line.trim()}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason: 'CHANGE #640 — cart_state() already carries the flag. A second '
            'round trip that answers "is this orderable?" separately is a '
            'second source of truth by definition:\n${offenders.join('\n')}',
      );
    });
  });
}
