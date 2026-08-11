import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// The ONE paste place. Om drops 10–15 specs separated by `---`, tunes the
/// per-add toggles, and submits. Duplicates come back as warnings with an
/// explicit "Add anyway" — the backend decides what is a duplicate, this sheet
/// only renders the verdict.
class DevQueueBulkAdd extends StatefulWidget {
  final DevQueueService service;
  const DevQueueBulkAdd({super.key, required this.service});

  @override
  State<DevQueueBulkAdd> createState() => _DevQueueBulkAddState();
}

class _DevQueueBulkAddState extends State<DevQueueBulkAdd> {
  final _paste = TextEditingController();
  final _batch = TextEditingController();
  List<TextEditingController> _titles = [];
  List<String> _specs = [];

  bool _urgent = false;
  bool _approval = false;
  bool _android = false;
  bool _ios = false;
  bool _busy = false;

  List<Map<String, dynamic>> _templates = const [];
  List<Map<String, dynamic>> _warnings = const [];

  @override
  void initState() {
    super.initState();
    _paste.addListener(_reparse);
    _loadTemplates();
  }

  @override
  void dispose() {
    _paste.dispose();
    _batch.dispose();
    for (final t in _titles) t.dispose();
    super.dispose();
  }

  Future<void> _loadTemplates() async {
    try {
      final t = await widget.service.templates();
      if (mounted) setState(() => _templates = t);
    } catch (_) {}
  }

  List<String> _split(String raw) => raw
      .split(RegExp(r'^\s*---\s*$', multiLine: true))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  String _defaultTitle(String spec) {
    final first = spec
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    return first.length > 80 ? '${first.substring(0, 77)}…' : first;
  }

  void _reparse() {
    final specs = _split(_paste.text);
    if (specs.length != _specs.length) {
      for (final t in _titles) t.dispose();
      _titles =
          specs.map((s) => TextEditingController(text: _defaultTitle(s))).toList();
    }
    setState(() {
      _specs = specs;
      _warnings = const [];
    });
  }

  List<Map<String, dynamic>> _buildItems() {
    return [
      for (var i = 0; i < _specs.length; i++)
        {
          'title': _titles[i].text.trim().isEmpty
              ? _defaultTitle(_specs[i])
              : _titles[i].text.trim(),
          'spec': _specs[i],
          'urgent': _urgent,
          'require_approval': _approval,
          if (_batch.text.trim().isNotEmpty) 'batch_label': _batch.text.trim(),
          'targets_web': true,
          'targets_android': _android,
          'targets_ios': _ios,
        }
    ];
  }

