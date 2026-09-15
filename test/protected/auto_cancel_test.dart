// PROTECTED — CMD #2053.
//
// See CLAUDE.md: runs before EVERY deploy; editable only by a CHANGE that
// deliberately changes Auto cancel behaviour, never to make an unrelated
// change go green.
//
// What this holds down — the Auto cancel screen (formerly "Order cut-off",
// which crashed with 42883 before this command and could not be opened at
// all):
//
//   1. **ONE FLAG, AND DART NEVER NAMES IT.** The pill at the top of the
//      screen is `payload.toggle`, in the SAME shape a Dashboard automation
//      chip arrives in, carrying the backend's own key, label, ON/OFF word
//      and tone. Nothing here may write "Auto cancel", "ON", "OFF", or decide
//      a tone from `on`. Both surfaces read one flag, so the pill the screen
//      draws and the pill the Dashboard draws are the same object.
//
//   2. **THE SENTENCE IS THE BACKEND'S.** "Auto cancel is off." when it is
//      off, and the pause-outside-hours sentence when it is on, both arrive
//      as `toggle.note`. Dart chooses neither — it prints whichever came.
//
//   3. **ABSENCE IS EXPLICIT.** No `toggle` in the payload means no pill,
//      rather than a pill Dart invented from `enabled`. A payload from an
//      older build therefore degrades to no control, never to a wrong one.
//
//   4. **THE FIELD LIST IS THE PAYLOAD'S.** The screen renders the knobs in
//      payload order and filters only a field with no key (it cannot be
//      saved). It does not drop `cutoff_enabled` itself — the BACKEND stopped
//      sending it, because the pill owns that flag now and a screen must
//      never offer two controls for one value.
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/order_cutoff_screen.dart';

Map<String, dynamic> _payload({
  required bool on,
  required String note,
  bool withToggle = true,
}) =>
    {
      'ok': true,
      'title': 'Auto cancel',
      'subtitle': 'Unpaid orders are warned and then cancelled after the cut-off.',
      'enabled': on,
      if (withToggle)
        'toggle': {
          'key': 'auto_cancel',
          'setting_key': 'cutoff_enabled',
          'label': 'Auto cancel',
          'on': on,
          'state_label': on ? 'ON' : 'OFF',
          'tone': on ? 'on' : 'off',
          'note': note,
        },
      'off_note': on ? '' : note,
      'on_note': on ? note : '',
      'fields': [
        {'key': 'cutoff_time', 'label': 'Cut-off time (this zone)', 'type': 'text', 'value': '18:00'},
        {'key': 'cutoff_warn1_min', 'label': 'First warning (minutes before)', 'type': 'int', 'value': 60},
        {'label': 'a field with no key', 'type': 'text', 'value': 'x'},
      ],
      'sections': {'settings': 'Auto cancel settings'},
      'clock': {'items': []},
      'never': {'items': []},
      'audit': {'items': []},
    };

void main() {
  group('CMD #2053 — Auto cancel pill', () {
    test('OFF: the pill and its sentence are the backend\'s, verbatim', () {
      const note = 'Auto cancel is off.';
      final v = OrderCutoffView(_payload(on: false, note: note));

      expect(v.togglePills, hasLength(1));
      final pill = v.togglePills.single;
      expect(pill.key, 'auto_cancel');
      expect(pill.label, 'Auto cancel');
      expect(pill.on, isFalse);
      expect(pill.stateLabel, 'OFF');
      expect(pill.tone, 'off');
      expect(v.toggleNote, note);
      // The old banner field still carries the same sentence, so an older
      // reader of off_note is not left blank.
      expect(v.offNote, note);
    });

    test('ON: the pause-outside-hours sentence is what the screen prints', () {
      const note = 'Auto cancel is on. Unpaid orders are warned and cancelled '
          'only outside shop hours — while the shop is open nothing is '
          'auto-cancelled.';
      final v = OrderCutoffView(_payload(on: true, note: note));

      expect(v.togglePills.single.on, isTrue);
      expect(v.togglePills.single.stateLabel, 'ON');
      expect(v.togglePills.single.tone, 'on');
      expect(v.toggleNote, note);
      // Nothing is "off" while it is on — the off banner is empty, and it is
      // empty because the BACKEND emptied it.
      expect(v.offNote, isEmpty);
    });

    test('a payload with no toggle draws no pill — Dart invents none', () {
      final v = OrderCutoffView(
          _payload(on: true, note: 'x', withToggle: false));
      expect(v.togglePills, isEmpty);
      expect(v.toggleNote, isEmpty);
    });

    test('the pill is dropped when the backend named it nothing', () {
      final v = OrderCutoffView({
        'ok': true,
        'toggle': {'key': 'auto_cancel', 'on': true},
      });
      // listFrom() requires a key AND a label: a chip with no word on it is
      // not rendered rather than being given one here.
      expect(v.togglePills, isEmpty);
    });

    test('the knobs render in payload order; only a keyless field is dropped',
        () {
      final v = OrderCutoffView(_payload(on: true, note: 'x'));
      expect(v.fields.map((f) => f['key']).toList(),
          ['cutoff_time', 'cutoff_warn1_min']);
      // The flag itself is NOT in the list — the backend stopped sending it,
      // so the screen has exactly one control for it.
      expect(v.fields.any((f) => f['key'] == 'cutoff_enabled'), isFalse);
      expect(v.fields.any((f) => f['key'] == 'cutoff_pause_outside_hours'),
          isFalse);
    });

    test('the screen words nothing: title and sections come from the payload',
        () {
      final v = OrderCutoffView(_payload(on: false, note: 'n'));
      expect(v.str('title'), 'Auto cancel');
      expect(v.section('settings'), 'Auto cancel settings');
      expect(v.section('nothing_like_this'), isEmpty);
    });
  });
}
