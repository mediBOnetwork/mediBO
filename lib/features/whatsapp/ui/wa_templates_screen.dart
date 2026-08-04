import 'package:flutter/material.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/utils/toast.dart';
import '../data/wa_template_api.dart';
import 'wa_template_actions.dart';
import 'wa_template_bits.dart';
import 'wa_template_editor_screen.dart';

/// Admin > WhatsApp > Templates. Route: /admin/wa-templates
///
/// ONE RPC (wa_templates_screen) fills this whole screen. Counts, chip labels,
/// chip tones, status labels, rejection help, edit budgets, performance
/// summaries and every button caption arrive render-ready. Nothing on this
/// screen is computed, sorted, filtered or formatted in Dart — the payload
/// arrives in the order it should be drawn and is drawn in that order.

class WaTemplatesScreen extends StatefulWidget {
  const WaTemplatesScreen({super.key});

  @override
  State<WaTemplatesScreen> createState() => _WaTemplatesScreenState();
}

class _WaTemplatesScreenState extends State<WaTemplatesScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _syncing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await WaTemplateApi.screen();
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _error = (res['error'] ?? '').toString();
          _loading = false;
        });
        return;
      }
      setState(() {
        _data = res;
        _error = null;
        _loading = false;
      });
      try {
        RenderLog.write(
            'wa_tpl_rows', ((res['templates'] as List?) ?? const []).length);
        RenderLog.write(
            'wa_tpl_alerts', ((res['alerts'] as List?) ?? const []).length);
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  WaCopy get _copy =>
      WaCopy((_data?['copy'] as Map?)?.cast<String, dynamic>() ?? const {});

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      final res = await WaTemplateApi.sync();
      final n = (res['synced'] ?? 0).toString();
      final ok = res['status'] == 'ok';
      final partial = res['status'] == 'partial';
      if (!mounted) return;
      if (ok || partial) {
        await _load();
        if (!mounted) return;
        showToast(
          context,
          _copy.sub(partial ? 'sync_partial' : 'sync_ok', {'n': n}),
          isError: partial,
        );
      } else {
        showToast(context, _copy['generic_error'], isError: true);
      }
    } catch (_) {
      if (mounted) showToast(context, _copy['generic_error'], isError: true);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _openEditor({
    Map<String, dynamic>? template,
    List<dynamic>? components,
  }) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WaTemplateEditorScreen(
          screen: _data ?? const {},
          template: template,
          initialComponents: components,
        ),
      ),
    );
    if (changed == true && mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _copy;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 20, color: Color(0xFF1B7A43)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          copy['title'],
          style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111827)),
        ),
        actions: [
          if (_data != null)
            TextButton.icon(
              onPressed: _syncing ? null : _sync,
              icon: _syncing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(0xFF1B7A43)),
                    )
                  : const Icon(Icons.sync, size: 18),
              label: Text(copy['sync_now']),
              style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF1B7A43)),
            ),
          const SizedBox(width: 8),
        ],
      ),
      floatingActionButton: _data == null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: const Color(0xFF1B7A43),
              foregroundColor: Colors.white,
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: Text(copy['new_template']),
            ),
      body: _buildBody(copy),
    );
  }

  Widget _buildBody(WaCopy copy) {
    if (_loading) return const _ListSkeleton();
    if (_error != null) {
      return WaErrorState(
        message: copy['load_error'].isEmpty ? _error! : copy['load_error'],
        onRetry: () {
          setState(() {
            _loading = true;
            _error = null;
          });
          _load();
        },
      );
    }

    final data = _data!;
    final templates = (data['templates'] as List?) ?? const [];
    final chips = (data['count_chips'] as List?) ?? const [];
    final alerts = (data['alerts'] as List?) ?? const [];
    final empty = (data['empty'] as Map?)?.cast<String, dynamic>() ?? const {};

    return RefreshIndicator(
      color: const Color(0xFF1B7A43),
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          // ── counts ──────────────────────────────────────────────────────
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in chips)
                if (c is Map)
                  WaChip(
                    label: (c['label'] ?? '').toString(),
                    value: (c['value'] ?? '').toString(),
                    tone: c['tone'],
                  ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            copy['sync_note'],
            style:
                const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),

          // ── alerts ──────────────────────────────────────────────────────
          if (alerts.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(
              copy['alerts_title'],
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 8),
            for (final a in alerts)
              if (a is Map)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _AlertRow(alert: a.cast<String, dynamic>()),
                ),
          ],

          const SizedBox(height: 24),

          // ── templates ───────────────────────────────────────────────────
          if (templates.isEmpty)
            _EmptyState(
              title: (empty['title'] ?? '').toString(),
              note: (empty['note'] ?? '').toString(),
            )
          else
            for (final t in templates)
              if (t is Map)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: WaTemplateCard(
                    template: t.cast<String, dynamic>(),
                    copy: copy,
                    onEdit: (tpl) => _openEditor(template: tpl),
                    onFixResubmit: (tpl) => _openEditor(
                      template: tpl,
                      components: (tpl['components'] as List?) ?? const [],
                    ),
                    onRestoreVersion: (tpl, components) =>
                        _openEditor(template: tpl, components: components),
                    onChanged: _load,
                    screen: _data ?? const {},
                  ),
                ),
        ],
      ),
    );
  }
}

