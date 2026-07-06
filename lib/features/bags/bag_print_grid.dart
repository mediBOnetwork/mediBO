import 'dart:math' as math;

/// Pure pagination/grid math for Bags PDF printing — no Flutter, no
/// dart:pdf/printing, no dart:html. Kept dependency-free so a plain
/// `flutter test` (VM target) can exercise the EXACT logic [printBags] uses,
/// without pulling in the web-only render_log import chain.

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
