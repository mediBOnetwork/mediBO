// CHANGE #570 — the post-login destination comes from my_session() only.
//
// The regression: logging in with the number 8357881873 landed on the customer
// storefront even though my_session() returned role=supplier,
// home_route=/supplier, display_name="BHARAT SALES" for that auth user.
//
// Cause: AuthNotifier._resolveRole asked get_my_role() for the admin bits and
// then re-derived supplier-ness from claim_supplier_profile(p_email:). The
// WhatsApp OTP path mints a synthetic address (8357881873@wa.medibo.in) that
// matches no supplier row, so that call returned 'not_found', isSupplier stayed
// false, and HomeShell fell through to the storefront. Logging in with the real
// email worked only because the email happened to match.
//
// These tests pin the session payload -> role/route mapping that the fix now
// relies on, for both login paths (the payload is identical either way — the
// whole point of routing on my_session()).

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/app_session.dart';

/// The exact my_session() payload for auth user
/// bbf44fa9-16c1-487c-8383-f6d362fcad08, captured from the live RPC.
Map<String, dynamic> bharatSalesSession() => <String, dynamic>{
      'signed_in': true,
      'auth_user_id': 'bbf44fa9-16c1-487c-8383-f6d362fcad08',
      'login_email': '8357881873@wa.medibo.in',
      'role': 'supplier',
      'is_admin': false,
      'owner_type': 'supplier',
      'owner_id': '8b43bfdf-0172-4ad0-b2be-ee195dfc15cf',
      'display_name': 'BHARAT SALES',
      'home_route': '/supplier',
      'home_label': 'Supplier Shop',
      'message': 'Signed in',
    };

void main() {
  test('the reported account routes to /supplier straight from my_session()',
      () {
    final session = AppSession.fromJson(bharatSalesSession());

    expect(session.homeRoute, '/supplier');
    expect(session.role, 'supplier');
    expect(session.isSupplier, isTrue);
    expect(session.isAdmin, isFalse);
    expect(session.displayName, 'BHARAT SALES');
  });

  test('supplierId comes from owner_id, not from an email lookup', () {
    final session = AppSession.fromJson(bharatSalesSession());

    // my_supplier_id() for this user; verified equal to owner_id against the
    // live database. The old path got this from claim_supplier_profile(email),
    // which returned not_found for the synthetic WhatsApp address.
    expect(session.supplierId, '8b43bfdf-0172-4ad0-b2be-ee195dfc15cf');
  });

  test('a synthetic WhatsApp login_email does not change the routing', () {
    // The identical account, same payload — the login_email is synthetic on the
    // phone path and real on the email path. Neither may affect the decision.
    final viaPhone = AppSession.fromJson(bharatSalesSession());
    final viaEmail = AppSession.fromJson({
      ...bharatSalesSession(),
      'login_email': 'bharat.sales@example.com',
    });

    expect(viaPhone.homeRoute, viaEmail.homeRoute);
    expect(viaPhone.role, viaEmail.role);
    expect(viaPhone.supplierId, viaEmail.supplierId);
  });

  test('home_route is taken verbatim — no role->route map in Dart', () {
    for (final entry in const {
      'customer': '/store',
      'supplier': '/supplier',
      'super_admin': '/dashboard',
      'admin': '/dashboard',
      'worker': '/route',
      'mr': '/mr',
    }.entries) {
      final session = AppSession.fromJson({
        ...bharatSalesSession(),
        'role': entry.key,
        'home_route': entry.value,
      });
      expect(session.homeRoute, entry.value,
          reason: 'route for ${entry.key} must come from the payload');
    }
  });

  test('a signed-out session lands on /login and is not a supplier', () {
    final session = AppSession.fromJson({'signed_in': false});

    expect(session.homeRoute, '/login');
    expect(session.isSupplier, isFalse);
    expect(session.isAdmin, isFalse);
  });

  test('an empty home_route falls back to /store rather than stranding', () {
    // The fallback exists solely so a malformed row cannot leave the user on a
    // blank route; it is not a role->route inference.
    final session = AppSession.fromJson({
      ...bharatSalesSession(),
      'home_route': '',
    });

    expect(session.homeRoute, '/store');
  });
}
