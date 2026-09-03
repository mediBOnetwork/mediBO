import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';

/// CHANGE #790 — Admin → Search synonyms.
///
/// The Hindi/Hinglish words a shopper types and the salt or class each one
/// searches for. Part C seeded the table from Gemini once; this is the screen
/// that keeps it correct, because a wrong mapping (bukhar → the wrong salt)
/// must be a row edit and never a migration.
///
/// Every string on this screen — the title, the field labels, the two
/// dropdowns' options, the counter, the toasts and every refusal — arrives in
/// `search_synonyms_list()`. Nothing here is worded in Dart.
class SearchSynonymsScreen extends StatefulWidget {
  const SearchSynonymsScreen({super.key});

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<SearchSynonymsScreen> createState() => _SearchSynonymsScreenState();
}

class _SearchSynonymsScreenState extends State<SearchSynonymsScreen> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await SearchSynonymsScreen.rpc('search_synonyms_list');
      if (!mounted) return;
      setState(() {
        _p = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// The RPC hands back the whole list again, so the screen re-renders from
  /// the server's answer instead of patching a row it edited.
  void _apply(Map<String, dynamic> res) {
    final msg = (res['message'] ?? '').toString();
    if (msg.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: res['ok'] == true ? Ds.c.brand : Ds.c.danger,
      ));
    }
    final state = res['state'];
    if (state is Map && mounted) {
      setState(() => _p = Map<String, dynamic>.from(state));
    }
  }

  Future<void> _save(Map<String, dynamic> row, {String? was}) async {
    final res = await SearchSynonymsScreen.rpc('search_synonym_upsert', {
      'p_term': row['term'],
      'p_target': row['target'],
      'p_lang': row['lang'],
      'p_target_kind': row['target_kind'],
      'p_display': row['display'],
      'p_note': row['note'],
      'p_active': row['active'] ?? true,
      if (was != null) 'p_was': was,
    });
    if (res is Map) _apply(Map<String, dynamic>.from(res));
  }

  Future<void> _delete(String term) async {
    final res =
        await SearchSynonymsScreen.rpc('search_synonym_delete', {'p_term': term});
    if (res is Map) _apply(Map<String, dynamic>.from(res));
  }

  Future<void> _edit([Map<String, dynamic>? existing]) async {
    final edited = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SynonymEditSheet(payload: _p, row: existing),
    );
    if (edited == null) return;
    await _save(edited, was: existing == null ? null : '${existing['term']}');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
          title: Text((_p['title'] ?? '').toString(), style: Ds.t.subtitle)),
      floatingActionButton: _p['ok'] == true
          ? FloatingActionButton.extended(
              onPressed: () => _edit(),
              backgroundColor: Ds.c.brand,
              label: Text((_p['add_label'] ?? '').toString()),
              icon: const Icon(Icons.add))
          : null,
      body: SafeArea(
        child: _loading
            ? SynonymsView.skeleton()
            : RefreshIndicator(
                onRefresh: _load,
                child: SynonymsView(
                  payload: _p,
                  onEdit: _edit,
                  onDelete: _delete,
                ),
              ),
      ),
    );
  }
}

/// The rendered list, split out so a protected test can pump a payload with no
/// Supabase and no timers.
class SynonymsView extends StatelessWidget {
  const SynonymsView({
    super.key,
    required this.payload,
    this.onEdit,
    this.onDelete,
  });

