import 'package:flutter/material.dart';

/// CHANGE #66 — the permanent, backend-driven design system ("Ds").
///
/// THE APP RENDERS. IT NEVER DECIDES. — a colour, a radius, a gap or a text
/// size is an ANSWER, and every answer belongs to the backend. `ui_boot()`
/// returns a `design` token block; this file is the one place that block is
/// turned into `ThemeData` and a tiny `Ds.*` accessor the whole app paints
/// with. Nothing here is authority: these are the DEFAULTS the first frame
/// paints before the payload lands, and the exact shape the payload overwrites.
///
/// Recolour the whole app with zero code change:
///   ui_design_set({"colors":{"brand":"#0E7C3A"}})
/// On the next boot `ui_boot().design.colors.brand` arrives, `Ds.apply()` sets
/// `Ds.c.brand`, `buildTheme()` rebuilds, and every theme-driven surface — app
/// bars, primary buttons, chips, links, nav — turns the new green. No deploy.
///
/// Defensive-import safe: this file imports only `package:flutter/material.dart`
/// (no dart:html / dart:js), so it may sit anywhere in the widget tree.
class Ds {
  Ds._();

  /// Bumped after [apply] so a listener (the boot copy revision already covers
  /// this, since ui_boot lands both in one payload) can re-theme.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static DsColors c = DsColors._defaults();

  // CHANGE #1017 (4) — dark mode is a second palette in the SAME token set
  // (`design.dark.colors`, data via ui_design_set) and one switch. Only the
  // ground and the text swap; the state colours keep their meaning. `_light`
  // remembers the day palette so a toggle is a swap, never a re-fetch.
  static DsColors _light = DsColors._defaults();
  static DsColors dark = DsColors._darkDefaults();
  static Brightness brightness = Brightness.light;
  static bool get isDark => brightness == Brightness.dark;

  /// Switch the live palette. The theme is rebuilt by whoever listens to
  /// [revision] — the same bump every token change already makes.
  static void setBrightness(Brightness b) {
    if (brightness == b) return;
    brightness = b;
    c = b == Brightness.dark ? dark : _light;
    revision.value++;
  }
  static DsRadius r = DsRadius._defaults();
  static DsType t = DsType._defaults();
  static DsSpace space = DsSpace._defaults();
  static DsElevation elevation = DsElevation._defaults();
  static DsMotion motion = DsMotion._defaults();
  static DsTouch touch = DsTouch._defaults();
  static DsHeader header = DsHeader._defaults();
  static DsPullClose pullClose = DsPullClose._defaults();

  /// CMD #2175 — the ONE shell geometry: `shell_style().common`, published on
  /// `ui_boot().design.shell`. The header row, the search bar, the banner, the
  /// bottom-nav rows and the floating "View cart" pill are all this tall, sit
  /// this far in from the edge, wear this corner and keep this gap from their
  /// neighbour — so "how tall is the shell" has exactly one answer.
  static DsShell shell = DsShell._defaults();

  /// The brand hex currently in force — mirrored to the render-log so a
  /// headless verifier can PROVE the app consumed a recolour token.
  static String brandHex = '#1B873F';

  /// Overwrite every token from the backend `design` block. Missing keys keep
  /// their current value, so a partial patch never blanks the theme.
  static void apply(Object? design) {
    if (design is! Map) return;
    _light = DsColors._from(_asMap(design['colors']), _light);
    dark = DsColors._from(_asMap(_asMap(design['dark'])['colors']), dark);
    c = isDark ? dark : _light;
    r = DsRadius._from(_asMap(design['radius']), r);
    t = DsType._from(_asMap(design['type']), t);
    space = DsSpace._from(design['spacing'], space);
    elevation = DsElevation._from(_asMap(design['elevation']), elevation);
    motion = DsMotion._from(_asMap(design['motion']), motion);
    touch = DsTouch._from(_asMap(design['touch']), touch);
    header = DsHeader._from(_asMap(design['header']), header);
    pullClose = DsPullClose._from(_asMap(design['pull_close']), pullClose);
    shell = DsShell._from(_asMap(design['shell']), shell);
    brandHex = _hexStr(_asMap(design['colors'])['brand']) ?? brandHex;
    revision.value++;
  }

  static Map _asMap(Object? v) => v is Map ? v : const {};

  /// Parses a backend `#RRGGBB` / `#AARRGGBB` string. Returns [fallback] for
  /// anything unreadable, so a bad colour row can never white-screen a page.
  static Color hex(Object? raw, Color fallback) {
    final s = _hexStr(raw);
    if (s == null) return fallback;
    var h = s.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return fallback;
    final v = int.tryParse(h, radix: 16);
    return v == null ? fallback : Color(v);
  }

  static String? _hexStr(Object? raw) =>
      raw is String && raw.trim().isNotEmpty ? raw.trim() : null;

  /// CMD #2167 — a backend font weight (400…900) as a [FontWeight].
  static FontWeight weight(int w, [FontWeight fallback = FontWeight.w400]) {
    final i = (w ~/ 100) - 1;
    if (i < 0 || i >= FontWeight.values.length) return fallback;
    return FontWeight.values[i];
  }

