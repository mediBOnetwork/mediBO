// CMD #409 — the fast-ordering trio's client contract.
//
// Every assertion here is the same assertion in three shapes: THE APP RENDERS,
// IT NEVER DECIDES. A scan refusal prints the backend's words; a mic sheet
// prints the backend's words and listens for the backend's number of seconds;
// the recently-viewed rail appears only because the backend said `has`.
//
// No network, no camera, no microphone, no Supabase — every seam is a
// constructor-injected closure, the shape the protected suite already uses.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/services/storefront_fast_order.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/recently_viewed_rail.dart';
import 'package:pharma_b2b/widgets/scan_mic_search_controls.dart';

/// One card, exactly the shape `_sf_cards()` sends.
Map<String, dynamic> _card({int id = 176026, String name = 'Telma 40 Tablet'}) => {
      'id': id,
      'name': name,
      'company': 'GLENMARK PHARMACEUTICALS LTD',
      'pack_label': 'Strip of 15 tablets',
      'form_chip': 'Strip',
      'pack_qty_label': '15.0 Tablets in 1 strip',
      'pack_type_label': 'Strip',
      'image': '',
      'mrp_label': '₹185.00',
      'buyable': true,
      'has_offer': false,
      'offer_chip': '',
      'availability': {'can_add': true, 'label': 'Add to cart', 'short': 'ADD'},
      // The pricing block exactly as storefront_pricing() sends it to an
      // ENTITLED viewer — the same block every rail card reads.
      'pricing': {
        'has_price': true,
        'mrp': 185,
        'sale_price': 152.90,
        'price_display': '₹152.90',
        'mrp_display': '₹185.00',
        'price_caption': 'PTR',
        'card_price': {
          'has_mrp': true,
          'mrp_label': 'MRP',
          'mrp_display': '₹185.00',
          'strike_mrp': true,
          'has_ptr': true,
          'ptr_label': 'PTR',
          'ptr_display': '₹152.90',
          'ptr_bg': '#1B7A43',
          'ptr_fg': '#FFFFFF',
          'has_note': false,
          'note': '',
        },
      },
    };

Widget _host(Widget child) => AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(body: child),
        routes: {'/product/176026': (_) => const Scaffold(body: Text('PDP'))},
      ),
    );

