import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../models/c459_ops_queues.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../widgets/backend_error_view.dart';

/// `admin_ops_queues()` → the whole screen in one payload.
typedef OpsQueuesRpc = Future<Map<String, dynamic>> Function();

/// A row action: `admin_oos_resend` / `admin_oos_close` / `admin_pending_rescan`
/// / `admin_alert_ack`. Returns the backend's `{ok, message}` verbatim.
typedef OpsActionRpc =
    Future<Map<String, dynamic>> Function(String action, String id);

/// CHANGE #459 — "Ops queues": the six admin register rows of batch B, on one
/// reachable screen.
///
/// The screen decides nothing. Section order, section titles, counts, row
/// order, every label, every tone and which buttons exist all arrive in the
/// payload; a section whose `layout` this build has never heard of is skipped
/// in silence. A refusal (`ok:false`, or a thrown PostgrestException) renders
/// [BackendErrorView] — the backend's copy for the driver's code, never the
/// driver's own sentence (GAP 179).
///
/// Both RPCs are injected, so the screen carries no Supabase import and pumps
/// on the Dart VM; home_shell supplies the live calls.
class AdminOpsQueuesScreen extends StatefulWidget {
  final OpsQueuesRpc loadRpc;
  final OpsActionRpc actionRpc;

  const AdminOpsQueuesScreen({
    super.key,
    required this.loadRpc,
    required this.actionRpc,
  });

  @override
  State<AdminOpsQueuesScreen> createState() => _AdminOpsQueuesScreenState();
}

class _AdminOpsQueuesScreenState extends State<AdminOpsQueuesScreen> {
  bool _loading = true;
  OpsQueues? _data;
  BackendError? _error;

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
      final payload = await widget.loadRpc();
      final parsed = OpsQueues.fromJson(payload);
      if (!mounted) return;
      setState(() {
        _data = parsed;
        _error = parsed.ok ? null : BackendError.fromCode(parsed.refusalCode);
        _loading = false;
      });
      RenderLog.write('c459_ops_queues', parsed.ok ? parsed.sections.length : 0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = BackendError.from(e);
        _loading = false;
      });
      RenderLog.write('c459_ops_queues', 0);
    }
  }

  Future<void> _act(String action, String id) async {
    Map<String, dynamic> reply;
    try {
      reply = await widget.actionRpc(action, id);
    } catch (e) {
      reply = {'ok': false, 'message': BackendError.from(e).body};
    }
    final message = (reply['message'] ?? '').toString();
    if (mounted && message.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
    await _load();
  }

  Color _tone(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      case 'neutral':
        return Ds.c.textSecondary;
      default:
        return Ds.c.info;
    }
  }

  Color _toneSoft(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'neutral':
        return Ds.c.bg;
      default:
        return Ds.c.infoSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(data?.title.isNotEmpty == true ? data!.title : c('ops.title')),
        actions: [
          IconButton(
            tooltip: c('ops.refresh'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? _skeleton()
          : _error != null
              ? BackendErrorView(
                  error: _error!,
                  onAction: _error!.isRefusal ? null : _load,
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      if (data!.subtitle.isNotEmpty) ...[
                        Text(data.subtitle, style: Ds.t.caption),
                        SizedBox(height: Ds.space.x24),
                      ],
                      for (final s in data.sections) ...[
                        _section(s),
                        SizedBox(height: Ds.space.x24),
                      ],
                    ],
                  ),
                ),
    );
  }

  /// A skeleton, not a bare spinner (design QA rule 6).
  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              height: Ds.touch.listRowMinHeight,
              margin: EdgeInsets.only(bottom: Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1,
              ),
            ),
        ],
      );

  Widget _section(OpsSection s) => Container(
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(s.title, style: Ds.t.subtitle)),
                if (s.countLabel.isNotEmpty) _chip(s.countLabel, s.tone),
              ],
            ),
            if (s.subtitle.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(s.subtitle, style: Ds.t.caption),
            ],
            if (s.layout == 'strip' && s.bannerLabel.isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              _banner(s.bannerLabel, s.bannerTone),
            ],
            SizedBox(height: Ds.space.x12),
            if (s.layout == 'queue')
              if (s.rows.isEmpty)
                Text(s.emptyLabel, style: Ds.t.caption)
              else
                for (final r in s.rows) _queueRow(s, r)
            else
              for (final r in s.stripRows) _stripRow(r),
          ],
        ),
      );

  Widget _chip(String label, String tone) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: _toneSoft(tone),
          borderRadius: Ds.r.rChip,
        ),
        child: Text(label,
            style: Ds.t.caption.copyWith(color: _tone(tone))),
      );

  Widget _banner(String label, String tone) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: _toneSoft(tone),
          borderRadius: Ds.r.rButton,
        ),
        child: Text(label, style: Ds.t.body.copyWith(color: _tone(tone))),
      );

  Widget _queueRow(OpsSection s, OpsRow r) {
    final actions = <Widget>[
      if (r.canResend && r.resendLabel.isNotEmpty)
        _action(r.resendLabel, () => _act('resend', r.id)),
      if (r.canRescan && r.rescanLabel.isNotEmpty)
        _action(r.rescanLabel, () => _act('rescan', r.id)),
      if (r.canAck && r.ackLabel.isNotEmpty)
        _action(r.ackLabel, () => _act('ack', r.id)),
      if (r.canResend && r.closeLabel.isNotEmpty)
        _action(r.closeLabel, () => _act('close', r.id)),
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(r.title, style: Ds.t.body)),
              if (r.stateLabel.isNotEmpty) ...[
                SizedBox(width: Ds.space.x8),
                _chip(r.stateLabel, r.stateTone),
              ],
            ],
          ),
          if (r.ageLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(r.ageLabel, style: Ds.t.caption),
          ],
          for (final line in r.detailLines) ...[
            SizedBox(height: Ds.space.x4),
            Text(line, style: Ds.t.caption),
          ],
          if (r.sourceLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(r.sourceLabel, style: Ds.t.caption),
          ],
          if (actions.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Wrap(spacing: Ds.space.x8, children: actions),
          ],
        ],
      ),
    );
  }

  Widget _action(String label, VoidCallback onTap) => SizedBox(
        height: Ds.touch.minTarget,
        child: TextButton(onPressed: onTap, child: Text(label)),
      );

  Widget _stripRow(OpsStripRow r) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.label, style: Ds.t.body),
                  if (r.detail.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x4),
                    Text(r.detail, style: Ds.t.caption),
                  ],
                ],
              ),
            ),
            SizedBox(width: Ds.space.x12),
            _chip(r.value, r.tone),
          ],
        ),
      );
}
