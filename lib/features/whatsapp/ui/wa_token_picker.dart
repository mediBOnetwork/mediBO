import 'dart:async';

import 'package:flutter/material.dart';

import '../data/wa_template_api.dart';
import 'wa_template_bits.dart';

/// The searchable, editable list of values an admin can drop into a template.
///
/// This replaces the fixed nine-value list wa_template_tokens() returned. That
/// list could not grow, so a value it did not carry (a delivery person's name)
/// simply could not be inserted — and typing a bare {{2}} instead sent the
/// customer a message that literally read "{{2}}". Everything shown here comes
/// from wa_tokens_screen(): the labels, the examples, the group headings, the
/// coverage warnings and the insert text itself.
///
/// Nothing in this file decides anything about a value. It does not build a
/// placeholder, it does not pick a number, it does not judge whether a field
/// name is real (wa_token_save says so), and it does not word the coverage
/// warning (that is `coverage_label`).
///
/// A row's `insert_as` is never read. It carried a NAMED placeholder
/// ({{customer_name}}), and Meta accepts numbered variables only — a named one
/// went out to the pharmacy as those literal characters. The picker now reports
/// the KEY alone and wa_body_insert_token decides where the text goes and what
/// number it gets.
class WaTokenPicker extends StatefulWidget {
  /// The KEY of the value the admin picked — never a placeholder, never a
  /// number. The editor hands it to wa_body_insert_token, which is what turns
  /// it into {{n}} at the caret. The picker never touches the body controller.
  final void Function(String key) onInsert;

  const WaTokenPicker({super.key, required this.onInsert});

  /// Debounce before a search round-trip. Test seam.
  @visibleForTesting
  static Duration searchDebounce = const Duration(milliseconds: 300);

  /// AI lookup poll cadence and ceiling. Test seams.
  @visibleForTesting
  static Duration pollInterval = const Duration(seconds: 2);
  @visibleForTesting
  static Duration pollTimeout = const Duration(seconds: 30);

  @override
  State<WaTokenPicker> createState() => _WaTokenPickerState();
}

class _WaTokenPickerState extends State<WaTokenPicker> {
  final _search = TextEditingController();
  Timer? _debounce;

  Map<String, dynamic> _payload = const {};
  List<dynamic> _rows = const [];

  bool _loading = true;
  String _error = '';

  /// A backend message to show above the list — a delete refusal, a save
  /// warning. Always the backend's own words, never assembled here.
  Map<String, dynamic>? _notice;

  bool _aiBusy = false;
  Map<String, dynamic>? _aiResult;
  String _aiStatus = '';

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  // ── payload accessors ──────────────────────────────────────────────────────

  String get _sampleFrom => (_payload['sample_from'] ?? '').toString();
  String get _emptyCopy => (_payload['empty_copy'] ?? '').toString();
  List<dynamic> get _sourceKinds =>
      (_payload['source_kinds'] as List?) ?? const [];
  List<dynamic> get _formats => (_payload['formats'] as List?) ?? const [];

  bool get _searching => _search.text.trim().isNotEmpty;

  // ── load / search ──────────────────────────────────────────────────────────

