// PROTECTED — CMD #2170, pull down to close.
//
// What this holds down is the thing that is easy to quietly undo: the gesture's
// answers are the BACKEND's, and the page at rest is untouched.
//
//  • Every number — how far, how fast, how long, how round, how dark — arrives
//    in `ui_boot().design.pull_close`. A test that hardcodes 120 would pass
//    against a Dart constant, so each one is proved by CHANGING the token and
//    watching the decision change with it.
//  • Which routes take the gesture is a deny list, not an allow list: a screen
//    nobody has written yet must already be covered, and the staff/admin
//    surfaces must already not be.
//  • Home is never a pull-to-home tab. Home's pull is the refresh it has.
//  • At rest the wrapper renders its child and nothing else — no clip, no
//    opacity layer, no scrim — so a page that is not being pulled is exactly
//    the page that shipped before this command.
//
// Dart VM only: no network, no Supabase, no canvas, no gestures.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/pull_to_close.dart';

/// The shape `ui_boot().design` arrives in.
Map<String, dynamic> _design(Map<String, dynamic> pullClose) =>
    <String, dynamic>{'pull_close': pullClose};

/// `Ds.apply` MERGES — a missing key keeps whatever is live — so every test
/// starts from the same fully-stated block instead of the last test's leftovers.
const Map<String, dynamic> _kBase = <String, dynamic>{
  'enabled': true,
  'threshold_dp': 120,
  'fling_dps': 700,
  'slop_dp': 8,
  'follow': 1.0,
  'corner_dp': 24,
  'scale_min': 0.92,
  'scrim': '#000000',
  'scrim_opacity': 0.45,
  'spring_ms': 200,
  'close_ms': 250,
  'home_index': 0,
  'tab_pages': <int>[1, 2, 12, 15],
  'deny_prefixes': <String>['/admin', '/partner', '/login'],
  'hint': 'Pull down to close',
};

