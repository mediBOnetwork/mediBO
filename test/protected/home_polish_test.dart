// CMD #2037 — the home polish pack, held down.
//
// Six separate complaints about the customer storefront, each of which had
// already been "fixed" once by a change that measured something else:
//
//   1. THE HEADER IS THE TOKEN'S HEIGHT. #2030 made the band's height and its
//      scroll travel ONE number so they could not drift apart, and set that
//      number to 56 — shortening the header as a side effect of making it
//      move. It is 64 again (the pre-#2030 geometry: a 40 px avatar in 12 px
//      of padding) and it is still the SAME token the band travels by.
//
//   2. ONE WHITE BLOCK. The search field was the page's grey inside a white
//      header with a grey rule under it: three tones in 100 px. The field is
//      the header's white with a hairline border, and the header's bottom rule
//      is gone.
//
//   3. NO CATEGORY CHIP ROW. "All / OTHERS / ANTI INFECTIVES / CARDIAC" is not
//      drawn on any surface. (The row's absence is asserted next to the rest
//      of the search surface, in search_one_surface_test.dart.)
//
//   4. THE SEE-ALL PILL IS ONE CENTRED GROUP. Thumbs on the left edge, a label
//      centred in what was left and a chevron pinned to the right edge is
//      three controls, not one; the group travels together now.
//
//   5. THE UPDATE CARD SITS ON THE NAV. Its float height is the bottom nav's
//      own height (0 gap), its shadow is cast UPWARDS out of its only visible
//      edge, the gear is an outline, the button is a rounded rectangle — and
//      it PUBLISHES its measured height so the floating cart pill can clear
//      it instead of being told a constant that goes stale.
//
//   6. THE HOME TAB IS A BACK BUTTON. One rung per tap: another tab hands the
//      storefront back as it was left, a list opened from home steps back out
//      to the feed, and only the feed at its root scrolls to the top.
//
// No network, no Supabase, no goldens, no camera. Everything below is either a
// pure decision or a widget mounted with fixture copy.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/home_sections.dart';
import 'package:pharma_b2b/models/shell_nav.dart';
import 'package:pharma_b2b/models/storefront_p3.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/home_sections_view.dart';
import 'package:pharma_b2b/widgets/search_surface.dart';
import 'package:pharma_b2b/widgets/update_bar.dart';

import 'ui_copy_fixture.dart';

/// The phone this build is designed on (CMD #1950).
const Size _phone360 = Size(360, 780);
const Size _phone412 = Size(412, 900);

Map<String, dynamic> _railCard(int id, String name) => {
      'id': id,
      'name': name,
      'company': 'GLENMARK PHARMACEUTICALS LTD',
      'pack_label': '1 Strip',
      'form_chip': 'Strip',
      'image': '',
      'mrp_label': '₹236.20',
      'buyable': true,
      'availability': {
        'is_available': true,
        'can_add': true,
      },
      'pricing': {
        'mrp': 236.2,
        'sale_price': 236.2,
        'discount_pct': 0,
        'mrp_display': '₹236.20',
        'price_display': '₹236.20',
        'discount_label': '',
        'has_price': true,
        'has_discount': false,
      },
    };

/// One rail with a category see-all, which is the shape that draws the pill.
Map<String, dynamic> _feed({List<String> thumbs = const []}) => {
      'ok': true,
      'sections': [
        {
          'id': 'cat_cardiac',
          'layout': 'rail',
          'title': 'Cardiac',
          'accent_word': 'Cardiac',
          'subtitle': 'TOP PICKS IN CARDIAC',
          'see_all': {'type': 'category', 'key': 'CARDIAC'},
          'see_all_label': 'ZZ-SEE-ALL-FROM-BACKEND',
          'see_all_thumbs': thumbs,
          'items': [_railCard(252328, 'SyNtraN 200 Capsule')],
        },
      ],
    };

int _seq = 0;

