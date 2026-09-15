// PROTECTED — dev-queue #308.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately brings the Offers marketplace back, never to make an unrelated
// change go green.
//
// WHY THIS FILE EXISTS
//
// The supplier-self-list Offers marketplace (#177/#178/#179/#223) was removed
// entirely by #308: six listing tables, 31 RPCs, four scheduled jobs, the
// `offer_listing_id` column on cart_items and order_items, and — the reason Om
// pulled it — the offer branches that had grown into _place_order_v2_core,
// _cart_unavailable_lines and _oa_release_and_cancel. All of it is gone from
// the database, so a client that still speaks that language is talking to
// nothing.
//
// This test pins the FRONTEND half of that removal, which is the half a future
// change could quietly undo:
//
//   1. The `short_dated` layout is no longer a layout this build knows. It must
//      therefore take the SAME path as any other unknown layout — dropped
//      silently at parse time — rather than throwing or half-rendering. This is
//      the forward/backward-compatibility contract from home_sections_test:
//      an old backend that still sends the section must not break a new client.
//
//   2. HomeSection carries no short-dated state at all. If someone re-adds a
//      `shortDatedOffers` list or a `disclosureNote` to the model, this file
//      goes red and the reviewer has to say so out loud.
//
//   3. No screen calls a dropped RPC. Every offers RPC now raises
//      "function does not exist" in production, so a surviving call site is a
//      crash waiting for a user, not a dead branch.
//
// No network, no Supabase, no goldens — pure parse-level assertions plus a
// source scan of lib/.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/home_sections.dart';

/// Every RPC #308 dropped. A call to any of these from lib/ is a live crash.
const _droppedRpcs = <String>[
  'offers_feed',
  'offer_add_to_cart',
  'offer_waitlist_join',
  'offer_match_customers',
  'offer_push_matched',
  'supplier_offer_create',
  'supplier_offer_update',
  'supplier_offers_mine',
  'admin_offers_list',
  'admin_offer_moderate',
  'admin_offer_margin_set',
  'short_dated_feed',
  'short_dated_add_to_cart',
  'short_dated_config_get',
  'short_dated_config_save',
  'short_dated_offer_list',
  'short_dated_offer_edit',
  'short_dated_offer_confirm',
  'short_dated_offer_disable',
  'short_dated_push_wa',
];

void main() {
  group('the Offers marketplace stays removed', () {
    test('a short_dated section from an older backend is dropped silently', () {
      // Deliberately well-formed and non-empty: the ONLY reason to drop it is
      // that this build no longer knows the layout.
      final section = HomeSection.fromMap({
        'id': 'short_dated_deals',
        'layout': 'short_dated',
        'title': 'Short-dated deals',
        'accent_word': 'deals',
        'subtitle': 'Near expiry, deeper discount',
        'disclosure_note': 'You confirm you have reviewed the expiry date.',
        'items': [
          {
            'offer_id': 'a1',
            'product_id': 42,
            'product_name': 'AMOXYCILLIN 500MG',
            'discount_pct': 40,
            'discount_label': '40% off',
            'remaining_qty': 12,
          },
        ],
      });

      expect(section, isNull,
          reason: 'short_dated is now an unknown layout — it must take the '
              'same silent-drop path as any other unrecognised section, not '
              'throw and not render half a rail');
    });

    test('short_dated is not a HomeSectionLayout any more', () {
      expect(
        HomeSectionLayout.values.map((e) => e.name),
        isNot(contains('shortDated')),
        reason: 'the enum is the switch the renderer is exhaustive over; a '
            'value here means a branch somewhere still paints offers',
      );
    });

    test('a known layout still parses — the drop is targeted, not a blanket', () {
      final section = HomeSection.fromMap({
        'id': 'shop_by_category',
        'layout': 'icon_grid',
        'title': 'Shop by category',
        'accent_word': 'category',
        'subtitle': '',
        'items': [
          {'label': 'CARDIAC', 'count_label': '1,204 products', 'key': 'CARDIAC'},
        ],
      });

      expect(section, isNotNull,
          reason: 'removing short_dated must not have widened into dropping '
              'sections this build does still know');
      expect(section!.layout, HomeSectionLayout.iconGrid);
      expect(section.title, 'Shop by category');
    });

    test('HomeSection exposes no short-dated state', () {
      final section = HomeSection.fromMap({
        'id': 'best_sellers',
        'layout': 'rail',
        'title': 'Best Sellers',
        'accent_word': 'Sellers',
        'subtitle': '',
        'items': [
          {
            'id': 1,
            'name': 'CROCIN 650',
            'company': 'GSK',
            'pricing': {'price_display': '₹30.00'},
            'availability': {'can_add': true, 'cta_label': 'Add to cart'},
          },
        ],
      })!;

      // isEmpty used to also consult shortDatedOffers. A rail with cards is not
      // empty, and nothing else may contribute to that answer.
      expect(section.isEmpty, isFalse);
      expect(section.cards, hasLength(1));
      expect(section.tiles, isEmpty);
    });

    test('no file under lib/ calls a dropped offers RPC', () {
      final offenders = <String>[];

      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        for (final rpc in _droppedRpcs) {
          // Match the call shape the app actually uses: rpc('name'.
          if (source.contains("rpc('$rpc'") || source.contains('rpc("$rpc"')) {
            offenders.add('${entity.path} -> $rpc');
          }
        }
      }

      expect(offenders, isEmpty,
          reason: 'these RPCs were dropped from the database by #308; a call '
              'site left behind throws "function does not exist" at a real '
              'user instead of failing here');
    });
  });
}
