// CHANGE #397 — Bulk actions, exports and undo.
//
// Three things that did not exist anywhere in the admin app: a way to change
// many rows at once, a way to get a list out as a file, and a way to take an
// action back. All three are one screen because they are one idea — an admin
// acting on a SET of rows, and being able to change their mind.
//
// The screen is a pure renderer. Every label, every option, every confirmation
// sentence, every result banner and every "why not" reason arrives from
// `admin_bulk_screen()`, `admin_export_screen()` and `admin_bulk_batches()`.
// Dart holds exactly two pieces of state the backend cannot: which rows the
// finger has ticked, and which tab is open. The file itself is built in SQL —
// this file never formats a cell, a number or a filename.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/download_bytes.dart';
import '../../utils/render_log.dart';

/// Injected in tests; null in production means the real RPCs.
typedef BulkRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

/// Saves a finished export. Overridden in tests so nothing touches the browser.
typedef BulkSaveFile = void Function(List<int> bytes, String name, String mime);

Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _list(Object? v) =>
    (v as List? ?? const []).map(_m).toList();

String _s(Object? v) => v?.toString() ?? '';

class AdminBulkScreen extends StatefulWidget {
  const AdminBulkScreen({super.key, this.rpc, this.saveFile, this.initialTab = 0});

  final BulkRpc? rpc;
  final BulkSaveFile? saveFile;

  /// Which tab opens first: 0 Bulk edit, 1 Exports, 2 History. The registry
  /// ships two features (Bulk actions, Exports) that share this screen, so the
  /// router says which one the tile meant.
  final int initialTab;

  @override
  State<AdminBulkScreen> createState() => _AdminBulkScreenState();
}

class _AdminBulkScreenState extends State<AdminBulkScreen> {
  Map<String, dynamic>? _bulk;
  Map<String, dynamic>? _exports;
  Map<String, dynamic>? _history;

  bool _loading = true;
  String? _error;

  String _target = '';
  String _search = '';
  final Set<String> _selected = <String>{};
  final TextEditingController _searchCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(
      String fn, Map<String, dynamic> params) async {
    if (widget.rpc != null) return widget.rpc!(fn, params);
    final res = await Supabase.instance.client.rpc(fn, params: params);
    return _m(res);
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bulk = await _call('admin_bulk_screen', {
        'p': {'target': _target, 'search': _search}
      });
      final exports = await _call('admin_export_screen', {'p': const {}});
      final history = await _call('admin_bulk_batches', {'p_limit': 30});
      if (!mounted) return;
      setState(() {
        _bulk = bulk;
        _exports = exports;
        _history = history;
        _target = _s(bulk['target']);
        _loading = false;
      });
      RenderLog.write('bulk_targets', _list(bulk['targets']).length);
      RenderLog.write('bulk_reports', _list(exports['reports']).length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _reloadBulk() async {
    try {
      final bulk = await _call('admin_bulk_screen', {
        'p': {'target': _target, 'search': _search}
      });
      final history = await _call('admin_bulk_batches', {'p_limit': 30});
      if (!mounted) return;
      setState(() {
        _bulk = bulk;
        _history = history;
      });
    } catch (_) {
      // A failed refresh leaves the last payload on screen; the next action
      // reports its own error with the backend's own words.
    }
  }

  void _toast(String message, {String? undoLabel, VoidCallback? onUndo}) {
    if (message.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      duration: Ds.motion.sheet * 8,
      action: (undoLabel != null && undoLabel.isNotEmpty && onUndo != null)
          ? SnackBarAction(label: undoLabel, onPressed: onUndo)
          : null,
    ));
  }

  // ── bulk edit ─────────────────────────────────────────────────────────────

  Future<void> _openApplySheet() async {
    final d = _bulk;
    if (d == null) return;
    final fields = _list(d['fields']);
    if (fields.isEmpty || _selected.isEmpty) return;

    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (_) => _ApplySheet(
        data: d,
        fields: fields,
        selectedCount: _selected.length,
      ),
    );
    if (picked == null || !mounted) return;

    final res = await _call('admin_bulk_apply', {
      'p_target': _target,
      'p_ids': _selected.toList(),
      'p_field': picked['field'],
      'p_value': picked['value'],
    });
    if (!mounted) return;

    if (res['ok'] == true) {
      setState(_selected.clear);
      await _reloadBulk();
      final batchId = res['batch_id'];
      _toast(_s(res['message']),
          undoLabel: _s(res['undo_label']),
          onUndo: batchId == null ? null : () => _undoBatch(batchId as int));
    } else {
      _toast(_s(res['message']));
    }
  }

