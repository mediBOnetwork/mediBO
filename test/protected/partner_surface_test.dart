// CHANGE #326 — the partner surface.
//
// A real partner login (a zone-locked fulfilment partner for Jai Mahakal) signed
// in and landed on the CUSTOMER storefront: Best Sellers, a Home/Catalogue/
// Offers/Orders/Bulk bottom nav, and a profile screen telling her
// "Not Registered — Complete Registration" for a pharmacy she will never have.
//
// The backend was never wrong. `my_session()` returned, for that exact uid,
// surface:'partner', is_partner:true, is_admin:false, home_route:'/partner'.
// `AccountSurface` simply had no word for it, so the payload parsed to
// `unresolved` — and the shell's unresolved path IS the customer storefront.
//
// This file pins the three things that let that happen, so none of them can
// come back quietly:
//   1. 'partner' parses to a real surface, and `is_partner` outranks the word.
//   2. A partner is never `customer`, never `admin`, and never asked to
//      register — even though get_my_role() calls them an admin so that the
//      fulfilment RPCs authorise.
//   3. The partner home renders the backend's payload verbatim, draws no zone
//      picker, and has both a way out (sign out) and a real error state.
//
// Fixtures are the SHAPE of the live payload for uid 8ecbe189-…-40854a332711.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/app_session.dart';
import 'package:pharma_b2b/screens/partner/partner_home_screen.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The live my_session() payload for the partner login that reported the bug,
/// trimmed to the fields the surface decision reads.
Map<String, dynamic> partnerSessionJson({String authUserId = 'uid-partner'}) => {
      'signed_in': true,
      'auth_user_id': authUserId,
      'login_email': 'pallavibanjare854@gmail.com',
      // The USER TYPE. get_my_role() still says 'admin' — deliberately — so the
      // zone-scoped fulfilment RPCs keep authorising.
      'role': 'partner',
      'surface': 'partner',
      'is_partner': true,
      'is_admin': false,
      'is_super_admin': false,
      'is_supplier': false,
      'is_customer': false,
      'has_customer_account': false,
      'needs_profile': false,
      'can_place_order': false,
      'owner_type': 'partner',
      'owner_id': '1',
      'partner_id': '1',
      'partner_name': 'Jai Mahakal Medical And Surgical',
      'partner_zone_id': 1,
      'partner_zone_label': 'Raipur Zone',
      'display_name': 'Jai Mahakal Medical And Surgical',
      'header_title': 'Jai Mahakal Medical And Surgical',
      'home_route': '/partner',
      'home_label': 'Partner',
      'order_gate': {
        'has_blocker': true,
        'reason': 'staff_account',
        'title': 'Not a customer account',
        'message': 'This account does not place orders.',
      },
    };

/// A partner_home() payload: two groups, deliberately NOT alphabetical, so a
/// client-side sort would be visible.
const Map<String, dynamic> partnerHomeJson = {
  'ok': true,
  'is_partner': true,
  'partner_id': 1,
  'partner_name': 'Jai Mahakal Medical And Surgical',
  'title': 'Partner',
  'subtitle': 'Your zone, your work.',
  'zone_id': 1,
  'zone_label': 'Raipur Zone',
  'zone_chip': 'Zone · Raipur Zone',
  'show_zone_picker': false,
  'feature_count': 3,
  'has_features': true,
  'groups': [
    {
      'label': 'Supply',
      'sort': '000001',
      'count': 2,
      'features': [
        {
          'feature_key': 'inquiry',
          'label': 'Inquiry',
          'icon_key': 'forum',
          'route_key': 'inquiry',
          'access': 'write',
          'can_write': true,
          'access_label': 'Full access',
        },
        {
          'feature_key': 'supplier_payment',
          'label': 'Supplier payment',
          'icon_key': 'rupee',
          'route_key': 'supplier_payment',
          'access': 'read',
          'can_write': false,
          'access_label': 'View only',
        },
      ],
    },
    {
      'label': 'Warehouse',
      'sort': '000002',
      'count': 1,
      'features': [
        {
          'feature_key': 'pack',
          'label': 'Pack',
          'icon_key': 'bag',
          'route_key': 'pack',
          'access': 'write',
          'can_write': true,
          'access_label': 'Full access',
        },
      ],
    },
  ],
  'empty_title': 'No features enabled yet',
  'empty_message': 'mediBO has not switched on any screens for this partner.',
};

