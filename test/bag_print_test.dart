import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/features/bags/bag_print_grid.dart';

void main() {
  group('bagPrintGrid / gridFor — capacity == density', () {
    for (final n in [4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24]) {
      test('$n B => cols*rows == $n', () {
        final g = gridFor(n);
        final cap = g[0] * g[1];
        expect(cap, n, reason: 'grid ${g[0]}x${g[1]} for ${n}B must have capacity == $n');
      });
    }
  });

  group('paginateBagIndices — full coverage, no skip/dup', () {
    for (final perPage in [4, 6, 9, 24]) {
      test('perPage=$perPage over 30 fake bags', () {
        const total = 30;
        final pages = paginateBagIndices(total, perPage);

        // Every page (except possibly the last) holds exactly cap == cols*rows
        // items (for perPage values in bagPrintGrid, cap == perPage exactly).
        final g = gridFor(perPage);
        final cap = g[0] * g[1];
        expect(pages.length, (total / cap).ceil(),
            reason: 'expected ceil($total/$cap) pages for perPage=$perPage');

        final seen = <int>[];
        for (var p = 0; p < pages.length; p++) {
          final page = pages[p];
          if (p < pages.length - 1) {
            expect(page.length, cap, reason: 'non-last page must be full ($cap items)');
          } else {
            expect(page.length, lessThanOrEqualTo(cap));
          }
          seen.addAll(page);
        }

        // Full coverage: every index 0..29 appears, in order, exactly once.
        expect(seen, List.generate(total, (i) => i),
            reason: 'every bag index 0..${total - 1} must appear exactly once, in order');
        expect(seen.toSet().length, total, reason: 'no duplicate indices');
      });
    }
  });

  group('CHANGE #391 — cells always fit the page (no dropped last row)', () {
    for (final perPage in [4, 6, 9, 12, 24]) {
      test('perPage=$perPage: rows*cellH+gutters+safety <= areaH, cols*cellW+gutters <= areaW', () {
        final layout = layoutFor(perPage);
        final totalH = layout.rows * layout.cellH +
            (layout.rows - 1) * kBagGutterPt +
            kBagSafetyPt;
        final totalW = layout.cols * layout.cellW + (layout.cols - 1) * kBagGutterPt;

        expect(layout.fits, isTrue, reason: 'layoutFor($perPage).fits must be true');
        expect(totalH, lessThanOrEqualTo(bagAreaHPt + 0.01),
            reason: 'rows*cellH+gutters+safety must not exceed the printable height '
                '(this is the anti-dropped-last-row proof)');
        expect(totalW, lessThanOrEqualTo(bagAreaWPt + 0.01),
            reason: 'cols*cellW+gutters must not exceed the printable width');
      });

      test('perPage=$perPage over 30 fake bags: full coverage + capacity check', () {
        const total = 30;
        final g = gridFor(perPage);
        final cap = g[0] * g[1];
        final pages = paginateBagIndices(total, perPage);
        expect(pages.length, (total / cap).ceil());
        for (var p = 0; p < pages.length - 1; p++) {
          expect(pages[p].length, cap, reason: 'non-last page must hold exactly $cap cells');
        }
        final seen = pages.expand((p) => p).toList();
        expect(seen, List.generate(total, (i) => i));
      });
    }

    test('Bag-N font is PROPORTIONAL to card size: 4B font > 24B font', () {
      final font4 = fontSizeForCellH(layoutFor(4).cellH);
      final font24 = fontSizeForCellH(layoutFor(24).cellH);
      expect(font4, greaterThan(font24),
          reason: '4B cards (bigger) must have a bigger font than 24B cards (smaller)');

      // Formula check: fontSize == clamp(cellH*0.11, 6.0, 20.0) for every density —
      // this is the actual proportionality proof (font scales linearly with
      // cellH until it hits the 6-20pt clamp range; 4B/6B/8B/12B/16B all sit
      // at the 20pt ceiling since their cellH*0.11 exceeds 20, which is
      // expected/correct clamp behavior, not a bug).
      for (final n in [4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24]) {
        final cellH = layoutFor(n).cellH;
        final expected = (cellH * 0.11).clamp(6.0, 20.0);
        expect(fontSizeForCellH(cellH), expected,
            reason: 'fontSizeForCellH must equal clamp(cellH*0.11, 6, 20) for ${n}B');
      }

      // Among densities where the formula is NOT clamped (cellH*0.11 < 20pt),
      // font must be non-decreasing with cellH (ties are legitimate when two
      // densities share the same row count, e.g. 18B/24B both have rows=6 ->
      // identical cellH -> identical font — that's correct proportional
      // behavior, not a bug).
      final unclamped = [10, 14, 18, 20, 22, 24];
      final byCellH = [...unclamped]..sort((a, b) =>
          layoutFor(a).cellH.compareTo(layoutFor(b).cellH));
      for (var i = 1; i < byCellH.length; i++) {
        final smaller = fontSizeForCellH(layoutFor(byCellH[i - 1]).cellH);
        final bigger = fontSizeForCellH(layoutFor(byCellH[i]).cellH);
        expect(bigger, greaterThanOrEqualTo(smaller),
            reason: 'font must not decrease as cellH increases in the unclamped range');
      }
      // And the extremes of the unclamped range must differ strictly.
      expect(fontSizeForCellH(layoutFor(10).cellH),
          greaterThan(fontSizeForCellH(layoutFor(22).cellH)),
          reason: '10B (bigger cells) must have a strictly bigger font than 22B (smallest cells)');
    });
  });
}
