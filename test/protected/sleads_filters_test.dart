// PROTECTED — CMD #1868. The Customers > S Leads filter row.
//
// What this holds down, and why each one was a real risk:
//
//   1. THE CHIPS ARE THE PAYLOAD'S. Their order, their labels, their counts
//      and which one is lit all arrive from sleads_filters(). The screen this
//      replaced kept `_sLeadClassLabels` and `_sLeadClassOrder` as Dart const
//      maps: adding "Hospital" or "Lab" to the taxonomy meant a deploy, and
//      the chip captions were composed in Dart as "$label (${counts[k]})".
//      Renaming a class is now one UPDATE.
//
//   2. FOUR GROUPS ARE HIDDEN UNTIL ASKED FOR. Non-targets, closed shops,
//      already-matched leads and stale ones are OFF by default and each has
//      its own switch. The switch list — keys, labels, hints, current values —
//      is data; nothing here enumerates the four.
//
//   3. TAPPING IS ADDITIVE PER CLASS, EXCLUSIVE PER PRESET, AND THE BACKEND
//      SAYS WHICH IS WHICH. The chip carries its own `kind`; "All" clears,
//      a preset replaces the class selection, a class toggles inside it.
//
//   4. THE SCORE CUT-OFF IS A BACKEND RANGE. min/max/step/default AND the
//      rendered "Score 40+" / "Any score" caption come from the payload; the
//      client never formats that sentence and never invents a default.
//
//   5. ZONE IS READ-ONLY HERE. It is the header picker's, printed verbatim
//      from the payload; the filter row offers no way to change it, which is
//      what keeps zone/date in exactly one place.
//
//   6. A SAVED VIEW ROUND-TRIPS. What is saved is the SAME normalised map the
//      RPCs take, so applying a view is a straight replacement with nothing
//      recomputed in Dart.
//
// No network, no Supabase, no goldens.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/sleads_filter_bar.dart';

Map<String, dynamic> _filters({
  List<String> classes = const [],
  String? preset,
  int minScore = 0,
  bool showNonTargets = false,
  bool showClosed = false,
  bool showMatched = false,
  bool showStale = false,
}) =>
    {
      'classes': classes,
      'preset': preset,
      'city': null,
      'search': null,
      'status': null,
      'min_score': minScore,
      'with_phone': false,
      'open_now': false,
      'with_email': false,
      'show_non_targets': showNonTargets,
      'show_closed': showClosed,
      'show_matched': showMatched,
      'show_stale': showStale,
    };

/// A payload shaped exactly like sleads_filters(). Deliberately NOT in the
/// order a Dart list would produce, and with labels that are not what any
/// client-side titlecase of the key would give.
Map<String, dynamic> _payload({
  Map<String, dynamic>? filters,
  List<Map<String, dynamic>>? views,
  int scoreValue = 0,
  String scoreLabel = 'Any score',
  String zoneLabel = 'All zones',
}) =>
    {
      'ok': true,
      'filters': filters ?? _filters(),
      'total': 9,
      'count_chip': 'S Leads (9)',
      'reset_label': 'Reset filters',
      'classes': {
        'label': 'Class',
        'chips': [
          {'key': 'all', 'kind': 'all', 'label': 'All', 'count': 9, 'count_label': '9', 'selected': true},
          {'key': 'non_pharmacy', 'kind': 'preset', 'label': 'Non-pharmacy', 'count': 4, 'count_label': '4', 'selected': false},
          {'key': 'medical_store', 'kind': 'class', 'label': 'Medical store', 'count': 2, 'count_label': '2', 'selected': false},
          {'key': 'alt_med', 'kind': 'class', 'label': 'Alt-med', 'count': 1, 'count_label': '1', 'selected': false},
        ],
      },
      'hidden': {
        'label': 'Hidden by default',
        'toggles': [
          {'key': 'show_non_targets', 'label': 'Show non-targets', 'hint': 'Leads mediBO does not sell to', 'value': false},
          {'key': 'show_closed', 'label': 'Show closed', 'hint': 'Permanently or temporarily closed on Maps', 'value': false},
          {'key': 'show_matched', 'label': 'Show matched', 'hint': 'Already a customer or supplier', 'value': false},
          {'key': 'show_stale', 'label': 'Show stale', 'hint': 'No recent review and no phone', 'value': false},
        ],
      },
      'score': {
        'label': 'Minimum score',
        'min': 0,
        'max': 100,
        'step': 5,
        'default': 0,
        'value': scoreValue,
        'value_label': scoreLabel,
      },
      'zone': {
        'label': 'Zone',
        'zone_id': null,
        'value_label': zoneLabel,
        'hint': 'Set in the header zone picker',
      },
      'views': {
        'label': 'Saved views',
        'empty': 'No saved views yet — set filters, then Save view',
        'save_label': 'Save view',
        'name_hint': 'Name this view',
        'delete_label': 'Delete',
        'items': views ?? const [],
      },
    };

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic> payload, {
  void Function(String, String)? onChipTap,
  void Function(String, bool)? onToggle,
  ValueChanged<int>? onScore,
  ValueChanged<int>? onApplyView,
  ValueChanged<int>? onDeleteView,
  VoidCallback? onSaveView,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SLeadsFilterBar(
          model: SLeadsFilterModel.fromPayload(payload),
          onChipTap: onChipTap ?? (_, __) {},
          onToggle: onToggle ?? (_, __) {},
          onScore: onScore ?? (_) {},
          onApplyView: onApplyView ?? (_) {},
          onDeleteView: onDeleteView ?? (_) {},
          onSaveView: onSaveView ?? () {},
        ),
      ),
    ),
  ));
}

