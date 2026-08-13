import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// CHANGE #673 — the storefront design system.
///
/// The old palette was one mid-tone green on white. Nothing was ever dark and
/// nothing was ever vivid, so every screen sat in the same narrow tonal band
/// and read as flat. The fix is the pairing every modern storefront uses: a
/// DARK brand block to anchor the page, a VIVID accent that only ever means
/// "act on this", and soft tinted bands so sections stop being one white sheet.
///
/// Type is DM Sans with the negative tracking a display font needs at large
/// sizes. Roboto at 0 tracking was the other half of the flat look.
///
/// These are DEFAULTS, not authority. Anything the backend sends a colour or a
/// string for wins — see `storefront_theme()`. This file exists so the first
/// frame has something to paint before that payload lands, and so a colour is
/// named once instead of being retyped as a hex literal in forty widgets.
class Brand {
  // ── The dark anchor ───────────────────────────────────────────────────────
  /// Header block, ribbons, footer. The page's gravity.
  static const Color deep = Color(0xFF06392A);
  static const Color deepAlt = Color(0xFF0A4F39); // gradient partner
  static const Color deepSoft = Color(0xFF12684A); // dark-on-dark dividers

  // ── The action accent ─────────────────────────────────────────────────────
  /// Reserved for action: ADD, cart pill, active nav, savings. Never decoration.
  ///
  /// #673 shipped this as orange. The brand is white / black / green only, so
  /// the accent is the brand green — it still reads as "act on this" because
  /// nothing else on a white card is saturated. Defaults only; the backend's
  /// `storefront_theme` accent row wins.
  static const Color accent = Color(0xFF12874F);
  static const Color accentDark = Color(0xFF0A4F39);
  static const Color accentSoft = Color(0xFFE8F6EF);

  // ── Trust green (kept: the whole app already reads these) ─────────────────
  static const Color green = Color(0xFF12874F); // primary action / logo
  static const Color greenDark = Color(0xFF0A4F39); // hero & footer bg
  static const Color greenDarker = Color(0xFF06392A); // gradient end
  static const Color mint = Color(0xFFE8F6EF); // light tint / chips
  static const Color price = Color(0xFF0F172B); // price text — ink, not green
  static const Color amber = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFDC2626);

  // ── Ink ───────────────────────────────────────────────────────────────────
  static const Color ink = Color(0xFF0F172B); // headings, price
  static const Color inkSub = Color(0xFF45556C); // body
  static const Color inkMuted = Color(0xFF62748E); // captions, eyebrows
  static const Color inkFaint = Color(0xFF90A1B9); // struck MRP

  // ── Surfaces ──────────────────────────────────────────────────────────────
  static const Color border = Color(0xFFE2E8F0); // hairline
  static const Color borderSoft = Color(0xFFF1F5F9);
  static const Color section = Color(0xFFF8FAFC); // alt section bg
  static const Color field = Color(0xFFF1F5F9); // input fill
  static const Color tile = Color(0xFFF8FAFC); // product image plate

  // ── Semantic chips ────────────────────────────────────────────────────────
  static const Color positiveBg = Color(0xFFECFDF5);
  static const Color positiveLine = Color(0xFF34D399);
  static const Color positiveFg = Color(0xFF047857);
  static const Color negativeBg = Color(0xFFFFE4E6);
  static const Color negativeFg = Color(0xFFC1121F);

  /// Section bands. A feed of white sections is the single biggest reason a
  /// page reads as dated; these give each block its own ground. The backend
  /// names which band a section wears — this list is only the fallback cycle.
  static const List<Color> bands = [
    Color(0xFFEAF6F0), // mint
    Color(0xFFFFF3EA), // peach
    Color(0xFFEAF4FB), // sky
    Color(0xFFF1EFFC), // lilac
    Color(0xFFFDEFF4), // blush
    Color(0xFFFDF7E7), // sand
  ];

  /// Parses a backend `#RRGGBB` / `#AARRGGBB` string. Returns [fallback] for
  /// anything it cannot read, so a bad colour row can never white-screen a
  /// page — it just looks like the default.
  static Color hex(Object? raw, Color fallback) {
    if (raw is! String) return fallback;
    var s = raw.trim().replaceFirst('#', '');
    if (s.length == 6) s = 'FF$s';
    if (s.length != 8) return fallback;
    final v = int.tryParse(s, radix: 16);
    return v == null ? fallback : Color(v);
  }
}

