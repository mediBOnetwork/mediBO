// PROTECTED — CHANGE #681 (customer-storefront UI fixes).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes one of these behaviours, never to make an unrelated
// change go green. No network, no Supabase, no camera, no goldens.
//
// What this holds down:
//
//   OTP entry (LoginView code step) is a real 6-box field:
//     • typing a digit lands it in that box and advances;
//     • pasting a whole code spreads across all six boxes;
//     • backspace on a FILLED box clears it in place and does NOT jump back
//       (the old bug: any empty onChanged jumped to the previous box);
//     • backspace on an EMPTY box steps back and clears the previous box.
//
//   The promotional "Health, Delivered with Care" hero is gone from the app —
//   the home banner shows the backend's own title, and the count it prints is
//   the payload's label, never a Dart literal.
//
//   The home feed ends at its footer: the trailing clearance is only whatever
//   bottom chrome floats over it (0 when nothing does), so there is no blank
//   slab below the footer.
//
//   A section's See-all control navigates with the backend's own key.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_state.dart';
import 'package:pharma_b2b/models/cart_model.dart';
import 'package:pharma_b2b/models/home_sections.dart';
import 'package:pharma_b2b/models/storefront_p3.dart';
import 'package:pharma_b2b/screens/auth/login_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/home_sections_view.dart';

// ─────────────────────────── OTP: LoginView code step ───────────────────────

const _loginConfig = <String, dynamic>{
  'brand': 'mediBO',
  'tagline': 'B2B pharma fulfilment',
  'google_label': 'Continue with Google',
  'whatsapp_label': 'Continue on WhatsApp',
  'number_section_label': 'WhatsApp number',
  'number_hint': '00000 00000',
  'number_prefix': '+91',
  'send_label': 'Send code',
  'sending_label': 'Sending',
  'code_section_label': 'Code from WhatsApp',
  'code_digits': 6,
  'code_idle_note': 'Enter the code to continue',
  'verify_label': 'Validate',
  'resend_label': 'Resend',
  // 0 → no resend countdown timer left running after the pump.
  'resend_seconds': 0,
  'sent_to_prefix': 'to',
  'footer_note': 'No password — we only send a login code',
  'show_password': false,
  'show_forgot_password': false,
};

/// Drives the WhatsApp flow to the code step without a network. requestOtp
/// succeeds, the first status poll says 'sent' (which opens the boxes), and
/// verifyOtp returns no `next` so an auto-verify stops cleanly.
class _CodeStepApi implements LoginApi {
  @override
  Future<Map<String, dynamic>> config() async => _loginConfig;

  @override
  Future<Map<String, dynamic>> requestOtp(String input) async =>
      {'ok': true, 'message': ''};

  @override
  Future<Map<String, dynamic>> otpStatus(String input) async =>
      {'state': 'sent', 'message': ''};

  // No 'next' → _verify sets itself back to idle and never navigates.
  @override
  Future<Map<String, dynamic>> verifyOtp(String input, String code) async =>
      <String, dynamic>{};

  @override
  Future<Map<String, dynamic>> postNext(
          String url, Map<String, dynamic> body) async =>
      throw StateError('not reached');

  @override
  Future<void> setSession(String refreshToken) async =>
      throw StateError('not reached');

  @override
  Future<Map<String, dynamic>> session() async =>
      throw StateError('not reached');

  @override
  Future<GoogleResult> googleSignIn({
    required String sheetTitle,
    required String sheetSubtitle,
    required String otherAccount,
    required String unavailableNote,
  }) async =>
      throw StateError('not reached');
}

Future<void> _toCodeStep(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: LoginView(
        api: _CodeStepApi(),
        onHome: (_) {},
        pollInterval: const Duration(milliseconds: 10),
        pollTimeout: const Duration(seconds: 1),
      ),
    ),
  ));
  await tester.pumpAndSettle();

  await tester.tap(find.text('Continue on WhatsApp'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, '9876543210');
  await tester.tap(find.text('Send code'));
  // Let the 10ms status poll fire and open the code boxes.
  await tester.pump(const Duration(milliseconds: 30));
  await tester.pumpAndSettle();

  // Six code boxes are now on screen.
  expect(find.byType(TextField), findsNWidgets(6));
}

TextEditingController _boxCtrl(WidgetTester tester, int i) =>
    tester.widget<TextField>(find.byType(TextField).at(i)).controller!;

// ───────────────────────────── home feed fixtures ───────────────────────────

Map<String, dynamic> _feedPayload() => {
      'ok': true,
      'hero': {
        'show': true,
        'eyebrow': 'EVERY BRAND, ONE ORDER',
        'title': "Your whole month's stock in one place",
        'cta': 'Browse catalogue',
        'props': [
          {'icon': 'inventory', 'label': '30,304+ products'},
          {'icon': 'truck', 'label': 'Next-day delivery'},
        ],
      },
      'sections': [
        {
          'id': 'best_sellers',
          'layout': 'icon_grid',
          'title': 'Shop by category',
          'accent_word': 'category',
          'subtitle': 'EVERY THERAPEUTIC CLASS',
          'see_all': {'type': 'category', 'key': 'All'},
          'see_all_label': 'Show all 30,304 products',
          'items': [
            {
              'label': 'Anti Infectives',
              'count_label': '77,547 products',
              'key': 'ANTI INFECTIVES',
            },
          ],
        },
      ],
    };

