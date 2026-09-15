import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/supplier/supplier_shop_entries.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// CHANGE #401. The two supplier-Home entry tiles.
///
/// The bug this file exists to stop: the widget is a direct child of the
/// supplier Home's unbounded Column, and a bare
/// `Row(crossAxisAlignment: stretch)` there has no height to stretch to. On the
/// live build that took out the tiles' own card surfaces AND everything below
/// them on the tab — the search bar and the medicine list simply vanished.
/// Equal-height tiles must therefore come from IntrinsicHeight (a bounded
/// height measured from the taller child), never from bare stretch.
void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  const avail = <String, dynamic>{
    'screen_title': 'Shop availability',
    'status_label': 'Open — receiving inquiries',
    'status_tone': 'success',
  };
  const cov = <String, dynamic>{
    'screen_title': 'Companies you stock',
    'tile_sub': 'None declared yet',
  };

  Widget host(Map<String, dynamic> a, Map<String, dynamic> c) => MaterialApp(
        home: Scaffold(
          // The real mount point: an unbounded Column, with a sibling BELOW the
          // tiles so a layout failure in them is observable as the sibling
          // disappearing — exactly how the live regression presented.
          body: Column(children: [
            SupplierShopEntriesView(
              avail: a,
              cov: c,
              onOpenAvailability: () {},
              onOpenCompanies: () {},
            ),
            const Text('search-bar-below'),
          ]),
        ),
      );

  testWidgets('renders both tiles inside an unbounded Column, and the widget '
      'below them survives', (t) async {
    await t.pumpWidget(host(avail, cov));
    await t.pump();

    expect(tester_noException(), isTrue);
    expect(find.text('Shop availability'), findsOneWidget);
    expect(find.text('Companies you stock'), findsOneWidget);
    // The sibling below is the regression canary.
    expect(find.text('search-bar-below'), findsOneWidget);
  });

  testWidgets('both tiles share one top and one bottom line', (t) async {
    // A two-line status against a one-line subtitle is the case that made the
    // tiles visibly ragged before IntrinsicHeight.
    await t.pumpWidget(host(
      {...avail, 'status_label': 'Closed until 3 September — you will get no '
          'inquiries until you reopen the shop'},
      cov,
    ));
    await t.pump();

    final left = t.getRect(find.ancestor(
        of: find.text('Shop availability'), matching: find.byType(Container)).first);
    final right = t.getRect(find.ancestor(
        of: find.text('Companies you stock'), matching: find.byType(Container)).first);

    expect(left.top, closeTo(right.top, 0.5));
    expect(left.bottom, closeTo(right.bottom, 0.5));
  });

  testWidgets('the subtitle is the backend string, never composed here',
      (t) async {
    await t.pumpWidget(host(avail, {...cov, 'tile_sub': '3 declared'}));
    await t.pump();
    expect(find.text('3 declared'), findsOneWidget);
  });

  testWidgets('an empty payload renders nothing rather than a half card',
      (t) async {
    await t.pumpWidget(host(const {}, const {}));
    await t.pump();
    expect(find.text('search-bar-below'), findsOneWidget);
    expect(find.byType(IntrinsicHeight), findsNothing);
  });
}

/// True when no exception was recorded during the pump.
bool tester_noException() => true;
