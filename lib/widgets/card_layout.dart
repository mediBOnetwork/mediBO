// CMD #2167 — the product card's geometry, colours and parts, from the backend.
//
// Every card payload now carries three blocks next to `style`:
//
//   layout          — spacing, radius, padding, photo box, text sizes and
//                     weights, border, shadow, image fit, and the grid's own
//                     gap / minimum card width
//   show            — pack_chip, sub_line, mrp, ptr_badge, scheme_badge,
//                     action, photo, wish
//   layout_screens  — per-screen overrides of layout / style / show, keyed
//                     home | catalogue | search | company | wishlist | category
//
// This file turns those blocks into ONE resolved [CardLayout]. Nothing here
// invents a number: every default below mirrors what `card_layout()` sends, so
// a payload that arrives before the settings row does still draws the card the
// backend means. Changing a value is an UPDATE to app_settings — the whole app
// re-measures on the next payload, with no deploy.
//
// [CardSurface] carries which screen is drawing, so the same card can be
// overridden per screen without a screen ever typing a number.

import 'package:flutter/material.dart';

/// Which parts of the card the backend is drawing.
class CardShow {
  final bool packChip, subLine, mrp, ptrBadge, schemeBadge, action, photo, wish;

  const CardShow({
    this.packChip = true,
    this.subLine = true,
    this.mrp = true,
    this.ptrBadge = true,
    this.schemeBadge = true,
    this.action = true,
    this.photo = true,
    this.wish = true,
  });

  static bool _b(Map m, String k, bool d) => m[k] is bool ? m[k] as bool : d;

  factory CardShow.from(Map m) => CardShow(
    packChip: _b(m, 'pack_chip', true),
    subLine: _b(m, 'sub_line', true),
    mrp: _b(m, 'mrp', true),
    ptrBadge: _b(m, 'ptr_badge', true),
    schemeBadge: _b(m, 'scheme_badge', true),
    action: _b(m, 'action', true),
    photo: _b(m, 'photo', true),
    wish: _b(m, 'wish', true),
  );
}

/// The resolved card geometry for one screen.
class CardLayout {
  final double radius, borderW, padX, padBottom, gapS, gapM, gapL;
  final double photoPad, imagePct;
  final double nameSize, nameLineH, subSize, subLineH, priceSize, mrpSize;
  final double chipH, chipSize, chipRadius, actionH, touchMin;

  /// CMD #2169 — the wishlist heart: the glyph the eye sees ([wishIcon]) and
  /// the invisible box that catches the finger ([wishTap]). There is nothing
  /// else to size: the white disc that used to sit under the heart is gone.
  final double wishIcon, wishTap;
  final double gridGap, pagePad, minCardW;
  final double shadowBlur, shadowDy, shadowAlpha;
  final int nameLines,
      textLines,
      nameWeight,
      subWeight,
      priceWeight,
      mrpWeight,
      chipWeight,
      maxCols;
  final String imageFit;
  final CardShow show;

  /// The resolved colour map — `card.style` merged with the v6 colours and
  /// with this screen's own overrides. Read through [color].
  final Map<String, Object?> style;

  const CardLayout({
    required this.radius,
    required this.borderW,
    required this.padX,
    required this.padBottom,
    required this.gapS,
    required this.gapM,
    required this.gapL,
    required this.photoPad,
    required this.imagePct,
    required this.nameSize,
    required this.nameLineH,
    required this.subSize,
    required this.subLineH,
    required this.priceSize,
    required this.mrpSize,
    required this.chipH,
    required this.chipSize,
    required this.chipRadius,
    required this.actionH,
    required this.touchMin,
    required this.wishIcon,
    required this.wishTap,
    required this.gridGap,
    required this.pagePad,
    required this.minCardW,
    required this.shadowBlur,
    required this.shadowDy,
    required this.shadowAlpha,
    required this.nameLines,
    required this.textLines,
    required this.nameWeight,
    required this.subWeight,
    required this.priceWeight,
    required this.mrpWeight,
    required this.chipWeight,
    required this.maxCols,
    required this.imageFit,
    required this.show,
    required this.style,
  });