  Future<void> _undoBatch(int batchId) async {
    final res = await _call('admin_bulk_undo', {'p_batch_id': batchId});
    if (!mounted) return;
    await _reloadBulk();
    _toast(_s(res['message']));
  }

  // ── exports ───────────────────────────────────────────────────────────────

  void _save(Map<String, dynamic> res) {
    final content = _s(res['content']);
    if (content.isEmpty) return;
    final save = widget.saveFile ?? downloadBytes;
    save(utf8.encode(content), _s(res['filename']), _s(res['mime']));
  }

  Future<void> _runExport(
      Map<String, dynamic> report, String format, Map<String, String> filters) async {
    final res = await _call('admin_export_run', {
      'p_report': report['key'],
      'p_format': format,
      'p_filters': filters,
    });
    if (!mounted) return;
    if (res['ok'] == true && res['ready'] == true) _save(res);
    await _refreshExports();
    _toast(_s(res['message']));
  }

  Future<void> _refreshExports() async {
    try {
      final exports = await _call('admin_export_screen', {'p': const {}});
      if (!mounted) return;
      setState(() => _exports = exports);
    } catch (_) {}
  }

  Future<void> _downloadJob(int id) async {
    final res = await _call('admin_export_job', {'p_id': id});
    if (!mounted) return;
    if (res['ok'] == true && res['ready'] == true) {
      _save(res);
    } else {
      _toast(_s(res['message']));
    }
  }

