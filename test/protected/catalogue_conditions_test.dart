// CMD #1910 — the fourth browse door, "Use / Condition".
//
// What this file holds down, and why each one is a bug worth a permanent test:
//
//   1. THE ADMIN SCREEN COMPUTES NOTHING. Every count, chip, status word and
//      field label on Uses & conditions is a string the backend printed. The
//      screen has no plural rule, no "N products", no "Live"/"Hidden" of its
//      own — the payload carries all four and the widget copies them.
//   2. A REFUSAL IS RENDERED, NOT THROWN. `ok:false` from admin_conditions_list
//      is the backend's own message on the screen, with a retry — never an
//      exception and never a blank page. The fence is the RPC's (§ the router
//      is not access control), so the screen must be able to draw the "no".
//   3. THE SCOPE LINE IS THE PAYLOAD'S. The zone and date under the title come
//      from `scope.label`, which is what admin_active_zone()/admin_active_date()
//      resolved — the screen never names a zone itself, so the counts and the
//      line they explain can never disagree.
//   4. THE EDITOR SENDS WHAT WAS TYPED, SPLIT THE WAY THE FIELD SAYS. Synonyms
//      are a comma-separated field; what goes to admin_condition_save is the
//      trimmed list, empties dropped — and the KEY of an existing use is the
//      one it was opened with, never the edited label.
//   5. AN EMPTY LIST STILL SPEAKS. `empty_label` is drawn when rows are empty,
//      so "no uses" is a sentence rather than a void.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/admin_conditions_screen.dart';
import 'package:pharma_b2b/utils/render_log.dart';

// ── fixtures ─────────────────────────────────────────────────────────────────

/// Deliberately NOT in count order and NOT alphabetical: the screen renders the
/// payload's order (the backend's sort_order), so a client-side sort would show.
Map<String, dynamic> _list({List<Map<String, dynamic>>? rows}) => {
      'ok': true,
      'title': 'Uses & conditions',
      'subtitle': 'The fourth door in Browse by. A shopper searches these words.',
      'scope': {
        'zone_id': null,
        'count_zone': 0,
        'label': 'All zones · 12 Sep 2026',
      },
      'search_hint': 'Search a use',
      'add_label': 'New use',
      'empty_label': 'No use matches this search.',
      'count_label': '3 uses',
      'total': 3,
      'offset': 0,
      'next_offset': 3,
      'has_more': false,
      'more_label': 'Load more',
      'label_field': 'Name a shopper reads',
      'rows': rows ??
          [
            {
              'key': 'fever',
              'label': 'Fever',
              'synonyms': ['bukhar', 'jwar'],
              'synonyms_label': 'bukhar, jwar',
              'sort_order': 10,
              'is_active': true,
              'status_label': 'Live',
              'status_tone': 'success',
              'count': 1240,
              'count_label': '1,240 products',
              'seeded': true,
            },
            {
              'key': 'diabetes-type-2',
              'label': 'Type 2 diabetes',
              'synonyms': ['sugar'],
              'synonyms_label': 'sugar',
              'sort_order': 130,
              'is_active': true,
              'status_label': 'Live',
              'status_tone': 'success',
              'count': 1,
              // Singular, from the BACKEND. A Dart plural rule would print
              // "1 products" here and nobody would notice for months.
              'count_label': '1 product',
              'seeded': true,
            },
            {
              'key': 'acidity',
              'label': 'Acidity & heartburn',
              'synonyms': <String>[],
              'synonyms_label': 'No other words yet',
              'sort_order': 70,
              'is_active': false,
              'status_label': 'Hidden',
              'status_tone': 'muted',
              'count': 0,
              'count_label': '0 products',
              'seeded': true,
            },
          ],
    };

Map<String, dynamic> _one() => {
      'ok': true,
      'key': 'fever',
      'label': 'Fever',
      'synonyms': ['bukhar', 'jwar'],
      'sort_order': 10,
      'is_active': true,
      'scope': {'zone_id': null, 'count_zone': 0, 'label': 'All zones · 12 Sep 2026'},
      'label_field': 'Name a shopper reads',
      'synonyms_field': 'Other words they search (comma separated)',
      'active_field': 'Show in Browse by',
      'products_title': 'Products under this use',
      'products_hint': 'Search the catalogue to add one.',
      'add_hint': 'Search a product name to add',
      'save_label': 'Save',
      'empty_label': 'No product under this use yet.',
      'count_label': '1,240 products',
      'total': 1,
      'offset': 0,
      'next_offset': 1,
      'has_more': false,
      'more_label': 'Load more',
      'rows': [
        {
          'id': 4242,
          'label': 'Dolo 650 Tablet',
          'sub_label': 'Micro Labs Ltd · Paracetamol (650mg)',
          'source': 'seed',
          'source_label': 'From the first seed',
          'remove_label': 'Remove',
        },
      ],
    };

/// Records every RPC the screen makes, and answers from a script.
class _Rpc {
  _Rpc(this.answers);
  final Map<String, Object? Function(Map<String, dynamic>?)> answers;
  final List<(String, Map<String, dynamic>?)> calls = [];

