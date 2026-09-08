import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/services/test_session.dart';
import 'package:pharma_b2b/widgets/test_mode_banner.dart';

/// CHANGE #573 — the platform-wide TEST MODE strip.
///
/// What this file holds down is one idea: the banner is the BACKEND's answer,
/// not the app's guess. Om switches test mode on and then walks the real order
/// flow from five different logins; if any screen decided for itself whether
/// the strip belongs there, the one thing that must never be wrong — "is this
/// real?" — would have two sources of truth.
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  setUp(() => TestSessionState.instance.debugSet(const {}));

  testWidgets('no payload — the strip is absent and the page is untouched',
      (tester) async {
    await tester.pumpWidget(host(
      const TestModeBannerHost(child: Text('page')),
    ));
    expect(find.text('page'), findsOneWidget);
    expect(find.byType(TestModeBanner), findsNothing);
  });

  testWidgets('on:false is absent too — "off" is a payload, not a missing key',
      (tester) async {
    TestSessionState.instance.debugSet(const {'on': false, 'poll_ms': 20000});
    await tester.pumpWidget(host(
      const TestModeBannerHost(child: Text('page')),
    ));
    await tester.pump();
    expect(find.byType(TestModeBanner), findsNothing);
  });

  testWidgets('on:true renders the backend words verbatim, above the page',
      (tester) async {
    TestSessionState.instance.debugSet(const {
      'on': true,
      'poll_ms': 20000,
      'session_id': 7,
      'text': 'TEST MODE — nothing here is real',
      'label': '02 Sep 18:40 run',
      'ends_label': 'Auto-ends 03 Sep 06:40',
      'badge': 'TEST',
      'tone': 'danger',
    });
    await tester.pumpWidget(host(
      const TestModeBannerHost(child: Text('page')),
    ));
    await tester.pump();

    expect(find.byType(TestModeBanner), findsOneWidget);
    expect(find.text('TEST MODE — nothing here is real'), findsOneWidget);
    expect(find.text('TEST'), findsOneWidget);
    // Label and expiry share one caption line, joined by the app but WORDED
    // by the backend — no sentence is composed here.
    expect(
      find.text('02 Sep 18:40 run  ·  Auto-ends 03 Sep 06:40'),
      findsOneWidget,
    );
    expect(find.text('page'), findsOneWidget);

    // It reflows rather than floats: a banner you can scroll behind is a
    // banner Om can forget is on.
    final bannerY = tester.getTopLeft(find.byType(TestModeBanner)).dy;
    final pageY = tester.getTopLeft(find.text('page')).dy;
    expect(bannerY, lessThan(pageY));
  });

  testWidgets('a missing string renders empty — never a Dart fallback',
      (tester) async {
    TestSessionState.instance.debugSet(const {'on': true});
    await tester.pumpWidget(host(
      const TestModeBannerHost(child: Text('page')),
    ));
    await tester.pump();
    expect(find.byType(TestModeBanner), findsOneWidget);
    // No invented copy anywhere in the strip.
    expect(find.textContaining('Test'), findsNothing);
    expect(find.textContaining('TEST'), findsNothing);
  });

  testWidgets('the strip appears and disappears with the payload alone',
      (tester) async {
    await tester.pumpWidget(host(
      const TestModeBannerHost(child: Text('page')),
    ));
    expect(find.byType(TestModeBanner), findsNothing);

    TestSessionState.instance.debugSet(const {'on': true, 'text': 'x', 'badge': 'T'});
    await tester.pump();
    expect(find.byType(TestModeBanner), findsOneWidget);
    expect(TestSessionState.instance.isOn, isTrue);

    TestSessionState.instance.debugSet(const {'on': false});
    await tester.pump();
    expect(find.byType(TestModeBanner), findsNothing);
    expect(TestSessionState.instance.isOn, isFalse);
  });
}
