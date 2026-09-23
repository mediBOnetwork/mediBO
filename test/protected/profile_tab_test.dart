// CMD #2174 — the Profile tab renders the backend's list, whatever
// `has_account` says.
//
// The live bug: a signed-in user whose pharmacy is not registered opened
// Profile and saw the name card and the "Not Registered" chip and NOTHING
// else — no Your cart, no Notifications, no About, and no Log out, so the
// account had no way out of itself. `customer_profile_tab()` was correct the
// whole time: it answers has_account=false plus three `rows` sections holding
// seven items, the last of them Log out with tone 'danger'.
//
// What this file holds down is that the tab computes NOTHING about who the
// viewer is. Both fixtures below are verbatim RPC answers — one for a
// registered pharmacy, one for an account with none — and the tab must draw
// every section and every item of whichever one it is handed, in payload
// order, with the danger row red and every row's tap carrying its own
// route_key. A regression that re-introduces an app-side account gate (on
// has_account, on a section key, on a row count) fails here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/customer/profile_tab_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Map<String, dynamic> _row(String key, String label, String route,
        {String tone = 'default'}) =>
    {
      'feature_key': key,
      'label': label,
      'caption': '',
      'icon_key': 'settings',
      'route_key': route,
      'tab': '',
      'render_kind': 'row',
      'tone': tone,
      'badge': '',
    };

/// `customer_profile_tab()` for a signed-in account with no pharmacy — copied
/// from the live answer, three sections and seven rows.
Map<String, dynamic> _unregistered() => {
      'ok': true,
      'has_account': false,
      'header': {
        'avatar_label': 'G',
        'title': 'Ghost Tester',
        'subtitle': '',
        'chip': {'label': 'Not Registered', 'tone': 'neutral'},
      },
      'sections': [
        {
          'key': 'info',
          'kind': 'rows',
          'title': 'Your information',
          'items': [_row('cust.cart', 'Your cart', 'cust_cart')],
        },
        {
          'key': 'prefs',
          'kind': 'rows',
          'title': 'Preferences',
          'items': [
            _row('cust.notifications', 'Notifications', 'cust_notifications')
          ],
        },
        {
          'key': 'other',
          'kind': 'rows',
          'title': 'Other',
          'items': [
            _row('cust.share_app', 'Share the app', 'cust_share'),
            _row('cust.about', 'About mediBO', 'cust_about'),
            _row('cust.privacy', 'Privacy', 'cust_privacy'),
            _row('cust.terms', 'Terms', 'cust_terms'),
            _row('cust.logout', 'Log out', 'cust_logout', tone: 'danger'),
          ],
        },
      ],
      'share_text': 'Order every brand for your pharmacy on mediBO',
      'share_copied': 'Link copied',
    };

/// The same RPC for a registered pharmacy: tiles and a hero ride above the
/// same rows, so the fix may not special-case the `rows` kind either.
Map<String, dynamic> _registered() => {
      'ok': true,
      'has_account': true,
      'header': {
        'avatar_label': 'P',
        'title': 'Prince Pharmacy',
        'subtitle': '98xxxxxx01 · PRI101',
        'chip': {'label': 'Approved', 'tone': 'success'},
      },
      'sections': [
        {
          'key': 'tiles',
          'kind': 'tiles',
          'title': '',
          'items': [
            _row('cust.orders', 'Orders', 'cust_orders'),
            _row('cust.ledger', 'Ledger', 'cust_account'),
          ],
        },
        {
          'key': 'my_shop',
          'kind': 'hero',
          'title': '',
          'items': [_row('cust.my_shop', 'My Shop', 'my_shop')],
        },
        {
          'key': 'other',
          'kind': 'rows',
          'title': 'Other',
          'items': [
            _row('cust.about', 'About mediBO', 'cust_about'),
            _row('cust.logout', 'Log out', 'cust_logout', tone: 'danger'),
          ],
        },
      ],
      'share_text': 'Order every brand for your pharmacy on mediBO',
      'share_copied': 'Link copied',
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> payload,
    {List<String>? taps, double width = 412}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ProfileTabScreen(
        active: true,
        signedIn: true,
        loader: () async => payload,
        navigate: (r) => taps?.add('nav:$r'),
        onOpenCart: () => taps?.add('cart'),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  testWidgets('has_account=false still draws every section and every row',
      (tester) async {
    await _pump(tester, _unregistered());

    // The header the shopper already saw.
    expect(find.text('Ghost Tester'), findsOneWidget);
    expect(find.text('Not Registered'), findsOneWidget);

    // …and the seven rows that were missing, each by its OWN handle, so a
    // section that quietly stops rendering cannot hide behind a count.
    for (final key in const [
      'cust.cart',
      'cust.notifications',
      'cust.share_app',
      'cust.about',
      'cust.privacy',
      'cust.terms',
      'cust.logout',
    ]) {
      expect(find.bySemanticsIdentifier('profile_row_$key'), findsOneWidget,
          reason: 'row $key must render for an unregistered account');
    }

    // The section titles are the backend's, in payload order.
    expect(find.text('Your information'), findsOneWidget);
    expect(find.text('Preferences'), findsOneWidget);
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('Log out'), findsOneWidget);
  });

  testWidgets('the danger row is red and the plain rows are not',
      (tester) async {
    await _pump(tester, _unregistered());

    Color labelColour(String label) => tester
        .widget<Text>(find.descendant(
            of: find.bySemanticsIdentifier('profile_row_cust.$label'),
            matching: find.byType(Text)))
        .style!
        .color!;

    expect(labelColour('logout'), Ds.c.danger);
    expect(labelColour('about'), Ds.c.text);
  });

  testWidgets('a tap carries the row own route_key', (tester) async {
    final taps = <String>[];
    await _pump(tester, _unregistered(), taps: taps);

    await tester.tap(find.bySemanticsIdentifier('profile_row_cust.cart'));
    await tester.pumpAndSettle();
    expect(taps, ['cart']);

    // Log out is the reason this command exists: it must reach the door, and
    // the door lands on the public home.
    expect(ProfileTabAction.doorOf(_row('cust.logout', 'Log out', 'cust_logout')),
        ProfileTabDoor.logout);
  });

  testWidgets('a registered account is unchanged — tiles, hero and rows',
      (tester) async {
    await _pump(tester, _registered());

    expect(find.text('Prince Pharmacy'), findsOneWidget);
    for (final key in const [
      'cust.orders',
      'cust.ledger',
      'cust.my_shop',
      'cust.about',
      'cust.logout',
    ]) {
      expect(find.bySemanticsIdentifier('profile_row_$key'), findsOneWidget);
    }
  });

  testWidgets('a payload with no rows at all says so in the backend words',
      (tester) async {
    final empty = _unregistered()
      ..['sections'] = const []
      ..['empty_label'] = 'Nothing to show here yet. Pull down to refresh.';
    await _pump(tester, empty);

    // The header still draws — and so does a sentence, instead of the blank
    // page under it that #2174 was reported for.
    expect(find.text('Ghost Tester'), findsOneWidget);
    expect(find.bySemanticsIdentifier('profile_rows_empty'), findsOneWidget);
    expect(find.text('Nothing to show here yet. Pull down to refresh.'),
        findsOneWidget);
  });

  testWidgets('no overflow at 360 or 412', (tester) async {
    for (final w in const [360.0, 412.0]) {
      await _pump(tester, _unregistered(), width: w);
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsIdentifier('profile_row_cust.logout'),
          findsOneWidget);
    }
  });
}