  // ── frame ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final d = _bulk;
    final blocked = d != null && d['ok'] != true;
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab,
      child: Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(
          backgroundColor: Ds.c.surface,
          surfaceTintColor: Ds.c.surface,
          elevation: 0,
          title: Text(_s(d?['title']), style: Ds.t.title),
          bottom: (d == null || blocked)
              ? null
              : TabBar(
                  labelStyle: Ds.t.bodyStrong,
                  unselectedLabelStyle: Ds.t.body,
                  labelColor: Ds.c.brand,
                  unselectedLabelColor: Ds.c.textSecondary,
                  indicatorColor: Ds.c.brand,
                  tabs: [
                    Tab(text: _s(d['tab_bulk'])),
                    Tab(text: _s(d['tab_export'])),
                    Tab(text: _s(d['tab_history'])),
                  ],
                ),
        ),
        body: _body(d, blocked),
        bottomNavigationBar: _selected.isEmpty ? null : _selectionBar(d),
      ),
    );
  }

  Widget _body(Map<String, dynamic>? d, bool blocked) {
    if (_loading && d == null) return const _Skeleton();
    if (_error != null) return _Message(text: _error!, onRetry: _loadAll);
    if (d == null) return const SizedBox.shrink();
    if (blocked) return _Message(text: _s(d['message']));

    return TabBarView(
      children: [
        _bulkTab(d),
        _ExportTab(
          data: _exports,
          onRun: _runExport,
          onDownloadJob: _downloadJob,
        ),
        _HistoryTab(data: _history, onUndo: _undoBatch),
      ],
    );
  }

  Widget _selectionBar(Map<String, dynamic>? d) {
    if (d == null) return const SizedBox.shrink();
    final label = _s(d['selected_fmt']).replaceAll('{n}', '${_selected.length}');
    return SafeArea(
      child: Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(color: Ds.c.surface, boxShadow: Ds.elevation.e2),
        child: Row(
          children: [
            Expanded(child: Text(label, style: Ds.t.bodyStrong)),
            SizedBox(width: Ds.space.x12),
            TextButton(
              onPressed: () => setState(_selected.clear),
              child: Text(_s(d['clear_label'])),
            ),
            SizedBox(width: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: d['can_write'] == true ? _openApplySheet : null,
                child: Text(_s(d['apply_label'])),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bulkTab(Map<String, dynamic> d) {
    final rows = _list(d['rows']);
    final targets = _list(d['targets']);
    final needsSearch = d['needs_search'] == true;

    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x48),
      children: [
        Text(_s(d['subtitle']), style: Ds.t.bodySecondary),
        SizedBox(height: Ds.space.x16),
        _TargetPicker(
          targets: targets,
          value: _target,
          onPick: (key) {
            setState(() {
              _target = key;
              _selected.clear();
              _search = '';
              _searchCtl.clear();
            });
            _reloadBulk();
          },
        ),
        if (_s(d['target_hint']).isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(_s(d['target_hint']), style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x16),
        _SearchField(
          controller: _searchCtl,
          hint: _s(d['search_hint']),
          onSubmit: (v) {
            setState(() {
              _search = v;
              _selected.clear();
            });
            _reloadBulk();
          },
        ),
        SizedBox(height: Ds.space.x24),
        if (needsSearch)
          _Empty(
              title: _s(d['needs_search_title']), hint: _s(d['needs_search_hint']))
        else if (rows.isEmpty)
          _Empty(title: _s(d['empty_title']), hint: _s(d['empty_hint']))
        else ...[
          Row(
            children: [
              Expanded(child: Text(_s(d['count_label']), style: Ds.t.caption)),
              TextButton(
                onPressed: () => setState(() {
                  final ids = rows.map((r) => _s(r['id'])).toSet();
                  if (_selected.containsAll(ids)) {
                    _selected.removeAll(ids);
                  } else {
                    _selected.addAll(ids);
                  }
                }),
                child: Text(_s(d['select_all_label'])),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          ...rows.map((r) => Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: BulkRowTile(
                  row: r,
                  selected: _selected.contains(_s(r['id'])),
                  onToggle: () => setState(() {
                    final id = _s(r['id']);
                    if (!_selected.remove(id)) _selected.add(id);
                  }),
                ),
              )),
        ],
      ],
    );
  }
}

// ── pieces ──────────────────────────────────────────────────────────────────

/// One selectable row. Both lines are backend strings; the tile computes
/// nothing about the record it shows.
class BulkRowTile extends StatelessWidget {
  const BulkRowTile(
      {super.key, required this.row, required this.selected, required this.onToggle});

  final Map<String, dynamic> row;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final extra = _s(row['extra']);
    return Material(
      color: selected ? Ds.c.brandSoft : Ds.c.surface,
      borderRadius: Ds.r.rCard,
      child: InkWell(
        borderRadius: Ds.r.rCard,
        onTap: onToggle,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x12),
          child: Row(
            children: [
              Checkbox(value: selected, onChanged: (_) => onToggle()),
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_s(row['name']), style: Ds.t.body),
                    if (extra.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(extra, style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TargetPicker extends StatelessWidget {
  const _TargetPicker(
      {required this.targets, required this.value, required this.onPick});

  final List<Map<String, dynamic>> targets;
  final String value;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: targets.map((t) {
        final key = _s(t['key']);
        final on = key == value;
        return ChoiceChip(
          selected: on,
          onSelected: (_) => onPick(key),
          label: Text(_s(t['label'])),
          labelStyle: Ds.t.caption,
          selectedColor: Ds.c.brandSoft,
          backgroundColor: Ds.c.surface,
          shape: RoundedRectangleBorder(
              borderRadius: Ds.r.rChip,
              side: BorderSide(color: on ? Ds.c.brand : Ds.c.divider)),
        );
      }).toList(),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField(
      {required this.controller, required this.hint, required this.onSubmit});

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: Ds.touch.minTarget,
      child: TextField(
        controller: controller,
        onSubmitted: onSubmit,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search),
          isDense: true,
        ),
      ),
    );
  }
}

/// The change sheet. It collects one field and one value and hands them back;
/// every word on it, including the warning under the value, is the backend's.
class _ApplySheet extends StatefulWidget {
  const _ApplySheet(
      {required this.data, required this.fields, required this.selectedCount});

  final Map<String, dynamic> data;
  final List<Map<String, dynamic>> fields;
  final int selectedCount;

  @override
  State<_ApplySheet> createState() => _ApplySheetState();
}

class _ApplySheetState extends State<_ApplySheet> {
  late Map<String, dynamic> _field = widget.fields.first;
  String? _enum;
  bool _bool = true;
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Object? _value() {
    switch (_s(_field['input_kind'])) {
      case 'enum':
        return _enum;
      case 'bool':
        return _bool;
      case 'number':
        return num.tryParse(_text.text.trim());
      default:
        return _text.text.trim();
    }
  }

  bool get _ready {
    final v = _value();
    if (v == null) return false;
    if (v is String && v.isEmpty) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    final kind = _s(_field['input_kind']);
    final label =
        _s(d['selected_fmt']).replaceAll('{n}', '${widget.selectedCount}');

    return Padding(
      padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(context).viewInsets.bottom + Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(d['sheet_title']), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text(label, style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          Text(_s(d['field_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          DropdownButtonFormField<String>(
            initialValue: _s(_field['field']),
            isExpanded: true,
            decoration: const InputDecoration(isDense: true),
            items: widget.fields
                .map((f) => DropdownMenuItem(
                    value: _s(f['field']),
                    child: Text(_s(f['label']), style: Ds.t.body)))
                .toList(),
            onChanged: (v) => setState(() {
              _field = widget.fields
                  .firstWhere((f) => _s(f['field']) == v, orElse: () => _field);
              _enum = null;
              _text.clear();
              _bool = true;
            }),
          ),
          if (_s(_field['hint']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(_field['hint']), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x24),
          Text(_s(d['value_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          if (kind == 'enum')
            DropdownButtonFormField<String>(
              initialValue: _enum,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: _list(_field['options'])
                  .map((o) => DropdownMenuItem(
                      value: _s(o['value']),
                      child: Text(_s(o['label']), style: Ds.t.body)))
                  .toList(),
              onChanged: (v) => setState(() => _enum = v),
            )
          else if (kind == 'bool')
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _bool,
              onChanged: (v) => setState(() => _bool = v),
              title: Text(_s(_field['label']), style: Ds.t.body),
            )
          else
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextField(
                controller: _text,
                keyboardType: kind == 'number'
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.text,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(isDense: true),
              ),
            ),
          if (_s(_field['confirm_body']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Container(
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                  color: Ds.c.warningSoft, borderRadius: Ds.r.rCard),
              child: Text(_s(_field['confirm_body']), style: Ds.t.caption),
            ),
          ],
          SizedBox(height: Ds.space.x24),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(_s(d['cancel_label'])),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: _ready
                        ? () => Navigator.of(context).pop({
                              'field': _s(_field['field']),
                              'value': _value(),
                            })
                        : null,
                    child: Text(_s(d['confirm_cta'])),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Exports. A report card carries its own filters and its own format list —
/// the tab knows the shape of a report, never the name of one.
class _ExportTab extends StatefulWidget {
  const _ExportTab(
      {required this.data, required this.onRun, required this.onDownloadJob});

  final Map<String, dynamic>? data;
  final Future<void> Function(
      Map<String, dynamic> report, String format, Map<String, String> filters) onRun;
  final Future<void> Function(int id) onDownloadJob;

  @override
  State<_ExportTab> createState() => _ExportTabState();
}

class _ExportTabState extends State<_ExportTab> {
  /// report key → filter key → typed value.
  final Map<String, Map<String, String>> _filters = {};

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    if (d == null) return const _Skeleton();
    if (d['ok'] != true) return _Message(text: _s(d['message']));

    final reports = _list(d['reports']);
    final jobs = _list(d['jobs']);

    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x48),
      children: [
        Text(_s(d['subtitle']), style: Ds.t.bodySecondary),
        SizedBox(height: Ds.space.x24),
        if (reports.isEmpty)
          _Empty(title: _s(d['empty_title']), hint: _s(d['empty_hint']))
        else
          ...reports.map((r) => Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: ExportReportCard(
                  report: r,
                  values: _filters.putIfAbsent(_s(r['key']), () => {}),
                  allLabel: _s(d['filter_all_label']),
                  onChanged: () => setState(() {}),
                  onRun: (fmt) =>
                      widget.onRun(r, fmt, _filters[_s(r['key'])] ?? const {}),
                ),
              )),
        SizedBox(height: Ds.space.x32),
        Text(_s(d['jobs_title']), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x8),
        if (jobs.isEmpty)
          Text(_s(d['jobs_empty']), style: Ds.t.caption)
        else
          ...jobs.map((j) => Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: _JobRow(
                  job: j,
                  onDownload: () => widget.onDownloadJob(j['id'] as int),
                ),
              )),
      ],
    );
  }
}

/// One report: its own filters, its own formats, its own words.
class ExportReportCard extends StatelessWidget {
  const ExportReportCard({
    super.key,
    required this.report,
    required this.values,
    required this.allLabel,
    required this.onChanged,
    required this.onRun,
  });

  final Map<String, dynamic> report;
  final Map<String, String> values;
  final String allLabel;
  final VoidCallback onChanged;
  final ValueChanged<String> onRun;

  @override
  Widget build(BuildContext context) {
    final filters = _list(report['filters']);
    final formats = _list(report['formats']);
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(report['label']), style: Ds.t.subtitle),
          if (_s(report['hint']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(report['hint']), style: Ds.t.caption),
          ],
          if (filters.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: filters
                  .map((f) => _FilterField(
                        filter: f,
                        value: values[_s(f['key'])] ?? '',
                        allLabel: allLabel,
                        onSet: (v) {
                          if (v.isEmpty) {
                            values.remove(_s(f['key']));
                          } else {
                            values[_s(f['key'])] = v;
                          }
                          onChanged();
                        },
                      ))
                  .toList(),
            ),
          ],
          SizedBox(height: Ds.space.x16),
          Row(
            children: formats
                .map((f) => Padding(
                      padding: EdgeInsets.only(right: Ds.space.x8),
                      child: SizedBox(
                        height: Ds.touch.minTarget,
                        child: OutlinedButton.icon(
                          onPressed: () => onRun(_s(f['key'])),
                          icon: const Icon(Icons.download_outlined),
                          label: Text(_s(f['label'])),
                        ),
                      ),
                    ))
                .toList(),
          ),
        ],
      ),
    );
  }
}

/// Filter controls sit in a Wrap and must reflow, so their width comes off the
/// space scale rather than an invented pixel number.
double get _filterWidth => Ds.space.x48 * 4;

class _FilterField extends StatelessWidget {
  const _FilterField(
      {required this.filter,
      required this.value,
      required this.allLabel,
      required this.onSet});

  final Map<String, dynamic> filter;
  final String value;
  final String allLabel;
  final ValueChanged<String> onSet;

  @override
  Widget build(BuildContext context) {
    final kind = _s(filter['kind']);
    final label = _s(filter['label']);

    if (kind == 'enum') {
      final options = _list(filter['options']);
      return SizedBox(
        width: _filterWidth,
        child: DropdownButtonFormField<String>(
          initialValue: value.isEmpty ? '' : value,
          isExpanded: true,
          decoration: InputDecoration(labelText: label, isDense: true),
          items: [
            DropdownMenuItem(value: '', child: Text(allLabel, style: Ds.t.body)),
            ...options.map((o) => DropdownMenuItem(
                value: _s(o['value']),
                child: Text(_s(o['label']), style: Ds.t.body))),
          ],
          onChanged: (v) => onSet(v ?? ''),
        ),
      );
    }

    if (kind == 'date') {
      return SizedBox(
        width: _filterWidth,
        height: Ds.touch.minTarget,
        child: OutlinedButton(
          onPressed: () async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: now,
              firstDate: DateTime(now.year - 5),
              lastDate: DateTime(now.year + 1),
            );
            if (picked == null) return;
            onSet(picked.toIso8601String().substring(0, 10));
          },
          child: Text(value.isEmpty ? label : '$label · $value',
              style: Ds.t.caption, overflow: TextOverflow.ellipsis),
        ),
      );
    }

    return SizedBox(
      width: _filterWidth,
      height: Ds.touch.minTarget,
      child: TextFormField(
        initialValue: value,
        onChanged: onSet,
        decoration: InputDecoration(labelText: label, isDense: true),
      ),
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job, required this.onDownload});

  final Map<String, dynamic> job;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${_s(job['title'])} · ${_s(job['format_label'])}',
                    style: Ds.t.body),
                SizedBox(height: Ds.space.x4),
                Text('${_s(job['state_label'])} · ${_s(job['when_label'])}',
                    style: Ds.t.caption),
              ],
            ),
          ),
          if (job['can_download'] == true)
            TextButton(
                onPressed: onDownload, child: Text(_s(job['download_label'])))
          else
            ToneDot(tone: _s(job['tone'])),
        ],
      ),
    );
  }
}