  static double _num(Object? v, double fallback) =>
      v is num ? v.toDouble() : fallback;
}

/// The semantic palette. Field names mirror the backend token keys exactly.
class DsColors {
  final Color bg, surface, brand, brandDark, text, textSecondary, divider;
  final Color success, warning, danger, info;
  const DsColors({
    required this.bg,
    required this.surface,
    required this.brand,
    required this.brandDark,
    required this.text,
    required this.textSecondary,
    required this.divider,
    required this.success,
    required this.warning,
    required this.danger,
    required this.info,
  });

  factory DsColors._defaults() => const DsColors(
        bg: Color(0xFFF7F7F8),
        surface: Color(0xFFFFFFFF),
        brand: Color(0xFF1B873F),
        brandDark: Color(0xFF136A30),
        text: Color(0xFF111111),
        textSecondary: Color(0xFF6E6E73),
        divider: Color(0xFFE5E5EA),
        success: Color(0xFF34C759),
        warning: Color(0xFFFF9500),
        danger: Color(0xFFFF3B30),
        info: Color(0xFF0A84FF),
      );

  /// The dark defaults, for a boot before the tokens arrive. The live values
  /// are the backend's (`design.dark.colors`); these only stop a flash.
  factory DsColors._darkDefaults() => const DsColors(
        bg: Color(0xFF0F1113),
        surface: Color(0xFF1A1D21),
        brand: Color(0xFF2FB25A),
        brandDark: Color(0xFF1B873F),
        text: Color(0xFFF2F3F5),
        textSecondary: Color(0xFFA0A6AD),
        divider: Color(0xFF2A2F35),
        success: Color(0xFF34C759),
        warning: Color(0xFFFF9F0A),
        danger: Color(0xFFFF453A),
        info: Color(0xFF409CFF),
      );

  factory DsColors._from(Map m, DsColors f) => DsColors(
        bg: Ds.hex(m['bg'], f.bg),
        surface: Ds.hex(m['surface'], f.surface),
        brand: Ds.hex(m['brand'], f.brand),
        brandDark: Ds.hex(m['brandDark'], f.brandDark),
        text: Ds.hex(m['text'], f.text),
        textSecondary: Ds.hex(m['textSecondary'], f.textSecondary),
        divider: Ds.hex(m['divider'], f.divider),
        success: Ds.hex(m['success'], f.success),
        warning: Ds.hex(m['warning'], f.warning),
        danger: Ds.hex(m['danger'], f.danger),
        info: Ds.hex(m['info'], f.info),
      );

  /// A quiet tint of the brand for chips / selected states / soft bands.
  Color get brandSoft => Color.alphaBlend(brand.withValues(alpha: 0.10), surface);
  Color get successSoft => Color.alphaBlend(success.withValues(alpha: 0.14), surface);
  Color get warningSoft => Color.alphaBlend(warning.withValues(alpha: 0.16), surface);
  Color get dangerSoft => Color.alphaBlend(danger.withValues(alpha: 0.12), surface);
  Color get infoSoft => Color.alphaBlend(info.withValues(alpha: 0.12), surface);
}

/// Corner radii. Backend keys: card, chip, sheet, button.
class DsRadius {
  final double card, chip, sheet, button;
  const DsRadius({required this.card, required this.chip, required this.sheet, required this.button});
  factory DsRadius._defaults() => const DsRadius(card: 16, chip: 20, sheet: 24, button: 12);
  factory DsRadius._from(Map m, DsRadius f) => DsRadius(
        card: Ds._num(m['card'], f.card),
        chip: Ds._num(m['chip'], f.chip),
        sheet: Ds._num(m['sheet'], f.sheet),
        button: Ds._num(m['button'], f.button),
      );
  BorderRadius get rCard => BorderRadius.circular(card);
  BorderRadius get rChip => BorderRadius.circular(chip);
  BorderRadius get rSheet => BorderRadius.circular(sheet);
  BorderRadius get rButton => BorderRadius.circular(button);
}

/// The spacing scale, indexable and named. Backend sends an ascending array;
/// the named getters map onto the canonical [4,8,12,16,24,32,48] rhythm.
class DsSpace {
  final List<double> scale;
  const DsSpace(this.scale);
  factory DsSpace._defaults() => const DsSpace([4, 8, 12, 16, 24, 32, 48]);
  factory DsSpace._from(Object? v, DsSpace f) {
    if (v is List && v.isNotEmpty) {
      final xs = v.whereType<num>().map((n) => n.toDouble()).toList();
      if (xs.isNotEmpty) return DsSpace(xs);
    }
    return f;
  }
  double _at(int i) => i >= 0 && i < scale.length ? scale[i] : scale.last;
  double get x4 => _at(0);
  double get x8 => _at(1);
  double get x12 => _at(2);
  double get x16 => _at(3);
  double get x24 => _at(4);
  double get x32 => _at(5);
  double get x48 => _at(6);
  /// A hairline rule — the one sub-scale width the design system allows
  /// (dividers, 1px borders). Defined here so screens never write `1`.
  double get hairline => 1;
  double call(int i) => _at(i);
}

