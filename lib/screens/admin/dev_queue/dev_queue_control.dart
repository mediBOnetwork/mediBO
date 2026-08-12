import 'dart:async';
import 'package:flutter/material.dart';

import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// The runner control strip at the top of the Dev Queue tab: three toggles
/// (VM / Claude / Workflow) with live status chips. Renders `dev_ctl_get`
/// verbatim; every flip is a `dev_ctl_set` (+ the vm-control edge fn for VM).
/// The backend/supervisor is the source of truth — this never infers state.
class DevQueueControl extends StatefulWidget {
  final DevQueueService service;
  const DevQueueControl({super.key, required this.service});

  @override
  State<DevQueueControl> createState() => _DevQueueControlState();
}

class _DevQueueControlState extends State<DevQueueControl> {
  Timer? _poll;
  Map<String, dynamic> _snap = const {};
  Map<String, dynamic> _usage = const {};
  final Set<String> _busy = {}; // keys mid-flip

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.service.ctlGet(),
        widget.service.sessionUsage(),
      ]);
      if (mounted) {
        setState(() {
          _snap = results[0];
          _usage = results[1];
        });
      }
    } catch (_) {}
  }

  Map<String, dynamic> get _desired =>
      (_snap['desired_state'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _status =>
      (_snap['runner_status'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _vm =>
      (_snap['vm'] as Map?)?.cast<String, dynamic>() ?? const {};

  bool _isOn(String k) => (_desired[k] ?? 'off') == 'on';

  bool get _claudeAlive {
    final at = DateTime.tryParse((_status['alive_at'] ?? '').toString());
    final now = DateTime.tryParse((_snap['server_now'] ?? '').toString());
    if (at == null || now == null) return false;
    return now.difference(at).inSeconds < 180;
  }

  int? get _buildingId {
    final v = _status['current_command_id'];
    return v is num ? v.toInt() : null;
  }

  bool get _remoteOn => (_status['remote_control'] ?? 'off') == 'on';

  Future<void> _flip(String key, bool on) async {
    final val = on ? 'on' : 'off';
    // Confirm VM Off while a command is building.
    if (key == 'vm' && !on && _buildingId != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          content: Text(c('dev_queue.ctl_confirm_vm_off')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(c('dev_queue.btn_cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF991B1B)),
                child: Text(c('dev_queue.btn_submit'))),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy.add(key));
    try {
      final res = await widget.service.ctlSet(key, val);
      if (res['call_edge'] == true) {
        // VM: no-op if already in the target state.
        final cur = (_vm['status'] ?? 'unknown').toString();
        if ((on && cur == 'running') || (!on && cur == 'stopped')) {
          if (mounted) {
            showToast(context,
                c(on ? 'dev_queue.ctl_vm_on_toast' : 'dev_queue.ctl_vm_off_toast'));
          }
        } else {
          try {
            await widget.service.vmControl(res['action']?.toString() ?? 'status');
          } catch (_) {
            if (mounted) showToast(context, c('dev_queue.ctl_edge_failed'), isError: true);
          }
        }
      }
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(c('dev_queue.ctl_section'),
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
          const Spacer(),
          if (_remoteOn)
            ToneChip(
                label: c('dev_queue.ctl_remote_on'),
                tone: statusTone('completed'),
                icon: Icons.phone_iphone),
        ]),
        const SizedBox(height: 4),
        _row('vm', c('dev_queue.ctl_vm'), Icons.dns_outlined, _vmChip()),
        _divider(),
        _row('claude', c('dev_queue.ctl_claude'), Icons.terminal, _claudeChip()),
        _divider(),
        _row('workflow', c('dev_queue.ctl_workflow'), Icons.sync, _workflowChip()),
        if (_usage.isNotEmpty) ...[
          _divider(),
          _usageMeter(),
        ],
      ]),
    );
  }

  /// Session usage meter — tokens/cost used in the rolling window vs the
  /// configurable budget. Every string + the percent come from the backend.
  Widget _usageMeter() {
    final pct = (_usage['pct'] as num?)?.toDouble() ?? 0;
    final tone = statusTone((_usage['tone'] ?? 'completed').toString());
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.data_usage, size: 18, color: kTextLo),
        const SizedBox(width: 8),
        Text(c('dev_queue.usage_label'),
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: kTextHi)),
        const Spacer(),
        Text('${_usage['window_label'] ?? ''} · ${_usage['pct_display'] ?? ''}',
            style: const TextStyle(fontSize: 12, color: kTextLo)),
      ]),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: LinearProgressIndicator(
          value: (pct / 100).clamp(0.0, 1.0),
          minHeight: 8,
          backgroundColor: const Color(0xFFF1F2F4),
          valueColor: AlwaysStoppedAnimation(tone.fg),
        ),
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('${_usage['window_tokens_display'] ?? ''}',
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: kTextHi)),
        ToneChip(label: '${_usage['window_cost_display'] ?? ''}', tone: statusTone('paused')),
        Text('${_usage['remaining_display'] ?? ''}',
            style: const TextStyle(fontSize: 11, color: kTextLo)),
      ]),
      const SizedBox(height: 4),
      Text(
          '${c('dev_queue.usage_today')} ${_usage['today_tokens_display'] ?? ''} · ${_usage['today_cost_display'] ?? ''} · ${_usage['today_commands'] ?? 0}',
          style: const TextStyle(fontSize: 11, color: kTextLo)),
    ]);
  }

  Widget _divider() =>
      const Divider(height: 12, thickness: 1, color: Color(0xFFF1F2F4));

  Widget _row(String key, String label, IconData icon, Widget chip) {
    final on = _isOn(key);
    final busy = _busy.contains(key);
    return Row(children: [
      Icon(icon, size: 18, color: kTextLo),
      const SizedBox(width: 8),
      SizedBox(
          width: 74,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: kTextHi))),
      const SizedBox(width: 4),
      Expanded(child: Align(alignment: Alignment.centerLeft, child: chip)),
      if (busy)
        const Padding(
          padding: EdgeInsets.only(right: 8),
          child: SizedBox(
              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      Switch(
        value: on,
        activeTrackColor: kBrand,
        onChanged: busy ? null : (v) => _flip(key, v),
      ),
    ]);
  }

  Widget _vmChip() {
    final s = (_vm['status'] ?? 'unknown').toString();
    const map = {
      'running': ['dev_queue.ctl_vm_running', 'completed'],
      'stopped': ['dev_queue.ctl_vm_stopped', 'paused'],
      'starting': ['dev_queue.ctl_vm_starting', 'awaiting_approval'],
      'stopping': ['dev_queue.ctl_vm_stopping', 'awaiting_approval'],
    };
    final e = map[s] ?? const ['dev_queue.ctl_vm_unknown', 'paused'];
    return ToneChip(label: c(e[0]), tone: statusTone(e[1]));
  }

  Widget _claudeChip() {
    if (_isOn('claude') && !_claudeAlive) {
      return ToneChip(label: c('dev_queue.ctl_applying'), tone: statusTone('awaiting_approval'));
    }
    return _claudeAlive
        ? ToneChip(label: c('dev_queue.ctl_claude_alive'), tone: statusTone('completed'))
        : ToneChip(label: c('dev_queue.ctl_claude_offline'), tone: statusTone('paused'));
  }

  Widget _workflowChip() {
    if (!_isOn('workflow')) {
      return ToneChip(label: c('dev_queue.ctl_wf_off'), tone: statusTone('paused'));
    }
    final bid = _buildingId;
    if (bid != null) {
      return ToneChip(
          label: cf('dev_queue.ctl_wf_building', {'id': '$bid'}),
          tone: statusTone('building'),
          spinning: true);
    }
    final st = (_status['state'] ?? '').toString();
    if (st == 'workflow_running') {
      return ToneChip(label: c('dev_queue.ctl_wf_running'), tone: statusTone('completed'));
    }
    return ToneChip(label: c('dev_queue.ctl_applying'), tone: statusTone('awaiting_approval'));
  }
}
