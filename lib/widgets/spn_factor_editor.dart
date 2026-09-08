// CHANGE #753 — the four-factor SPN editor.
//
// It used to be a panel that expanded under a supplier's row on the list. The
// list is a plain name list now, so the editor moved to the supplier page:
// the SPN chip in the header and the "SPN factors" card at the top of Info
// both open THIS sheet. Om, 3 Sep: "Nothing about the SPN formula changes."
// It does not: margin / cd_condition / behaviour / payment_term still each
// carry their own points, admin_set_supplier_spn() still writes one field at a
// time, and supplier_spn_propagate() still re-ranks on the write.
//
// The widget knows nothing about what an SPN factor IS. The block names the
// four fields, their labels, the columns admin_set_supplier_spn expects back,
// and every button caption; spn_options_list() supplies each field's options.
// The only Dart decision here is "which fields did the user actually change",
// so an untouched factor is never rewritten.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../services/spn_options.dart';

/// Opens the editor for the supplier named by [block] (an `spn` block from
/// admin_supplier_page / admin_supplier_tab_profile). Resolves true when a
/// save landed, so the caller can re-read its payload and show the new SPN
/// and rank immediately.
Future<bool> openSpnFactorEditor(
  BuildContext context,
  Map<String, dynamic> block, {
  Future<Object?> Function(String rpc, Map<String, dynamic> params)? rpc,
}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
    builder: (_) => SpnFactorEditor(block: block, rpc: rpc),
  );
  return saved == true;
}

class SpnFactorEditor extends StatefulWidget {
  final Map<String, dynamic> block;

  /// Test seam. Null in production -> the real RPCs.
  final Future<Object?> Function(String rpc, Map<String, dynamic> params)? rpc;

  const SpnFactorEditor({super.key, required this.block, this.rpc});

  @override
  State<SpnFactorEditor> createState() => _SpnFactorEditorState();
}

class _SpnFactorEditorState extends State<SpnFactorEditor> {
  Map<String, List<SpnOption>> _options = const {};
  final Map<String, SpnOption?> _picked = {};
  final Map<String, SpnOption?> _initial = {};
  bool _loading = true;
  bool _saving = false;

  String _s(Object? v) => v == null ? '' : v.toString();

  List<Map<String, dynamic>> get _factors => widget.block['factors'] is List
      ? (widget.block['factors'] as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList()
      : const <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    for (final f in _factors) {
      final field = _s(f['field']);
      final label = _s(f['value']);
      final points = f['points'] is num ? (f['points'] as num).toInt() : 0;
      final opt = label.isEmpty ? null : SpnOption(label, points);
      _initial[field] = opt;
      _picked[field] = opt;
    }
    _loadOptions();
  }

  Future<Object?> _rpc(String name, Map<String, dynamic> params) {
    final over = widget.rpc;
    if (over != null) return over(name, params);
    return Supabase.instance.client.rpc(name, params: params);
  }

  Future<void> _loadOptions() async {
    try {
      final rows = await _rpc('spn_options_list', const {});
      final out = <String, List<SpnOption>>{};
      if (rows is List) {
        for (final r in rows.whereType<Map>()) {
          final field = _s(r['field']);
          final label = _s(r['label']);
          if (field.isEmpty || label.isEmpty) continue;
          final pts = r['points'] is num ? (r['points'] as num).toInt() : 0;
          out.putIfAbsent(field, () => <SpnOption>[]).add(SpnOption(label, pts));
        }
      }
      if (!mounted) return;
      setState(() {
        _options = out;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _dirty =>
      _factors.any((f) => _picked[_s(f['field'])] != _initial[_s(f['field'])]);

  Future<void> _save() async {
    setState(() => _saving = true);
    var wrote = false;
    try {
      for (final f in _factors) {
        final field = _s(f['field']);
        final chosen = _picked[field];
        // Only what actually moved. Rewriting an untouched factor would
        // re-stamp its points for no reason and churn the rank.
        if (chosen == _initial[field]) continue;
        await _rpc('admin_set_supplier_spn', {
          'p_id': _s(widget.block['supplier_id']),
          'p_field': {
            'col': _s(f['col']),
            'points_col': _s(f['points_col']),
            'label': chosen?.label ?? '',
            'points': (chosen?.points ?? 0).toString(),
          },
        });
        wrote = true;
      }
      if (mounted) Navigator.pop(context, wrote);
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Expanded(child: Text(_s(b['title']), style: Ds.t.subtitle)),
            _stat(_s(b['total_label']), _s(b['total_value'])),
            SizedBox(width: Ds.space.x16),
            _stat(_s(b['rank_label']), _s(b['rank_value'])),
          ]),
          SizedBox(height: Ds.space.x16),
          if (_loading)
            Padding(
              padding: EdgeInsets.all(Ds.space.x24),
              child: const CircularProgressIndicator(),
            )
          else
            for (final f in _factors) ...[
              _dropdown(f),
              SizedBox(height: Ds.space.x12),
            ],
          SizedBox(height: Ds.space.x8),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context, false),
              child: Text(_s(b['cancel_label']), style: Ds.t.body),
            ),
            SizedBox(width: Ds.space.x8),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
              onPressed: (_saving || !_dirty) ? null : _save,
              child: Text(_s(b['save_label'])),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Ds.t.caption),
          Text(value, style: Ds.t.bodyStrong),
        ],
      );

  Widget _dropdown(Map<String, dynamic> f) {
    final field = _s(f['field']);
    final opts = _options[field] ?? const <SpnOption>[];
    final current = _picked[field];
    // A value the option list no longer offers still has to be selectable, or
    // opening the editor would silently blank it.
    final items = <SpnOption>[
      ...opts,
      if (current != null && !opts.contains(current)) current,
    ];
    return InputDecorator(
      decoration: InputDecoration(
        labelText: _s(f['label']),
        labelStyle: Ds.t.caption,
        filled: true,
        fillColor: Ds.c.bg,
        isDense: true,
        border: OutlineInputBorder(borderRadius: Ds.r.rButton),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<SpnOption?>(
          value: current,
          isExpanded: true,
          hint: Text(_s(widget.block['unset_label']), style: Ds.t.caption),
          items: [
            for (final o in items)
              DropdownMenuItem<SpnOption?>(
                value: o,
                child: Text(
                  '${o.label}   ${_s(widget.block['points_format']).replaceAll('{n}', '${o.points}')}',
                  style: Ds.t.body,
                ),
              ),
          ],
          onChanged: _saving
              ? null
              : (v) => setState(() => _picked[field] = v),
        ),
      ),
    );
  }
}