/// The type ramp. Each style carries size + weight + the shared line-height.
class DsType {
  final double displaySize, titleSize, subtitleSize, bodySize, captionSize;
  final int displayWeight, titleWeight, subtitleWeight, bodyWeight, captionWeight;
  final double lineHeight;
  const DsType({
    required this.displaySize,
    required this.titleSize,
    required this.subtitleSize,
    required this.bodySize,
    required this.captionSize,
    required this.displayWeight,
    required this.titleWeight,
    required this.subtitleWeight,
    required this.bodyWeight,
    required this.captionWeight,
    required this.lineHeight,
  });
  factory DsType._defaults() => const DsType(
        displaySize: 28,
        titleSize: 20,
        subtitleSize: 17,
        bodySize: 15,
        captionSize: 13,
        displayWeight: 700,
        titleWeight: 600,
        subtitleWeight: 600,
        bodyWeight: 400,
        captionWeight: 400,
        lineHeight: 1.35,
      );
  factory DsType._from(Map m, DsType f) {
    Map g(String k) => m[k] is Map ? m[k] as Map : const {};
    final d = g('display'), ti = g('title'), su = g('subtitle'), b = g('body'), ca = g('caption');
    return DsType(
      displaySize: Ds._num(d['size'], f.displaySize),
      titleSize: Ds._num(ti['size'], f.titleSize),
      subtitleSize: Ds._num(su['size'], f.subtitleSize),
      bodySize: Ds._num(b['size'], f.bodySize),
      captionSize: Ds._num(ca['size'], f.captionSize),
      displayWeight: Ds._num(d['weight'], f.displayWeight.toDouble()).round(),
      titleWeight: Ds._num(ti['weight'], f.titleWeight.toDouble()).round(),
      subtitleWeight: Ds._num(su['weight'], f.subtitleWeight.toDouble()).round(),
      bodyWeight: Ds._num(b['weight'], f.bodyWeight.toDouble()).round(),
      captionWeight: Ds._num(ca['weight'], f.captionWeight.toDouble()).round(),
      lineHeight: Ds._num(m['lineHeight'], f.lineHeight),
    );
  }

  FontWeight _w(int v) {
    const map = {
      100: FontWeight.w100, 200: FontWeight.w200, 300: FontWeight.w300,
      400: FontWeight.w400, 500: FontWeight.w500, 600: FontWeight.w600,
      700: FontWeight.w700, 800: FontWeight.w800, 900: FontWeight.w900,
    };
    return map[(v ~/ 100) * 100] ?? FontWeight.w400;
  }

  TextStyle _style(double size, int weight, Color color, {double? tracking}) => TextStyle(
        fontSize: size,
        height: lineHeight,
        fontWeight: _w(weight),
        letterSpacing: tracking,
        color: color,
        decoration: TextDecoration.none,
      );

  TextStyle get display => _style(displaySize, displayWeight, Ds.c.text, tracking: -0.5);
  TextStyle get title => _style(titleSize, titleWeight, Ds.c.text, tracking: -0.3);
  TextStyle get subtitle => _style(subtitleSize, subtitleWeight, Ds.c.text, tracking: -0.2);
  TextStyle get body => _style(bodySize, bodyWeight, Ds.c.text);
  TextStyle get bodySecondary => _style(bodySize, bodyWeight, Ds.c.textSecondary);

  /// CHANGE #286 — body size at the subtitle weight. The slim update bar's
  /// one line and its pill label are "15px semibold" in the spec; both numbers
  /// stay backend tokens (type.body.size + type.subtitle.weight) instead of
  /// becoming literals at the call site.
  TextStyle get bodyStrong => _style(bodySize, subtitleWeight, Ds.c.text);
  TextStyle get caption => _style(captionSize, captionWeight, Ds.c.textSecondary);
}

/// Two elevation levels → ready-to-use BoxShadow lists.
class DsElevation {
  final double e1x, e1y, e1blur, e1alpha;
  final double e2x, e2y, e2blur, e2alpha;

  /// CMD #2037 — the UPWARD shadow. A bar that sits ON something (the update
  /// card on the bottom nav, a pinned footer on a list) needs its shadow cast
  /// up out of its top edge; e1/e2 both fall downwards, where nothing can see
  /// them. Same three numbers, negative y, so it is retunable from the backend
  /// like every other elevation.
  final double eUpx, eUpy, eUpblur, eUpalpha;
  const DsElevation({
    required this.e1x, required this.e1y, required this.e1blur, required this.e1alpha,
    required this.e2x, required this.e2y, required this.e2blur, required this.e2alpha,
    required this.eUpx, required this.eUpy, required this.eUpblur, required this.eUpalpha,
  });
  factory DsElevation._defaults() => const DsElevation(
        e1x: 0, e1y: 1, e1blur: 3, e1alpha: 0.06,
        e2x: 0, e2y: 4, e2blur: 12, e2alpha: 0.08,
        eUpx: 0, eUpy: -4, eUpblur: 16, eUpalpha: 0.08,
      );
  factory DsElevation._from(Map m, DsElevation f) {
    Map g(String k) => m[k] is Map ? m[k] as Map : const {};
    final a = g('e1'), b = g('e2'), u = g('eUp');
    return DsElevation(
      e1x: Ds._num(a['x'], f.e1x), e1y: Ds._num(a['y'], f.e1y),
      e1blur: Ds._num(a['blur'], f.e1blur), e1alpha: Ds._num(a['alpha'], f.e1alpha),
      e2x: Ds._num(b['x'], f.e2x), e2y: Ds._num(b['y'], f.e2y),
      e2blur: Ds._num(b['blur'], f.e2blur), e2alpha: Ds._num(b['alpha'], f.e2alpha),
      eUpx: Ds._num(u['x'], f.eUpx), eUpy: Ds._num(u['y'], f.eUpy),
      eUpblur: Ds._num(u['blur'], f.eUpblur), eUpalpha: Ds._num(u['alpha'], f.eUpalpha),
    );
  }
  List<BoxShadow> get e1 => [
        BoxShadow(color: const Color(0xFF000000).withValues(alpha: e1alpha), offset: Offset(e1x, e1y), blurRadius: e1blur),
      ];
  List<BoxShadow> get e2 => [
        BoxShadow(color: const Color(0xFF000000).withValues(alpha: e2alpha), offset: Offset(e2x, e2y), blurRadius: e2blur),
      ];

