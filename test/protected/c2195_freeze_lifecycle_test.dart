// PROTECTED — CMD #2195, the freeze that survived CMD #2193.
//
// THE BUG, in the words of the person who hit it: "on the installed APK the app
// suddenly stops responding. No button works, nothing reacts, and only killing
// and reopening the app helps. It happens on the registration screen most often
// but I have seen it on every screen." Reproduced repeatedly on 1.3.35.
//
// THE MECHANISM. Pull-to-close (CMD #2170) takes the navigator's user gesture
// while a pull runs (`didStartUserGesture`). Flutter wraps EVERY ModalRoute's
// subtree in `IgnorePointer(ignoring: navigator.userGestureInProgress)`
// (widgets/routes.dart), so a pull that starts and never ends does not spoil
// one animation — it makes every route in the app paint normally and accept no
// touch at all, for the life of the process. Killing the app is the only exit,
// because the flag lives on the navigator and the navigator lives as long as
// the process.
//
// WHAT #2193 CLOSED, AND WHAT IT DID NOT. #2193 made the recogniser end every
// pull it starts: a second finger, a rejection, an arena sweep and dispose all
// land in `didStopTrackingLastPointer`. That closes every path that ends with a
// pointer event. It does not close the path where THERE IS NO POINTER EVENT:
//
//   A pull is running. Another activity takes the window — the image picker or
//   the camera on the registration form, a permission dialog, a notification
//   shade, recents. Android stops handing this app touch events, and the
//   PointerUp for the finger that is mid-pull is never delivered. Nothing in
//   the framework cancels it. The app comes back deaf.
//
// and the path where the release is REFUSED:
//
//   `didStopUserGesture` notifies `userGestureInProgressNotifier`, whose
//   listener is the ListenableBuilder that builds the IgnorePointer. Fired
//   while the tree is locked — which is what `dispose` does, because a widget
//   is disposed DURING a build — that rebuild is refused and the IgnorePointer
//   still on screen never hears that the flag went false.
//
// So what is protected here is not an animation. It is that after the app has
// been away and come back, and after the wrapper is swapped out mid-pull, the
// navigator holds no gesture and the screen still takes a tap.
//
// Dart VM only: no network, no Supabase, no canvas.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/pull_to_close.dart';

/// The backend's own block, as `ui_boot().design.pull_close` sends it after
/// CMD #2195's migration — the registration form's REAL addresses are on the
/// deny list, which is what '/register' was always meant to say.
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
  'deny_prefixes': <String>[
    '/admin', '/partner', '/supplier', '/staff', '/dev',
    '/login', '/register', '/signup',
    '/complete-registration', '/customer/documents', '/delivery-register',
  ],
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
                key: const Key('c2195-button'),
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
  expect(find.byKey(const Key('c2195-button')), findsOneWidget);
}

/// Start a real pull and confirm it really did take the gesture — otherwise the
/// test below would pass without ever reproducing anything.
Future<TestGesture> _startPull(WidgetTester tester) async {
  final g = await tester.startGesture(const Offset(200, 120));
  await tester.pump();
  await g.moveBy(const Offset(0, 40)); // past slop_dp: the pull is ours
  await tester.pump();
  expect(_navKey.currentState!.userGestureInProgress, isTrue,
      reason: 'the pull did not start, so nothing is being reproduced');
  return g;
}

Future<void> _expectScreenStillAlive(WidgetTester tester) async {
  expect(_navKey.currentState!.userGestureInProgress, isFalse,
      reason: 'the navigator is still holding a user gesture, which puts '
          "Flutter's own IgnorePointer over every route in the app — this is "
          'the freeze: painted, and deaf until the app is killed');
  await tester.tap(find.byKey(const Key('c2195-button')));
  await tester.pump();
  expect(find.text('tapped 1'), findsOneWidget,
      reason: 'the screen painted but would not take a tap — the freeze');
}

void main() {
  // The list the APP SHIPS WITH — read before any `Ds.apply`, so it is the
  // value a phone uses for the frames between launch and `ui_boot()` landing.
  late final DsPullClose shipped;

  setUpAll(() {
    RenderLog.flushEnabled = false;
    shipped = Ds.pullClose;
  });
  setUp(() => Ds.apply(<String, dynamic>{'pull_close': _kPull}));

  testWidgets(
      'the picker takes the window mid-pull and no pointer-up ever arrives',
      (tester) async {
    await _pumpPushedPage(tester);
    await _startPull(tester);

    // The registration form's "upload your licence" opens the system picker.
    // From here Android hands this app nothing: no move, no up, no cancel.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 1));

    // …and the finger that was on the glass is never heard from again.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    await _expectScreenStillAlive(tester);
  });

  testWidgets('a pull that is hidden by the app going away is not resumed',
      (tester) async {
    await _pumpPushedPage(tester);
    final g = await _startPull(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 300));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    // A late release for a pointer that is no longer ours must change nothing:
    // no second gesture is taken, and the page is still tappable.
    await g.up();
    await tester.pumpAndSettle();
    await _expectScreenStillAlive(tester);
  });

  testWidgets('the wrapper swapped away mid-pull releases on a legal frame',
      (tester) async {
    await _pumpPushedPage(tester);
    final g = await _startPull(tester);

    // The backend turns the gesture off (ui_design_set) while a finger is
    // down: buildTransitions stops returning the wrapper, so its State is
    // disposed DURING the build — and the release lands inside a locked tree.
    final Map<String, dynamic> off = Map<String, dynamic>.from(_kPull)
      ..['enabled'] = false;
    Ds.apply(<String, dynamic>{'pull_close': off});
    await tester.pumpAndSettle();
    await g.up();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'the release was made inside a frame that was already '
            "building, so Flutter refused the IgnorePointer's rebuild");
    await _expectScreenStillAlive(tester);
  });

  test('the deny list names the screen the freeze was reported on', () {
    Ds.apply(<String, dynamic>{'pull_close': _kPull});
    // The two addresses lib/main.dart gives the one registration form. Before
    // CMD #2195 the list said '/register', which is a prefix of neither, so
    // the form took the gesture the list existed to keep off it.
    expect(Ds.pullClose.allowsRoute('/complete-registration'), isFalse);
    expect(Ds.pullClose.allowsRoute('/customer/documents'), isFalse);
    expect(Ds.pullClose.allowsRoute('/complete-registration?step=docs'),
        isFalse);
    // …and the customer pages it was written FOR still have it.
    expect(Ds.pullClose.allowsRoute('/product/1'), isTrue);
    expect(Ds.pullClose.allowsRoute('/cart'), isTrue);
  });

  test('the shipped list denies it too, for the frames before ui_boot lands',
      () {
    expect(shipped.allowsRoute('/complete-registration'), isFalse);
    expect(shipped.allowsRoute('/customer/documents'), isFalse);
    expect(shipped.allowsRoute('/product/1'), isTrue);
  });
}
