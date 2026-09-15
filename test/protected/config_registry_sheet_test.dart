// CMD #1949 — the Pool settings sheet is dev_config_registry rendered verbatim.
//
// pool_get().fields carries one row per editable setting (label, help, control,
// value, range, choices). The sheet draws them in payload order, skips a
// control it cannot draw (forward compat), keeps label/help verbatim, and turns
// the admin's edits into the pool_set patch: a top-level key as itself, a nested
// key as its WHOLE top-level object (pool_set shallow-merges), a text control
// as typed (the backend parses it), an unparsable number as the stored value.
// Pure class, no widgets, no Supabase — runs on the VM in milliseconds.
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/dev_queue/pool_settings_fields.dart';

// Deliberately NOT in alphabetical or "natural" order — the registry's
// sort_order is the order, and the sheet must not re-sort.
const _payload = [
  {
    'key': 'routing.lanes.opus',
    'segments': ['routing', 'lanes', 'opus'],
    'label': 'Opus workers',
    'help': '',
    'control': 'number',
    'value': 7,
    'min': 0,
    'max': 16,
    'choices': [],
  },
  {
    'key': 'cap',
    'segments': ['cap'],
    'label': 'Workers (max parallel)',
    'help': 'How many commands build at once.',
    'control': 'slider',
    'value': 4,
    'min': 1,
    'max': 8,
    'choices': [],
  },
  {
    'key': 'billing_mode',
    'segments': ['billing_mode'],
    'label': 'Billing mode',
    'help': 'Max plan shrinks on quota; API key uses the daily ₹ cap.',
    'control': 'choice',
    'value': 'max_subscription',
    'choices': [
      {'value': 'max_subscription', 'label': 'Max plan'},
      {'value': 'api', 'label': 'API key'},
    ],
  },
  {
    'key': 'future.thing',
    'segments': ['future', 'thing'],
    'label': 'A control this build cannot draw',
    'control': 'colour_wheel',
    'value': 1,
  },
  {
    'key': 'context_compact_pct',
    'segments': ['context_compact_pct'],
    'label': 'Compact context at %',
    'help': 'A build session past this % of its context window is compacted.',
    'control': 'number',
    'value': 60,
    'min': 30,
    'max': 95,
  },
  {
    'key': 'deploy_wait.minutes_by_position',
    'segments': ['deploy_wait', 'minutes_by_position'],
    'label': 'Safety check by queue position (minutes)',
    'help': 'Comma-separated, one value per position.',
    'control': 'text',
    'value': '2, 5, 5, 10',
  },
];

const _config = {
  'cap': 4,
  'max': 8,
  'min': 1,
  'billing_mode': 'max_subscription',
  'context_compact_pct': 60,
  'routing': {
    'enabled': true,
    'log': true,
    'lanes': {'opus': 7, 'sonnet': 0},
    'opus_markers': ['migration', 'schema'],
  },
  'deploy_wait': {
    'minutes_by_position': [2, 5, 5, 10],
    'safety_poll_minutes': 15,
    'urgent_jumps': true,
  },
};

void main() {
  group('CMD #1949 — pool settings fields are the registry, verbatim', () {
    test('payload order is kept and an unknown control is skipped silently', () {
      final fields = PoolSettingsFields.parse(_payload);
      expect(fields.map((f) => f.key).toList(), [
        'routing.lanes.opus',
        'cap',
        'billing_mode',
        'context_compact_pct',
        'deploy_wait.minutes_by_position',
      ]);
    });

    test('label, help, range and choices are the backend strings, untouched', () {
      final fields = PoolSettingsFields.parse(_payload);
      final cap = fields[1];
      expect(cap.label, 'Workers (max parallel)');
      expect(cap.help, 'How many commands build at once.');
      expect(cap.control, 'slider');
      expect(cap.min, 1);
      expect(cap.max, 8);
      final billing = fields[2];
      expect(billing.choices.map((c) => c['label']).toList(), ['Max plan', 'API key']);
      final compact = fields[3];
      expect(compact.help, 'A build session past this % of its context window is compacted.');
      expect(compact.min, 30);
      expect(compact.max, 95);
    });

    test('a null/garbage payload is an empty list, never a throw', () {
      expect(PoolSettingsFields.parse(null), isEmpty);
      expect(PoolSettingsFields.parse('nope'), isEmpty);
      expect(PoolSettingsFields.parse([1, 'x', null, {}]), isEmpty);
      expect(PoolSettingsFields.parse([{'control': 'number'}]), isEmpty,
          reason: 'a field without a key cannot be patched');
    });

    test('the patch sends a top-level key as itself', () {
      final fields = PoolSettingsFields.parse(_payload);
      final patch = PoolSettingsFields.buildPatch(
          _config, fields, {'cap': 6, 'context_compact_pct': 70});
      expect(patch, {'cap': 6, 'context_compact_pct': 70});
    });

    test('a nested key is sent as its WHOLE top-level object with the edit applied',
        () {
      final fields = PoolSettingsFields.parse(_payload);
      final patch = PoolSettingsFields.buildPatch(
          _config, fields, {'routing.lanes.opus': 5});
      expect(patch.keys.toList(), ['routing']);
      expect(patch['routing'], {
        'enabled': true,
        'log': true,
        'lanes': {'opus': 5, 'sonnet': 0},
        'opus_markers': ['migration', 'schema'],
      });
      // The config we were handed is not mutated.
      expect((_config['routing'] as Map)['lanes'], {'opus': 7, 'sonnet': 0});
    });

    test('a text control is sent as typed — the backend parses it', () {
      final fields = PoolSettingsFields.parse(_payload);
      final patch = PoolSettingsFields.buildPatch(
          _config, fields, {'deploy_wait.minutes_by_position': '2 · 5 · 5 · 10'});
      expect(patch['deploy_wait'], {
        'minutes_by_position': '2 · 5 · 5 · 10',
        'safety_poll_minutes': 15,
        'urgent_jumps': true,
      });
    });

    test('fields the admin did not touch are not sent', () {
      final fields = PoolSettingsFields.parse(_payload);
      expect(PoolSettingsFields.buildPatch(_config, fields, {}), isEmpty);
    });

    test('an unparsable number keeps the stored value (backend range-checks)', () {
      expect(PoolSettingsFields.numberValue(' 42 ', 60), 42);
      expect(PoolSettingsFields.numberValue('', 60), 60);
      expect(PoolSettingsFields.numberValue('x', 60), 60);
    });
  });
}