  /// CMD #2167 — a shadow the BACKEND sizes. The card's `layout` block carries
  /// blur / dy / alpha, so a flatter or deeper card is an app_settings update
  /// rather than a deploy. Same shape as e1/e2, different numbers.
  List<BoxShadow> shadow(double blur, double dy, double alpha) => [
        BoxShadow(
            color: const Color(0xFF000000).withValues(alpha: alpha),
            offset: Offset(0, dy),
            blurRadius: blur),
      ];

  /// A soft shadow cast UPWARDS out of the top edge.
  List<BoxShadow> get eUp => [
        BoxShadow(color: const Color(0xFF000000).withValues(alpha: eUpalpha), offset: Offset(eUpx, eUpy), blurRadius: eUpblur),
      ];
}

/// Motion tokens → Durations + curve.
class DsMotion {
  final int standardMs, sheetMs;
  final String curveName;
  const DsMotion({required this.standardMs, required this.sheetMs, required this.curveName});
  factory DsMotion._defaults() => const DsMotion(standardMs: 200, sheetMs: 300, curveName: 'easeOut');
  factory DsMotion._from(Map m, DsMotion f) => DsMotion(
        standardMs: Ds._num(m['standardMs'], f.standardMs.toDouble()).round(),
        sheetMs: Ds._num(m['sheetMs'], f.sheetMs.toDouble()).round(),
        curveName: m['curve'] is String ? m['curve'] as String : f.curveName,
      );
  Duration get standard => Duration(milliseconds: standardMs);
  Duration get sheet => Duration(milliseconds: sheetMs);
  Curve get curve {
    switch (curveName) {
      case 'easeIn':
        return Curves.easeIn;
      case 'easeInOut':
        return Curves.easeInOut;
      case 'linear':
        return Curves.linear;
      case 'easeOut':
      default:
        return Curves.easeOut;
    }
  }
}

/// Touch-target minimums.
class DsTouch {
  final double minTarget, listRowMinHeight;

  /// CMD #2030 — the storefront header band's height, in logical pixels: both
  /// the row's height AND the exact distance the band travels before it is
  /// gone, so the two can never be set apart by an edit.
  ///
  /// CMD #2175 — it is no longer a token of its own. The header row is one of
  /// the five pieces of chrome Om's redline puts on ONE height, so the band's
  /// number IS [Ds.shell.height] — a getter, not a copy, because two numbers
  /// that must agree are one edit away from disagreeing. Retuning the header
  /// is still one `ui_design_set({'shell': {'height': N}})` away, with no
  /// deploy; it just retunes the search bar, the banner, the nav and the
  /// "View cart" pill with it, which is the point.
  double get headerBand => Ds.shell.height;

  /// CMD #2038 — how far the finger has to travel in the NEW direction before
  /// the scroll-linked header is allowed to turn around, in logical pixels.
  /// Anything smaller is jitter, a bounce or a snap-back, and the band ignores
  /// it. A token, not a constant, so the flicker guard is retunable with one
  /// `ui_design_set` and no deploy.
  ///
  /// CMD #2052 — it is 40 now, and it is measured on the FINGER rather than on
  /// the list: a deliberate change of mind, not a tremor.
  final double headerHysteresis;

  /// CMD #2052 — how long the band takes to finish itself off once the finger
  /// has left the glass, in milliseconds. The gesture decides WHICH end (the
  /// direction the drag was going); this decides how fast it gets there, so the
  /// band is never left half open. A token, so the feel is an `ui_design_set`.
  final double headerSettleMs;

  /// CHANGE #286 — how far above the bottom of the screen a pinned bar floats,
  /// so it clears the bottom nav (and any floating cart pill) instead of
  /// covering it. Backend token, so the offset is retunable with zero deploy.
  final double bottomBarGap;

