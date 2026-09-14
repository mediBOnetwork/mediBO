// CMD #1986 — Admin › Partner agreement › Printed document.
//
// Om, mid-build: "all fields in agreement should be editable no hardcoded at
// all". This is that door. Everything the contract PDF puts on paper is edited
// here and nowhere else:
//   • the WHEREAS recitals, added, reworded, reordered, deleted;
//   • the defined terms, each one a bold term and a meaning;
//   • the schedules themselves — a fourth schedule is a row, not a release —
//     each naming which platform record fills its table;
//   • every heading, label, column caption, status line, note and sentence the
//     PDF or the public verification page prints, field by field.
//
// The screen decides NOTHING. Section headings, hints, button captions, the
// source names, the read-only notice and every refusal come from
// agreement_doc_editor(); the three writes are agreement_front_save(),
// agreement_schedule_save() and agreement_text_save(), and each hands back the
// whole editor state to draw next. The FIGURES are never editable here on
// purpose: the split, the licence numbers and the zone come from the records
// the platform settles on, so the printed contract and the payout can never
// disagree.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../partner/partner_ui.dart';

class AgreementDocumentScreen extends StatefulWidget {
  const AgreementDocumentScreen({super.key, this.versionId});

  final int? versionId;

  /// Test seam — the same shape every screen in this app uses.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<AgreementDocumentScreen> createState() => _AgreementDocumentScreenState();
}

