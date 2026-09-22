// PROTECTED — CMD #2166, the no-photo placeholder is the backend's.
//
// The card computes no artwork. `placeholder` carries the KIND (from
// card_placeholder_kind()), the DRAWING (icon_url → app_settings
// 'card.placeholder_icons') and the TINT (fg → card.style.placeholder_fg), and
// the card renders exactly those three. What this file holds down:
//   * CardV5 reads icon_url and fg verbatim; an older payload without them is
//     '' and null, never a guess.
//   * A url draws that SVG — the built-in Material glyph is a FAILURE state
//     (empty url, or a dead url), never the normal one.
//   * The tint is always the payload's fg, on the SVG and on the fallback
//     glyph alike. No Ds.c.brand green reaches either.
//   * An unknown kind still draws (carton), so a kind added in SQL renders
//     without a deploy.
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/product.dart';
import 'package:pharma_b2b/models/product_card_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/card_pack_icon.dart';
import 'package:pharma_b2b/widgets/compact_product_card.dart';

const String _url =
    'https://swojhmarmaijkshsbeih.supabase.co/storage/v1/object/public/app-assets/placeholders/strip.svg';

Map<String, dynamic> _card(Map<String, dynamic> placeholder) => {
  'style': {'photo_bg': '#FFFFFF', 'sub_fg': '#111827', 'mrp_fg': '#111827'},
  'placeholder': placeholder,
  'price': <String, dynamic>{},
  'layout': {'text_lines': 3, 'name_max_lines': 2},
};

const String _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
    'stroke="#111827" stroke-width="1.5"><rect x="3" y="7" width="18" '
    'height="10" rx="3"/></svg>';

Future<void> _pumpIcon(WidgetTester tester, CardPackIcon icon) =>
    tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: icon))));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  setUp(() {
    // Serves the drawing the backend's url points at. A test that wants the
    // dead-url path installs its own 404 client.
    CardPackIcon.httpClient = MockClient(
      (_) async => http.Response(_svg, 200, headers: const {
        'content-type': 'image/svg+xml',
      }),
    );
  });
  tearDown(() {
    CardPackIcon.httpClient = null;
    CardPackIcon.resetCache();
  });

  test('CardV5 reads icon_url and fg verbatim', () {
    final v = CardV5.of(_card({
      'kind': 'strip',
      'fg': '#9CA3AF',
      'icon_url': _url,
    }))!;
    expect(v.placeholderKind, 'strip');
    expect(v.placeholderIconUrl, _url);
    expect(v.placeholderFg, '#9CA3AF');
  });

  test('a payload without the new keys is absence, not a default', () {
    final v = CardV5.of(_card({'kind': 'bottle'}))!;
    expect(v.placeholderIconUrl, '');
    expect(v.placeholderFg, isNull);
  });

  testWidgets('a url draws the backend SVG, tinted with fg', (tester) async {
    const tint = Color(0xFF9CA3AF);
    await _pumpIcon(
      tester,
      const CardPackIcon(kind: 'strip', size: 64, iconUrl: _url, color: tint),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.colorFilter, const ColorFilter.mode(tint, BlendMode.srcIn));
    expect(
      find.byIcon(CardPackIcon.glyphFor('strip')),
      findsNothing,
      reason: 'the built-in glyph is a failure state, not the normal one',
    );
  });

  testWidgets('a dead url falls back to the glyph — still in fg',
      (tester) async {
    const tint = Color(0xFF9CA3AF);
    CardPackIcon.resetCache();
    CardPackIcon.httpClient =
        MockClient((_) async => http.Response('gone', 404));
    await _pumpIcon(
      tester,
      const CardPackIcon(kind: 'strip', size: 64, iconUrl: _url, color: tint),
    );
    await tester.pumpAndSettle();
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, CardPackIcon.glyphFor('strip'));
    expect(icon.color, tint, reason: 'the fallback wears the payload tint too');
  });

  testWidgets('no url falls back to the built-in glyph — still in fg',
      (tester) async {
    const tint = Color(0xFF9CA3AF);
    await _pumpIcon(
      tester,
      const CardPackIcon(kind: 'strip', size: 64, color: tint),
    );
    expect(find.byType(SvgPicture), findsNothing);
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, CardPackIcon.glyphFor('strip'));
    expect(icon.color, tint);
    expect(icon.color, isNot(Ds.c.brand), reason: 'never the brand green');
  });

  testWidgets('an unknown kind still draws the carton', (tester) async {
    await _pumpIcon(
      tester,
      const CardPackIcon(
        kind: 'a_kind_this_build_has_never_heard_of',
        size: 64,
        color: Color(0xFF9CA3AF),
      ),
    );
    expect(
      tester.widget<Icon>(find.byType(Icon)).icon,
      CardPackIcon.glyphFor('carton'),
    );
  });

  testWidgets('the icon keeps the size it was given', (tester) async {
    await _pumpIcon(
      tester,
      const CardPackIcon(kind: 'bottle', size: 64, color: Color(0xFF9CA3AF)),
    );
    expect(tester.widget<Icon>(find.byType(Icon)).size, 64);
  });

  testWidgets('the card hands the plate the payload url and fg, nothing else',
      (tester) async {
    CartModel.rpcTransport = (fn, params) async => {
      'ok': true,
      'message': '',
      'cart': <String, dynamic>{},
    };
    addTearDown(() => CartModel.rpcTransport = null);

    final card = _card({
      'kind': 'strip',
      'fg': '#9CA3AF',
      'icon_url': _url,
    })
      ..addAll({
        'v': 1,
        'id': 274472,
        'name': 'Gally M 40mg/500mg Tablet',
        'image': {'url': '', 'placeholder': true},
        'pack_chip': {'has': false, 'label': ''},
        'sub_line': {'has': false, 'label': '', 'fg': '#111827'},
        'wish': {'has': false, 'saved': false},
        'rx': {'has': false, 'is_rx': false, 'label': ''},
        'offer': {'has': false, 'label': ''},
        'foot': {'has': false, 'label': ''},
        'qty_in_cart': 0,
      });

    await tester.pumpWidget(
      AppState(
        cart: CartModel.forTest(),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 170,
                height: CompactProductCard.extent,
                child: CompactProductCard(
                  product: Product.fromMap({
                    'id': 274472,
                    'product_name': card['name'],
                    'image_url_1': '',
                    'availability': {
                      'is_available': true,
                      'can_add': true,
                      'cta_label': 'Add to cart',
                      'cta_short': 'ADD',
                    },
                    'card': card,
                  }),
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final icon = tester.widget<CardPackIcon>(find.byType(CardPackIcon));
    expect(icon.iconUrl, _url, reason: 'the payload url, verbatim');
    expect(icon.color, const Color(0xFF9CA3AF), reason: 'placeholder.fg');
    expect(icon.color, isNot(Ds.c.brand));
    expect(icon.kind, 'strip');
  });
}
