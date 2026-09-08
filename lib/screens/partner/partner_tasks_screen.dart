// lib/screens/partner/partner_tasks_screen.dart — CHANGE #707
//
// The task board: who owns each fulfilment stage in this zone, right now.
//
// Before this change the pipeline could say WHAT stage an order sat in and,
// afterwards, who had touched each line — but never who was SUPPOSED to do the
// next stage. So a partner could not hand work out, and "this order is late"
// and "nobody picked it up" were indistinguishable.
//
// NOTHING HERE DECIDES ANYTHING. The stage label, the age, the promised time,
// the owner's name, the tone, the quantity sentence and every refusal are
// finished strings from fulfil_task_board(); the worker chips are the ones the
// BACKEND says are on shift, so an absent worker cannot be offered; and
// can_write governs whether the assign affordance exists at all rather than
// whether it is greyed out.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'partner_ui.dart';

/// The sheet returns null when it is dismissed and this sentinel when the
/// partner chose "Unassigned" — two different silences that must not collapse
/// into one.
const Object _clear = Object();

class PartnerTasksScreen extends StatefulWidget {
  const PartnerTasksScreen({super.key});

  @override
  State<PartnerTasksScreen> createState() => _PartnerTasksScreenState();
}

class _PartnerTasksScreenState extends State<PartnerTasksScreen> {
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
      final res = await Supabase.instance.client.rpc('fulfil_task_board');
      final map = Map<String, dynamic>.from(res as Map);
      RenderLog.write(
          'c707_task_board',
          'ok=${map['ok']} rows=${(map['rows'] as List?)?.length ?? 0} '
          'workers=${(map['workers'] as List?)?.length ?? 0} '
          'write=${map['can_write']}');
      if (!mounted) return;
      setState(() {
        _d = map;
        _loading = false;
      });
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

  /// The chip sheet. Its options are the payload's `workers` — a worker the
  /// backend did not send simply cannot be picked, which is how an absent
  /// worker stays unpickable without this file knowing what a shift is.
  Future<void> _assignSheet(Map<String, dynamic> row) async {
    final d = _d;
    if (d == null) return;
    final workers = (d['workers'] as List? ?? const []);
    final task = (row['task'] is Map)
        ? Map<String, dynamic>.from(row['task'] as Map)
        : const <String, dynamic>{};
    final assigned = task['assigned'] == true;
    final picked = await showModalBottomSheet<Object?>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text((d['assign_label'] as String?) ?? '', style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                for (final w in workers)
                  ActionChip(
                    // Padded to the touch minimum: this chip is the whole
                    // gesture of the feature, on a warehouse phone.
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x12, vertical: Ds.space.x8),
                    label: Text(((w as Map)['name'] ?? '').toString()),
                    onPressed: () => Navigator.of(ctx).pop(w['worker_id']),
                  ),
                // Clearing the owner is the same RPC with no worker, and its
                // caption is the payload's own word for "nobody".
                if (assigned)
                  ActionChip(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x12, vertical: Ds.space.x8),
                    label: Text((d['unassigned_label'] as String?) ?? ''),
                    onPressed: () => Navigator.of(ctx).pop(_clear),
                  ),
              ],
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(c('partner.cancel_label')),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _call('fulfil_task_assign', {
      'p_order_id': row['order_id'],
      'p_stage_key': row['stage_key'],
      // `_clear` is this file's way of saying "the sheet was dismissed with
      // Unassign", which is a null worker on the wire — distinct from the null
      // that means "the sheet was dismissed with nothing".
      'p_worker_id': identical(picked, _clear) ? null : picked,
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    // The shell pushes this screen directly (shellExtraRouteScreen, #707), so
    // it owns its own Scaffold rather than borrowing PartnerFeaturePage's —
    // and the AppBar title is the PAYLOAD's, which is why it is empty for the
    // first frame instead of carrying a Dart word that would then be replaced.
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
          title: Text((d?['title'] as String?) ?? '', style: Ds.t.subtitle)),
      body: SafeArea(
        child: _loading
          ? const PartnerSkeleton()
          : (d == null || d['ok'] != true)
              ? PartnerNotice(
                  title: (d?['message'] as String?) == null
                      ? c('partner.error_title')
                      : '',
                  text:
                      (d?['message'] as String?) ?? c('partner.error_message'),
                  onRetry: _load,
                  retryLabel: c('partner.retry_label'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: PartnerTasksView(
                    payload: d,
                    onAssign: d['can_write'] == true ? _assignSheet : null,
                    onAutoAssign: d['can_write'] == true
                        ? () => _call('fulfil_task_auto_assign',
                            <String, dynamic>{})
                        : null,
                  ),
                ),
      ),
    );
  }
}

