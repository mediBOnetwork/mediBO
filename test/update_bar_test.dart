// CHANGE #286 — the slim, Plazza-style update bar.
//
// What this pins down, in the order Om's complaint listed it:
//   • it is ONE line — the "A newer version is loading…" sub-line is gone;
//   • it is pinned to the BOTTOM, not the top, and it reflows nothing;
//   • every string is backend copy (ui_copy), printed verbatim;
//   • tapping runs the update action once, then the pill swaps to the updating
//     label and stops accepting taps;
//   • the chip and the pill both clear the 44×44 touch minimum.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/update_bar.dart';

const _copy = <String, String>{
  'update_bar.title': 'New update available',
  'update_bar.action': 'Update',
  'update_bar.updating': 'Updating…',
};

Widget _host(UpdateBarController ctrl) => MaterialApp(
      home: Scaffold(
        body: UpdateBarHost(
          controller: ctrl,
          child: const Center(child: Text('page content')),
        ),
      ),
    );

void main() {
  setUpAll(() {
    RenderLog.flushEnabled = false;
    UiCopy.debugSet(_copy);
  });

  testWidgets('hidden until shown — the page is untouched', (t) async {
    final ctrl = UpdateBarController();
    await t.pumpWidget(_host(ctrl));

    expect(find.text('page content'), findsOneWidget);
    expect(find.byType(UpdateBar), findsNothing);
    expect(find.text('New update available'), findsNothing);
  });

  testWidgets('shown: one backend line, one backend pill, no sub-line',
      (t) async {
    final ctrl = UpdateBarController();
    await t.pumpWidget(_host(ctrl));

    ctrl.show(onUpdate: () {});
    await t.pumpAndSettle();

    // The copy is the backend's, verbatim.
    expect(find.text('New update available'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);

    // The old top card's sub-line is gone for good.
    expect(find.textContaining('newer version is loading'), findsNothing);

    // Exactly two Text widgets inside the bar: the line and the pill label.
    final texts = find.descendant(
        of: find.byType(UpdateBar), matching: find.byType(Text));
    expect(texts, findsNWidgets(2));

    // One line, never wrapped into a paragraph.
    final line = t.widget<Text>(find.text('New update available'));
    expect(line.maxLines, 1);
  });

  testWidgets('pinned to the BOTTOM and reflows nothing', (t) async {
    final ctrl = UpdateBarController();
    await t.pumpWidget(_host(ctrl));
    final before = t.getCenter(find.text('page content'));

    ctrl.show(onUpdate: () {});
    await t.pumpAndSettle();

    // The page did not move: this is an overlay, not a banner that pushes the
    // logo and the search bar down the screen.
    expect(t.getCenter(find.text('page content')), before);

    // And the bar sits in the lower half of the screen.
    final screen = t.getSize(find.byType(MaterialApp));
    expect(t.getCenter(find.byType(UpdateBar)).dy,
        greaterThan(screen.height / 2));
  });

  testWidgets('tap runs the action once, then the pill locks with the '
      'updating label', (t) async {
    final ctrl = UpdateBarController();
    var taps = 0;
    await t.pumpWidget(_host(ctrl));

    ctrl.show(onUpdate: () {
      taps++;
      ctrl.markUpdating();
    });
    await t.pumpAndSettle();

    await t.tap(find.text('Update'));
    await t.pumpAndSettle();

    expect(taps, 1);
    expect(find.text('Updating…'), findsOneWidget);
    expect(find.text('Update'), findsNothing);

    // Disabled: a second tap changes nothing.
    await t.tap(find.text('Updating…'));
    await t.pumpAndSettle();
    expect(taps, 1);

    final button =
        t.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('chip and pill both clear the 44x44 touch minimum', (t) async {
    final ctrl = UpdateBarController();
    await t.pumpWidget(_host(ctrl));
    ctrl.show(onUpdate: () {});
    await t.pumpAndSettle();

    final min = Ds.touch.minTarget;

    final chipBox = t.getSize(find.ancestor(
        of: find.byType(Icon), matching: find.byType(Container)));
    expect(chipBox.width, greaterThanOrEqualTo(min));
    expect(chipBox.height, greaterThanOrEqualTo(min));

    final pill = t.getSize(find.byType(FilledButton));
    expect(pill.height, greaterThanOrEqualTo(min));
    expect(pill.width, greaterThanOrEqualTo(min));
  });

  // MOBILE FIRST (Om, #282): 99% of pharmacies open mediBO on a phone, so the
  // bar is judged at 360 px, not on a desktop. Before this, the chrome (44 px
  // chip + two x12 gaps + an x16-padded pill) ate so much of the row that the
  // sentence got a stub of the width and rendered as "App u…". The rule the bar
  // must keep is: the CHROME gives way before the sentence does. Measured as a
  // share of the bar, because the test font is fixed-width Ahem and its glyph
  // widths say nothing about the real one.
  for (final width in <double>[360, 390, 414]) {
    testWidgets('phone $width px: the line gets the row, not the chrome',
        (t) async {
      t.view.physicalSize = Size(width, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final ctrl = UpdateBarController();
      await t.pumpWidget(_host(ctrl));
      ctrl.show(onUpdate: () {});
      await t.pumpAndSettle();

      final bar = t.getSize(find.byType(UpdateBar)).width;
      final line = t.getSize(find.text('New update available')).width;
      expect(line, greaterThan(bar * 0.4),
          reason: 'the title slot collapsed — chrome is eating the sentence');

      // And the bar still fits the phone exactly: no horizontal overflow.
      expect(bar, width);
      expect(tester_hasNoOverflow(t), isTrue);
    });
  }

  testWidgets('a missing copy key renders empty, never a Dart fallback',
      (t) async {
    UiCopy.debugSet(const {});
    final ctrl = UpdateBarController();
    await t.pumpWidget(_host(ctrl));
    ctrl.show(onUpdate: () {});
    await t.pumpAndSettle();

    expect(find.text('New update available'), findsNothing);
    expect(find.text('Update'), findsNothing);
    // No hardcoded English leaked in as a stand-in.
    final texts = find
        .descendant(of: find.byType(UpdateBar), matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .toList();
    expect(texts, everyElement(''));

    UiCopy.debugSet(_copy);
  });
}

/// True when no RenderFlex overflow was reported while laying the bar out.
/// `takeException` would swallow a real failure, so this only reads the flag.
bool tester_hasNoOverflow(WidgetTester t) => t.takeException() == null;
