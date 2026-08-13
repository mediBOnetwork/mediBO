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
  static DsRadius r = DsRadius._defaults();
  static DsType t = DsType._defaults();
  static DsSpace space = DsSpace._defaults();
  static DsElevation elevation = DsElevation._defaults();
  static DsMotion motion = DsMotion._defaults();
  static DsTouch touch = DsTouch._defaults();

  /// The brand hex currently in force — mirrored to the render-log so a
  /// headless verifier can PROVE the app consumed a recolour token.
  static String brandHex = '#1B873F';

  /// Overwrite every token from the backend `design` block. Missing keys keep
  /// their current value, so a partial patch never blanks the theme.
  static void apply(Object? design) {
    if (design is! Map) return;
    c = DsColors._from(_asMap(design['colors']), c);
    r = DsRadius._from(_asMap(design['radius']), r);
    t = DsType._from(_asMap(design['type']), t);
    space = DsSpace._from(design['spacing'], space);
    elevation = DsElevation._from(_asMap(design['elevation']), elevation);
    motion = DsMotion._from(_asMap(design['motion']), motion);
    touch = DsTouch._from(_asMap(design['touch']), touch);
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
  TextStyle get caption => _style(captionSize, captionWeight, Ds.c.textSecondary);
}

/// Two elevation levels → ready-to-use BoxShadow lists.
class DsElevation {
  final double e1x, e1y, e1blur, e1alpha;
  final double e2x, e2y, e2blur, e2alpha;
  const DsElevation({
    required this.e1x, required this.e1y, required this.e1blur, required this.e1alpha,
    required this.e2x, required this.e2y, required this.e2blur, required this.e2alpha,
  });
  factory DsElevation._defaults() => const DsElevation(
        e1x: 0, e1y: 1, e1blur: 3, e1alpha: 0.06,
        e2x: 0, e2y: 4, e2blur: 12, e2alpha: 0.08,
      );
  factory DsElevation._from(Map m, DsElevation f) {
    Map g(String k) => m[k] is Map ? m[k] as Map : const {};
    final a = g('e1'), b = g('e2');
    return DsElevation(
      e1x: Ds._num(a['x'], f.e1x), e1y: Ds._num(a['y'], f.e1y),
      e1blur: Ds._num(a['blur'], f.e1blur), e1alpha: Ds._num(a['alpha'], f.e1alpha),
      e2x: Ds._num(b['x'], f.e2x), e2y: Ds._num(b['y'], f.e2y),
      e2blur: Ds._num(b['blur'], f.e2blur), e2alpha: Ds._num(b['alpha'], f.e2alpha),
    );
  }
  List<BoxShadow> get e1 => [
        BoxShadow(color: const Color(0xFF000000).withValues(alpha: e1alpha), offset: Offset(e1x, e1y), blurRadius: e1blur),
      ];
  List<BoxShadow> get e2 => [
        BoxShadow(color: const Color(0xFF000000).withValues(alpha: e2alpha), offset: Offset(e2x, e2y), blurRadius: e2blur),
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
  const DsTouch({required this.minTarget, required this.listRowMinHeight});
  factory DsTouch._defaults() => const DsTouch(minTarget: 44, listRowMinHeight: 56);
  factory DsTouch._from(Map m, DsTouch f) => DsTouch(
        minTarget: Ds._num(m['minTarget'], f.minTarget),
        listRowMinHeight: Ds._num(m['listRowMinHeight'], f.listRowMinHeight),
      );
}