/// Geometry, named once. Every radius and gap in the storefront comes from
/// here so "make the cards rounder" is one edit, not forty.
class Rad {
  static const double chip = 6;
  static const double pill = 999;
  static const double card = 14;
  static const double tile = 12;
  static const double sheet = 20;
  static const double band = 24;
}

/// The type scale, measured from the reference storefront and set in DM Sans.
///
/// Two things here do most of the visual work:
///  * REAL size contrast — a 24px w800 section title against an 11px eyebrow,
///    instead of everything living between 12 and 20 at w600.
///  * NEGATIVE tracking that grows with size. Display text set at 0 tracking
///    is the tell of a default theme; -0.5px at 24px is what makes a heading
///    look typeset rather than printed.
class AppType {
  static const String family = 'DMSans';

  static const TextStyle h4 = TextStyle(
      fontSize: 27, height: 32 / 27, fontWeight: FontWeight.w800, letterSpacing: -0.6, color: Brand.ink);
  static const TextStyle h3 = TextStyle(
      fontSize: 24, height: 30 / 24, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: Brand.ink);
  static const TextStyle h2 = TextStyle(
      fontSize: 22, height: 28 / 22, fontWeight: FontWeight.w700, letterSpacing: -0.45, color: Brand.ink);
  static const TextStyle h1 = TextStyle(
      fontSize: 20, height: 26 / 20, fontWeight: FontWeight.w700, letterSpacing: -0.4, color: Brand.ink);

  static const TextStyle l1 = TextStyle(
      fontSize: 18, height: 24 / 18, fontWeight: FontWeight.w700, letterSpacing: -0.35, color: Brand.ink);
  static const TextStyle l2 = TextStyle(
      fontSize: 16, height: 22 / 16, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: Brand.ink);
  static const TextStyle l3 = TextStyle(
      fontSize: 15, height: 20 / 15, fontWeight: FontWeight.w700, letterSpacing: -0.3, color: Brand.ink);
  static const TextStyle l4 = TextStyle(
      fontSize: 14, height: 18 / 14, fontWeight: FontWeight.w600, letterSpacing: -0.25, color: Brand.ink);
  static const TextStyle l5 = TextStyle(
      fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w600, letterSpacing: -0.2, color: Brand.ink);

  static const TextStyle b1 = TextStyle(
      fontSize: 15, height: 22 / 15, fontWeight: FontWeight.w400, letterSpacing: -0.4, color: Brand.inkSub);
  static const TextStyle b2 = TextStyle(
      fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w400, letterSpacing: -0.3, color: Brand.inkSub);
  static const TextStyle b3 = TextStyle(
      fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w400, letterSpacing: -0.2, color: Brand.inkMuted);

  static const TextStyle t1 = TextStyle(
      fontSize: 11, height: 14 / 11, fontWeight: FontWeight.w500, letterSpacing: -0.1, color: Brand.inkMuted);
  static const TextStyle t2 = TextStyle(
      fontSize: 10, height: 13 / 10, fontWeight: FontWeight.w600, color: Brand.inkMuted);
  static const TextStyle t3 = TextStyle(
      fontSize: 9, height: 12 / 9, fontWeight: FontWeight.w800, letterSpacing: 0.2, color: Colors.white);

  /// The small-caps line above a section title. Wide tracking is the whole
  /// effect — at 0 it is just small grey text.
  static const TextStyle eyebrow = TextStyle(
      fontSize: 11, height: 14 / 11, fontWeight: FontWeight.w600, letterSpacing: 1.6, color: Brand.inkMuted);
}