  Future<dynamic> call(String fn, Map<String, dynamic>? params) async {
    calls.add((fn, params));
    final a = answers[fn];
    return a == null ? <String, dynamic>{} : a(params);
  }

  Map<String, dynamic>? paramsOf(String fn) {
    for (final c in calls.reversed) {
      if (c.$1 == fn) return c.$2;
    }
    return null;
  }
}

Future<void> _pump(WidgetTester t, _Rpc rpc, Widget child) async {
  AdminConditionsScreen.rpcTransport = rpc.call;
  await t.pumpWidget(MaterialApp(home: child));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(() => RenderLog.flushEnabled = false);
  tearDown(() => AdminConditionsScreen.rpcTransport = null);

  testWidgets('1 · every count, chip and status word is the backend\'s',
      (t) async {
    final rpc = _Rpc({'admin_conditions_list': (_) => _list()});
    await _pump(t, rpc, const AdminConditionsScreen());

    // The counts, verbatim — including the singular the backend chose.
    expect(find.text('1,240 products'), findsOneWidget);
    expect(find.text('1 product'), findsOneWidget);
    expect(find.text('0 products'), findsOneWidget);
    expect(find.text('3 uses'), findsOneWidget);

    // The status words are the payload's, not a Dart ternary over is_active.
    expect(find.text('Live'), findsNWidgets(2));
    expect(find.text('Hidden'), findsOneWidget);

    // The synonym line is a string, never joined here.
    expect(find.text('bukhar, jwar'), findsOneWidget);
    expect(find.text('No other words yet'), findsOneWidget);
  });

  testWidgets('2 · the rows keep the payload order, never a client sort',
      (t) async {
    final rpc = _Rpc({'admin_conditions_list': (_) => _list()});
    await _pump(t, rpc, const AdminConditionsScreen());

    final labels = t
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data ?? '')
        .where((s) => s == 'Fever' || s == 'Type 2 diabetes' || s == 'Acidity & heartburn')
        .toList();
    // sort_order says 10 / 130 / 70 — the BACKEND still sent them in this
    // order, so this is what must be drawn.
    expect(labels, ['Fever', 'Type 2 diabetes', 'Acidity & heartburn']);
  });

  testWidgets('3 · ok:false renders the backend\'s refusal, not a blank page',
      (t) async {
    final rpc = _Rpc({
      'admin_conditions_list': (_) => {
            'ok': false,
            'error': 'denied',
            'tone': 'danger',
            'message': 'Only an admin can edit uses.',
          }
    });
    await _pump(t, rpc, const AdminConditionsScreen());

    expect(find.text('Only an admin can edit uses.'), findsOneWidget);
    expect(find.text('Fever'), findsNothing);
  });

  testWidgets('4 · the scope line is the payload\'s zone and date', (t) async {
    final rpc = _Rpc({'admin_conditions_list': (_) => _list()});
    await _pump(t, rpc, const AdminConditionsScreen());
    expect(find.text('All zones · 12 Sep 2026'), findsOneWidget);
  });

  testWidgets('5 · an empty list still speaks', (t) async {
    final rpc = _Rpc({'admin_conditions_list': (_) => _list(rows: const [])});
    await _pump(t, rpc, const AdminConditionsScreen());
    expect(find.text('No use matches this search.'), findsOneWidget);
  });

  testWidgets('6 · save sends the opened key and the split synonyms',
      (t) async {
    final rpc = _Rpc({
      'admin_conditions_list': (_) => _list(),
      'admin_condition_get': (_) => _one(),
      'admin_condition_save': (_) =>
          {'ok': true, 'key': 'fever', 'tone': 'success', 'message': 'Saved — live now.'},
    });
    await _pump(t, rpc, const AdminConditionsScreen());

    await t.tap(find.text('Fever'));
    await t.pumpAndSettle();

    // The field arrived pre-filled from the payload, comma separated.
    expect(find.text('bukhar, jwar'), findsOneWidget);
    expect(find.text('Products under this use'), findsOneWidget);
    expect(find.text('Dolo 650 Tablet'), findsOneWidget);
    expect(find.text('From the first seed'), findsOneWidget);

    await t.enterText(
        find.widgetWithText(TextField, 'bukhar, jwar'), ' bukhar , jwar ,, tez bukhar ');
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();

    final sent = rpc.paramsOf('admin_condition_save')!;
    // The KEY is the one the row was opened with — never the edited label.
    expect(sent['p_key'], 'fever');
    expect(sent['p_synonyms'], ['bukhar', 'jwar', 'tez bukhar']);
    expect(sent['p_is_active'], true);
  });

  testWidgets('7 · removing a product names the row\'s id and off', (t) async {
    final rpc = _Rpc({
      'admin_conditions_list': (_) => _list(),
      'admin_condition_get': (_) => _one(),
      'admin_condition_map': (_) =>
          {'ok': true, 'on': false, 'tone': 'success', 'message': 'Removed — live now.'},
    });
    await _pump(t, rpc, const AdminConditionsScreen());

    await t.tap(find.text('Fever'));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove'));
    await t.pumpAndSettle();

    final sent = rpc.paramsOf('admin_condition_map')!;
    expect(sent['p_key'], 'fever');
    expect(sent['p_product_id'], 4242);
    expect(sent['p_on'], false);
  });
}
