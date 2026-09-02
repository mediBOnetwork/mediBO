// CHANGE #657 — the partner surface, and why there is no longer one.
//
// #326 wrote this file because a zone partner landed on the CUSTOMER storefront:
// `my_session()` shipped surface:'partner' and `AccountSurface` had no word for
// it, so the payload parsed to `unresolved`, whose fallthrough IS the storefront.
// The fix gave Dart the word AND made `is_partner` outrank it.
//
// #653 then retired the partner surface in the BACKEND:
// `_session_partner_overlay()` returns surface:'admin', is_admin:true, because
// super admin, admin and partner are ONE interface — what differs is the
// per-feature View/Write matrix and the zone lock, both server-side.
//
// #326's `is_partner` short-circuit outlived the payload it was written for, and
// that is the bug this file now pins. Om signed in as a partner of Jai Mahakal
// on a FRESH build #975 (version.json commit 7b6b3a6c == the running bundle, so
// no cache was involved) and still got "Partner / Your zone, your work" — because
// `AppSession.surface()` returned AccountSurface.partner before it ever read the
// backend's word 'admin'.
//
// What this file holds down now:
//   1. The backend's `surface` word decides, and nothing else does. A partner
//      payload (surface:'admin', is_partner:true) resolves to ADMIN.
//   2. `is_partner` is still carried through as identity/scope — it simply
//      routes nothing.
//   3. The legacy word 'partner' resolves to ADMIN, never to `unresolved` —
//      because `unresolved` is the storefront, which is the #326 bug.
//   4. The RULE 4 mismatch guard still outranks everything.
//   5. The shared partner widgets that the ADMIN interface still uses render the
//      backend verbatim (partnerDestination, PartnerHomeView's tiles).
//
// Fixtures are the SHAPE of the live payload for uid
// 67c8a63a-4e58-4e4e-bcb4-29e63211cc7a (pallavi.medicom@gmail.com).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/app_session.dart';
import 'package:pharma_b2b/screens/partner/partner_home_screen.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The live my_session() payload for the partner login that reported the bug,
/// as `_session_partner_overlay()` returns it AFTER #653: the surface word is
/// 'admin' and is_admin is true. Copied from the function body in pg_proc, not
/// invented here.
Map<String, dynamic> partnerSessionJson({String authUserId = 'uid-partner'}) => {
      'signed_in': true,
      'auth_user_id': authUserId,
      'login_email': 'pallavi.medicom@gmail.com',
      // The USER TYPE stays 'partner' — it is identity, not a route.
      'role': 'partner',
      'surface': 'admin',
      'is_partner': true,
      'is_admin': true,
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
      'home_route': '/dashboard',
      'home_label': 'Dashboard',
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
    test('the live partner payload resolves to the ADMIN surface', () {
      // The exact regression Om reported: this returned AccountSurface.partner
      // on build #975 and rendered the old Partner page.
      final s = AppSession.fromJson(partnerSessionJson());
      expect(s.surface(matchesAuthUser: true), AccountSurface.admin);
    });

    test('the backend word decides — is_partner routes NOTHING', () {
      // Same booleans, a different surface word: if `is_partner` still
      // short-circuited, both of these would answer the same thing.
      final admin = AppSession.fromJson(partnerSessionJson());
      final asCustomer = AppSession.fromJson(
          partnerSessionJson()..['surface'] = 'customer');
      expect(admin.surface(matchesAuthUser: true), AccountSurface.admin);
      expect(asCustomer.surface(matchesAuthUser: true), AccountSurface.customer);
    });

    test("the legacy word 'partner' lands on admin, never on unresolved", () {
      // No backend function emits it any more, but `unresolved` falls through
      // to the customer storefront and that is the #326 bug.
      expect(AppSession.surfaceFromName('partner'), AccountSurface.admin);
      final s = AppSession.fromJson(partnerSessionJson()..['surface'] = 'partner');
      final surface = s.surface(matchesAuthUser: true);
      expect(surface, AccountSurface.admin);
      expect(surface, isNot(AccountSurface.unresolved));
      expect(surface, isNot(AccountSurface.customer));
    });

    test('a partner is still never asked to register a pharmacy', () {
      final s = AppSession.fromJson(partnerSessionJson());
      expect(s.isPartner, isTrue);
      expect(s.isSuperAdmin, isFalse);
      expect(s.isCustomer, isFalse);
      // needs_profile / has_customer_account are what draw "Not Registered" and
      // "Complete Registration" on the customer profile screen.
      expect(s.needsProfile, isFalse);
      expect(s.hasCustomerAccount, isFalse);
      expect(s.canPlaceOrder, isFalse);
    });

    test('the partner identity and its ONE zone are carried through', () {
      // Deleting the partner SURFACE must not delete the partner SCOPE — the
      // zone lock is what every zone-aware RPC is clamped by.
      final s = AppSession.fromJson(partnerSessionJson());
      expect(s.partnerId, '1');
      expect(s.partnerName, 'Jai Mahakal Medical And Surgical');
      expect(s.partnerZoneId, '1');
      expect(s.partnerZoneLabel, 'Raipur Zone');
      expect(s.homeRoute, '/dashboard');
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

  group('the shared partner widgets render the backend, compute nothing', () {
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