/// Visual style for a product's image plate + category tile, keyed by the
/// catalog category. We have no product photos for much of the catalog, so
/// each category gets a tinted plate and an icon — that tint is also what
/// makes a grid of missing images look designed instead of broken.
class CategoryStyle {
  final Color bg;
  final Color fg;
  final IconData icon;
  const CategoryStyle(this.bg, this.fg, this.icon);
}

// Keyed by the raw therapeutic_class values stored in the catalog (uppercase).
// A few legacy title-case keys are kept so older data still maps.
const Map<String, CategoryStyle> _categoryStyles = {
  'CARDIAC': CategoryStyle(Color(0xFFFFE9EC), Color(0xFFE11D48), Icons.favorite_rounded),
  'GASTRO INTESTINAL': CategoryStyle(Color(0xFFFDE9F3), Color(0xFFDB2777), Icons.restaurant_rounded),
  'ANTI INFECTIVES': CategoryStyle(Color(0xFFE7F0FF), Color(0xFF2563EB), Icons.coronavirus_rounded),
  'NEURO CNS': CategoryStyle(Color(0xFFEDEBFF), Color(0xFF4F46E5), Icons.psychology_rounded),
  'PAIN ANALGESICS': CategoryStyle(Color(0xFFFFF0E4), Color(0xFFEA580C), Icons.healing_rounded),
  'RESPIRATORY': CategoryStyle(Color(0xFFE4F8F0), Color(0xFF059669), Icons.air_rounded),
  'ANTI DIABETIC': CategoryStyle(Color(0xFFFFE7E7), Color(0xFFDC2626), Icons.water_drop_rounded),
  'DERMA': CategoryStyle(Color(0xFFFFEFF6), Color(0xFFDB2777), Icons.spa_rounded),
  'VITAMINS MINERALS NUTRIENTS': CategoryStyle(Color(0xFFFFF6D6), Color(0xFFB45309), Icons.eco_rounded),
  'OPHTHAL': CategoryStyle(Color(0xFFDEF6FA), Color(0xFF0891B2), Icons.visibility_rounded),
  'GYNAECOLOGICAL': CategoryStyle(Color(0xFFFDE9F3), Color(0xFFC026D3), Icons.pregnant_woman_rounded),
  'UROLOGY': CategoryStyle(Color(0xFFE4F2FF), Color(0xFF0369A1), Icons.wc_rounded),
  'ANTI NEOPLASTICS': CategoryStyle(Color(0xFFF4E8FF), Color(0xFF7C3AED), Icons.biotech_rounded),
  'HORMONES': CategoryStyle(Color(0xFFE4F8F0), Color(0xFF0D9488), Icons.science_rounded),
  'BLOOD RELATED': CategoryStyle(Color(0xFFFFE9EC), Color(0xFFB91C1C), Icons.bloodtype_rounded),
  'SEX STIMULANTS REJUVENATORS': CategoryStyle(Color(0xFFFDE6F2), Color(0xFFDB2777), Icons.favorite_border_rounded),
  'OPHTHAL OTOLOGICALS': CategoryStyle(Color(0xFFDEF6FA), Color(0xFF0E7490), Icons.hearing_rounded),
  'VACCINES': CategoryStyle(Color(0xFFE4F6EC), Color(0xFF16A34A), Icons.vaccines_rounded),
  'OTHERS': CategoryStyle(Color(0xFFEEF1F5), Color(0xFF64748B), Icons.category_rounded),
  'OTOLOGICALS': CategoryStyle(Color(0xFFDEF6FA), Color(0xFF0891B2), Icons.hearing_rounded),
  'STOMATOLOGICALS': CategoryStyle(Color(0xFFE7F0FF), Color(0xFF2563EB), Icons.medical_services_rounded),
  'ANTI MALARIALS': CategoryStyle(Color(0xFFEEF6DE), Color(0xFF4D7C0F), Icons.pest_control_rounded),
};

const CategoryStyle _fallbackStyle =
    CategoryStyle(Brand.mint, Brand.green, Icons.medication_rounded);

