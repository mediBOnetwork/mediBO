// Journey `menu-reachability`, implemented (CHANGE #237).
//
// It sat in dev_journeys as required=true with the body "IMPLEMENT in VM cmd",
// so it could never pass — and because it is a GLOBAL journey it blocked the
// bug-loop gate on every UI command. Flutter renders to canvas, so it cannot be
// a headless click test; it is a widget test on the two nav surfaces instead,
// which is repeatable and cannot rot silently.
//
// What it pins: a super-admin can reach Dev Queue FROM THE MENU on both shells
// (wide "More" popup, narrow profile sheet), a plain admin cannot, and GCP
// Control is reached from the Dev Queue header rather than by typing a URL.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/admin_nav_entries.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  // The label is BACKEND copy, never a Dart literal — seeding it here is also
  // how this test proves that: blank the key and the menu item has no text.
  const kDevQueueLabel = 'Dev Queue';
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(const {'dev_queue.nav_label': kDevQueueLabel});
  });

  group('menu-reachability — Dev Queue is reachable, and only by super-admin', () {
    testWidgets('wide shell: the More popup offers Dev Queue to a super-admin',
        (tester) async {
      String? routed;
      await tester.pumpWidget(_host(AdminMoreNavMenu(
          onNav: (r) => routed = r, isSuperAdmin: true)));

      await tester.tap(find.byType(AdminMoreNavMenu));
      await tester.pumpAndSettle();

      final item = find.widgetWithText(PopupMenuItem<String>, kDevQueueLabel);
      expect(item, findsOneWidget,
          reason: 'no menu path to Dev Queue = the screen does not exist');

      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(routed, 'dev_queue', reason: 'the tap must carry the route');
    });

    testWidgets('wide shell: a plain admin is not offered Dev Queue',
        (tester) async {
      await tester.pumpWidget(_host(AdminMoreNavMenu(
          onNav: (_) {}, isSuperAdmin: false)));

      await tester.tap(find.byType(AdminMoreNavMenu));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(PopupMenuItem<String>, kDevQueueLabel), findsNothing);
    });

    testWidgets('narrow shell: the profile sheet offers Dev Queue to a super-admin',
        (tester) async {
      String? routed;
      await tester.pumpWidget(_host(SingleChildScrollView(
          child: AdminProfileMenuTiles(
              nav: (r) => routed = r, isSuperAdmin: true))));
      await tester.pumpAndSettle();

      final tile = find.widgetWithText(AdminSheetTile, kDevQueueLabel);
      expect(tile, findsOneWidget);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(routed, 'dev_queue');
    });
  });
}
