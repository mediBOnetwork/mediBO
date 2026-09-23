// CMD #2172 (Om) — THE BOTTOM BARS: ONE CARD, ONE BAR, AND ONLY THE NAV HIDES.
//
// Om, on the live app: "banner floats loose, nav never hides — #2156 lost it."
// Both halves of that were real, and both were the kind of bug a screenshot of
// a resting screen cannot show, so this file holds the whole shape down:
//
//  1. ONE FLOATING CARD. Banner row on top, nav row below, both 64, the card
//     inset 14 with 28 corners and ONE shadow. No bar → the nav row alone, and
//     the card is still one rounded card.
//  2. THE BANNER IS THE BACKEND'S LOOK, NOT DART'S. Its ground, its round
//     icon's disc, its glyph colour and WHICH glyph all arrive in the bar
//     payload's `style` block. #2147 drew a light-green ground and a Dart
//     `IconData`, so "make the banner white" was a deploy. The only thing that
//     stays a token is the green button — one brand primary per screen is the
//     design contract, not a colour a row picks.
//  3. ONLY THE NAV ROW HIDES. The shell's hiding slot is handed DOWN and wraps
//     the nav row and the hairline above it — never the banner. A scrolled page
//     therefore leaves the banner behind as its own rounded card at the bottom,
//     which is exactly the design, and the card's own height shrinks so the
//     Scaffold hands those pixels to the body and the View cart pill rides
//     down with it (#2066).
//  4. VIEW CART IS SEPARATE AND NEVER HIDES. Its own pill, its own air — 10 px
//     of it — above whatever card is left.
//
// Nothing here mocks the dock's decisions, because the dock has none: every
// string, colour and glyph key in this file is a payload the test wrote.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/widgets/bottom_stack.dart';
import 'package:pharma_b2b/widgets/floating_dock.dart';
import 'package:pharma_b2b/utils/render_log.dart';

List<DockTab> _tabs() => const [
      DockTab(
          key: 'home', label: 'Home', icon: Icons.home_outlined, activeIcon: Icons.home),
      DockTab(
          key: 'catalogue',
          label: 'Catalogue',
          icon: Icons.grid_view_outlined,
          activeIcon: Icons.grid_view),
      DockTab(
          key: 'orders',
          label: 'Orders',
          icon: Icons.receipt_long_outlined,
          activeIcon: Icons.receipt_long),
    ];

/// A bar payload, exactly as `customer_registration_bar().style` sends it.
Map<String, dynamic> _payload({
  String bg = '#FFFFFF',
  String iconBg = '#F3FAF5',
  String iconFg = '#1B7A43',
  String iconKey = 'person',
  String iconUrl = '',
}) =>
    {
      'style': {
        'bg': bg,
        'icon_url': iconUrl,
        'icon_key': iconKey,
        'icon_bg': iconBg,
        'icon_fg': iconFg,
      }
    };

Widget _row(Map<String, dynamic> payload, {VoidCallback? onAction}) => DockBarRow(
      style: BarStyle.from(payload),
      label: 'Backend banner line',
      action: 'Backend CTA',
      onAction: onAction ?? () {},
    );

/// The dock on a 360 px phone, bottom-aligned the way a Scaffold mounts it.
Widget _app(Widget dock, {double width = 360}) => MediaQuery(
      data: MediaQueryData(size: Size(width, 780), devicePixelRatio: 1),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Material(
          child: Align(alignment: Alignment.bottomCenter, child: dock),
        ),
      ),
    );

/// The nav row "fully hidden": the shell's slot shortens it to nothing. The
/// real slot is `_NavSlot` (a render object driven by `shellNavHide`); what
/// this file holds down is that the dock puts the slot around the NAV ROW and
/// around nothing else.
Widget _hidden(Widget _) => const SizedBox(width: double.infinity, height: 0);