void main() {
  // The card and the sheets write render-log keys; the 800ms debounce is a
  // real Timer that would outlive the test and try to reach Supabase.
  setUpAll(() => RenderLog.flushEnabled = false);

  // Every cart write goes through the fake transport, so a rendered card can
  // never reach Supabase.
  setUp(() {
    CartModel.rpcTransport = (fn, params) async =>
        {'ok': true, 'message': '', 'cart': <String, dynamic>{}};
  });
  tearDown(() => CartModel.rpcTransport = null);

  group('barcode scan-to-cart', () {
    testWidgets('a resolved scan prints the backend title and the real card',
        (t) async {
      await t.pumpWidget(_host(ScanSheet(
        resolver: (code) async => ScanResult.fromMap({
          'ok': true,
          'product_id': 176026,
          'title': 'Found it',
          'message': 'Telma 40 Tablet',
          'card': _card(),
        }),
      )));
      await t.pump();

      final state = t.state<State<ScanSheet>>(find.byType(ScanSheet));
      await (state as dynamic).handleCode('8901234567890');
      await t.pump();

      // The words are the payload's, verbatim.
      expect(find.text('Found it'), findsOneWidget);
      expect(find.text('Telma 40 Tablet'), findsWidgets);
      // And the card is the SAME card every rail draws, so the price and the
      // ADD pill come from the same block — the sheet re-derives neither.
      expect(find.text('₹152.90'), findsWidgets);
    });

    testWidgets('an unknown barcode prints the backend refusal and NO card',
        (t) async {
      await t.pumpWidget(_host(ScanSheet(
        resolver: (code) async => ScanResult.fromMap({
          'ok': false,
          'error': 'unknown_barcode',
          'title': 'Not in the catalogue yet',
          'message': 'We could not match this barcode to a product.',
          'hint': 'Search the product by name instead.',
        }),
      )));
      await t.pump();
      final state = t.state<State<ScanSheet>>(find.byType(ScanSheet));
      await (state as dynamic).handleCode('9999999999999');
      await t.pump();

      expect(find.text('Not in the catalogue yet'), findsOneWidget);
      expect(find.text('We could not match this barcode to a product.'),
          findsOneWidget);
      expect(find.text('Search the product by name instead.'), findsOneWidget);
      // A refusal is never dressed up as a product.
      expect(find.byKey(const Key('c409_scan_title')), findsOneWidget);
      expect(find.text('₹152.90'), findsNothing);
    });

    testWidgets('a refusal the backend did not word prints NOTHING, never a '
        'Dart sentence', (t) async {
      await t.pumpWidget(_host(ScanSheet(
        // The network died before any copy arrived.
        resolver: (code) async => throw StateError('offline'),
      )));
      await t.pump();
      final state = t.state<State<ScanSheet>>(find.byType(ScanSheet));
      await (state as dynamic).handleCode('8901234567890');
      await t.pump();

      expect(find.byKey(const Key('c409_scan_title')), findsNothing);
      expect(find.byKey(const Key('c409_scan_message')), findsNothing);
    });
  });

  group('voice search', () {
    testWidgets('the sheet prints the backend copy and hands back the '
        'BACKEND-corrected query, never raw speech', (t) async {
      String? handed;
      await t.pumpWidget(_host(VoiceSearchSheet(
        onQuery: (q) => handed = q,
        configLoader: () async => VoiceSearchConfig.fromMap({
          'lang': 'hi-IN',
          'max_seconds': 6,
          'title': 'Speak the medicine name',
          'hint': 'Say the brand name — quantity and pack words are ignored.',
          'listening': 'Listening…',
          'stop_label': 'Stop',
          'cancel_label': 'Cancel',
        }),
        // What the STT heard, after voice_search_resolve applied the counting
        // vocabulary: the pack word and the spoken quantity are gone, the
        // strength survives. That decision is the BACKEND's — this closure
        // stands in for the RPC, not for the logic.
        transcriber: (transcript, lang) async {
          expect(lang, 'hi-IN'); // the backend chose the language
          return VoiceSearchResult.fromMap({
            'ok': true,
            'query': 'telma 40',
            'transcript': 'Telma 40 do strip',
          });
        },
      )));
      await t.pump();

      expect(find.text('Speak the medicine name'), findsOneWidget);
      expect(find.text('Listening…'), findsOneWidget);
      expect(find.text('Stop'), findsOneWidget);

      await t.tap(find.byKey(const Key('c409_voice_stop')));
      // pump, not pumpAndSettle: the sheet is hosted bare here, so the working
      // spinner it paints while the RPC is in flight never stops animating.
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(handed, 'telma 40');
    });

    testWidgets('silence never becomes a search', (t) async {
      String? handed;
      await t.pumpWidget(_host(VoiceSearchSheet(
        onQuery: (q) => handed = q,
        configLoader: () async => VoiceSearchConfig.fromMap({
          'title': 'Speak the medicine name',
          'listening': 'Listening…',
          'stop_label': 'Stop',
          'error_message': 'Voice search did not work. Type the name instead.',
        }),
        transcriber: (transcript, lang) async => VoiceSearchResult.fromMap({
          'ok': false,
          'error': 'blank',
          'query': '',
          'message': 'We could not hear a product name.',
        }),
      )));
      await t.pump();
      await t.tap(find.byKey(const Key('c409_voice_stop')));
      await t.pumpAndSettle();

      expect(handed, isNull);
      // and the failure is worded by the backend
      expect(find.text('Voice search did not work. Type the name instead.'),
          findsOneWidget);
    });

    testWidgets('a config with no words renders no words', (t) async {
      await t.pumpWidget(_host(VoiceSearchSheet(
        onQuery: (_) {},
        configLoader: () async => VoiceSearchConfig.none,
        transcriber: (_, __) async => const VoiceSearchResult(ok: false),
      )));
      await t.pump();
      expect(find.byKey(const Key('c409_voice_headline')), findsNothing);
      expect(find.byKey(const Key('c409_voice_stop')), findsNothing);
    });
  });

  group('recently viewed', () {
    testWidgets('renders the payload in payload order, with its own title',
        (t) async {
      await t.pumpWidget(_host(RecentlyViewedRail(
        loader: () async => RecentRail.fromMap({
          'ok': true,
          'has': true,
          'title': 'Recently viewed',
          'accent_word': 'Recently',
          'subtitle': 'PICK UP WHERE YOU LEFT OFF',
          // Deliberately NOT alphabetical: the rail must not sort.
          'items': [
            _card(id: 176026, name: 'Telma 40 Tablet'),
            _card(id: 176027, name: 'Amlokind 5 Tablet'),
          ],
        }),
      )));
      await t.pumpAndSettle();

      expect(find.text('Recently viewed'), findsOneWidget);
      expect(find.text('PICK UP WHERE YOU LEFT OFF'), findsOneWidget);

      final first = t.getTopLeft(find.text('Telma 40 Tablet')).dx;
      final second = t.getTopLeft(find.text('Amlokind 5 Tablet')).dx;
      expect(first, lessThan(second), reason: 'payload order, never sorted');
    });

    testWidgets('has:false draws nothing at all — the app never infers it from '
        'the item count', (t) async {
      await t.pumpWidget(_host(RecentlyViewedRail(
        loader: () async => RecentRail.fromMap({
          'ok': true,
          // The BACKEND says no, even though it sent a card. Availability is
          // its decision, applied after it picked the ids.
          'has': false,
          'title': 'Recently viewed',
          'items': [_card()],
        }),
      )));
      await t.pumpAndSettle();

      expect(find.text('Recently viewed'), findsNothing);
      expect(find.text('Telma 40 Tablet'), findsNothing);
    });

    testWidgets('an anonymous viewer gets an empty rail, not an error',
        (t) async {
      await t.pumpWidget(_host(RecentlyViewedRail(
        loader: () async => RecentRail.fromMap(
            {'ok': true, 'has': false, 'items': [], 'title': ''}),
      )));
      await t.pumpAndSettle();
      // It mounted and drew nothing — no throw, no spinner, no empty-state
      // sentence invented in Dart.
      expect(find.byType(RecentlyViewedRail), findsOneWidget);
      expect(find.byType(Text), findsNothing);
    });
  });
}
