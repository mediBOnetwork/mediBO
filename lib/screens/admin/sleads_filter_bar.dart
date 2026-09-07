// CMD #1868 — the Customers > S Leads filter row.
//
// THE BACKEND DECIDES, THIS FILE DRAWS. `sleads_filters(filters)` returns the
// whole row: which class chips exist, their order, their labels, their counts,
// which one is selected, the four hidden-by-default toggles with their own
// copy, the score slider's bounds and its rendered value label, the active
// zone's name and the saved views. Nothing below invents a chip, a label, a
// count, a default or an order — a new class is one INSERT, not a deploy.
//
// The filter state itself is ONE json map with a fixed shape, normalised by
// the backend (`_sleads_filters_norm`). That is why saving a view and applying
// it later is a round-trip with no client-side translation: the same map goes
// to sleads_page(), to sleads_count() and into lead_views.filters.
//
// Pure of Supabase on purpose — the RPCs live in
// services/sleads_filter_service.dart — so the model and the widget can both
// be mounted in test/protected/sleads_filters_test.dart with no network.

import 'package:flutter/material.dart';

import '../../design_tokens.dart';

/// The canonical filter map, exactly the shape `_sleads_filters_norm` returns.
///
/// Every mutation returns a NEW map so a rebuild is a plain setState, and the
/// map is handed to the RPCs untouched.
class SLeadsFilterState {
  const SLeadsFilterState([this.value = const <String, dynamic>{}]);

  final Map<String, dynamic> value;

  static const String presetKey = 'preset';
  static const String classesKey = 'classes';
  static const String scoreKey = 'min_score';

  Map<String, dynamic> get _copy => Map<String, dynamic>.from(value);

  List<String> get classes =>
      (value[classesKey] as List?)?.map((e) => e.toString()).toList() ?? const [];

  String? get preset {
    final p = value[presetKey];
    final s = p?.toString() ?? '';
    return s.isEmpty ? null : s;
  }

  int get minScore => (value[scoreKey] as num?)?.toInt() ?? 0;

  bool toggle(String key) => value[key] == true;

  /// Tapping a chip. `kind` is the BACKEND's own kind for that chip — the
  /// client never decides that "non_pharmacy" behaves differently from
  /// "clinic"; the payload says so.
  SLeadsFilterState tapChip(String key, String kind) {
    final m = _copy;
    switch (kind) {
      case 'all':
        m[classesKey] = const <String>[];
        m[presetKey] = null;
        break;
      case 'preset':
        m[classesKey] = const <String>[];
        m[presetKey] = m[presetKey] == key ? null : key;
        break;
      default:
        final sel = classes.toList();
        if (sel.contains(key)) {
          sel.remove(key);
        } else {
          sel.add(key);
        }
        m[classesKey] = sel;
        m[presetKey] = null;
    }
    return SLeadsFilterState(m);
  }

  SLeadsFilterState setToggle(String key, bool on) {
    final m = _copy;
    m[key] = on;
    return SLeadsFilterState(m);
  }

  SLeadsFilterState setScore(int score) {
    final m = _copy;
    m[scoreKey] = score;
    return SLeadsFilterState(m);
  }

  /// Everything except the free-text search, which the search box owns.
  SLeadsFilterState withSearch(String? search) {
    final m = _copy;
    final s = (search ?? '').trim();
    m['search'] = s.isEmpty ? null : s;
    return SLeadsFilterState(m);
  }

  SLeadsFilterState withCity(String? city) {
    final m = _copy;
    m['city'] = city;
    return SLeadsFilterState(m);
  }

  /// Replaces the whole state with a saved view's filters, verbatim.
  static SLeadsFilterState fromPayload(Object? raw) =>
      SLeadsFilterState(raw is Map ? Map<String, dynamic>.from(raw) : const {});
}

/// `sleads_filters()`, parsed. Every getter is a straight read — no defaults
/// are invented here, because an absent key means the backend chose to send
/// nothing and the row simply is not drawn.
class SLeadsFilterModel {
  const SLeadsFilterModel(this.payload);

  final Map<String, dynamic> payload;