/// The rendered board, split from the screen so a protected test can pump a
/// payload with no Supabase, no network and no timers.
class PartnerTasksView extends StatelessWidget {
  const PartnerTasksView({
    super.key,
    required this.payload,
    this.onAssign,
    this.onAutoAssign,
  });

  final Map<String, dynamic> payload;

  /// Null when the backend said can_write:false — the affordance is then
  /// ABSENT, not greyed out.
  final void Function(Map<String, dynamic> row)? onAssign;
  final VoidCallback? onAutoAssign;

  @override
  Widget build(BuildContext context) {
    final d = payload;
    final rows = (d['rows'] as List? ?? const []);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text((d['subtitle'] as String?) ?? '', style: Ds.t.caption),
        if (onAutoAssign != null) ...[
          SizedBox(height: Ds.space.x16),
          Row(
            children: [
              Expanded(
                child: Text((d['auto_state_label'] as String?) ?? '',
                    style: Ds.t.caption),
              ),
              SizedBox(width: Ds.space.x8),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: onAutoAssign,
                  child: Text((d['auto_label'] as String?) ?? ''),
                ),
              ),
            ],
          ),
        ],
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty)
          PartnerNotice(title: '', text: (d['empty_label'] as String?) ?? '')
        else
          for (final r in rows) ...[
            _TaskRow(
              row: Map<String, dynamic>.from(r as Map),
              assignLabel: (d['assign_label'] as String?) ?? '',
              reassignLabel: (d['reassign_label'] as String?) ?? '',
              onAssign: onAssign,
            ),
            SizedBox(height: Ds.space.x12),
          ],
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.row,
    required this.assignLabel,
    required this.reassignLabel,
    this.onAssign,
  });

  final Map<String, dynamic> row;
  final String assignLabel;
  final String reassignLabel;
  final void Function(Map<String, dynamic> row)? onAssign;

  @override
  Widget build(BuildContext context) {
    final task = (row['task'] is Map)
        ? Map<String, dynamic>.from(row['task'] as Map)
        : const <String, dynamic>{};
    final assigned = task['assigned'] == true;

    return PartnerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((row['order_code'] ?? '').toString(),
                        style: Ds.t.body),
                    SizedBox(height: Ds.space.x4),
                    Text(
                        '${(row['stage_label'] ?? '')} · ${(row['age_label'] ?? '')}',
                        style: Ds.t.caption),
                  ],
                ),
              ),
              // The owner chip carries the backend's word AND its tone: an
              // unassigned stage is the payload's 'warning', never a colour
              // this file picks from a null check.
              PartnerChip(
                text: (task['worker_label'] ?? '').toString(),
                tone: (task['worker_tone'] ?? '').toString(),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text((row['promised_label'] ?? '').toString(), style: Ds.t.caption),
          if ((task['state_label'] ?? '').toString().isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text((task['state_label'] ?? '').toString(), style: Ds.t.caption),
          ],
          if (onAssign != null) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: () => onAssign!(row),
                child: Text(assigned ? reassignLabel : assignLabel),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
