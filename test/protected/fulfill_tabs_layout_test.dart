// PROTECTED — CHANGE #1890.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes one of these behaviours, never to make an unrelated
// change go green.
//
// Three Om reports on the Fulfill tabs, and all three are layout that decided
// something it had no business deciding.
//
//   1. SEND-ALL READINESS wrapped ONE LETTER PER LINE (screenshot 08 Sep
//      01:31). #754 had put the label in a Row's only `Expanded` and then
//      dropped the AutoFlow / Bundle chips into the same Row; once the chips
//      were wide enough the Expanded was handed a few pixels and the Text did
//      as it was told. A Row starves its flexible child in SILENCE — no
//      overflow stripe, no exception — which is why it shipped. So the label
//      now owns a full-width row with no flexible sibling, the chips scroll
//      sideways in a strip below it, and the block is a fixed height in both
//      states so the card cannot jump under the finger that tapped it.
//
//   2. The toggles are ONE strip, under the tab bar, on both tabs. Inquiry
//      gets the chips the backend put in `inquiry`, Supplier orders gets the
//      ones in `order`, and a tab the backend sent nothing for draws no strip
//      at all rather than an empty bar. The pill's words are the payload's
//      joined by ui_copy; a tap always asks for the OPPOSITE of what the
//      backend last said; a long press opens the settings sheet.
//
//   3. The Supplier Shop map card is COLLAPSED by default and fixed-size:
//      filters in a two-column grid, a square thumbnail at the payload's mini
//      height. Open, the map is capped at the payload's share of the viewport
//      so the supplier list below stays reachable — the cap only ever makes
//      the map smaller, and it never makes it zero.
//
// No network, no Supabase, no goldens — payloads and copy are injected inline.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/fulfill/readiness_header_block.dart';
import 'package:pharma_b2b/fulfill/supplier_map_panel_view.dart';
import 'package:pharma_b2b/fulfill/supplier_toggle_chips.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ───────────────────────────────────────────────────────────────

const _kLongTitle = 'SEND-ALL READINESS';

Map<String, dynamic> _chipPayload() => {
      'ok': true,
      'inquiry': [
        {
          'key': 'auto_meta',
          'label': 'AutoFlow',
          'on': false,
          'state_label': 'OFF',
          'tone': 'off',
        },
        {
          'key': 'bundle',
          'label': 'Bundle',
          'on': true,
          'state_label': 'ON',
          'tone': 'on',
          'action_label': 'Re-optimise bundles',
        },
      ],
      'order': [
        {
          'key': 'order_auto_meta',
          'label': 'AutoFlow',
          'on': false,
          'state_label': 'OFF',
          'tone': 'off',
        },
      ],
      'toast_on': 'Automatic by Meta: ON',
      'toast_off': 'Automatic by Meta: OFF',
    };

Map<String, dynamic> _mapPayload() => {
      'status': 'ok',
      'header_label': 'View suppliers in map (12)',
      'legend_label': 'Status filters',
      'has_points': true,
      'empty_label': '',
      'map_mini_height': 120,
      'map_full_height': 320,
      'map_full_max_ratio': 0.6,
      'badges': [
        {'key': 'NP', 'filter_key': 'NP', 'text': 'NP·0S'},
        {'key': 'P', 'filter_key': 'P', 'text': 'P·0S'},
        {'key': 'NC', 'filter_key': 'NC', 'text': 'NC·0S'},
        {'key': 'C', 'filter_key': 'C', 'text': 'C·0S'},
        {'key': 'ROUTE', 'filter_key': null, 'text': 'Optimize route', 'is_action': true},
      ],
      'map_points': [
        {'supplier': 'A', 'lat': 21.25, 'lng': 81.62, 'pin_color': '#1B7A43'},
      ],
      'groups': const <Map<String, dynamic>>[],
    };