  Future<void> _submit({bool force = false}) async {
    final items = force
        ? _buildItems()
            .where((it) =>
                _warnings.any((w) => w['title'] == it['title']))
            .toList()
        : _buildItems();
    if (items.isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await widget.service.bulkAdd(items, force: force);
      final added = ((res['added'] as List?) ?? const []).length;
      final warnings = ((res['warnings'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      if (warnings.isEmpty || force) {
        if (added > 0 && mounted) showToast(context, '+$added');
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _warnings = warnings;
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showToast(context, e.toString(), isError: true);
      }
    }
  }

  Future<void> _saveTemplate() async {
    if (_paste.text.trim().isEmpty) return;
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(hintText: c('dev_queue.template_save_hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, ctl.text.trim()),
              child: Text(c('dev_queue.btn_save_template'))),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await widget.service.templateSave(name, _paste.text.trim());
      await _loadTemplates();
    } catch (_) {}
  }

  void _insertTemplate(Map<String, dynamic> t) {
    final spec = (t['spec'] ?? t['spec_template'] ?? '').toString();
    if (spec.isEmpty) return;
    final cur = _paste.text.trim();
    _paste.text = cur.isEmpty ? spec : '$cur\n---\n$spec';
  }

  void _mic() {
    if (kIsWeb) {
      showToast(context, c('dev_queue.mic_unsupported'));
      return;
    }
    // Native (Android app) wires the shared VoiceLiveController recorder here.
    showToast(context, c('dev_queue.mic_unsupported'));
  }

  @override
  Widget build(BuildContext context) {
    final n = _specs.length;
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      expand: false,
      builder: (ctx, scroll) => Container(
        decoration: const BoxDecoration(
          color: kPageBg,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(children: [
          _grabber(),
          Expanded(
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                Row(children: [
                  Expanded(
                    child: Text(c('dev_queue.bulk_title'),
                        style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: kTextHi)),
                  ),
                  IconButton(
                    tooltip: c('dev_queue.mic_tooltip'),
                    onPressed: _mic,
                    icon: const Icon(Icons.mic_none, color: kBrand),
                  ),
                ]),
                Text(c('dev_queue.bulk_hint'),
                    style: const TextStyle(fontSize: 12, color: kTextLo)),
                const SizedBox(height: 10),
                _pasteBox(),
                const SizedBox(height: 10),
                _templateRow(),
                const SizedBox(height: 10),
                _toggles(),
                const SizedBox(height: 10),
                _batchField(),
                if (n > 0) ...[
                  const SizedBox(height: 16),
                  Text(n == 1 ? c('dev_queue.bulk_count_one') : '$n',
                      style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: kTextLo)),
                  const SizedBox(height: 8),
                  for (var i = 0; i < n; i++) _titleTile(i),
                ],
                if (_warnings.isNotEmpty) _warningsBox(),
              ],
            ),
          ),
          _submitBar(n),
        ]),
      ),
    );
  }

  Widget _grabber() => Container(
        margin: const EdgeInsets.only(top: 8, bottom: 4),
        width: 40,
        height: 4,
        decoration: BoxDecoration(
            color: kBorder, borderRadius: BorderRadius.circular(2)),
      );

  Widget _pasteBox() => TextField(
        controller: _paste,
        minLines: 6,
        maxLines: 14,
        style: const TextStyle(fontSize: 14, height: 1.4),
        decoration: InputDecoration(
          filled: true,
          fillColor: Colors.white,
          hintText: c('dev_queue.bulk_hint'),
          contentPadding: const EdgeInsets.all(12),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: kBrand),
          ),
        ),
      );

  Widget _templateRow() => Row(children: [
        Expanded(
          child: DropdownButtonFormField<Map<String, dynamic>>(
            isExpanded: true,
            decoration: _fieldDeco(c('dev_queue.template_pick')),
            items: [
              for (final t in _templates)
                DropdownMenuItem(
                  value: t,
                  child: Text((t['name'] ?? '').toString(),
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (t) {
              if (t != null) _insertTemplate(t);
            },
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: _saveTemplate,
          icon: const Icon(Icons.bookmark_add_outlined, size: 16),
          label: Text(c('dev_queue.btn_save_template'),
              style: const TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
              foregroundColor: kBrand, side: const BorderSide(color: kBrand)),
        ),
      ]);

  Widget _toggles() => Wrap(spacing: 8, runSpacing: 8, children: [
        _toggle(c('dev_queue.toggle_web'), true, null), // locked on
        _toggle(c('dev_queue.toggle_urgent'), _urgent,
            (v) => setState(() => _urgent = v)),
        _toggle(c('dev_queue.toggle_approval'), _approval,
            (v) => setState(() => _approval = v)),
        _toggle(c('dev_queue.toggle_android'), _android,
            (v) => setState(() => _android = v)),
        _toggle(c('dev_queue.toggle_ios'), _ios, (v) => setState(() => _ios = v)),
      ]);

  Widget _toggle(String label, bool value, ValueChanged<bool>? onChanged) {
    final locked = onChanged == null;
    return FilterChip(
      label: Text(label),
      selected: value,
      onSelected: locked ? null : (v) => onChanged(v),
      showCheckmark: true,
      disabledColor: const Color(0xFFD1FAE5),
      selectedColor: const Color(0xFFD1FAE5),
      backgroundColor: Colors.white,
      labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: value ? const Color(0xFF065F46) : kTextLo),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: kBorder),
      ),
    );
  }

  Widget _batchField() => TextField(
        controller: _batch,
        style: const TextStyle(fontSize: 14),
        decoration: _fieldDeco(c('dev_queue.label_batch')),
      );

  Widget _titleTile(int i) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kBorder),
        ),
        child: Row(children: [
          Text('${i + 1}',
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _titles[i],
              style: const TextStyle(fontSize: 14, color: kTextHi),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: c('dev_queue.label_title'),
              ),
            ),
          ),
        ]),
      );

  Widget _warningsBox() => Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('dev_queue.dup_warn_title'),
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF92400E))),
          const SizedBox(height: 4),
          Text(c('dev_queue.dup_warn_body'),
              style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
          const SizedBox(height: 8),
          for (final w in _warnings)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                  '• ${w['title']}  →  #${w['duplicate_of']}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _busy ? null : () => _submit(force: true),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF92400E)),
              child: Text(c('dev_queue.btn_add_anyway')),
            ),
          ),
        ]),
      );

  Widget _submitBar(int n) => Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: kBorder)),
        ),
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: FilledButton(
            onPressed: (n == 0 || _busy) ? null : () => _submit(),
            style: FilledButton.styleFrom(
                backgroundColor: kBrand,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text('${c('dev_queue.btn_submit')}${n > 0 ? '  ($n)' : ''}',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
      );

  InputDecoration _fieldDeco(String hint) => InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: kBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: kBrand),
        ),
      );
}