Future<void> _pumpFeed(WidgetTester t, Map<String, dynamic> payload,
    {Size size = _phone360}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  HomeSectionsView.resetMemo();
  addTearDown(HomeSectionsView.resetMemo);
  await t.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: HomeSectionsView(
            key: ValueKey('polish-${_seq++}'),
            loader: () async => HomeSections.fromMap(payload),
            onCategoryTap: (_) {},
            onBrowseAll: () {},
            onOpenCompanies: () {},
            notificationsLoader: () async => BackInStock.empty,
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

/// CMD #2066 — the bar has no offset of its own any more, so this mounts it
/// exactly the way the bottom stack does: anchored at the bottom of the body,
/// and optionally given the fixed slot height the stack hands it.
Future<void> _pumpUpdateBar(
  WidgetTester t, {
  double? fixedHeight,
  Size size = _phone360,
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: UpdateBar(
                title: 'ZZ-UPDATE-AVAILABLE',
                actionLabel: 'ZZ-UPDATE-NOW',
                updatingLabel: 'ZZ-UPDATING',
                updating: false,
                fixedHeight: fixedHeight,
                onUpdate: () {},
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

/// The source of a file in the repo — the only honest way to assert "this
/// literal is not written here any more" for a canvas app.
String _src(String path) => File(path).readAsStringSync();

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    seedUiCopy();
  });

  // ── 1. the header band ────────────────────────────────────────────────────
  group('1 — the header is back to its pre-#2030 height', () {
    test('headerBand is 64, and it is one token', () {
      expect(Ds.touch.headerBand, 64,
          reason: 'the pre-#2030 geometry: a 40 px avatar in 12 px of padding');
    });

    test('the band still TRAVELS by the same token it is tall', () {
      // #2030's whole point: "how tall" and "how far" cannot be set apart by an
      // edit. Both read Ds.touch.headerBand and nothing else does the arithmetic.
      final src = _src('lib/screens/shell/shell_mobile_chrome.dart');
      expect(src.contains('height: Ds.touch.headerBand'), isTrue);
      expect(src.contains('final double h = Ds.touch.headerBand;'), isTrue);
      expect(RegExp(r'headerBand\s*[-+*/]\s*\d').hasMatch(src), isFalse,
          reason: 'no file may adjust the band token on its way past');
    });

    test('a backend token still wins over the default', () {
      // ui_design_set({'touch': {'headerBand': N}}) retunes the header with no
      // deploy — that is the contract, and 64 is only the fallback.
      final src = _src('lib/design_tokens.dart');
      expect(src.contains("headerBand: Ds._num(m['headerBand'], f.headerBand)"),
          isTrue);
    });
  });

  // ── 2. one white block ────────────────────────────────────────────────────
  group('2 — the header and the search field are one white block', () {
    testWidgets('the field is the surface white with a hairline, not the page grey',
        (t) async {
      t.view.physicalSize = _phone360;
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SearchHeaderBar(
            controller: ctrl,
            placeholder: 'ZZ-PLACEHOLDER',
            onChanged: (_) {},
            onSubmit: (_) {},
          ),
        ),
      ));
      await t.pump();

      // The FIELD: the box that is exactly one fieldHeight tall.
      final field = t.widgetList<Container>(find.byType(Container)).firstWhere(
          (c) => c.constraints?.maxHeight == SearchHeaderBar.fieldHeight);
      final d = field.decoration! as BoxDecoration;
      expect(d.color, Ds.c.surface,
          reason: 'the header\'s white — the page grey made it a second block');
      expect(d.color, isNot(Ds.c.bg));
      expect((d.border! as Border).top.color, Ds.c.divider,
          reason: 'one thin light-grey hairline is all that says "type here"');
    });

    test('the header draws no bottom rule under itself', () {
      final src = _src('lib/screens/shell/shell_mobile_chrome.dart');
      expect(src.contains('Border(bottom: BorderSide(color: Brand.border))'),
          isFalse,
          reason: 'a hairline between two white strips is what broke the block');
    });
  });

  // ── 4. the See-all pill ───────────────────────────────────────────────────
  group('4 — the See-all pill is ONE centred group', () {
    testWidgets('thumbs, label and chevron sit together, centred', (t) async {
      await _pumpFeed(
          t,
          _feed(thumbs: const [
            'https://img.test/a.png',
            'https://img.test/b.png',
          ]));

      final pill = find.byKey(const Key('c2027_see_all_pill'));
      expect(pill, findsOneWidget);

      final label = find.text('ZZ-SEE-ALL-FROM-BACKEND');
      final chevron = find.descendant(
          of: pill, matching: find.byIcon(Icons.chevron_right));
      final thumb0 = find.byKey(const ValueKey('c2027_pill_thumb_0'));
      expect(label, findsOneWidget);
      expect(chevron, findsOneWidget);
      expect(thumb0, findsOneWidget);

      final pillBox = t.getRect(pill);
      final groupLeft = t.getRect(thumb0).left;
      final groupRight = t.getRect(chevron).right;

      // The group is CENTRED in the pill: the air on its left and the air on
      // its right are the same, to within a pixel. The old layout pinned the
      // discs to the left padding and the chevron to the right one, so those
      // two numbers were both exactly the padding whatever the label said —
      // and the label was centred against the pill rather than its own group.
      final leftAir = groupLeft - pillBox.left;
      final rightAir = pillBox.right - groupRight;
      expect((leftAir - rightAir).abs(), lessThan(1.5),
          reason: 'one group, centred — not three things pinned to two edges');
      expect(leftAir, greaterThan(Ds.space.x16),
          reason: 'a centred group leaves MORE than the padding on each side');

      // And nothing inside the group is holding a gap open: label to chevron
      // is tight, not "whatever width is left".
      final labelRight = t.getRect(label).right;
      expect(t.getRect(chevron).left - labelRight, lessThan(Ds.space.x8 + 1));
    });

    testWidgets('with no thumbs the label and chevron stay centred together',
        (t) async {
      await _pumpFeed(t, _feed());
      final pill = find.byKey(const Key('c2027_see_all_pill'));
      final label = find.text('ZZ-SEE-ALL-FROM-BACKEND');
      final chevron = find.descendant(
          of: pill, matching: find.byIcon(Icons.chevron_right));
      expect(find.byKey(const ValueKey('c2027_pill_thumb_0')), findsNothing);

      final pillBox = t.getRect(pill);
      final leftAir = t.getRect(label).left - pillBox.left;
      final rightAir = pillBox.right - t.getRect(chevron).right;
      expect((leftAir - rightAir).abs(), lessThan(1.5));
    });

    testWidgets('a long label ellipsises inside the pill, it never overflows',
        (t) async {
      final p = _feed();
      (p['sections'] as List).first['see_all_label'] =
          'ZZ-A-VERY-LONG-BACKEND-LABEL-THAT-CANNOT-POSSIBLY-FIT-ON-A-PHONE';
      await _pumpFeed(t, p, size: _phone360);
      expect(tester_hasOverflow(), isFalse);
      final pill = find.byKey(const Key('c2027_see_all_pill'));
      expect(t.getRect(pill).width, lessThanOrEqualTo(360));
    });
  });

  // ── 5. the update card ────────────────────────────────────────────────────
  group('5 — the update card sits on the bottom nav', () {
    testWidgets('no payload gap = exactly one bottom-nav height, 0 extra',
        (t) async {
      await _pumpUpdateBar(t);
      final card = t.getRect(find.text('ZZ-UPDATE-AVAILABLE'));
      expect(card.bottom, lessThan(_phone360.height));
      // The bottom of the CARD is one nav height off the bottom of the screen.
      final decorated = find.ancestor(
          of: find.text('ZZ-UPDATE-AVAILABLE'),
          matching: find.byType(DecoratedBox));
      final box = t.getRect(decorated.first);
      // CMD #2066 — no offset of any kind: the bar's bottom edge is the
      // bottom of whatever it is anchored to, which in the stack is the top
      // of the bottom nav. It rests ON the nav; it never floats above it.
      expect(_phone360.height - box.bottom, closeTo(0, 1),
          reason: 'the bar rests ON the nav, it does not float above it');
    });

    // CMD #2066 — this used to read "the backend's bottom_gap is what is used
    // when it sends one". A number the backend can change is a position that
    // can move, and every position in this chrome is now static: the bar fills
    // the slot the stack reserved for it, exactly, and `bottom_gap` is ignored
    // (test/protected/bottom_stack_test.dart proves the payload key no longer
    // lifts anything).
    testWidgets('a slot height is EXACT — the bar fills it and never grows',
        (t) async {
      final slot = Ds.touch.listRowMinHeight;
      await _pumpUpdateBar(t, fixedHeight: slot);
      final decorated = find.ancestor(
          of: find.text('ZZ-UPDATE-AVAILABLE'),
          matching: find.byType(DecoratedBox));
      expect(t.getRect(decorated.first).height, closeTo(slot, 0.5),
          reason: 'a second line at 360 px must not make the chrome taller');
    });

    // CMD #2051 — EDGE TO EDGE, and only the top corners are rounded. #2037's
    // card kept a margin each side because it was still a floating card; the
    // bar is now the top surface of the bottom chrome (nav, bar, cart pill in
    // one column), and a floating card with air down both sides does not read
    // as the same object as the nav it is sitting on. The margin moved INSIDE:
    // the sentence and the gear still start one step in.
    testWidgets('full width, and the content keeps its margin', (t) async {
      await _pumpUpdateBar(t);
      final decorated = find.ancestor(
          of: find.text('ZZ-UPDATE-AVAILABLE'),
          matching: find.byType(DecoratedBox));
      final box = t.getRect(decorated.first);
      expect(box.left, closeTo(0, 0.5));
      expect(box.width, closeTo(_phone360.width, 0.5));
      expect(t.getRect(find.byIcon(Icons.settings_outlined)).left - box.left,
          greaterThanOrEqualTo(Ds.space.x16));
    });

    testWidgets('only the TOP corners are rounded — it meets the nav flat',
        (t) async {
      await _pumpUpdateBar(t);
      final decorated = find.ancestor(
          of: find.text('ZZ-UPDATE-AVAILABLE'),
          matching: find.byType(DecoratedBox));
      final d = t.widget<DecoratedBox>(decorated.first).decoration
          as BoxDecoration;
      final r = d.borderRadius! as BorderRadius;
      expect(r.topLeft.x, Ds.r.card);
      expect(r.topRight.x, Ds.r.card);
      expect(r.bottomLeft, Radius.zero);
      expect(r.bottomRight, Radius.zero);
    });

    testWidgets('the gear is an OUTLINE glyph in its own circle', (t) async {
      await _pumpUpdateBar(t);
      expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
      expect(find.byIcon(Icons.settings_rounded), findsNothing);
    });

    testWidgets('the button is a rounded RECTANGLE, not a stadium', (t) async {
      await _pumpUpdateBar(t);
      final btn = t.widget<FilledButton>(find.byType(FilledButton));
      final shape = btn.style!.shape!.resolve(<WidgetState>{});
      expect(shape, isA<RoundedRectangleBorder>());
      expect(shape, isNot(isA<StadiumBorder>()));
    });

    test('the shadow is cast UPWARDS out of the card\'s only visible edge', () {
      expect(Ds.elevation.eUp.single.offset.dy, lessThan(0));
      expect(_src('lib/widgets/update_bar.dart')
          .contains('boxShadow: Ds.elevation.eUp'), isTrue);
    });

    // CMD #2066 — this used to read "the card publishes its MEASURED height".
    // Publishing a height is what made every list on screen re-pad whenever
    // the bar arrived, a cart emptied or the sentence took a second line. The
    // bar publishes nothing now: it is one data row tall, always.
    testWidgets('the bar is one data row tall, and nothing is published',
        (t) async {
      await _pumpUpdateBar(t);
      await t.pump();
      final decorated = find.ancestor(
          of: find.text('ZZ-UPDATE-AVAILABLE'),
          matching: find.byType(DecoratedBox));
      expect(t.getRect(decorated.first).height,
          greaterThanOrEqualTo(Ds.touch.listRowMinHeight));
      // No notifier survives for anything to listen to. (The file still
      // NAMES both of them, in the comment that says why they are gone — so
      // this looks for the declarations, not for the words.)
      final src = _src('lib/widgets/update_bar.dart');
      expect(src.contains('ValueNotifier<double> appUpdateBarHeight'), isFalse);
      expect(src.contains('ValueNotifier<int> bottomStackMounted'), isFalse);
      expect(src.contains('class UpdateBarHost'), isFalse,
          reason: 'one renderer: the reserved slot of the bottom stack');
    });

    test('the cart pill and the home feed both clear the ONE constant', () {
      // CMD #2051 — the pill does not clear the bar by being lifted an agreed
      // number of pixels; it clears it by being ABOVE it in one column.
      // CMD #2066 — and the feed pads by that column's CONSTANT height rather
      // than by a number the column measures and republishes, which is what
      // made the content above it jump every time the chrome changed shape.
      expect(
          _src('lib/screens/shell/shell_bottom_bars.dart')
              .contains('StorefrontBottomStack('),
          isTrue);
      expect(
          _src('lib/widgets/home_sections_view.dart')
              .contains('padding: EdgeInsets.only(bottom: _updateBarClearance)'),
          isTrue);
      expect(
          _src('lib/widgets/home_sections_view.dart')
              .contains('=> bottomStackHeight'),
          isTrue);
      // …and it does not listen to it, because there is nothing to hear.
      expect(
          _src('lib/widgets/home_sections_view.dart')
              .contains('bottomStackHeight.addListener'),
          isFalse);
    });

    testWidgets('at 412 px it still fits and the sentence is never clipped away',
        (t) async {
      await _pumpUpdateBar(t, size: _phone412);
      expect(find.text('ZZ-UPDATE-AVAILABLE'), findsOneWidget);
      expect(find.text('ZZ-UPDATE-NOW'), findsOneWidget);
      expect(tester_hasOverflow(), isFalse);
      // The one control a shopper taps is a real target at every width.
      expect(t.getSize(find.byType(FilledButton)).height,
          greaterThanOrEqualTo(Ds.touch.minTarget));
    });
  });

  // ── 6. the Home tab is a back button ──────────────────────────────────────
  group('6 — the Home tab is a back button, and only then a scroll-to-top', () {
    ShellNavState state({
      int page = ShellPage.storefront,
      String category = 'All',
      String query = '',
      bool browseAll = false,
      bool cartOpen = false,
    }) =>
        ShellNavState(
          page: page,
          category: category,
          query: query,
          browseAll: browseAll,
          cartOpen: cartOpen,
        );

    test('from another tab: the storefront comes back as it was left', () {
      for (final page in [1, 2, 11, ShellPage.catalogue]) {
        expect(ShellNav.homeTap(state(page: page)),
            ShellHomeTap.resumeStorefront,
            reason: 'page $page');
      }
    });

    test('from a list opened from home: back out to the feed', () {
      expect(ShellNav.homeTap(state(category: 'CARDIAC')),
          ShellHomeTap.backToFeed);
      expect(ShellNav.homeTap(state(query: 'monticope')),
          ShellHomeTap.backToFeed);
      expect(ShellNav.homeTap(state(browseAll: true)),
          ShellHomeTap.backToFeed);
      expect(ShellNav.homeTap(state(cartOpen: true)),
          ShellHomeTap.backToFeed);
    });

    test('at the home root: scroll to the top', () {
      expect(ShellNav.homeTap(state()), ShellHomeTap.scrollTop);
    });

    test('the ladder is one rung per tap, never two', () {
      // Orders → feed-as-left → (say it was a category) → feed → top.
      var s = state(page: 1, category: 'CARDIAC');
      expect(ShellNav.homeTap(s), ShellHomeTap.resumeStorefront);
      s = state(category: 'CARDIAC');
      expect(ShellNav.homeTap(s), ShellHomeTap.backToFeed);
      s = state();
      expect(ShellNav.homeTap(s), ShellHomeTap.scrollTop);
    });

    test('the LOGO and the system back button are untouched', () {
      // Both still mean the home ROOT — #2021's rule, unchanged.
      expect(ShellNav.tapOn(ShellPage.storefront), ShellTabTap.homeRoot);
      expect(ShellNav.back(state(category: 'CARDIAC')), ShellBack.goHome);
      expect(ShellNav.back(state()), ShellBack.exit);
    });

    test('only the scroll-to-top rung bumps the shell\'s scroll trigger', () {
      final src = _src('lib/screens/shell/shell_nav_roots.dart');
      expect(src.contains('if (toTop) _scrollToTopTrigger++;'), isTrue);
      expect(src.contains('_goHome(toTop: false)'), isTrue,
          reason: 'stepping back out of a list keeps the offset');
    });

    test('the feed remembers where it was left across an unmount', () {
      final src = _src('lib/widgets/home_sections_view.dart');
      expect(src.contains('ScrollController(initialScrollOffset: _homeFeedOffset)'),
          isTrue);
      expect(src.contains('_homeFeedOffset = _scroll.hasClients'), isTrue);
      expect(src.contains('_homeFeedOffset = 0;'), isTrue,
          reason: 'a scroll-to-top must forget the old offset');
    });
  });
}

/// True when this frame reported a RenderFlex overflow. `takeException()` is
/// how the framework surfaces one to a test.
bool tester_hasOverflow() {
  final e = TestWidgetsFlutterBinding.instance.takeException();
  return e != null;
}
