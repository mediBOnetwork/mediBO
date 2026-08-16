import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// Portable Memory (#182) — the app surface for the provider-agnostic agent
/// memory. One RPC in (`memory_list`), rendered verbatim: every label, scope
/// name, hint and toast string is backend-owned. Editing writes straight back
/// to the Supabase source of truth via `memory_put` / `memory_delete`; the VM
/// renderer re-writes RULES.md + every agent file on the next session, and the
/// memory MCP server serves the same rows to any other agent live.
///
/// THE APP RENDERS. IT NEVER DECIDES. — no rule text, ordering, or wording is
/// invented here; the backend already grouped and formatted the rows.
class MemoryScreen extends StatefulWidget {
  final DevQueueService? service;
  const MemoryScreen({super.key, this.service});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();

  Map<String, dynamic> _payload = const {};
  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _labels = const {};
  List<Map<String, dynamic>> _scopes = const [];
  List<String> _sections = const [];
  String _query = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await _svc.memoryList();
      if (!mounted) return;
      setState(() {
        _payload = p;
        _rows = ((p['rows'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _labels = (p['labels'] as Map?)?.cast<String, dynamic>() ?? const {};
        _scopes = ((p['scopes'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _sections = ((p['sections_hint'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _lbl(String k) => (_labels[k] ?? '').toString();

  List<Map<String, dynamic>> get _visible {
    if (_query.trim().isEmpty) return _rows;
    final q = _query.toLowerCase();
    return _rows
        .where((r) =>
            (r['section'] ?? '').toString().toLowerCase().contains(q) ||
            (r['body'] ?? '').toString().toLowerCase().contains(q) ||
            (r['scope'] ?? '').toString().toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final title = (_payload['screen_title'] ?? '').toString();
    final subtitle = (_payload['subtitle'] ?? '').toString();
    final visible = _visible;
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(title.isEmpty ? 'Agent Memory' : title,
            style:
                Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      floatingActionButton: _loading
          ? null
          : FloatingActionButton.extended(
              backgroundColor: kBrand,
              onPressed: () => _openEditor(null),
              icon: const Icon(Icons.add, color: Colors.white),
              label: Text(_lbl('add'),
                  style: Ds.t.body
                      .copyWith(color: Colors.white, fontWeight: FontWeight.w600)),
            ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: kBrand))
            : Column(children: [
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                        Ds.space.x16, Ds.space.x12, Ds.space.x16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(subtitle,
                          style: Ds.t.caption.copyWith(color: kTextLo)),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                      Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x8),
                  child: TextField(
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      prefixIcon: Icon(Icons.search, color: kTextLo),
                      hintText: _lbl('search_hint'),
                      filled: true,
                      fillColor: Colors.white,
                      isDense: true,
                      border: OutlineInputBorder(
                          borderRadius: Ds.r.rButton,
                          borderSide: BorderSide(color: kBorder)),
                    ),
                  ),
                ),
                Expanded(
                  child: visible.isEmpty
                      ? Center(
                          child: Padding(
                            padding: EdgeInsets.all(Ds.space.x32),
                            child: Text(_lbl('empty'),
                                textAlign: TextAlign.center,
                                style: Ds.t.body.copyWith(color: kTextLo)),
                          ),
                        )
                      : RefreshIndicator(
                          color: kBrand,
                          onRefresh: _load,
                          child: ListView.builder(
                            padding: EdgeInsets.fromLTRB(Ds.space.x16,
                                Ds.space.x8, Ds.space.x16, Ds.space.x48),
                            itemCount: visible.length,
                            itemBuilder: (_, i) => _ruleCard(visible[i]),
                          ),
                        ),
                ),
              ]),
      ),
    );
  }

  Widget _ruleCard(Map<String, dynamic> r) {
    final scope = (r['scope'] ?? '').toString();
    final section = (r['section'] ?? '').toString();
    final body = (r['body'] ?? '').toString();
    final metaLabel = (r['meta_label'] ?? '').toString();
    final updated = (r['updated_label'] ?? '').toString();
    final enabled = r['enabled'] == true;
    final priority = r['priority'];

    final tone = scope == 'global'
        ? toneByName('info')
        : (scope == 'project' ? toneByName('success') : toneByName('neutral'));

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DqCard(
        accent: scope == 'global' ? Ds.c.brand : kBorder,
        onTap: () => _openEditor(r),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(section,
                  style: Ds.t.body
                      .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
            ),
            ToneChip(label: scope, tone: tone, icon: Icons.public),
          ]),
          SizedBox(height: Ds.space.x8),
          Text(body,
              style: Ds.t.body.copyWith(color: kTextHi, height: 1.35)),
          SizedBox(height: Ds.space.x12),
          Row(children: [
            Icon(enabled ? Icons.check_circle_outline : Icons.pause_circle_outline,
                size: Ds.space.x16, color: enabled ? kBrand : kTextLo),
            SizedBox(width: Ds.space.x4),
            Expanded(
              child: Text('$metaLabel · ${_lbl('priority')} $priority',
                  style: Ds.t.caption.copyWith(color: kTextLo)),
            ),
          ]),
          if (updated.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(updated, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
        ]),
      ),
    );
  }

  // ── Add / edit sheet (sheets > dialogs per the design contract) ────────────
  Future<void> _openEditor(Map<String, dynamic>? row) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MemoryEditor(
        svc: _svc,
        labels: _labels,
        scopes: _scopes,
        sections: _sections,
        existing: row,
      ),
    );
    if (result == null || !mounted) return;
    showToast(context,
        result == 'deleted' ? _lbl('deleted_toast') : _lbl('saved_toast'));
    _load();
  }
}

class _MemoryEditor extends StatefulWidget {
  final DevQueueService svc;
  final Map<String, dynamic> labels;
  final List<Map<String, dynamic>> scopes;
  final List<String> sections;
  final Map<String, dynamic>? existing;
  const _MemoryEditor({
    required this.svc,
    required this.labels,
    required this.scopes,
    required this.sections,
    required this.existing,
  });

  @override
  State<_MemoryEditor> createState() => _MemoryEditorState();
}

class _MemoryEditorState extends State<_MemoryEditor> {
  late String _scope;
  late final TextEditingController _section;
  late final TextEditingController _body;
  late final TextEditingController _priority;
  bool _busy = false;

  String _lbl(String k) => (widget.labels[k] ?? '').toString();

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _scope = (e?['scope'] ?? (widget.scopes.isNotEmpty
            ? widget.scopes.first['value']
            : 'global'))
        .toString();
    _section = TextEditingController(text: (e?['section'] ?? '').toString());
    _body = TextEditingController(text: (e?['body'] ?? '').toString());
    _priority =
        TextEditingController(text: (e?['priority'] ?? 100).toString());
  }

  @override
  void dispose() {
    _section.dispose();
    _body.dispose();
    _priority.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final section = _section.text.trim();
    final body = _body.text.trim();
    if (section.isEmpty || body.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.svc.memoryPut(
        _scope,
        section,
        body,
        int.tryParse(_priority.text.trim()) ?? 100,
      );
      if (mounted) Navigator.of(context).pop('saved');
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final id = (widget.existing?['id'] ?? '').toString();
    if (id.isEmpty) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        margin: EdgeInsets.all(Ds.space.x16),
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: Ds.r.rCard),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_lbl('delete_confirm'),
              style: Ds.t.body.copyWith(color: kTextHi)),
          SizedBox(height: Ds.space.x16),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(_lbl('cancel')),
              ),
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Ds.c.danger),
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(_lbl('delete'),
                    style: Ds.t.body.copyWith(color: Colors.white)),
              ),
            ),
          ]),
        ]),
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await widget.svc.memoryDelete(id);
      if (mounted) Navigator.of(context).pop('deleted');
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        margin: EdgeInsets.all(Ds.space.x12),
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(color: Colors.white, borderRadius: Ds.r.rCard),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isEdit ? _lbl('edit') : _lbl('add'),
                  style: Ds.t.subtitle
                      .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
              SizedBox(height: Ds.space.x16),
              Text(_lbl('scope'),
                  style: Ds.t.caption
                      .copyWith(fontWeight: FontWeight.w600, color: kTextLo)),
              SizedBox(height: Ds.space.x8),
              Wrap(spacing: Ds.space.x8, children: [
                for (final s in widget.scopes)
                  ChoiceChip(
                    label: Text((s['label'] ?? '').toString(),
                        style: Ds.t.caption.copyWith(
                            fontWeight: FontWeight.w600,
                            color: _scope == s['value']
                                ? Colors.white
                                : kTextHi)),
                    selected: _scope == s['value'],
                    selectedColor: kBrand,
                    backgroundColor: Colors.white,
                    side: BorderSide(
                        color: _scope == s['value'] ? kBrand : kBorder),
                    onSelected: (_) =>
                        setState(() => _scope = (s['value'] ?? 'global').toString()),
                  ),
              ]),
              SizedBox(height: Ds.space.x16),
              _field(_lbl('section'), _section, hint: _lbl('section_hint')),
              if (widget.sections.isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
                  for (final s in widget.sections)
                    ActionChip(
                      label: Text(s,
                          style: Ds.t.caption.copyWith(color: kTextHi)),
                      backgroundColor: kPageBg,
                      side: BorderSide(color: kBorder),
                      onPressed: () => setState(() => _section.text = s),
                    ),
                ]),
              ],
              SizedBox(height: Ds.space.x16),
              _field(_lbl('body'), _body, hint: _lbl('body_hint'), lines: 5),
              SizedBox(height: Ds.space.x16),
              _field(_lbl('priority'), _priority, number: true),
              SizedBox(height: Ds.space.x24),
              Row(children: [
                if (isEdit)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _delete,
                      icon: Icon(Icons.delete_outline, color: Ds.c.danger),
                      label: Text(_lbl('delete'),
                          style: Ds.t.body.copyWith(color: Ds.c.danger)),
                      style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Ds.c.danger)),
                    ),
                  ),
                if (isEdit) SizedBox(width: Ds.space.x12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: kBrand,
                        minimumSize: Size.fromHeight(Ds.space.x48)),
                    onPressed: _busy ? null : _save,
                    child: _busy
                        ? SizedBox(
                            height: Ds.space.x16,
                            width: Ds.space.x16,
                            child: const CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(_lbl('save'),
                            style: Ds.t.body.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600)),
                  ),
                ),
              ]),
              if ((widget.labels['mcp_hint'] ?? '').toString().isNotEmpty) ...[
                SizedBox(height: Ds.space.x16),
                Text(_lbl('mcp_hint'),
                    style: Ds.t.caption.copyWith(color: kTextLo)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctl,
      {String hint = '', int lines = 1, bool number = false}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label,
          style:
              Ds.t.caption.copyWith(fontWeight: FontWeight.w600, color: kTextLo)),
      SizedBox(height: Ds.space.x8),
      TextField(
        controller: ctl,
        maxLines: lines,
        keyboardType: number ? TextInputType.number : TextInputType.multiline,
        decoration: InputDecoration(
          hintText: hint,
          filled: true,
          fillColor: kPageBg,
          isDense: true,
          border: OutlineInputBorder(
              borderRadius: Ds.r.rButton, borderSide: BorderSide(color: kBorder)),
          focusedBorder: OutlineInputBorder(
              borderRadius: Ds.r.rButton, borderSide: BorderSide(color: kBrand)),
        ),
      ),
    ]);
  }
}
