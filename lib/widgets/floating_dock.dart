// CMD #2147 — the customer bottom navigation, as a floating dock.
//
// A rounded white dock floating 12 px above the bottom and the sides: 60 px
// tall, radius 22, soft shadow. Tabs are 24 px grey outline icons with no
// labels; the ACTIVE tab widens into a 44 px green pill wearing its white
// filled icon and its name, and the pill slides + stretches to a tapped tab
// (220 ms, gentle spring) while the name fades in and outline → filled
// cross-fades. Orders' count is a red badge on the icon, and sits inside the
// pill when Orders is active. Profile is a letter ring, and a white letter
// disc inside the pill when active.
//
// WHICH tabs exist, their order, their names, their badges and the page each
// opens are `customer_nav()`'s rows — this file draws [DockTab]s and decides
// nothing about them. Reduce-motion (the phone's setting) switches instantly.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// One tab, already resolved from its `customer_nav` row by the shell.
class DockTab {
  const DockTab({
    required this.key,
    required this.label,
    required this.icon,
    required this.activeIcon,
    this.badge = '',
    this.avatarLetter,
  });

  /// The row's `key` — also the tab's semantics handle (`nav_slot_<key>`).
  final String key;
  final String label;

  final IconData icon, activeIcon;

  /// The badge text, verbatim; '' = no badge.
  final String badge;

  /// Non-null = an avatar tab ('' draws the person glyph).
  final String? avatarLetter;
}

class FloatingDock extends StatelessWidget {
  const FloatingDock({
    super.key,
    required this.tabs,
    required this.activeIndex,
    required this.onTap,
    this.bar,
  });

  /// CMD #2147 (Om) — the login / registration ask, joined INTO the dock as
  /// the card's top row ([DockBarRow]). Null = the card is the dock alone; the
  /// change animates (200 ms).
  final Widget? bar;

  final List<DockTab> tabs;

  /// The lit tab's POSITION in [tabs]; the shell resolves it from the rows.
  final int activeIndex;

  /// Hands back the tapped tab's position; the shell maps it to its row.
  final ValueChanged<int> onTap;

  /// The dock's own height, its float above the screen edges, and the pill.
  static double get dockHeight => Ds.space.x48 + Ds.space.x16;
  static double get edge => Ds.space.x12 + 2;
  static double get pillHeight => Ds.space.x48;
  static double get radius => Ds.space.x24 + Ds.space.x4;

  /// CMD #2156 (Om) — the joined bar row is EXACTLY the nav row's height
  /// (64 + 64, the 1 px hairline between), and its button is the 44 touch
  /// minimum while the active pill is 48 — both centred in their rows.
  static double get barHeight => dockHeight;
  static double get barButtonHeight => Ds.touch.minTarget;
  static const double hairline = 1;

  /// One shadow for the whole card: 0 6 20 rgba(0,0,0,.12).
  static List<BoxShadow> get cardShadow => [
        BoxShadow(color: Ds.c.text.withValues(alpha: 0.12), blurRadius: Ds.space.x16 + Ds.space.x4, offset: Offset(0, Ds.space.x4 + 2)),
      ];

  /// The bar row's light-green ground.
  static Color get barGround => Color.alphaBlend(Ds.c.brand.withValues(alpha: 0.05), Ds.c.surface);

  /// The motion: 220 ms on a gentle spring.
  static const Duration motion = Duration(milliseconds: 220);
  static const Curve spring = Curves.easeOutBack;

  /// Everything the dock takes from the bottom of the screen, safe area
  /// excluded: the float + the dock. Pages pad by this (+ the float) so their
  /// last row scrolls clear of it.
  static double get slotHeight => dockHeight + edge;

