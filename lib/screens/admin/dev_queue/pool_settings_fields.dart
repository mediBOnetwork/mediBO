/// CMD #1949 — the Pool settings sheet is `dev_config_registry` rendered verbatim.
///
/// `pool_get().fields` lists the editable `worker_pool` settings, each carrying
/// the registry's label / help / control / current value / min / max / choices.
/// Every setting has exactly one control, and the app decides nothing: this
/// file holds the two things the sheet must get right and that a test can pin
/// down without Supabase — parsing the payload IN ORDER (skipping a control it
/// cannot draw, forward-compat) and turning the admin's edits into the
/// `pool_set` patch.
class PoolSettingField {
  /// Path under `worker_pool`, e.g. `routing.lanes.opus`.
  final String key;
  final List<String> segments;
  final String label;
  final String help;

  /// One of [controls]; anything else is skipped by [PoolSettingsFields.parse].
  final String control;
  final dynamic value;
  final num? min;
  final num? max;
  final List<Map<String, dynamic>> choices;

  const PoolSettingField({
    required this.key,
    required this.segments,
    required this.label,
    required this.help,
    required this.control,
    required this.value,
    required this.min,
    required this.max,
    required this.choices,
  });

  static const controls = {'slider', 'switch', 'number', 'choice', 'text'};

  static PoolSettingField? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final control = (raw['control'] ?? '').toString();
    if (!controls.contains(control)) return null;
    final key = (raw['key'] ?? '').toString();
    if (key.isEmpty) return null;
    final segs = (raw['segments'] as List?)?.map((e) => e.toString()).toList();
    return PoolSettingField(
      key: key,
      segments: (segs == null || segs.isEmpty) ? key.split('.') : segs,
      label: (raw['label'] ?? key).toString(),
      help: (raw['help'] ?? '').toString(),
      control: control,
      value: raw['value'],
      min: raw['min'] is num ? raw['min'] as num : num.tryParse('${raw['min'] ?? ''}'),
      max: raw['max'] is num ? raw['max'] as num : num.tryParse('${raw['max'] ?? ''}'),
      choices: ((raw['choices'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
    );
  }
}

class PoolSettingsFields {
  /// Payload order is the registry's sort order — never re-sorted here.
  static List<PoolSettingField> parse(dynamic fields) =>
      (fields is List ? fields : const [])
          .map(PoolSettingField.tryParse)
          .whereType<PoolSettingField>()
          .toList();

  /// `pool_set` shallow-merges the top level (and `routing` specially), so a
  /// nested edit is sent as its WHOLE top-level object — copied from [config]
  /// with the edit applied — while a top-level edit is sent as itself. Fields
  /// absent from [values] are not sent.
  static Map<String, dynamic> buildPatch(
    Map<String, dynamic> config,
    List<PoolSettingField> fields,
    Map<String, dynamic> values,
  ) {
    final patch = <String, dynamic>{};
    for (final f in fields) {
      if (!values.containsKey(f.key)) continue;
      final v = values[f.key];
      if (f.segments.length == 1) {
        patch[f.segments.first] = v;
        continue;
      }
      final top = f.segments.first;
      final obj = patch[top] is Map<String, dynamic>
          ? patch[top] as Map<String, dynamic>
          : _deepCopy(config[top]);
      var cur = obj;
      for (var i = 1; i < f.segments.length - 1; i++) {
        final next = cur[f.segments[i]];
        if (next is Map<String, dynamic>) {
          cur = next;
        } else {
          final m = <String, dynamic>{};
          cur[f.segments[i]] = m;
          cur = m;
        }
      }
      cur[f.segments.last] = v;
      patch[top] = obj;
    }
    return patch;
  }

  /// A number field's text becomes its value; an unparsable entry keeps the
  /// backend's current value (pool_set range-checks on save and RAISEs verbatim).
  static dynamic numberValue(String text, dynamic current) =>
      int.tryParse(text.trim()) ?? current;

  static Map<String, dynamic> _deepCopy(dynamic m) => m is Map
      ? m.map((k, v) => MapEntry(k.toString(), v is Map ? _deepCopy(v) : v))
      : <String, dynamic>{};
}