  Future<void> _load(String? search) async {
    if (mounted) setState(() => _loading = true);
    try {
      final res = await WaTemplateApi.tokensScreen(search);
      if (!mounted) return;
      if ((res['error'] ?? '').toString().isNotEmpty) {
        setState(() {
          _error = (res['message'] ?? res['error']).toString();
          _loading = false;
        });
        return;
      }
      setState(() {
        _payload = res;
        _rows = (res['rows'] as List?) ?? const [];
        _error = '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Re-reads the full list after a create / edit / toggle / delete so the
  /// chips never lag behind the backend.
  Future<void> _reloadAll() async {
    final res = await WaTemplateApi.tokensScreen(null);
    if (!mounted) return;
    final rows = (res['rows'] as List?) ?? const [];
    setState(() {
      if (!_searching) {
        _payload = res;
        _rows = rows;
      }
    });
    if (_searching) await _load(_search.text.trim());
  }

  void _onSearchChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(WaTokenPicker.searchDebounce, () {
      final q = _search.text.trim();
      setState(() {
        _aiResult = null;
        _aiStatus = '';
      });
      _load(q.isEmpty ? null : q);
    });
  }

  // ── AI lookup ──────────────────────────────────────────────────────────────

  Future<void> _askAi() async {
    final query = _search.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _aiBusy = true;
      _aiResult = null;
      _aiStatus = '';
      _notice = null;
    });
    try {
      final start = await WaTemplateApi.tokenAiSearch(query);
      if (!mounted) return;
      if ((start['error'] ?? '').toString().isNotEmpty) {
        setState(() {
          _aiBusy = false;
          _aiStatus = (start['message'] ?? start['error']).toString();
        });
        return;
      }
      final jobId = (start['job_id'] ?? '').toString();

      final deadline = DateTime.now().add(WaTokenPicker.pollTimeout);
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(WaTokenPicker.pollInterval);
        if (!mounted) return;
        final r = await WaTemplateApi.tokenSearchResult(jobId);
        if (!mounted) return;

        if ((r['error'] ?? '').toString().isNotEmpty) {
          setState(() {
            _aiBusy = false;
            _aiStatus = (r['error']).toString();
          });
          return;
        }
        final result = r['result'];
        if (result is Map) {
          setState(() {
            _aiBusy = false;
            _aiResult = result.cast<String, dynamic>();
            _aiStatus = (r['status_label'] ?? '').toString();
          });
          return;
        }
        // Still running — show the backend's own word for the state.
        setState(() => _aiStatus = (r['status_label'] ?? '').toString());
      }
      if (mounted) setState(() => _aiBusy = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _aiBusy = false;
          _aiStatus = e.toString();
        });
      }
    }
  }

  /// Reports an AI match by key. Whether that key still names a real value is
  /// wa_body_insert_token's call — it refuses an unknown one with its own
  /// message — so nothing is filtered out here.
  void _insertByKey(String key) {
    if (key.isEmpty) return;
    widget.onInsert(key);
  }

  Future<void> _createFromProposal(Map<String, dynamic> p) async {
    final res = await WaTemplateApi.tokenSave(
      key: (p['key'] ?? '').toString(),
      label: (p['label'] ?? '').toString(),
      sourceKind: (p['source_kind'] ?? '').toString(),
      sourceRef: p['source_ref']?.toString(),
      group: p['group_label']?.toString(),
      format: p['format']?.toString(),
      fallback: p['fallback']?.toString(),
      example: p['example']?.toString(),
    );
    if (!mounted) return;

    if (res['ok'] != true) {
      // Nothing is inserted on a refusal — the value does not exist.
      setState(() => _notice = {
            'tone': 'bad',
            'lines': [(res['message'] ?? res['error'] ?? '').toString()],
          });
      return;
    }

    widget.onInsert((res['key'] ?? p['key'] ?? '').toString());

    final warning = (res['warning'] ?? '').toString();
    if (warning.isNotEmpty) {
      setState(() => _notice = {
            'tone': 'warn',
            'lines': [warning],
          });
    }
    await _reloadAll();
  }

  // ── row actions ────────────────────────────────────────────────────────────

  Future<void> _toggle(Map<String, dynamic> row) async {
    final res = await WaTemplateApi.tokenToggle(
      (row['key'] ?? '').toString(),
      !(row['enabled'] == true),
    );
    if (!mounted) return;
    if ((res['error'] ?? '').toString().isNotEmpty) {
      setState(() => _notice = {
            'tone': 'bad',
            'lines': [(res['message'] ?? res['error']).toString()],
          });
      return;
    }
    await _reloadAll();
  }

  Future<void> _delete(Map<String, dynamic> row) async {
    final res = await WaTemplateApi.tokenDelete((row['key'] ?? '').toString());
    if (!mounted) return;
    if (res['ok'] != true) {
      final templates = (res['templates'] as List?) ?? const [];
      setState(() => _notice = {
            'tone': 'bad',
            'lines': [
              (res['message'] ?? res['error'] ?? '').toString(),
              ...templates.map((t) => t.toString()),
            ],
          });
      return;
    }
    await _reloadAll();
  }

  Future<void> _openForm({Map<String, dynamic>? row}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => WaValueForm(
        row: row,
        sourceKinds: _sourceKinds,
        formats: _formats,
      ),
    );
    if (saved == true) await _reloadAll();
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_sampleFrom.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              _sampleFrom,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ),
        Row(
          children: [
            Expanded(child: _searchField()),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add a value'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1B7A43),
                side: const BorderSide(color: Color(0xFF1B7A43)),
                shape:
                    RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                minimumSize: const Size(0, 44),
              ),
            ),
          ],
        ),
        if (_notice != null) ...[
          const SizedBox(height: 12),
          WaBanner(
            tone: _notice!['tone'],
            lines: (_notice!['lines'] as List).cast<String>(),
            action: TextButton(
              onPressed: () => setState(() => _notice = null),
              child: const Text('Dismiss'),
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (_loading)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              WaSkeleton(height: 16, width: 160),
              SizedBox(height: 8),
              WaSkeleton(height: 40),
            ],
          )
        else if (_error.isNotEmpty)
          WaErrorState(
              message: _error, onRetry: () => _load(null))
        else if (_rows.isEmpty)
          _emptyState()
        else
          ..._groups(),
        if (_aiBusy || _aiResult != null || _aiStatus.isNotEmpty) ...[
          const SizedBox(height: 16),
          _aiPanel(),
        ],
      ],
    );
  }

  Widget _searchField() => TextField(
        controller: _search,
        onChanged: _onSearchChanged,
        style: const TextStyle(fontSize: 15, color: Color(0xFF111827)),
        decoration: InputDecoration(
          hintText: 'Search values',
          hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
          prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
          filled: true,
          fillColor: const Color(0xFFF5F6F8),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF1B7A43)),
          ),
        ),
      );

  Widget _emptyState() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _emptyCopy,
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
          // Offered only once a search has actually come back empty — there is
          // nothing for the AI to look for otherwise.
          if (_searching && !_aiBusy) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _askAi,
                icon: const Icon(Icons.auto_awesome, size: 16),
                label: const Text('Ask AI to find it'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1B7A43),
                  side: const BorderSide(color: Color(0xFF1B7A43)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ),
          ],
        ],
      );

  /// Groups in the order the payload presented them. The backend already
  /// ordered rows by sort_order inside each group, so nothing is sorted here.
  List<Widget> _groups() {
    final order = <String>[];
    final byGroup = <String, List<Map<String, dynamic>>>{};
    for (final r in _rows) {
      if (r is! Map) continue;
      final row = r.cast<String, dynamic>();
      final g = (row['group_label'] ?? '').toString();
      if (!byGroup.containsKey(g)) {
        byGroup[g] = [];
        order.add(g);
      }
      byGroup[g]!.add(row);
    }

    final out = <Widget>[];
    for (final g in order) {
      if (out.isNotEmpty) out.add(const SizedBox(height: 16));
      if (g.isNotEmpty) {
        out.add(Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            g,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827)),
          ),
        ));
      }
      out.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final row in byGroup[g]!)
            _ValueTile(
              row: row,
              onInsert: () => _insertByKey((row['key'] ?? '').toString()),
              onEdit: () => _openForm(row: row),
              onToggle: () => _toggle(row),
              onDelete: () => _delete(row),
            ),
        ],
      ));
    }
    return out;
  }

  Widget _aiPanel() {
    final result = _aiResult;
    final note = (result?['note'] ?? '').toString();
    final matches = (result?['matches'] as List?) ?? const [];
    final proposal = result?['proposal'];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_aiBusy)
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFF1E40AF)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _aiStatus,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF1E40AF)),
                  ),
                ),
              ],
            )
          else if (result == null && _aiStatus.isNotEmpty)
            Text(_aiStatus,
                style: const TextStyle(fontSize: 13, color: Color(0xFF1E40AF))),
          if (note.isNotEmpty) ...[
            Text(note,
                style: const TextStyle(fontSize: 13, color: Color(0xFF1E40AF))),
            const SizedBox(height: 8),
          ],
          for (final m in matches)
            if (m is Map)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  onTap: () => _insertByKey((m['key'] ?? '').toString()),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((m['key'] ?? '').toString(),
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF111827))),
                        Text((m['why'] ?? '').toString(),
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFF6B7280))),
                      ],
                    ),
                  ),
                ),
              ),
          // Only offered when the backend actually proposed a new value.
          if (proposal is Map) _proposalCard(proposal.cast<String, dynamic>()),
        ],
      ),
    );
  }

  Widget _proposalCard(Map<String, dynamic> p) {
    final from = [
      (p['source_kind'] ?? '').toString(),
      (p['source_ref'] ?? '').toString(),
    ].where((s) => s.isNotEmpty).join(' · ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1B7A43)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((p['label'] ?? '').toString(),
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827))),
          if ((p['why'] ?? '').toString().isNotEmpty)
            Text((p['why']).toString(),
                style:
                    const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          if (from.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(from,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280))),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton(
              onPressed: () => _createFromProposal(p),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Create and insert'),
            ),
          ),
        ],
      ),
    );
  }
}

