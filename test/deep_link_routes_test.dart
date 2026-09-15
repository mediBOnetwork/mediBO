// CMD #421 — the deep links for Customer 360 and Stock on hand.
//
// CHANGE #865 (#396) shipped both screens and wired them to the dashboard tile,
// the command palette and the order payment panel. The one surface they never
// reached was a LINK: `/admin/go/customer_360/<id>` from a push notification, a
// WhatsApp button or a pasted URL. Two separate bugs stood in the way and this
// file pins both.
//
//  1. The parser welded the subject onto the route. main.dart stripped EVERY
//     slash out of the path tail, so `/admin/go/customer_360/abc` arrived as
//     the single key `customer_360abc` — a key no case in the shell's switch
//     has ever heard of, and that switch has no default branch, so the link
//     opened nothing and said nothing.
//  2. The subject had nowhere to live. A parked link was a bare route string,
//     so even a correctly split id had been thrown away by the time the shell
//     mounted and the URL was long gone.
//
// The shell's switch itself is not pumped here on purpose — HomeShell needs a
// live Supabase to build. What is testable is where the decisions actually
// live: the parser, the parking slot, and the fact that the id reaches the
// screen's own RPC unchanged.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_customer_360_screen.dart';
import 'package:pharma_b2b/screens/admin/nav_registry_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  setUp(() {
    PendingAdminNav.route = null;
    PendingAdminNav.seed = null;
  });

  group('AdminGoLink.parse — the subject is split off, never welded on', () {
    test('a route with a subject keeps them apart', () {
      final link = AdminGoLink.parse('/admin/go/customer_360/cust-9f2a');
      expect(link, isNotNull);
      expect(link!.route, 'customer_360');
      expect(link.seed, 'cust-9f2a');
    });

    test('a route with no subject reports null, not an empty string', () {
      final link = AdminGoLink.parse('/admin/go/stock_on_hand');
      expect(link!.route, 'stock_on_hand');
      expect(link.seed, isNull);
    });

    test('a trailing slash is not a subject', () {
      final link = AdminGoLink.parse('/admin/go/stock_on_hand/');
      expect(link!.route, 'stock_on_hand');
      expect(link.seed, isNull);
    });

    test('a query string is not part of the subject', () {
      final link = AdminGoLink.parse('/admin/go/customer_360/cust-1?from=wa');
      expect(link!.route, 'customer_360');
      expect(link.seed, 'cust-1');
    });

    test('a subject that itself contains a slash survives whole', () {
      final link = AdminGoLink.parse('/admin/go/customer_360/a/b/c');
      expect(link!.route, 'customer_360');
      expect(link.seed, 'a/b/c');
    });

    test('a path that is not an admin-go link is not one', () {
      expect(AdminGoLink.parse('/admin/cron-health'), isNull);
      expect(AdminGoLink.parse('/admin/go/'), isNull);
    });
  });

  group('PendingAdminNav — a parked link keeps its subject', () {
    test('park stores both; take clears only the route', () {
      PendingAdminNav.park('customer_360', 'cust-7');
      expect(PendingAdminNav.take(), 'customer_360');
      // The shell re-parks a link it may not open yet. The subject must still
      // be there on the next pass — the URL is gone by then.
      expect(PendingAdminNav.seed, 'cust-7');
    });

    test('a re-parked link still opens with its subject', () {
      PendingAdminNav.park('customer_360', 'cust-7');
      final first = PendingAdminNav.take();
      PendingAdminNav.route = first; // "not ours to open — leave it parked"
      expect(PendingAdminNav.take(), 'customer_360');
      expect(PendingAdminNav.takeSeed(), 'cust-7');
    });

    test('takeSeed is read-and-clear, so a link fires once', () {
      PendingAdminNav.park('customer_360', 'cust-7');
      expect(PendingAdminNav.takeSeed(), 'cust-7');
      expect(PendingAdminNav.takeSeed(), isNull);
    });

    test('parking with no subject parks null, not an empty subject', () {
      PendingAdminNav.park('stock_on_hand');
      expect(PendingAdminNav.seed, isNull);
      PendingAdminNav.park('customer_360', '');
      expect(PendingAdminNav.seed, isNull);
    });

    test('a new link does not inherit the previous one subject', () {
      PendingAdminNav.park('customer_360', 'cust-7');
      PendingAdminNav.park('stock_on_hand');
      expect(PendingAdminNav.route, 'stock_on_hand');
      expect(PendingAdminNav.seed, isNull);
    });
  });

  testWidgets('the id from the link is the id the screen asks about',
      (tester) async {
    final asked = <String, dynamic>{};
    AdminCustomer360Screen.rpcOverride = (fn, params) async {
      asked[fn] = params;
      return <String, dynamic>{'ok': false, 'message': 'stub'};
    };
    addTearDown(() => AdminCustomer360Screen.rpcOverride = null);

    // Exactly what the route table does with a parked link.
    PendingAdminNav.park('customer_360', 'cust-9f2a');
    PendingAdminNav.take();
    final id = PendingAdminNav.takeSeed()!;

    await tester.pumpWidget(MaterialApp(
      home: AdminCustomer360Screen(customerId: id),
    ));
    await tester.pump();

    expect(asked['customer_360'], isNotNull);
    expect((asked['customer_360'] as Map)['p_customer_id'], 'cust-9f2a');
  });
}
