// PROTECTED — CHANGE #653.
//
// One interface for super admin, admin and partner: one shell, one nav, one
// set of routes and screens. The ONLY differentiator is the per-feature
// View/Write matrix, and this file holds that down.
//
// What must never regress:
//   * View off means hidden EVERYWHERE — nav entry, route and tab alike.
//   * View on + Write off is read-only; Write on always carries View on.
//   * Nothing is computed in Dart. Every flag and every refusal sentence is
//     read from the backend payload, in the backend's own order.
//   * An UNRESOLVED matrix (boot has not answered yet) is not the same as
//     "off": it must stay permissive, because the RPC layer is the real gate
//     and a slow boot must never blank an admin's whole shell.
//   * A route or tab the registry has not catalogued yet is left visible —
//     forward compatibility, so shipping a screen before its registry row
//     does not make it unreachable.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/admin_nav_entries.dart';
import 'package:pharma_b2b/services/access.dart';

/// A payload shaped exactly like `access_boot()` returns it.
Map<String, dynamic> _boot({
  String role = 'partner',
  bool isSuper = false,
  Map<String, dynamic>? features,
  Map<String, dynamic>? routes,
  Map<String, dynamic>? tabs,
}) =>
    {
      'ok': true,
      'role': role,
      'is_super': isSuper,
      'zone_locked': role == 'partner',
      'zone_id': role == 'partner' ? 1 : null,
      'zone_label': role == 'partner' ? 'Raipur' : '',
      'denied_view_message':
          'This screen is not turned on for your login. Ask a mediBO super admin for access.',
      'denied_write_message':
          'You have view-only access here. Ask a mediBO super admin to turn on Write.',
      'readonly_badge': 'View only',
      'features': features ??
          {
            'partner.pack': {'v': true, 'w': true},
            'partner.disputes': {'v': true, 'w': false},
            'admin.dev_queue': {'v': false, 'w': false},
          },
      'routes': routes ??
          {
            'pack': {'feature': 'partner.pack', 'label': 'Pack', 'v': true, 'w': true},
            'disputes': {
              'feature': 'partner.disputes',
              'label': 'Disputes',
              'v': true,
              'w': false
            },
            'dev_queue': {
              'feature': 'admin.dev_queue',
              'label': 'Dev Queue',
              'v': false,
              'w': false
            },
          },
      'tabs': tabs ??
          {
            'fulfillment': [
              {
                'tab_key': 'pack',
                'label': 'Pack',
                'feature': 'partner.pack',
                'v': true,
                'w': true
              },
              {
                'tab_key': 'disputes',
                'label': 'Disputes',
                'feature': 'partner.disputes',
                'v': true,
                'w': false
              },
              {
                'tab_key': 'collect',
                'label': 'Supplier Shop',
                'feature': 'partner.collect',
                'v': false,
                'w': false
              },
            ],
          },
    };

