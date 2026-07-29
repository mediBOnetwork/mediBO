// CHANGE #609 — the zone picker renders what zone_picker() returned.
//
// Payloads below are fabricated zone_picker() responses, inline — no network.
// Four rules, all decided server-side and none re-derived in Dart:
//
//   a) can_change:true  -> a dropdown listing options[].label, with the
//      selected:true entry marked current
//   b) can_change:false -> static text, NO dropdown and NO tap target
//   c) show:false       -> nothing renders at all
//   d) picking the All-zones entry reports zone_id null — not 0, not ''
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/widgets/zone_picker_view.dart';

/// (a) and (d): a super admin — may change zone, All zones + Raipur Zone.
const _superAdmin = <String, dynamic>{
  'show': true,
  'can_change': true,
  'title': 'Zone',
  'selected_zone_id': 1,
  'selected_label': 'Raipur Zone',
  'options': [
    {'zone_id': null, 'code': 'all', 'label': 'All zones', 'selected': false},
    {'zone_id': 1, 'code': 'rpr', 'label': 'Raipur Zone', 'selected': true},
  ],
  'empty': '',
};

/// (b): an admin — locked to their own zone, no options.
const _lockedAdmin = <String, dynamic>{
  'show': true,
  'can_change': false,
  'title': 'Your zone',
  'selected_zone_id': 1,
  'selected_label': 'Raipur Zone',
  'options': <Map<String, dynamic>>[],
  'empty': '',
};

/// (c): anyone else.
const _hidden = <String, dynamic>{
  'show': false,
  'can_change': false,
  'title': '',
  'selected_zone_id': null,
  'selected_label': '',
  'options': <Map<String, dynamic>>[],
  'empty': '',
};

/// Everything reported by the view. `hasRun` separates "never called" from
/// "called with null" — the distinction the All-zones entry depends on.
bool hasRun = false;
Object? reported = 'UNSET';

Widget _harness(Map<String, dynamic> payload) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: ZonePickerView(
            payload: payload,
            onSelect: (zoneId) async {
              hasRun = true;
              reported = zoneId;
            },
          ),
        ),
      ),
    );

void main() {
  setUp(() {
    hasRun = false;
    reported = 'UNSET';
  });

  testWidgets('a) can_change:true renders a dropdown of options[].label',
      (tester) async {
    await tester.pumpWidget(_harness(_superAdmin));

    // The closed control shows the current selection and a dropdown affordance.
    expect(find.text('Raipur Zone'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_drop_down), findsOneWidget);

    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();

    // Both labels come from options[] — neither is written in Dart.
    expect(find.text('All zones'), findsOneWidget);
    expect(find.text('Raipur Zone'), findsWidgets);

    // "Raipur Zone" is the current one: selected:true carries the check mark.
    expect(find.byIcon(Icons.check), findsOneWidget);
    final checked = tester.widget<Text>(
      find
          .descendant(
            of: find.ancestor(
              of: find.byIcon(Icons.check),
              matching: find.byType(Row),
            ).first,
            matching: find.byType(Text),
          )
          .first,
    );
    expect(checked.data, 'Raipur Zone');
  });

  testWidgets('b) can_change:false renders static text, no tap target',
      (tester) async {
    await tester.pumpWidget(_harness(_lockedAdmin));

    expect(find.text('Raipur Zone'), findsOneWidget);
    expect(find.text('Your zone'), findsOneWidget); // title as the caption

    // No dropdown, no tap target, no arrow.
    expect(find.byType(InkWell), findsNothing);
    expect(find.byIcon(Icons.arrow_drop_down), findsNothing);

    // Nothing to tap means nothing can be reported.
    expect(hasRun, isFalse);
  });

  testWidgets('c) show:false renders nothing at all', (tester) async {
    await tester.pumpWidget(_harness(_hidden));

    expect(find.byType(Text), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(find.byType(Container), findsNothing);
    expect(find.byIcon(Icons.place_outlined), findsNothing);
  });

  testWidgets('d) picking "All zones" reports null — not 0, not empty string',
      (tester) async {
    await tester.pumpWidget(_harness(_superAdmin));

    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All zones'));
    await tester.pumpAndSettle();

    expect(hasRun, isTrue, reason: 'the selection must reach onSelect');
    expect(reported, isNull);
    expect(reported, isNot(0));
    expect(reported, isNot(-1));
    expect(reported, isNot(''));
  });

  testWidgets('picking the already-selected entry writes nothing',
      (tester) async {
    await tester.pumpWidget(_harness(_superAdmin));

    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();
    // Tap the menu's "Raipur Zone" (selected:true), not the closed control.
    await tester.tap(find.text('Raipur Zone').last);
    await tester.pumpAndSettle();

    expect(hasRun, isFalse);
  });

  testWidgets('dismissing the menu reports nothing', (tester) async {
    await tester.pumpWidget(_harness(_superAdmin));

    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();
    // Tap well outside the menu to dismiss it.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(hasRun, isFalse);
  });
}
