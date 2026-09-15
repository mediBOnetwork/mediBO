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
// CMD #2038 added the three filters that stand between "a delta arrived" and
// "the finger asked for it", because 1:1 obeyed deltas no finger produced and
// the header popped in and back out mid-scroll:
//
//   · overscroll, bounce and edge snap-back drive the band by NOTHING — only
//     the stretch of a delta inside [min, max] is scrolling at all;
//   · a reversal must travel `Ds.touch.headerHysteresis` before it is believed,
//     and when it is, it is paid in FULL, so 1:1 survives the threshold;
//   · a ballistic phase is locked to the direction of its first delta until the
//     list stops or a finger lands, so a fling never turns around mid-flight;
//   · and the wrapper builds nothing either — the band is a render object that
//     reads the notifier itself.
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

/// CMD #2038 — a notification now says WHO moved the list, because the driver
/// treats a finger and a fling differently. [drag] true is a finger on the
/// glass (`dragDetails` present, which is exactly how Flutter marks a drag
/// update); false is ballistic — a fling coasting, or the physics settling.
ScrollUpdateNotification _update({
  required double delta,
  double pixels = 500,
  double max = 4000,
  double min = 0,
  Axis axis = Axis.vertical,
  bool drag = true,
  required BuildContext context,
}) =>
    ScrollUpdateNotification(
      metrics: _metrics(pixels: pixels, max: max, min: min, axis: axis),
      context: context,
      scrollDelta: delta,
      dragDetails: drag
          ? DragUpdateDetails(
              globalPosition: Offset.zero,
              delta: Offset(0, -delta),
              primaryDelta: -delta,
            )
          : null,
    );

void _scroll(
  double delta, {
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
            pixels: pixels,
            max: max,
            min: min,
            axis: axis,
            drag: drag,
            context: context),
        enabled);

