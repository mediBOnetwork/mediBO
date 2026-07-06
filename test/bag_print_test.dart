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
}