/// Every bulk change ever made, each with the backend's verdict on whether it
/// can still be taken back — and, when it cannot, the reason in its words.
class _HistoryTab extends StatelessWidget {
  const _HistoryTab({required this.data, required this.onUndo});

  final Map<String, dynamic>? data;
  final Future<void> Function(int batchId) onUndo;

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null) return const _Skeleton();
    if (d['ok'] != true) return _Message(text: _s(d['message']));
    final rows = _list(d['rows']);

    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x48),
      children: [
        Text(_s(d['window_label']), style: Ds.t.bodySecondary),
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty)
          _Empty(title: _s(d['empty_title']), hint: _s(d['empty_hint']))
        else
          ...rows.map((r) => Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: BulkBatchCard(
                  batch: r,
                  onUndo: () async {
                    final ok = await showModalBottomSheet<bool>(
                      context: context,
                      backgroundColor: Ds.c.surface,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.vertical(
                              top: Radius.circular(Ds.r.sheet))),
                      builder: (_) => _ConfirmSheet(row: r),
                    );
                    if (ok == true) await onUndo(r['id'] as int);
                  },
                ),
              )),
      ],
    );
  }
}

class BulkBatchCard extends StatelessWidget {
  const BulkBatchCard({super.key, required this.batch, required this.onUndo});