  /// CMD #2116 — the EXACT width of the action button on a bottom bar, in
  /// logical pixels.
  ///
  /// The update bar, the registration bar and the login bar are one widget in
  /// one box, and they still did not line up: the button was sized to its own
  /// label, so `Login` drew a narrower box than `Continue` and the two bars
  /// read as two different pieces of chrome stacked in the same slot. A width
  /// the LABEL decides is a width that changes every time the backend rewords
  /// the button — which is exactly the thing that is supposed to be free.
  ///
  /// So the box is a token and the word goes inside it. A longer word scales
  /// down to fit rather than widening the button or ellipsing into `Updat…`,
  /// and every bar in the slot is the same rectangle whatever it says.
  final double barActionWidth;

  /// CMD #2172 (Om) — how far the finger travels before the bottom nav row is
  /// gone, and back again, in logical pixels.
  ///
  /// It is deliberately NOT [headerBand]: #2080 published the nav as the band's
  /// own travel read as a fraction, so the bar needed 64 px of BELIEVED travel
  /// (the band's 40 px reservoir first) before it had moved at all. Om's design
  /// is "scroll down 8 dp: only the nav row slides away · scroll up 8 dp: the
  /// nav returns" — a short window that answers the finger straight away. A
  /// token, so the feel is one `ui_design_set` and no deploy.
  final double navHideTravel;

  /// CMD #2172 (Om) — the air between the View cart pill and the floating card
  /// under it. The pill is SEPARATE from the card and never hides, so this is
  /// the one number that keeps it off whatever the card currently is: both rows
  /// at the top of a page, the banner alone once the nav has slid away.
  final double cartPillGap;

  /// CMD #2147 (Om) — the header's own measurements, one token each.
  final double headerTile, headerTileRadius, headerTileMark, headerTop, headerWord, headerWordGap, headerGap, headerPill, headerPillText;

  const DsTouch({
    required this.minTarget,
    required this.listRowMinHeight,
    required this.bottomBarGap,
    required this.barActionWidth,
    required this.headerHysteresis,
    required this.headerSettleMs,
    required this.navHideTravel,
    required this.cartPillGap,
    required this.headerTile,
    required this.headerTileRadius,
    required this.headerTileMark,
    required this.headerTop,
    required this.headerWord,
    required this.headerWordGap,
    required this.headerGap,
    required this.headerPill,
    required this.headerPillText,
  });
  factory DsTouch._defaults() => const DsTouch(
      minTarget: 44,
      listRowMinHeight: 56,
      bottomBarGap: 56,
      // CMD #2116 — wide enough for the longest word the three bars send
      // ("Update Now") at body-strong weight plus its side padding, and still
      // leaving the sentence its share of a 360 px row.
      barActionWidth: 120,
      // CMD #2037 — back to the height the header had before #2030 (a 40 px
      // avatar in 12 px of padding, top and bottom). #2030 made the band's
      // height and its scroll travel ONE number and set that number to 56,
      // which shortened the header as a side effect of making it move; this
      // puts the height back without touching the 1:1 travel, because the
      // travel is still the same token.
      // CMD #2052 — 40 px of FINGER travel. #2038's 8 was measured on the
      // list's own deltas, where 8 px was already generous; on the pointer it
      // is a twitch. Forty is the spec's own number: a deliberate change of
      // mind, and nothing smaller turns the header around.
      headerHysteresis: 40,
      // CMD #2052 — the settle. Long enough to read as a movement, short
      // enough that a fast scroller never sees a half-open header.
      headerSettleMs: 180,
      // CMD #2172 — Om's own number, on the finger: 8 dp each way.
      navHideTravel: 8,
      // CMD #2172 — Om's own number: the pill floats 10 dp above the card.
      cartPillGap: 10,
      headerTile: 40, // the logo tile, the header row, the sticky search field and the bell box
      headerTileRadius: 11, // the logo tile corner
      headerTileMark: 28, // the tile's "m"
      headerTop: 12, // header row inset from the top
      headerWord: 26, // the mediBO wordmark (CMD #2164: never bigger than 26)
      headerWordGap: 8, // tile → wordmark
      headerGap: 10, // wordmark → pill, and tile → sticky search
      // CMD #2175 (Om, on #1523) — "Pill is 40 dp radius 20 — same as the logo
      // tile and the search box." The three round things on the shell's one
      // row are now one size, so the header reads as a single optical line
      // instead of a 40 tile beside a 32 pill.
      headerPill: 40, // the order-hours pill height
      headerPillText: 14); // the order-hours pill label
  factory DsTouch._from(Map m, DsTouch f) => DsTouch(
        minTarget: Ds._num(m['minTarget'], f.minTarget),
        listRowMinHeight: Ds._num(m['listRowMinHeight'], f.listRowMinHeight),
        bottomBarGap: Ds._num(m['bottomBarGap'], f.bottomBarGap),
        barActionWidth: Ds._num(m['barActionWidth'], f.barActionWidth),
        headerHysteresis:
            Ds._num(m['headerHysteresis'], f.headerHysteresis),
        headerSettleMs:
            Ds._num(m['headerSettleMs'], f.headerSettleMs),
        navHideTravel: Ds._num(m['navHideTravel'], f.navHideTravel),
        cartPillGap: Ds._num(m['cartPillGap'], f.cartPillGap),
        headerTile: Ds._num(m['headerTile'], f.headerTile),
        headerTileRadius: Ds._num(m['headerTileRadius'], f.headerTileRadius),
        headerTileMark: Ds._num(m['headerTileMark'], f.headerTileMark),
        headerTop: Ds._num(m['headerTop'], f.headerTop),
        headerWord: Ds._num(m['headerWord'], f.headerWord),
        headerWordGap: Ds._num(m['headerWordGap'], f.headerWordGap),
        headerGap: Ds._num(m['headerGap'], f.headerGap),
        headerPill: Ds._num(m['headerPill'], f.headerPill),
        headerPillText: Ds._num(m['headerPillText'], f.headerPillText),
      );
}