CategoryStyle categoryStyle(String category) =>
    _categoryStyles[category.toUpperCase()] ?? _fallbackStyle;

/// CHANGE #66 — the theme is now built from backend design tokens (`Ds`), not
/// from hard-coded literals. `ui_boot().design` lands, `Ds.apply()` sets the
/// tokens, `UiCopy.revision` bumps, MaterialApp rebuilds and calls this again
/// with the new values. Change one token (`ui_design_set`) and every
/// theme-driven surface recolours on the next boot with zero code change.
ThemeData buildTheme() {
  final ds = Ds.c;
  final scheme = ColorScheme.fromSeed(
    seedColor: ds.brand,
    brightness: Brightness.light,
  ).copyWith(
    primary: ds.brand,
    onPrimary: Colors.white,
    primaryContainer: ds.brandSoft,
    onPrimaryContainer: ds.brandDark,
    secondary: ds.brand,
    onSecondary: Colors.white,
    surface: ds.surface,
    onSurface: ds.text,
    error: ds.danger,
  );

  const pageTransitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
    },
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: ds.bg,
    fontFamily: AppType.family,
    pageTransitionsTheme: pageTransitions,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
  );

  OutlinedBorder rounded(double r) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

  // The scale above, mapped onto Material's slots so any widget that reads
  // the ambient theme (dialogs, menus, list tiles) inherits it too.
  final text = base.textTheme
      .copyWith(
        displaySmall: AppType.h4,
        headlineMedium: AppType.h3,
        headlineSmall: AppType.h2,
        titleLarge: AppType.h1,
        titleMedium: AppType.l2,
        titleSmall: AppType.l4,
        bodyLarge: AppType.b1,
        bodyMedium: AppType.b2,
        bodySmall: AppType.b3,
        labelLarge: AppType.l4,
        labelMedium: AppType.l5,
        labelSmall: AppType.t1,
      )
      .apply(
        bodyColor: ds.text,
        displayColor: ds.text,
        // Explicitly clear any stray text decoration inherited from the
        // Material 3 base theme — prevents yellow underline on canvas text.
        decoration: TextDecoration.none,
        decorationColor: Colors.transparent,
      );

  return base.copyWith(
    textTheme: text,
    dividerTheme: DividerThemeData(color: ds.divider, thickness: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      color: ds.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: Ds.r.rCard,
        side: BorderSide(color: ds.divider),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ds.brand,
        foregroundColor: Colors.white,
        elevation: 0,
        minimumSize: Size(0, Ds.touch.minTarget + 4),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        textStyle: AppType.l3.copyWith(color: Colors.white),
        shape: rounded(Ds.r.button),
      ).copyWith(
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ds.brand,
        side: BorderSide(color: ds.brand, width: 1.4),
        minimumSize: Size(0, Ds.touch.minTarget + 4),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: AppType.l3.copyWith(color: ds.brand),
        shape: rounded(Ds.r.button),
      ).copyWith(
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: ds.brandSoft,
      selectedColor: ds.brand,
      side: BorderSide(color: ds.divider),
      labelStyle: AppType.l5,
      shape: rounded(Ds.r.chip),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ds.bg,
      hintStyle: AppType.b2.copyWith(color: ds.textSecondary),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Rad.pill),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Rad.pill),
        borderSide: BorderSide.none,
      ),
      // No green border while typing: focus matches the unfocused state so the
      // input never flashes a coloured outline on focus (Om, CHANGE #25).
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Rad.pill),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    // Suppress yellow underlines that can bleed through on Flutter web CanvasKit.
    listTileTheme: const ListTileThemeData(
      titleTextStyle: TextStyle(decoration: TextDecoration.none, decorationColor: Color(0x00000000)),
      subtitleTextStyle: TextStyle(decoration: TextDecoration.none, decorationColor: Color(0x00000000)),
      leadingAndTrailingTextStyle: TextStyle(decoration: TextDecoration.none, decorationColor: Color(0x00000000)),
    ),
  );
}
