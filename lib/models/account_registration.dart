// CHANGE #569 / #571 — the ONE test for "is this account a registered customer".
//
// Lives beside [AppSession] rather than inside it so the test can be driven
// from a plain VM test, and deliberately platform-free (no dart:html, no
// Supabase).
//
// CHANGE #571 — this used to read `session.role == 'customer' &&
// session.ownerId.isNotEmpty`, which is a role branch: Dart deciding an answer
// the backend already holds. my_session() now ships `has_customer_account`
// directly, so this reads the boolean instead of reconstructing it.
//
// Nothing here looks at `pharmacy_profiles.user_id`, at the Supabase SDK's
// current user, or at any cached flag. A registered customer stays registered
// even when the user_id column is null or points at a stale auth user, which
// is precisely the state that produced a false "Not Registered" after Google
// login.

import 'app_session.dart';

/// True when this ACCOUNT has a customer profile. Note this is "has an
/// account", NOT "is approved" — for approval use [AppSession.canPlaceOrder]
/// or `isRegisteredCustomerFlag`. Conflating the two is what let an unapproved
/// account reach the checkout.
bool isRegisteredCustomer(AppSession? session) =>
    session != null && session.signedIn && session.hasCustomerAccount;