/// The list coming to rest. It ends a fling's direction lock.
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
      // CMD #2038 — `identical`, not a widget-type search: the band is a render
      // object now, so "no wrapper" is literally "the same Widget back".
      const Widget child = SizedBox(height: 56, key: Key('band'));
      expect(identical(shellCollapsibleBand(false, child), child), isTrue,
          reason: 'a disabled tab was still wrapped in the collapsing band');
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(alignment: Alignment.topLeft, child: child),
      ));
      expect(tester.getSize(find.byKey(const Key('band'))).height, 56);
    });

    testWidgets('CMD #2038 — the WRAPPER does not rebuild either', (tester) async {
      // #2030 handed the header through untouched, but the wrapper itself was a
      // ValueListenableBuilder: one new Align per frame of every flick, to
      // change one number. The band is a render object now, so a whole band of
      // travel builds nothing at all — not the header, and not its wrapper.
      final builds = ValueNotifier<int>(0);
      await tester.pumpWidget(_band(builds));
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
      expect(builds.value, builtBefore);
      expect(identical(tester.renderObject(find.byKey(const Key('band'))),
              before),
          isTrue,
          reason: 'the band rebuilt its own subtree while scrolling');
    });
  });

  // ── CMD #2038 — the band moves on INTENT, never on a delta alone ──────────
  group('CMD #2038 · overscroll, bounce and snap-back drive it by nothing', () {
    testWidgets('a bounce past the top and back moves the band by zero',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(_h, context: context);
      expect(shellHeaderCollapse.value, _h);
      // A bouncing list reports pixels BEYOND its own end and then reports
      // them back. Both halves live outside [min, max]; neither is scrolling.
      _scroll(-30, pixels: -30, context: context);
      _scroll(30, pixels: 0, context: context);
      expect(shellHeaderCollapse.value, 0,
          reason: 'arriving at the top wears the whole header — and the '
              'bounce that followed must not take it away again');
    });

    testWidgets('only the stretch INSIDE the list counts', (tester) async {
      final context = await _ctx(tester);
      _scroll(40, context: context);
      expect(shellHeaderCollapse.value, 40);
      // The list bounced 30 px past its own end and is springing back: 50 px
      // reported, running 4030 -> 3980. Thirty of those pixels are outside the
      // list and did not happen; twenty did. The cap is wide open here (the
      // list is 3980 px from its top), so the arithmetic is what is on trial.
      _scroll(-50, pixels: 3980, max: 4000, context: context);
      expect(shellHeaderCollapse.value, 20,
          reason: 'the band was driven by pixels the list does not have');
    });

    testWidgets('an OverscrollNotification never drives the band',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(20, context: context);
      shellHeaderScroll(
          OverscrollNotification(
              metrics: _metrics(pixels: 4000),
              context: context,
              overscroll: 60),
          true);
      expect(shellHeaderCollapse.value, 20,
          reason: 'the glow at the end of the list moved the header');
    });
  });

  group('CMD #2038 · a reversal has to earn its turn', () {
    testWidgets('a 6 px wobble mid-scroll does not move the header',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(30, context: context);
      _scroll(-6, context: context);
      expect(shellHeaderCollapse.value, 30,
          reason: 'finger tremor turned the header around — this IS the '
              'pop-in/pop-out #2038 was filed for');
      // …and carrying on down is obeyed at once: the guard is on TURNING, not
      // on moving. The 6 px that were held are netted off, so the band is
      // exactly where the FINGER is — down 30, up 6, down 10 is 34.
      _scroll(10, context: context);
      expect(shellHeaderCollapse.value, 34,
          reason: 'the held wobble was either lost or paid twice');
    });

    testWidgets('jitter under the threshold NEVER accumulates into a turn',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(40, context: context);
      final double at = shellHeaderCollapse.value;
      // Down-up-down-up, all under 8 px: a finger shaking on the glass.
      for (var i = 0; i < 6; i++) {
        _scroll(-3, context: context);
        _scroll(3, context: context);
      }
      expect(shellHeaderCollapse.value, at,
          reason: 'six wobbles walked the header somewhere');
    });

    testWidgets('a real reversal is paid in FULL — 1:1 survives the threshold',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(40, context: context);
      final double at = shellHeaderCollapse.value;
      // Three 3 px steps: the first two are held, the third crosses 8 and pays
      // all nine. The finger asked for 9 px back and gets 9 px back.
      _scroll(-3, context: context);
      _scroll(-3, context: context);
      expect(shellHeaderCollapse.value, at,
          reason: 'the band turned before the reversal was believed');
      _scroll(-3, context: context);
      expect(shellHeaderCollapse.value, at - 9,
          reason: 'the hysteresis SHORTENED the reversal instead of delaying '
              'it — the first 8 px of every scroll-up would be eaten');
    });

    testWidgets('the threshold is the backend token, not a number in Dart',
        (tester) async {
      final context = await _ctx(tester);
      final double t = Ds.touch.headerHysteresis;
      expect(t, greaterThan(0));
      _scroll(_h, context: context);
      final double at = shellHeaderCollapse.value;
      _scroll(-(t - 1), context: context);
      expect(shellHeaderCollapse.value, at,
          reason: 'a reversal one pixel short of the token was believed');
      _scroll(-1, context: context);
      expect(shellHeaderCollapse.value, at - t,
          reason: 'the reversal did not commit exactly at the token');
    });

    testWidgets('going WITH the grain needs no threshold at all',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(2, context: context);
      _scroll(2, context: context);
      expect(shellHeaderCollapse.value, 4,
          reason: '#2030 promised no threshold on the way the band is already '
              'going, and that promise is untouched');
    });
  });

  group('CMD #2038 · a fling is one direction until it stops', () {
    testWidgets('a snap-back inside a fling cannot turn the header',
        (tester) async {
      final context = await _ctx(tester);
      // The finger lifts; the list coasts. Ballistic deltas carry no drag.
      _scroll(20, drag: false, context: context);
      _scroll(20, drag: false, context: context);
      final double at = shellHeaderCollapse.value;
      _scroll(-20, drag: false, context: context);
      expect(shellHeaderCollapse.value, at,
          reason: 'the header re-evaluated its direction mid-fling — a long '
              'fling down would flash the header on the way');
    });

    testWidgets('the fling still follows the list 1:1 in its own direction',
        (tester) async {
      final context = await _ctx(tester);
      _scroll(10, drag: false, context: context);
      _scroll(10, drag: false, context: context);
      expect(shellHeaderCollapse.value, 20,
          reason: '#2030 1:1 was lost during a fling');
    });

    testWidgets('the list coming to rest releases the lock', (tester) async {
      final context = await _ctx(tester);
      _scroll(30, drag: false, context: context);
      _end(context);
      _scroll(-30, drag: false, context: context);
      expect(shellHeaderCollapse.value, 0,
          reason: 'the fling lock outlived the fling');
    });

    testWidgets('a finger landing mid-fling outranks the lock', (tester) async {
      final context = await _ctx(tester);
      _scroll(40, drag: false, context: context);
      final double at = shellHeaderCollapse.value;
      // Om catches the coasting list and drags it back up. Intent wins, and it
      // still has to clear the hysteresis like any other reversal.
      _scroll(-4, context: context);
      expect(shellHeaderCollapse.value, at);
      _scroll(-6, context: context);
      expect(shellHeaderCollapse.value, at - 10,
          reason: 'a real drag could not overrule a fling that had already '
              'ended in everything but name');
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
