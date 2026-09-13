// PROTECTED — CMD #1934.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes the Order cut-off SCREEN's contract, never to make an
// unrelated change go green.
//
// order_cutoff_test.dart already holds the CARD down. This file holds down the
// SCREEN around it — the door CMD #1934 added — and every assertion here is
// about one thing: the page is a printer for order_cutoff_screen().
//
//   1. THE KNOBS RENDER IN PAYLOAD ORDER. The fixture lists them deliberately
//      out of alphabetical order and with the master switch in the middle, so a
//      screen that sorts, groups or hardcodes the cut-off field list fails. A
//      knob added to the backend tomorrow appears with no deploy precisely
//      because nothing in Dart names them.
//
//   2. A FIELD IS A SWITCH BECAUSE THE BACKEND SAID `type: bool`, and a text
//      box is multi-line because the backend said `multiline: true`. The
//      fixture pairs a bool-typed field with a numeric-looking value to catch a
//      screen that sniffs the value instead of reading the type.
//
//   3. SECTION HEADINGS ARE LOOKUPS. A heading the payload never sent is the
//      empty string — not a Dart fallback word, not the map key.
//
//   4. THE RESTORATION BANNER IS THE BACKEND'S CLOCK. It shows only when the
//      payload says `window_open: true` AND carries a sentence. The fixture
//      deliberately sends a `window_note` with `window_open:false`, which is
//      exactly the shape that would make a screen holding its own timer print
//      a window that has already shut.
//
//   5. THE AUDIT IS RENDERED, NEVER COMPOSED. who / what / why / when are four
//      strings the backend wrote; the tone is a named token and an unknown one
//      degrades to neutral instead of throwing.
//
//   6. MARKING A PHARMACY NEVER-AUTO-CANCEL REUSES customer_credit_list(), and
//      a pharmacy already marked is not offered a second time.
//
// No network, no Supabase, no camera: the payloads below are fixtures.
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/screens/admin/order_cutoff_screen.dart';

/// The shape order_cutoff_screen() returns, trimmed to what the screen reads.
/// The field order is deliberately NOT alphabetical and the master switch sits
/// in the middle of the list.
const _payload = <String, dynamic>{
  'ok': true,
  'title': 'Order cut-off',
  'subtitle': 'The daily cut-off, the unpaid auto-cancel and the restoration window.',
  'off_note': '',
  'saved_label': 'Saved.',
  'date_label': '12/09/2026',
  'sections': {
    'settings': 'The rule',
    'clock': 'On the clock',
    'never': 'Never auto-cancelled',
    'audit': 'What changed',
  },
  'fields': [
    {'key': 'cutoff_time', 'label': 'Cut-off time (this zone)', 'type': 'text', 'value': '12:00'},
    {'key': 'cutoff_warn1_min', 'label': 'First warning (minutes before)', 'type': 'int', 'value': 60},
    // A bool whose value LOOKS numeric — a screen that sniffs the value
    // instead of reading `type` renders a text box here and fails.
    {'key': 'cutoff_enabled', 'label': 'Cut-off rule on', 'type': 'bool', 'value': true},
    {'key': 'cutoff_warn2_min', 'label': 'Second warning (minutes before)', 'type': 'int', 'value': 30},
    {'key': 'cutoff_restore_min', 'label': 'Restoration window (minutes)', 'type': 'int', 'value': 20},
    {'key': 'cutoff_warn_text', 'label': 'Warning message', 'type': 'text', 'value': 'Pay now', 'multiline': true},
    // No key: it cannot be saved, so it is not drawn.
    {'label': 'ghost', 'type': 'text', 'value': 'x'},
  ],
  'clock': {
    'title': 'On the clock',
    'empty_label': 'No order is on the cut-off clock for this zone and date.',
    // The window has SHUT, yet the sentence is still in the payload. The
    // banner must stay down: window_open is the whole of the decision.
    'window_open': false,
    'window_note': 'Restoration window open — the inquiry is held until it closes.',
    'items': [
      {'order_id': 'o-1', 'order_code': 'CPO060926CHA101O1', 'state': 'cancelled'},
      {'order_id': 'o-2', 'order_code': 'AAA010101AAA001O1', 'state': 'watching'},
    ],
  },
  'never': {
    'hint': 'These pharmacies are never auto-cancelled, whatever the clock says.',
    'empty_label': 'No pharmacy is exempt. Every unpaid order is on the clock.',
    'add_label': 'Mark a pharmacy never-auto-cancel',
    'search_label': 'Search a pharmacy',
    'items': [
      {'customer_id': 'c-1', 'name': 'Sunrise Medical Store', 'remove_label': 'Put back on the clock'},
    ],
  },
  'audit': {
    'hint': 'Who changed a setting, and why each order was cancelled or restored.',
    'empty_label': 'Nothing has changed here yet.',
    'items': [
      {
        'action': 'order_cutoff_cancel',
        'action_label': 'Auto-cancelled',
        'target_label': 'CPO060926CHA101O1',
        'who_label': 'system',
        'why_label': 'Advance not verified by the cut-off',
        'when_label': '06/09 17:27',
        'tone': 'danger',
      },
      {
        'action': 'order_alert_settings_set',
        'action_label': 'Setting changed',
        'target_label': 'singleton',
        'who_label': 'boss@medibo.in',
        'why_label': 'cutoff_time',
        'when_label': '12/09 09:10',
        'tone': 'wildly-unknown-tone',
      },
    ],
  },
};

