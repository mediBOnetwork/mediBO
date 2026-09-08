// CMD #1875 — the ₹ chips on a route card and a plan summary, and the version
// chips that make a rebuilt plan legible.
//
// What this file holds down: the frontend computes NOTHING about money. Every
// rupee string in these fixtures is a backend string, printed verbatim; the
// only decisions Dart is allowed to make are which chips exist and what tone
// each carries — and the tone of the "per converted lead" chip comes from the
// backend's has_conversions flag, never from parsing the number back out of
// the label.
//
// Runs on the Dart VM in milliseconds: no widgets, no network, no Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/route_cost_chips.dart';

/// A route as `route_plan_get()` returns it, trimmed to the cost block.
Map<String, dynamic> routeWithConversions() => {
      'route_id': 'bbbbbbbb-0000-0000-0000-000000001872',
      'title': 'Pandri loop',
      'subtitle': '3 stops · 1.2 km · 0h 34m',
      'cost_inr': 99.64,
      'cost_label': '₹100 route cost',
      'converted': 1,
      'converted_label': '1 converted',
      'has_conversions': true,
      'cost_per_converted': 99.64,
      'cost_per_converted_label': '₹100 per converted lead',
    };

/// The same block before anyone has checked in.
Map<String, dynamic> planNoConversions() => {
      'routes': 1,
      'stops': 1,
      'total_km_label': '18.6 km total',
      'cost_inr': 255.94,
      'cost_label': '₹256 plan cost',
      'converted': 0,
      'converted_label': null,
      'has_conversions': false,
      'cost_per_converted': null,
      'cost_per_converted_label': 'No conversions yet',
    };

void main() {
  group('CMD #1875 — ₹ chips are backend strings', () {
    test('a route with a conversion shows cost, per-converted and the count',
        () {
      final m = RouteCostChips.from(routeWithConversions());
      expect(m.isEmpty, isFalse);
      expect(m.chips.map((c) => c.label).toList(), [
        '₹100 route cost',
        '₹100 per converted lead',
        '1 converted',
      ]);
      // Tone is driven by has_conversions, not by reading the label.
      expect(m.chips[0].tone, RouteChipTone.brand);
      expect(m.chips[1].tone, RouteChipTone.success);
      expect(m.chips[2].tone, RouteChipTone.info);
    });

    test('no conversions yet: the backend copy is shown, quietly', () {
      final m = RouteCostChips.from(planNoConversions());
      expect(m.chips.length, 2);
      expect(m.chips[1].label, 'No conversions yet');
      expect(m.chips[1].tone, RouteChipTone.muted,
          reason: 'an empty result must not be dressed up as a good one');
      expect(m.chips.map((c) => c.label), isNot(contains('0 converted')),
          reason: 'the backend sends no converted_label at zero, so neither '
              'does the chip row — Dart never invents one');
    });

    test('a payload with no cost renders nothing at all — never ₹0', () {
      final m = RouteCostChips.from({'title': 'R1', 'subtitle': '3 stops'});
      expect(m.isEmpty, isTrue);
      expect(m.chips, isEmpty);
      final blank = RouteCostChips.from({'cost_label': ''});
      expect(blank.isEmpty, isTrue);
    });

    test('labels are printed verbatim — no formatting, no currency in Dart',
        () {
      // A deliberately odd backend string: lakh grouping, no decimals, a word
      // order Dart could never have produced. It must survive untouched.
      final m = RouteCostChips.from({
        'cost_label': '₹1,24,500 plan cost',
        'cost_per_converted_label': '₹41,500 per converted lead',
        'converted_label': '3 converted',
        'has_conversions': true,
      });
      expect(m.chips[0].label, '₹1,24,500 plan cost');
      expect(m.chips[1].label, '₹41,500 per converted lead');
    });

    test('has_conversions is the flag, even if the counts disagree', () {
      // The backend is the authority. A stale converted count must not flip
      // the tone behind its back.
      final m = RouteCostChips.from({
        'cost_label': '₹100 route cost',
        'cost_per_converted_label': 'No conversions yet',
        'converted': 5,
        'has_conversions': false,
      });
      expect(m.chips[1].tone, RouteChipTone.muted);
    });
  });

  group('CMD #1875 — plan version chips', () {
    test('a plan that was never rebuilt says nothing', () {
      final v = RoutePlanVersionChips.from({
        'title': 'Raipur · 1 routes · 3 leads',
        'version': 1,
        'version_label': 'v1',
        'superseded_label': null,
      });
      expect(v.chips, isEmpty,
          reason: 'v1 is the normal case and must not add furniture');
    });

    test('a rebuilt plan names its version', () {
      final v = RoutePlanVersionChips.from({
        'version': 2,
        'version_label': 'v2',
        'superseded_label': null,
      });
      expect(v.chips.single.label, 'v2');
      expect(v.chips.single.tone, RouteChipTone.info);
    });

    test('the plan it replaced names its successor', () {
      final v = RoutePlanVersionChips.from({
        'version': 1,
        'version_label': 'v1',
        'superseded_label': 'Replaced by v2',
      });
      expect(v.chips.single.label, 'Replaced by v2');
      expect(v.chips.single.tone, RouteChipTone.warning,
          reason: 'a superseded plan is a warning, not a decoration');
    });

    test('a missing version defaults to 1 and stays silent', () {
      final v = RoutePlanVersionChips.from({'title': 'old plan'});
      expect(v.version, 1);
      expect(v.chips, isEmpty);
    });
  });
}
