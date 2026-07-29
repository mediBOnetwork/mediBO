// CHANGE #571 — logout must clear the screen, not just the nav.
//
// The regression: after logout the bottom navigation redrew as the signed-out
// set while the body kept showing the previous account's screen. my_session()
// was right all along (signed_in=false, surface='public', home_route='/login')
// — the nav read it and the body did not.
//
// The shell now picks its surface from `my_session().surface` instead of from
// role booleans it derived itself. These tests pin that mapping: the payloads
// below are the exact shapes public.my_session() returns for each role (read
// off the live function definition), and the assertions are what the shell
// switches on.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/app_session.dart';

/// The verbatim signed-out payload from my_session()'s `auth.uid() is null`
/// branch — the one the bug report quotes.
Map<String, dynamic> signedOutPayload() => <String, dynamic>{
      'signed_in': false,
      'auth_user_id': '',
      'login_email': '',
      'role': 'none',
      'is_admin': false,
      'surface': 'public',
      'owner_type': '',
      'owner_id': '',
      'display_name': '',
      'home_route': '/login',
      'home_label': 'Login',
      'message': 'Please log in',
    };

Map<String, dynamic> signedInPayload({
  required String role,
  required String surface,
  required String homeRoute,
  String authUserId = 'auth-user-1',
}) =>
    <String, dynamic>{
      'signed_in': true,
      'auth_user_id': authUserId,
      'login_email': 'someone@medibo.in',
      'role': role,
      'is_admin': role == 'admin' || role == 'super_admin',
      'surface': surface,
      'owner_type': role == 'supplier' ? 'supplier' : 'customer',
      'owner_id': 'owner-1',
      'display_name': 'Someone',
      'home_route': homeRoute,
      'home_label': 'Home',
      'message': 'Signed in',
    };

void main() {
  group('signed out', () {
    test('surface is public and home_route is the backend\'s /login', () {
      final s = AppSession.fromJson(signedOutPayload());

      expect(s.signedIn, isFalse);
      expect(s.surfaceName, 'public');
      // What logout navigates to. Not a literal in Dart — this is the value
      // login_role_config holds for role 'none'.
      expect(s.homeRoute, '/login');
      // The public storefront IS the customer surface; what sends a logged-out
      // user to the login screen is home_route, not the surface.
      expect(s.surface(matchesAuthUser: true), AccountSurface.customer);
    });

    test('a signed-out session never reads as a mismatch', () {
      // The mismatch guard exists to stop account A's session rendering while
      // the SDK holds account B. A signed-out payload carries no account, so it
      // must stay renderable even when the SDK still has a user — this is also
      // the fallback when my_session() cannot be reached, and treating it as a
      // mismatch would pin the app on a spinner forever.
      final s = AppSession.fromJson(signedOutPayload());
      expect(s.surface(matchesAuthUser: false), AccountSurface.unresolved);
      expect(AppSession.signedOut.surfaceName, 'public');
    });
  });

  group('surface comes from the backend, not from role', () {
    test('admin', () {
      final s = AppSession.fromJson(signedInPayload(
          role: 'admin', surface: 'admin', homeRoute: '/dashboard'));
      expect(s.surface(matchesAuthUser: true), AccountSurface.admin);
      expect(s.homeRoute, '/dashboard');
    });

    test('super_admin lands on the admin surface too', () {
      final s = AppSession.fromJson(signedInPayload(
          role: 'super_admin', surface: 'admin', homeRoute: '/dashboard'));
      expect(s.surface(matchesAuthUser: true), AccountSurface.admin);
    });

    test('approved supplier', () {
      final s = AppSession.fromJson(signedInPayload(
          role: 'supplier', surface: 'supplier', homeRoute: '/supplier'));
      expect(s.surface(matchesAuthUser: true), AccountSurface.supplier);
    });

    test('customer', () {
      final s = AppSession.fromJson(signedInPayload(
          role: 'customer', surface: 'customer', homeRoute: '/store'));
      expect(s.surface(matchesAuthUser: true), AccountSurface.customer);
    });

    test('worker renders the customer surface, as it did before', () {
      final s = AppSession.fromJson(signedInPayload(
          role: 'worker', surface: 'worker', homeRoute: '/route'));
      expect(s.surface(matchesAuthUser: true), AccountSurface.customer);
    });

    test('a supplier awaiting approval is not a plain customer', () {
      // my_supplier_id() only matches approved rows, so the backend calls this
      // account a customer. claim_supplier_profile — also the backend — is what
      // tells the two apart, and the waiting screen depends on it.
      final s = AppSession.fromJson(signedInPayload(
              role: 'customer', surface: 'customer', homeRoute: '/store'))
          .withSupplierStatus('pending_approval');
      expect(s.surface(matchesAuthUser: true), AccountSurface.pendingSupplier);
      expect(s.surfaceName, 'customer', reason: 'withSupplierStatus must carry the surface through');
    });
  });

  group('nothing renders on an unresolved or mismatched session', () {
    test('a signed-in session for a different auth user', () {
      final s = AppSession.fromJson(signedInPayload(
          role: 'admin', surface: 'admin', homeRoute: '/dashboard'));
      expect(s.surface(matchesAuthUser: false), AccountSurface.unresolved);
    });

    test('a payload with no surface at all', () {
      final raw = signedInPayload(
          role: 'customer', surface: 'customer', homeRoute: '/store')
        ..remove('surface');
      final s = AppSession.fromJson(raw);
      expect(s.surfaceName, '');
      expect(s.surface(matchesAuthUser: true), AccountSurface.unresolved,
          reason: 'an absent surface is not the same as public');
    });
  });

  test('View As customer overrides an admin session, and only that', () {
    final s = AppSession.fromJson(signedInPayload(
        role: 'super_admin', surface: 'admin', homeRoute: '/dashboard'));
    expect(
        s.surface(matchesAuthUser: true, actingAsCustomer: true),
        AccountSurface.customer);
    expect(s.surface(matchesAuthUser: true), AccountSurface.admin);
  });
}