/// CMD #2173 — the brand lock-up, entirely as backend answers.
///
/// The header owns no logo. `app_settings 'brand.logo'` rides in on
/// `ui_boot().design.header.logo` and says what the 40dp tile and the
/// wordmark draw: an uploaded image when a URL is set, otherwise the letter
/// and the two words in their own colours. Swapping the logo, recolouring the
/// wordmark or renaming the app is an UPDATE to that row — the next reload
/// carries it, with no deploy and no app asset.
class DsBrandLogo {
  /// The tile image. Empty = draw [letter] on [tileBg] instead.
  final String tileUrl;

  /// The wordmark image. Empty = draw [word1] + [word2] instead.
  final String wordmarkUrl;

  /// The mark inside the tile when there is no [tileUrl].
  final String letter;

  /// The tile's own fill and the letter's colour.
  final Color tileBg, tileFg;

  /// The two halves of the wordmark, and the colour of each.
  final String word1, word2;
  final Color word1Fg, word2Fg;

  const DsBrandLogo({
    required this.tileUrl,
    required this.wordmarkUrl,
    required this.letter,
    required this.tileBg,
    required this.tileFg,
    required this.word1,
    required this.word1Fg,
    required this.word2,
    required this.word2Fg,
  });

  /// What the very first frame draws, before the payload lands.
  static const DsBrandLogo fallback = DsBrandLogo(
    tileUrl: '',
    wordmarkUrl: '',
    letter: 'm',
    tileBg: Color(0xFF1B8A3E),
    tileFg: Color(0xFFFFFFFF),
    word1: 'medi',
    word1Fg: Color(0xFF1B7A43),
    word2: 'BO',
    word2Fg: Color(0xFF2FA24F),
  );

  /// True while the tile should draw [tileUrl] rather than [letter].
  bool get hasTileImage => tileUrl.trim().isNotEmpty;

  /// True while the wordmark should draw [wordmarkUrl] rather than the words.
  bool get hasWordmarkImage => wordmarkUrl.trim().isNotEmpty;

  static String _str(Object? v, String fallback) =>
      v is String && v.trim().isNotEmpty ? v.trim() : fallback;

  factory DsBrandLogo.from(Object? raw, DsBrandLogo f) {
    if (raw is! Map) return f;
    return DsBrandLogo(
      tileUrl: _str(raw['tile_url'], ''),
      wordmarkUrl: _str(raw['wordmark_url'], ''),
      letter: _str(raw['letter'], f.letter),
      tileBg: Ds.hex(raw['tile_bg'], f.tileBg),
      tileFg: Ds.hex(raw['tile_fg'], f.tileFg),
      word1: _str(raw['word_1'], f.word1),
      word1Fg: Ds.hex(raw['word_1_fg'], f.word1Fg),
      word2: _str(raw['word_2'], f.word2),
      word2Fg: Ds.hex(raw['word_2_fg'], f.word2Fg),
    );
  }
}

/// CMD #2164 — the customer header's redline, the numbers and colours that
/// have no general token. Backend key `design.header`; every field is one
/// `ui_design_set` away.
class DsHeader {
  final Color tile, wordMedi, wordBo, line, placeholder;
  final double wordNarrow, narrowBelow, wordSpacing, markWeight, wordWeight;
  final double pillRadius, search, searchRadius, searchCompactRadius;
  final double searchBorderWidth, searchText, searchIcon, searchPad, iconGap;
  final double bellIcon, lineWidth, fadeMs;

  /// CMD #2173 — the brand lock-up itself: which image (if any) the tile and
  /// the wordmark draw, and the letter/words/colours they fall back to.
  /// Backend key `design.header.logo`, read live from app_settings
  /// 'brand.logo' — a new logo is an UPDATE, never a deploy.
  final DsBrandLogo logo;

  const DsHeader({
    required this.logo,
    required this.tile,
    required this.wordMedi,
    required this.wordBo,
    required this.line,
    required this.placeholder,
    required this.wordNarrow,
    required this.narrowBelow,
    required this.wordSpacing,
    required this.markWeight,
    required this.wordWeight,
    required this.pillRadius,
    required this.search,
    required this.searchRadius,
    required this.searchCompactRadius,
    required this.searchBorderWidth,
    required this.searchText,
    required this.searchIcon,
    required this.searchPad,
    required this.iconGap,
    required this.bellIcon,
    required this.lineWidth,
    required this.fadeMs,
  });

