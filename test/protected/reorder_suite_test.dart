// PROTECTED — CHANGE #173.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes reorder behaviour.
//
// What this holds down, for the B2B repeat-buying suite:
//
//   1. RANKING IS THE SERVER'S. reorder_suggestions() ranks rows "due first,
//      then most overdue, then most frequent". The screen splits that list into
//      its two sections by FILTERING, so payload order survives inside each
//      section. The fixture is deliberately interleaved (due, not-due, due) —
//      a client-side sort would reorder it and fail here.
//
//   2. NO INVENTED COPY. Every label is read from the payload; an absent key
//      renders as empty, never as an English word chosen in Dart. This is what
//      keeps the screen honest when the backend adds a language or changes
//      wording without a deploy.
//
//   3. AVAILABILITY IS A FLAG, NOT A NUMBER. A row offers "Add" only when the
//      backend said can_add — the screen never looks at a stock count and never
//      decides for itself that something is orderable.
//
//   4. THE SHELF LEVEL CLEARS. An empty (or unparseable) shelf box must reach
//      reorder_prefs_set as NULL so the stored level is cleared. Sending 0
//      would silently mean "a shelf level of zero" and the low-stock cron would
//      then nudge on a threshold the pharmacy never set.
//
//   5. TURNING THE REMINDER OFF IS SENT, NOT OMITTED. notify:false travels as
//      false; a missing param would leave the old opt-in in place and keep
//      WhatsApp nudging a pharmacy that just switched it off.
//
// Fixture shape mirrors the live reorder_suggestions() payload (2026-08-16).
// Pure Dart: no network, no Supabase, no widget tree, no timers.

import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/models/reorder_view.dart';

Map<String, dynamic> _item({
  required String id,
  required String name,
  bool due = false,
  bool canAdd = true,
  bool remindOn = false,
  String qtyLabel = 'Usual: 3',
  String dueLabel = '',
  String remindLabel = 'Remind me',
  String shelfLabel = '',
  int? shelfLevel,
}) =>
    <String, dynamic>{
      'product_id': id,
      'name': name,
      'usual_qty': 3,
      'qty_label': qtyLabel,
      'since_label': '7 days ago',
      'due': due,
      'due_label': dueLabel,
      'price_display': '₹120.00',
      'can_add': canAdd,
      'unavailable_label': canAdd ? '' : 'Currently unavailable',
      'remind_on': remindOn,
      'remind_label': remindLabel,
      'shelf_level': shelfLevel,
      'shelf_label': shelfLabel,
    };

// Deliberately interleaved: due, NOT due, due. Any client-side sort shows up.
final Map<String, dynamic> _payload = <String, dynamic>{
  'ok': true,
  'has_history': true,
  'has_due': true,
  'due_count': 2,
  'title': 'Reorder',
  'due_title': 'Due for reorder',
  'all_title': 'Your regular items',
  'add_all_label': 'Add all due to cart',
  'add_label': 'Add',
  'remind_title': 'Low-stock reminder',
  'items': <Map<String, dynamic>>[
    _item(id: '181726', name: 'Rozustat 20 Tablet', due: true, dueLabel: 'Due now'),
    _item(id: '198836', name: 'Temsan-AM 5 Tablet'),
    _item(
      id: '259152',
      name: 'Inditel CH 40 Tablet',
      due: true,
      dueLabel: 'Due now',
      remindOn: true,
      remindLabel: 'Reminder on',
      shelfLevel: 12,
      shelfLabel: 'Shelf level 12',
    ),
    _item(id: '233335', name: 'Ozamore Cream', canAdd: false),
  ],
};

void main() {
  group('reorder suggestions — the server ranks, the screen renders', () {
    test('sections filter the payload without re-sorting it', () {
      final v = ReorderSuggestions(_payload);

      expect(v.hasHistory, isTrue);
      expect(v.hasDue, isTrue);
      expect(v.items.length, 4);

      // Due section keeps payload order (181726 before 259152), and the
      // not-due row that sat BETWEEN them is not dragged along.
      expect(v.due.map((e) => e['product_id']).toList(),
          <String>['181726', '259152']);
      expect(v.rest.map((e) => e['product_id']).toList(),
          <String>['198836', '233335']);

      // Together the two sections are exactly the payload, nothing dropped.
      expect(v.due.length + v.rest.length, v.items.length);
    });

    test('labels are read, never invented', () {
      final v = ReorderSuggestions(_payload);
      expect(v.label('due_title'), 'Due for reorder');
      expect(v.label('add_all_label'), 'Add all due to cart');

      // A key the backend did not send renders as nothing — NOT as a Dart word.
      expect(v.label('manage_label'), '');
      expect(ReorderSuggestions.field(v.due.first, 'shelf_label'), '');

      // Row labels come through verbatim, including the reminder wording that
      // states its own state ("Reminder on" vs "Remind me").
      expect(ReorderSuggestions.field(v.due.first, 'remind_label'), 'Remind me');
      expect(ReorderSuggestions.field(v.due.last, 'remind_label'), 'Reminder on');
      expect(ReorderSuggestions.field(v.due.last, 'shelf_label'), 'Shelf level 12');
      expect(ReorderSuggestions.field(v.due.first, 'due_label'), 'Due now');
    });

    test('add is offered on the backend flag, and the reminder state is read', () {
      final v = ReorderSuggestions(_payload);
      final oos = v.rest.firstWhere((e) => e['product_id'] == '233335');

      expect(ReorderSuggestions.canAdd(oos), isFalse);
      expect(ReorderSuggestions.field(oos, 'unavailable_label'),
          'Currently unavailable');
      expect(ReorderSuggestions.canAdd(v.due.first), isTrue);

      expect(ReorderSuggestions.remindOn(v.due.first), isFalse);
      expect(ReorderSuggestions.remindOn(v.due.last), isTrue);
    });

    test('an empty payload is an empty state, not a crash', () {
      const v = ReorderSuggestions(<String, dynamic>{'ok': true, 'has_history': false});
      expect(v.hasHistory, isFalse);
      expect(v.items, isEmpty);
      expect(v.due, isEmpty);
      expect(v.rest, isEmpty);
      expect(v.label('empty_title'), '');
    });
  });

  group('reorder_prefs_set params', () {
    test('an empty shelf box clears the level (null, never 0)', () {
      final p = ReorderPrefsRequest.build(
          productId: '181726', shelfText: '', notify: true);
      expect(p['p_product_id'], '181726');
      expect(p['p_shelf_level'], isNull);
      expect(p['p_notify'], isTrue);
    });

    test('a typed level is sent as an int, spaces and junk tolerated', () {
      expect(
          ReorderPrefsRequest.build(
              productId: 'x', shelfText: ' 12 ', notify: true)['p_shelf_level'],
          12);
      expect(
          ReorderPrefsRequest.build(
              productId: 'x', shelfText: 'abc', notify: true)['p_shelf_level'],
          isNull);
      expect(
          ReorderPrefsRequest.build(
              productId: 'x', shelfText: '0', notify: true)['p_shelf_level'],
          0);
    });

    test('turning the reminder off travels as false', () {
      final p = ReorderPrefsRequest.build(
          productId: '259152', shelfText: '12', notify: false);
      expect(p.containsKey('p_notify'), isTrue);
      expect(p['p_notify'], isFalse);
      expect(p['p_shelf_level'], 12);
    });
  });
}