class _AgreementDocumentScreenState extends State<AgreementDocumentScreen> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : const {};

  static String _s(Map<String, dynamic> m, String k) =>
      (m[k] == null) ? '' : m[k].toString();

  static List<Map<String, dynamic>> _list(Map<String, dynamic> m, String k) {
    final raw = m[k];
    if (raw is! List) return const [];
    return raw
        .map((e) => e is Map ? Map<String, dynamic>.from(e) : null)
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  String _t(String k) => _s(_p, k);

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final raw = await AgreementDocumentScreen.rpc('agreement_doc_editor',
          {if (widget.versionId != null) 'p_version_id': widget.versionId});
      final m = _map(raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (!mounted) return;
      setState(() {
        _p = m;
        _loading = false;
      });
      RenderLog.write(
          'c1986_agreement_doc_editor',
          'recitals=${_list(_map(m['recitals']), 'items').length},'
              'definitions=${_list(_map(m['definitions']), 'items').length},'
              'schedules=${_list(_map(m['schedules']), 'items').length},'
              'wording=${_list(_map(m['wording']), 'groups').length}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// Every write: call, print the backend's own message, redraw from the state
  /// it handed back. The screen never patches its own list.
  Future<bool> _write(String fn, Map<String, dynamic> body) async {
    setState(() => _busy = true);
    try {
      final raw = await AgreementDocumentScreen.rpc(fn, {'p': body});
      final m = _map(raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (!mounted) return false;
      final next = _map(m['editor']);
      setState(() {
        _busy = false;
        if (next.isNotEmpty) _p = next;
      });
      final msg = _s(m, 'message');
      if (msg.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
      return m['ok'] == true;
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
      return false;
    }
  }

  bool get _canEdit => _p['can_edit'] == true;
  int? get _versionId => (_p['version_id'] as num?)?.toInt();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_t('title'))),
      body: SafeArea(
        child: _loading
            ? const PartnerSkeleton(rows: 6)
            : _p['ok'] != true
                ? PartnerNotice(text: _t('message'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: EdgeInsets.all(Ds.space.x16),
                      children: [
                        Text(_t('sub'), style: Ds.t.bodySecondary),
                        if (_t('readonly_note').isNotEmpty) ...[
                          SizedBox(height: Ds.space.x12),
                          Container(
                            width: double.infinity,
                            padding: EdgeInsets.all(Ds.space.x12),
                            decoration: BoxDecoration(
                              color: Ds.c.warningSoft,
                              borderRadius: Ds.r.rCard,
                            ),
                            child: Text(_t('readonly_note'),
                                style: Ds.t.bodySecondary),
                          ),
                        ],
                        SizedBox(height: Ds.space.x24),
                        _recitals(),
                        SizedBox(height: Ds.space.x24),
                        _definitions(),
                        SizedBox(height: Ds.space.x24),
                        _schedules(),
                        SizedBox(height: Ds.space.x24),
                        _wording(),
                        SizedBox(height: Ds.space.x32),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _sectionHead(Map<String, dynamic> b) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(b, 'heading'), style: Ds.t.subtitle),
          if (_s(b, 'hint').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(b, 'hint'), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x12),
        ],
      );

  Widget _addButton(String label, VoidCallback onTap) => SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: OutlinedButton.icon(
          onPressed: _busy || !_canEdit ? null : onTap,
          icon: const Icon(Icons.add),
          label: Text(label),
        ),
      );

  // ── recitals ──────────────────────────────────────────────────────────────
  Widget _recitals() {
    final b = _map(_p['recitals']);
    final items = _list(b, 'items');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHead(b),
        if (items.isEmpty) PartnerNotice(text: _s(b, 'empty')),
        for (var i = 0; i < items.length; i++)
          PartnerCard(
            onTap: _canEdit ? () => _frontSheet('recital', b, items[i]) : null,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: Text(String.fromCharCode(65 + i),
                      style: Ds.t.bodyStrong),
                ),
                Expanded(
                  child: Text(_s(items[i], 'body'), style: Ds.t.body),
                ),
                if (_canEdit)
                  Icon(Icons.edit_outlined, size: 18, color: Ds.c.textSecondary),
              ],
            ),
          ),
        SizedBox(height: Ds.space.x8),
        _addButton(_s(b, 'add_label'), () => _frontSheet('recital', b, const {})),
      ],
    );
  }

  // ── defined terms ─────────────────────────────────────────────────────────
  Widget _definitions() {
    final b = _map(_p['definitions']);
    final items = _list(b, 'items');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHead(b),
        if (items.isEmpty) PartnerNotice(text: _s(b, 'empty')),
        for (var i = 0; i < items.length; i++)
          PartnerCard(
            onTap:
                _canEdit ? () => _frontSheet('definition', b, items[i]) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(_s(items[i], 'term'), style: Ds.t.bodyStrong),
                    ),
                    if (_canEdit)
                      Icon(Icons.edit_outlined,
                          size: 18, color: Ds.c.textSecondary),
                  ],
                ),
                SizedBox(height: Ds.space.x4),
                Text(_s(items[i], 'body'), style: Ds.t.bodySecondary),
              ],
            ),
          ),
        SizedBox(height: Ds.space.x8),
        _addButton(
            _s(b, 'add_label'), () => _frontSheet('definition', b, const {})),
      ],
    );
  }

  Future<void> _frontSheet(
      String kind, Map<String, dynamic> b, Map<String, dynamic> item) async {
    final isDef = kind == 'definition';
    final id = (item['id'] as num?)?.toInt();
    await _sheet(
      heading: _s(b, 'heading'),
      help: _t('token_help'),
      fields: [
        if (isDef)
          _SheetField('term', _s(b, 'term_hint'), _s(item, 'term'), false),
        _SheetField('body', _s(b, 'body_hint'), _s(item, 'body'), true),
      ],
      onDelete: id == null
          ? null
          : () => _write('agreement_front_save',
              {'id': id, 'kind': kind, 'delete': true}),
      onSave: (v, _) => _write('agreement_front_save', {
        if (id != null) 'id': id,
        if (id == null) 'version_id': _versionId,
        'kind': kind,
        'term': v['term'] ?? '',
        'body': v['body'] ?? '',
      }),
    );
  }

  // ── schedules ─────────────────────────────────────────────────────────────
  Widget _schedules() {
    final b = _map(_p['schedules']);
    final items = _list(b, 'items');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHead(b),
        if (items.isEmpty) PartnerNotice(text: _s(b, 'empty')),
        for (final s in items)
          PartnerCard(
            onTap: _canEdit ? () => _scheduleSheet(b, s) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('${_s(s, 'code')} — ${_s(s, 'heading')}',
                          style: Ds.t.bodyStrong),
                    ),
                    if (_canEdit)
                      Icon(Icons.edit_outlined,
                          size: 18, color: Ds.c.textSecondary),
                  ],
                ),
                SizedBox(height: Ds.space.x4),
                Text(_s(s, 'source_label'), style: Ds.t.caption),
                if (_s(s, 'intro').isNotEmpty) ...[
                  SizedBox(height: Ds.space.x8),
                  Text(_s(s, 'intro'), style: Ds.t.bodySecondary),
                ],
              ],
            ),
          ),
        SizedBox(height: Ds.space.x8),
        _addButton(_s(b, 'add_label'), () => _scheduleSheet(b, const {})),
      ],
    );
  }

  Future<void> _scheduleSheet(
      Map<String, dynamic> b, Map<String, dynamic> item) async {
    final id = (item['id'] as num?)?.toInt();
    await _sheet(
      heading: _s(b, 'heading'),
      fields: [
        _SheetField('code', _s(b, 'code_hint'), _s(item, 'code'), false),
        _SheetField('heading', _s(b, 'heading_hint'), _s(item, 'heading'), false),
        _SheetField('intro', _s(b, 'intro_hint'), _s(item, 'intro'), true),
        _SheetField('note', _s(b, 'note_hint'), _s(item, 'note'), true),
      ],
      chipLabel: _s(b, 'source_label'),
      chips: _list(b, 'sources'),
      chipSelected: _s(item, 'source').isEmpty ? 'none' : _s(item, 'source'),
      onDelete: id == null
          ? null
          : () => _write('agreement_schedule_save', {'id': id, 'delete': true}),
      onSave: (v, chip) => _write('agreement_schedule_save', {
        if (id != null) 'id': id,
        if (id == null) 'version_id': _versionId,
        'code': v['code'] ?? '',
        'heading': v['heading'] ?? '',
        'intro': v['intro'] ?? '',
        'note': v['note'] ?? '',
        'source': chip ?? 'none',
      }),
    );
  }

  // ── every printed word ────────────────────────────────────────────────────
  Widget _wording() {
    final b = _map(_p['wording']);
    final groups = _list(b, 'groups');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHead(b),
        if (groups.isEmpty) PartnerNotice(text: _s(b, 'empty')),
        for (final g in groups)
          PartnerCard(
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.only(bottom: Ds.space.x8),
                title: Text(_s(g, 'group_label'), style: Ds.t.bodyStrong),
                children: [
                  for (final f in _list(g, 'fields'))
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      minVerticalPadding: Ds.space.x8,
                      title: Text(_s(f, 'label'), style: Ds.t.caption),
                      subtitle: Text(_s(f, 'value'), style: Ds.t.body),
                      trailing: _canEdit
                          ? Icon(Icons.edit_outlined,
                              size: 18, color: Ds.c.textSecondary)
                          : null,
                      onTap: _canEdit ? () => _textSheet(f) : null,
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _textSheet(Map<String, dynamic> f) async {
    await _sheet(
      heading: _s(f, 'label'),
      help: _s(f, 'hint'),
      fields: [
        _SheetField('value', _s(f, 'label'), _s(f, 'value'),
            f['multiline'] == true),
      ],
      onSave: (v, _) => _write('agreement_text_save', {
        'key': _s(f, 'key'),
        'value': v['value'] ?? '',
        'version_id': _versionId,
      }),
    );
  }

  /// ONE sheet for all three writes. It is a StatefulWidget of its own so the
  /// TextEditingControllers live and die with the sheet's element: creating
  /// them in the caller and disposing them when showModalBottomSheet returns
  /// throws "used after being disposed" during the sheet's exit animation.
  Future<void> _sheet({
    required String heading,
    required List<_SheetField> fields,
    required Future<bool> Function(Map<String, String> values, String? chip)
        onSave,
    String? help,
    String? chipLabel,
    List<Map<String, dynamic>> chips = const [],
    String? chipSelected,
    Future<bool> Function()? onDelete,
  }) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Ds.c.surface,
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
        builder: (ctx) => _EditSheet(
          heading: heading,
          help: help,
          fields: fields,
          chipLabel: chipLabel,
          chips: chips,
          chipSelected: chipSelected,
          saveLabel: _t('save_label'),
          deleteLabel: _t('delete_label'),
          onSave: onSave,
          onDelete: onDelete,
        ),
      );
}

/// One field inside the sheet: which key it writes, what the backend calls it,
/// what it holds now, and whether it is a paragraph.
class _SheetField {
  const _SheetField(this.key, this.label, this.initial, this.multiline);
  final String key;
  final String label;
  final String initial;
  final bool multiline;
}

class _EditSheet extends StatefulWidget {
  const _EditSheet({
    required this.heading,
    required this.fields,
    required this.saveLabel,
    required this.deleteLabel,
    required this.onSave,
    this.help,
    this.chipLabel,
    this.chips = const [],
    this.chipSelected,
    this.onDelete,
  });

  final String heading;
  final String? help;
  final List<_SheetField> fields;
  final String? chipLabel;
  final List<Map<String, dynamic>> chips;
  final String? chipSelected;
  final String saveLabel;
  final String deleteLabel;
  final Future<bool> Function(Map<String, String> values, String? chip) onSave;
  final Future<bool> Function()? onDelete;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final Map<String, TextEditingController> _ctl = {
    for (final f in widget.fields)
      f.key: TextEditingController(text: f.initial),
  };
  late String? _chip = widget.chipSelected;

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16, Ds.space.x16,
          MediaQuery.of(context).viewInsets.bottom + Ds.space.x16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.heading, style: Ds.t.subtitle),
            if ((widget.help ?? '').isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(widget.help!, style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x12),
            for (final f in widget.fields) ...[
              TextField(
                controller: _ctl[f.key],
                maxLines: f.multiline ? 6 : 2,
                minLines: f.multiline ? 3 : 1,
                decoration: InputDecoration(labelText: f.label),
              ),
              SizedBox(height: Ds.space.x12),
            ],
            if (widget.chips.isNotEmpty) ...[
              Text(widget.chipLabel ?? '', style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
              Wrap(
                spacing: Ds.space.x8,
                runSpacing: Ds.space.x8,
                children: [
                  for (final s in widget.chips)
                    ChoiceChip(
                      label: Text((s['label'] ?? '').toString()),
                      selected: _chip == (s['key'] ?? '').toString(),
                      onSelected: (_) => setState(
                          () => _chip = (s['key'] ?? '').toString()),
                    ),
                ],
              ),
              SizedBox(height: Ds.space.x16),
            ],
            Row(
              children: [
                if (widget.onDelete != null)
                  TextButton(
                    onPressed: () {
                      final run = widget.onDelete!;
                      Navigator.of(context).pop();
                      run();
                    },
                    child: Text(widget.deleteLabel,
                        style: TextStyle(color: Ds.c.danger)),
                  ),
                const Spacer(),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: () {
                      final values = {
                        for (final e in _ctl.entries) e.key: e.value.text,
                      };
                      final chip = _chip;
                      Navigator.of(context).pop();
                      widget.onSave(values, chip);
                    },
                    child: Text(widget.saveLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