String _code(String path) => File(path)
    .readAsLinesSync()
    .where((String l) => !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
    .join('\n');

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  group('1 · one floating card', () {
    testWidgets('banner row on top, nav row below, both 64, one card',
        (t) async {
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(), activeIndex: 0, onTap: (_) {}, bar: _row(_payload()))));
      await t.pumpAndSettle();

      final bar = t.getRect(find.byType(DockBarRow));
      final nav = t.getRect(find.bySemanticsIdentifier('nav_slot_home'));
      expect(bar.height, FloatingDock.barHeight);
      expect(FloatingDock.barHeight, FloatingDock.dockHeight,
          reason: 'the two rows of one card must be the same 64');
      expect(bar.bottom, lessThanOrEqualTo(nav.top + 0.5),
          reason: 'the banner is not above the nav — it floated loose again');
      expect(FloatingDock.edge, 14);
      expect(FloatingDock.radius, 28);
      expect(FloatingDock.cardShadow.length, 1,
          reason: 'one shadow for the whole card, not one per row');
    });

    testWidgets('no bar → the nav row alone, still one rounded card',
        (t) async {
      await t.pumpWidget(
          _app(FloatingDock(tabs: _tabs(), activeIndex: 0, onTap: (_) {})));
      await t.pumpAndSettle();
      expect(find.byType(DockBarRow), findsNothing);
      final card = t.getRect(find.byType(ClipRRect).first);
      expect(card.height, closeTo(FloatingDock.dockHeight, 0.5),
          reason: 'an empty banner slot left room behind it');
    });
  });

  group('2 · the banner is the payload, not Dart', () {
    testWidgets('ground, disc and glyph colours all come from style',
        (t) async {
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(),
          activeIndex: 0,
          onTap: (_) {},
          bar: _row(_payload(
              bg: '#FFFFFF', iconBg: '#EEF2FF', iconFg: '#1E40AF')))));
      await t.pumpAndSettle();

      final ground = t.widget<Container>(find
          .descendant(of: find.byType(DockBarRow), matching: find.byType(Container))
          .first);
      expect(ground.color, const Color(0xFFFFFFFF),
          reason: 'the banner ground is not the payload\'s — it is white now');

      final glyph = t.widget<Icon>(find.descendant(
          of: find.byType(DockBarRow), matching: find.byType(Icon)));
      expect(glyph.color, const Color(0xFF1E40AF),
          reason: 'the glyph colour is not the payload\'s');
      expect(glyph.icon, Icons.person_outline,
          reason: 'icon_key is not resolved through the one glyph map');

      final disc = t
          .widgetList<Container>(find.descendant(
              of: find.byType(DockBarRow), matching: find.byType(Container)))
          .firstWhere((c) => c.decoration is BoxDecoration &&
              (c.decoration as BoxDecoration).shape == BoxShape.circle);
      expect((disc.decoration as BoxDecoration).color, const Color(0xFFEEF2FF),
          reason: 'the round icon\'s disc is not the payload\'s');
    });

    testWidgets('an unknown icon_key draws the neutral glyph, never throws',
        (t) async {
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(),
          activeIndex: 0,
          onTap: (_) {},
          bar: _row(_payload(iconKey: 'a_glyph_that_ships_next_month')))));
      await t.pumpAndSettle();
      expect(_noErrorOn(t), isTrue);
      final glyph = t.widget<Icon>(find.descendant(
          of: find.byType(DockBarRow), matching: find.byType(Icon)));
      expect(glyph.icon, Icons.info_outline);
    });

    testWidgets('the words are the payload\'s and the button is the brand',
        (t) async {
      var taps = 0;
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(),
          activeIndex: 0,
          onTap: (_) {},
          bar: _row(_payload(), onAction: () => taps++))));
      await t.pumpAndSettle();
      expect(find.text('Backend banner line'), findsOneWidget);
      expect(find.text('Backend CTA'), findsOneWidget);
      final button = t.widget<FilledButton>(find.byType(FilledButton));
      expect(
          button.style?.backgroundColor?.resolve(const <WidgetState>{}), Ds.c.brand,
          reason: 'the button stays green — one brand primary per screen');
      expect(FloatingDock.barButtonHeight, Ds.touch.minTarget,
          reason: 'the button dropped under the 44 touch minimum');
      await t.tap(find.text('Backend CTA'));
      expect(taps, 1);
    });

    test('no bar colour or ground is written in Dart any more', () {
      final dock = _code('lib/widgets/floating_dock.dart');
      expect(dock, isNot(contains('barGround')),
          reason: 'the hardcoded light-green ground is back');
      expect(dock, contains('color: style.bg'),
          reason: 'the banner ground stopped being the payload\'s');
      expect(dock, contains('color: style.iconBg'),
          reason: 'the round icon\'s disc stopped being the payload\'s');
    });
  });

  group('3 · only the nav row hides', () {
    testWidgets('the banner stays and becomes the bottom card', (t) async {
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(),
          activeIndex: 0,
          onTap: (_) {},
          bar: _row(_payload()),
          navSlot: _hidden)));
      await t.pumpAndSettle();

      expect(find.byType(DockBarRow), findsOneWidget,
          reason: 'the banner went away with the nav — that is #2156\'s bug');
      expect(find.bySemanticsIdentifier('nav_slot_home'), findsNothing,
          reason: 'a hidden nav row is still tappable');
      final card = t.getRect(find.byType(ClipRRect).first);
      final bar = t.getRect(find.byType(DockBarRow));
      expect(card.height, closeTo(FloatingDock.barHeight, 0.5),
          reason: 'the card did not shrink to the banner, so the pixels never '
              'went back to the body and the View cart pill could not ride down');
      expect(bar.bottom, closeTo(card.bottom, 0.5),
          reason: 'the banner did not drop to the bottom of the card');
    });

    testWidgets('with no banner, hiding the nav leaves no card behind',
        (t) async {
      await t.pumpWidget(_app(FloatingDock(
          tabs: _tabs(), activeIndex: 0, onTap: (_) {}, navSlot: _hidden)));
      await t.pumpAndSettle();
      expect(t.getRect(find.byType(ClipRRect).first).height, closeTo(0, 0.5));
    });

    test('the slot wraps the nav row and nothing else', () {
      final dock = _code('lib/widgets/floating_dock.dart');
      expect(dock, contains('slot == null ? row : slot(row)'),
          reason: 'the dock stopped applying the shell\'s hiding slot');
      // The hairline belongs to the nav row: it must travel away with it, or a
      // banner left on its own wears a stray line under it.
      final navRow = dock.split('Widget _navRow(')[1].split('Widget _track(')[0];
      expect(navRow, contains('hairline'),
          reason: 'the hairline is not inside the hiding slot');
    });

    test('the shell reads the backend flag and hands the slot down', () {
      final shell = File('lib/screens/home_shell.dart').readAsStringSync();
      expect(shell, contains('shellHidingNav('),
          reason: 'the nav is not wrapped, so it can never hide');
      expect(shell, contains('navSlot:'),
          reason: 'the slot is not handed down, so it wraps the whole card '
              'again and takes the banner with it');
    });
  });

  group('4 · View cart is separate', () {
    test('its air above the card is 10, and it is a token', () {
      expect(BottomStackMetrics.gap, 10);
      expect(BottomStackMetrics.gap, Ds.touch.cartPillGap,
          reason: 'the gap is a Dart number again');
      final stack = _code('lib/widgets/bottom_stack.dart');
      expect(stack, contains('Ds.touch.cartPillGap'));
    });

    test('the pill slot is above the bar slot, never inside the card', () {
      final stack = _code('lib/widgets/bottom_stack.dart');
      // The pill is its own box in the bottom stack, which the shell mounts
      // ABOVE the dock (`bottom: MediaQuery.paddingOf`), so the dock hiding
      // its nav row moves the pill and never hides it.
      expect(stack, contains('kPillSlotKey'));
      final dock = _code('lib/widgets/floating_dock.dart');
      expect(dock, isNot(contains('CartPill')),
          reason: 'View cart was pulled inside the card, where the nav hiding '
              'would take it with it');
    });
  });

  group('5 · ONE bar at a time, on EVERY customer tab', () {
    // Om's order, from #2114 and unchanged here: Update outranks Login, Login
    // outranks Registration, and nothing ever stacks two banners in the card.
    // The decision is `_joinedBar`'s single early return, so the thing to hold
    // down is that it stays ONE return and stays in that order.
    test('update outranks the ask, and there is only ever one row', () {
      final bars = _code('lib/screens/shell/shell_bottom_bars.dart');
      final joined =
          bars.split('static Widget? _joinedBar(')[1].split('static ')[0];
      expect(joined.indexOf('appUpdateBar.visible'),
          lessThan(joined.indexOf('appRegistrationBar.visible')),
          reason: 'the update bar lost its precedence over the login ask');
      expect('return DockBarRow('.allMatches(joined).length, 2,
          reason: 'the card builds more than the one banner row it may show');
      expect(joined, contains('if (!appRegistrationBar.visible) return null'),
          reason: 'nothing owed no longer collapses the card to the nav alone');
    });

    test('every customer tab, because the shell owns the enable', () {
      final shell = File('lib/screens/home_shell.dart').readAsStringSync();
      // Not a screen name, not a tab index: one flag, read once, for the whole
      // customer shell — which is what makes this true on Orders and Bulk too.
      expect(shell, contains('enabled: !isAdmin && shellNavHideEnabled'),
          reason: 'the hide is decided per screen again');
    });
  });
}

/// Did the last pump throw? `takeException` is the only honest answer, and it
/// has to be consumed or the next test inherits it.
bool _noErrorOn(WidgetTester t) => t.takeException() == null;
