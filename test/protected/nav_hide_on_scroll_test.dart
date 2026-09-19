// CMD #2080 — the storefront bottom nav hides on the way down and comes back
// on the way up, and it does it on the HEADER's driver, not a second one.
//
// The header band took four commands to get right (#2019 → #2030 → #2038 →
// #2052) and every one of them was the same lesson: a piece of chrome that
// reads the scroll OFFSET flashes back the moment the list re-measures, and a
// verdict computed twice drifts. So the contract this file holds down is not
// "the bar hides" — it is "the bar hides BY BEING THE HEADER'S OWN NUMBER":
//
//   · ONE ACCUMULATOR. `shellNavHide` is `shellHeaderCollapse` in another
//     unit. Same finger, same 1:1 travel, same 40 px hysteresis, same settle,
//     same top-of-page floor — because there is nothing here that could
//     disagree with them.
//   · EVERY CUSTOMER TAB, NOT JUST THE BAND'S TWO. Orders and Bulk keep their
//     header and still hide their bar, so the two enables are separate and
//     both are the shell's.
//   · STAFF CHROME IS UNTOUCHED. `nav:false` moves the bar by nothing, ever.
//   · A SHORT PAGE KEEPS ITS BAR, and so does the top of every page.
//   · OVERSCROLL — pull-to-refresh — MOVES IT BY NOTHING.
//   · THE SLOT SHRINKS, THE BAR IS NOT TRANSLATED OUT OF IT: the body grows by
//     the same pixels in the same frame, which is the whole of "the cart pill
//     moves down with the nav, no overlap, no gap" (#2066 mounts the bottom
//     stack at `bottom: 0` of that body). What is hit-testable is exactly what
//     is visible.
//   · THE BEHAVIOUR IS A BACKEND FLAG, read from `ui_copy`, never a literal.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/home_shell.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

final double _h = Ds.touch.headerBand;
final double _t = Ds.touch.headerHysteresis;

FixedScrollMetrics _metrics({
  double pixels = 500,
  double max = 4000,
  double min = 0,
}) =>
    FixedScrollMetrics(
      pixels: pixels,
      minScrollExtent: min,
      maxScrollExtent: max,
      viewportDimension: 800,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    );

/// One dragged scroll update. [delta] is the finger's travel in band sign:
/// positive hides the chrome.
void _drag(
  double delta, {
  double pixels = 500,
  double max = 4000,
  double min = 0,
  bool band = true,
  bool nav = true,
  required BuildContext context,
}) {
  shellHeaderScroll(
    ScrollUpdateNotification(
      metrics: _metrics(pixels: pixels, max: max, min: min),
      context: context,
      scrollDelta: delta,
      dragDetails: DragUpdateDetails(
        globalPosition: Offset.zero,
        delta: Offset(0, -delta),
        primaryDelta: -delta,
      ),
    ),
    band,
    nav: nav,
  );
}

void _overscroll(BuildContext context, {bool band = true, bool nav = true}) =>
    shellHeaderScroll(
      OverscrollNotification(
        metrics: _metrics(pixels: 0),
        context: context,
        overscroll: -40,
        dragDetails: DragUpdateDetails(
          globalPosition: Offset.zero,
          delta: const Offset(0, 40),
          primaryDelta: 40,
        ),
      ),
      band,
      nav: nav,
    );

