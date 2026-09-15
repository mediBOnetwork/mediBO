// PROTECTED — CHANGE #537.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes fulfill-pipeline behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the Fulfill surface is ONE payload printed in the
// order it arrived:
//
//   1. THE ORDER IS THE BACKEND'S. The nine stages are the physical route an
//      order travels (Customer order → Supplier inquiry → Supplier order →
//      Supplier shop → Warehouse → Bag → Pack → Delivery → Dispute) and that
//      sequence lives in feature_registry.sort_order, not in this app. The
//      fixtures below arrive deliberately out of order to prove the widget
//      renders payload order and never sorts, reorders or re-groups.
//
//   2. A PARTNER IS THE SAME BAR, MINUS. A region partner calls the same RPC
//      and is simply not sent the stages their permission matrix does not
//      grant. The remaining tabs keep their positions relative to each other —
//      which is exactly why the selected tab is a STAGE KEY and never an
//      index. If it were an index, "tab 4" would be Warehouse for an admin and
//      something else entirely for a partner.
//
//   3. NOTHING IS COUNTED HERE. label and badge_label print verbatim. '99+'
//      appears because the BACKEND capped it; a badge appears only when the
//      payload sent one (has_badge / badge_label), never because a count
//      happened to be non-zero in Dart, and never re-pluralised.
//
//   4. AN UNKNOWN STAGE IS SILENCE, NOT A CRASH. A stage_key this build has
//      never heard of resolves to nothing, so the backend can register a tenth
//      stage before the app ships a body for it.
//
//   5. A TAP CARRIES THE BACKEND'S OWN KEY. The screen deep-links on
//      stage_key, so a stage arriving under a new key routes itself.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/fulfill/fulfill_pipeline_tabs.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// The full nine, as `fulfill_tabs()` sends them to a super-admin — but with
/// the LIST deliberately shuffled, so a widget that sorted by `sort` (or by
/// label) instead of rendering payload order would be caught.
Map<String, dynamic> _tab(
  String key,
  String label,
  int sort, {
  String? badge,
  String access = 'write',
}) =>
    <String, dynamic>{
      'stage_key': key,
      'feature_key': 'fulfill.$key',
      'label': label,
      'sort': sort,
      'icon_key': 'receipt',
      'deep_link': '/admin/fulfill/$key',
      'access': access,
      'can_write': access == 'write',
      'badge_count': badge == null ? 0 : 7,
      'has_badge': badge != null,
      'badge_label': badge,
    };

Map<String, dynamic> _payload(List<Map<String, dynamic>> tabs,
        {bool isPartner = false}) =>
    <String, dynamic>{
      'ok': true,
      'is_partner': isPartner,
      'zone_label': 'Raipur Zone',
      'tabs': tabs,
      'tab_count': tabs.length,
      'has_tabs': tabs.isNotEmpty,
      'empty_title': 'No pipeline stages',
      'empty_message': 'Your permissions do not include any fulfilment stage yet.',
    };

/// The admin payload, in the order the backend actually sends it.
List<Map<String, dynamic>> _nine() => [
      _tab('customer_order', 'Customer order', 10, badge: '12'),
      _tab('supplier_inquiry', 'Supplier inquiry', 20),
      _tab('supplier_order', 'Supplier order', 30, badge: '3'),
      _tab('supplier_shop', 'Supplier shop', 40),
      _tab('warehouse', 'Warehouse', 50, badge: '99+'),
      _tab('bag', 'Bag', 60),
      _tab('pack', 'Pack', 70, badge: '2'),
      _tab('delivery', 'Delivery', 80),
      _tab('dispute', 'Dispute', 90),
    ];