  final Map<String, dynamic> batch;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    final canUndo = batch['can_undo'] == true;
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(_s(batch['title']), style: Ds.t.subtitle)),
              SizedBox(width: Ds.space.x8),
              ToneChip(
                  label: _s(batch['state_label']), tone: _s(batch['tone'])),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text('${_s(batch['value_label'])} · ${_s(batch['count_label'])}',
              style: Ds.t.body),
          SizedBox(height: Ds.space.x4),
          Text('${_s(batch['actor_label'])} · ${_s(batch['when_label'])}',
              style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          if (canUndo)
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton.icon(
                onPressed: onUndo,
                icon: const Icon(Icons.undo),
                label: Text(_s(batch['undo_label'])),
              ),
            )
          else if (_s(batch['undo_blocked_label']).isNotEmpty)
            Text(_s(batch['undo_blocked_label']), style: Ds.t.caption),
        ],
      ),
    );
  }
}

/// Confirmation is a sheet, and every word in it is the backend's.
class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(row['confirm_title']), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(_s(row['confirm_body']), style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x24),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(_s(row['cancel_label'])),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(_s(row['confirm_cta'])),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The backend names a tone; this is the only place a tone becomes a colour.
class ToneChip extends StatelessWidget {
  const ToneChip({super.key, required this.label, required this.tone});

  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration:
          BoxDecoration(color: _toneBg(tone), borderRadius: Ds.r.rChip),
      child: Text(label, style: Ds.t.caption),
    );
  }
}

class ToneDot extends StatelessWidget {
  const ToneDot({super.key, required this.tone});

  final String tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: Ds.space.x8,
      height: Ds.space.x8,
      decoration: BoxDecoration(color: _toneBg(tone), shape: BoxShape.circle),
    );
  }
}

Color _toneBg(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    default:
      return Ds.c.infoSoft;
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(hint, style: Ds.t.bodySecondary),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              SizedBox(height: Ds.space.x16),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                    onPressed: onRetry, child: const Text('Retry')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: List.generate(
        5,
        (i) => Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: Container(
            height: Ds.space.x48 + Ds.space.x24,
            decoration: BoxDecoration(
                color: Ds.c.surface, borderRadius: Ds.r.rCard),
          ),
        ),
      ),
    );
  }
}
