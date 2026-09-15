// CMD #2052 — the storefront header band moves on the FINGER, and nothing else.
//
// #2019 put the band on a verdict; #2030 made it a distance that follows the
// list 1:1; #2038 filtered the deltas no finger produced. All three read the
// SCROLL OFFSET, and the offset is the thing that lies: a page of products
// arriving re-measures the list, a grid re-lays out, the keyboard opens, a
// `jumpTo` fires, a collapsing band hands its own height to the viewport. Each
// reports pixels running backwards, and every backward pixel read as "the
// finger came up" — the header flashing back mid-scroll with no reversal of
// Om's own. That is not a filter problem: once you are looking at an offset, a
// re-measure and a drag are the same event.
//
// So this file holds down a different contract, and it is the whole of it:
//
//   · ONLY A FINGER MOVES IT. The driver reads `dragDetails.delta` — the
//     pointer's own travel — and a ScrollUpdate without a drag moves the band
//     by exactly zero, whatever its scrollDelta says. Inserted content, a
//     re-measure, a keyboard, a programmatic jump and a fling are all that.
//   · IT FOLLOWS THE POINTER, NOT THE LIST. When the two disagree — and they
//     disagree exactly when the list re-measures — the pointer wins.
//   · MOMENTUM FOLLOWS THE DRAG THAT STARTED IT. A downward fling can only end
//     with the header away; it can never reveal it on the way.
//   · A DIRECTION EARNS ITSELF over `Ds.touch.headerHysteresis` (40 px) of
//     deliberate travel, first direction and reversal alike, and when it is
//     earned it is paid in FULL rather than docked the threshold.
//   · OVERSCROLL AND BOUNCE DRIVE IT BY NOTHING, both the notification and any
//     drag reported while the list is outside its own ends.
//   · IT IS NEVER LEFT HALF OPEN. The gesture ends, the band finishes itself
//     off at the end the drag was heading for, on an animation value.
//   · NOTHING REBUILDS. Not the header, not the wrapper — dragging or settling.
//   · ONE BAND FOR HOME AND CATALOGUE (#2052(8)), and one driver, and one
//     notifier — never a second controller to keep in step.
//
// The other half is the promise the spec makes about the chrome that must NOT
// move: the search bar, the breadcrumb and the A–Z rail are pinned by sitting
// outside the scroll view, so what is protected is that the shell never moves
// them in.

import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/home_shell.dart';
import 'package:pharma_b2b/utils/render_log.dart';

final double _h = Ds.touch.headerBand;
final double _t = Ds.touch.headerHysteresis;

FixedScrollMetrics _metrics({
  double pixels = 500,
  double max = 4000,
  double min = 0,
  Axis axis = Axis.vertical,
}) =>
    FixedScrollMetrics(
      pixels: pixels,
      minScrollExtent: min,
      maxScrollExtent: max,
      viewportDimension: 800,
      axisDirection:
          axis == Axis.vertical ? AxisDirection.down : AxisDirection.right,
      devicePixelRatio: 1,
    );

/// A scroll update. [drag] true is a finger on the glass (`dragDetails`
/// present, which is exactly how Flutter marks a drag update); false is
/// everything else the list reports on its own — a fling coasting, the physics
/// settling, a re-measure after a page is inserted, a programmatic jump.
///
/// [pointer] is the FINGER's travel in band-sign (positive hides), and it is
/// deliberately a separate number from [delta], the list's own. They agree in
/// every ordinary frame and disagree exactly when the list moves by itself,
/// which is what several of these tests are about.
ScrollUpdateNotification _update({
  required double delta,
  double? pointer,
  double pixels = 500,
  double max = 4000,
  double min = 0,
  Axis axis = Axis.vertical,
  bool drag = true,
  required BuildContext context,
}) {
  final double p = pointer ?? delta;
  return ScrollUpdateNotification(
    metrics: _metrics(pixels: pixels, max: max, min: min, axis: axis),
    context: context,
    scrollDelta: delta,
    dragDetails: drag
        ? DragUpdateDetails(
            globalPosition: Offset.zero,
            delta: Offset(0, -p),
            primaryDelta: -p,
          )
        : null,
  );
}

void _scroll(
  double delta, {
  double? pointer,
  double pixels = 500,
  double max = 4000,
  double min = 0,
  Axis axis = Axis.vertical,
  bool enabled = true,
  bool drag = true,
  required BuildContext context,
}) =>
    shellHeaderScroll(
        _update(
            delta: delta,
            pointer: pointer,
            pixels: pixels,
            max: max,
            min: min,
            axis: axis,
            drag: drag,
            context: context),
        enabled);

/// The finger leaving the glass. Flutter reports it as `idle` BEFORE the
/// ballistic phase starts, which is why the band can settle without waiting for
/// the fling to run out.
void _lift(BuildContext context) => shellHeaderScroll(
    UserScrollNotification(
        metrics: _metrics(), context: context, direction: ScrollDirection.idle),
    true);

