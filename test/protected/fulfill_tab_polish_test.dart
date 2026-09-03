// PROTECTED — CHANGE #754.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes one of these behaviours, never to make an unrelated
// change go green.
//
// Three Om reports on the Fulfill tabs, and each one is really the same bug:
// the app was deciding something the backend already knew.
//
//   1. ONE SCREEN, ONE TAB. Customer Orders kept showing inside Customers, and
//      Supplier Inquiry / Supplier Orders inside Suppliers, after all three
//      moved to Fulfill. It survived because `tabCanView` treats a tab the
//      payload never mentions as VISIBLE — deleting the registry row would
//      have made it MORE visible, not less. So a retired tab keeps its row and
//      arrives with v:false and the route it moved to, and the old deep link
//      resolves to a Fulfill stage the BACKEND paired it with.
//
//   2. The AutoFlow / Bundle chips print the backend's label and the backend's
//      ON/OFF word. A chip with no label is not rendered rather than being
//      given one here, and the tone — not a colour — is what the payload sends.
//
//   3. The Supplier Shop map has exactly TWO sizes, both from the payload, and
//      is never given a zero one: zero is how the widget gets disposed, and a
//      disposed Google map is a paid reload. The status chips are a legend row
//      of their own and the empty-day sentence OVERLAYS the live map.
//
// No network, no Supabase, no goldens — mock payloads inline.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/fulfill/supplier_map_panel_view.dart';
import 'package:pharma_b2b/fulfill/supplier_toggle_chips.dart';
import 'package:pharma_b2b/services/access.dart';

// ── fixtures ───────────────────────────────────────────────────────────────

/// access_boot() as it answers after #754: the three moved tabs are still IN
/// the payload, carrying v:false and where they went.
Map<String, dynamic> _accessPayload() => {
      'ok': true,
      'role': 'super_admin',
      'is_super': true,
      'readonly_badge': 'View only',
      'features': {
        'admin.cust_tab.customers': {'v': true, 'w': true},
        'partner.customer_orders': {'v': true, 'w': true},
        'partner.inquiry': {'v': true, 'w': true},
        'partner.supplier_orders': {'v': true, 'w': true},
      },
      'routes': {
        // The old entry points. Same feature as the Fulfill stage, so the
        // backend pairs them with it.
        'customer_orders': {
          'feature': 'partner.customer_orders',
          'stage': 'customer_order',
          'v': true,
          'w': true,
        },
        'inquiry': {
          'feature': 'partner.inquiry',
          'stage': 'supplier_inquiry',
          'v': true,
          'w': true,
        },
        // A route that is still its own screen carries no stage.
        'customers': {'feature': 'admin.cust_tab.customers', 'stage': '', 'v': true, 'w': true},
      },
      'tabs': {
        'customer': [
          {
            'tab_key': 'customers',
            'label': 'Customers',
            'feature': 'admin.cust_tab.customers',
            'index': 0,
            'active': true,
            'moved_to': '',
            'v': true,
            'w': true,
          },
          {
            'tab_key': 'orders',
            'label': 'Customer Orders',
            'feature': 'partner.customer_orders',
            'index': 1,
            'active': false,
            'moved_to': 'customer_order',
            'v': false,
            'w': false,
          },
        ],
        'supplier': [
          {
            'tab_key': 'inquiry',
            'label': 'Supplier Inquiry',
            'feature': 'partner.inquiry',
            'index': 1,
            'active': false,
            'moved_to': 'supplier_inquiry',
            'v': false,
            'w': false,
          },
          {
            'tab_key': 'orders',
            'label': 'Supplier Orders',
            'feature': 'partner.supplier_orders',
            'index': 2,
            'active': false,
            'moved_to': 'supplier_order',
            'v': false,
            'w': false,
          },
        ],
      },
    };

Map<String, dynamic> _chipPayload() => {
      'ok': true,
      'inquiry': [
        {
          'key': 'auto_meta',
          'setting_key': 'inquiry_auto_meta',
          'label': 'AutoFlow',
          'on': false,
          'state_label': 'OFF',
          'tone': 'off',
        },
        {
          'key': 'bundle',
          'setting_key': 'allocation_mode',
          'label': 'Bundle',
          'on': true,
          'state_label': 'ON',
          'tone': 'on',
          'action_label': 'Re-optimize bundles',
        },
      ],
      'order': [
        {
          'key': 'order_auto_meta',
          'setting_key': 'supplier_order_auto_meta',
          'label': 'AutoFlow',
          'on': true,
          'state_label': 'ON',
          'tone': 'on',
        },
      ],
      'toast_on': 'Automatic by Meta: ON',
      'toast_off': 'Automatic by Meta: OFF',
    };

