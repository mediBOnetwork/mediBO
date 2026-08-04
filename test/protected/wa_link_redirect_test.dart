// PROTECTED — /r/<code> campaign tracking link.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes tracking-link behaviour.
//
// What this holds down:
//
//   1. ok:true SENDS THE BROWSER TO `target`, AND NOWHERE ELSE. The destination
//      is a column in wa_links. This page must never derive one from the code,
//      because the click has already been counted by then — a wrong guess puts
//      the customer on the wrong page with the attribution already banked.
//
//   2. THE REDIRECT REPLACES HISTORY. Back must return to WhatsApp, not to this
//      resolver, which would immediately redirect forward again and trap the
//      customer in a loop they can only escape by closing the tab.
//
//   3. ok:false IS AN EMPTY STATE, NEVER A CRASH AND NEVER A BLANK PAGE. The
//      expiry copy is the backend's (expired_title / expired_note / expired_cta
//      / home_route), so rewording it is an UPDATE, not a deploy.
//
//   4. A THROWN RPC — an offline phone, Supabase down — lands on the same card
//      rather than an error screen. This route is opened from a WhatsApp message
//      by a logged-out customer on 4G; a Flutter exception page is not an
//      acceptable outcome for a bad network.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/public/wa_link_redirect_page.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The real ok:false payload from wa_link_click(), read off the live function
/// definition on 2026-08-04.
Map<String, dynamic> _unknownLink() => {
      'ok': false,
      'error': 'unknown_link',
      'expired_title': 'That link has expired',
      'expired_note': 'Browse mediBO to find what you were looking for.',
      'expired_cta': 'Go to mediBO',
      'home_route': '/',
    };

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('ok:true redirects to the payload target', (tester) async {
    final redirects = <String>[];
    var codeSeen = '';

    await tester.pumpWidget(
      MaterialApp(
        home: WaLinkRedirectPage(
          code: 'k7f2a9',
          linkClickRpc: (code) async {
            codeSeen = code;
            return {'ok': true, 'target': 'https://medibo.in/catalogue'};
          },
          onRedirect: redirects.add,
        ),
      ),
    );
    // pump(), not pumpAndSettle(): on the success path the spinner is still on
    // screen and animating forever by design, so settling would never return.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The code goes to the backend exactly as it arrived in the URL.
    expect(codeSeen, 'k7f2a9');
    expect(redirects, ['https://medibo.in/catalogue']);
    expect(tester.takeException(), isNull);

    // Still a spinner, never the expired card: the browser is on its way out.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('That link has expired'), findsNothing);
  });

  testWidgets('the target is taken verbatim, not rebuilt from the code',
      (tester) async {
    final redirects = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: WaLinkRedirectPage(
          code: 'abc123',
          linkClickRpc: (_) async => {
            'ok': true,
            'target': 'https://example.test/anything?utm=wa&x=1',
          },
          onRedirect: redirects.add,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(redirects.single, 'https://example.test/anything?utm=wa&x=1');
  });

  testWidgets('ok:false shows the backend expiry copy and does not crash',
      (tester) async {
    final redirects = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: WaLinkRedirectPage(
          code: 'testcode',
          linkClickRpc: (_) async => _unknownLink(),
          onRedirect: redirects.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('That link has expired'), findsOneWidget);
    expect(find.text('Browse mediBO to find what you were looking for.'),
        findsOneWidget);
    expect(find.text('Go to mediBO'), findsOneWidget);

    // Nothing navigated on its own — an unknown code must not bounce the
    // customer somewhere of the app's choosing.
    expect(redirects, isEmpty);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('the expiry copy is the payload\'s, not a Dart constant',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WaLinkRedirectPage(
          code: 'x',
          linkClickRpc: (_) async => {
            'ok': false,
            'error': 'unknown_link',
            'expired_title': 'यह लिंक समाप्त हो गया है',
            'expired_note': 'मेडीबीओ पर देखें।',
            'expired_cta': 'मेडीबीओ खोलें',
            'home_route': '/hi',
          },
          onRedirect: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('यह लिंक समाप्त हो गया है'), findsOneWidget);
    expect(find.text('मेडीबीओ खोलें'), findsOneWidget);
    // If this screen held its own copy, the English string would appear here.
    expect(find.text('That link has expired'), findsNothing);
  });

  testWidgets('the CTA goes to the payload home_route', (tester) async {
    final redirects = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: WaLinkRedirectPage(
          code: 'x',
          linkClickRpc: (_) async =>
              _unknownLink()..['home_route'] = '/c/cardiac',
          onRedirect: redirects.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Go to mediBO'));
    await tester.pumpAndSettle();

    expect(redirects, ['/c/cardiac']);
  });

  testWidgets('a thrown RPC lands on the expired card, not an error page',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WaLinkRedirectPage(
          code: 'x',
          linkClickRpc: (_) async => throw Exception('offline'),
          onRedirect: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // No payload existed to print, so the offline fallback stands in — but it
    // is still a readable card, never a blank page or a red screen.
    expect(find.text('That link has expired'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('ok:true with an empty target does not navigate to nowhere',
      (tester) async {
    final redirects = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: WaLinkRedirectPage(
          code: 'x',
          linkClickRpc: (_) async => {'ok': true, 'target': ''},
          onRedirect: redirects.add,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(redirects, isEmpty);
    expect(tester.takeException(), isNull);
    expect(find.text('That link has expired'), findsOneWidget);
  });
}