  static SLeadsFilterModel fromPayload(Object? raw) =>
      SLeadsFilterModel(raw is Map ? Map<String, dynamic>.from(raw) : const {});

  bool get ok => payload['ok'] == true;

  Map<String, dynamic> _m(String key) =>
      payload[key] is Map ? Map<String, dynamic>.from(payload[key] as Map) : const {};

  List<Map<String, dynamic>> _l(Map<String, dynamic> m, String key) =>
      (m[key] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Map<String, dynamic> get filters => _m('filters');
  SLeadsFilterState get state => SLeadsFilterState(filters);

  String get classesLabel => _m('classes')['label']?.toString() ?? '';
  List<Map<String, dynamic>> get chips => _l(_m('classes'), 'chips');

  String get hiddenLabel => _m('hidden')['label']?.toString() ?? '';
  List<Map<String, dynamic>> get toggles => _l(_m('hidden'), 'toggles');

  Map<String, dynamic> get score => _m('score');
  Map<String, dynamic> get zone => _m('zone');

  Map<String, dynamic> get views => _m('views');
  List<Map<String, dynamic>> get viewItems => _l(_m('views'), 'items');

  String get countChip => payload['count_chip']?.toString() ?? '';
  String get resetLabel => payload['reset_label']?.toString() ?? '';
  int get total => (payload['total'] as num?)?.toInt() ?? 0;
}

/// The row itself. Every string it prints is a value out of [model].
class SLeadsFilterBar extends StatelessWidget {
  const SLeadsFilterBar({
    super.key,
    required this.model,
    required this.onChipTap,
    required this.onToggle,
    required this.onScore,
    required this.onApplyView,
    required this.onDeleteView,
    required this.onSaveView,
    this.trailing,
  });

  final SLeadsFilterModel model;
  final void Function(String key, String kind) onChipTap;
  final void Function(String key, bool value) onToggle;
  final ValueChanged<int> onScore;
  final ValueChanged<int> onApplyView;
  final ValueChanged<int> onDeleteView;
  final VoidCallback onSaveView;