/// A source file with its comments removed, so an assertion about what the
/// CODE does is not answered by a comment saying what it deliberately does
/// not do.
String _code(String path) => File(path)
    .readAsLinesSync()
    .where((String l) => !l.trimLeft().startsWith('//'))
    .join('\n');

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
  setUp(() {
    shellHeaderBandShow();
    UiCopy.debugSet({kNavHideOnScrollKey: 'true'});
  });

  group('CMD #2080 · the bar is the header band in another unit', () {
    testWidgets('a drag down hides it, 1:1 with the band', (tester) async {
      final context = await _ctx(tester);
      _drag(_t, context: context);
      expect(shellHeaderCollapse.value, _t,
          reason: 'the band stopped moving with the finger');
      expect(shellNavHide.value, closeTo(_t / _h, 1e-9),
          reason: 'the bar is not the same travel read as a fraction');
    });

    testWidgets('a drag up brings it straight back', (tester) async {
      final context = await _ctx(tester);
      _drag(_h, context: context);
      expect(shellNavHide.value, 1.0, reason: 'the bar never went away');
      // A reversal earns its turn over the hysteresis — once, for both.
      _drag(-_t, context: context);
      expect(shellNavHide.value, lessThan(1.0),
          reason: 'scrolling up did not bring the bar back');
      expect(shellNavHide.value, closeTo(shellHeaderCollapse.value / _h, 1e-9),
          reason: 'the two pieces of chrome have drifted apart');
    });

    testWidgets('it can never be more than fully gone', (tester) async {
      final context = await _ctx(tester);
      _drag(_h * 4, context: context);
      expect(shellNavHide.value, 1.0);
      _drag(-_h * 4, context: context);
      expect(shellNavHide.value, 0.0);
    });

    testWidgets('the top of a page always wears its bar', (tester) async {
      final context = await _ctx(tester);
      _drag(_h, context: context);
      expect(shellNavHide.value, 1.0);
      // The finger is at the top of the list and still pulling down.
      _drag(-4, pixels: 0, context: context);
      expect(shellNavHide.value, 0.0,
          reason: 'the bar stayed hidden at the top of the page');
    });

    testWidgets('a page too short to scroll keeps its bar', (tester) async {
      final context = await _ctx(tester);
      _drag(_h * 2, max: _h - 1, context: context);
      expect(shellNavHide.value, 0.0,
          reason: 'a page with nothing to scroll lost its bar anyway');
    });

    testWidgets('pull-to-refresh moves it by nothing', (tester) async {
      final context = await _ctx(tester);
      _drag(_h, context: context);
      expect(shellNavHide.value, 1.0);
      final double before = shellNavHide.value;
      _overscroll(context);
      expect(shellNavHide.value, before,
          reason: 'an overscroll — the whole of a pull-to-refresh — drove the '
              'bar');
    });

    testWidgets('no finger, no movement', (tester) async {
      final context = await _ctx(tester);
      shellHeaderScroll(
        ScrollUpdateNotification(
          metrics: _metrics(),
          context: context,
          scrollDelta: _h * 2,
        ),
        true,
        nav: true,
      );
      expect(shellNavHide.value, 0.0,
          reason: 'a re-measure, a fling or a jumpTo moved the bar');
    });
  });

  group('CMD #2080 · which chrome each tab has is the SHELL\'s answer', () {
    testWidgets('a tab with no band still hides its bar', (tester) async {
      final context = await _ctx(tester);
      _drag(_h, band: false, nav: true, context: context);
      expect(shellNavHide.value, 1.0,
          reason: 'Orders and Bulk are scrollable customer pages and must '
              'hide the bar even though they keep their header');
      expect(shellHeaderCollapse.value, 0.0,
          reason: 'a tab that keeps its header started collapsing it');
    });

    testWidgets('staff chrome is untouched', (tester) async {
      final context = await _ctx(tester);
      _drag(_h, band: false, nav: false, context: context);
      expect(shellNavHide.value, 0.0, reason: 'the staff bar moved');
      expect(shellHeaderCollapse.value, 0.0);
    });

    testWidgets('leaving the tab puts both back', (tester) async {
      final context = await _ctx(tester);
      _drag(_h, context: context);
      expect(shellNavHide.value, 1.0);
      shellHeaderBandShow();
      expect(shellNavHide.value, 0.0);
      expect(shellHeaderCollapse.value, 0.0);
    });
  });

  group('CMD #2080 · the flag is the backend\'s, and so is the timing', () {
    test('the behaviour is a ui_copy key, read as a flag', () {
      UiCopy.debugSet({kNavHideOnScrollKey: 'true'});
      expect(shellNavHideEnabled, isTrue);
      UiCopy.debugSet({kNavHideOnScrollKey: 'false'});
      expect(shellNavHideEnabled, isFalse,
          reason: 'turning the behaviour off has to be an UPDATE, not a '
              'deploy');
      UiCopy.debugSet(const {});
      expect(shellNavHideEnabled, isFalse,
          reason: 'the app invented an answer the backend had not given');
    });

    test('the shell asks the flag before it wraps the bar', () {
      final shell = File('lib/screens/home_shell.dart').readAsStringSync();
      expect(shell, contains('shellHidingNav('),
          reason: 'the bar is not wrapped, so it can never hide');
      expect(shell, contains('nav: !isAdmin && shellNavHideEnabled'),
          reason: 'the driver stopped being told whether this tab hides its '
              'bar');
      expect(shell, contains('enabled: !isAdmin && shellNavHideEnabled'),
          reason: 'the wrapper stopped reading the backend flag, or started '
              'wrapping the staff bar');
    });

    test('there is ONE driver and ONE accumulator behind both', () {
      final band =
          File('lib/screens/shell/shell_header_band.dart').readAsStringSync();
      final hide = _code('lib/screens/shell/shell_nav_hide.dart');
      expect('bool shellHeaderScroll('.allMatches(band).length, 1,
          reason: 'a second driver appeared — the two would drift');
      expect(hide, isNot(contains('ScrollNotification')),
          reason: 'the bar grew a scroll listener of its own instead of '
              'reading the one the header already feeds');
      expect(hide, isNot(contains('AnimationController')),
          reason: 'the bar grew a second curve to keep equal to the '
              "header's settle");
      expect('final ValueNotifier<double> shellNavHide'.allMatches(band).length,
          1,
          reason: 'the bar is published from somewhere other than the one '
              'accumulator');
    });

    test('the bar shortens its SLOT — it is not translated out of the body',
        () {
      final hide = _code('lib/screens/shell/shell_nav_hide.dart');
      // #2066 mounts the bottom stack at `bottom: 0` of the Scaffold body, so
      // the body's own height IS the pill's anchor. Shrinking the slot hands
      // those pixels to the body in the same frame; a Transform would leave
      // the pill behind and open a gap under it, and would put the pill
      // outside the rectangle that can be tapped.
      expect(hide, contains('nat * (1 - _gone)'),
          reason: 'the slot stopped shrinking, so the cart pill can no longer '
              'ride the top edge of the bar');
      expect(hide, isNot(contains('Transform')),
          reason: 'the bar is being translated instead of the slot being '
              'shortened — that is the gap #2080 exists to avoid');
    });

    testWidgets('an open keyboard keeps the bar out', (tester) async {
      final context = await _ctx(tester);
      _drag(_h, context: context);
      expect(shellNavHide.value, 1.0);

      late BuildContext inner;
      Widget app(double inset) => MediaQuery(
            data: MediaQueryData(viewInsets: EdgeInsets.only(bottom: inset)),
            child: Directionality(
              textDirection: TextDirection.ltr,
              // Bottom-aligned, because that is where a Scaffold puts its
              // nav slot and loose constraints are what let the slot report a
              // height of its own.
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Builder(builder: (c) {
                  inner = c;
                  return shellHidingNav(
                    enabled: true,
                    const SizedBox(width: 300, height: 56),
                  );
                }),
              ),
            ),
          );

      final Finder slot = find.byWidgetPredicate(
          (Widget w) => w.runtimeType.toString() == '_NavSlot');

      await tester.pumpWidget(app(300));
      expect(tester.getSize(slot).height, 56,
          reason: 'the bar hid itself while the keyboard was up');

      await tester.pumpWidget(app(0));
      await tester.pump();
      expect(tester.getSize(slot).height, 0,
          reason: 'with the keyboard gone the finger is back in charge');
      expect(inner, isNotNull);
    });
  });
}
