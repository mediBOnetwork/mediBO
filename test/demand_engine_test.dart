// CMD #427 — the demand engine and the price check compute nothing.
//
// What these tests hold down is the boundary that makes a cross-pharmacy number
// safe to show at all. The median, the percentage, the rupee impact and the
// "across N nearby pharmacies" count are decided once, in the backend, under a
// cohort floor no screen can see — so a screen that re-derived any of them
// would be showing a number nobody checked against that floor.
//
// The anonymity fence is here too, and it is the strongest kind: the payload
// carries no other pharmacy, and a payload that DID carry one must still put
// nothing of it on screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_demand_engine_screen.dart';
import 'package:pharma_b2b/screens/pharmacy/pharmacy_overpay_screen.dart';
import 'package:pharma_b2b/services/demand_engine_api.dart';
import 'package:pharma_b2b/utils/render_log.dart';

Widget _host(Widget child) => MaterialApp(home: child);

// ── payloads ────────────────────────────────────────────────────────────────

const _overpay = <String, dynamic>{
  'ok': true,
  'title': 'Price check',
  'subtitle': 'What your bills say you paid, next to what pharmacies near you '
      'paid for the same pack.',
  'privacy': 'Rates are a median across at least 5 pharmacies. No pharmacy or '
      'supplier is ever named, and yours is never shown to anyone.',
  'empty': 'Nothing to flag this month.',
  'total_label': 'About ₹2,940.00 across these lines',
  'count': 2,
  'rows': [
    {
      'id': 'aaaaaaaa-0000-0000-0000-000000000001',
      'medicine_id': 4242,
      'name': 'Paracetamol 650',
      'pack_label': '10 tablets',
      'headline': 'You paid ₹110.00; pharmacies near you pay ₹96.00 (-14.6%)',
      'detail': 'Across 5 nearby pharmacies. At your volume that is about '
          '₹2,240.00 over the period.',
      'month_label': 'September 2026',
      'tone': 'info',
      'action_label': 'Get the mediBO price',
      'route': '/product/4242',
      'dismiss_label': 'Not useful',
      'dismissed': false,
    },
    {
      'id': 'aaaaaaaa-0000-0000-0000-000000000002',
      'medicine_id': 77,
      'name': 'Amoxycillin 500',
      'pack_label': '',
      'headline': 'You paid ₹58.00; pharmacies near you pay ₹51.00 (-12.1%)',
      'detail': 'Across 7 nearby pharmacies.',
      'month_label': 'September 2026',
      'tone': 'warning',
      'action_label': 'Get the mediBO price',
      'route': '/product/77',
      'dismiss_label': 'Not useful',
      'dismissed': false,
    },
  ],
};