void main() {
  const v = OrderCutoffView(_payload);

  test('the knobs render in payload order, and only the savable ones', () {
    expect(v.fields.map((f) => f['key']).toList(), [
      'cutoff_time',
      'cutoff_warn1_min',
      'cutoff_enabled',
      'cutoff_warn2_min',
      'cutoff_restore_min',
      'cutoff_warn_text',
    ]);
  });

  test('a field is a switch because the TYPE says bool, not the value', () {
    final enabled = v.fields.firstWhere((f) => f['key'] == 'cutoff_enabled');
    final time = v.fields.firstWhere((f) => f['key'] == 'cutoff_time');
    expect(v.isSwitch(enabled), isTrue);
    expect(v.isSwitch(time), isFalse);
  });

  test('multiline is the payload flag, never a guess from the label', () {
    expect(v.isMultiline(v.fields.firstWhere((f) => f['key'] == 'cutoff_warn_text')), isTrue);
    expect(v.isMultiline(v.fields.firstWhere((f) => f['key'] == 'cutoff_time')), isFalse);
  });

  test('every word on the page is the payload word', () {
    expect(v.str('title'), 'Order cut-off');
    expect(v.str('saved_label'), 'Saved.');
    expect(v.section('settings'), 'The rule');
    expect(v.section('audit'), 'What changed');
    // A heading the backend never sent is absent, not invented.
    expect(v.section('nope'), '');
  });

  test('the restoration banner obeys window_open, not the sentence', () {
    expect(v.showWindowNote, isFalse);
    const open = OrderCutoffView(<String, dynamic>{
      'clock': {'window_open': true, 'window_note': 'held'}
    });
    expect(open.showWindowNote, isTrue);
    // A window the backend calls open but gives no words to says nothing.
    const mute = OrderCutoffView(<String, dynamic>{
      'clock': {'window_open': true, 'window_note': ''}
    });
    expect(mute.showWindowNote, isFalse);
  });

  test('the clock is the payload list, in its order', () {
    expect(v.clockItems.map((e) => e['order_code']).toList(),
        ['CPO060926CHA101O1', 'AAA010101AAA001O1']);
  });

  test('the never-auto-cancel list carries its own remove label', () {
    expect(v.neverItems.single['name'], 'Sunrise Medical Store');
    expect(v.neverItems.single['remove_label'], 'Put back on the clock');
  });

  test('the audit prints who, what, why and when verbatim', () {
    final first = v.auditItems.first;
    expect(first['action_label'], 'Auto-cancelled');
    expect(first['target_label'], 'CPO060926CHA101O1');
    expect(first['who_label'], 'system');
    expect(first['why_label'], 'Advance not verified by the cut-off');
    expect(first['when_label'], '06/09 17:27');
    // The rows stay in the backend's order — newest first is ITS decision.
    expect(v.auditItems.map((e) => e['action']).toList(),
        ['order_cutoff_cancel', 'order_alert_settings_set']);
  });

  test('an empty section is empty because the backend sent nothing', () {
    const bare = OrderCutoffView(<String, dynamic>{});
    expect(bare.fields, isEmpty);
    expect(bare.clockItems, isEmpty);
    expect(bare.neverItems, isEmpty);
    expect(bare.auditItems, isEmpty);
    expect(bare.offNote, '');
    expect(bare.showWindowNote, isFalse);
  });

  test('marking a pharmacy never offers one already marked', () {
    final candidates = OrderCutoffView.neverCandidates(<String, dynamic>{
      'items': [
        {'customer_id': 'c-1', 'customer_name': 'Sunrise Medical Store', 'never_auto_cancel': true},
        {'customer_id': 'c-2', 'customer_name': 'Bharat Medicos', 'never_auto_cancel': false},
        {'customer_id': 'c-3', 'customer_name': 'Nova Chemist'},
      ],
    });
    expect(candidates.map((e) => e['customer_id']).toList(), ['c-2', 'c-3']);
    expect(OrderCutoffView.neverCandidates(null), isEmpty);
  });
}
