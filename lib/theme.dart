import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Brand palette mirroring the mediBO reference storefront
/// (emerald primary, dark-green hero/footer, mint tints).
class Brand {
  static const Color green = Color(0xFF16A34A); // primary action / logo
  static const Color greenDark = Color(0xFF0F4C35); // hero & footer bg
  static const Color greenDarker = Color(0xFF0A3527); // gradient end
  static const Color mint = Color(0xFFE7F6EE); // light tint / chips
  static const Color price = Color(0xFF15803D); // price text
  static const Color amber = Color(0xFFF59E0B); // rating stars
  static const Color danger = Color(0xFFDC2626); // Rx / discount accents

  static const Color ink = Color(0xFF1F2A37); // primary text
  static const Color inkMuted = Color(0xFF6B7280); // secondary text
  static const Color border = Color(0xFFE5E7EB); // hairline borders
  static const Color section = Color(0xFFF6F8FA); // alt section bg
  static const Color field = Color(0xFFF1F3F5); // input fill
}

/// Visual style for a product's "image" block + category tile, keyed by the
/// catalog category. We have no product photos in the DB, so each category
/// gets a soft pastel block + an icon, matching the reference card rhythm.
class CategoryStyle {
  final Color bg;
  final Color fg;
  final IconData icon;
  const CategoryStyle(this.bg, this.fg, this.icon);
}

// Keyed by the raw therapeutic_class values stored in the catalog (uppercase).
// A few legacy title-case keys are kept so older data still maps.
const Map<String, CategoryStyle> _categoryStyles = {
  'CARDIAC': CategoryStyle(Color(0xFFFFEAEC), Color(0xFFE11D48), Icons.favorite),
  'GASTRO INTESTINAL': CategoryStyle(Color(0xFFFDEAF4), Color(0xFFDB2777), Icons.local_dining),
  'ANTI INFECTIVES': CategoryStyle(Color(0xFFE8F1FF), Color(0xFF2563EB), Icons.coronavirus),
  'NEURO CNS': CategoryStyle(Color(0xFFECEBFF), Color(0xFF4F46E5), Icons.psychology),
  'PAIN ANALGESICS': CategoryStyle(Color(0xFFFFF1E6), Color(0xFFEA7317), Icons.healing),
  'RESPIRATORY': CategoryStyle(Color(0xFFE7F9F1), Color(0xFF059669), Icons.air),
  'ANTI DIABETIC': CategoryStyle(Color(0xFFFFE9E9), Color(0xFFDC2626), Icons.water_drop),
  'DERMA': CategoryStyle(Color(0xFFFFF0F6), Color(0xFFDB2777), Icons.spa),
  'VITAMINS MINERALS NUTRIENTS': CategoryStyle(Color(0xFFFFF7DB), Color(0xFFB45309), Icons.eco),
  'OPHTHAL': CategoryStyle(Color(0xFFE0F7FA), Color(0xFF0891B2), Icons.visibility),
  'GYNAECOLOGICAL': CategoryStyle(Color(0xFFFDEAF4), Color(0xFFC026D3), Icons.pregnant_woman),
  'UROLOGY': CategoryStyle(Color(0xFFE6F4FF), Color(0xFF0369A1), Icons.wc),
  'ANTI NEOPLASTICS': CategoryStyle(Color(0xFFF3E8FF), Color(0xFF7C3AED), Icons.biotech),
  'HORMONES': CategoryStyle(Color(0xFFE7F9F1), Color(0xFF0D9488), Icons.science),
  'BLOOD RELATED': CategoryStyle(Color(0xFFFFEAEC), Color(0xFFB91C1C), Icons.bloodtype),
  'SEX STIMULANTS REJUVENATORS': CategoryStyle(Color(0xFFFDE7F3), Color(0xFFDB2777), Icons.favorite_border),
  'OPHTHAL OTOLOGICALS': CategoryStyle(Color(0xFFE0F7FA), Color(0xFF0E7490), Icons.hearing),
  'VACCINES': CategoryStyle(Color(0xFFE7F6EE), Color(0xFF16A34A), Icons.vaccines),
  'OTHERS': CategoryStyle(Color(0xFFEEF1F4), Color(0xFF64748B), Icons.category),
  'OTOLOGICALS': CategoryStyle(Color(0xFFE0F7FA), Color(0xFF0891B2), Icons.hearing),
  'STOMATOLOGICALS': CategoryStyle(Color(0xFFE8F1FF), Color(0xFF2563EB), Icons.medical_services),
  'ANTI MALARIALS': CategoryStyle(Color(0xFFEFF6E0), Color(0xFF4D7C0F), Icons.pest_control),
};

const CategoryStyle _fallbackStyle =
    CategoryStyle(Brand.mint, Brand.green, Icons.medication);

CategoryStyle categoryStyle(String category) =>
    _categoryStyles[category.toUpperCase()] ?? _fallbackStyle;

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.green,
    brightness: Brightness.light,
  ).copyWith(
    primary: Brand.green,
    onPrimary: Colors.white,
    primaryContainer: Brand.mint,
    onPrimaryContainer: Brand.greenDark,
    surface: Colors.white,
    onSurface: Brand.ink,
    error: Brand.danger,
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
    scaffoldBackgroundColor: Colors.white,
    fontFamily: 'Roboto',
    pageTransitionsTheme: pageTransitions,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
  );

  OutlinedBorder rounded(double r) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r));

  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: Brand.ink,
      displayColor: Brand.ink,
    ),
    dividerTheme: const DividerThemeData(color: Brand.border, thickness: 1),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Brand.border),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Brand.green,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        shape: rounded(10),
      ).copyWith(
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Brand.green,
        side: const BorderSide(color: Brand.green),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        shape: rounded(10),
      ).copyWith(
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Brand.section,
      selectedColor: Brand.green,
      side: const BorderSide(color: Brand.border),
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      shape: rounded(20),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Brand.field,
      hintStyle: const TextStyle(color: Brand.inkMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Brand.green, width: 1.5),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