  @override
  Widget build(BuildContext context) {
    if (tabs.length < 2) return const SizedBox.shrink();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final active = activeIndex.clamp(0, tabs.length - 1);
    RenderLog.write('c2147_dock', '${tabs.length}:${tabs[active].key}');
    final safe = MediaQuery.viewPaddingOf(context).bottom;
    final bar = this.bar;
    return Padding(
      padding: EdgeInsets.only(left: edge, right: edge, bottom: edge + safe),
      // ONE white card: the bar row on top, the dock row below, no gap.
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: BorderRadius.circular(radius),
          boxShadow: cardShadow,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSize(
                duration: Duration(milliseconds: still ? 0 : 200),
                curve: Curves.easeOut,
                alignment: Alignment.bottomCenter,
                child: bar == null
                    ? const SizedBox(width: double.infinity)
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        SizedBox(height: barHeight, child: bar),
                        Container(height: hairline, color: Ds.c.divider),
                      ]),
              ),
              Container(
                height: dockHeight,
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
                child: LayoutBuilder(
                  builder: (context, box) =>
                      _track(context, box.maxWidth, active, still),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _track(BuildContext context, double width, int active, bool still) {
    final geo = DockGeometry.compute(
      width: width,
      tabs: tabs,
      active: active,
      labelWidth: (s) => _textWidth(context, s),
    );
    final d = still ? Duration.zero : motion;
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        // The green pill: ONE box that slides and stretches to the tab.
        AnimatedPositioned(
          duration: d,
          curve: spring,
          left: geo.lefts[active],
          width: geo.widths[active],
          top: (dockHeight - pillHeight) / 2,
          height: pillHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Ds.c.brand,
              borderRadius: BorderRadius.circular(pillHeight / 2),
            ),
          ),
        ),
        Row(
          children: [
            for (var i = 0; i < tabs.length; i++)
              AnimatedContainer(
                duration: d,
                curve: spring,
                width: geo.widths[i],
                height: dockHeight,
                child: _tab(tabs[i], i, i == active, still),
              ),
          ],
        ),
      ],
    );
  }

  Widget _tab(DockTab t, int i, bool on, bool still) {
    final d = Duration(milliseconds: still ? 0 : 150);
    return Semantics(
      container: true,
      identifier: 'nav_slot_${t.key}',
      button: true,
      selected: on,
      label: t.label,
      child: InkResponse(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap(i);
        },
        radius: pillHeight,
        containedInkWell: false,
        highlightShape: BoxShape.circle,
        child: ClipRect(
          child: OverflowBox(
            maxWidth: double.infinity,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: d,
                    child: KeyedSubtree(
                      key: ValueKey(on),
                      child: _glyph(t, on, d),
                    ),
                  ),
                  if (on) ...[
                    SizedBox(width: Ds.space.x8),
                    _FadeIn(
                      duration: d,
                      child: Text(
                        t.label,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: _labelStyle,
                      ),
                    ),
                    if (t.badge.isNotEmpty) ...[
                      SizedBox(width: Ds.space.x8),
                      _Pop(
                        duration: d,
                        value: t.badge,
                        child: _countDisc(t.badge, inPill: true),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static TextStyle get _labelStyle =>
      Ds.t.bodyStrong.copyWith(color: Ds.c.surface, height: 1);

  Widget _glyph(DockTab t, bool on, Duration d) {
    final size = Ds.space.x24;
    if (t.avatarLetter != null) {
      final letter = t.avatarLetter!;
      final fg = on ? Ds.c.brand : Ds.c.textSecondary;
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? Ds.c.surface : null,
          shape: BoxShape.circle,
          border: on ? null : Border.all(color: fg, width: 1.5),
        ),
        child: letter.isEmpty
            ? Icon(Icons.person, size: Ds.space.x16, color: fg)
            : Text(letter,
                style: Ds.t.caption.copyWith(
                    color: fg, fontWeight: FontWeight.w700, height: 1)),
      );
    }
    final icon = Icon(on ? t.activeIcon : t.icon,
        size: size, color: on ? Ds.c.surface : Ds.c.textSecondary);
    if (on || t.badge.isEmpty) return icon;
    // Inactive: the red count sits on the icon's top-right corner.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -Ds.space.x8,
          top: -Ds.space.x4,
          child: _Pop(
              duration: d, value: t.badge, child: _countDisc(t.badge, inPill: false)),
        ),
      ],
    );
  }

  static Widget _countDisc(String text, {required bool inPill}) => Container(
        constraints: BoxConstraints(
            minWidth: Ds.space.x16 + Ds.space.x4,
            minHeight: Ds.space.x16 + Ds.space.x4),
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: inPill ? Ds.c.surface : Ds.c.danger,
          borderRadius: BorderRadius.circular(Ds.space.x12),
          border: inPill ? null : Border.all(color: Ds.c.surface, width: 1.5),
        ),
        child: Text(text,
            style: Ds.t.caption.copyWith(
                color: inPill ? Ds.c.brand : Ds.c.surface,
                fontWeight: FontWeight.w700,
                height: 1)),
      );

  static double _textWidth(BuildContext context, String s) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: _labelStyle),
      maxLines: 1,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return tp.width;
  }
}

