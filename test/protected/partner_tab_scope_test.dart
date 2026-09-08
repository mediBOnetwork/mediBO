// PROTECTED — CHANGE #528, feature_gaps rows 142 + 143 (partner, severity=high).
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes how a partner grant bounds a shared admin screen,
// never to make an unrelated change go green.
//
// The defect these rows recorded: `partnerDestination()` opened WHOLE admin
// screens from a single grant.
//
//   * row 142 — collect / count / bag_mapping / pack / assign_delivery all
//     returned `AdminFulfillmentScreen(initialTab: N)`. `initialTab` only
//     chose which tab was SELECTED first; the tab row and the IndexedStack
//     still built all six children, so a partner holding only `partner.pack`
//     landed on Pack and could tap Collect, Warehouse, Bag, Disputes and
//     Delivery. Tab 4 (Disputes) was not a feature_registry key at all, so no
//     grant could govern it in either direction.
//   * row 143 — `inquiry`, `supplier_orders` AND `supplier_payment` each
//     returned a bare `AdminSupplierScreen()`. Three separately-registered
//     features, three separate access rows, one unbounded screen.
//
// What this holds down:
//
//   1. THE TAB SET IS THE BACKEND'S. `partnerDestination` reads it out of
//      `partner_open().tabs` (which the backend builds from partner_screen_tab
//      joined to the caller's own permissions) and hands it to the screen. The
//      widget never derives a tab set from the route_key it was given.
//   2. ONE GRANT OPENS ONE TAB. A pack-only payload produces {3} — not the six
//      the screen can draw.
//   3. INQUIRY IS NOT SUPPLIER ORDERS. The supplier screen is bounded by the
//      same mechanism, so `partner.inquiry` cannot reach the orders tab.
//   4. ABSENCE MEANS UNBOUNDED, NOT EMPTY. No `tabs` key -> allowedTabs stays
//      null, which is every admin/super-admin call site, byte-identical.
//   5. DISPUTES IS ROUTABLE NOW. 'disputes' resolves to a destination, so the
//      registered `partner.disputes` feature has somewhere to open.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/partner/partner_home_screen.dart';
import 'package:pharma_b2b/screens/admin/admin_fulfillment_screen.dart';
import 'package:pharma_b2b/screens/admin/admin_supplier_screen.dart';

/// The shape `partner_open()` returns for one granted tab.
List<Map<String, dynamic>> _tabs(List<int> indexes) => [
      for (final i in indexes)
        {'index': i, 'key': 'k$i', 'label': 'L$i', 'access': 'write'},
    ];

void main() {
  group('row 142 — one fulfilment grant opens one fulfilment tab', () {
    test('pack-only payload bounds the screen to tab 3', () {
      final dest = partnerDestination('pack', tabs: _tabs([3]));
      expect(dest, isA<AdminFulfillmentScreen>());
      final s = dest as AdminFulfillmentScreen;
      expect(s.initialTab, 3);
      // The defect: this used to be every tab the screen could draw.
      expect(s.allowedTabs, {3});
      expect(s.allowedTabs!.contains(0), isFalse, reason: 'Collect');
      expect(s.allowedTabs!.contains(4), isFalse, reason: 'Disputes');
      expect(s.allowedTabs!.contains(5), isFalse, reason: 'Delivery');
    });

    test('two grants open exactly two tabs, in the payload order', () {
      final s = partnerDestination('collect', tabs: _tabs([0, 2]))
          as AdminFulfillmentScreen;
      expect(s.allowedTabs, {0, 2});
    });

    test('Disputes has a destination now that it is a registered feature', () {
      final s = partnerDestination('disputes', tabs: _tabs([4]))
          as AdminFulfillmentScreen;
      expect(s.initialTab, 4);
      expect(s.allowedTabs, {4});
    });

    test('no tabs in the payload = unbounded = the admin call path', () {
      final s = partnerDestination('pack') as AdminFulfillmentScreen;
      expect(s.allowedTabs, isNull);
      final s2 =
          partnerDestination('pack', tabs: const []) as AdminFulfillmentScreen;
      expect(s2.allowedTabs, isNull);
    });
  });

  group('row 143 — inquiry is not supplier orders', () {
    test('an inquiry grant bounds the supplier screen to the inquiry tab', () {
      final s = partnerDestination('inquiry', tabs: _tabs([1]))
          as AdminSupplierScreen;
      expect(s.allowedTabs, {1});
      expect(s.allowedTabs!.contains(2), isFalse,
          reason: 'Supplier Orders is a separate feature and a separate grant');
      expect(s.allowedTabs!.contains(0), isFalse, reason: 'Suppliers registry');
      expect(s.allowedTabs!.contains(3), isFalse, reason: 'Pending Approval');
    });

    test('a supplier_orders grant opens the orders tab and only that', () {
      final s = partnerDestination('supplier_orders', tabs: _tabs([2]))
          as AdminSupplierScreen;
      expect(s.allowedTabs, {2});
    });

    test('an admin opening the supplier screen stays unbounded', () {
      final s = partnerDestination('inquiry') as AdminSupplierScreen;
      expect(s.allowedTabs, isNull);
    });
  });

  group('the tab list is read, never invented', () {
    test('a malformed entry is skipped rather than guessed at', () {
      final s = partnerDestination('pack', tabs: [
        {'index': 3},
        {'no_index': true},
        'garbage',
      ]) as AdminFulfillmentScreen;
      expect(s.allowedTabs, {3});
    });

    test('an unknown route_key still resolves to nothing', () {
      expect(partnerDestination('admin_dashboard', tabs: _tabs([0])), isNull);
      expect(partnerDestination('', tabs: _tabs([0])), isNull);
    });
  });
}