  /// The screen's own controls (city, search) keep living in the screen.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    if (!model.ok) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(model.classesLabel),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [for (final chip in model.chips) _chip(chip)],
        ),
        SizedBox(height: Ds.space.x24),
        _sectionLabel(model.hiddenLabel),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x24,
          runSpacing: Ds.space.x8,
          children: [for (final t in model.toggles) _toggle(t)],
        ),
        SizedBox(height: Ds.space.x24),
        _scoreSlider(),
        SizedBox(height: Ds.space.x24),
        _zoneLine(),
        SizedBox(height: Ds.space.x24),
        _savedViews(),
        if (trailing != null) ...[SizedBox(height: Ds.space.x24), trailing!],
      ],
    );
  }

  Widget _sectionLabel(String text) =>
      text.isEmpty ? const SizedBox.shrink() : Text(text, style: Ds.t.caption);

  // ── Class chips ────────────────────────────────────────────────────────
  // label + count_label are the backend's; the client never composes
  // "Medical store (12)" from two of its own strings.
  Widget _chip(Map<String, dynamic> chip) {
    final key = chip['key']?.toString() ?? '';
    final kind = chip['kind']?.toString() ?? 'class';
    final selected = chip['selected'] == true;
    final label = chip['label']?.toString() ?? '';
    final count = chip['count_label']?.toString() ?? '';
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      child: ChoiceChip(
        key: ValueKey('sleads_chip_$key'),
        label: Text(count.isEmpty ? label : '$label  $count'),
        labelStyle: selected
            ? Ds.t.bodyStrong.copyWith(color: Ds.c.brand)
            : Ds.t.body,
        selected: selected,
        onSelected: (_) => onChipTap(key, kind),
        selectedColor: Ds.c.brandSoft,
        backgroundColor: Ds.c.surface,
        side: BorderSide(color: selected ? Ds.c.brand : Ds.c.divider),
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
      ),
    );
  }

  // ── The four hidden-by-default groups ──────────────────────────────────
  Widget _toggle(Map<String, dynamic> t) {
    final key = t['key']?.toString() ?? '';
    final on = t['value'] == true;
    final hint = t['hint']?.toString() ?? '';
    return SizedBox(
      height: Ds.touch.minTarget,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            key: ValueKey('sleads_toggle_$key'),
            value: on,
            onChanged: (v) => onToggle(key, v),
            activeThumbColor: Ds.c.brand,
          ),
          SizedBox(width: Ds.space.x8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t['label']?.toString() ?? '', style: Ds.t.body),
              if (hint.isNotEmpty) Text(hint, style: Ds.t.caption),
            ],
          ),
        ],
      ),
    );
  }

  // ── Score cut-off ──────────────────────────────────────────────────────
  // min / max / step / value AND the rendered value label are the payload's.
  Widget _scoreSlider() {
    final s = model.score;
    if (s.isEmpty) return const SizedBox.shrink();
    final min = (s['min'] as num?)?.toDouble() ?? 0;
    final max = (s['max'] as num?)?.toDouble() ?? 0;
    final step = (s['step'] as num?)?.toDouble() ?? 1;
    final value = ((s['value'] as num?)?.toDouble() ?? min).clamp(min, max);
    final divisions = step <= 0 || max <= min ? null : ((max - min) / step).round();
    return Row(
      children: [
        _sectionLabel(s['label']?.toString() ?? ''),
        SizedBox(width: Ds.space.x12),
        Expanded(
          child: Slider(
            key: const ValueKey('sleads_score_slider'),
            min: min,
            max: max,
            value: value,
            divisions: divisions == null || divisions <= 0 ? null : divisions,
            activeColor: Ds.c.brand,
            onChanged: (v) => onScore(v.round()),
          ),
        ),
        SizedBox(width: Ds.space.x12),
        Text(s['value_label']?.toString() ?? '', style: Ds.t.bodyStrong),
      ],
    );
  }

  // ── Header zone, read-only: it lives in the header picker, never here ──
  Widget _zoneLine() {
    final z = model.zone;
    if (z.isEmpty) return const SizedBox.shrink();
    final hint = z['hint']?.toString() ?? '';
    return Row(
      children: [
        _sectionLabel(z['label']?.toString() ?? ''),
        SizedBox(width: Ds.space.x8),
        Text(z['value_label']?.toString() ?? '',
            key: const ValueKey('sleads_zone_label'), style: Ds.t.bodyStrong),
        if (hint.isNotEmpty) ...[
          SizedBox(width: Ds.space.x8),
          Flexible(child: Text(hint, style: Ds.t.caption)),
        ],
      ],
    );
  }

  // ── Saved views ────────────────────────────────────────────────────────
  Widget _savedViews() {
    final v = model.views;
    if (v.isEmpty) return const SizedBox.shrink();
    final items = model.viewItems;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _sectionLabel(v['label']?.toString() ?? ''),
            SizedBox(width: Ds.space.x12),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                key: const ValueKey('sleads_view_save'),
                onPressed: onSaveView,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  side: BorderSide(color: Ds.c.brand),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(v['save_label']?.toString() ?? '', style: Ds.t.body),
              ),
            ),
          ],
        ),
        SizedBox(height: Ds.space.x8),
        if (items.isEmpty)
          Text(v['empty']?.toString() ?? '', style: Ds.t.caption)
        else
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final item in items)
                InputChip(
                  key: ValueKey('sleads_view_${item['id']}'),
                  label: Text(item['label']?.toString() ?? '', style: Ds.t.body),
                  onPressed: () => onApplyView((item['id'] as num?)?.toInt() ?? 0),
                  onDeleted: () => onDeleteView((item['id'] as num?)?.toInt() ?? 0),
                  deleteIcon: const Icon(Icons.close),
                  deleteButtonTooltipMessage: v['delete_label']?.toString(),
                  deleteIconColor: Ds.c.textSecondary,
                  backgroundColor: Ds.c.surface,
                  side: BorderSide(color: Ds.c.divider),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
                ),
            ],
          ),
      ],
    );
  }
}