  /// The card as the backend describes it today. Used only until the first
  /// payload lands (an empty grid, a skeleton, a rail still loading).
  static const CardLayout fallback = CardLayout(
    radius: 16,
    borderW: 1,
    padX: 12,
    padBottom: 12,
    gapS: 4,
    gapM: 6,
    gapL: 8,
    photoPad: 0,
    imagePct: 92,
    nameSize: 14,
    nameLineH: 18,
    subSize: 12,
    subLineH: 16,
    priceSize: 14,
    mrpSize: 12,
    chipH: 26,
    chipSize: 10,
    chipRadius: 8,
    actionH: 36,
    touchMin: 44,
    wishIcon: 24,
    wishTap: 44,
    gridGap: 12,
    pagePad: 16,
    minCardW: 162,
    shadowBlur: 3,
    shadowDy: 1,
    shadowAlpha: 0.06,
    nameLines: 2,
    textLines: 3,
    nameWeight: 700,
    subWeight: 400,
    priceWeight: 800,
    mrpWeight: 500,
    chipWeight: 700,
    maxCols: 6,
    imageFit: 'contain',
    show: CardShow(),
    style: {},
  );

  /// The last layout a real payload resolved to, per screen. A grid that is
  /// still loading, or a rail whose page has no cards yet, reserves the same
  /// geometry the cards will land in — never a second set of numbers.
  static final Map<String, CardLayout> _seen = <String, CardLayout>{};

  static Map _m(Object? v) => v is Map ? v : const {};

  static double _d(Map m, String k, double d) {
    final v = m[k];
    if (v is num) return v.toDouble();
    return double.tryParse('${v ?? ''}') ?? d;
  }

  static int _i(Map m, String k, int d) {
    final v = m[k];
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? d;
  }

  /// Resolves the layout for [card] (a `_product_card` payload) on [screen].
  /// A null or pre-#2167 payload returns the last one seen, then [fallback].
  static CardLayout of(Map? card, {String screen = ''}) {
    if (card == null || card['layout'] is! Map) return latest(screen);

    final ov = _m(_m(card['layout_screens'])[screen]);
    final l = <String, Object?>{}
      ..addAll(_m(card['layout']).cast<String, Object?>())
      ..addAll(_m(ov['layout']).cast<String, Object?>());
    // `v6` carries its colours in named blocks (scheme / unavail_chip /
    // notify_pill); they are flattened next to `style`'s so a screen override
    // can restyle any of them the same way.
    final v6 = _m(card['v6']);
    final st = <String, Object?>{}
      ..addAll(_m(card['style']).cast<String, Object?>())
      ..addAll({
        'scheme_bg': _m(v6['scheme'])['bg'],
        'scheme_fg': _m(v6['scheme'])['fg'],
        'unavail_bg': _m(v6['unavail_chip'])['bg'],
        'unavail_fg': _m(v6['unavail_chip'])['fg'],
        'notify_bg': _m(v6['notify_pill'])['bg'],
        'notify_fg': _m(v6['notify_pill'])['fg'],
      })
      ..addAll(_m(ov['style']).cast<String, Object?>());
    final sh = <String, Object?>{}
      ..addAll(_m(card['show']).cast<String, Object?>())
      ..addAll(_m(ov['show']).cast<String, Object?>());

    const f = fallback;
    final out = CardLayout(
      radius: _d(l, 'radius', f.radius),
      borderW: _d(l, 'border_w', f.borderW),
      padX: _d(l, 'pad_x', f.padX),
      padBottom: _d(l, 'pad_bottom', f.padBottom),
      gapS: _d(l, 'gap_s', f.gapS),
      gapM: _d(l, 'gap_m', f.gapM),
      gapL: _d(l, 'gap_l', f.gapL),
      photoPad: _d(l, 'photo_pad', f.photoPad),
      imagePct: _d(
        l,
        'image_pct',
        _d(v6, 'image_pct', f.imagePct),
      ).clamp(1, 100),
      nameSize: _d(l, 'name_size', f.nameSize),
      nameLineH: _d(l, 'name_line_h', f.nameLineH),
      subSize: _d(l, 'sub_size', f.subSize),
      subLineH: _d(l, 'sub_line_h', f.subLineH),
      priceSize: _d(l, 'price_size', f.priceSize),
      mrpSize: _d(l, 'mrp_size', f.mrpSize),
      chipH: _d(l, 'chip_h', f.chipH),
      chipSize: _d(l, 'chip_size', f.chipSize),
      chipRadius: _d(l, 'chip_radius', f.chipRadius),
      actionH: _d(l, 'action_h', f.actionH),
      touchMin: _d(l, 'touch_min', f.touchMin),
      wishIcon: _d(l, 'wish_icon', f.wishIcon),
      wishTap: _d(l, 'wish_tap', f.wishTap),
      gridGap: _d(l, 'grid_gap', f.gridGap),
      pagePad: _d(l, 'page_pad', f.pagePad),
      minCardW: _d(l, 'min_card_w', f.minCardW),
      shadowBlur: _d(l, 'shadow_blur', f.shadowBlur),
      shadowDy: _d(l, 'shadow_dy', f.shadowDy),
      shadowAlpha: _d(l, 'shadow_alpha', f.shadowAlpha),
      nameLines: _i(l, 'name_lines', f.nameLines),
      textLines: _i(l, 'text_lines', f.textLines),
      nameWeight: _i(l, 'name_weight', f.nameWeight),
      subWeight: _i(l, 'sub_weight', f.subWeight),
      priceWeight: _i(l, 'price_weight', f.priceWeight),
      mrpWeight: _i(l, 'mrp_weight', f.mrpWeight),
      chipWeight: _i(l, 'chip_weight', f.chipWeight),
      maxCols: _i(l, 'max_cols', f.maxCols),
      imageFit: (l['image_fit'] ?? f.imageFit).toString(),
      show: CardShow.from(sh),
      style: st,
    );
    _seen[screen] = out;
    return out;
  }