  factory DsHeader._defaults() => DsHeader(
        logo: DsBrandLogo.fallback,
        tile: const Color(0xFF1B8A3E),
        wordMedi: Color(0xFF1B7A43),
        wordBo: Color(0xFF2FA24F),
        line: Color(0xFFEEF0EE),
        placeholder: Color(0xFF6B7280),
        wordNarrow: 22,
        narrowBelow: 360,
        wordSpacing: -0.4,
        markWeight: 900,
        wordWeight: 800,
        // CMD #2175 (Om, on #1523) — half the pill's own 40, so it is the
        // same full-radius shape as the search box's 20.
        pillRadius: 20,
        search: 48,
        searchRadius: 24,
        searchCompactRadius: 20,
        searchBorderWidth: 1.5,
        searchText: 16,
        searchIcon: 22,
        searchPad: 16,
        iconGap: 12,
        bellIcon: 24,
        lineWidth: 1,
        fadeMs: 200,
      );

  factory DsHeader._from(Map m, DsHeader f) => DsHeader(
        logo: DsBrandLogo.from(m['logo'], f.logo),
        tile: Ds.hex(m['tile'], f.tile),
        wordMedi: Ds.hex(m['wordMedi'], f.wordMedi),
        wordBo: Ds.hex(m['wordBo'], f.wordBo),
        line: Ds.hex(m['line'], f.line),
        placeholder: Ds.hex(m['placeholder'], f.placeholder),
        wordNarrow: Ds._num(m['wordNarrow'], f.wordNarrow),
        narrowBelow: Ds._num(m['narrowBelow'], f.narrowBelow),
        wordSpacing: Ds._num(m['wordSpacing'], f.wordSpacing),
        markWeight: Ds._num(m['markWeight'], f.markWeight),
        wordWeight: Ds._num(m['wordWeight'], f.wordWeight),
        pillRadius: Ds._num(m['pillRadius'], f.pillRadius),
        search: Ds._num(m['search'], f.search),
        searchRadius: Ds._num(m['searchRadius'], f.searchRadius),
        searchCompactRadius:
            Ds._num(m['searchCompactRadius'], f.searchCompactRadius),
        searchBorderWidth:
            Ds._num(m['searchBorderWidth'], f.searchBorderWidth),
        searchText: Ds._num(m['searchText'], f.searchText),
        searchIcon: Ds._num(m['searchIcon'], f.searchIcon),
        searchPad: Ds._num(m['searchPad'], f.searchPad),
        iconGap: Ds._num(m['iconGap'], f.iconGap),
        bellIcon: Ds._num(m['bellIcon'], f.bellIcon),
        lineWidth: Ds._num(m['lineWidth'], f.lineWidth),
        fadeMs: Ds._num(m['fadeMs'], f.fadeMs),
      );

  /// A 100..900 weight token as a [FontWeight].
  static FontWeight weight(double w) =>
      FontWeight.values[((w / 100).round() - 1).clamp(0, 8)];

  /// The wordmark size for a viewport: [wordNarrow] only below [narrowBelow].
  double wordFor(double width) =>
      width < narrowBelow ? wordNarrow : Ds.touch.headerWord;
}

/// CMD #2170 — the pull-down-to-close gesture, entirely as backend answers.
///
/// Nothing here is a taste the app holds: how far a pull must go, how fast a
/// flick counts, how long the spring back and the close take, how round the
/// top corners get on the way out, how dark the screen behind goes, which
/// routes may be closed this way at all and which tab roots pull back to Home
/// are all decided by `ui_boot().design.pull_close`. These values are only
/// what the first frame uses before that payload lands — re-tuning the gesture
/// is `ui_design_set({"pull_close":{...}})`, never a deploy.
class DsPullClose {
  /// Master switch — false and every route keeps the platform transition.
  final bool enabled;

  /// Past this much pull (logical px) the page closes.
  final double thresholdDp;

  /// …or at this downward speed (px/s), however short the pull was.
  final double flingDps;

  /// How far the finger must travel downward before the gesture is taken off
  /// the list underneath. Below this, scrolling is untouched.
  final double slopDp;

  /// 1.0 = the page tracks the finger exactly.
  final double follow;

  /// The page's top corner radius at full pull.
  final double cornerDp;

  /// How small the page gets at full pull.
  final double scaleMin;

  /// The dim layer over the screen behind: colour and its opacity at rest.
  final Color scrim;
  final double scrimOpacity;

  /// A short pull springs back in this; a committed close (and every push)
  /// takes this.
  final int springMs, closeMs;

  /// The tab a tab-root pull lands on, and the tab indices that do it.
  final int homeIndex;
  final List<int> tabPages;

  /// Route prefixes that keep the platform transition (staff/admin, auth).
  final List<String> denyPrefixes;

  /// The gesture's spoken hint, verbatim.
  final String hint;

  const DsPullClose({
    required this.enabled,
    required this.thresholdDp,
    required this.flingDps,
    required this.slopDp,
    required this.follow,
    required this.cornerDp,
    required this.scaleMin,
    required this.scrim,
    required this.scrimOpacity,
    required this.springMs,
    required this.closeMs,
    required this.homeIndex,
    required this.tabPages,
    required this.denyPrefixes,
    required this.hint,
  });

