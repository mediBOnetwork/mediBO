// CHANGE — saved segments for WhatsApp campaigns.
//
// /admin/wa-segments — a named, reusable audience: "customers who ordered 3+
// times", "suppliers who answered nothing in 30 days". A campaign then points
// at the segment by id instead of carrying a copy of its rules.
//
// The screen holds NO vocabulary of its own. Every field an admin may filter
// on, every operator, and the two match modes arrive in the payload:
//
//   fields.customer / fields.supplier -> [{value,label,type}]
//   operators                         -> [{value,label}]
//   match_modes                       -> [{value,label}]
//
// So adding a filterable field is a backend change with no deploy, and this
// file cannot offer a filter the backend cannot resolve. `matches` is likewise
// the backend's count, refetched with the list — never a number computed here
// from the rules, which would be a second implementation of the segment.
//
// One shape leaves this file, and it is exact:
//   {"match":"all|any","rules":[{"field":...,"op":...,"value":...}]}
import 'package:flutter/material.dart';

import '../../features/whatsapp/data/wa_campaign_api.dart';
import '../../features/whatsapp/ui/wa_campaign_chips.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

const _kGreen = Color(0xFF1B7A43);
const _kBg = Color(0xFFF5F6F8);
const _kCard = Colors.white;
const _kBorder = Color(0xFFE5E7EB);
const _kText = Color(0xFF111827);
const _kMuted = Color(0xFF6B7280);
const _kRed = Color(0xFFB91C1C);

class WaSegmentsScreen extends StatefulWidget {
  final WaAudiencesScreenRpc? screenRpc;
  final WaAudienceSaveRpc? saveRpc;
  final WaAudienceDeleteRpc? deleteRpc;

  const WaSegmentsScreen({
    super.key,
    this.screenRpc,
    this.saveRpc,
    this.deleteRpc,
  });

  @override
  State<WaSegmentsScreen> createState() => _WaSegmentsScreenState();
}

class _WaSegmentsScreenState extends State<WaSegmentsScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await (widget.screenRpc ?? waAudiencesScreen)();
      if (!mounted) return;
      final err = waPayloadError(res);
      setState(() {
        _loading = false;
        _error = err;
        _payload = err == null ? res : null;
      });
      if (err == null) {
        try {
          RenderLog.write('wa_segments_screen',
              'rows=${(res['rows'] as List?)?.length ?? 0}');
        } catch (_) {}
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<Map<String, dynamic>> get _rows =>
      ((_payload?['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// of_label belongs to the ROWS, not to the fields map — so the two audience
  /// buttons in the editor are labelled from a row that already uses that side
  /// when one exists, and from the backend's own key when none does. Either
  /// way the words are the backend's.
  String ofLabel(String key) {
    for (final r in _rows) {
      if ((r['audience_of'] ?? '').toString() == key) {
        final l = (r['of_label'] ?? '').toString();
        if (l.isNotEmpty) return l;
      }
    }
    return key;
  }

  Future<void> _openEditor({Map<String, dynamic>? segment}) async {
    final p = _payload ?? const {};
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WaSegmentEditor(
          segment: segment,
          matchModes: (p['match_modes'] as List?) ?? const [],
          operators: (p['operators'] as List?) ?? const [],
          fields: Map<String, dynamic>.from((p['fields'] as Map?) ?? const {}),
          ofLabel: ofLabel,
          saveRpc: widget.saveRpc,
        ),
      ),
    );
    if (saved == true) _load();
  }

  Future<void> _delete(Map<String, dynamic> s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this segment?'),
        content: Text((s['name'] ?? '').toString(),
            style: const TextStyle(fontSize: 13.5)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: _kRed),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final res =
          await (widget.deleteRpc ?? waAudienceDelete)((s['id'] ?? '').toString());
      if (!mounted) return;
      final err = waPayloadError(res);
      // A refusal changes nothing else — the list is not touched and the
      // backend's sentence is all the admin is told.
      if (err != null) {
        showToast(context, err, isError: true);
        return;
      }
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kCard,
        elevation: 0,
        foregroundColor: _kText,
        title: const Text('Segments',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: _kBorder),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: _payload == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('New segment'),
            ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(
            strokeWidth: 2.5, valueColor: AlwaysStoppedAnimation(_kGreen)),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 36, color: _kRed),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: _kMuted)),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _load,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _kGreen, foregroundColor: Colors.white),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final rows = _rows;
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            (_payload?['empty_copy'] ?? '').toString(),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13.5, height: 1.4, color: _kMuted),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
        children: [
          for (final s in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _SegmentCard(
                s: s,
                onEdit: () => _openEditor(segment: s),
                onDelete: () => _delete(s),
              ),
            ),
        ],
      ),
    );
  }
}

