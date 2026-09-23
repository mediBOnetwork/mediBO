// PROTECTED — CMD #2147, Header v2 + floating dock.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes this behaviour, never to make an unrelated change pass.
//
// What this holds down:
//   1. The order-hours pill is order_hours_state().pill printed verbatim: the
//      label, the tone's colours, a pulsing ring only when pulse:true, nothing
//      at all without a label, and a tap opens the backend's sheet.
//   2. The floating dock draws customer_nav()'s rows in payload order with
//      their own handles, the active tab wears its name, the Orders count sits
//      on the icon (inactive) or inside the pill (active), and a tap hands
//      back the row's own page.
//   3. At 320 px every inactive tab keeps a 44 px touch target.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/floating_dock.dart';
import 'package:pharma_b2b/widgets/order_hours_pill.dart';

// CMD #2191 (Om): the pill prints `lines[]` and nothing else, out of a
// COMPLETE `style` — a payload carrying only `label` is the stale shape that
// now draws nothing, so the fixture is what header_status_pill() really sends.
const _pill = <String, dynamic>{
  'state': 'last_hour',
  'lines': [
    {'kind': 'status', 'text': 'Closes in 40 min'},
  ],
  'label': 'Closes in 40 min',
  'tone': {'bg': '#FEF3C7', 'fg': '#92400E', 'dot': '#D97706'},
  'style': {
    'bg': '#FEF3C7',
    'fg': '#92400E',
    'dot': '#D97706',
    'height': 32,
    'radius': 16,
    'text': 14,
    'pad_x': 12,
    'dot_size': 8,
    'dot_gap': 6,
    'min_w': 120,
    'max_w': 270,
  },
  'pulse': true,
  'pulse_ms': 1600,
  'refresh_s': 30,
};
const _sheet = <String, dynamic>{
  'title': 'Hours title from backend',
  'hours': '6 am – 12 pm',
  'note': 'A note from backend',
};

Widget _app(Widget child, {double width = 390}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: Size(width, 800)),
        child: Scaffold(body: Center(child: child)),
      ),
    );

