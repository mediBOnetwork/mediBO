import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/customer/profile_tab_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// CMD #2125 — the Profile tab is customer_profile_tab() rendered verbatim.
Map<String, dynamic> _item(String key, String label, String route,
        {String kind = 'row', String tone = 'default', String tab = ''}) =>
    {
      'feature_key': key,
      'label': label,
      'caption': '',
      'icon_key': 'person',
      'route_key': route,
      'tab': tab,
      'render_kind': kind,
      'tone': tone,
      'badge': '',
    };

final Map<String, dynamic> _payload = {
  'ok': true,
  'has_account': true,
  'header': {
    'avatar_label': 'C',
    'title': 'Chandra Medical',
    'subtitle': '98271 44310 · CUST-0412',
    'chip': {'label': 'Registration pending', 'tone': 'warning'},
  },
  'sections': [
    {
      'key': 'tiles',
      'kind': 'tiles',
      'title': '',
      'items': [
        _item('cust.orders', 'Your orders', 'cust_orders', kind: 'tile'),
        _item('cust.ledger', 'Ledger', 'cust_account', kind: 'tile', tab: 'statement'),
        _item('cust.help_requests', 'Need help?', 'cust_help_requests', kind: 'tile'),
      ],
    },
    {
      'key': 'my_shop',
      'kind': 'hero',
      'title': '',
      'items': [_item('cust.my_shop', 'My Shop', 'my_shop', kind: 'hero')],
    },
    {
      'key': 'other',
      'kind': 'rows',
      'title': 'Other',
      'items': [
        _item('cust.cart', 'Your cart', 'cust_cart'),
        _item('cust.logout', 'Log out', 'cust_logout', kind: 'action', tone: 'danger'),
      ],
    },
  ],
  'share_text': 'x',
  'share_copied': 'y',
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  test('doors are decided from the row alone', () {
    expect(ProfileTabAction.doorOf(_item('a', 'a', 'cust_cart')), ProfileTabDoor.cart);
    expect(ProfileTabAction.doorOf(_item('a', 'a', 'cust_share')), ProfileTabDoor.share);
    expect(ProfileTabAction.doorOf(_item('a', 'a', 'cust_logout')), ProfileTabDoor.logout);
    expect(ProfileTabAction.doorOf(_item('a', 'a', 'my_shop')), ProfileTabDoor.myShop);
    expect(ProfileTabAction.doorOf(_item('a', 'a', 'cust_account', tab: 'billing')),
        ProfileTabDoor.screen);
    expect(ProfileTabAction.doorOf(_item('a', 'a', 'cust_saved_lists')), ProfileTabDoor.shell);
  });

  testWidgets('renders header and sections in payload order, verbatim',
      (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 1600 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    var carts = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProfileTabScreen(
          active: true,
          signedIn: true,
          navigate: (_) {},
          onOpenCart: () => carts++,
          loader: () async => _payload,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Chandra Medical'), findsOneWidget);
    expect(find.text('98271 44310 · CUST-0412'), findsOneWidget);
    expect(find.text('Registration pending'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    for (final t in ['Your orders', 'Ledger', 'Need help?', 'My Shop', 'Other', 'Your cart', 'Log out']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    // Payload order: tiles above the hero above the rows card.
    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    expect(y('Your orders') < y('My Shop'), isTrue);
    expect(y('My Shop') < y('Your cart'), isTrue);
    expect(y('Your cart') < y('Log out'), isTrue);

    // One row height: both rows are 56 px tall.
    Size rowBox(String t) => tester.getSize(find
        .ancestor(of: find.text(t), matching: find.byType(SizedBox))
        .first);
    expect(rowBox('Your cart').height, 56);
    expect(rowBox('Log out').height, 56);

    await tester.tap(find.text('Your cart'));
    expect(carts, 1);
  });

  testWidgets('a failed load shows the error state with Retry', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ProfileTabScreen(
          active: true,
          signedIn: true,
          navigate: (_) {},
          onOpenCart: () {},
          loader: () async => {'ok': false},
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(OutlinedButton), findsOneWidget);
  });
}