  final Map<String, dynamic> payload;
  final void Function(Map<String, dynamic> row)? onEdit;
  final Future<void> Function(String term)? onDelete;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  static Widget skeleton() => Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 5; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                    height: Ds.space.x48,
                    decoration: BoxDecoration(
                        color: Ds.c.surface, borderRadius: Ds.r.rCard)),
              ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] != true) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(_s(payload, 'message'),
              textAlign: TextAlign.center, style: Ds.t.body),
        ),
      );
    }

    final rows = ((payload['rows'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(payload, 'subtitle'), style: Ds.t.body),
        SizedBox(height: Ds.space.x4),
        Text(_s(payload, 'count_label'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        if (rows.isEmpty)
          Text(_s(payload, 'empty_note'), style: Ds.t.caption)
        else
          for (final r in rows) ...[
            Container(
              padding: EdgeInsets.all(Ds.space.x16),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // "bukhar → Paracetamol", composed by the backend.
                        Text(_s(r, 'subtitle'), style: Ds.t.body),
                        SizedBox(height: Ds.space.x4),
                        Text(_s(r, 'source_label'), style: Ds.t.caption),
                      ],
                    ),
                  ),
                  if (onEdit != null)
                    IconButton(
                      tooltip: _s(payload, 'save_label'),
                      onPressed: () => onEdit!(r),
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  if (onDelete != null)
                    IconButton(
                      tooltip: _s(payload, 'delete_label'),
                      onPressed: () => onDelete!(_s(r, 'term')),
                      icon: Icon(Icons.delete_outline, color: Ds.c.danger),
                    ),
                ],
              ),
            ),
            SizedBox(height: Ds.space.x12),
          ],
      ],
    );
  }
}

/// Add or edit one mapping. The two dropdowns offer exactly the options the
/// payload carried — a language or a match-kind this build has never heard of
/// still renders, because the list is the backend's.
class SynonymEditSheet extends StatefulWidget {
  const SynonymEditSheet({super.key, required this.payload, this.row});

  final Map<String, dynamic> payload;
  final Map<String, dynamic>? row;

  @override
  State<SynonymEditSheet> createState() => _SynonymEditSheetState();
}

class _SynonymEditSheetState extends State<SynonymEditSheet> {
  late final TextEditingController _term =
      TextEditingController(text: '${widget.row?['term'] ?? ''}');
  late final TextEditingController _target =
      TextEditingController(text: '${widget.row?['target'] ?? ''}');
  late String _lang = '${widget.row?['lang'] ?? 'hi'}';
  late String _kind = '${widget.row?['target_kind'] ?? 'salt'}';
  late bool _active = widget.row?['active'] != false;

  @override
  void dispose() {
    _term.dispose();
    _target.dispose();
    super.dispose();
  }

  String _s(String k) => (widget.payload[k] ?? '').toString();

  List<Map<String, dynamic>> _options(String k) =>
      ((widget.payload[k] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  @override
  Widget build(BuildContext context) {
    final langs = _options('lang_options');
    final kinds = _options('kind_options');
    return Padding(
      padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16, Ds.space.x16,
          MediaQuery.of(context).viewInsets.bottom + Ds.space.x16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_s('add_label'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: _term,
            decoration: InputDecoration(
                labelText: _s('term_label'), hintText: _s('term_hint')),
          ),
          SizedBox(height: Ds.space.x12),
          TextField(
            controller: _target,
            decoration: InputDecoration(
                labelText: _s('target_label'), hintText: _s('target_hint')),
          ),
          SizedBox(height: Ds.space.x12),
          if (langs.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue:
                  langs.any((o) => '${o['key']}' == _lang) ? _lang : null,
              decoration: InputDecoration(labelText: _s('lang_label')),
              items: [
                for (final o in langs)
                  DropdownMenuItem(
                      value: '${o['key']}', child: Text('${o['label']}')),
              ],
              onChanged: (v) => setState(() => _lang = v ?? _lang),
            ),
          SizedBox(height: Ds.space.x12),
          if (kinds.isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue:
                  kinds.any((o) => '${o['key']}' == _kind) ? _kind : null,
              decoration: InputDecoration(labelText: _s('kind_label')),
              items: [
                for (final o in kinds)
                  DropdownMenuItem(
                      value: '${o['key']}', child: Text('${o['label']}')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? _kind),
            ),
          SizedBox(height: Ds.space.x12),
          SwitchListTile(
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: Text(_s('active_label'), style: Ds.t.body),
            contentPadding: EdgeInsets.zero,
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
              onPressed: () => Navigator.of(context).pop(<String, dynamic>{
                'term': _term.text,
                'target': _target.text,
                'lang': _lang,
                'target_kind': _kind,
                'display': _term.text,
                'note': widget.row?['note'],
                'active': _active,
              }),
              child: Text(_s('save_label')),
            ),
          ),
        ],
      ),
    );
  }
}
