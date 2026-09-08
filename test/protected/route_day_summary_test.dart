// CMD #1877 — the day summary: one RPC, two surfaces, zero arithmetic.
//
// The card at the top of the Routes tab and the "Field" strip on the Leads tab
// are the SAME payload. The bug this file exists to prevent is the obvious one:
// somebody adds up a column in Dart to "fix" a mismatch, and the two surfaces
// start telling Om different stories about the same day. Every number here is
// a backend string, and this suite proves the parse never invents one.
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/route_cost_chips.dart';
import 'package:pharma_b2b/models/route_day_summary.dart';

/// A real route_day_summary() reply, trimmed to the fields the app reads.
/// Deliberately worded oddly ("3 of 3 stops closed", "₹65 cost") so a test
/// that passes because Dart happened to format the same thing would fail.
Map<String, dynamic> _payload({
  bool ok = true,
  bool has = true,
  bool isAdmin = true,
  List<Map<String, dynamic>>? workers,
  Map<String, dynamic>? strip,
}) =>
    {
      'ok': ok,
      'has': has,
      'is_admin': isAdmin,
      'title': 'Day summary',
      'header_label': 'Tue 08 Sep · All zones',
      'count_label': '1 worker in the field',
      'empty_label': has ? null : 'No route is assigned to a worker for this date in this zone.',
      'totals': {
        'progress_label': '3 of 3 stops closed',
        'km_label': '0.7 km',
        'cost_label': '₹65 cost',
        'conversion_label': '33% converted',
        'chips': [
          {'key': 'planned', 'tone': 'info', 'label': 'Planned 3'},
          {'key': 'converted', 'tone': 'brand', 'label': 'Converted 1'},
        ],
      },
      'workers': workers ??
          [
            {
              'worker_label': 'Rahul Sahu',
              'progress_label': '3 of 3 stops closed',
              'km_label': '0.7 km',
              'cost_label': '₹65 cost',
              'conversion_label': '33% converted',
              'chips': [
                {'key': 'planned', 'tone': 'info', 'label': 'Planned 3'},
                {'key': 'visited', 'tone': 'success', 'label': 'Visited 1'},
                {'key': 'closed', 'tone': 'warning', 'label': 'Closed 0'},
                {'key': 'not_interested', 'tone': 'danger', 'label': 'Not interested 1'},
                {'key': 'converted', 'tone': 'brand', 'label': 'Converted 1'},
                {'key': 'km', 'tone': 'neutral', 'label': '0.7 km'},
                {'key': 'cost', 'tone': 'neutral', 'label': '₹65 cost'},
              ],
            },
          ],
      'strip': strip ??
          {
            'has': has,
            'title': 'Field today',
            'header_label': 'Tue 08 Sep · All zones',
            'summary_label': '3 of 3 stops · 1 converted · 0.7 km',
            'cost_label': '₹65 cost',
            'conversion_label': '33% converted',
            'link_label': 'Routes',
            'chips': [
              {'key': 'converted', 'tone': 'brand', 'label': 'Converted 1'},
            ],
          },
    };

void main() {
  test('every number and word is the backend\'s, printed verbatim', () {
    final d = RouteDaySummary.from(_payload());
    expect(d.title, 'Day summary');
    expect(d.headerLabel, 'Tue 08 Sep · All zones');
    expect(d.countLabel, '1 worker in the field');

    final w = d.workers.single;
    expect(w.label, 'Rahul Sahu');
    // Not "3/3", not "100%", not "₹65.00" — exactly what the RPC sent.
    expect(w.progressLabel, '3 of 3 stops closed');
    expect(w.kmLabel, '0.7 km');
    expect(w.costLabel, '₹65 cost');
    expect(w.conversionLabel, '33% converted');
  });

  test('chip tones are the payload\'s names, danger included', () {
    final w = RouteDaySummary.from(_payload()).workers.single;
    expect(w.chips.map((c) => c.label).toList(), [
      'Planned 3', 'Visited 1', 'Closed 0', 'Not interested 1',
      'Converted 1', '0.7 km', '₹65 cost',
    ]);
    expect(w.chips.map((c) => c.tone).toList(), [
      RouteChipTone.info,
      RouteChipTone.success,
      RouteChipTone.warning,
      // 'Not interested' is the reason RouteChipTone gained `danger`.
      RouteChipTone.danger,
      RouteChipTone.brand,
      // An unknown tone name ('neutral') degrades to muted rather than
      // throwing — a backend that adds a tone must not white-screen the tab.
      RouteChipTone.muted,
      RouteChipTone.muted,
    ]);
  });

  test('the Leads strip and the Routes card carry the same day', () {
    final d = RouteDaySummary.from(_payload());
    expect(d.strip.has, isTrue);
    expect(d.strip.title, 'Field today');
    expect(d.strip.summaryLabel, '3 of 3 stops · 1 converted · 0.7 km');
    // Same conversion sentence on both surfaces, because it is the same field.
    expect(d.strip.conversionLabel, d.totals!.conversionLabel);
    expect(d.strip.costLabel, d.totals!.costLabel);
  });

  test('strip absence is the backend\'s flag, never a row of zeroes', () {
    final d = RouteDaySummary.from(_payload(has: false, workers: const [], strip: {
      'has': false,
      'title': 'Field today',
      'empty_label': 'No route is assigned to a worker for this date in this zone.',
    }));
    expect(d.strip.has, isFalse);
    expect(d.strip.summaryLabel, isNull);
    expect(d.has, isFalse);
    // The card still draws — it prints the backend's empty copy.
    expect(d.showCard, isTrue);
    expect(d.emptyLabel, 'No route is assigned to a worker for this date in this zone.');
  });

  test('ok:false draws nothing at all — not an error, not an empty state', () {
    final d = RouteDaySummary.from(_payload(ok: false));
    expect(d.showCard, isFalse);
  });

  test('a totals line is an admin thing, and only above one worker', () {
    final two = _payload(workers: [
      {'worker_label': 'Rahul Sahu', 'progress_label': '3 of 3 stops closed', 'chips': const []},
      {'worker_label': 'Asha Verma', 'progress_label': '1 of 4 stops closed', 'chips': const []},
    ]);
    expect(RouteDaySummary.from(two).showTotals, isTrue);
    // One worker: the totals would just repeat his own line.
    expect(RouteDaySummary.from(_payload()).showTotals, isFalse);
    // A field worker never sees a team line, however many rows arrive.
    expect(RouteDaySummary.from({...two, 'is_admin': false}).showTotals, isFalse);
  });

  test('workers render in payload order — no client sort', () {
    final d = RouteDaySummary.from(_payload(workers: [
      {'worker_label': 'Zara', 'chips': const []},
      {'worker_label': 'Asha', 'chips': const []},
      {'worker_label': 'Manish', 'chips': const []},
    ]));
    expect(d.workers.map((w) => w.label).toList(), ['Zara', 'Asha', 'Manish']);
  });

  test('an empty payload is survivable', () {
    final d = RouteDaySummary.from(const <String, dynamic>{});
    expect(d.showCard, isFalse);
    expect(d.workers, isEmpty);
    expect(d.totals, isNull);
    expect(d.strip.has, isFalse);
    expect(d.title, '');
  });
}
