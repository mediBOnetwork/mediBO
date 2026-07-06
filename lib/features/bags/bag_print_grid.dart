import 'dart:math' as math;
import 'package:pdf/pdf.dart';

/// Pure pagination/grid/fit math for Bags PDF printing — Flutter- and
/// dart:html-free (only `dart:math` + the pure-Dart `pdf` package, which has
/// no web/platform dependency), so a plain `flutter test` (VM target) can
/// exercise the EXACT logic [printBags] uses, without pulling in the
/// web-only render_log import chain.

// Fixed density -> [cols, rows] grid. Every entry here has cols*rows == the
// exposed density option EXACTLY, so page capacity always matches the chosen
// "NB" count — no bags can be dropped between pages.
const Map<int, List<int>> bagPrintGrid = {
  4: [2, 2], 6: [2, 3], 8: [2, 4], 10: [2, 5], 12: [3, 4],
  14: [2, 7], 16: [4, 4], 18: [3, 6], 20: [4, 5], 22: [2, 11], 24: [4, 6],
};

List<int> gridFor(int n) {
  if (bagPrintGrid.containsKey(n)) return bagPrintGrid[n]!;
  final cols = math.max(1, (math.sqrt(n * (210 / 297))).round());
  return [cols, (n / cols).ceil()];
}

/// Given a total bag count and the chosen density, returns one `List<int>`
/// of ORIGINAL-list indices per printed page, using cap(=cols*rows) as the
/// stride. Every index 0..total-1 appears in exactly one page, in order,
/// with no skips/duplicates.
List<List<int>> paginateBagIndices(int total, int perPage) {
  final g = gridFor(perPage);
  final cap = g[0] * g[1];
  final pages = <List<int>>[];
  for (var s = 0; s < total; s += cap) {
    final end = math.min(s + cap, total);
    pages.add(List.generate(end - s, (i) => s + i));
  }
  return pages;
}

// A4 portrait printable area (8mm L/R, 10mm T/B margins), in points.
const double kBagGutterPt = 5.0;
const double kBagSafetyPt = 2.0; // pt of slack subtracted from cellH so the
// bottom row can never overflow the page (rounding/border/gutter margin).

double get bagAreaWPt => (210 - 16) * PdfPageFormat.mm;
double get bagAreaHPt => (297 - 20) * PdfPageFormat.mm;

class BagCellLayout {
  final int cols, rows;
  final double cellW, cellH;
  final bool fits;
  const BagCellLayout({
    required this.cols,
    required this.rows,
    required this.cellW,
    required this.cellH,
    required this.fits,
  });
}

/// Computes the fixed cell size for a density so every row/col of cards
/// tiles the printable area with only [kBagGutterPt] between cells — and,
/// crucially, so the bottom row NEVER overflows the page ([kBagSafetyPt]
/// slack is baked into cellH). [fits] asserts the math: total rendered
/// height/width must not exceed the printable area.
BagCellLayout layoutFor(int perPage) {
  final g = gridFor(perPage);
  final cols = g[0], rows = g[1];
  final areaW = bagAreaWPt, areaH = bagAreaHPt;

  final cellW = (areaW - (cols - 1) * kBagGutterPt) / cols;
  final cellH = (areaH - (rows - 1) * kBagGutterPt - kBagSafetyPt) / rows;

  final totalW = cols * cellW + (cols - 1) * kBagGutterPt;
  final totalH = rows * cellH + (rows - 1) * kBagGutterPt + kBagSafetyPt;
  final fits = totalW <= areaW + 0.01 && totalH <= areaH + 0.01;

  return BagCellLayout(cols: cols, rows: rows, cellW: cellW, cellH: cellH, fits: fits);
}

/// "Bag N" header font size scales PROPORTIONALLY with the card's own
/// height — bigger cards (fewer per page) get bigger text, smaller cards
/// get smaller text — instead of a fixed size per column count.
double fontSizeForCellH(double cellH) {
  final f = cellH * 0.11;
  return f.clamp(6.0, 20.0);
}