/// Where each tab sits. Pure, so the VM suite can hold the rules down: the
/// active tab is as wide as its icon + name (+ count) needs, capped so every
/// other tab keeps at least a 44 px touch target; the others share the rest.
class DockGeometry {
  const DockGeometry(this.widths, this.lefts);
  final List<double> widths, lefts;

  static DockGeometry compute({
    required double width,
    required List<DockTab> tabs,
    required int active,
    required double Function(String) labelWidth,
  }) {
    final n = tabs.length;
    final t = tabs[active];
    final pad = Ds.space.x16;
    var want = pad * 2 + Ds.space.x24 + Ds.space.x8 + labelWidth(t.label);
    if (t.badge.isNotEmpty) {
      want += Ds.space.x8 + Ds.space.x16 + Ds.space.x4 + labelWidth(t.badge);
    }
    final minOther = Ds.touch.minTarget;
    final cap = width - minOther * (n - 1);
    final even = width / n;
    final activeW = want.clamp(even < minOther ? minOther : even, cap < minOther ? minOther : cap);
    final other = n > 1 ? (width - activeW) / (n - 1) : 0.0;
    final widths = [for (var i = 0; i < n; i++) i == active ? activeW : other];
    final lefts = <double>[];
    var x = 0.0;
    for (final w in widths) {
      lefts.add(x);
      x += w;
    }
    return DockGeometry(widths, lefts);
  }
}

/// The name fades in when its tab becomes active.
class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.child, required this.duration});
  final Widget child;
  final Duration duration;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: duration,
        builder: (_, v, c) => Opacity(opacity: v, child: c),
        child: child,
      );
}

/// A count that pops (scale 0.6 → 1, 150 ms) whenever its value changes.
class _Pop extends StatelessWidget {
  const _Pop({required this.child, required this.value, required this.duration});
  final Widget child;
  final String value;
  final Duration duration;
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        key: ValueKey(value),
        tween: Tween(begin: 0.6, end: 1),
        duration: duration,
        curve: Curves.easeOutBack,
        builder: (_, v, c) => Transform.scale(scale: v, child: c),
        child: child,
      );
}

/// CMD #2147 (Om) — the login / registration ask as the dock card's top row:
/// light-green ground, a 40 px round white icon, the backend's label in bold on
/// one line (ellipsis), and a green pill button 10 px from the right edge.
/// Every string is `customer_registration_bar()`'s; this widget only draws.
class DockBarRow extends StatelessWidget {
  const DockBarRow({
    super.key,
    required this.icon,
    required this.label,
    required this.action,
    required this.onAction,
    this.actionIdentifier,
  });

  final IconData icon;
  final String label, action;
  final VoidCallback onAction;
  final String? actionIdentifier;

  @override
  Widget build(BuildContext context) => Container(
        color: FloatingDock.barGround,
        padding: EdgeInsets.only(left: Ds.space.x12, right: Ds.space.x8 + 2),
        child: Row(children: [
          Container(
            width: Ds.space.x32 + Ds.space.x8,
            height: Ds.space.x32 + Ds.space.x8,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: Ds.c.surface, shape: BoxShape.circle),
            child: Icon(icon, size: Ds.space.x24 - 4, color: Ds.c.textSecondary),
          ),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.bodyStrong.copyWith(fontWeight: FontWeight.w800)),
          ),
          SizedBox(width: Ds.space.x8),
          Semantics(
            identifier: actionIdentifier,
            button: true,
            child: SizedBox(
              height: FloatingDock.barButtonHeight,
              child: FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  foregroundColor: Ds.c.surface,
                  shape: const StadiumBorder(),
                  padding: EdgeInsets.symmetric(horizontal: Ds.space.x16 + Ds.space.x4),
                  textStyle: Ds.t.bodyStrong.copyWith(fontWeight: FontWeight.w700),
                ),
                child: Text(action, maxLines: 1),
              ),
            ),
          ),
        ]),
      );
}