/// The list coming to rest.
void _end(BuildContext context) => shellHeaderScroll(
    ScrollEndNotification(metrics: _metrics(), context: context), true);

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

  group('CMD #2052 · only a finger moves the band', () {
    testWidgets('a drag moves it 1:1 once the direction is earned',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_t, context: context);
      expect(shellHeaderCollapse.value, _t,
          reason: 'the band did not move with the finger, 1:1');
      _scroll(10, context: context);
      expect(shellHeaderCollapse.value, _t + 10,
          reason: 'going on the way it was already going needs no threshold');
    });

    testWidgets('an update with NO drag moves it by nothing at all',
        (tester) async {
      final context = await _ctx(tester);
      // Nothing has been dragged yet. A page of products lands and the list
      // re-measures; a grid re-lays out; the keyboard opens; something calls
      // jumpTo. Every one of them reports a delta with no finger behind it.
      _scroll(_h * 4, drag: false, context: context);
      _scroll(-_h * 4, drag: false, pixels: 0, context: context);
      expect(shellHeaderCollapse.value, 0,
          reason: 'the list moved the header without a finger');

      // And once a drag HAS sent the header away, the same deltas cannot bring
      // it back — this is the flash-back #2052 is filed for.
      _scroll(_t + 10, context: context);
      _end(context);
      expect(shellHeaderCollapse.value, _h);
      _scroll(-200, drag: false, context: context);
      _scroll(-40, drag: false, pixels: 60, context: context);
      _scroll(-4000, drag: false, pixels: 0, context: context);
      expect(shellHeaderCollapse.value, _h,
          reason: 'the header flashed back on a delta no finger produced — '
              'this IS the bug');
    });

    testWidgets('it follows the POINTER when the list disagrees',
        (tester) async {
      final context = await _ctx(tester);
      // The finger is still going down the page by 20 px, but the list reports
      // itself running 300 px backwards because it just re-measured. The band
      // must obey the finger.
      _scroll(-300, pointer: _t, context: context);
      expect(shellHeaderCollapse.value, _t,
          reason: 'the band read the list\'s own delta instead of the finger');
    });

    testWidgets('a short page can never lose its header', (tester) async {
      final context = await _ctx(tester);
      _scroll(_h * 4, max: _h - 1, context: context);
      expect(shellHeaderCollapse.value, 0);
    });

    testWidgets('horizontal rails are ignored entirely', (tester) async {
      final context = await _ctx(tester);
      _scroll(_h * 4, axis: Axis.horizontal, context: context);
      expect(shellHeaderCollapse.value, 0,
          reason: 'a sideways rail moved the header band');
    });

    testWidgets('disabled means shown — every tab the band does not own',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h * 2, context: context);
      expect(shellHeaderCollapse.value, _h);
      _scroll(_h, enabled: false, context: context);
      expect(shellHeaderCollapse.value, 0);
    });

    testWidgets('the listener never swallows the notification it read',
        (tester) async {
      final context = await _ctx(tester);
      expect(shellHeaderScroll(_update(delta: _h, context: context), true),
          isFalse);
      expect(shellHeaderScroll(_update(delta: _h, context: context), false),
          isFalse);
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
  });

  group('CMD #2052 · a direction has to earn itself', () {
    testWidgets('jitter under the threshold changes nothing, from cold',
        (tester) async {
      final context = await _ctx(tester);
      for (var i = 0; i < 6; i++) {
        _scroll(3, context: context);
        _scroll(-3, context: context);
      }
      expect(shellHeaderCollapse.value, 0,
          reason: 'a shaking finger walked the header off a page nobody '
              'had scrolled');
    });

    testWidgets('a wobble mid-scroll does not turn it around', (tester) async {
      final context = await _ctx(tester);
      _scroll(_t + 20, context: context);
      final double at = shellHeaderCollapse.value;
      _scroll(-6, context: context);
      expect(shellHeaderCollapse.value, at,
          reason: 'finger tremor turned the header around — this is the '
              'pop-in/pop-out the band keeps being filed for');
      // …and carrying on down is obeyed at once: the guard is on TURNING, not
      // on moving. The 6 px held are netted off, so the band is exactly where
      // the finger is.
      _scroll(10, context: context);
      expect(shellHeaderCollapse.value, at + 4,
          reason: 'the held wobble was either lost or paid twice');
    });

    testWidgets('a reversal is DELAYED by the threshold, never shortened',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h, context: context);
      final double at = shellHeaderCollapse.value;
      _scroll(-(_t - 1), context: context);
      expect(shellHeaderCollapse.value, at,
          reason: 'a reversal one pixel short of the token was believed');
      _scroll(-1, context: context);
      expect(shellHeaderCollapse.value, at - _t,
          reason: 'the threshold SHORTENED the reversal instead of delaying '
              'it — the first 40 px of every scroll-up would be eaten');
    });

    testWidgets('the threshold is the backend token, and it is 40',
        (tester) async {
      expect(_t, 40,
          reason: 'the spec asks for a deliberate 40 px drag');
      expect(Ds.touch.headerSettleMs, greaterThan(0),
          reason: 'the settle has no duration to animate over');
    });
  });

  group('CMD #2052 · overscroll and bounce drive it by nothing', () {
    testWidgets('a drag reported outside the list moves nothing',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h, context: context);
      // A bouncing list reports pixels BEYOND its own end and then reports them
      // back. Neither half is scrolling, and a finger stretching a bounce is
      // not scrolling either.
      _scroll(-_h, pixels: -30, context: context);
      _scroll(_h, pixels: 4030, max: 4000, context: context);
      expect(shellHeaderCollapse.value, _h,
          reason: 'the bounce at the end of the list moved the header');
    });

    testWidgets('an OverscrollNotification never drives the band',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_t, context: context);
      shellHeaderScroll(
          OverscrollNotification(
              metrics: _metrics(pixels: 4000), context: context, overscroll: 60),
          true);
      expect(shellHeaderCollapse.value, _t,
          reason: 'the glow at the end of the list moved the header');
    });

    testWidgets('a finger at the very top always wears the whole header',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h, context: context);
      expect(shellHeaderCollapse.value, _h);
      // There is no list left to drag back, so the band cannot be earned back
      // a pixel at a time. It is simply worn.
      _scroll(-1, pixels: 0, context: context);
      expect(shellHeaderCollapse.value, 0,
          reason: 'the band stayed hidden with the list at its own top');
    });
  });

  group('CMD #2052 · momentum follows the drag that started it', () {
    testWidgets('a downward fling never reveals the header', (tester) async {
      final context = await _ctx(tester);
      _scroll(_t, context: context);
      // The finger lifts and the list coasts — including the snap-back at the
      // end of the fling, which used to be the reveal.
      _lift(context);
      _scroll(-300, drag: false, context: context);
      _scroll(-80, drag: false, context: context);
      _end(context);
      expect(shellHeaderCollapse.value, _h,
          reason: 'a fling revealed the header the drag had sent away');
    });

    testWidgets('an upward drag gets the header back on the lift',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h, context: context);
      expect(shellHeaderCollapse.value, _h);
      _scroll(-_t, context: context);
      _lift(context);
      expect(shellHeaderCollapse.value, 0,
          reason: 'an upward drag did not hand the whole header back');
    });
  });

  group('CMD #2052 · it is never left half open', () {
    testWidgets('a half-hidden band finishes the way the drag was going',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_t, context: context); // less than the band is tall
      expect(shellHeaderCollapse.value, lessThan(_h));
      _lift(context);
      expect(shellHeaderCollapse.value, _h,
          reason: 'the band was left standing half open');
    });

    testWidgets('an end notification finishes it too', (tester) async {
      final context = await _ctx(tester);
      _scroll(_t, context: context);
      _end(context);
      expect(shellHeaderCollapse.value, _h);
    });

    testWidgets('a gesture that earned no direction settles nowhere',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(4, context: context);
      _lift(context);
      expect(shellHeaderCollapse.value, 0,
          reason: 'four pixels of jitter took the whole header away');
    });

    testWidgets('the settle is ANIMATED when a band is on screen',
        (tester) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 360,
            child: shellCollapsibleBand(
                true, SizedBox(height: _h, key: const Key('band'))),
          ),
        ),
      ));
      final BuildContext context = tester.element(find.byKey(const Key('band')));
      _scroll(_t, context: context);
      expect(shellHeaderCollapse.value, _t);
      _lift(context);
      // Mid-flight: on its way, not there yet, and not still where it was.
      await tester.pump();
      await tester.pump(Duration(
          milliseconds: (Ds.touch.headerSettleMs / 3).round()));
      expect(shellHeaderCollapse.value, greaterThan(_t),
          reason: 'the settle jumped instead of animating');
      expect(shellHeaderCollapse.value, lessThan(_h),
          reason: 'the settle finished in one frame — it is not animating');
      await tester.pump(Duration(
          milliseconds: Ds.touch.headerSettleMs.round() + 50));
      expect(shellHeaderCollapse.value, _h,
          reason: 'the settle never arrived');
    });
  });

  group('the band wrapper draws the position it is given', () {
    /// The band under test, with a build counter on the child so a rebuild
    /// during a flick is visible.
    Widget band(ValueNotifier<int> builds) => Directionality(
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
      await tester.pumpWidget(band(builds));
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
      await tester.pumpWidget(band(builds));
      final top = tester.getTopLeft(find.byKey(const Key('band'))).dy;

      shellHeaderCollapse.value = 20;
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(const Key('band'))).dy, top - 20,
          reason: 'the header shortened in place instead of rising 20 px');
    });

    testWidgets('disabled returns the child untouched — no wrapper at all',
        (tester) async {
      // `identical`, not a widget-type search: the band is a render object, so
      // "no wrapper" is literally "the same Widget back".
      const Widget child = SizedBox(height: 56, key: Key('band'));
      expect(identical(shellCollapsibleBand(false, child), child), isTrue,
          reason: 'a disabled tab was still wrapped in the collapsing band');
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(alignment: Alignment.topLeft, child: child),
      ));
      expect(tester.getSize(find.byKey(const Key('band'))).height, 56);
    });

    testWidgets('neither the header NOR the wrapper rebuilds as it moves',
        (tester) async {
      // #2030 handed the header through untouched, but the wrapper itself was a
      // ValueListenableBuilder: one new Align per frame of every flick, to
      // change one number. The band is a render object, so a whole band of
      // travel — dragged or settling — builds nothing at all.
      final builds = ValueNotifier<int>(0);
      await tester.pumpWidget(band(builds));
      expect(find.byType(ValueListenableBuilder<double>), findsNothing,
          reason: 'the band went back to rebuilding a wrapper every frame');
      expect(find.byType(AnimatedBuilder), findsNothing);
      final RenderObject before =
          tester.renderObject(find.byKey(const Key('band')));
      final int builtBefore = builds.value;
      for (var px = 1.0; px <= _h; px++) {
        shellHeaderCollapse.value = px;
        await tester.pump();
      }
      expect(builds.value, builtBefore,
          reason: 'the header subtree rebuilt on scroll — a whole band of '
              'widgets per frame is what drops the frames');
      expect(
          identical(tester.renderObject(find.byKey(const Key('band'))), before),
          isTrue,
          reason: 'the band rebuilt its own subtree while scrolling');
    });
  });

  group('CMD #2052 · one band for Home AND the Catalogue', () {
    final shell = File('lib/screens/home_shell.dart').readAsStringSync();
    // CMD #2052 — the band is its own shard now (shell_header_band.dart): one
    // driver, one notifier, one settle, one render object, on its own leasable
    // path. The mobile chrome keeps the header it DRAWS.
    final chrome =
        File('lib/screens/shell/shell_header_band.dart').readAsStringSync();
    final catalogue = File('lib/screens/catalogue_screen.dart').readAsStringSync();

    test('the Catalogue tab owns the band, and so does Home', () {
      expect(shellHeaderBandTab(0), isTrue, reason: 'Home lost the band');
      expect(shellHeaderBandTab(12), isTrue,
          reason: 'the Catalogue header still never hides — #2052(8)');
      for (final int other in const [1, 2, 3, 11, 13, 14]) {
        expect(shellHeaderBandTab(other), isFalse,
            reason: 'tab $other started collapsing a header it should keep');
      }
    });

    test('there is ONE driver and ONE notifier, not a second controller', () {
      expect('final ValueNotifier<double> shellHeaderCollapse'
              .allMatches(chrome)
              .length,
          1,
          reason: 'a second band notifier appeared — the two would drift');
      expect('bool shellHeaderScroll('.allMatches(chrome).length, 1,
          reason: 'a second driver appeared');
      expect(catalogue, isNot(contains('shellHeaderCollapse')),
          reason: 'the Catalogue grew its own header controller instead of '
              'riding the shell it already lives in');
      expect(shell,
          contains('shellHeaderScroll(n, !isAdmin && shellHeaderBandTab(_index))'),
          reason: 'the shell stopped feeding the one band from the page '
              'scroll, or wrapped it in something that can rebuild the '
              'IndexedStack');
    });

    test('the Catalogue keeps its own rows OUTSIDE the scroll view', () {
      // The breadcrumb and the A–Z rail are Column children of the page, above
      // the Expanded body. That is what pins them while the band above travels.
      final int trail = catalogue.indexOf('_TrailBar(');
      final int rail = catalogue.indexOf('CatalogueAlphabetRail(');
      final int body = catalogue.indexOf('Expanded(');
      expect(trail, greaterThan(0), reason: 'the breadcrumb row is gone');
      expect(rail, greaterThan(0), reason: 'the A–Z rail is gone');
      expect(trail, lessThan(body),
          reason: 'the breadcrumb moved inside the scrolling body and will '
              'now scroll away with the products');
      expect(rail, lessThan(body),
          reason: 'the A–Z rail moved inside the scrolling body');
      expect(catalogue, isNot(contains('SliverPersistentHeader')),
          reason: 'the Catalogue chrome was moved into a scroll view — it can '
              'no longer stay pinned');
    });
  });

  group('the pinned chrome stays outside the scroll view', () {
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
