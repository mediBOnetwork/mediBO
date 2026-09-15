// CMD #2030 — the storefront header band FOLLOWS THE FINGER, 1:1.
//
// CMD #2019 put the band on a verdict: 12 px of travel flipped a bool and a
// 180 ms curve played the remaining 44. A 20 px drag therefore bumped the whole
// header away and a flick popped it back — it moved further than the finger and
// at its own speed. This file holds down the arithmetic that replaced it, and
// every guard that keeps a 1:1 header honest:
//
//   · one pixel of scroll is one pixel of band, both directions, no threshold;
//   · no snap and no auto-complete — a half-hidden band STAYS half hidden;
//   · never more hidden than the list has travelled from the top, so the top of
//     the page always wears the whole header;
//   · the band's own height is the travel, and it is the same token the header
//     is drawn with;
//   · the last band-height of the list is frozen in the hiding direction (the
//     collapse hands its height to the viewport, and at the end of the list that
//     correction comes back as a delta — the two used to chase each other);
//   · a short page, a horizontal rail and a disabled tab never move it;
//   · the band RISES (its bottom slice is what stays) rather than shortening;
//   · and the header subtree is LAID OUT, never rebuilt, as it moves.
//
// The other half is the promise the spec makes about the chrome that must NOT
// move: the search bar and the category chip row are pinned by sitting outside
// the scroll view, so what is protected is that the shell never moves them in.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/home_shell.dart';
import 'package:pharma_b2b/utils/render_log.dart';

final double _h = Ds.touch.headerBand;

ScrollUpdateNotification _update({
  required double delta,
  double pixels = 500,
  double max = 4000,
  Axis axis = Axis.vertical,
  required BuildContext context,
}) =>
    ScrollUpdateNotification(
      metrics: FixedScrollMetrics(
        pixels: pixels,
        minScrollExtent: 0,
        maxScrollExtent: max,
        viewportDimension: 800,
        axisDirection:
            axis == Axis.vertical ? AxisDirection.down : AxisDirection.right,
        devicePixelRatio: 1,
      ),
      context: context,
      scrollDelta: delta,
    );

void _scroll(
  double delta, {
  double pixels = 500,
  double max = 4000,
  Axis axis = Axis.vertical,
  bool enabled = true,
  required BuildContext context,
}) =>
    shellHeaderScroll(
        _update(
            delta: delta,
            pixels: pixels,
            max: max,
            axis: axis,
            context: context),
        enabled);

