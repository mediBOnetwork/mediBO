// CHANGE #400 (1/3) — the partner manages its OWN counting and packing workers.
//
// The worker role already existed (voice counting); what was missing was anyone
// to attribute a count TO. This screen adds and removes a zone's workers and
// marks today's attendance, so every voice count and pack action carries a
// named person.
//
// Everything here is the backend's: partner_workers_console() sends the role
// options, the attendance options, each row's status label and its tone. The
// screen picks none of them — a new attendance state is one row in
// partner_ops_label plus one entry in the RPC's option list, never a deploy.
//
// CHANGE #707 added the productivity columns. Every cell in them — the
// items/hour, the variance percentage, the '—' that means "nothing measured
// yet" — arrives as a FINISHED string on the row's `productivity` block, and
// the four headings arrive once on the payload. This file divides nothing,
// rounds nothing and appends no '%'; a worker with no closed task shows the
// backend's dash rather than a zero this screen invented.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'partner_ui.dart';

class PartnerWorkersScreen extends StatefulWidget {
  const PartnerWorkersScreen({super.key});

  @override
  State<PartnerWorkersScreen> createState() => _PartnerWorkersScreenState();
}

class _PartnerWorkersScreenState extends State<PartnerWorkersScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('partner_workers_console');
      final map = Map<String, dynamic>.from(res as Map);
      RenderLog.write('c400_workers',
          'ok=${map['ok']} rows=${(map['rows'] as List?)?.length ?? 0} '
          'write=${map['can_write']}');
      if (!mounted) return;
      setState(() { _d = map; _loading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// Every write: call, print the backend's own message with the backend's own
  /// tone, reload. The screen never decides what happened.
  Future<void> _call(String fn, Map<String, dynamic> params) async {
    try {
      final res = await Supabase.instance.client.rpc(fn, params: params);
      final map = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      final msg = (map['message'] as String?) ?? '';
      if (msg.isNotEmpty) showToast(context, msg, isError: map['ok'] != true);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _addSheet() async {
    final d = _d;
    if (d == null) return;
    final idCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final roles = (d['role_options'] as List? ?? const []);
    // Default to the backend's FIRST option rather than a word chosen here.
    String role = roles.isEmpty
        ? ''
        : ((roles.first as Map)['value'] ?? '').toString();

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: Ds.space.x16,
            right: Ds.space.x16,
            top: Ds.space.x24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text((d['add_label'] as String?) ?? '', style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x16),
              TextField(
                controller: idCtrl,
                autofocus: true,
                decoration: InputDecoration(
                    hintText: (d['identity_hint'] as String?) ?? ''),
              ),
              SizedBox(height: Ds.space.x12),
              TextField(
                controller: nameCtrl,
                decoration: InputDecoration(
                    hintText: (d['name_hint'] as String?) ?? ''),
              ),
              if (roles.isNotEmpty) ...[
                SizedBox(height: Ds.space.x16),
                Text((d['role_label'] as String?) ?? '', style: Ds.t.caption),
                SizedBox(height: Ds.space.x8),
                Wrap(
                  spacing: Ds.space.x8,
                  runSpacing: Ds.space.x8,
                  children: [
                    for (final o in roles)
                      ChoiceChip(
                        label: Text(((o as Map)['label'] ?? '').toString()),
                        selected: role == (o['value'] ?? '').toString(),
                        onSelected: (_) => setSheet(
                            () => role = (o['value'] ?? '').toString()),
                      ),
                  ],
                ),
              ],
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text((d['add_label'] as String?) ?? ''),
                ),
              ),
              SizedBox(height: Ds.space.x8),
              SizedBox(
                height: Ds.touch.minTarget,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(c('partner.cancel_label')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    await _call('partner_worker_add', {
      'p_identity': idCtrl.text.trim(),
      'p_name': nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
      'p_role': role.isEmpty ? null : role,
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return ColoredBox(
      color: Ds.c.bg,
      child: _loading
          ? const PartnerSkeleton()
          : (d == null || d['ok'] != true)
              ? PartnerNotice(
                  title: (d?['message'] as String?) == null
                      ? c('partner.error_title')
                      : '',
                  text: (d?['message'] as String?) ??
                      c('partner.error_message'),
                  onRetry: _load,
                  retryLabel: c('partner.retry_label'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: PartnerWorkersView(
                    payload: d,
                    onAdd: d['can_write'] == true ? _addSheet : null,
                    onRemove: (id) =>
                        _call('partner_worker_remove', {'p_id': id}),
                    onShift: (id, status) => _call('partner_worker_shift_set',
                        {'p_worker_id': id, 'p_status': status}),
                  ),
                ),
    );
  }
}

/// The rendered worker list, split from the screen so a protected test can pump
/// a payload with no Supabase, no network and no timers.
///
/// It computes nothing. The attendance options come from the payload, each
/// row's status label and tone come from the payload, and a role the payload
/// did not send simply cannot be chosen.
class PartnerWorkersView extends StatelessWidget {
  const PartnerWorkersView({
    super.key,
    required this.payload,
    required this.onRemove,
    required this.onShift,
    this.onAdd,
  });

  /// Null when the backend said can_write:false — the button is then absent,
  /// not merely disabled.
  final VoidCallback? onAdd;

  final Map<String, dynamic> payload;
  final void Function(Object id) onRemove;
  final void Function(Object id, String status) onShift;

  @override
  Widget build(BuildContext context) {
    final d = payload;
    final rows = (d['rows'] as List? ?? const []);
    final shiftOptions = (d['shift_options'] as List? ?? const []);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text((d['intro'] as String?) ?? '', style: Ds.t.caption),
        if (onAdd != null) ...[
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: Text((d['add_label'] as String?) ?? ''),
            ),
          ),
        ],
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty)
          PartnerNotice(title: '', text: (d['empty_text'] as String?) ?? '')
        else ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                  child: Text((d['shift_title'] as String?) ?? '',
                      style: Ds.t.subtitle)),
              Text((d['today_label'] as String?) ?? '', style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text((d['shift_hint'] as String?) ?? '', style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          for (final r in rows) ...[
            PartnerCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(((r as Map)['name'] ?? '').toString(),
                                style: Ds.t.body),
                            SizedBox(height: Ds.space.x4),
                            Text(
                                '${(r['identity'] ?? '')} · ${(r['role_label'] ?? '')}',
                                style: Ds.t.caption),
                          ],
                        ),
                      ),
                      PartnerChip(
                        text: (r['shift_label'] ?? '').toString(),
                        tone: (r['shift_tone'] ?? '').toString(),
                      ),
                    ],
                  ),
                  // CHANGE #707 — today's numbers for this worker. The block
                  // is ABSENT (not zeroed) on a payload that never sent one,
                  // so an older backend simply draws the card it always drew.
                  if (r['productivity'] is Map) ...[
                    SizedBox(height: Ds.space.x12),
                    _ProductivityRow(
                      prod: Map<String, dynamic>.from(
                          r['productivity'] as Map),
                      tasksLabel: (d['prod_tasks_label'] as String?) ?? '',
                      itemsLabel: (d['prod_items_label'] as String?) ?? '',
                      varianceLabel:
                          (d['prod_variance_label'] as String?) ?? '',
                      packErrLabel: (d['prod_packerr_label'] as String?) ?? '',
                    ),
                  ],
                  if (onAdd != null) ...[
                    SizedBox(height: Ds.space.x12),
                    Wrap(
                      spacing: Ds.space.x8,
                      runSpacing: Ds.space.x8,
                      children: [
                        for (final o in shiftOptions)
                          ChoiceChip(
                            label: Text(((o as Map)['label'] ?? '').toString()),
                            selected:
                                (r['shift'] ?? '') == (o['value'] ?? ''),
                            onSelected: (_) => onShift(
                                r['id'] as Object, (o['value'] ?? '').toString()),
                          ),
                        TextButton(
                          onPressed: () => onRemove(r['id'] as Object),
                          child: Text((d['remove_label'] as String?) ?? ''),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(height: Ds.space.x12),
          ],
        ],
      ],
    );
  }
}