Future<void> _pump(
  WidgetTester tester,
  FulfillPipelinePayload p,
  String selected,
  void Function(String) onSelect,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 390, // a phone: nine stages cannot all fit, and must not need to
        child: FulfillPipelineTabBar(
          tabs: p.tabs,
          selectedStage: selected,
          onSelect: onSelect,
          selectedColor: const Color(0xFF1B7A43),
          unselectedColor: const Color(0xFF6B7280),
          badgeColor: const Color(0xFF6B7280),
          surfaceColor: const Color(0xFFFFFFFF),
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  setUpAll(() {
    // RenderLog.write's 800 ms debounce is a real Timer that would outlive the
    // test and try to reach Supabase.
    RenderLog.flushEnabled = false;
  });

  group('the order is the backend\'s', () {
    test('tabs are kept in PAYLOAD order, not sorted by sort or by label', () {
      // Arrive shuffled. A widget that sorted would "fix" this and pass for
      // the wrong reason; parsing must not.
      final shuffled = [
        _tab('pack', 'Pack', 70),
        _tab('customer_order', 'Customer order', 10),
        _tab('dispute', 'Dispute', 90),
        _tab('bag', 'Bag', 60),
      ];
      final p = FulfillPipelinePayload.fromJson(_payload(shuffled));
      expect(p.tabs.map((t) => t.stageKey).toList(),
          ['pack', 'customer_order', 'dispute', 'bag']);
    });

    testWidgets('the nine stages render in the pipeline sequence',
        (tester) async {
      final p = FulfillPipelinePayload.fromJson(_payload(_nine()));
      await _pump(tester, p, p.firstStage, (_) {});

      // Every stage is BUILT — nine on a 390 px phone, none dropped. That is
      // the #349 rule: a tab may scroll off screen, it may never be absent.
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      for (final label in const [
        'Customer order',
        'Supplier inquiry',
        'Supplier order',
        'Supplier shop',
        'Warehouse',
        'Bag',
        'Pack',
        'Delivery',
        'Dispute',
      ]) {
        expect(texts.contains(label), isTrue, reason: '$label is missing');
      }

      // …and in the order the payload listed them.
      final labelsInOrder =
          texts.where((s) => s.length > 2 && !s.contains('+')).toList();
      expect(
        labelsInOrder.indexOf('Customer order') <
            labelsInOrder.indexOf('Warehouse'),
        isTrue,
      );
      expect(
        labelsInOrder.indexOf('Warehouse') < labelsInOrder.indexOf('Dispute'),
        isTrue,
      );
    });

    test('firstStage is the first tab the backend sent', () {
      final p = FulfillPipelinePayload.fromJson(_payload(_nine()));
      expect(p.firstStage, 'customer_order');
    });
  });

  group('a partner is the same bar, minus', () {
    // partner_permissions for partner 1 in production: inquiry,
    // supplier_orders, collect, count, bag_mapping, assign_delivery — no
    // customer orders, no pack, no disputes.
    List<Map<String, dynamic>> partnerSix() => [
          _tab('supplier_inquiry', 'Supplier inquiry', 20),
          _tab('supplier_order', 'Supplier order', 30),
          _tab('supplier_shop', 'Supplier shop', 40),
          _tab('warehouse', 'Warehouse', 50),
          _tab('bag', 'Bag', 60),
          _tab('delivery', 'Delivery', 80),
        ];

    test('the stages they lack are ABSENT, and the rest keep their order', () {
      final p =
          FulfillPipelinePayload.fromJson(_payload(partnerSix(), isPartner: true));
      expect(p.tabs.length, 6);
      expect(p.byStage('customer_order'), isNull);
      expect(p.byStage('pack'), isNull);
      expect(p.byStage('dispute'), isNull);
      expect(p.tabs.map((t) => t.stageKey).toList(), [
        'supplier_inquiry',
        'supplier_order',
        'supplier_shop',
        'warehouse',
        'bag',
        'delivery',
      ]);
    });

    test('the same stage is the same KEY for both, at a different index', () {
      final admin = FulfillPipelinePayload.fromJson(_payload(_nine()));
      final partner =
          FulfillPipelinePayload.fromJson(_payload(partnerSix(), isPartner: true));

      // Warehouse sits at 4 for the admin and 3 for the partner. An index
      // would have selected the wrong screen; the key cannot.
      expect(admin.indexOfStage('warehouse'), 4);
      expect(partner.indexOfStage('warehouse'), 3);
      expect(admin.byStage('warehouse')!.label,
          partner.byStage('warehouse')!.label);
    });

    test('a read-only grant is a flag, never a missing tab', () {
      final p = FulfillPipelinePayload.fromJson(_payload(
          [_tab('pack', 'Pack', 70, access: 'read')],
          isPartner: true));
      expect(p.tabs.single.access, 'read');
      expect(p.tabs.single.canWrite, isFalse);
    });
  });

  group('nothing is counted in Dart', () {
    testWidgets('the badge is the backend string, cap included', (tester) async {
      final p = FulfillPipelinePayload.fromJson(_payload(_nine()));
      await _pump(tester, p, 'warehouse', (_) {});

      // '99+' is printed because the BACKEND capped it. Nothing here knows
      // what the cap is, or that there is one.
      expect(find.text('99+'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('a tab the payload sent no badge for shows none',
        (tester) async {
      final p = FulfillPipelinePayload.fromJson(
          _payload([_tab('bag', 'Bag', 60)]));
      await _pump(tester, p, 'bag', (_) {});
      expect(p.tabs.single.hasBadge, isFalse);
      expect(p.tabs.single.badgeLabel, isNull);
      // Only the label is on screen — no number of any kind.
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .toList();
      expect(texts, ['Bag']);
    });

    test('badge_count > 0 with no badge_label still shows nothing', () {
      // The BACKEND decides whether a badge is due. A non-zero count is not a
      // licence to invent one.
      final p = FulfillPipelinePayload.fromJson(_payload([
        <String, dynamic>{
          'stage_key': 'pack',
          'feature_key': 'fulfill.pack',
          'label': 'Pack',
          'sort': 70,
          'access': 'write',
          'can_write': true,
          'badge_count': 5,
          'has_badge': false,
          'badge_label': null,
        }
      ]));
      expect(p.tabs.single.badgeLabel, isNull);
    });
  });

  group('an unknown stage is silence, not a crash', () {
    test('a stage key this build never heard of resolves to nothing', () {
      final p = FulfillPipelinePayload.fromJson(_payload([
        ..._nine(),
        _tab('quality_hold', 'Quality hold', 95),
      ]));
      // It is CARRIED (the bar draws it, the backend owns the sequence)…
      expect(p.tabs.length, 10);
      expect(p.byStage('quality_hold'), isNotNull);
      // …and a stage that is not in the payload at all selects nothing.
      expect(p.indexOfStage('nonsense'), -1);
      expect(p.byStage('nonsense'), isNull);
    });

    test('a row with no stage_key is dropped rather than rendered blank', () {
      final p = FulfillPipelinePayload.fromJson(_payload([
        <String, dynamic>{'label': 'Nameless', 'sort': 5},
        _tab('bag', 'Bag', 60),
      ]));
      expect(p.tabs.map((t) => t.stageKey).toList(), ['bag']);
    });

    test('an empty payload keeps the backend\'s own empty copy', () {
      final p = FulfillPipelinePayload.fromJson(_payload(const []));
      expect(p.hasTabs, isFalse);
      expect(p.firstStage, '');
      expect(p.emptyMessage,
          'Your permissions do not include any fulfilment stage yet.');
    });

    test('a refusal carries the backend message, with no Dart fallback', () {
      final p = FulfillPipelinePayload.fromJson(<String, dynamic>{
        'ok': false,
        'error': 'not_authorized',
        'tabs': const [],
        'message': 'You do not have access to the fulfilment pipeline.',
      });
      expect(p.ok, isFalse);
      expect(p.message, 'You do not have access to the fulfilment pipeline.');
      expect(p.tabs, isEmpty);
    });
  });

  group('a tap carries the backend\'s own key', () {
    testWidgets('tapping Dispute reports stage_key, not an index or a label',
        (tester) async {
      final p = FulfillPipelinePayload.fromJson(_payload(_nine()));
      String? picked;
      await _pump(tester, p, 'customer_order', (k) => picked = k);

      await tester.ensureVisible(find.text('Dispute'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dispute'));
      await tester.pump();

      expect(picked, 'dispute');
    });

    testWidgets('every one of the nine is reachable by tap on a 390 px phone',
        (tester) async {
      final p = FulfillPipelinePayload.fromJson(_payload(_nine()));
      final tapped = <String>[];
      await _pump(tester, p, 'customer_order', tapped.add);

      for (final t in p.tabs) {
        await tester.ensureVisible(find.text(t.label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(t.label));
        await tester.pump();
      }
      expect(tapped, p.tabs.map((t) => t.stageKey).toList());
    });
  });
}