/// One value. Everything on it is a backend string.
class _ValueTile extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onInsert;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _ValueTile({
    required this.row,
    required this.onInsert,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final label = (row['label'] ?? '').toString();
    final example = (row['example'] ?? '').toString();
    final coverageLabel = row['coverage_label'];
    final usedIn = (row['used_in'] as num?)?.toInt() ?? 0;
    final enabled = row['enabled'] == true;
    // can_delete false means the backend owns this value — no Delete offered.
    final canDelete = row['can_delete'] == true;

    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Opacity(
        opacity: enabled ? 1 : 0.5,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: enabled ? onInsert : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF111827))),
                        if (example.isNotEmpty)
                          Text(example,
                              style: const TextStyle(
                                  fontSize: 12, color: Color(0xFF6B7280))),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert,
                      size: 18, color: Color(0xFF6B7280)),
                  onSelected: (v) {
                    if (v == 'edit') onEdit();
                    if (v == 'toggle') onToggle();
                    if (v == 'delete') onDelete();
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(
                      value: 'toggle',
                      child: Text(enabled ? 'Disable' : 'Enable'),
                    ),
                    if (canDelete)
                      const PopupMenuItem(
                          value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            // The coverage warning sits with the chip, BEFORE the admin can
            // insert it — finding out afterwards is what made this a bug.
            if (coverageLabel != null &&
                coverageLabel.toString().isNotEmpty) ...[
              const SizedBox(height: 8),
              WaChip(
                  label: coverageLabel.toString(), tone: row['coverage_tone']),
            ],
            if (usedIn > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('used in $usedIn templates',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280))),
              ),
          ],
        ),
      ),
    );
  }
}

