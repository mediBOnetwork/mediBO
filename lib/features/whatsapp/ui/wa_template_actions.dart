import 'package:flutter/material.dart';

import 'package:pharma_b2b/utils/toast.dart';
import '../data/wa_template_api.dart';
import 'wa_template_bits.dart';
import 'wa_template_editor_screen.dart';

/// Part C actions: submit, test send, clone, delete, versions.
///
/// Every message shown here is either backend copy (app_settings) or the
/// backend's / Meta's own error text, printed verbatim. Nothing is reworded,
/// and no client-side rule decides whether an action is allowed — the card only
/// offers an action when its own `can_*` flag came back true.

// ── submit ───────────────────────────────────────────────────────────────────

Future<void> waSubmitTemplate(
  BuildContext context,
  Map<String, dynamic> template,
  WaCopy copy,
  VoidCallback onChanged,
) async {
  final id = (template['id'] ?? '').toString();
  try {
    final res = await WaTemplateApi.submit(id);
    if (!context.mounted) return;
    if (res['status'] == 'ok') {
      showToast(context, copy['submit_ok']);
      onChanged();
      return;
    }
    // Meta's own wording — never reworded.
    final meta = (res['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final title = (meta['title'] ?? '').toString();
    final message = (meta['message'] ?? '').toString();
    final shown = [title, message].where((s) => s.isNotEmpty).join(' — ');
    showToast(context, shown.isEmpty ? copy['generic_error'] : shown,
        isError: true);
  } catch (_) {
    if (context.mounted) {
      showToast(context, copy['generic_error'], isError: true);
    }
  }
}

// ── why Submit is off ────────────────────────────────────────────────────────

/// Opened by tapping the disabled Submit button.
///
/// Answers the question a greyed-out button cannot: what is stopping this, and
/// what do I do about it. Every line is wa_template_submit_blockers' own
/// wording — the sheet adds no heading and no summary of its own, so there is
/// nothing here that can disagree with the button's state.
///
/// [gate] is wa_template_submit_blockers, [similar] is wa_template_similar.
/// Either may be null (never asked, or the RPC refused), in which case that
/// part is simply absent rather than replaced with an invented explanation.
Future<void> waSubmitBlockersSheet(
  BuildContext context,
  Map<String, dynamic>? gate,
  Map<String, dynamic>? similar,
) async {
  final why = (gate?['why_label'] ?? '').toString();
  final blockers = (gate?['blockers'] as List?) ?? const [];
  // Warnings are listed apart from the blockers because they do NOT block:
  // Meta approves templates that carry them.
  final warnings = [
    for (final w in (gate?['warnings'] as List?) ?? const [])
      if (w.toString().isNotEmpty) w.toString(),
  ];
  final dupBlocking = similar?['blocking'] == true;
  final dupSummary = (similar?['summary'] ?? '').toString();
  final dupRows = (similar?['rows'] as List?) ?? const [];

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (why.isNotEmpty) ...[
              Text(
                why,
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827)),
              ),
              const SizedBox(height: 16),
            ],
            if (blockers.isNotEmpty) WaIssueList(issues: blockers),
            if (dupBlocking && dupSummary.isNotEmpty) ...[
              WaBanner(body: dupSummary, tone: similar?['tone']),
              if (dupRows.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in dupRows)
                      if (r is Map)
                        WaChip(
                            label: (r['label'] ?? '').toString(),
                            tone: r['tone']),
                  ],
                ),
              ],
              const SizedBox(height: 12),
            ],
            if (warnings.isNotEmpty)
              WaBanner(tone: 'warn', lines: warnings),
          ],
        ),
      ),
    ),
  );
}

// ── test send ────────────────────────────────────────────────────────────────