class _SegmentCard extends StatelessWidget {
  final Map<String, dynamic> s;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _SegmentCard({
    required this.s,
    required this.onEdit,
    required this.onDelete,
  });

  String _v(String k) => (s[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final canDelete = s['can_delete'] == true;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(_v('name'),
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _kText)),
              ),
              if (_v('of_label').isNotEmpty)
                WaPlainChip(label: _v('of_label')),
            ],
          ),
          if (_v('description').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_v('description'),
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.35, color: _kMuted)),
            ),
          if (_v('match_label').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_v('match_label'),
                  style: const TextStyle(fontSize: 12.5, color: _kMuted)),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              _stat('Rules', _v('rule_count')),
              const SizedBox(width: 20),
              // The live count. It is refetched with the list rather than
              // recalculated when a rule changes — one number, one source.
              _stat('Matches', _v('matches')),
            ],
          ),
          if (_v('updated_label').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_v('updated_label'),
                  style: const TextStyle(fontSize: 11.5, color: _kMuted)),
            ),
          const SizedBox(height: 8),
          const Divider(height: 1, color: _kBorder),
          const SizedBox(height: 6),
          Row(
            children: [
              TextButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined, size: 15),
                label: const Text('Edit', style: TextStyle(fontSize: 12.5)),
              ),
              // can_delete is the backend's answer to "is anything still using
              // this?". Never inferred from rule_count or from matches.
              TextButton.icon(
                onPressed: canDelete ? onDelete : null,
                style: TextButton.styleFrom(
                    foregroundColor: _kRed,
                    disabledForegroundColor: const Color(0xFF9CA3AF)),
                icon: const Icon(Icons.delete_outline, size: 15),
                label: const Text('Delete', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String caption, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(caption,
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: _kMuted)),
          const SizedBox(height: 2),
          Text(value,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
        ],
      );
}

// ── editor ──────────────────────────────────────────────────────────────────

/// Builds ONE jsonb value. Nothing here interprets a rule: an operator is a
/// string taken from `operators`, a field is a string taken from `fields`, and
/// the value is typed by the admin and sent as typed. Whether "gte 3" is
/// meaningful for the `orders` field is wa_audience_save()'s judgement, and its
/// {error, message} is printed unchanged when it says no.
class WaSegmentEditor extends StatefulWidget {
  /// Existing row from wa_audiences_screen when editing; null = new.
  final Map<String, dynamic>? segment;
  final List<dynamic> matchModes;
  final List<dynamic> operators;

  /// {customer:[{value,label,type}], supplier:[...]}
  final Map<String, dynamic> fields;

  /// Resolves an audience_of key to the backend's own label for it.
  final String Function(String key)? ofLabel;

  final WaAudienceSaveRpc? saveRpc;

  const WaSegmentEditor({
    super.key,
    this.segment,
    this.matchModes = const [],
    this.operators = const [],
    this.fields = const {},
    this.ofLabel,
    this.saveRpc,
  });

  @override
  State<WaSegmentEditor> createState() => _WaSegmentEditorState();
}

class _WaSegmentEditorState extends State<WaSegmentEditor> {
  final _keyCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  late String _audienceOf;
  String? _match;
  final List<_RuleRow> _rules = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Default to the first side the backend listed, and the first match mode it
    // listed. Both are the payload's order, not a preference held here.
    final sides = widget.fields.keys.toList();
    _audienceOf = sides.isEmpty ? '' : sides.first;
    _match = _firstMatchValue();

