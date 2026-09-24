// PROTECTED — CMD #2193, the 1.3.35 freeze.
//
// THE BUG THIS HOLDS DOWN, in the words of the person who hit it: "on any
// screen — registration most often — the UI stops responding: no button works,
// only killing and reopening the app helps."
//
// THE CAUSE. Pull-to-close (CMD #2170) takes the navigator's user gesture when
// a pull starts (`didStartUserGesture`) and gives it back when the pull ends.
// Flutter wraps EVERY ModalRoute's subtree in
// `IgnorePointer(ignoring: navigator.userGestureInProgress)`
// (widgets/routes.dart), so a pull that is started and never ended does not
// spoil one animation — it makes every route in the app paint normally and
// accept no taps at all, for the life of the process.
//
// Three ordinary things ended a pull without ending it: a SECOND finger landing
// mid-pull (it re-entered the recogniser and cleared the "we are pulling" flag,
// so the release fired nothing), the route's own controller going away under
// the finger, and the widget being disposed mid-pull.
//
// So what is protected here is not an animation. It is that after ANY of those,
// `userGestureInProgress` is false and the screen still takes a tap.
//
// Dart VM only: no network, no Supabase, no canvas.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/pull_to_close.dart';

const Map<String, dynamic> _kPull = <String, dynamic>{
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

final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

class _Taps extends StatefulWidget {
  const _Taps();
  @override
  State<_Taps> createState() => _TapsState();
}

class _TapsState extends State<_Taps> {
  int taps = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: <Widget>[
            ElevatedButton(
              key: const Key('c2193-button'),
              onPressed: () => setState(() => taps++),
              child: Text('tapped $taps'),
            ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      );
}

Future<void> _pumpPushedPage(WidgetTester tester) async {
  const pull = PullClosePageTransitions(FadeUpwardsPageTransitionsBuilder());
  await tester.pumpWidget(MaterialApp(
    navigatorKey: _navKey,
    theme: ThemeData(
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: pull,
        TargetPlatform.iOS: pull,
        TargetPlatform.linux: pull,
        TargetPlatform.macOS: pull,
        TargetPlatform.windows: pull,
      }),
    ),
    home: const Scaffold(body: Center(child: Text('home'))),
  ));
  _navKey.currentState!.push(MaterialPageRoute<void>(
    settings: const RouteSettings(name: '/product/1'),
    builder: (_) => const _Taps(),
  ));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('c2193-button')), findsOneWidget);
}

