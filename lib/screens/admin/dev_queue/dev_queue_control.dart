import 'dart:async';
import 'package:flutter/material.dart';

import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';
import 'dev_queue_workers.dart';

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
  bool _expanded = false; // collapsed by default — tap the header to open
  // Anchors so a lock/confirm popup can float right next to the tapped toggle.
  final Map<String, GlobalKey> _anchors = {
    'vm': GlobalKey(),
    'claude': GlobalKey(),
    'workflow': GlobalKey(),
  };
  OverlayEntry? _mini; // the single live mini popup

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _load());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _mini?.remove();
    _mini = null;
    super.dispose();
  }

  Map<String, dynamic> get _controls =>
      (_snap['controls'] as Map?)?.cast<String, dynamic>() ?? const {};

  bool _locked(String key) =>
      ((_controls[key] as Map?)?['locked'] ?? false) == true;

  String _lockMsg(String key) =>
      ((_controls[key] as Map?)?['lock_msg'] ?? '').toString();

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

  /// Opening the panel signals the VM to fetch a live reading, then re-reads a
  /// few times over the next several seconds to catch it — no manual button.
  /// The VM guards the rate limit, so a rapid re-open just re-serves fresh data.
  void _refreshUsage() {
    widget.service.requestUsageRefresh();
    _load();
    for (final s in const [2, 5, 9]) {
      Timer(Duration(seconds: s), () {
        if (mounted && _expanded) _load();
      });
    }
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

  /// A toggle tap. Locked toggles (per the backend ordering vm→claude→workflow)
  /// don't flip — they float a mini reason popup next to the switch and keep
  /// their colour. VM-off while building asks to confirm in that same mini
  /// popup, never a centre dialog.
  void _onToggle(String key, bool on) {
    if (_locked(key)) {
      _showMini(key, message: _lockMsg(key));
      return;
    }
    if (key == 'vm' && !on && _buildingId != null) {
      _showMini(key,
          message: c('dev_queue.ctl_confirm_vm_off'),
          confirmLabel: c('dev_queue.btn_submit'),
          onConfirm: () => _doFlip(key, on));
      return;
    }
    _doFlip(key, on);
  }

  Future<void> _doFlip(String key, bool on) async {
    final val = on ? 'on' : 'off';
    setState(() => _busy.add(key));
    try {
      final res = await widget.service.ctlSet(key, val);
      if (res['call_edge'] == true) {
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
      // Backend also enforces the ordering — surface a refusal as a mini popup.
      final msg = e.toString();
      if (mounted && msg.contains('LOCKED')) {
        _showMini(key, message: _lockMsg(key));
      } else if (mounted) {
        showToast(context, msg, isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  /// A small floating card anchored just above the tapped toggle. Info popups
  /// auto-dismiss; confirm popups carry a Cancel / action pair.
  void _showMini(String key,
      {required String message, String? confirmLabel, VoidCallback? onConfirm}) {
    _mini?.remove();
    _mini = null;
    final ctx = _anchors[key]?.currentContext;
    final overlay = Overlay.of(context);
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.of(context).size;
    // right-align the card to the switch; place it above, or below if near top.
    const w = 210.0;
    final right = (screen.width - (topLeft.dx + box.size.width)).clamp(8.0, screen.width - w - 8);
    final above = topLeft.dy > 130;
    final top = above ? topLeft.dy - 8 : topLeft.dy + box.size.height + 8;

    void close() {
      _mini?.remove();
      _mini = null;
    }

    final entry = OverlayEntry(builder: (_) {
      return Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: close,
          ),
        ),
        Positioned(
          right: right,
          top: above ? null : top,
          bottom: above ? (screen.height - topLeft.dy + 8) : null,
          width: w,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kTextHi,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 14,
                      offset: const Offset(0, 4)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(confirmLabel == null ? Icons.lock_outline : Icons.help_outline,
                        size: 15, color: Colors.white),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(message,
                          style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                    ),
                  ]),
                  if (confirmLabel != null) ...[
                    const SizedBox(height: 10),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      TextButton(
                        onPressed: close,
                        style: TextButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 10)),
                        child: Text(c('dev_queue.btn_cancel'),
                            style: const TextStyle(
                                fontSize: 12.5, color: Colors.white70)),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: () {
                          close();
                          onConfirm?.call();
                        },
                        style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF991B1B),
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 14)),
                        child: Text(confirmLabel,
                            style: const TextStyle(fontSize: 12.5)),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ]);
    });
    _mini = entry;
    overlay.insert(entry);
    if (confirmLabel == null) {
      Future.delayed(const Duration(milliseconds: 2200), () {
        if (_mini == entry) close();
      });
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
      // The whole card is a tap-to-expand panel: collapsed by default (a slim
      // summary bar so it never blocks the list), tapped open to reveal the
      // toggles + real usage. No chevron — the header itself is the control.
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () {
            setState(() => _expanded = !_expanded);
            if (_expanded) _refreshUsage(); // pull a FRESH reading on open
          },
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: _expanded ? _expandedHeader() : _collapsedHeader(),
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: 4),
          _row('vm', c('dev_queue.ctl_vm'), Icons.dns_outlined, _vmChip()),
          _divider(),
          _row('claude', c('dev_queue.ctl_claude'), Icons.terminal, _claudeChip()),
          _divider(),
          _row('workflow', c('dev_queue.ctl_workflow'), Icons.sync, _workflowChip()),
          _divider(),
          WorkerGridCard(
            pool: (_snap['pool'] as Map?)?.cast<String, dynamic>() ?? const {},
            service: widget.service,
            onChanged: _load,
          ),
          if ((_usage['has_usage'] ?? false) == true) ...[
            _divider(),
            _usageMeter(),
          ],
        ],
      ]),
    );
  }

  Widget _expandedHeader() => Row(children: [
        Text(c('dev_queue.ctl_section'),
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
        const Spacer(),
        if (_remoteOn)
          ToneChip(
              label: c('dev_queue.ctl_remote_on'),
              tone: statusTone('completed'),
              icon: Icons.phone_iphone),
      ]);

  /// Slim one-line summary shown when collapsed: workflow state + the top usage
  /// percent, so Om reads the essentials without opening the panel.
  Widget _collapsedHeader() {
    final wf = _isOn('workflow');
    final limits = (_usage['limits'] as List?) ?? const [];
    Map<String, dynamic>? first =
        limits.isNotEmpty ? Map<String, dynamic>.from(limits.first as Map) : null;
    return Row(children: [
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
            color: wf && _claudeAlive
                ? const Color(0xFF1B7A43)
                : kTextLo.withValues(alpha: 0.5),
            shape: BoxShape.circle),
      ),
      const SizedBox(width: 8),
      Text(c('dev_queue.ctl_section'),
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: kTextHi)),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
            _workflowSummary(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: kTextLo)),
      ),
      if (first != null) ...[
        const SizedBox(width: 6),
        ToneChip(
            label: '${first['pct_display']}',
            tone: statusTone((first['tone'] ?? 'completed').toString())),
      ],
    ]);
  }

  String _workflowSummary() {
    final wf = _isOn('workflow');
    final id = _buildingId;
    if (id != null) return '${c('dev_queue.status_building')} #$id';
    return wf ? c('dev_queue.status_pending') : c('dev_queue.ctl_workflow');
  }

  /// Real Claude usage — the actual session (5h) + weekly + Fable percentages
  /// pulled from Anthropic's usage endpoint on the VM. Every string + percent
  /// comes from the backend; the app only draws the bars.
  Widget _usageMeter() {
    final limits = (_usage['limits'] as List?) ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.data_usage, size: 18, color: kTextLo),
        const SizedBox(width: 8),
        Text(c('dev_queue.usage_label'),
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: kTextHi)),
        const Spacer(),
        _syncChip(),
      ]),
      const SizedBox(height: 10),
      for (final raw in limits) _limitBar(Map<String, dynamic>.from(raw as Map)),
      const SizedBox(height: 2),
      Text('${_usage['spend_display'] ?? ''}',
          style: const TextStyle(fontSize: 11, color: kTextLo)),
      Text('${_usage['today_display'] ?? ''}',
          style: const TextStyle(fontSize: 11, color: kTextLo)),
      const SizedBox(height: 6),
      Row(children: [
        Expanded(
          child: Text(c('dev_queue.plan_note'),
              style: const TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: kBrand)),
        ),
        InkWell(
          onTap: _openRates,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.info_outline, size: 12, color: Color(0xFF1E40AF)),
              const SizedBox(width: 4),
              Text(c('dev_queue.rates_open'),
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF1E40AF))),
            ]),
          ),
        ),
      ]),
    ]);
  }

  /// Read-only "API-equivalent rates" sheet — the official per-model ₹/Mtok
  /// table, fed entirely by dev_rates_get(). ₹ = USD × usd_inr, exactly as the
  /// RPC's own note prescribes; no price is written in Dart.
  Future<void> _openRates() async {
    Map<String, dynamic> rates = const {};
    try {
      rates = await widget.service.ratesGet();
    } catch (_) {/* sheet shows empty then */}
    if (!mounted) return;
    final models = (rates['models'] as Map?)?.cast<String, dynamic>() ?? const {};
    final usdInr = rates['usd_inr'];
    final note = (rates['note'] ?? '').toString();
    num inr(dynamic usd) =>
        (usd is num && usdInr is num) ? (usd * usdInr).round() : 0;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, ctl) => ListView(
          controller: ctl,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          children: [
            Text(c('dev_queue.rates_title'),
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: kTextHi)),
            const SizedBox(height: 4),
            if (usdInr != null)
              Text(cf('dev_queue.rates_usd_inr', {'rate': '$usdInr'}),
                  style: const TextStyle(fontSize: 12, color: kTextLo)),
            const SizedBox(height: 12),
            for (final e in models.entries)
              _rateRow(e.key, (e.value as Map?)?.cast<String, dynamic>() ?? const {}, inr),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(note, style: const TextStyle(fontSize: 11, color: kTextLo)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rateRow(String model, Map<String, dynamic> r, num Function(dynamic) inr) {
    final hasFast = r['fast_in'] != null || r['fast_out'] != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(model.replaceFirst('claude-', ''),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kTextHi)),
        const SizedBox(height: 2),
        Text('${c('dev_queue.rates_in')}: ₹${inr(r['in'])}   ${c('dev_queue.rates_out')}: ₹${inr(r['out'])}',
            style: const TextStyle(fontSize: 12, color: kTextLo)),
        if (hasFast)
          Text('${c('dev_queue.rates_fast_in')}: ₹${inr(r['fast_in'])}   ${c('dev_queue.rates_fast_out')}: ₹${inr(r['fast_out'])}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
      ]),
    );
  }

  /// Freshness indicator for the usage block. The string AND the tone come from
  /// the backend (updated_display / updated_tone): green when live, amber/red
  /// when the reading is stale — so a minutes-old number can never look current.
  Widget _syncChip() {
    final txt = '${_usage['updated_display'] ?? ''}';
    if (txt.isEmpty) return const SizedBox.shrink();
    final tone = statusTone((_usage['updated_tone'] ?? 'completed').toString());
    final fresh = (_usage['stale'] ?? false) != true;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: tone.bg, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(fresh ? Icons.check_circle : Icons.sync_problem,
            size: 12, color: tone.fg),
        const SizedBox(width: 4),
        Text(txt,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: tone.fg)),
      ]),
    );
  }

  Widget _limitBar(Map<String, dynamic> l) {
    final pct = (l['percent'] as num?)?.toDouble() ?? 0;
    final tone = statusTone((l['tone'] ?? 'completed').toString());
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text('${l['label'] ?? ''}',
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: kTextHi)),
          ),
          Text('${l['pct_display'] ?? ''}',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w700, color: tone.fg)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: (pct / 100).clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: const Color(0xFFF1F2F4),
            valueColor: AlwaysStoppedAnimation(tone.fg),
          ),
        ),
        const SizedBox(height: 4),
        Text('${l['resets_display'] ?? ''}',
            style: const TextStyle(fontSize: 11, color: kTextLo)),
      ]),
    );
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
      // The switch keeps its colour even when locked — a locked tap floats a
      // reason popup instead of flipping (handled in _onToggle), so we never
      // grey it out. onChanged stays live unless a real flip is in flight.
      KeyedSubtree(
        key: _anchors[key],
        child: Switch(
          value: on,
          activeTrackColor: kBrand,
          onChanged: busy ? null : (v) => _onToggle(key, v),
        ),
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