Future<void> waTestSendDialog(
  BuildContext context,
  Map<String, dynamic> template,
  WaCopy copy,
  Map<String, dynamic> screen,
) async {
  final cfg =
      (screen['test_send'] as Map?)?.cast<String, dynamic>() ?? const {};
  final preview =
      (template['preview'] as Map?)?.cast<String, dynamic>() ?? const {};
  // The example values the template already carries — prefilled, still editable.
  final used = (preview['used_values'] as List?) ?? const [];

  final to = TextEditingController(text: (cfg['default_to'] ?? '').toString());
  final vars = [
    for (final v in used) TextEditingController(text: v.toString()),
  ];

  await showDialog<void>(
    context: context,
    builder: (ctx) => _BusyDialog(
      title: (cfg['title'] ?? '').toString(),
      note: (cfg['note'] ?? '').toString(),
      actionLabel: (cfg['send_label'] ?? '').toString(),
      cancelLabel: copy['cancel'],
      fields: [
        _DialogField(label: (cfg['field_label'] ?? '').toString(), controller: to),
        if (vars.isNotEmpty) ...[
          _DialogLabel((cfg['values_title'] ?? '').toString()),
          for (var i = 0; i < vars.length; i++)
            _DialogField(label: '{{${i + 1}}}', controller: vars[i]),
        ],
      ],
      onAction: () async {
        final res = await WaTemplateApi.testSend(
          to: to.text,
          templateName: (template['name'] ?? '').toString(),
          language: (template['language'] ?? '').toString(),
          variables: vars.map((c) => c.text).toList(),
        );
        if (res['status'] == 'ok') {
          return _Outcome.ok(
              '${(cfg['sent_prefix'] ?? '').toString()}${(res['wamid'] ?? '').toString()}');
        }
        // Backend / Meta detail, verbatim.
        final detail = (res['error'] ?? res['message'] ?? '').toString();
        return _Outcome.fail(detail.isEmpty ? copy['generic_error'] : detail);
      },
    ),
  );

  to.dispose();
  for (final c in vars) {
    c.dispose();
  }
}

// ── clone ────────────────────────────────────────────────────────────────────

Future<void> waCloneDialog(
  BuildContext context,
  Map<String, dynamic> template,
  WaCopy copy,
  Map<String, dynamic> screen,
  VoidCallback onChanged,
) async {
  final own = (template['language'] ?? '').toString();
  // The template's own language is not a clone target.
  final langs = [
    for (final l in (screen['languages'] as List?) ?? const [])
      if (l is Map && (l['key'] ?? '').toString() != own) l,
  ];
  if (langs.isEmpty) return;

  var picked = (langs.first['key'] ?? '').toString();
  Map<String, dynamic>? created;
  String note = '';

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => _BusyDialog(
        title: copy['clone_title'],
        actionLabel: copy['clone_action'],
        cancelLabel: copy['cancel'],
        fields: [
          _DialogLabel(copy['clone_language_label']),
          DropdownButtonFormField<String>(
            initialValue: picked,
            decoration: const InputDecoration(isDense: true),
            items: [
              for (final l in langs)
                DropdownMenuItem(
                  value: (l['key'] ?? '').toString(),
                  child: Text((l['label'] ?? '').toString()),
                ),
            ],
            onChanged: (v) => setLocal(() => picked = v ?? picked),
          ),
        ],
        onAction: () async {
          final res = await WaTemplateApi.clone(
              (template['id'] ?? '').toString(), picked);
          if (res['ok'] == true) {
            created = (res['template'] as Map?)?.cast<String, dynamic>();
            note = (res['note'] ?? '').toString();
            return _Outcome.ok(note);
          }
          final msg = (res['message'] ?? '').toString();
          return _Outcome.fail(msg.isEmpty ? copy['generic_error'] : msg);
        },
      ),
    ),
  );

  if (created == null || !context.mounted) return;
  onChanged();
  // Open the new draft so the admin can translate it straight away.
  final changed = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => WaTemplateEditorScreen(screen: screen, template: created),
    ),
  );
  if (changed == true) onChanged();
}

// ── delete ───────────────────────────────────────────────────────────────────