Future<void> _expectScreenStillAlive(WidgetTester tester) async {
  expect(_navKey.currentState!.userGestureInProgress, isFalse,
      reason: 'the navigator is still holding a user gesture, which puts '
          'IgnorePointer over every route in the app');
  await tester.tap(find.byKey(const Key('c2193-button')));
  await tester.pump();
  expect(find.text('tapped 1'), findsOneWidget,
      reason: 'the screen painted but would not take a tap — the freeze');
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  setUp(() => Ds.apply(<String, dynamic>{'pull_close': _kPull}));

  testWidgets('a second finger during a pull does not freeze the app',
      (tester) async {
    await _pumpPushedPage(tester);

    final one = await tester.startGesture(const Offset(200, 120));
    await tester.pump();
    await one.moveBy(const Offset(0, 40)); // past the slop: the pull is ours
    await tester.pump();
    expect(_navKey.currentState!.userGestureInProgress, isTrue,
        reason: 'the pull should have taken the gesture');

    // The everyday accident: a second finger (a palm, a thumb) lands.
    final two = await tester.startGesture(const Offset(80, 300));
    await tester.pump();
    await two.up();
    await one.up();
    await tester.pumpAndSettle();

    await _expectScreenStillAlive(tester);
  });

  testWidgets('a pull that is cancelled gives the gesture back',
      (tester) async {
    await _pumpPushedPage(tester);
    final g = await tester.startGesture(const Offset(200, 120));
    await tester.pump();
    await g.moveBy(const Offset(0, 40));
    await tester.pump();
    await g.cancel();
    await tester.pumpAndSettle();
    await _expectScreenStillAlive(tester);
  });

  testWidgets('a route popped from under the finger gives the gesture back',
      (tester) async {
    await _pumpPushedPage(tester);
    final g = await tester.startGesture(const Offset(200, 120));
    await tester.pump();
    await g.moveBy(const Offset(0, 40));
    await tester.pump();

    // The back button, a deep link, a forced logout: the route goes while the
    // finger is still down.
    _navKey.currentState!.pop();
    await tester.pumpAndSettle();
    await g.up();
    await tester.pumpAndSettle();

    expect(_navKey.currentState!.userGestureInProgress, isFalse,
        reason: 'a route disposed mid-pull left the whole app deaf');
  });

  testWidgets('a completed pull closes the page and gives the gesture back',
      (tester) async {
    await _pumpPushedPage(tester);
    final g = await tester.startGesture(const Offset(200, 120));
    await tester.pump();
    await g.moveBy(const Offset(0, 260)); // past threshold_dp
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('c2193-button')), findsNothing,
        reason: 'the pull should still close the page');
    expect(_navKey.currentState!.userGestureInProgress, isFalse);
  });

  group('the recogniser always ends a pull it started', () {
    late int starts;
    late int ends;

    Future<void> pumpRecognizer(WidgetTester tester) async {
      starts = 0;
      ends = 0;
      await tester.pumpWidget(MaterialApp(
        home: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: <Type, GestureRecognizerFactory>{
            PullDownRecognizer:
                GestureRecognizerFactoryWithHandlers<PullDownRecognizer>(
              () => PullDownRecognizer(
                canStart: () => true,
                onPullStart: () => starts++,
                onPullUpdate: (_) {},
                onPullEnd: (_) => ends++,
              ),
              (PullDownRecognizer r) => r
                ..canStart = (() => true)
                ..onPullStart = (() => starts++)
                ..onPullUpdate = ((_) {})
                ..onPullEnd = ((_) => ends++),
            ),
          },
          child: const SizedBox.expand(),
        ),
      ));
    }

    testWidgets('a plain pull starts once and ends once', (tester) async {
      await pumpRecognizer(tester);
      final g = await tester.startGesture(const Offset(200, 120));
      await tester.pump();
      await g.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(starts, 1);
      await g.up();
      await tester.pump();
      expect(ends, 1, reason: 'a pull that started must always end');
    });

    testWidgets('a second finger mid-pull does not swallow the end',
        (tester) async {
      await pumpRecognizer(tester);
      final one = await tester.startGesture(const Offset(200, 120));
      await tester.pump();
      await one.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(starts, 1);

      // THE FREEZE, in one line: a palm or a thumb lands while the pull runs.
      final two = await tester.startGesture(const Offset(60, 400));
      await tester.pump();
      await two.up();
      await one.up();
      await tester.pump();

      expect(starts, 1, reason: 'the second finger must not start a pull');
      expect(ends, 1,
          reason: 'the pull ended without telling anyone — the navigator is '
              'left holding the user gesture and every route goes deaf');
    });

    testWidgets('a cancelled pointer still ends the pull', (tester) async {
      await pumpRecognizer(tester);
      final g = await tester.startGesture(const Offset(200, 120));
      await tester.pump();
      await g.moveBy(const Offset(0, 40));
      await tester.pump();
      await g.cancel();
      await tester.pump();
      expect(ends, 1);
    });

    testWidgets('a pull whose widget is torn down still ends', (tester) async {
      await pumpRecognizer(tester);
      final g = await tester.startGesture(const Offset(200, 120));
      await tester.pump();
      await g.moveBy(const Offset(0, 40));
      await tester.pump();
      expect(starts, 1);
      await tester.pumpWidget(const MaterialApp(home: SizedBox.expand()));
      await tester.pump();
      expect(ends, 1, reason: 'a recogniser disposed mid-pull still owes the '
          'navigator its release');
      await g.up();
    });
  });
}