const _engine = <String, dynamic>{
  'ok': true,
  'title': 'Demand engine',
  'subtitle': 'What the zone actually buys.',
  'privacy': 'Every row here is a group of at least 5 pharmacies.',
  'zone_id': 12,
  'zones': [
    {'key': '12', 'label': 'Raipur North'},
    {'key': '13', 'label': 'Bhilai'},
  ],
  'month_key': '2026-09-01',
  'months': [
    {'key': '2026-09-01', 'label': 'Sep 2026'},
    {'key': '2026-08-01', 'label': 'Aug 2026'},
  ],
  'tiles': [
    {'label': 'SKUs', 'value': '218', 'tone': 'info'},
    {'label': 'Units bought', 'value': '41290', 'tone': 'info'},
    {'label': 'Pharmacies', 'value': '31', 'tone': 'success'},
  ],
  'tabs': [
    {'key': 'movers', 'label': 'Top movers'},
    {'key': 'rising', 'label': 'Rising'},
    {'key': 'spread', 'label': 'Rate spread'},
    {'key': 'season', 'label': 'Seasonality'},
  ],
  'empty': 'Nothing has cleared the anonymity floor yet.',
  // deliberately NOT alphabetical, and not sorted by units either
  'movers': [
    {
      'medicine_id': 9,
      'name': 'Zincovit',
      'units_label': '980 units',
      'rate_label': 'median ₹88.00',
      'spread_label': '₹84.00 – ₹94.00',
      'delta_label': '+22.4%',
      'cohort_label': '14 pharmacies',
      'tone': 'success',
      'route': '/product/9',
    },
    {
      'medicine_id': 4,
      'name': 'Azithral 500',
      'units_label': '1210 units',
      'rate_label': 'median ₹64.00',
      'spread_label': '₹61.00 – ₹70.00',
      'delta_label': '',
      'cohort_label': '9 pharmacies',
      'tone': 'info',
      'route': '/product/4',
    },
  ],
  'rising': [
    {
      'medicine_id': 9,
      'name': 'Zincovit',
      'units_label': '980 units',
      'delta_label': '+22.4%',
      'cohort_label': '14 pharmacies',
      'tone': 'success',
      'route': '/product/9',
    },
  ],
  'spread': [
    {
      'medicine_id': 4,
      'name': 'Azithral 500',
      'supplier': 'Shivam Pharma Distributors',
      'rate_label': '₹61.00',
      'range_label': '₹60.00 – ₹63.00',
      'units_label': '640 units',
      'cohort_label': '8 pharmacies',
      'vs_label': '-4.7% vs network',
      'tone': 'success',
    },
  ],
  'season': [
    {
      'key': 'fever',
      'label': 'Fever & pain',
      'factor_label': 'x1.5 this month',
      'tone': 'success',
    },
  ],
};

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);

  // A tall viewport, so the whole payload is on screen and "the screen renders
  // it" is a real assertion rather than an accident of the fold.
  setUp(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(1200, 3200);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  // ── the price check ───────────────────────────────────────────────────────

  group('price check', () {
    testWidgets('every line is the backend\'s string, in payload order', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PharmacyOverpayScreen(
            rpc: (fn, p) async => _overpay,
            onOpenRoute: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The sentence the spec asks for, rendered exactly as it arrived — no
      // rupee formatting, no percentage and no minus sign built in Dart.
      expect(
        find.text('You paid ₹110.00; pharmacies near you pay ₹96.00 (-14.6%)'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Across 5 nearby pharmacies. At your volume that is about '
          '₹2,240.00 over the period.',
        ),
        findsOneWidget,
      );
      expect(find.text('About ₹2,940.00 across these lines'), findsOneWidget);
      expect(find.text('10 tablets'), findsOneWidget);

      // Payload order, not alphabetical: Paracetamol before Amoxycillin.
      final names = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s == 'Paracetamol 650' || s == 'Amoxycillin 500')
          .toList();
      expect(names, ['Paracetamol 650', 'Amoxycillin 500']);
    });

    testWidgets('the privacy promise is the backend\'s, not a Dart sentence', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(PharmacyOverpayScreen(rpc: (fn, p) async => _overpay)),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Rates are a median across at least 5 pharmacies. No pharmacy or '
          'supplier is ever named, and yours is never shown to anyone.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('an empty pack label is an absence, never a dash', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(PharmacyOverpayScreen(rpc: (fn, p) async => _overpay)),
      );
      await tester.pumpAndSettle();
      expect(find.text('—'), findsNothing);
      expect(find.text('-'), findsNothing);
    });

    testWidgets('the action carries the backend\'s route and never builds one', (
      tester,
    ) async {
      final opened = <String>[];
      await tester.pumpWidget(
        _host(
          PharmacyOverpayScreen(
            rpc: (fn, p) async => _overpay,
            onOpenRoute: opened.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get the mediBO price').first);
      await tester.pumpAndSettle();
      expect(opened, ['/product/4242']);
    });

    testWidgets('dismiss posts the row id and prints the backend reply', (
      tester,
    ) async {
      final calls = <String>[];
      await tester.pumpWidget(
        _host(
          PharmacyOverpayScreen(
            rpc: (fn, p) async {
              calls.add('$fn:${p['p_id']}');
              if (fn == 'pharmacy_overpay_dismiss') {
                return {'ok': true, 'message': 'Hidden. It will not come back.'};
              }
              return _overpay;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not useful').first);
      await tester.pumpAndSettle();

      expect(
        calls,
        contains(
          'pharmacy_overpay_dismiss:aaaaaaaa-0000-0000-0000-000000000001',
        ),
      );
      expect(find.text('Hidden. It will not come back.'), findsOneWidget);
    });

    testWidgets('nothing about another pharmacy reaches the screen', (
      tester,
    ) async {
      // A payload that WERE to carry a neighbour still puts none of it on
      // screen: the widget reads named keys only, so a leak cannot arrive by
      // accident from a future backend change.
      final leaky = Map<String, dynamic>.from(_overpay);
      leaky['rows'] = [
        {
          ...(_overpay['rows'] as List).first as Map<String, dynamic>,
          'peer_pharmacy': 'Sharma Medical Store',
          'peer_supplier': 'Ganesh Distributors',
        },
      ];
      await tester.pumpWidget(
        _host(PharmacyOverpayScreen(rpc: (fn, p) async => leaky)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Sharma Medical Store'), findsNothing);
      expect(find.textContaining('Ganesh Distributors'), findsNothing);
    });

    testWidgets('an empty month renders the backend copy, not a blank list', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PharmacyOverpayScreen(
            rpc: (fn, p) async => {
              ..._overpay,
              'rows': const [],
              'total_label': '',
              'count': 0,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nothing to flag this month.'), findsOneWidget);
      expect(find.text('Get the mediBO price'), findsNothing);
    });

    testWidgets('ok:false prints the backend refusal instead of throwing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PharmacyOverpayScreen(
            rpc: (fn, p) async => const {
              'ok': false,
              'error': 'not_a_pharmacy',
              'message': 'This screen is for a pharmacy account.',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('This screen is for a pharmacy account.'),
        findsOneWidget,
      );
    });
  });

  // ── the demand engine ─────────────────────────────────────────────────────

  group('demand engine', () {
    testWidgets('the first load asks with NO zone and NO month', (
      tester,
    ) async {
      final params = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        _host(
          AdminDemandEngineScreen(
            rpc: (fn, p) async {
              params.add(p);
              return _engine;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      // An untouched filter is an ABSENT parameter — the backend picks the
      // busiest zone and the current month, and Dart guesses neither.
      expect(params.first.containsKey('p_zone'), isFalse);
      expect(params.first.containsKey('p_month'), isFalse);
    });

    testWidgets('the tab list is the payload\'s and the first one opens', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(AdminDemandEngineScreen(rpc: (fn, p) async => _engine)),
      );
      await tester.pumpAndSettle();
      for (final label in ['Top movers', 'Rising', 'Rate spread', 'Seasonality']) {
        expect(find.text(label), findsOneWidget);
      }
      // movers is first in the payload, so movers is what is drawn
      expect(find.text('median ₹88.00'), findsOneWidget);
      expect(find.text('₹84.00 – ₹94.00'), findsOneWidget);
    });

    testWidgets('rows render in payload order, never re-sorted by units', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(AdminDemandEngineScreen(rpc: (fn, p) async => _engine)),
      );
      await tester.pumpAndSettle();
      final names = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .where((s) => s == 'Zincovit' || s == 'Azithral 500')
          .toList();
      // Zincovit has FEWER units than Azithral and still comes first, because
      // the backend put it first.
      expect(names, ['Zincovit', 'Azithral 500']);
    });

    testWidgets('switching a tab draws that list, cohort line and all', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(AdminDemandEngineScreen(rpc: (fn, p) async => _engine)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rate spread'));
      await tester.pumpAndSettle();
      expect(find.text('Shivam Pharma Distributors'), findsOneWidget);
      expect(find.text('-4.7% vs network'), findsOneWidget);
      expect(find.text('8 pharmacies'), findsOneWidget);

      await tester.tap(find.text('Seasonality'));
      await tester.pumpAndSettle();
      expect(find.text('Fever & pain'), findsOneWidget);
      expect(find.text('x1.5 this month'), findsOneWidget);
    });

    testWidgets('picking a zone sends the backend\'s own key', (tester) async {
      final params = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        _host(
          AdminDemandEngineScreen(
            rpc: (fn, p) async {
              params.add(p);
              return _engine;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bhilai'));
      await tester.pumpAndSettle();
      expect(params.last['p_zone'], 13);
    });

    testWidgets('a tab key this build has never seen renders the empty state', (
      tester,
    ) async {
      final future = Map<String, dynamic>.from(_engine);
      future['tabs'] = const [
        {'key': 'quantum_flux', 'label': 'Something new'},
      ];
      await tester.pumpWidget(
        _host(AdminDemandEngineScreen(rpc: (fn, p) async => future)),
      );
      await tester.pumpAndSettle();
      // Forward compatible: an unknown list is an empty list, not a crash.
      expect(find.text('Something new'), findsOneWidget);
      expect(
        find.text('Nothing has cleared the anonymity floor yet.'),
        findsOneWidget,
      );
    });

    testWidgets('the engine names suppliers but never a pharmacy', (
      tester,
    ) async {
      final leaky = Map<String, dynamic>.from(_engine);
      leaky['movers'] = [
        {
          ...(_engine['movers'] as List).first as Map<String, dynamic>,
          'top_buyer': 'Sharma Medical Store',
        },
      ];
      await tester.pumpWidget(
        _host(AdminDemandEngineScreen(rpc: (fn, p) async => leaky)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Sharma Medical Store'), findsNothing);
    });

    testWidgets('ok:false prints the backend refusal', (tester) async {
      await tester.pumpWidget(
        _host(
          AdminDemandEngineScreen(
            rpc: (fn, p) async => const {
              'ok': false,
              'error': 'not_admin',
              'message': 'The demand engine is for mediBO operators.',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('The demand engine is for mediBO operators.'),
        findsOneWidget,
      );
    });
  });

  // ── the entry button ──────────────────────────────────────────────────────

  group('price check entry', () {
    test('the button exists only when the backend says show', () async {
      await OverpayEntry.load(
        rpc: (fn, p) async => const {'ok': true, 'show': false},
      );
      expect(OverpayEntry.show, isFalse);

      await OverpayEntry.load(
        rpc: (fn, p) async => const {
          'ok': true,
          'show': true,
          'label': 'Price check',
          'count': 2,
          'badge': '2',
        },
      );
      expect(OverpayEntry.show, isTrue);
      expect(OverpayEntry.value.value['label'], 'Price check');
      // The badge is the backend's string — Dart never renders count.toString().
      expect(OverpayEntry.value.value['badge'], '2');
    });

    test('a throwing RPC leaves no button rather than a broken one', () async {
      await OverpayEntry.load(rpc: (fn, p) async => throw StateError('offline'));
      expect(OverpayEntry.show, isFalse);
    });
  });
}