/// A real [BuildContext] — [ScrollUpdateNotification] insists on one, though
/// nothing under test reads it.
Future<BuildContext> _ctx(WidgetTester tester) async {
  late BuildContext ctx;
  await tester.pumpWidget(Builder(builder: (c) {
    ctx = c;
    return const SizedBox.shrink();
  }));
  return ctx;
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  setUp(shellHeaderBandShow);

  group('one pixel of scroll is one pixel of band', () {
    testWidgets('down 20 hides exactly 20, up 20 hands exactly 20 back',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(20, context: context);
      expect(shellHeaderCollapse.value, 20,
          reason: 'the band did not move with the finger, 1:1');
      _scroll(-20, context: context);
      expect(shellHeaderCollapse.value, 0,
          reason: 'scrolling back up did not hand the same 20 px back');
    });

    testWidgets('there is no threshold — 4 px of scroll is 4 px of band',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(4, context: context);
      expect(shellHeaderCollapse.value, 4,
          reason: 'a small delta was swallowed by a threshold');
    });

    testWidgets('a half-hidden band STAYS half hidden — no snap, no complete',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h / 2, context: context);
      expect(shellHeaderCollapse.value, _h / 2);
      // Everything that is not a delta: an end notification, a zero delta, a
      // notification of another kind. None of them may finish the movement.
      _scroll(0, context: context);
      shellHeaderScroll(
          ScrollEndNotification(
              metrics: _update(delta: 0, context: context).metrics,
              context: context),
          true);
      expect(shellHeaderCollapse.value, _h / 2,
          reason: 'something completed the collapse the finger left half done');
    });

    testWidgets('it never hides more of the band than the band is tall',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h * 4, context: context);
      expect(shellHeaderCollapse.value, _h);
      _scroll(_h * 4, context: context);
      expect(shellHeaderCollapse.value, _h,
          reason: 'the band collapsed past its own height');
    });

    testWidgets('a direction change is not a reset — it is 1:1 the other way',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(30, context: context);
      _scroll(-10, context: context);
      expect(shellHeaderCollapse.value, 20,
          reason: 'reversing threw the position away instead of moving it back');
    });
  });

  group('the guards that keep a 1:1 header honest', () {
    testWidgets('never more hidden than the list has travelled from the top',
        (tester) async {
      final context = await _ctx(tester);
      // 40 px of delta reported at offset 10 can only mean 10 px of band: the
      // first band-height of the page scrolls the header off exactly as if it
      // were the first row of content.
      _scroll(40, pixels: 10, context: context);
      expect(shellHeaderCollapse.value, 10);
    });

    testWidgets('the top of the page always wears the whole header',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h * 2, context: context);
      expect(shellHeaderCollapse.value, _h);
      _scroll(20, pixels: 0, context: context);
      expect(shellHeaderCollapse.value, 0,
          reason: 'the band stayed hidden at offset 0');
    });

    testWidgets('a page too short to scroll can never lose its header',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h * 4, max: _h - 1, context: context);
      expect(shellHeaderCollapse.value, 0);
    });

    testWidgets('the end of the list is frozen in the hiding direction only',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(20, context: context);
      // Collapsing hands the band's height to the viewport; over the last
      // band-height of the list that shortens maxScrollExtent and the
      // correction returns as a delta. Freezing there is what stops the strobe.
      _scroll(30, pixels: 4000 - (_h / 2), context: context);
      expect(shellHeaderCollapse.value, 20,
          reason: 'the band moved at the end of the list, where its own '
              'collapse feeds the next delta');
      // Coming back up from there still works — the freeze is one-directional.
      _scroll(-10, pixels: 4000 - (_h / 2), context: context);
      expect(shellHeaderCollapse.value, 10);
    });

    testWidgets('horizontal rails are ignored entirely', (tester) async {
      final context = await _ctx(tester);
      _scroll(40, axis: Axis.horizontal, context: context);
      expect(shellHeaderCollapse.value, 0,
          reason: 'a sideways rail moved the header band');
    });

    testWidgets('disabled means shown — admin and every other tab keep it',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h * 2, context: context);
      expect(shellHeaderCollapse.value, _h);
      _scroll(40, enabled: false, context: context);
      expect(shellHeaderCollapse.value, 0);
    });

    testWidgets('the listener never swallows the notification it read',
        (tester) async {
      final context = await _ctx(tester);
      expect(shellHeaderScroll(_update(delta: 40, context: context), true),
          isFalse);
      expect(shellHeaderScroll(_update(delta: 40, context: context), false),
          isFalse);
    });
  });

  group('the band wrapper draws the position it is given', () {
    /// The band under test, with a build counter on the child so a rebuild
    /// during a flick is visible.
    Widget _band(ValueNotifier<int> builds) => Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              key: const Key('wrap'),
              width: 360,
              child: shellCollapsibleBand(
                true,
                Builder(builder: (_) {
                  builds.value++;
                  return SizedBox(
                      height: Ds.touch.headerBand, key: const Key('band'));
                }),
              ),
            ),
          ),
        );

    testWidgets('its height is the band less exactly what has been scrolled',
        (tester) async {
      final builds = ValueNotifier<int>(0);
      await tester.pumpWidget(_band(builds));
      expect(tester.getSize(find.byKey(const Key('wrap'))).height, _h);

      shellHeaderCollapse.value = 20;
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('wrap'))).height, _h - 20,
          reason: 'the band did not give up exactly the 20 px scrolled');

      shellHeaderCollapse.value = _h;
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('wrap'))).height, 0,
          reason: 'the band did not collapse');

      shellHeaderCollapse.value = 0;
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('wrap'))).height, _h,
          reason: 'the band did not come back');
    });

    testWidgets('the band RISES — its bottom slice is what stays on screen',
        (tester) async {
      final builds = ValueNotifier<int>(0);
      await tester.pumpWidget(_band(builds));
      final top = tester.getTopLeft(find.byKey(const Key('band'))).dy;

      shellHeaderCollapse.value = 20;
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(const Key('band'))).dy, top - 20,
          reason: 'the header shortened in place instead of rising 20 px');
    });

    testWidgets('a flick lays the header out, it never rebuilds it',
        (tester) async {
      final builds = ValueNotifier<int>(0);
      await tester.pumpWidget(_band(builds));
      final after = builds.value;
      for (var px = 1.0; px <= _h; px++) {
        shellHeaderCollapse.value = px;
        await tester.pump();
      }
      expect(builds.value, after,
          reason: 'the header subtree rebuilt on scroll — a whole band of '
              'widgets per frame is what drops the frames');
    });

    testWidgets('disabled returns the child untouched — no wrapper at all',
        (tester) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: shellCollapsibleBand(
          false,
          const SizedBox(height: 56, key: Key('band')),
        ),
      ));
      expect(find.byType(ClipRect), findsNothing);
    });
  });

  group('the pinned chrome stays outside the scroll view', () {
    // The search bar and the category chip row are one widget
    // (`_shellSearchHeader`). It is pinned because it is a sibling of the page,
    // not a sliver inside it — the moment it moves into the scroll view it
    // scrolls away with the products and the spec is broken.
    final shell = File('lib/screens/home_shell.dart').readAsStringSync();
    final chrome =
        File('lib/screens/shell/shell_mobile_chrome.dart').readAsStringSync();

    test('the search header is mounted as a Column child, never as a sliver',
        () {
      expect(shell, contains('if (_index == 0) _shellSearchHeader(this)'),
          reason: 'the shell stopped mounting the one search header');
      expect(shell, isNot(contains('SliverPersistentHeader')),
          reason: 'the search chrome was moved into a scroll view — it can no '
              'longer stay pinned while the idle rail changes its height');
    });

    test('only the header band is wrapped in the collapse', () {
      expect(shell, contains('shellCollapsibleBand(!isAdmin, _LocationHeader('),
          reason: 'the band wrapper left the header');
      expect('shellCollapsibleBand('.allMatches(shell).length, 1,
          reason: 'something other than the header band is being collapsed');
    });

    test('the scroll path never calls setState on the shell', () {
      expect(shell, contains('onNotification: (n) => shellHeaderScroll(n,'),
          reason: 'the shell stopped feeding the band from the page scroll, or '
              'wrapped it in something that can rebuild the IndexedStack');
    });

    test('the pinned chrome sits below the system bar even when collapsed', () {
      // The band carries its own SafeArea; collapsing it would take the status
      // bar inset with it and slide the search bar under the clock. The shell
      // holds the inset itself, above everything that can move.
      expect(shell, contains('SafeArea(bottom: false, child: Column('),
          reason: 'the mobile chrome lost the safe-area inset that survives '
              'the header collapsing');
    });

    test('the header is drawn with the very token it travels by', () {
      // Two numbers — "how tall is the header" and "how far does it move" —
      // would drift apart on the first edit. There is one.
      expect(chrome, contains('height: Ds.touch.headerBand'),
          reason: 'the header band stopped being drawn at its token height');
      expect(chrome, isNot(contains('minHeight: 70')),
          reason: 'the old 70 px header came back');
    });

    test('the header and the search bar share one side margin', () {
      expect(chrome,
          contains('padding: EdgeInsets.symmetric(horizontal: Ds.space.x16)'),
          reason: 'the header row left the search bar\'s 16 px side margin, so '
              'the avatar and the cart no longer line up with the field');
      expect(
          File('lib/widgets/search_surface.dart').readAsStringSync(),
          contains('Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x8'),
          reason: 'the search bar changed its own side margin — the header is '
              'aligned to Ds.space.x16 and the two must agree');
    });
  });
}