/// The four productivity cells, in the order the spec names them: tasks done,
/// items per hour, count-variance rate, pack errors.
///
/// It is a [Wrap] rather than a fixed four-column [Row] on purpose — the same
/// card is read at 360 px and at 1280 px, and four cells that must share one
/// line would squash the labels on a phone. Each cell keeps its label above its
/// value so the pairing survives the reflow.
class _ProductivityRow extends StatelessWidget {
  const _ProductivityRow({
    required this.prod,
    required this.tasksLabel,
    required this.itemsLabel,
    required this.varianceLabel,
    required this.packErrLabel,
  });

  final Map<String, dynamic> prod;
  final String tasksLabel;
  final String itemsLabel;
  final String varianceLabel;
  final String packErrLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Ds.space.x24,
          runSpacing: Ds.space.x12,
          children: [
            _Cell(label: tasksLabel, value: (prod['tasks_done'] ?? '').toString()),
            _Cell(
                label: itemsLabel,
                value: (prod['items_per_hour'] ?? '').toString()),
            _Cell(
                label: varianceLabel,
                value: (prod['variance_rate'] ?? '').toString()),
            _Cell(
                label: packErrLabel,
                value: (prod['pack_errors_label'] ?? '').toString()),
          ],
        ),
        // The open-task count is the backend's own sentence ("3 open"), never
        // a number this file pluralises.
        if ((prod['open_label'] ?? '').toString().isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text((prod['open_label'] ?? '').toString(), style: Ds.t.caption),
        ],
      ],
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Text(value, style: Ds.t.bodyStrong),
      ],
    );
  }
}