Future<void> waDeleteDialog(
  BuildContext context,
  Map<String, dynamic> template,
  WaCopy copy,
  VoidCallback onChanged,
) async {
  final name = (template['name'] ?? '').toString();
  await showDialog<void>(
    context: context,
    builder: (ctx) => _BusyDialog(
      title: copy['delete_title'],
      // The backend's sentence already says this also deletes at Meta and
      // cannot be undone.
      note: copy.sub('delete_confirm', {'name': name}),
      actionLabel: copy['delete_action'],
      cancelLabel: copy['cancel'],
      danger: true,
      fields: const [],
      onAction: () async {
        final res =
            await WaTemplateApi.deleteRemote((template['id'] ?? '').toString());
        if (res['status'] == 'ok') return _Outcome.ok(copy['delete_ok']);
        // Includes {error:'delete_at_meta', message} from the RPC path.
        final msg = (res['message'] ?? res['error'] ?? '').toString();
        return _Outcome.fail(msg.isEmpty ? copy['generic_error'] : msg);
      },
    ),
  );
  if (context.mounted) onChanged();
}

// ── versions ─────────────────────────────────────────────────────────────────

/// Lists versions[] in PAYLOAD ORDER — wa_templates_screen already sorts them
/// newest first, so re-sorting here could only introduce a disagreement.
Future<void> waVersionsSheet(
  BuildContext context,
  Map<String, dynamic> template,
  WaCopy copy,
  void Function(List<dynamic> components) onRestore,
) async {
  final versions = (template['versions'] as List?) ?? const [];
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              copy['versions_title'],
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827)),
            ),
          ),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: versions.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: Color(0xFFE5E7EB)),
              itemBuilder: (_, i) {
                final v = versions[i];
                if (v is! Map) return const SizedBox.shrink();
                return ListTile(
                  title: Text(
                    'v${(v['version'] ?? '').toString()} · '
                    '${(v['action'] ?? '').toString()}',
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827)),
                  ),
                  subtitle: Text(
                    (v['at'] ?? '').toString(),
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF6B7280)),
                  ),
                  trailing: TextButton(
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      onRestore((v['components'] as List?) ?? const []);
                    },
                    style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF1B7A43)),
                    child: Text(copy['restore']),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

// ── shared dialog ────────────────────────────────────────────────────────────

class _Outcome {
  final bool ok;
  final String message;
  const _Outcome.ok(this.message) : ok = true;
  const _Outcome.fail(this.message) : ok = false;
}

class _DialogLabel extends StatelessWidget {
  final String text;
  const _DialogLabel(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6B7280))),
      );
}

class _DialogField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  const _DialogField({required this.label, required this.controller});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: TextField(
          controller: controller,
          style: const TextStyle(fontSize: 15),
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );
}

/// A dialog whose action runs an async call, shows a spinner, then reports the
/// backend's own message.
class _BusyDialog extends StatefulWidget {
  final String title;
  final String? note;
  final String actionLabel;
  final String cancelLabel;
  final List<Widget> fields;
  final Future<_Outcome> Function() onAction;
  final bool danger;

  const _BusyDialog({
    required this.title,
    required this.actionLabel,
    required this.cancelLabel,
    required this.fields,
    required this.onAction,
    this.note,
    this.danger = false,
  });

  @override
  State<_BusyDialog> createState() => _BusyDialogState();
}

class _BusyDialogState extends State<_BusyDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _run() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final out = await widget.onAction();
      if (!mounted) return;
      if (out.ok) {
        Navigator.of(context).pop();
        if (out.message.isNotEmpty) showToast(context, out.message);
      } else {
        setState(() {
          _busy = false;
          _error = out.message;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: Colors.white,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text(widget.title,
            style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827))),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if ((widget.note ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(widget.note!,
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFF6B7280))),
                ),
              ...widget.fields,
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: WaBanner(body: _error, tone: 'red'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            style:
                TextButton.styleFrom(foregroundColor: const Color(0xFF6B7280)),
            child: Text(widget.cancelLabel),
          ),
          ElevatedButton(
            onPressed: _busy ? null : _run,
            style: ElevatedButton.styleFrom(
              backgroundColor: widget.danger
                  ? const Color(0xFF991B1B)
                  : const Color(0xFF1B7A43),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Text(widget.actionLabel),
          ),
        ],
      );
}