List<DockTab> _tabs({String orders = '2', String letter = 'C'}) => [
      const DockTab(key: 'home', label: 'Home',
          icon: Icons.home_outlined, activeIcon: Icons.home),
      const DockTab(key: 'catalogue', label: 'Catalogue',
          icon: Icons.grid_view_outlined, activeIcon: Icons.grid_view),
      const DockTab(key: 'bulk', label: 'Bulk',
          icon: Icons.upload_file_outlined, activeIcon: Icons.upload_file),
      DockTab(key: 'orders', label: 'Orders',
          icon: Icons.receipt_long_outlined, activeIcon: Icons.receipt_long,
          badge: orders),
      DockTab(key: 'profile', label: 'Profile',
          icon: Icons.person_outline, activeIcon: Icons.person,
          avatarLetter: letter),
    ];

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('1. the pill is the payload', () {
    testWidgets('label verbatim, tone colours, ring while pulsing', (t) async {
      await t.pumpWidget(_app(const OrderHoursPill(pill: _pill, sheet: _sheet)));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Closes in 40 min'), findsOneWidget);
      final text = t.widget<Text>(find.text('Closes in 40 min'));
      expect(text.style?.color, const Color(0xFF92400E));
      // Two dots: the solid one and the growing ring.
      final dot = find.descendant(
          of: find.byType(LiveDot), matching: find.byType(Container));
      expect(dot, findsNWidgets(2));
    });

    testWidgets('pulse:false is a still dot — no ring', (t) async {
      final still = Map<String, dynamic>.from(_pill)..['pulse'] = false;
      await t.pumpWidget(_app(OrderHoursPill(pill: still, sheet: _sheet)));
      final dot = find.descendant(
          of: find.byType(LiveDot), matching: find.byType(Container));
      expect(dot, findsOneWidget);
    });

    testWidgets('no label, no pill', (t) async {
      await t.pumpWidget(_app(const OrderHoursPill(pill: {}, sheet: _sheet)));
      expect(find.byType(LiveDot), findsNothing);
    });

    testWidgets('a tap opens the backend sheet, verbatim', (t) async {
      await t.pumpWidget(_app(const OrderHoursPill(pill: _pill, sheet: _sheet)));
      await t.tap(find.text('Closes in 40 min'));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('Hours title from backend'), findsOneWidget);
      expect(find.text('6 am – 12 pm'), findsOneWidget);
      expect(find.text('A note from backend'), findsOneWidget);
    });
  });

  group('2. the dock is customer_nav', () {
    testWidgets('rows in payload order, active name shown, tap → position',
        (t) async {
      final taps = <int>[];
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(), activeIndex: 0, onTap: taps.add)));
      await t.pumpAndSettle();
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Catalogue'), findsNothing,
          reason: 'inactive tabs are icons only');
      final xs = [
        for (final k in ['home', 'catalogue', 'bulk', 'orders', 'profile'])
          t.getCenter(find.bySemanticsIdentifier('nav_slot_$k')).dx
      ];
      expect(xs, orderedEquals([...xs]..sort()),
          reason: 'the dock draws the rows in payload order');
      await t.tap(find.bySemanticsIdentifier('nav_slot_orders'));
      expect(taps, [3], reason: 'the dock hands back the tapped position');
    });

    testWidgets('Orders count: on the icon inactive, inside the pill active',
        (t) async {
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(), activeIndex: 0, onTap: (_) {})));
      await t.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      expect(find.text('Orders'), findsNothing);
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(), activeIndex: 3, onTap: (_) {})));
      await t.pumpAndSettle();
      expect(find.text('Orders'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('no count, no badge', (t) async {
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(orders: ''), activeIndex: 0, onTap: (_) {})));
      await t.pumpAndSettle();
      expect(find.text('2'), findsNothing);
    });

    // CMD #2156 (Om) — the bar row and the nav row are the SAME height, the
    // bar button is the 44 touch minimum and the active pill is 48.
    // CMD #2175 — that height is the shell's ONE height (56), the float is the
    // shell's inset and the corner is the shell's radius, so the dock cannot
    // drift away from the header row and the search bar it sits under.
    testWidgets('the card floats on the shell inset; both rows are the shell height',
        (t) async {
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(), activeIndex: 0, onTap: (_) {})));
      await t.pumpAndSettle();
      expect(FloatingDock.dockHeight, Ds.shell.height);
      expect(FloatingDock.dockHeight, 56);
      expect(FloatingDock.edge, Ds.shell.inset);
      expect(FloatingDock.edge, 14);
      expect(FloatingDock.radius, Ds.shell.radius);
      expect(FloatingDock.radius, 28);
      expect(FloatingDock.barHeight, FloatingDock.dockHeight);
      expect(FloatingDock.barButtonHeight, 44);
      expect(FloatingDock.pillHeight, 48);
    });

    testWidgets('the login ask joins the card as its top row, verbatim',
        (t) async {
      var tapped = 0;
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(),
          activeIndex: 0,
          onTap: (_) {},
          bar: DockBarRow(
              // CMD #2172 — the row's ground and its round icon are the
              // payload's, so the test hands it a payload rather than an icon.
              style: BarStyle.from(const {
                'style': {
                  'bg': '#FFFFFF',
                  'icon_url': '',
                  'icon_key': 'person',
                  'icon_bg': '#F3FAF5',
                  'icon_fg': '#1B7A43',
                }
              }),
              label: 'Backend login line',
              action: 'Backend CTA',
              actionIdentifier: 'c2114_login_bar_action',
              onAction: () => tapped++))));
      await t.pumpAndSettle();
      expect(find.text('Backend login line'), findsOneWidget);
      final bar = t.getRect(find.byType(DockBarRow));
      final home = t.getRect(find.bySemanticsIdentifier('nav_slot_home'));
      expect(bar.bottom, lessThanOrEqualTo(home.top + 0.5),
          reason: 'bar row on top, dock row below');
      expect(bar.height, Ds.shell.height);
      await t.tap(find.text('Backend CTA'));
      expect(tapped, 1);
    });
  });

  group('3. touch targets at 320 px', () {
    test('every inactive tab keeps 44 px, the active one is widest', () {
      for (final active in [0, 1, 4]) {
        final g = DockGeometry.compute(
          width: 320 - 24 - Ds.space.x16,
          tabs: _tabs(),
          active: active,
          labelWidth: (s) => s.length * 9.0,
        );
        for (var i = 0; i < g.widths.length; i++) {
          expect(g.widths[i], greaterThanOrEqualTo(44 - 0.01));
        }
        expect(g.widths.reduce((a, b) => a + b),
            closeTo(320 - 24 - Ds.space.x16, 0.01));
        expect(g.widths[active], g.widths.reduce((a, b) => a > b ? a : b));
      }
    });
  });
}
