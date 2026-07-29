// CHANGE #569 — the Profile screen resolves the account from my_session()
// only (RULE 1: role, display_name, owner_id).
//
// The regression: a registered, approved customer saw "Not Registered" after
// Google login because the screen resolved the account with
// `pharmacy_profiles.eq('user_id', auth.uid())`. That row's user_id was null,
// so the lookup matched nothing even though my_session() named the account.
// These tests pin the decision to the session payload and prove the user_id
// column plays no part in it.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/account_registration.dart';
import 'package:pharma_b2b/models/app_session.dart';

/// The exact my_session() payload returned for auth user
/// 8ecbe189-94d1-4316-85c2-40854a332711 (captured from the live RPC), whose
/// pharmacy_profiles.user_id was null at the time the bug was reported.
Map<String, dynamic> pallaviSession() => <String, dynamic>{
      'signed_in': true,
      'auth_user_id': '8ecbe189-94d1-4316-85c2-40854a332711',
      'login_email': 'pallavibanjare854@gmail.com',
      'role': 'customer',
      'is_admin': false,
      'owner_type': 'customer',
      'owner_id': 'bb7caca1-0ee0-4e95-8245-e8cfcc21b3b2',
      'display_name': 'Pallavi Pharmacy',
      'home_route': '/store',
      'home_label': 'Store',
      'message': 'Signed in',
    };

void main() {
  test('the reported account reads as registered straight from my_session()',
      () {
    final session = AppSession.fromJson(pallaviSession());

    expect(isRegisteredCustomer(session), isTrue);
    // The three fields RULE 1 allows the screen to use.
    expect(session.role, 'customer');
    expect(session.displayName, 'Pallavi Pharmacy');
    expect(session.ownerId, 'bb7caca1-0ee0-4e95-8245-e8cfcc21b3b2');
  });

  test('owner_id is the pharmacy_profiles PK, never the auth user id', () {
    final session = AppSession.fromJson(pallaviSession());

    // Hydration keys off owner_id. If this ever equalled auth_user_id the
    // screen would be back to the user_id join that caused the bug.
    expect(session.ownerId, isNot(session.authUserId));
  });

  test('a signed-in visitor with no customer account is not registered', () {
    final session = AppSession.fromJson({
      ...pallaviSession(),
      'owner_id': '',
      'display_name': '',
    });

    // Genuinely unregistered — the registration CTA is correct here.
    expect(isRegisteredCustomer(session), isFalse);
  });

  test('a signed-out session is not registered', () {
    final session = AppSession.fromJson({'signed_in': false});

    expect(session, same(AppSession.signedOut));
    expect(isRegisteredCustomer(session), isFalse);
  });

  test('an admin session does not read as a registered customer', () {
    final session = AppSession.fromJson({
      ...pallaviSession(),
      'role': 'super_admin',
      'is_admin': true,
      'owner_type': 'admin',
      'owner_id': 'admin-1',
    });

    expect(isRegisteredCustomer(session), isFalse);
    expect(session.isSuperAdmin, isTrue);
  });

  test('an unresolved session (RPC not back yet) is not registered', () {
    expect(isRegisteredCustomer(null), isFalse);
  });
}
