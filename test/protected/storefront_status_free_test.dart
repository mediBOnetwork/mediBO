// PROTECTED — CMD #1812.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how availability is resolved, never to make an
// unrelated change go green.
//
// THE BUG THIS EXISTS TO RETIRE
//
//   Abbott Gel Hand Sanitizer rendered a red "Discontinued" chip, the sentence
//   "This product has been discontinued and cannot be ordered" under it, and
//   "Not for sale" where the Add button belongs — on a pack a supplier in the
//   customer's own zone could send that afternoon. Nothing in mediBO had said
//   so. `MEDICINE.status` / `MEDICINE.status_reason` were scraped 1mg fields,
//   and ~6,200 of those rows were not even well formed: the reason was glued
//   onto the status word ("DISCONTINUEDWE DO NOT FACILITATE SALE OF THIS
//   PRODUCT AT PRESENT").
//
//   The backend half of the fix deletes both columns, the three helpers that
//   read them (med_status_block / med_status_sellable / _med_status_key), the
//   policy table and the copy keys, and removes `p_status` from
//   `storefront_cta()` altogether. This file is the Dart half: it fails if the
//   app ever grows a second availability answer out of a catalogue word again.
//
// THE ONE RULE, EVERYWHERE
//
//   standby = the master zone supplier list − (out of stock + nostock).
//   Available when standby > 0. `storefront_cta()` renders that and nothing
//   else, and the app prints what it rendered.
//
// What this holds down:
//
//   1. A CATALOGUE WORD DECIDES NOTHING. A payload that still carries
//      `status`, `status_reason` and a whole `status_block` — a stale cache, a
//      replayed fixture, a half-deployed edge — changes not one pixel. The
//      verdict is `availability`, alone.
//
//   2. STANDBY > 0 MEANS ADD, WHATEVER 1MG CALLED IT. The exact shape that was
//      broken — a product 1mg marked DISCONTINUED, with a zone that has stock —
//      offers the backend's Add CTA, and the red chip is nowhere on the page.
//
//   3. STANDBY = 0 IS THE ONLY REFUSAL, AND IT IS NOT RED. The page prints the
//      backend's "Out of stock" / "No supplier for this product right now" and
//      offers Notify — because zone stock can come back. "Not for sale" is a
//      sentence this app can no longer produce.
//
//   4. NOTHING PARSES A STATUS. `ProductDetail` and `Product` expose no status
//      field to render, so a screen cannot reintroduce the branch by accident.
//
// The suite runs on the Dart VM in ~2s. No network, no Supabase, no goldens.

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

/// `storefront_cta()`'s output. After #1812 it has exactly two shapes for a
/// resolved row, and both of them are the zone standby count speaking.
Map<String, dynamic> _cta({required bool standbyPositive}) => standbyPositive
    ? {
        'is_available': true,
        'can_add': true,
        'cta_label': 'Add to cart',
        'gated': true,
        'cta_short': 'ADD',
        'colors': {'bg': '#1B7A43', 'fg': '#FFFFFF'},
      }
    : {
        'is_available': false,
        'can_add': false,
        'cta_label': 'Unavailable',
        'gated': true,
        'blocked_by': 'no_supplier',
        'note': 'No supplier for this product right now',
        'cta_short': 'Out of stock',
        'colors': {'bg': '#F3F4F6', 'fg': '#9CA3AF'},
      };

/// The dead 1mg fields, in the shape production actually held them: the reason
/// glued onto the status word, plus the whole `status_block` the old
/// `med_status_block()` built. A payload like this can still arrive from a
/// cached page or a stale edge node. It must change nothing.
const _deadStatusKeys = <String, dynamic>{
  'status': 'DISCONTINUEDWE DO NOT FACILITATE SALE OF THIS PRODUCT AT PRESENT',
  'status_reason': 'This product has been discontinued and cannot be ordered',
  'status_block': {
    'key': 'DISCONTINUED',
    'label': 'Discontinued',
    'sellable': false,
    'tone': 'danger',
    'reason': 'This product has been discontinued and cannot be ordered',
  },
  'blocked_by_status': true,
};