void _tokens([Map<String, dynamic> patch = const <String, dynamic>{}]) =>
    Ds.apply(_design(<String, dynamic>{..._kBase, ...patch}));

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  setUp(_tokens);

  group('the thresholds are the backend’s', () {
    test('a pull closes at the backend’s distance, not a Dart constant', () {
      _tokens(const {'threshold_dp': 120, 'fling_dps': 700});
      expect(PullCloseGeometry.shouldClose(119, 0), isFalse);
      expect(PullCloseGeometry.shouldClose(120, 0), isTrue);

      // Move the token and the SAME pull decides the other way.
      _tokens(const {'threshold_dp': 60});
      expect(PullCloseGeometry.shouldClose(119, 0), isTrue);
      _tokens(const {'threshold_dp': 400});
      expect(PullCloseGeometry.shouldClose(390, 0), isFalse);
    });

    test('a flick closes however short the pull was', () {
      _tokens(const {'threshold_dp': 120, 'fling_dps': 700});
      expect(PullCloseGeometry.shouldClose(20, 699), isFalse);
      expect(PullCloseGeometry.shouldClose(20, 700), isTrue);
      // Upward speed is not a close.
      expect(PullCloseGeometry.shouldClose(20, -2000), isFalse);
    });

    test('the two timings are the backend’s, in milliseconds', () {
      _tokens(const {'spring_ms': 200, 'close_ms': 250});
      expect(Ds.pullClose.spring, const Duration(milliseconds: 200));
      expect(Ds.pullClose.close, const Duration(milliseconds: 250));
      _tokens(const {'spring_ms': 90, 'close_ms': 310});
      expect(Ds.pullClose.spring, const Duration(milliseconds: 90));
      expect(Ds.pullClose.close, const Duration(milliseconds: 310));
    });
  });

  group('the page follows the finger', () {
    test('offset tracks the pull one for one', () {
      _tokens(const {'follow': 1.0});
      final g = PullCloseGeometry.forPull(150, 800);
      expect(g.offset(800), closeTo(150, 0.001));
      expect(g.t, closeTo(1 - 150 / 800, 0.001));
    });

    test('at rest nothing is moved, rounded or scaled', () {
      const g = PullCloseGeometry(1);
      expect(g.offset(800), 0);
      expect(g.radius, 0);
      expect(g.scale, 1);
      // The dim is at its full value — and entirely hidden, because the page
      // covers it. It is what the screen behind sinks to as the page leaves,
      // and PullCloseSurface does not even build it at rest (below).
      expect(g.scrimOpacity, closeTo(Ds.pullClose.scrimOpacity, 0.001));
      expect(const PullCloseGeometry(0).scrimOpacity, 0);
    });

    test('the corner radius and the dim are tokens', () {
      _tokens(const {'corner_dp': 24, 'scrim_opacity': 0.45});
      // Half way out: half the corner, a little over half the dim gone.
      expect(const PullCloseGeometry(0.5).radius, closeTo(12, 0.001));
      expect(const PullCloseGeometry(0.5).scrimOpacity, closeTo(0.225, 0.001));
      _tokens(const {'corner_dp': 8});
      expect(const PullCloseGeometry(0.5).radius, closeTo(4, 0.001));
    });

    test('a pull can never push the page past the viewport', () {
      expect(PullCloseGeometry.forPull(5000, 800).t, 0);
      // …and an upward pull is not a pull at all.
      expect(PullCloseGeometry.forPull(0, 800).t, 1);
    });
  });

  group('which screens take the gesture is a DENY list', () {
    test('a screen nobody has written yet is already covered', () {
      _tokens(const {
        'deny_prefixes': ['/admin', '/login'],
      });
      for (final r in <String>[
        '/product/abc',
        '/compare/abc',
        '/cart',
        '/search',
        '/company/cipla',
        '/c/cardiac',
        '/wishlist',
        '/bulk-upload',
        '/order/SPO1',
        '/profile',
        '/a-screen-invented-next-year',
      ]) {
        expect(Ds.pullClose.allowsRoute(r), isTrue, reason: r);
      }
    });

    test('the staff surfaces and the auth pages keep the old transition', () {
      _tokens(const {
        'deny_prefixes': ['/admin', '/partner', '/login'],
      });
      expect(Ds.pullClose.allowsRoute('/admin'), isFalse);
      expect(Ds.pullClose.allowsRoute('/admin/dev-queue'), isFalse);
      expect(Ds.pullClose.allowsRoute('/admin/dev-queue?panel=runner'), isFalse);
      expect(Ds.pullClose.allowsRoute('/partner/issues'), isFalse);
      expect(Ds.pullClose.allowsRoute('/login'), isFalse);
    });

    test('the master switch turns every route off at once', () {
      _tokens(const {'enabled': false});
      expect(Ds.pullClose.allowsRoute('/product/abc'), isFalse);
      expect(Ds.pullClose.pullsHome(12), isFalse);
    });
  });

  group('tab roots', () {
    test('the listed tabs pull back to Home and Home never does', () {
      _tokens(const {
        'home_index': 0,
        'tab_pages': [1, 2, 12, 15],
      });
      expect(Ds.pullClose.pullsHome(0), isFalse, reason: 'Home’s pull is refresh');
      for (final i in <int>[1, 2, 12, 15]) {
        expect(Ds.pullClose.pullsHome(i), isTrue, reason: 'tab $i');
      }
      expect(Ds.pullClose.pullsHome(7), isFalse, reason: 'an admin page');
    });

    test('the tab list is data — one UPDATE moves it', () {
      _tokens(const {'tab_pages': [12]});
      expect(Ds.pullClose.pullsHome(12), isTrue);
      expect(Ds.pullClose.pullsHome(1), isFalse);
    });

    testWidgets('a tab that does not pull home is handed through untouched',
        (tester) async {
      _tokens(const {'tab_pages': [12]});
      const marker = Key('tab-body');
      await tester.pumpWidget(const MaterialApp(
        home: PullToHomeTab(
          page: 0,
          onHome: _noop,
          child: SizedBox(key: marker),
        ),
      ));
      expect(find.byKey(marker), findsOneWidget);
      expect(find.byType(PullCloseSurface), findsNothing);
    });
  });

  group('a page at rest is the page that shipped', () {
    testWidgets('no clip, no opacity layer, no scrim while resting',
        (tester) async {
      const marker = Key('page');
      await tester.pumpWidget(const MaterialApp(
        home: PullCloseSurface(
          t: 1,
          following: false,
          child: SizedBox(key: marker),
        ),
      ));
      final inside = find.descendant(
          of: find.byType(PullCloseSurface), matching: find.byType(SizedBox));
      expect(inside, findsOneWidget);
      for (final t in <Type>[ClipRRect, ColoredBox, Transform, Opacity]) {
        expect(
            find.descendant(
                of: find.byType(PullCloseSurface), matching: find.byType(t)),
            findsNothing,
            reason: '$t drawn on a page that is only sitting there');
      }
    });

    testWidgets('a pull in progress draws the scrim and moves the page',
        (tester) async {
      _tokens(const {'scrim_opacity': 0.45, 'corner_dp': 24});
      const marker = Key('page');
      await tester.pumpWidget(const MaterialApp(
        home: PullCloseSurface(
          t: 0.5,
          following: true,
          child: SizedBox(key: marker),
        ),
      ));
      expect(find.byKey(marker), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(PullCloseSurface),
              matching: find.byType(ClipRRect)),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(PullCloseSurface),
              matching: find.byType(ColoredBox)),
          findsWidgets);
    });
  });
}

void _noop() {}