void main() {
  group('the matrix is READ, never computed', () {
    test('View off hides the feature, the route and the tab', () {
      final m = AccessMatrix.fromJson(_boot());

      expect(m.canView('admin.dev_queue'), isFalse);
      expect(m.canWrite('admin.dev_queue'), isFalse);
      expect(m.routeCanView('dev_queue'), isFalse,
          reason: 'a hidden feature must be hidden on its ROUTE too — the '
              'deep link is the way in behind a hidden nav row');
      expect(m.tabCanView('fulfillment', 'collect'), isFalse);
    });

    test('View on + Write off is read-only, never half-open', () {
      final m = AccessMatrix.fromJson(_boot());

      expect(m.canView('partner.disputes'), isTrue);
      expect(m.canWrite('partner.disputes'), isFalse);
      expect(m.routeCanView('disputes'), isTrue);
      expect(m.routeCanWrite('disputes'), isFalse);
      expect(m.tabCanView('fulfillment', 'disputes'), isTrue);
      expect(m.tabCanWrite('fulfillment', 'disputes'), isFalse);
    });

    test('Write on carries View on', () {
      final m = AccessMatrix.fromJson(_boot());
      expect(m.canWrite('partner.pack'), isTrue);
      expect(m.canView('partner.pack'), isTrue);
    });

    test('a feature the payload never mentioned is OFF, not guessed', () {
      final m = AccessMatrix.fromJson(_boot());
      expect(m.canView('admin.money'), isFalse);
      expect(m.canWrite('admin.money'), isFalse);
    });

    test('the refusal wording is the backend sentence, verbatim', () {
      final m = AccessMatrix.fromJson(_boot());
      expect(
          m.deniedViewMessage,
          'This screen is not turned on for your login. '
          'Ask a mediBO super admin for access.');
      expect(m.deniedWriteMessage,
          'You have view-only access here. Ask a mediBO super admin to turn on Write.');
      expect(m.readonlyBadge, 'View only');
    });

    test('role, super flag and the zone SCOPE are payload reads', () {
      final partner = AccessMatrix.fromJson(_boot());
      expect(partner.role, 'partner');
      expect(partner.isSuper, isFalse);
      expect(partner.zoneLocked, isTrue,
          reason: 'scope is a separate attribute from permission');
      expect(partner.zoneLabel, 'Raipur');

      final admin = AccessMatrix.fromJson(_boot(role: 'admin'));
      expect(admin.zoneLocked, isFalse);
      expect(admin.zoneLabel, '');
    });
  });

  group('one interface: the same payload drives every surface', () {
    test('a super admin holds everything the backend sent', () {
      final m = AccessMatrix.fromJson(_boot(
        role: 'super_admin',
        isSuper: true,
        features: {
          'admin.dev_queue': {'v': true, 'w': true},
          'partner.pack': {'v': true, 'w': true},
        },
        routes: {
          'dev_queue': {'feature': 'admin.dev_queue', 'v': true, 'w': true},
        },
      ));
      expect(m.isSuper, isTrue);
      expect(m.canWrite('admin.dev_queue'), isTrue);
      expect(m.routeCanView('dev_queue'), isTrue);
    });

    test('a partner and an admin with the same toggles read identically', () {
      final asPartner = AccessMatrix.fromJson(_boot(role: 'partner'));
      final asAdmin = AccessMatrix.fromJson(_boot(role: 'admin'));

      for (final key in ['partner.pack', 'partner.disputes', 'admin.dev_queue']) {
        expect(asPartner.canView(key), asAdmin.canView(key),
            reason: 'the ROLE must not change what a feature resolves to — '
                'only the toggles may');
        expect(asPartner.canWrite(key), asAdmin.canWrite(key));
      }
    });

    test('tabs render in PAYLOAD order, each with its own two flags', () {
      final m = AccessMatrix.fromJson(_boot());
      final tabs = m.tabsFor('fulfillment');
      expect(tabs.map((t) => t.tabKey).toList(), ['pack', 'disputes', 'collect'],
          reason: 'deliberately not alphabetical — the screen must not sort');
      expect(tabs.first.label, 'Pack');
      expect(tabs[1].canWrite, isFalse);
      expect(tabs[2].canView, isFalse);
    });
  });

  group('absence is forward compatibility, not a refusal', () {
    test('an unresolved matrix stays permissive so the shell never blanks', () {
      const m = AccessMatrix.unresolved;
      expect(m.resolved, isFalse);
      expect(m.canView('anything'), isTrue);
      expect(m.canWrite('anything'), isTrue);
      expect(m.routeCanView('dev_queue'), isTrue);
      expect(m.tabCanView('fulfillment', 'collect'), isTrue);
    });

    test('ok:false is unresolved, not an empty (all-off) matrix', () {
      final m = AccessMatrix.fromJson({'ok': false, 'role': 'none'});
      expect(m.resolved, isFalse);
      expect(m.canView('partner.pack'), isTrue);
    });

    test('a route with no registry row is left alone, not hidden', () {
      final m = AccessMatrix.fromJson(_boot());
      expect(m.routeCanView('some_screen_shipped_today'), isTrue);
      expect(m.featureForRoute('some_screen_shipped_today'), '');
    });

    test('a tab the backend did not send is left visible', () {
      final m = AccessMatrix.fromJson(_boot());
      expect(m.tabCanView('fulfillment', 'brand_new_tab'), isTrue);
      expect(m.tabCanView('a_screen_with_no_tab_rows', 'anything'), isTrue);
    });
  });

  group('the nav list is filtered by the same answer', () {
    const entries = <AdminNavEntry>[
      AdminNavEntry('Dashboard', Icons.dashboard_outlined, route: 'dashboard'),
      AdminNavEntry('Dev Queue', Icons.terminal, route: 'dev_queue'),
      AdminNavEntry('Pack', Icons.inventory_2_outlined, route: 'pack'),
      AdminNavEntry('No route yet', Icons.help_outline),
    ];

    test('an entry whose route is View=off is dropped', () {
      final m = AccessMatrix.fromJson(_boot());
      final visible = visibleNavEntries(entries, m.routeCanView);
      expect(visible.map((e) => e.label).toList(),
          ['Dashboard', 'Pack', 'No route yet'],
          reason: 'dev_queue is View=off; dashboard has no registry row and a '
              'route-less entry is not a feature at all');
    });

    test('order is preserved so hiding one entry never moves another', () {
      final m = AccessMatrix.fromJson(_boot());
      final visible = visibleNavEntries(entries, m.routeCanView);
      expect(visible.first.route, 'dashboard');
      expect(visible[1].route, 'pack');
    });

    test('an unresolved matrix leaves the whole nav in place', () {
      const m = AccessMatrix.unresolved;
      expect(visibleNavEntries(entries, m.routeCanView).length, entries.length);
    });
  });

  group('the Access holder', () {
    tearDown(Access.instance.clear);

    test('starts unresolved and clears back to unresolved on sign-out', () {
      expect(Access.instance.matrix.resolved, isFalse);
      Access.instance.setMatrix(AccessMatrix.fromJson(_boot()));
      expect(Access.instance.canView('admin.dev_queue'), isFalse);
      Access.instance.clear();
      expect(Access.instance.matrix.resolved, isFalse);
      expect(Access.instance.canView('admin.dev_queue'), isTrue,
          reason: 'a cleared matrix is unresolved, and unresolved is '
              'permissive — the next login re-fetches its own');
    });

    test('notifies listeners so the shell re-reads the nav', () {
      var beats = 0;
      void listener() => beats++;
      Access.instance.addListener(listener);
      Access.instance.setMatrix(AccessMatrix.fromJson(_boot()));
      Access.instance.clear();
      Access.instance.removeListener(listener);
      expect(beats, 2);
    });
  });
}