Future<List<String>> _pumpFeed(
  WidgetTester tester, {
  double bottomInset = 0,
}) async {
  tester.view.physicalSize = const Size(1000, 3000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  HomeSectionsView.resetMemo();
  addTearDown(HomeSectionsView.resetMemo);

  final categoryTaps = <String>[];

  await tester.pumpWidget(
    AppState(
      cart: CartModel.forTest(),
      child: MaterialApp(
        home: Scaffold(
          body: HomeSectionsView(
            loader: () async => HomeSections.fromMap(_feedPayload()),
            notificationsLoader: () async => BackInStock.empty,
            onCategoryTap: categoryTaps.add,
            bottomInset: bottomInset,
            footer: const Text('THE FOOTER'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return categoryTaps;
}

ListView _feedListView(WidgetTester tester) => tester.widget<ListView>(
      find.byWidgetPredicate(
        (w) => w is ListView && w.key == const PageStorageKey('home-sections'),
      ),
    );

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  setUp(() {
    CartModel.rpcTransport = (fn, params) async =>
        {'ok': true, 'message': '', 'cart': <String, dynamic>{}};
  });
  tearDown(() => CartModel.rpcTransport = null);

  group('OTP entry is a real six-box field', () {
    testWidgets('pasting a whole code spreads across all six boxes',
        (tester) async {
      await _toCodeStep(tester);

      await tester.enterText(find.byType(TextField).first, '123456');
      await tester.pumpAndSettle();

      for (var i = 0; i < 6; i++) {
        expect(_boxCtrl(tester, i).text, '${i + 1}',
            reason: 'box $i holds the ${i + 1}th pasted digit');
      }
    });

    testWidgets('typing a digit lands in its box and the next box takes the '
        'next digit', (tester) async {
      await _toCodeStep(tester);

      await tester.enterText(find.byType(TextField).at(0), '4');
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(1), '7');
      await tester.pump();

      expect(_boxCtrl(tester, 0).text, '4');
      expect(_boxCtrl(tester, 1).text, '7');
    });

    testWidgets('backspace on a FILLED box clears it in place, never jumping '
        'back', (tester) async {
      await _toCodeStep(tester);

      await tester.enterText(find.byType(TextField).at(0), '4');
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(1), '7');
      await tester.pump();

      // Clearing box 1 (an empty onChanged, as a delete produces) must leave
      // box 0 untouched — the old code jumped back and wiped the previous box.
      await tester.enterText(find.byType(TextField).at(1), '');
      await tester.pump();

      expect(_boxCtrl(tester, 1).text, '');
      expect(_boxCtrl(tester, 0).text, '4',
          reason: 'clear-in-place must not touch the previous box');
    });

    testWidgets('backspace on an EMPTY box steps back and clears the previous '
        'box', (tester) async {
      await _toCodeStep(tester);

      await tester.enterText(find.byType(TextField).at(0), '4');
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(1), '7');
      await tester.pump();
      // Focus lands on box 2 (empty) after two digits.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      expect(_boxCtrl(tester, 1).text, '',
          reason: 'the previous box is cleared');
      expect(_boxCtrl(tester, 0).text, '4',
          reason: 'only the immediately previous box is cleared');
    });
  });

  group('the home banner', () {
    testWidgets('renders the backend count label, not a hardcoded number',
        (tester) async {
      await _pumpFeed(tester);

      expect(find.text('30,304+ products'), findsOneWidget,
          reason: 'the count is the payload prop label, printed verbatim');
      expect(find.textContaining('562,889'), findsNothing,
          reason: 'no stale hardcoded catalogue number survives');
    });

    testWidgets('shows the backend hero title, and the removed promo hero is '
        'absent', (tester) async {
      await _pumpFeed(tester);

      expect(find.text("Your whole month's stock in one place"), findsOneWidget);
      expect(find.textContaining('Health, Delivered'), findsNothing,
          reason: 'the "Health, Delivered with Care" hero was deleted app-wide');
    });
  });

  group('the See-all control navigates with the backend key', () {
    testWidgets('tapping "Show all N products" hands back see_all.key',
        (tester) async {
      final taps = await _pumpFeed(tester);

      await tester.tap(find.text('Show all 30,304 products'));
      await tester.pumpAndSettle();

      expect(taps, ['All'],
          reason: 'the shell turns this key into the All-products listing');
    });
  });

  group('the home feed ends at the footer', () {
    testWidgets('no trailing spacer when nothing floats over the feed',
        (tester) async {
      await _pumpFeed(tester, bottomInset: 0);

      expect(find.text('THE FOOTER'), findsOneWidget);
      expect(_feedListView(tester).padding, EdgeInsets.zero,
          reason: 'empty cart → no sticky bar → the page ends at the footer');
    });

    testWidgets('clearance is applied only when bottom chrome floats',
        (tester) async {
      await _pumpFeed(tester, bottomInset: 96);

      expect(_feedListView(tester).padding, const EdgeInsets.only(bottom: 96),
          reason: 'a floating sticky cart bar gets its clearance, and only it');
    });
  });
}
