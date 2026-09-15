import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

/// CMD #1910 — Admin → Uses & conditions.
///
/// The vocabulary behind the fourth browse door. A seed built the first mapping
/// once, from the MEDICINE taxonomy; after that it is this screen's, and
/// nothing recomputes it behind the admin's back.
///
/// Every string here arrives in a payload: the title, the field labels, the
/// status chips, the counts, the empty states and every toast. Nothing on this
/// screen is worded in Dart, and no count is computed in Dart — `count_label`
/// is what the backend printed for the zone the header picker is showing.
class AdminConditionsScreen extends StatefulWidget {
  const AdminConditionsScreen({super.key});

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<AdminConditionsScreen> createState() => _AdminConditionsScreenState();
}

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

List<Map<String, dynamic>> _rows(Map<String, dynamic> m, String k) =>
    ((m[k] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);

class _AdminConditionsScreenState extends State<AdminConditionsScreen> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  String _error = '';
  String _q = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final res = await AdminConditionsScreen.rpc('admin_conditions_list', {
        'p_q': _q.isEmpty ? null : _q,
        'p_offset': 0,
        'p_limit': 200,
      });
      if (!mounted) return;
      final p = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() {
        _p = p;
        _loading = false;
      });
      RenderLog.write('c1910_admin_conditions',
          'rows=${_rows(p, 'rows').length};ok=${p['ok'] == true}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _onQuery(String v) {
    _q = v;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _open(String key) async {
    final changed = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
        builder: (_) => _ConditionEditor(conditionKey: key)));
    if (changed == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final rows = _rows(p, 'rows');
    final denied = p.isNotEmpty && p['ok'] != true;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(p, 'title'))),
      body: _loading && p.isEmpty
          ? const _Skeleton()
          : denied
              ? _Notice(message: _s(p, 'message'), onRetry: _load)
              : _error.isNotEmpty
                  ? _Notice(message: _error, onRetry: _load)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: EdgeInsets.fromLTRB(
                            Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
                        children: [
                          if (_s(p, 'subtitle').isNotEmpty)
                            Text(_s(p, 'subtitle'), style: Ds.t.caption),
                          SizedBox(height: Ds.space.x8),
                          _ScopeLine(scope: p['scope']),
                          SizedBox(height: Ds.space.x16),
                          TextField(
                            decoration: InputDecoration(
                                hintText: _s(p, 'search_hint'),
                                prefixIcon: const Icon(Icons.search)),
                            onChanged: _onQuery,
                          ),
                          SizedBox(height: Ds.space.x12),
                          Row(
                            children: [
                              Expanded(
                                  child: Text(_s(p, 'count_label'),
                                      style: Ds.t.caption)),
                              TextButton.icon(
                                onPressed: () => _open(''),
                                icon: const Icon(Icons.add),
                                label: Text(_s(p, 'add_label')),
                              ),
                            ],
                          ),
                          SizedBox(height: Ds.space.x8),
                          if (rows.isEmpty)
                            Padding(
                              padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
                              child: Text(_s(p, 'empty_label'),
                                  style: Ds.t.caption,
                                  textAlign: TextAlign.center),
                            ),
                          for (final r in rows) ...[
                            _ConditionCard(row: r, onTap: () => _open(_s(r, 'key'))),
                            SizedBox(height: Ds.space.x8),
                          ],
                        ],
                      ),
                    ),
    );
  }
}

/// The zone and date the header picker is showing. The counts below it are read
/// for THAT zone, so the line is not decoration — it says what the numbers mean.
class _ScopeLine extends StatelessWidget {
  const _ScopeLine({required this.scope});
  final Object? scope;

  @override
  Widget build(BuildContext context) {
    final m = scope is Map
        ? Map<String, dynamic>.from(scope as Map)
        : const <String, dynamic>{};
    final label = _s(m, 'label');
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(
          color: Ds.c.infoSoft, borderRadius: Ds.r.rChip),
      child: Text(label, style: Ds.t.caption),
    );
  }
}