/// A `product_detail()` payload for the pack that started this: Abbott's gel
/// hand sanitizer, which 1mg called DISCONTINUED.
///
/// [standbyPositive] is the ONLY thing that may change the page.
/// [withDeadStatusKeys] replays the scraped fields on top of it.
Map<String, dynamic> _payload({
  required bool standbyPositive,
  bool withDeadStatusKeys = false,
  bool hasSupplierLabel = true,
}) =>
    {
      'ok': true,
      'id': 305118,
      'labels': _labels,
      'header': {
        'name': 'Abbott Gel Hand Sanitizer',
        'company': 'ABBOTT INDIA LTD',
        'pack_label': 'Bottle of 500 ml',
        'form_chip': 'Gel',
        'rx_required': false,
        'images': <String>[],
      },
      'price': {
        'has_mrp': true,
        'mrp_label': '₹250.00',
        'mrp_note': 'MRP',
        'has_gst': false,
        'gst_label': '',
        'scheme': false,
      },
      'pricing': {
        'mrp': 250.0,
        'sale_price': 250.0,
        'discount_pct': 0,
        'mrp_display': '₹250.00',
        'price_display': '₹250.00',
        'discount_label': '',
        'has_price': true,
        'has_discount': false,
      },
      'availability': _cta(standbyPositive: standbyPositive),
      'stock': {
        'buyable': standbyPositive,
        'has_supplier_label': hasSupplierLabel && standbyPositive,
        'supplier_label': hasSupplierLabel && standbyPositive ? 'AV • 7S' : '',
        if (withDeadStatusKeys) ..._deadStatusKeys,
      },
      if (withDeadStatusKeys) ..._deadStatusKeys,
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
          key: ValueKey('pdp-1812-${_pumpSeq++}'),
          productId: '305118',
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

  group('1 — a catalogue word decides nothing', () {
    test('the dead 1mg fields do not move the verdict in either direction', () {
      final live = ProductDetail.fromMap(
        _payload(standbyPositive: true, withDeadStatusKeys: true),
      );
      final clean = ProductDetail.fromMap(_payload(standbyPositive: true));

      // Same verdict, same CTA, with and without the scraped fields present.
      expect(live.canAdd, isTrue);
      expect(live.canAdd, clean.canAdd);
      expect(live.availability?.ctaLabel, clean.availability?.ctaLabel);
      expect(live.availability?.ctaLabel, 'Add to cart');
    });

    test('and it cannot rescue a refusal either', () {
      // status_block says "sellable: false"; standby says 0. Both point the
      // same way here, but the assertion that matters is WHICH one is read:
      // the copy on screen is the backend's no-supplier note, never the
      // scraped reason.
      final d = ProductDetail.fromMap(
        _payload(standbyPositive: false, withDeadStatusKeys: true),
      );

      expect(d.canAdd, isFalse);
      expect(d.availability?.ctaLabel, 'Unavailable');
      expect(d.availability?.note, 'No supplier for this product right now');
    });
  });

  group('2 — standby > 0 means Add, whatever 1mg called it', () {
    testWidgets('the approved pharmacy is offered the backend CTA, not a chip',
        (tester) async {
      await _pump(
        tester,
        _payload(standbyPositive: true, withDeadStatusKeys: true),
      );

      expect(find.text('Add to cart'), findsOneWidget);
      // The red chip and its sentence are gone from the page entirely.
      expect(find.text('Discontinued'), findsNothing);
      expect(
        find.text('This product has been discontinued and cannot be ordered'),
        findsNothing,
      );
      expect(find.text('Not for sale'), findsNothing);
      expect(find.text('Out of stock'), findsNothing);
      // The supplier chip is the operator detail, and it still shows.
      expect(find.text('AV • 7S'), findsOneWidget);
    });
  });

  group('3 — standby = 0 is the only refusal, and it is not red', () {
    testWidgets('same product, empty zone: Out of stock + Notify, never a status',
        (tester) async {
      await _pump(
        tester,
        _payload(standbyPositive: false, withDeadStatusKeys: true),
      );

      expect(find.text('Out of stock'), findsOneWidget);
      // Notify is offered because ZONE stock comes back. This is precisely
      // what the old status branch suppressed.
      expect(find.text('Notify me'), findsOneWidget);
      expect(find.text('Add to cart'), findsNothing);
      expect(find.text('Not for sale'), findsNothing);
      expect(find.text('Discontinued'), findsNothing);
    });
  });

  group('4 — nothing parses a status', () {
    test('a card row carrying the scraped fields still reads only availability',
        () {
      final card = Product.fromMap({
        'id': 305118,
        'product_name': 'Abbott Gel Hand Sanitizer',
        'mrp': '₹250.00',
        'buyable': true,
        'supplier_count': 7,
        'availability': _cta(standbyPositive: true),
        ..._deadStatusKeys,
      });

      expect(card.availability?.canAdd, isTrue);
      expect(card.availability?.ctaLabel, 'Add to cart');
    });

    test('ProductDetail exposes no status surface a screen could render', () {
      final d = ProductDetail.fromMap(
        _payload(standbyPositive: false, withDeadStatusKeys: true),
      );

      // toString() is the cheapest total view of what the model carries. If a
      // future change reintroduces a status field, the scraped words start
      // appearing here and this fails.
      expect(d.toString().contains('DISCONTINUED'), isFalse);
      expect(d.toString().contains('Discontinued'), isFalse);
    });
  });
}
