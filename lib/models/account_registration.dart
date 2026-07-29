// CHANGE #569 — the ONE test for "is this account a registered customer".
//
// Lives beside [AppSession] rather than inside it so app_session.dart stays
// byte-identical to the CHANGE #558 original, and deliberately platform-free
// (no dart:html, no Supabase) so it can be driven from a plain VM test.

import 'app_session.dart';

/// RULE 1 — role and owner_id both come from my_session().
///
/// Nothing here looks at `pharmacy_profiles.user_id`, at the Supabase SDK's
/// current user, or at any cached flag. A registered customer stays registered
/// even when the user_id column is null or points at a stale auth user, which
/// is precisely the state that produced a false "Not Registered" after Google
/// login.
///
/// owner_id is empty for a signed-in visitor who has no customer account —
/// that is the genuine "needs to register" case, not a failed lookup.
bool isRegisteredCustomer(AppSession? session) =>
    session != null &&
    session.signedIn &&
    session.role == 'customer' &&
    session.ownerId.isNotEmpty;
