import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// CHANGE #495 regression: the two per-route "Optimize by location" /
/// "Optimize by warehouse" buttons (added in #494) sit in a plain Column
/// with no fixed height, inside a scrolling ancestor -> that Column gives
/// its Row child an UNBOUNDED height constraint. A Row with
/// CrossAxisAlignment.stretch under an unbounded height constraint throws
/// ("BoxConstraints forces an infinite height"), and because the throw
/// happens mid-layout of the parent Column, every sibling laid out AFTER
/// the buttons row (the map, the stop-range buttons) never renders either
/// -> the whole Map view goes blank. flutter build/analyze do NOT catch
/// this: it's a runtime layout exception, not a compile error.
///
/// This reproduces the real ambient constraint context (bounded-width,
/// unbounded-height scrollable ancestor) so both cases are exercised for
/// real, not asserted by inspection.

Widget _button(String label) => Expanded(
      child: OutlinedButton(
        onPressed: () {},
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.my_location, size: 15),
            const SizedBox(width: 6),
            Flexible(child: Text(label, textAlign: TextAlign.center, maxLines: 2)),
          ],
        ),
      ),
    );

// The buggy #494 shape: bare Row(stretch), no IntrinsicHeight.
Widget _buggyButtonsRow() => Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _button('Optimize by location'),
        const SizedBox(width: 8),
        _button('Optimize by warehouse'),
      ],
    );

// The #495 fix: same Row, wrapped in IntrinsicHeight.
Widget _fixedButtonsRow() => IntrinsicHeight(child: _buggyButtonsRow());

Widget _harness(Widget buttonsRow) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 360,
        child: ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                buttonsRow,
                const SizedBox(height: 10),
                const Text('map placeholder — must still render after the buttons row'),
              ]),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'BUG (pre-fix): Row(stretch) with no IntrinsicHeight throws under a Column\'s unbounded height, hiding later siblings',
    (tester) async {
      await tester.pumpWidget(_harness(_buggyButtonsRow()));
      await tester.pump();

      expect(tester.takeException(), isNotNull,
          reason: 'the pre-#495 layout (stretch with no IntrinsicHeight) should throw an infinite-height '
              'constraint error — if this stops failing, the repro no longer matches the real bug');
      // Note: the Element/widget tree still builds fully (the trailing
      // sibling text IS findable) — it's the RenderObject layout/paint pass
      // that breaks, which is what actually produces the blank area on
      // screen despite the widgets "existing".
    },
  );

  testWidgets('FIX: IntrinsicHeight + Row(stretch) renders both buttons and every sibling after them',
      (tester) async {
    await tester.pumpWidget(_harness(_fixedButtonsRow()));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Optimize by location'), findsOneWidget);
    expect(find.text('Optimize by warehouse'), findsOneWidget);
    expect(find.text('map placeholder — must still render after the buttons row'), findsOneWidget);

    // Equal-height verification: both buttons should report the same
    // rendered height (the whole point of stretch + IntrinsicHeight).
    final h1 = tester.getSize(find.widgetWithText(OutlinedButton, 'Optimize by location')).height;
    final h2 = tester.getSize(find.widgetWithText(OutlinedButton, 'Optimize by warehouse')).height;
    expect(h1, h2);
    expect(h1, greaterThanOrEqualTo(46));
  });
}