    final s = widget.segment;
    if (s != null) {
      _keyCtrl.text = (s['key'] ?? '').toString();
      _nameCtrl.text = (s['name'] ?? '').toString();
      _descCtrl.text = (s['description'] ?? '').toString();
      final of = (s['audience_of'] ?? '').toString();
      if (of.isNotEmpty) _audienceOf = of;
      final filters = (s['filters'] as Map?) ?? const {};
      final m = (filters['match'] ?? '').toString();
      if (m.isNotEmpty) _match = m;
      for (final r in ((filters['rules'] as List?) ?? const [])) {
        if (r is! Map) continue;
        _rules.add(_RuleRow()
          ..field = (r['field'] ?? '').toString().isEmpty
              ? null
              : (r['field']).toString()
          ..op = (r['op'] ?? '').toString().isEmpty ? null : (r['op']).toString()
          ..valueCtrl.text = (r['value'] ?? '').toString());
      }
    }
  }

  String? _firstMatchValue() {
    for (final m in widget.matchModes) {
      if (m is Map) return (m['value'] ?? '').toString();
    }
    return null;
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _nameCtrl.dispose();
    _descCtrl.dispose();
    for (final r in _rules) {
      r.valueCtrl.dispose();
    }
    super.dispose();
  }

  List<Map<String, dynamic>> get _fieldsForSide =>
      ((widget.fields[_audienceOf] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// The exact shape wa_audience_save() expects. Rows go out as the form holds
  /// them — an unfinished rule is sent unfinished, and the backend says so,
  /// rather than being silently dropped by a rule this file invented.
  Map<String, dynamic> buildFilters() => {
        'match': _match,
        'rules': [
          for (final r in _rules)
            {
              'field': r.field,
              'op': r.op,
              'value': r.valueCtrl.text.trim(),
            },
        ],
      };

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final res = await (widget.saveRpc ?? waAudienceSave)({
        'p_id': widget.segment?['id'],
        'p_key': _keyCtrl.text.trim(),
        'p_name': _nameCtrl.text.trim(),
        'p_filters': buildFilters(),
        'p_audience_of': _audienceOf,
        'p_description': _descCtrl.text.trim(),
      });
      if (!mounted) return;
      setState(() => _saving = false);
      final err = waPayloadError(res);
      if (err != null) {
        showToast(context, err, isError: true);
        return;
      }
      // summary is the backend's "N contact(s) match this segment right now".
      showToast(context, (res['summary'] ?? '').toString());
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sides = widget.fields.keys.toList();
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kCard,
        elevation: 0,
        foregroundColor: _kText,
        title: Text(
          widget.segment == null ? 'New segment' : 'Edit segment',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1, color: _kBorder),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
        children: [
          _card('Name', [
            TextField(controller: _nameCtrl, decoration: _dec('Segment name')),
            const SizedBox(height: 8),
            TextField(controller: _keyCtrl, decoration: _dec('Key')),
            const SizedBox(height: 8),
            TextField(controller: _descCtrl, decoration: _dec('Description')),
          ]),
          _card('Audience', [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final side in sides)
                  ChoiceChip(
                    label: Text(
                      widget.ofLabel?.call(side) ?? side,
                      style: const TextStyle(fontSize: 12),
                    ),
                    selected: _audienceOf == side,
                    onSelected: (_) => setState(() {
                      _audienceOf = side;
                      // The other side's fields do not exist here, so a rule
                      // pointing at one is no longer answerable. Clear the
                      // field, keep the row and its value.
                      for (final r in _rules) {
                        r.field = null;
                      }
                    }),
                    selectedColor: const Color(0xFFD1FAE5),
                    backgroundColor: const Color(0xFFF9FAFB),
                    side: const BorderSide(color: _kBorder),
                  ),
              ],
            ),
          ]),
          _card('Match', [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in widget.matchModes.whereType<Map>())
                  ChoiceChip(
                    label: Text((m['label'] ?? '').toString(),
                        style: const TextStyle(fontSize: 12)),
                    selected: _match == (m['value'] ?? '').toString(),
                    onSelected: (_) =>
                        setState(() => _match = (m['value'] ?? '').toString()),
                    selectedColor: const Color(0xFFD1FAE5),
                    backgroundColor: const Color(0xFFF9FAFB),
                    side: const BorderSide(color: _kBorder),
                  ),
              ],
            ),
          ]),
          _card('Rules', [
            for (var i = 0; i < _rules.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ruleRow(i),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _rules.add(_RuleRow())),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add rule', style: TextStyle(fontSize: 13)),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(Colors.white)))
                  : const Icon(Icons.save_outlined, size: 17),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ruleRow(int i) {
    final row = _rules[i];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: row.field,
            isExpanded: true,
            decoration: _dec('Field'),
            items: [
              for (final f in _fieldsForSide)
                DropdownMenuItem(
                  value: (f['value'] ?? '').toString(),
                  child: Text((f['label'] ?? '').toString(),
                      style: const TextStyle(fontSize: 13)),
                ),
            ],
            onChanged: (v) => setState(() => row.field = v),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: row.op,
            isExpanded: true,
            decoration: _dec('Operator'),
            items: [
              for (final o in widget.operators.whereType<Map>())
                DropdownMenuItem(
                  value: (o['value'] ?? '').toString(),
                  child: Text((o['label'] ?? '').toString(),
                      style: const TextStyle(fontSize: 13)),
                ),
            ],
            onChanged: (v) => setState(() => row.op = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                    controller: row.valueCtrl, decoration: _dec('Value')),
              ),
              IconButton(
                onPressed: () => setState(() => _rules.removeAt(i)),
                icon: const Icon(Icons.close, size: 18, color: _kMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _card(String title, List<Widget> children) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kCard,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );

  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      );
}

class _RuleRow {
  String? field;
  String? op;
  final TextEditingController valueCtrl = TextEditingController();
}
