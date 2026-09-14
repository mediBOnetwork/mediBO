// CMD #2019 — the storefront header band, and the chrome that must NOT move.
//
// The bug class this holds down is a header that strobes. The band is driven
// by raw scroll deltas, so every guard that keeps a fling from flickering it
// — the floor at the top of the page, the short-page case, the travel
// threshold, the reset on a direction change, and horizontal rails being
// ignored entirely — is a line of arithmetic that a later edit can quietly
// drop. Each one is asserted here.
//
// The other half is the promise the spec actually makes: the search bar and
// the category chip row are PINNED. They are pinned by sitting outside the
// scroll view, so what this file protects is that the shell never moves them
// into one — the band is the only thing the scroll listener may touch.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/home_shell.dart';
import 'package:pharma_b2b/utils/render_log.dart';

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
        axisDirection: axis == Axis.vertical
            ? AxisDirection.down
            : AxisDirection.right,
        devicePixelRatio: 1,
      ),
      context: context,
      scrollDelta: delta,
    );

/// Scrolls far enough in one direction to cross the travel threshold.
void _travel(
  double delta, {
  int times = 4,
  Axis axis = Axis.vertical,
  double max = 4000,
  required BuildContext context,
}) {
  for (var i = 0; i < times; i++) {
    shellHeaderScroll(
        _update(delta: delta, axis: axis, max: max, context: context), true);
  }
}

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

  group('the band answers to scrolling, and only to scrolling', () {
    testWidgets('sustained downward travel hides it, upward brings it back',
        (tester) async {
      final context = await _ctx(tester);
      _travel(6, context: context);
      expect(shellHeaderVisible.value, isFalse,
          reason: 'scrolling down did not hand the band back to the products');
      _travel(-6, context: context);
      expect(shellHeaderVisible.value, isTrue,
          reason: 'scrolling up did not return the header');
    });

    testWidgets('one small delta is not enough — a fling must not strobe it',
        (tester) async {
      final context = await _ctx(tester);
      shellHeaderScroll(_update(delta: 4, context: context), true);
      expect(shellHeaderVisible.value, isTrue);
    });

    testWidgets('a direction change resets the travel, it does not accumulate',
        (tester) async {
      final context = await _ctx(tester);
      // 8 down then 8 up is 16 px of movement and zero net travel: neither
      // direction may reach the threshold on its own.
      shellHeaderScroll(_update(delta: 8, context: context), true);
      shellHeaderScroll(_update(delta: -8, context: context), true);
      expect(shellHeaderVisible.value, isTrue);
    });

    testWidgets('the top of the page always wears full chrome',
        (tester) async {
      final context = await _ctx(tester);
      _travel(6, context: context);
      expect(shellHeaderVisible.value, isFalse);
      shellHeaderScroll(
          _update(delta: 20, pixels: 0, context: context), true);
      expect(shellHeaderVisible.value, isTrue,
          reason: 'the band stayed hidden at offset 0');
    });

    testWidgets('a page too short to scroll can never lose its header',
        (tester) async {
      final context = await _ctx(tester);
      _travel(20, max: 40, context: context);
      expect(shellHeaderVisible.value, isTrue);
    });

    testWidgets('horizontal rails are ignored entirely', (tester) async {
      final context = await _ctx(tester);
      // The home feed is full of carousels and the chip row scrolls sideways.
      _travel(40, axis: Axis.horizontal, context: context);
      expect(shellHeaderVisible.value, isTrue,
          reason: 'a sideways rail moved the header band');
    });

    testWidgets(
        'disabled means shown — admin and every other tab keep their header',
        (tester) async {
      final context = await _ctx(tester);
      _travel(6, context: context);
      expect(shellHeaderVisible.value, isFalse);
      shellHeaderScroll(_update(delta: 40, context: context), false);
      expect(shellHeaderVisible.value, isTrue);
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

  group('the band wrapper', () {
    testWidgets('collapses to nothing and comes back at full height',
        (tester) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: const Key('wrap'),
            width: 100,
            child: shellCollapsibleBand(
              true,
              const SizedBox(height: 70, key: Key('band')),
            ),
          ),
        ),
      ));
      expect(tester.getSize(find.byKey(const Key('wrap'))).height, 70);

      shellHeaderVisible.value = false;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('wrap'))).height, 0,
          reason: 'the band did not collapse');

      shellHeaderVisible.value = true;
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('wrap'))).height, 70,
          reason: 'the band did not come back');
    });

    testWidgets('disabled returns the child untouched — no animator at all',
        (tester) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: shellCollapsibleBand(
          false,
          const SizedBox(height: 70, key: Key('band')),
        ),
      ));
      expect(find.byType(SizeTransition), findsNothing);
    });
  });

  group('the pinned chrome stays outside the scroll view', () {
    // The search bar and the category chip row are one widget
    // (`_shellSearchHeader`). It is pinned because it is a sibling of the page,
    // not a sliver inside it — the moment it moves into the scroll view it
    // scrolls away with the products and the spec is broken.
    final shell = File('lib/screens/home_shell.dart').readAsStringSync();

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

    test('the pinned chrome sits below the system bar even when collapsed', () {
      // The band carries its own SafeArea; collapsing it would take the status
      // bar inset with it and slide the search bar under the clock. The shell
      // holds the inset itself, above everything that can move.
      expect(shell, contains('SafeArea(bottom: false, child: Column('),
          reason: 'the mobile chrome lost the safe-area inset that survives '
              'the header collapsing');
    });
  });
}