// ── alert row ────────────────────────────────────────────────────────────────

/// One line per alert. Tone and label both come from the payload, so this
/// widget holds no kind -> colour map.
class _AlertRow extends StatelessWidget {
  final Map<String, dynamic> alert;
  const _AlertRow({required this.alert});

  @override
  Widget build(BuildContext context) {
    final tone = WaTone.of(alert['tone']);
    final detail = (alert['detail_label'] ?? '').toString();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: WaDot(tone: alert['tone']),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${(alert['template'] ?? '').toString()} · '
                  '${(alert['label'] ?? '').toString()}',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: tone.fg),
                ),
                if (detail.isNotEmpty)
                  Text(
                    detail,
                    style: TextStyle(fontSize: 13, color: tone.fg),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            (alert['at'] ?? '').toString(),
            style: TextStyle(fontSize: 12, color: tone.fg),
          ),
        ],
      ),
    );
  }
}

// ── template card ────────────────────────────────────────────────────────────

class WaTemplateCard extends StatelessWidget {
  final Map<String, dynamic> template;
  final WaCopy copy;
  final Map<String, dynamic> screen;
  final void Function(Map<String, dynamic> template) onEdit;
  final void Function(Map<String, dynamic> template) onFixResubmit;
  final void Function(Map<String, dynamic> template, List<dynamic> components)
      onRestoreVersion;
  final VoidCallback onChanged;

  const WaTemplateCard({
    super.key,
    required this.template,
    required this.copy,
    required this.screen,
    required this.onEdit,
    required this.onFixResubmit,
    required this.onRestoreVersion,
    required this.onChanged,
  });

  bool _flag(String key) => template[key] == true;

