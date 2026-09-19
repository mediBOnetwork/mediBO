// CMD #2100 — Two apps, one codebase: the partner flavor's role home.
//
// Holds down:
//   * AppHomeState is the BACKEND's answer and nothing else: blocked:true with
//     a block payload paints the "Use the mediBO app" screen; blocked:false
//     (or a failed call) paints the shell. A rebuild never re-asks; sign-out
//     forgets the answer so the next account is asked.
//   * PartnerAppBlockScreen prints the payload verbatim — title, body, hint,
//     button labels — and its CTA opens exactly the backend's cta_url. No
//     string on it is a Dart literal.
//   * The flavor name is never empty: web is 'web', an Android build with no
//     --flavor is 'customer'; the header key is the one the backend reads.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/build_info.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/partner_app_block_screen.dart';
import 'package:pharma_b2b/services/app_home_state.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _blocked() => {
      'ok': true,
      'flavor': 'partner',
      'role': 'customer',
      'home': 'blocked',
      'blocked': true,
      'block': {
        'title': 'Use the mediBO app',
        'body': 'This app is for mediBO partners, suppliers, delivery and staff.',
        'hint': 'Signed in as test.cust1@medibo.in',
        'cta_label': 'Get mediBO on Google Play',
        'cta_url': 'https://play.google.com/store/apps/details?id=in.medibo.app',
        'signout_label': 'Sign out and use another account',
      },
    };

Map<String, dynamic> _staff() => {
      'ok': true,
      'flavor': 'partner',
      'role': 'supplier',
      'home': 'supplier',
      'blocked': false,
      'block': null,
    };

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    Ds.apply(const {});
  });

  tearDown(() {
    AppHomeState.rpcOverride = null;
    AppHomeState.instance.reset();
  });

  group('the flavor name', () {
    test('is never empty and the header key is the backend\'s', () {
      // In a VM test there is no --flavor and kIsWeb is false.
      expect(appFlavorName, 'customer');
      expect(isPartnerFlavor, isFalse);
      expect(kFlavorHeader, 'x-medibo-flavor');
    });
  });

  group('AppHomeState holds the backend\'s answer', () {
    test('blocked:true exposes the block payload; a rebuild never re-asks',
        () async {
      var calls = 0;
      AppHomeState.rpcOverride = () async {
        calls++;
        return _blocked();
      };
      // No Supabase client in a VM test: sync() finds no uid and asks
      // nothing, so drive the fetch through the same path the root uses
      // once a uid is known.
      final s = AppHomeState.instance;
      expect(s.block, isNull);
      await s.fetchForTest();
      expect(s.block, isNotNull);
      expect(s.block!['title'], 'Use the mediBO app');
      expect(s.home, 'blocked');
      await s.fetchForTest();
      expect(calls, 1, reason: 'the same user is asked exactly once');
    });

    test('blocked:false renders the shell (block is null)', () async {
      AppHomeState.rpcOverride = () async => _staff();
      await AppHomeState.instance.fetchForTest();
      expect(AppHomeState.instance.block, isNull);
      expect(AppHomeState.instance.home, 'supplier');
    });

    test('a failed call is not a block, and it is asked again', () async {
      var calls = 0;
      AppHomeState.rpcOverride = () async {
        calls++;
        throw StateError('network');
      };
      await AppHomeState.instance.fetchForTest();
      expect(AppHomeState.instance.block, isNull);
      await AppHomeState.instance.fetchForTest();
      expect(calls, 2);
    });

    test('reset forgets the answer', () async {
      AppHomeState.rpcOverride = () async => _blocked();
      await AppHomeState.instance.fetchForTest();
      expect(AppHomeState.instance.block, isNotNull);
      AppHomeState.instance.reset();
      expect(AppHomeState.instance.block, isNull);
      expect(AppHomeState.instance.payload, isEmpty);
    });
  });

  group('PartnerAppBlockScreen prints the payload verbatim', () {
    testWidgets('title, body, hint, both buttons; CTA opens cta_url',
        (t) async {
      Uri? opened;
      var signedOut = 0;
      await t.pumpWidget(MaterialApp(
        home: PartnerAppBlockScreen(
          payload: Map<String, dynamic>.from(_blocked()['block'] as Map),
          onSignOut: () async => signedOut++,
          launch: (u) async => opened = u,
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('Use the mediBO app'), findsOneWidget);
      expect(
          find.text(
              'This app is for mediBO partners, suppliers, delivery and staff.'),
          findsOneWidget);
      expect(find.text('Signed in as test.cust1@medibo.in'), findsOneWidget);
      expect(find.text('Get mediBO on Google Play'), findsOneWidget);
      expect(find.text('Sign out and use another account'), findsOneWidget);

      await t.tap(find.text('Get mediBO on Google Play'));
      await t.pump();
      expect(opened.toString(),
          'https://play.google.com/store/apps/details?id=in.medibo.app');

      await t.tap(find.text('Sign out and use another account'));
      await t.pump();
      expect(signedOut, 1);
    });

    testWidgets('an absent body or hint is simply not painted', (t) async {
      await t.pumpWidget(MaterialApp(
        home: PartnerAppBlockScreen(
          payload: const {'title': 'T', 'cta_label': 'C', 'signout_label': 'S'},
          onSignOut: () async {},
          launch: (_) async {},
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('T'), findsOneWidget);
      expect(find.byType(Text), findsNWidgets(3));
    });

    testWidgets('lays out at 360px with no overflow', (t) async {
      t.view.physicalSize = const Size(360, 740);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      await t.pumpWidget(MaterialApp(
        home: PartnerAppBlockScreen(
          payload: Map<String, dynamic>.from(_blocked()['block'] as Map),
          onSignOut: () async {},
          launch: (_) async {},
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.text('Use the mediBO app'), findsOneWidget);
    });
  });
}
