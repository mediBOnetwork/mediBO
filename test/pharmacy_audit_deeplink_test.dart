// CMD #447 — the stock audit gets a URL of its own.
//
// #430 shipped the audit (CHANGE #918) reachable only from the shelf app-bar
// icon: no `/pharmacy/audit` route and no `pharmacy_audit` case in the shell's
// switch, because both files were leased by #426 and then #431 for the whole
// of that build. A screen with no URL is not just inconvenient — the
// post-deploy verifier drives the app by URL, so it could never paint that
// screen headlessly, and the one surface #430 could not prove was the one it
// shipped.
//
// Two decisions carry the link, and this file pins both:
//
//  1. `pharmacy_audit` must be SELF-GATED. `_consumePendingDeepLink` re-parks
//     any key that is not in that set when the caller is not an admin — and a
//     pharmacy owner counting their own shelves is not an admin. Miss this and
//     the link lands on the storefront in silence, which is exactly what
//     #432's UPI link did the first time.
//  2. The route key must survive the parser intact, with no subject welded on
//     (the bug #421 fixed for customer_360).
//
// The shell's switch itself is not pumped here, for the same reason
// deep_link_routes_test.dart gives: HomeShell needs a live Supabase to build.
// So the set is exposed and asserted directly rather than inferred from a
// widget that cannot be mounted.
//
// The safety claim behind entry 1 is a BACKEND fact, not a Dart one:
// pharmacy_audit_home() resolves the shop from the caller (_c430_shop()) and
// returns _c430_denied() when there is none, so opening this link as the wrong
// account renders the backend's own refusal. The link grants nothing.
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/nav_registry_view.dart';
import 'package:pharma_b2b/screens/home_shell.dart';
import 'package:pharma_b2b/utils/render_log.dart';

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  setUp(() {
    PendingAdminNav.route = null;
    PendingAdminNav.seed = null;
  });

  group('pharmacy_audit is self-gated, so a pharmacy can open its own link', () {
    test('the key is in the self-gated set', () {
      expect(HomeShell.selfGatedRoutes.contains('pharmacy_audit'), isTrue);
    });

    test('it sits with the other pharmacy-owned screens, not with admin ones', () {
      // Same story as these four: each resolves the caller's OWN pharmacy in
      // SQL and prints the backend's refusal for anyone else.
      for (final key in const [
        'pharmacy_stock',
        'pos',
        'pos_upi',
        'pharmacy_gst',
      ]) {
        expect(HomeShell.selfGatedRoutes.contains(key), isTrue,
            reason: '$key is a pharmacy-owned screen');
      }
      // An admin-only key must NOT have drifted into the set — that would hand
      // a non-admin a door the backend, not the shell, is expected to hold.
      expect(HomeShell.selfGatedRoutes.contains('audit_log'), isFalse);
      expect(HomeShell.selfGatedRoutes.contains('scope_audit'), isFalse);
    });
  });

  group('the link parses to exactly that key', () {
    test('/admin/go/pharmacy_audit is the bare key, no subject', () {
      final link = AdminGoLink.parse('/admin/go/pharmacy_audit');
      expect(link, isNotNull);
      expect(link!.route, 'pharmacy_audit');
      expect(link.seed, isNull);
    });

    test('a trailing slash does not become a subject', () {
      expect(AdminGoLink.parse('/admin/go/pharmacy_audit/')!.route,
          'pharmacy_audit');
      expect(AdminGoLink.parse('/admin/go/pharmacy_audit/')!.seed, isNull);
    });

    test('a parked audit link survives being re-parked and still fires once', () {
      PendingAdminNav.park('pharmacy_audit');
      final first = PendingAdminNav.take();
      expect(first, 'pharmacy_audit');
      PendingAdminNav.route = first; // "not ours to open yet — leave it parked"
      expect(PendingAdminNav.take(), 'pharmacy_audit');
      expect(PendingAdminNav.take(), isNull);
    });
  });
}