class _ConditionCard extends StatelessWidget {
  const _ConditionCard({required this.row, required this.onTap});
  final Map<String, dynamic> row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = row['is_active'] == true;
    return Material(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      child: InkWell(
        borderRadius: Ds.r.rCard,
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
              borderRadius: Ds.r.rCard, boxShadow: Ds.elevation.e1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(row, 'label'), style: Ds.t.bodyStrong),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(row, 'synonyms_label'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.caption),
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_s(row, 'count_label'), style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x4),
                  Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x8, vertical: Ds.space.x4),
                    decoration: BoxDecoration(
                        color: active ? Ds.c.successSoft : Ds.c.bg,
                        borderRadius: Ds.r.rChip),
                    child: Text(_s(row, 'status_label'), style: Ds.t.caption),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One condition: its words, and the products under it.
class _ConditionEditor extends StatefulWidget {
  const _ConditionEditor({required this.conditionKey});
  final String conditionKey;

  @override
  State<_ConditionEditor> createState() => _ConditionEditorState();
}

class _ConditionEditorState extends State<_ConditionEditor> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _dirty = false;
  String _error = '';
  final _label = TextEditingController();
  final _syn = TextEditingController();
  final _find = TextEditingController();
  List<Map<String, dynamic>> _found = const [];
  bool _active = true;
  Timer? _debounce;

  bool get _isNew => widget.conditionKey.isEmpty;

  @override
  void initState() {
    super.initState();
    if (_isNew) {
      _loading = false;
      _loadCopyOnly();
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _label.dispose();
    _syn.dispose();
    _find.dispose();
    super.dispose();
  }

  /// A new use has no row to read, so the FIELD LABELS still come from the
  /// backend — asked for with a key that does not exist, whose payload carries
  /// the copy and nothing else.
  Future<void> _loadCopyOnly() async {
    try {
      final res = await AdminConditionsScreen.rpc('admin_conditions_list',
          {'p_q': null, 'p_offset': 0, 'p_limit': 1});
      if (!mounted) return;
      final p = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() => _p = <String, dynamic>{
            'ok': true,
            'label_field': p['label_field'] ?? '',
            'title': p['add_label'] ?? '',
          });
    } catch (_) {/* the fields still render; their labels simply stay empty */}
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final res = await AdminConditionsScreen.rpc(
          'admin_condition_get', {'p_key': widget.conditionKey, 'p_limit': 100});
      if (!mounted) return;
      final p = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() {
        _p = p;
        _loading = false;
        _label.text = _s(p, 'label');
        _syn.text = ((p['synonyms'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .join(', ');
        _active = p['is_active'] != false;
      });
      RenderLog.write('c1910_condition_editor',
          '${_s(p, 'key')};products=${_rows(p, 'rows').length}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _toast(Map<String, dynamic> res) {
    final msg = _s(res, 'message');
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: res['ok'] == true ? Ds.c.brand : Ds.c.danger,
    ));
  }

  Future<void> _save() async {
    final res = await AdminConditionsScreen.rpc('admin_condition_save', {
      // A new use has no key yet: the backend slugifies the NAME into one, so
      // the admin is never asked to invent an identifier.
      'p_key': _isNew ? _label.text : widget.conditionKey,
      'p_label': _label.text,
      'p_synonyms': _syn.text
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList(),
      'p_is_active': _active,
    });
    final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    _toast(m);
    if (m['ok'] == true) {
      _dirty = true;
      if (_isNew && mounted) {
        Navigator.of(context).pop(true);
      } else {
        await _load();
      }
    }
  }

  Future<void> _map(Object? id, bool on) async {
    final res = await AdminConditionsScreen.rpc('admin_condition_map',
        {'p_key': widget.conditionKey, 'p_product_id': id, 'p_on': on});
    final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    _toast(m);
    if (m['ok'] == true) {
      _dirty = true;
      await _load();
      if (_find.text.isNotEmpty) await _search(_find.text);
    }
  }

  Future<void> _search(String q) async {
    final res = await AdminConditionsScreen.rpc('admin_condition_product_search',
        {'p_key': widget.conditionKey, 'p_q': q, 'p_limit': 20});
    if (!mounted) return;
    final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    setState(() => _found = _rows(m, 'rows'));
  }

  void _onFind(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _search(v));
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final products = _rows(p, 'rows');
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_dirty);
      },
      child: Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(title: Text(_isNew ? _s(p, 'title') : _s(p, 'label'))),
        body: _loading
            ? const _Skeleton()
            : _error.isNotEmpty
                ? _Notice(message: _error, onRetry: _load)
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                        Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
                    children: [
                      _ScopeLine(scope: p['scope']),
                      SizedBox(height: Ds.space.x16),
                      TextField(
                        controller: _label,
                        decoration:
                            InputDecoration(labelText: _s(p, 'label_field')),
                      ),
                      SizedBox(height: Ds.space.x12),
                      TextField(
                        controller: _syn,
                        maxLines: 2,
                        decoration:
                            InputDecoration(labelText: _s(p, 'synonyms_field')),
                      ),
                      SizedBox(height: Ds.space.x12),
                      SwitchListTile(
                        value: _active,
                        onChanged: (v) => setState(() => _active = v),
                        title: Text(_s(p, 'active_field'), style: Ds.t.body),
                        contentPadding: EdgeInsets.zero,
                      ),
                      SizedBox(height: Ds.space.x12),
                      SizedBox(
                        width: double.infinity,
                        height: Ds.touch.minTarget,
                        child: FilledButton(
                          onPressed: _save,
                          child: Text(_s(p, 'save_label')),
                        ),
                      ),
                      if (!_isNew) ...[
                        SizedBox(height: Ds.space.x32),
                        Row(
                          children: [
                            Expanded(
                                child: Text(_s(p, 'products_title'),
                                    style: Ds.t.subtitle)),
                            Text(_s(p, 'count_label'), style: Ds.t.caption),
                          ],
                        ),
                        SizedBox(height: Ds.space.x4),
                        Text(_s(p, 'products_hint'), style: Ds.t.caption),
                        SizedBox(height: Ds.space.x12),
                        TextField(
                          controller: _find,
                          decoration: InputDecoration(
                              hintText: _s(p, 'add_hint'),
                              prefixIcon: const Icon(Icons.search)),
                          onChanged: _onFind,
                        ),
                        SizedBox(height: Ds.space.x8),
                        for (final f in _found)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(_s(f, 'label'), style: Ds.t.body),
                            subtitle: Text(_s(f, 'sub_label'), style: Ds.t.caption),
                            trailing: f['already'] == true
                                ? Text(_s(f, 'action_label'), style: Ds.t.caption)
                                : TextButton(
                                    onPressed: () => _map(f['id'], true),
                                    child: Text(_s(f, 'action_label')),
                                  ),
                          ),
                        SizedBox(height: Ds.space.x16),
                        if (products.isEmpty)
                          Text(_s(p, 'empty_label'), style: Ds.t.caption),
                        for (final r in products)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(_s(r, 'label'), style: Ds.t.body),
                            subtitle:
                                Text(_s(r, 'source_label'), style: Ds.t.caption),
                            trailing: TextButton(
                              onPressed: () => _map(r['id'], false),
                              child: Text(_s(r, 'remove_label')),
                            ),
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
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 6; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Container(
                height: Ds.touch.listRowMinHeight,
                decoration: BoxDecoration(
                    color: Ds.c.surface, borderRadius: Ds.r.rCard),
              ),
            ),
        ],
      );
}

/// A refusal or a failure, in the backend's words where there are any, with the
/// one action that can help.
class _Notice extends StatelessWidget {
  const _Notice({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center, style: Ds.t.body),
              SizedBox(height: Ds.space.x16),
              OutlinedButton(
                  onPressed: onRetry, child: Text(c('condition.retry'))),
            ],
          ),
        ),
      );
}
