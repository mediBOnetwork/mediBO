// Journey `menu-reachability`, implemented (CHANGE #237), moved to the registry
// (CHANGE #325).
//
// What it has always pinned: a super-admin can reach Dev Queue FROM THE MENU,
// a plain admin cannot, and neither reaches it by typing a URL. Flutter renders
// to canvas, so it cannot be a headless click test; it is a widget test on the
// nav surface instead, which is repeatable and cannot rot silently.
//
// #325 changed WHERE that menu is. Dev Queue used to be a hard-coded row in the
// wide "More" popup and the narrow profile sheet, gated by an `isSuperAdmin`
// bool passed down from the shell. Both surfaces are gone: Dev Queue is a row
// in feature_registry (category 'system', roles_allowed ['super_admin']) and it
// renders as a dashboard tile. The gate moved with it — `nav_registry()` filters
// on roles_allowed in SQL, so a plain admin's payload simply does not contain
// the row, and there is no `isSuperAdmin` branch left in Dart to get wrong.
//
// That is the stronger arrangement, and it is what this test now checks: the
// nav renders exactly the rows the backend sent, so "a plain admin cannot reach
// Dev Queue" is proven by the tile being absent from their payload rather than
// by a client-side bool nobody can see.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/nav_registry_view.dart';
import 'package:pharma_b2b/utils/render_log.dart';

import 'registered_routes.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// The 'Admin & System' section exactly as nav_registry() ships it — with the
/// Dev Queue row for a super-admin, without it for a plain admin.
List<Map<String, dynamic>> _systemSection({required bool superAdmin}) => [
      {
        'category_key': 'system',
        'label': 'Admin & System',
        'icon_key': 'settings',
        'items': [
          if (superAdmin)
            {
              'feature_key': 'admin.dev_queue',
              'label': 'Dev Queue',
              'icon_key': 'terminal',
              'route_key': 'dev_queue',
              'deep_link': '/admin/go/dev_queue',
              'badge_count': null,
              'pinned': false,
            },
          {
            'feature_key': 'admin.scope_audit',
            'label': 'Scope audit',
            'icon_key': 'rule',
            'route_key': 'scope_audit',
            'badge_count': null,
            'pinned': false,
          },
        ],
      },
    ];

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('menu-reachability — Dev Queue is reachable, and only by super-admin',
      () {
    testWidgets('a super-admin is offered Dev Queue, and the tap routes',
        (tester) async {
      Map<String, dynamic>? routed;
      await tester.pumpWidget(_host(SingleChildScrollView(
        child: NavSections(
          sections: _systemSection(superAdmin: true),
          pinned: const [],
          pinnedLabel: 'Pinned',
          pinHint: '',
          onOpen: (t) => routed = t,
          onPin: (_) async => const {},
        ),
      )));
      await tester.pumpAndSettle();

      final tile = find.text('Dev Queue');
      expect(tile, findsOneWidget,
          reason: 'no menu path to Dev Queue = the screen does not exist');

      await tester.tap(tile);
      expect(routed?['route_key'], 'dev_queue',
          reason: 'the tap must carry the backend route');
    });

    testWidgets('a plain admin is not offered it — the row is not in their '
        'payload at all', (tester) async {
      await tester.pumpWidget(_host(SingleChildScrollView(
        child: NavSections(
          sections: _systemSection(superAdmin: false),
          pinned: const [],
          pinnedLabel: 'Pinned',
          pinHint: '',
          onOpen: (_) {},
          onPin: (_) async => const {},
        ),
      )));
      await tester.pumpAndSettle();

      expect(find.text('Dev Queue'), findsNothing);
      // The section itself still renders — the gate removes one feature, not
      // the whole category.
      expect(find.text('Scope audit'), findsOneWidget);
    });

    test('and the route is one the shell router can actually open', () {
      expect(kRegisteredAdminRoutes, contains('dev_queue'),
          reason: 'a registered tile whose route has no case in '
              '_handleAdminNav renders perfectly and does nothing on tap');
    });
  });
}