Map<String, dynamic> _mapPayload({required bool withPoints}) => {
      'status': 'ok',
      'header_label': withPoints ? 'View suppliers in map (12)' : 'View suppliers in map (0)',
      'legend_label': 'Status filters',
      'has_points': withPoints,
      'empty_label': withPoints ? '' : 'No supplier locations for 03/09/2026',
      'map_mini_height': 120,
      'map_full_height': 320,
      'badges': [
        {'key': 'NP', 'filter_key': 'NP', 'text': 'NP·7S', 'fill': '#FCD34D', 'fg': '#7C4A03'},
        {'key': 'P', 'filter_key': 'P', 'text': 'P·5S', 'fill': '#1B7A43', 'fg': '#FFFFFF'},
      ],
      'map_points': withPoints
          ? [
              {'supplier': 'A', 'lat': 21.25, 'lng': 81.62, 'pin_color': '#1B7A43'},
            ]
          : <Map<String, dynamic>>[],
      'groups': withPoints
          ? [
              {'key': 'OMC', 'header': 'Old Medical Complex (1)', 'chips': [], 'suppliers': []},
            ]
          : <Map<String, dynamic>>[],
    };

void main() {
  // ── 1. one screen, one tab ───────────────────────────────────────────────
  group('#754 — a screen lives under ONE tab bar', () {
    final m = AccessMatrix.fromJson(_accessPayload());

    test('a retired tab is hidden, and says where it went', () {
      expect(m.tabCanView('customer', 'orders'), isFalse,
          reason: 'Customer Orders moved to Fulfill and must not draw here');
      expect(m.tabCanWrite('customer', 'orders'), isFalse);
      expect(m.tabMovedTo('customer', 'orders'), 'customer_order');

      expect(m.tabCanView('supplier', 'inquiry'), isFalse);
      expect(m.tabMovedTo('supplier', 'inquiry'), 'supplier_inquiry');
      expect(m.tabCanView('supplier', 'orders'), isFalse);
      expect(m.tabMovedTo('supplier', 'orders'), 'supplier_order');
    });

    test('the tab the screen KEEPS is untouched', () {
      expect(m.tabCanView('customer', 'customers'), isTrue);
      expect(m.tabMovedTo('customer', 'customers'), isEmpty);
    });

    test('a tab the payload never mentions is still visible (forward compat)', () {
      // This is the rule that made the duplicate survive, and it is deliberate:
      // a tab the registry has not caught up with must not vanish. It is also
      // exactly why a retired row is KEPT rather than deleted.
      expect(m.tabCanView('customer', 'a_tab_shipped_next_deploy'), isTrue);
    });

    test('an unresolved matrix hides nothing', () {
      const u = AccessMatrix.unresolved;
      expect(u.tabCanView('customer', 'orders'), isTrue);
      expect(u.tabMovedTo('customer', 'orders'), isEmpty);
    });

    test('a payload from before #754 leaves every listed tab live', () {
      final legacy = AccessMatrix.fromJson({
        'ok': true,
        'features': {'f': {'v': true, 'w': true}},
        'routes': const {},
        'tabs': {
          'customer': [
            {'tab_key': 'orders', 'label': 'Customer Orders', 'feature': 'f', 'v': true, 'w': true},
          ],
        },
      });
      expect(legacy.tabCanView('customer', 'orders'), isTrue);
      expect(legacy.tabMovedTo('customer', 'orders'), isEmpty);
    });
  });

  group('#754 — an old deep link redirects to its Fulfill stage', () {
    final m = AccessMatrix.fromJson(_accessPayload());

    test('the stage is the BACKEND pairing, not a Dart table', () {
      expect(m.fulfillStageForRoute('customer_orders'), 'customer_order');
      expect(m.fulfillStageForRoute('inquiry'), 'supplier_inquiry');
    });

    test('a route that is still its own screen redirects nowhere', () {
      expect(m.fulfillStageForRoute('customers'), isEmpty);
      expect(m.fulfillStageForRoute('route_this_build_never_heard_of'), isEmpty);
    });
  });

  // ── 2. the AutoFlow / Bundle chips ───────────────────────────────────────
  group('#754 — the toggle chips compute nothing', () {
    final set = SupplierToggleChipSet.fromJson(_chipPayload());

    test('labels, state words and toasts are the payload verbatim', () {
      expect(set.inquiry.map((c) => c.label).toList(), ['AutoFlow', 'Bundle']);
      expect(set.inquiry.map((c) => c.stateLabel).toList(), ['OFF', 'ON']);
      expect(set.order.single.label, 'AutoFlow');
      expect(set.order.single.stateLabel, 'ON');
      expect(set.toast(true), 'Automatic by Meta: ON');
      expect(set.toast(false), 'Automatic by Meta: OFF');
    });

    test('the inquiry tab gets two chips, the order tab one', () {
      // The ⋮ menu held exactly these, and nothing else — which is why the row
      // it sat on was empty and why it is gone.
      expect(set.inquiry.length, 2);
      expect(set.order.length, 1);
    });

    test('an extra affordance exists only when the backend offered one', () {
      expect(set.inquiry[0].hasAction, isFalse);
      expect(set.inquiry[1].hasAction, isTrue);
      expect(set.inquiry[1].actionLabel, 'Re-optimize bundles');
    });

    test('a refusal or a chip with no label renders nothing', () {
      expect(SupplierToggleChipSet.fromJson({'ok': false}).inquiry, isEmpty);
      expect(SupplierToggleChipSet.fromJson(null).order, isEmpty);
      expect(
        SupplierToggleChip.listFrom([
          {'key': 'x', 'label': '', 'on': true, 'state_label': 'ON', 'tone': 'on'},
          {'key': '', 'label': 'Nameless', 'on': true, 'state_label': 'ON', 'tone': 'on'},
        ]),
        isEmpty,
      );
    });

    testWidgets('the row prints label + state word and reports the backend key',
        (tester) async {
      final tapped = <String>[];
      final nexts = <bool>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SupplierToggleChipRow(
            chips: set.inquiry,
            onToggle: (c, next) {
              tapped.add(c.key);
              nexts.add(next);
            },
            onAction: (c) => tapped.add('action:${c.key}'),
          ),
        ),
      ));

      expect(find.text('AutoFlow'), findsOneWidget);
      expect(find.text('Bundle'), findsOneWidget);
      expect(find.text('OFF'), findsOneWidget);
      expect(find.text('ON'), findsOneWidget);

      await tester.tap(find.text('AutoFlow'));
      expect(tapped, ['auto_meta']);
      // A tap always asks for the OPPOSITE of what the backend last said —
      // never a value the widget kept for itself.
      expect(nexts, [true]);

      await tester.tap(find.text('Bundle'));
      expect(nexts.last, isFalse);
    });

    testWidgets('a busy chip shows a spinner and refuses taps', (tester) async {
      final tapped = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SupplierToggleChipRow(
            chips: set.order,
            busyKeys: const {'order_auto_meta'},
            onToggle: (c, next) => tapped.add(c.key),
          ),
        ),
      ));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('AutoFlow'));
      expect(tapped, isEmpty);
    });

    testWidgets('an empty set draws no row at all', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SupplierToggleChipRow(chips: const [], onToggle: (_, __) {}),
        ),
      ));
      expect(find.byType(Wrap), findsNothing);
    });
  });

  // ── 3. the Supplier Shop map ─────────────────────────────────────────────
  group('#754 — the map has two sizes and is never removed', () {
    final full = SupplierMapPanelView.fromJson(_mapPayload(withPoints: true));
    final emptyDay = SupplierMapPanelView.fromJson(_mapPayload(withPoints: false));

    test('both heights are the payload\'s numbers', () {
      expect(full.mapHeight(open: false), 120);
      expect(full.mapHeight(open: true), 320);
    });

    test('collapsing never returns a zero height', () {
      // Zero is how the map gets disposed, and every new Google Maps load is
      // billable. The collapsed state is MINI, not gone.
      expect(full.mapHeight(open: false), greaterThan(0));
      expect(emptyDay.mapHeight(open: false), greaterThan(0));
      expect(full.mapIsMounted, isTrue);
      expect(emptyDay.mapIsMounted, isTrue);
    });

    test('a payload that carried only one height still never collapses to 0', () {
      final oneSize = SupplierMapPanelView.fromJson({
        'header_label': 'View suppliers in map (1)',
        'map_full_height': 320,
      });
      expect(oneSize.mapHeight(open: false), 320);
      expect(oneSize.mapHeight(open: true), 320);
    });

    test('the count stays in the header in both sizes', () {
      expect(full.headerLabel, 'View suppliers in map (12)');
      expect(emptyDay.headerLabel, 'View suppliers in map (0)');
    });

    test('the status chips are a legend row, shown in mini as well as full', () {
      expect(full.showsLegend, isTrue);
      expect(emptyDay.showsLegend, isTrue);
      expect(full.legendLabel, 'Status filters');
      expect(full.badges.length, 2);
      // Verbatim: the chip text is the backend's, counts included.
      expect(full.badges.first['text'], 'NP·7S');
    });

    test('an empty day overlays the map instead of replacing it', () {
      expect(emptyDay.hasPoints, isFalse);
      expect(emptyDay.showsEmptyOverlay, isTrue);
      expect(emptyDay.emptyLabel, 'No supplier locations for 03/09/2026');
      expect(emptyDay.mapIsMounted, isTrue,
          reason: 'the empty sentence is drawn OVER the live map');
      expect(full.showsEmptyOverlay, isFalse);
    });

    test('only the supplier groups fold away with the arrow', () {
      expect(full.showsGroups(open: true), isTrue);
      expect(full.showsGroups(open: false), isFalse);
      // An empty day has no groups to fold either way.
      expect(emptyDay.showsGroups(open: true), isFalse);
    });

    test('an unanswered RPC leaves the card unloaded, not broken', () {
      expect(SupplierMapPanelView.fromJson(null).loaded, isFalse);
      expect(SupplierMapPanelView.empty.headerLabel, isEmpty);
      expect(SupplierMapPanelView.empty.showsLegend, isFalse);
    });
  });
}