/// Add / edit a value.
///
/// Nothing typed here is checked in Dart. wa_token_save() is what knows whether
/// `source_ref` names a real field, and its `warning` / `resolves` verdict is
/// rendered exactly as it comes back.
class WaValueForm extends StatefulWidget {
  final Map<String, dynamic>? row;
  final List<dynamic> sourceKinds;
  final List<dynamic> formats;

  const WaValueForm({
    super.key,
    this.row,
    required this.sourceKinds,
    required this.formats,
  });

  @override
  State<WaValueForm> createState() => _WaValueFormState();
}

class _WaValueFormState extends State<WaValueForm> {
  final _label = TextEditingController();
  final _key = TextEditingController();
  final _group = TextEditingController();
  final _sourceRef = TextEditingController();
  final _fallback = TextEditingController();
  final _example = TextEditingController();

  String _sourceKind = '';
  String _format = '';
  bool _busy = false;

  /// The backend's verdict on the last save — sample / warning / message.
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    final r = widget.row;
    _label.text = (r?['label'] ?? '').toString();
    _key.text = (r?['key'] ?? '').toString();
    _group.text = (r?['group_label'] ?? '').toString();
    _sourceRef.text = (r?['source_ref'] ?? '').toString();
    _fallback.text = (r?['fallback'] ?? '').toString();
    _example.text = (r?['example'] ?? '').toString();
    _sourceKind = (r?['source_kind'] ?? '').toString();
    _format = (r?['format'] ?? '').toString();
  }

  @override
  void dispose() {
    for (final c in [_label, _key, _group, _sourceRef, _fallback, _example]) {
      c.dispose();
    }
    super.dispose();
  }

  Map<String, dynamic>? get _kindSpec {
    for (final k in widget.sourceKinds) {
      if (k is Map && (k['value'] ?? '').toString() == _sourceKind) {
        return k.cast<String, dynamic>();
      }
    }
    return null;
  }

  /// A kind that lists its options gets a dropdown; one that does not gets a
  /// free text field. The backend decides which by sending `options`.
  List<dynamic> get _refOptions => (_kindSpec?['options'] as List?) ?? const [];

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await WaTemplateApi.tokenSave(
        key: _key.text.trim(),
        label: _label.text,
        sourceKind: _sourceKind,
        sourceRef: _sourceRef.text.trim(),
        group: _group.text,
        format: _format,
        fallback: _fallback.text,
        example: _example.text,
      );
      if (!mounted) return;
      setState(() {
        _result = res;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _result = {'error': 'error', 'message': e.toString()};
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final res = _result;
    final ok = res?['ok'] == true;

    return AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(
        widget.row == null ? 'Add a value' : 'Edit',
        style: const TextStyle(
            fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
      ),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _text('Label', _label),
              const SizedBox(height: 12),
              _text('Key', _key, enabled: widget.row == null),
              const SizedBox(height: 12),
              _text('Group', _group),
              const SizedBox(height: 12),
              _kindDropdown(),
              const SizedBox(height: 12),
              if (_refOptions.isNotEmpty)
                _refDropdown()
              else
                _text('Field', _sourceRef),
              const SizedBox(height: 12),
              _formatDropdown(),
              const SizedBox(height: 12),
              _text('Fallback', _fallback),
              const SizedBox(height: 12),
              _text('Example', _example),
              if (res != null) ...[
                const SizedBox(height: 16),
                if (!ok)
                  WaBanner(
                    tone: 'bad',
                    lines: [(res['message'] ?? res['error'] ?? '').toString()],
                  )
                else ...[
                  if ((res['sample'] ?? '').toString().isNotEmpty)
                    WaBanner(tone: 'good', body: res['sample'].toString()),
                  // resolves:false means the field did not come back with a
                  // value — the warning is the backend's own wording.
                  if (res['resolves'] == false &&
                      (res['warning'] ?? '').toString().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    WaBanner(tone: 'warn', body: res['warning'].toString()),
                  ],
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(ok),
          child: Text(ok ? 'Done' : 'Cancel'),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _save,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF1B7A43),
            foregroundColor: Colors.white,
            elevation: 0,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _text(String label, TextEditingController c, {bool enabled = true}) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6B7280))),
          const SizedBox(height: 6),
          TextField(
            controller: c,
            enabled: enabled,
            style: const TextStyle(fontSize: 15, color: Color(0xFF111827)),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0xFFF5F6F8),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
              ),
            ),
          ),
        ],
      );

  Widget _kindDropdown() {
    final values = [
      for (final k in widget.sourceKinds)
        if (k is Map) (k['value'] ?? '').toString(),
    ];
    return _wrapDropdown(
      'Source',
      DropdownButton<String>(
        value: values.contains(_sourceKind) ? _sourceKind : null,
        isExpanded: true,
        onChanged: (v) => setState(() {
          _sourceKind = v ?? '';
          _sourceRef.text = '';
        }),
        items: [
          for (final k in widget.sourceKinds)
            if (k is Map)
              DropdownMenuItem(
                value: (k['value'] ?? '').toString(),
                child: Text((k['label'] ?? '').toString(),
                    style: const TextStyle(
                        fontSize: 15, color: Color(0xFF111827))),
              ),
        ],
      ),
    );
  }

  Widget _refDropdown() {
    final opts = _refOptions.map((e) => e.toString()).toList();
    return _wrapDropdown(
      'Field',
      DropdownButton<String>(
        value: opts.contains(_sourceRef.text) ? _sourceRef.text : null,
        isExpanded: true,
        onChanged: (v) => setState(() => _sourceRef.text = v ?? ''),
        items: [
          for (final o in opts)
            DropdownMenuItem(
              value: o,
              child: Text(o,
                  style:
                      const TextStyle(fontSize: 15, color: Color(0xFF111827))),
            ),
        ],
      ),
    );
  }

  Widget _formatDropdown() {
    final opts = widget.formats.map((e) => e.toString()).toList();
    return _wrapDropdown(
      'Format',
      DropdownButton<String>(
        value: opts.contains(_format) ? _format : null,
        isExpanded: true,
        onChanged: (v) => setState(() => _format = v ?? ''),
        items: [
          for (final o in opts)
            DropdownMenuItem(
              value: o,
              child: Text(o,
                  style:
                      const TextStyle(fontSize: 15, color: Color(0xFF111827))),
            ),
        ],
      ),
    );
  }

  Widget _wrapDropdown(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6B7280))),
          const SizedBox(height: 6),
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F6F8),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: DropdownButtonHideUnderline(child: child),
          ),
        ],
      );
}

// WaTokenMap used to live here. It scanned the body for each row's `insert_as`
// and rebuilt p_token_map from what it found — the last piece of Dart that
// decided which value fed which variable. wa_body_insert_token and
// wa_body_renumber return the map themselves now, so there is nothing left to
// derive: the editor stores what they hand back and passes it straight to
// wa_template_save.