  @override
  Widget build(BuildContext context) {
    final versions = (template['versions'] as List?) ?? const [];
    final performance =
        (template['performance'] as Map?)?.cast<String, dynamic>() ?? const {};
    final rejection =
        (template['rejection_help'] as Map?)?.cast<String, dynamic>();
    final quality = (template['quality_score'] ?? '').toString();
    final bodyPreview = (template['body_preview'] ?? '').toString();
    final summary = (performance['summary'] ?? '').toString();
    final lastUsed = (template['last_used_label'] ?? '').toString();
    final edits = (template['edits_label'] ?? '').toString();
    final lastError = (template['last_error'] ?? '').toString();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // name + chips
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                (template['name'] ?? '').toString(),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827)),
              ),
              WaChip(label: (template['language'] ?? '').toString()),
              WaChip(label: (template['category_label'] ?? '').toString()),
              // status_label + status_tone verbatim. An unknown status is a
              // grey chip carrying whatever label the backend sent.
              WaChip(
                label: (template['status_label'] ?? '').toString(),
                tone: template['status_tone'],
              ),
              if (quality.isNotEmpty) ...[
                WaDot(tone: template['quality_tone']),
                Text(
                  '${copy['quality_label']} $quality',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280)),
                ),
              ],
            ],
          ),

          if (bodyPreview.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              bodyPreview,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 14,
                  height: 1.35,
                  color: Color(0xFF111827)),
            ),
          ],

          // Meta moved the category — cost per message changed.
          if (template['category_changed'] == true) ...[
            const SizedBox(height: 12),
            WaBanner(
              body: (template['category_change_note'] ?? '').toString(),
              tone: 'yellow',
            ),
          ],

          // Rejected: Meta's reason, our fix advice, and a direct way back in.
          if (rejection != null) ...[
            const SizedBox(height: 12),
            WaBanner(
              title: (rejection['title'] ?? '').toString(),
              body: (rejection['fix'] ?? '').toString(),
              tone: 'red',
              action: TextButton(
                onPressed: () => onFixResubmit(template),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF991B1B),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: Text(copy['fix_resubmit']),
              ),
            ),
          ],

          if (lastError.isNotEmpty) ...[
            const SizedBox(height: 12),
            WaBanner(body: lastError, tone: 'red'),
          ],

          // metadata lines
          const SizedBox(height: 12),
          if (summary.isNotEmpty)
            Text(summary,
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF6B7280))),
          Wrap(
            spacing: 12,
            children: [
              if (lastUsed.isNotEmpty)
                Text(lastUsed,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF6B7280))),
              if (edits.isNotEmpty)
                Text(edits,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF6B7280))),
            ],
          ),

          // ── actions: each shown ONLY when its own backend flag is true ──
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_flag('can_edit'))
                _CardAction(
                  label: copy['edit'],
                  icon: Icons.edit_outlined,
                  onTap: () => onEdit(template),
                ),
              if (_flag('can_submit'))
                _CardAction(
                  label: copy['submit'],
                  icon: Icons.send_outlined,
                  primary: true,
                  onTap: () => waSubmitTemplate(
                      context, template, copy, onChanged),
                ),
              if (_flag('can_test_send'))
                _CardAction(
                  label: copy['test_send'],
                  icon: Icons.forum_outlined,
                  onTap: () =>
                      waTestSendDialog(context, template, copy, screen),
                ),
              if (_flag('can_clone'))
                _CardAction(
                  label: copy['clone'],
                  icon: Icons.copy_outlined,
                  onTap: () => waCloneDialog(
                      context, template, copy, screen, onChanged),
                ),
              if (_flag('can_delete'))
                _CardAction(
                  label: copy['delete'],
                  icon: Icons.delete_outline,
                  danger: true,
                  onTap: () =>
                      waDeleteDialog(context, template, copy, onChanged),
                ),
              if (versions.isNotEmpty)
                _CardAction(
                  label: copy['versions'],
                  icon: Icons.history,
                  onTap: () => waVersionsSheet(
                    context,
                    template,
                    copy,
                    (components) => onRestoreVersion(template, components),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool primary;
  final bool danger;

  const _CardAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.primary = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger
        ? const Color(0xFF991B1B)
        : (primary ? Colors.white : const Color(0xFF1B7A43));
    final bg = primary ? const Color(0xFF1B7A43) : Colors.white;
    final border = danger ? const Color(0xFFFECACA) : const Color(0xFF1B7A43);

    return SizedBox(
      height: 40,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 13)),
        style: OutlinedButton.styleFrom(
          foregroundColor: fg,
          backgroundColor: bg,
          side: BorderSide(color: primary ? const Color(0xFF1B7A43) : border),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
      ),
    );
  }
}

// ── empty + skeleton ─────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String title;
  final String note;
  const _EmptyState({required this.title, required this.note});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827)),
            ),
            const SizedBox(height: 8),
            Text(
              note,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
            ),
          ],
        ),
      );
}

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: const [
              WaSkeleton(height: 28, width: 70),
              SizedBox(width: 8),
              WaSkeleton(height: 28, width: 90),
              SizedBox(width: 8),
              WaSkeleton(height: 28, width: 80),
            ],
          ),
          const SizedBox(height: 24),
          for (var i = 0; i < 3; i++)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: const [
                  WaSkeleton(height: 18, width: 160),
                  SizedBox(height: 12),
                  WaSkeleton(),
                  SizedBox(height: 8),
                  WaSkeleton(width: 220),
                  SizedBox(height: 16),
                  WaSkeleton(height: 36, width: 240),
                ],
              ),
            ),
        ],
      );
}