Widget _host(Widget child) => MaterialApp(home: child);

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(const {
      'partner.error_title': 'Could not load your partner home',
      'partner.error_message': 'Check your connection and try again.',
      'partner.retry_label': 'Retry',
      'partner.sign_out_label': 'Sign out',
    });
  });

  group('the surface a partner resolves to', () {
    test("'partner' is a real surface, not an unknown word", () {
      expect(AppSession.surfaceFromName('partner'), AccountSurface.partner);
    });

    test('the live partner payload resolves to the partner surface', () {
      final s = AppSession.fromJson(partnerSessionJson());
      expect(s.surface(matchesAuthUser: true), AccountSurface.partner);
    });

    test('a partner is NEVER the customer surface — the reported bug', () {
      final s = AppSession.fromJson(partnerSessionJson());
      final surface = s.surface(matchesAuthUser: true);
      expect(surface, isNot(AccountSurface.customer));
      // `unresolved` is the value that used to land here, and the shell's
      // unresolved path is the storefront. That is the whole bug.
      expect(surface, isNot(AccountSurface.unresolved));
    });

    test('is_partner outranks a drifted surface word', () {
      // If the backend ever renamed the word, the fallthrough must not put a
      // partner back on the storefront: is_partner is a backend boolean too.
      final json = partnerSessionJson()..['surface'] = 'something_new';
      final s = AppSession.fromJson(json);
      expect(s.surface(matchesAuthUser: true), AccountSurface.partner);
    });

    test('a partner is not an admin and is never asked to register', () {
      final s = AppSession.fromJson(partnerSessionJson());
      expect(s.isPartner, isTrue);
      expect(s.isAdmin, isFalse);
      expect(s.isSuperAdmin, isFalse);
      expect(s.isCustomer, isFalse);
      // needs_profile / has_customer_account are what draw "Not Registered" and
      // "Complete Registration" on the customer profile screen.
      expect(s.needsProfile, isFalse);
      expect(s.hasCustomerAccount, isFalse);
      expect(s.canPlaceOrder, isFalse);
    });

    test('the partner identity and its ONE zone are carried through', () {
      final s = AppSession.fromJson(partnerSessionJson());
      expect(s.partnerId, '1');
      expect(s.partnerName, 'Jai Mahakal Medical And Surgical');
      expect(s.partnerZoneId, '1');
      expect(s.partnerZoneLabel, 'Raipur Zone');
      expect(s.homeRoute, '/partner');
    });

    test('the RULE 4 mismatch guard still outranks everything', () {
      final s = AppSession.fromJson(partnerSessionJson());
      expect(s.surface(matchesAuthUser: false), AccountSurface.unresolved);
    });

    test('a non-partner session is untouched by any of this', () {
      final s = AppSession.fromJson({
        'signed_in': true,
        'auth_user_id': 'uid-cust',
        'surface': 'customer',
        'role': 'customer',
        'has_customer_account': true,
        'can_place_order': true,
      });
      expect(s.isPartner, isFalse);
      expect(s.partnerId, '');
      expect(s.surface(matchesAuthUser: true), AccountSurface.customer);
    });
  });

  group('partner home renders the backend, computes nothing', () {
    testWidgets('groups and tiles print verbatim, in payload order',
        (tester) async {
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: partnerHomeJson,
        onOpen: (_) {},
      )));
      await tester.pump();

      expect(find.text('Partner'), findsOneWidget);
      expect(find.text('Jai Mahakal Medical And Surgical'), findsOneWidget);
      expect(find.text('Zone · Raipur Zone'), findsOneWidget);

      // The backend's own words for access, never composed in Dart.
      expect(find.text('Full access'), findsNWidgets(2));
      expect(find.text('View only'), findsOneWidget);

      // Payload order, not alphabetical: 'Supply' before 'Warehouse', and
      // 'Inquiry' before 'Supplier payment'.
      final supply = tester.getTopLeft(find.text('Supply')).dy;
      final warehouse = tester.getTopLeft(find.text('Warehouse')).dy;
      expect(supply, lessThan(warehouse));
      final inquiry = tester.getTopLeft(find.text('Inquiry')).dy;
      final payment = tester.getTopLeft(find.text('Supplier payment')).dy;
      expect(inquiry, lessThan(payment));
    });

    testWidgets('a tap reports the backend feature_key, not a label',
        (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: partnerHomeJson,
        onOpen: tapped.add,
      )));
      await tester.pump();
      await tester.tap(find.text('Supplier payment'));
      expect(tapped, ['supplier_payment']);
    });

    testWidgets('there is no zone picker — the zone is the backend\'s',
        (tester) async {
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: partnerHomeJson,
        onOpen: (_) {},
      )));
      await tester.pump();
      expect(find.byType(DropdownButton<String>), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(partnerHomeJson['show_zone_picker'], isFalse);
    });

    testWidgets('a failed partner_home() shows backend copy and a Retry',
        (tester) async {
      var retries = 0;
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: const {},
        onOpen: (_) {},
        failed: true,
        onRetry: () => retries++,
      )));
      await tester.pump();

      // Not a blank card: real words, and something to tap.
      expect(find.text('Could not load your partner home'), findsOneWidget);
      expect(find.text('Check your connection and try again.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
    });

    testWidgets('a failure is NOT rendered as "not a partner"', (tester) async {
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: const {},
        onOpen: (_) {},
        failed: true,
        onRetry: () {},
      )));
      await tester.pump();
      // The empty/`is_partner:false` state must not stand in for a network
      // error — that inversion is what drew an unreadable blank card.
      expect(find.text('No features enabled yet'), findsNothing);
    });

    testWidgets('a partner always has a way out', (tester) async {
      var signedOut = 0;
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: partnerHomeJson,
        onOpen: (_) {},
        onSignOut: () => signedOut++,
      )));
      await tester.pump();
      await tester.tap(find.text('Sign out'));
      expect(signedOut, 1);
    });

    testWidgets('the empty state is the backend\'s, when there are no features',
        (tester) async {
      final payload = Map<String, dynamic>.from(partnerHomeJson)
        ..['has_features'] = false
        ..['feature_count'] = 0
        ..['groups'] = const [];
      await tester.pumpWidget(_host(PartnerHomeView(
        payload: payload,
        onOpen: (_) {},
      )));
      await tester.pump();
      expect(find.text('No features enabled yet'), findsOneWidget);
      expect(find.text('Inquiry'), findsNothing);
    });
  });

  group('only permitted features are reachable', () {
    test('every route_key the backend can send resolves to a screen', () {
      // A tile the backend grants but the app cannot open is a dead end; a
      // route the app knows but the backend never grants is an orphan.
      for (final key in const [
        'inquiry',
        'supplier_orders',
        'supplier_payment',
        'collect',
        'count',
        'bag_mapping',
        'pack',
        'assign_delivery',
        'settlement',
      ]) {
        expect(partnerDestination(key), isNotNull, reason: 'route_key $key');
      }
    });

    test('an unknown route_key opens nothing rather than guessing', () {
      expect(partnerDestination('admin_dashboard'), isNull);
      expect(partnerDestination('margin'), isNull);
      expect(partnerDestination(''), isNull);
    });
  });
}
