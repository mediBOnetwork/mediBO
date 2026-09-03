// lib/screens/worker/worker_tasks_screen.dart — CHANGE #707
//
// "My tasks": the stages assigned to the logged-in worker today, in the order
// the BACKEND promised them.
//
// The ordering is the point. A worker's list sorted by anything this file
// computes — creation time, order code, whatever arrived first — is a list that
// disagrees with the ops board's clock. fulfil_my_tasks() resolves each stage's
// SLA against the zone's own config and sorts by the resulting promise, and a
// stage with no SLA row has NO promise: it prints the backend's "No promised
// time" and sorts last, rather than being given a fake urgency here.
//
// Start and Finish send the task id and print whatever comes back. In
// particular, a Finish that the backend refuses — because the stage belongs to
// somebody else — shows the backend's own sentence naming that person; this
// file has no fallback wording and no idea who is allowed to close what.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../partner/partner_ui.dart';

class WorkerTasksScreen extends StatefulWidget {
  const WorkerTasksScreen({super.key});

  @override
  State<WorkerTasksScreen> createState() => _WorkerTasksScreenState();
}

class _WorkerTasksScreenState extends State<WorkerTasksScreen> {
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
      final res = await Supabase.instance.client.rpc('fulfil_my_tasks');
      final map = Map<String, dynamic>.from(res as Map);
      RenderLog.write('c707_my_tasks',
          'ok=${map['ok']} rows=${(map['rows'] as List?)?.length ?? 0}');
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
                  child: WorkerTasksView(
                    payload: d,
                    onStart: (id) =>
                        _call('fulfil_task_start', {'p_task_id': id}),
                    onFinish: (id) =>
                        _call('fulfil_task_finish', {'p_task_id': id}),
                  ),
                ),
      ),
    );
  }
}

/// The rendered list, split from the screen so a protected test can pump a
/// payload with no Supabase, no network and no timers.
///
/// It renders `rows` IN PAYLOAD ORDER. There is no sort here — the backend
/// already sorted by the promise it computed.
class WorkerTasksView extends StatelessWidget {
  const WorkerTasksView({
    super.key,
    required this.payload,
    required this.onStart,
    required this.onFinish,
  });

  final Map<String, dynamic> payload;
  final void Function(Object taskId) onStart;
  final void Function(Object taskId) onFinish;

  @override
  Widget build(BuildContext context) {
    final d = payload;
    final rows = (d['rows'] as List? ?? const []);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text((d['subtitle'] as String?) ?? '', style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty)
          PartnerNotice(title: '', text: (d['empty_label'] as String?) ?? '')
        else
          for (final r in rows) ...[
            _MyTaskRow(
              row: Map<String, dynamic>.from(r as Map),
              onStart: onStart,
              onFinish: onFinish,
            ),
            SizedBox(height: Ds.space.x12),
          ],
      ],
    );
  }
}

class _MyTaskRow extends StatelessWidget {
  const _MyTaskRow({
    required this.row,
    required this.onStart,
    required this.onFinish,
  });

  final Map<String, dynamic> row;
  final void Function(Object taskId) onStart;
  final void Function(Object taskId) onFinish;

  @override
  Widget build(BuildContext context) {
    final task = (row['task'] is Map)
        ? Map<String, dynamic>.from(row['task'] as Map)
        : const <String, dynamic>{};
    final id = task['task_id'];
    // `started` is the backend's flag, not an inference from state_label.
    final started = task['started'] == true;

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
                    Text((row['stage_label'] ?? '').toString(),
                        style: Ds.t.caption),
                  ],
                ),
              ),
              if ((task['override_chip'] ?? '').toString().isNotEmpty)
                PartnerChip(
                    text: (task['override_chip'] ?? '').toString(),
                    tone: 'warning'),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text((row['promised_label'] ?? '').toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text((task['qty_label'] ?? '').toString(), style: Ds.t.caption),
          if (id != null) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () =>
                    started ? onFinish(id as Object) : onStart(id as Object),
                child: Text(started
                    ? (task['finish_label'] ?? '').toString()
                    : (task['start_label'] ?? '').toString()),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