/// Pumps [child] at a given viewport.
///
/// The default is a desktop width on purpose: `flutter_test` draws every glyph
/// as a full em square, so a 14-character pill measures ~180 px here against
/// ~95 px in a real font. Asserting "both pills are visible" at 390 px would
/// therefore be testing the test font, not the layout. The phone width is used
/// where it is the POINT of the assertion (the label that wrapped, and the
/// strip that must scroll rather than grow a second row).
Future<void> _pumpAt(WidgetTester tester, Widget child,
    {double width = 1024, double height = 780}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: Align(alignment: Alignment.topCenter, child: child)),
  ));
}

void main() {
  setUpAll(() {
    // RenderLog's 800 ms debounce is a real Timer that would outlive the test
    // and try to reach Supabase (CLAUDE.md).
    RenderLog.flushEnabled = false;
    UiCopy.debugSet({
      'admin_supplier.automation_title': 'Automation',
      'admin_supplier.automation_pill': '{label} · {state}',
      'admin_supplier.automation_hint': 'Tap to switch · hold for settings',
      'admin_supplier.settings_auto_meta_title': 'AutoFlow · Supplier inquiry',
      'admin_supplier.settings_auto_meta_body': 'What AutoFlow does.',
      'admin_supplier.settings_bundle_title': 'Bundle',
      'admin_supplier.settings_bundle_body': 'What Bundle does.',
      'admin_supplier.settings_close': 'Close',
    });
  });

  // ── 1. the readiness header ──────────────────────────────────────────────
  group('#1890 — the readiness label never shares a row with a flexible child', () {
    testWidgets('the label is on a row of its own and prints in full', (tester) async {
      await _pumpAt(
        tester,
        ReadinessHeaderBlock(
          title: _kLongTitle,
          statusLabel: 'READY TO SEND',
          statusBg: const Color(0xFFD1FAE5),
          statusFg: const Color(0xFF065F46),
          dateLabel: '08/09/2026',
          onTap: () {},
        ),
        width: 390,
      );

      final title = find.text(_kLongTitle);
      expect(title, findsOneWidget);

      // THE BUG, stated as an assertion: no Flexible/Expanded anywhere above
      // the label. That is what handed it a one-character width.
      expect(
        find.ancestor(of: title, matching: find.byType(Flexible)),
        findsNothing,
        reason: 'a flexible ancestor is exactly how the label got starved',
      );

      // And it is genuinely wide — a starved label measured a few pixels.
      final w = tester.getSize(title).width;
      expect(w, greaterThan(80),
          reason: 'the label got $w px — that is the letter-per-line bug');
    });

    testWidgets('the label does not wrap: one line, clipped, never stacked',
        (tester) async {
      // 200 px is narrower than any phone this app supports, so if anything
      // still wraps, it wraps here.
      await _pumpAt(
        tester,
        SizedBox(
          width: 200,
          child: ReadinessHeaderBlock(
            title: _kLongTitle,
            statusLabel: 'READY TO SEND',
            dateLabel: '08/09/2026',
            onTap: () {},
          ),
        ),
        width: 200,
      );
      final t = tester.widget<Text>(find.text(_kLongTitle));
      expect(t.maxLines, 1);
      expect(t.softWrap, isFalse);
      expect(t.overflow, TextOverflow.ellipsis);
      // One line means the label's height is the row's height, not a multiple
      // of it — the screenshot showed 18 stacked letters.
      expect(tester.getSize(find.text(_kLongTitle)).height,
          lessThanOrEqualTo(ReadinessHeaderBlock.labelHeight));
    });

    testWidgets('the block measures the same with and without chips',
        (tester) async {
      await _pumpAt(
        tester,
        ReadinessHeaderBlock(
          title: _kLongTitle,
          statusLabel: 'READY TO SEND',
          dateLabel: '08/09/2026',
          onTap: () {},
        ),
      );
      final withChips =
          tester.getSize(find.byType(ReadinessHeaderBlock)).height;

      await _pumpAt(
        tester,
        ReadinessHeaderBlock(title: _kLongTitle, onTap: () {}),
      );
      final without = tester.getSize(find.byType(ReadinessHeaderBlock)).height;

      // Open or closed, chips or no chips: one height. The card never jumps.
      expect(withChips, without);
      expect(withChips, ReadinessHeaderBlock.blockHeight);
      expect(ReadinessHeaderBlock.blockHeight,
          ReadinessHeaderBlock.labelHeight + ReadinessHeaderBlock.chipsHeight);
    });

    testWidgets('a payload with no status and no date still draws the strip',
        (tester) async {
      await _pumpAt(tester, ReadinessHeaderBlock(title: _kLongTitle, onTap: () {}));
      expect(find.text(_kLongTitle), findsOneWidget);
      expect(tester.getSize(find.byType(ReadinessHeaderBlock)).height,
          ReadinessHeaderBlock.blockHeight);
    });

    testWidgets('tapping anywhere on the block toggles the card', (tester) async {
      var taps = 0;
      await _pumpAt(
        tester,
        ReadinessHeaderBlock(
            title: _kLongTitle, dateLabel: '08/09/2026', onTap: () => taps++),
      );
      await tester.tap(find.text(_kLongTitle));
      expect(taps, 1);
    });
  });

  // ── 2. the Automation strip ──────────────────────────────────────────────
  group('#1890 — ONE Automation strip, and it computes nothing', () {
    final set = SupplierToggleChipSet.fromJson(_chipPayload());

    testWidgets('inquiry gets both toggles, printed label · state', (tester) async {
      await _pumpAt(
        tester,
        SupplierAutomationStrip(chips: set.inquiry, onToggle: (_, __) {}),
      );
      expect(find.text('Automation'), findsOneWidget);
      expect(find.text('AutoFlow · OFF'), findsOneWidget);
      expect(find.text('Bundle · ON'), findsOneWidget);
    });

    testWidgets('supplier orders gets the same strip with AutoFlow only',
        (tester) async {
      await _pumpAt(
        tester,
        SupplierAutomationStrip(chips: set.order, onToggle: (_, __) {}),
      );
      expect(find.text('Automation'), findsOneWidget);
      expect(find.text('AutoFlow · OFF'), findsOneWidget);
      expect(find.textContaining('Bundle'), findsNothing);
    });

    testWidgets('a tab with no toggles draws no strip at all', (tester) async {
      await _pumpAt(
        tester,
        SupplierAutomationStrip(chips: const [], onToggle: (_, __) {}),
      );
      // Not an empty bar — nothing. An empty bar under the tab bar is the row
      // #754 deleted and this change must not bring back.
      expect(find.text('Automation'), findsNothing);
      expect(tester.getSize(find.byType(SupplierAutomationStrip)).height, 0);
    });

    testWidgets('a tap asks for the opposite of what the BACKEND last said',
        (tester) async {
      final asked = <String>[];
      await _pumpAt(
        tester,
        SupplierAutomationStrip(
          chips: set.inquiry,
          onToggle: (c, next) => asked.add('${c.key}=$next'),
        ),
      );
      await tester.tap(find.text('AutoFlow · OFF'));
      await tester.tap(find.text('Bundle · ON'));
      expect(asked, ['auto_meta=true', 'bundle=false']);
    });

    testWidgets('a long press opens settings instead of toggling',
        (tester) async {
      final toggled = <String>[];
      final settings = <String>[];
      await _pumpAt(
        tester,
        SupplierAutomationStrip(
          chips: set.inquiry,
          onToggle: (c, _) => toggled.add(c.key),
          onSettings: (c) => settings.add(c.key),
        ),
      );
      await tester.longPress(find.text('Bundle · ON'));
      expect(settings, ['bundle']);
      expect(toggled, isEmpty, reason: 'a long press must not switch it too');
    });

    testWidgets('a busy chip spins and refuses taps', (tester) async {
      final toggled = <String>[];
      await _pumpAt(
        tester,
        SupplierAutomationStrip(
          chips: set.order,
          busyKeys: const {'order_auto_meta'},
          onToggle: (c, _) => toggled.add(c.key),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('AutoFlow · OFF'), findsNothing);
      await tester.tap(find.byType(CircularProgressIndicator));
      expect(toggled, isEmpty);
    });

    testWidgets('the strip stays one line — it never grows a second row',
        (tester) async {
      // Six toggles at 390 px is far more than fits; they must scroll, not wrap.
      final many = SupplierToggleChip.listFrom([
        for (var i = 0; i < 6; i++)
          {
            'key': 'k$i',
            'label': 'Toggle number $i',
            'on': false,
            'state_label': 'OFF',
            'tone': 'off',
          }
      ]);
      await _pumpAt(
        tester,
        SupplierAutomationStrip(chips: many, onToggle: (_, __) {}),
        width: 390,
      );
      expect(tester.getSize(find.byType(SupplierAutomationStrip)).height,
          SupplierAutomationStrip.height);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every pill is a real 44 px tap target', (tester) async {
      await _pumpAt(
        tester,
        SupplierAutomationStrip(chips: set.inquiry, onToggle: (_, __) {}),
      );
      for (final label in ['AutoFlow · OFF', 'Bundle · ON']) {
        final box = find.ancestor(
            of: find.text(label), matching: find.byType(InkWell));
        expect(tester.getSize(box.first).height, greaterThanOrEqualTo(44));
      }
    });

    testWidgets('the settings sheet is addressed by the chip\'s own key',
        (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        })),
      ));
      showAutomationSettingsSheet(ctx, set.inquiry[1], onToggle: (_, __) {});
      await tester.pumpAndSettle();
      // 'settings_bundle_title' / '_body' — no Dart branch chose these.
      expect(find.text('Bundle'), findsOneWidget);
      expect(find.text('What Bundle does.'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });
  });

  // ── 3. the Supplier Shop map card ────────────────────────────────────────
  group('#1890 — the map card is collapsed, fixed, and capped', () {
    final v = SupplierMapPanelView.fromJson(_mapPayload());

    test('the collapsed thumbnail is the payload\'s mini height, squared', () {
      expect(v.thumbSize, 120);
      expect(v.collapsedBodyHeight, 120);
      expect(v.thumbSize, greaterThan(0),
          reason: 'zero is how the map widget gets disposed');
    });

    test('the filters are TWO columns — never "as many as fit"', () {
      expect(SupplierMapPanelView.collapsedFilterColumns, 2);
      // The five the backend sends, in payload order, text verbatim.
      expect(v.badges.map((b) => b['text']).toList(),
          ['NP·0S', 'P·0S', 'NC·0S', 'C·0S', 'Optimize route']);
      expect(v.badges.last['is_action'], isTrue);
    });

    test('the open map is capped at the payload share of the viewport', () {
      expect(v.fullMaxRatio, 0.6);
      // A short phone: 0.6 * 500 = 300 < the payload's 320, so it is capped.
      expect(v.expandedHeight(500), 300);
      // A tall desktop: the cap is above the payload height, which wins.
      expect(v.expandedHeight(1200), 320);
      // The cap only ever makes the map SMALLER.
      expect(v.expandedHeight(500), lessThanOrEqualTo(v.mapHeight(open: true)));
    });

    test('a payload with no ratio still caps, at the documented 0.6', () {
      final noRatio = SupplierMapPanelView.fromJson({
        'header_label': 'View suppliers in map (1)',
        'map_mini_height': 120,
        'map_full_height': 320,
      });
      expect(noRatio.fullMaxRatio, 0);
      expect(noRatio.expandedHeight(500), 300);
    });

    test('a caller with no viewport to measure gets the payload height', () {
      // A unit test, or the very first frame: the cap needs a viewport and
      // must not invent one.
      expect(v.expandedHeight(0), 320);
      expect(v.expandedHeight(-1), 320);
    });

    test('#754 still holds: two sizes, both the payload\'s, neither zero', () {
      expect(v.mapHeight(open: false), 120);
      expect(v.mapHeight(open: true), 320);
      expect(v.mapIsMounted, isTrue);
      expect(SupplierMapPanelView.empty.thumbSize, 0);
    });
  });
}