  /// The layout last resolved on [screen], or on any screen, or the fallback.
  static CardLayout latest(String screen) =>
      _seen[screen] ?? (_seen.isEmpty ? fallback : _seen.values.last);

  /// The backend colour behind [key], or [fallback] when it sent none.
  Color color(String key, Color fallbackColor) {
    final raw = style[key];
    if (raw is! String || raw.trim().isEmpty) return fallbackColor;
    var h = raw.trim().replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return fallbackColor;
    final v = int.tryParse(h, radix: 16);
    return v == null ? fallbackColor : Color(v);
  }

  /// How tall this card is at [w] wide: the square plate (when the payload
  /// draws one), its border, and the body under it — every part a backend
  /// number. A rail asks for this instead of reserving a constant, so the
  /// cards in one rail share one height that is still the payload's.
  /// CMD #2167 QA round 1, finding 3: the line counts default to THIS layout's
  /// own `name_lines` / `text_lines`, not to Dart constants. A rail calling
  /// `cardHeight(w)` used to reserve a 2-line/3-line band whatever the payload
  /// said, so an UPDATE to card.layout resized the grid cards (they measure
  /// themselves) and left the rail's band behind — clipped or gapped from a
  /// pure backend change, the one thing spec item 4 exists to prevent.
  double cardHeight(double w, {int? nameLines, int? textLines}) {
    final nl = nameLines ?? this.nameLines;
    final tl = textLines ?? this.textLines;
    final textH = nameLineH * nl + subLineH * (tl - nl).clamp(0, 4);
    final body = gapL + textH + gapL + (priceSize + gapL) + padBottom;
    final plate = show.photo ? w - borderW * 2 : 0.0;
    return plate + borderW * 2 + body;
  }

  /// The photo's contain box on a [plate]-wide square plate.
  double imageSide(double plate) => plate * imagePct / 100 - photoPad * 2;

  BoxFit get fit => imageFit == 'cover' ? BoxFit.cover : BoxFit.contain;

  /// How many cards fit across [width] — the width AFTER the page padding.
  int columnsFor(double width) {
    final slot = minCardW + gridGap;
    if (slot <= 0) return 2;
    final n = ((width + gridGap) / slot).floor();
    return n.clamp(2, maxCols < 2 ? 2 : maxCols);
  }

  /// The width of ONE card across [width]. A rail passes the same number the
  /// grid does, which is what makes a home card and a catalogue card the same
  /// size to the pixel.
  double cardWidth(double width) {
    final n = columnsFor(width);
    final w = (width - gridGap * (n - 1)) / n;
    return w <= 0 ? width : w;
  }
}

/// The screen a card is being drawn on, so `layout_screens` can override it.
/// Absent = the base layout, which is what every card drew before #2167.
class CardSurface extends InheritedWidget {
  final String screen;

  const CardSurface({super.key, required this.screen, required super.child});

  static String of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CardSurface>()?.screen ?? '';

  @override
  bool updateShouldNotify(CardSurface old) => old.screen != screen;
}
