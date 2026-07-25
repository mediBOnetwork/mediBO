import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/supplier_map_groups_panel.dart';

/// The panel's map body (GoogleMap) can't be safely pumped in `flutter test`
/// — no precedent for that anywhere in this codebase (the Route tab's own
/// RouteGoogleMapPanel has zero test coverage for the same reason: no
/// platform-view mocking for google_maps_flutter is set up here). This
/// instead verifies the part that's always on-screen above the Supplier
/// Shop list regardless of map support: the collapsed header (closed by
/// default) renders without a layout exception and the fallback header text
/// shows before the RPC (which fails with no Supabase instance in tests,
/// caught by the panel's own try/catch) resolves. Since the map body only
/// builds when `_open && _data != null`, and `_data` never populates without
/// a real Supabase client, tapping the header to toggle it open here never
/// reaches the GoogleMap widget either.
void main() {
  testWidgets('collapsed panel renders without throwing; toggling open stays safe with no data',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SupplierMapGroupsPanel()),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('View suppliers in map'), findsOneWidget);

    await tester.tap(find.text('View suppliers in map'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