void main() {
  group('1 — the chips are the payload, in payload order', () {
    test('labels and counts are read, never composed from a Dart table', () {
      final m = SLeadsFilterModel.fromPayload(_payload());
      expect(m.chips.map((c) => c['key']).toList(),
          ['all', 'non_pharmacy', 'medical_store', 'alt_med']);
      // 'Medical store' — not 'Medical Store', which is what the deleted
      // _sLeadClassLabels map said, and not initcap of the key either.
      expect(m.chips[2]['label'], 'Medical store');
      expect(m.chips[3]['label'], 'Alt-med');
      expect(m.chips[2]['count_label'], '2');
    });

    testWidgets('an unknown class the client has never heard of still renders',
        (tester) async {
      final p = _payload();
      (p['classes'] as Map)['chips'] = [
        {'key': 'veterinary', 'kind': 'class', 'label': 'Veterinary', 'count': 3, 'count_label': '3', 'selected': false},
      ];
      await _pump(tester, p);
      expect(find.text('Veterinary  3'), findsOneWidget);
    });

    testWidgets('the lit chip is the payload\'s selected flag', (tester) async {
      final p = _payload(filters: _filters(classes: ['medical_store']));
      final chips = (p['classes'] as Map)['chips'] as List;
      (chips[0] as Map)['selected'] = false;
      (chips[2] as Map)['selected'] = true;
      await _pump(tester, p);
      final chip = tester.widget<ChoiceChip>(
          find.byKey(const ValueKey('sleads_chip_medical_store')));
      expect(chip.selected, isTrue);
      final all =
          tester.widget<ChoiceChip>(find.byKey(const ValueKey('sleads_chip_all')));
      expect(all.selected, isFalse);
    });
  });

  group('2 — hidden-by-default groups', () {
    test('all four are off in a default filter state', () {
      final s = SLeadsFilterState(_filters());
      for (final k in ['show_non_targets', 'show_closed', 'show_matched', 'show_stale']) {
        expect(s.toggle(k), isFalse, reason: '$k must start hidden');
      }
    });

    testWidgets('each switch reports its own key, and nothing else moves',
        (tester) async {
      final fired = <String, bool>{};
      await _pump(tester, _payload(), onToggle: (k, v) => fired[k] = v);
      await tester.tap(find.byKey(const ValueKey('sleads_toggle_show_matched')));
      await tester.pump();
      expect(fired, {'show_matched': true});
    });

    testWidgets('the switch list is drawn from the payload, not enumerated here',
        (tester) async {
      final p = _payload();
      (p['hidden'] as Map)['toggles'] = [
        {'key': 'show_stale', 'label': 'Show stale', 'hint': '', 'value': true},
      ];
      await _pump(tester, p);
      expect(find.byType(Switch), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    test('setToggle changes exactly one key', () {
      final s = SLeadsFilterState(_filters()).setToggle('show_closed', true);
      expect(s.toggle('show_closed'), isTrue);
      expect(s.toggle('show_stale'), isFalse);
      expect(s.value['min_score'], 0);
    });
  });

  group('3 — tapping obeys the chip\'s own kind', () {
    test('a class chip toggles inside the class set', () {
      var s = SLeadsFilterState(_filters());
      s = s.tapChip('medical_store', 'class');
      expect(s.classes, ['medical_store']);
      s = s.tapChip('clinic', 'class');
      expect(s.classes, ['medical_store', 'clinic']);
      s = s.tapChip('medical_store', 'class');
      expect(s.classes, ['clinic']);
    });

    test('a preset replaces the class selection and is exclusive', () {
      var s = SLeadsFilterState(_filters(classes: ['medical_store']));
      s = s.tapChip('non_pharmacy', 'preset');
      expect(s.preset, 'non_pharmacy');
      expect(s.classes, isEmpty);
      s = s.tapChip('non_pharmacy', 'preset');
      expect(s.preset, isNull);
    });

    test('picking a class clears a preset — they are one dimension', () {
      var s = SLeadsFilterState(_filters(preset: 'non_pharmacy'));
      s = s.tapChip('clinic', 'class');
      expect(s.preset, isNull);
      expect(s.classes, ['clinic']);
    });

    test('All clears both', () {
      final s = SLeadsFilterState(_filters(classes: ['clinic'], preset: 'non_pharmacy'))
          .tapChip('all', 'all');
      expect(s.classes, isEmpty);
      expect(s.preset, isNull);
    });

    testWidgets('a tap hands back the key AND the kind', (tester) async {
      final seen = <String>[];
      await _pump(tester, _payload(),
          onChipTap: (k, kind) => seen.add('$k/$kind'));
      await tester.tap(find.byKey(const ValueKey('sleads_chip_non_pharmacy')));
      await tester.pump();
      expect(seen, ['non_pharmacy/preset']);
    });
  });

  group('4 — the score cut-off is a backend range', () {
    testWidgets('bounds and the caption come from the payload', (tester) async {
      await _pump(tester, _payload(scoreValue: 40, scoreLabel: 'Score 40+'));
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, 0);
      expect(slider.max, 100);
      expect(slider.value, 40);
      expect(slider.divisions, 20); // (100-0)/5 — the payload's own step
      // The sentence is NOT composed here: no '+' is typed in Dart.
      expect(find.text('Score 40+'), findsOneWidget);
    });

    testWidgets('zero prints the backend\'s own "any" wording', (tester) async {
      await _pump(tester, _payload());
      expect(find.text('Any score'), findsOneWidget);
      expect(find.textContaining('0+'), findsNothing);
    });

    test('setScore keeps the rest of the state', () {
      final s = SLeadsFilterState(_filters(classes: ['clinic'])).setScore(60);
      expect(s.minScore, 60);
      expect(s.classes, ['clinic']);
    });
  });

  group('5 — zone is the header picker\'s, printed and not offered', () {
    testWidgets('the active zone name is rendered verbatim', (tester) async {
      await _pump(tester, _payload(zoneLabel: 'Raipur'));
      expect(
          tester
              .widget<Text>(find.byKey(const ValueKey('sleads_zone_label')))
              .data,
          'Raipur');
    });

    testWidgets('"All zones" is the backend\'s wording, not a Dart fallback',
        (tester) async {
      await _pump(tester, _payload(zoneLabel: 'Every zone'));
      expect(find.text('Every zone'), findsOneWidget);
      expect(find.text('All zones'), findsNothing);
    });

    testWidgets('the row exposes no zone control', (tester) async {
      await _pump(tester, _payload(zoneLabel: 'Raipur'));
      expect(find.byType(DropdownButton<String?>), findsNothing);
    });
  });

  group('6 — saved views round-trip', () {
    test('a view\'s filters replace the state whole, unmodified', () {
      final saved = _filters(classes: ['wholesaler'], minScore: 60, showStale: true);
      final s = SLeadsFilterState.fromPayload(saved);
      expect(s.value, saved);
      expect(s.classes, ['wholesaler']);
      expect(s.minScore, 60);
      expect(s.toggle('show_stale'), isTrue);
    });

    testWidgets('an empty list shows the backend\'s guidance, not a blank',
        (tester) async {
      await _pump(tester, _payload());
      expect(find.text('No saved views yet — set filters, then Save view'),
          findsOneWidget);
    });

    testWidgets('one tap applies, the delete icon deletes, by id',
        (tester) async {
      int? applied;
      int? deleted;
      await _pump(
        tester,
        _payload(views: [
          {'id': 7, 'label': 'High-score wholesalers', 'filters': _filters()},
        ]),
        onApplyView: (id) => applied = id,
        onDeleteView: (id) => deleted = id,
      );
      expect(find.text('High-score wholesalers'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sleads_view_7')));
      await tester.pump();
      expect(applied, 7);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(deleted, 7);
    });

    testWidgets('Save view is the payload\'s caption', (tester) async {
      var saved = false;
      final p = _payload();
      ((p['views']) as Map)['save_label'] = 'Remember this';
      await _pump(tester, p, onSaveView: () => saved = true);
      expect(find.text('Remember this'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('sleads_view_save')));
      await tester.pump();
      expect(saved, isTrue);
    });
  });

  group('7 — the count chip is the backend\'s sentence', () {
    test('count_chip is printed, never rebuilt from total', () {
      final m = SLeadsFilterModel.fromPayload(_payload());
      expect(m.countChip, 'S Leads (9)');
      expect(m.total, 9);
    });

    testWidgets('an ok:false payload draws nothing at all', (tester) async {
      await _pump(tester, {'ok': false});
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(Switch), findsNothing);
    });
  });
}