  factory DsPullClose._defaults() => const DsPullClose(
        enabled: true,
        thresholdDp: 120,
        flingDps: 700,
        slopDp: 8,
        follow: 1.0,
        cornerDp: 24,
        scaleMin: 0.92,
        scrim: Color(0xFF000000),
        scrimOpacity: 0.45,
        springMs: 200,
        closeMs: 250,
        homeIndex: 0,
        tabPages: <int>[1, 2, 12, 15],
        denyPrefixes: <String>[
          '/admin', '/partner', '/supplier', '/staff', '/dev',
          '/login', '/register', '/signup',
        ],
        hint: 'Pull down to close',
      );

  factory DsPullClose._from(Map m, DsPullClose f) => DsPullClose(
        enabled: m['enabled'] is bool ? m['enabled'] as bool : f.enabled,
        thresholdDp: Ds._num(m['threshold_dp'], f.thresholdDp),
        flingDps: Ds._num(m['fling_dps'], f.flingDps),
        slopDp: Ds._num(m['slop_dp'], f.slopDp),
        follow: Ds._num(m['follow'], f.follow),
        cornerDp: Ds._num(m['corner_dp'], f.cornerDp),
        scaleMin: Ds._num(m['scale_min'], f.scaleMin),
        scrim: Ds.hex(m['scrim'], f.scrim),
        scrimOpacity: Ds._num(m['scrim_opacity'], f.scrimOpacity),
        springMs: Ds._num(m['spring_ms'], f.springMs.toDouble()).round(),
        closeMs: Ds._num(m['close_ms'], f.closeMs.toDouble()).round(),
        homeIndex: Ds._num(m['home_index'], f.homeIndex.toDouble()).round(),
        tabPages: _ints(m['tab_pages'], f.tabPages),
        denyPrefixes: _strings(m['deny_prefixes'], f.denyPrefixes),
        hint: m['hint'] is String ? m['hint'] as String : f.hint,
      );

  static List<int> _ints(Object? v, List<int> f) {
    if (v is! List) return f;
    final out = <int>[for (final e in v) if (e is num) e.toInt()];
    return out.isEmpty ? f : out;
  }

  static List<String> _strings(Object? v, List<String> f) {
    if (v is! List) return f;
    return <String>[for (final e in v) if (e is String && e.isNotEmpty) e];
  }

  Duration get spring => Duration(milliseconds: springMs);
  Duration get close => Duration(milliseconds: closeMs);

  /// Whether a pushed route named [name] takes the gesture. The backend's deny
  /// list is the whole rule; the app adds no screens of its own.
  bool allowsRoute(String? name) {
    if (!enabled) return false;
    final n = (name ?? '').split('?').first;
    for (final p in denyPrefixes) {
      if (n == p || n.startsWith(p)) return false;
    }
    return true;
  }

  /// Whether the shell tab at [index] pulls back to the Home tab.
  bool pullsHome(int index) => enabled && index != homeIndex && tabPages.contains(index);
}

/// CMD #2175 — the shell's common geometry, from `shell_style().common`.
///
/// Om, on #1521: "56 dp is the TOTAL of each row measured outside edge to
/// outside edge, GAPS INCLUDED." So [height] is the ROW, not the box inside
/// it: the search row is [padY] + [boxHeight] + [padY] = [height], which is
/// why the search box is 40 (the logo tile's own size, so the two read as one
/// optical line) rather than 56 (which looked fat beside it).
class DsShell {
  final double height, inset, radius, gap, boxHeight, padY, boxRadius;

  /// Where the typed word and the hint sit inside the box, as the backend's
  /// own word ('center' / 'top' / 'bottom'). Om, on #1521: "the hint and the
  /// leading icon sit on the true vertical centre of the box". It is a TOKEN
  /// rather than a constant in the field because the rule is the backend's —
  /// retuning the box's height and where its text sits must stay one UPDATE.
  final String textAlignV;

  const DsShell._({
    required this.height,
    required this.inset,
    required this.radius,
    required this.gap,
    required this.boxHeight,
    required this.padY,
    required this.boxRadius,
    required this.textAlignV,
  });

  /// [textAlignV] as Flutter's own value. Anything the backend has not named
  /// falls back to the centre, which is the redline.
  TextAlignVertical get textAlign {
    switch (textAlignV) {
      case 'top':
        return TextAlignVertical.top;
      case 'bottom':
        return TextAlignVertical.bottom;
      default:
        return TextAlignVertical.center;
    }
  }

  /// Om's redline, and the fallback if the payload never arrives.
  factory DsShell._defaults() => const DsShell._(
        height: 56,
        inset: 14,
        radius: 28,
        gap: 10,
        boxHeight: 40,
        padY: 8,
        boxRadius: 20,
        textAlignV: 'center',
      );

  factory DsShell._from(Map m, DsShell f) => DsShell._(
        height: Ds._num(m['height'], f.height),
        inset: Ds._num(m['inset'], f.inset),
        radius: Ds._num(m['radius'], f.radius),
        gap: Ds._num(m['gap'], f.gap),
        boxHeight: Ds._num(m['box_h'], f.boxHeight),
        padY: Ds._num(m['pad_y'], f.padY),
        boxRadius: Ds._num(m['box_radius'], f.boxRadius),
        textAlignV: (m['text_align_v'] ?? f.textAlignV).toString(),
      );
}
