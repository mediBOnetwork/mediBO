import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_detail.dart';
import 'dev_queue_service.dart';

/// The parallel-build worker grid, slotted inside the Runner-control card.
///
/// THE APP RENDERS. IT NEVER DECIDES. — every value here is drawn from
/// `dev_ctl_get().pool` ({config, state, lease_counts}); `state` is what the VM
/// orchestrator last published (active_workers, workers[], quota, load, shrink),
/// each field already render-ready. The card composes nothing: it shows the
/// backend's chips, its shrink banner, and opens a PIN-gated settings sheet that
/// only forwards the admin's patch to `pool_set`.
class WorkerGridCard extends StatelessWidget {
  final Map<String, dynamic> pool;
  final DevQueueService service;
  final VoidCallback onChanged;
  const WorkerGridCard({
    super.key,
    required this.pool,
    required this.service,
    required this.onChanged,
  });

  Map<String, dynamic> get _config =>
      (pool['config'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _state =>
      (pool['state'] as Map?)?.cast<String, dynamic>() ?? const {};

  List<Map<String, dynamic>> get _workers =>
      ((_state['workers'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  @override
  Widget build(BuildContext context) {
    final workers = _workers;
    final active = asInt(_state['active_workers']);
    final cap = asInt(_config['cap']);
    final shrink = (_state['shrink_display'] ?? '').toString();
    final quota = (_state['quota_display'] ?? '').toString();
    final load = (_state['load_display'] ?? '').toString();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header: title · active/cap count · settings gear.
      Row(children: [
        Icon(Icons.dashboard_customize_outlined,
            size: Ds.space.x16 + 2, color: Ds.c.textSecondary),
        SizedBox(width: Ds.space.x8),
        Text(c('dev_queue.workers_title'),
            style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w700, color: Ds.c.text)),
        SizedBox(width: Ds.space.x8),
        Text(cf('dev_queue.workers_count', {'active': '$active', 'cap': '$cap'}),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        const Spacer(),
        InkWell(
          onTap: () => _openSettings(context),
          borderRadius: Ds.r.rChip,
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x4),
            child: Icon(Icons.tune,
                size: Ds.space.x16 + 4, color: Ds.c.brand),
          ),
        ),
      ]),
      // Shrink banner (only when the backend supplied a reason string).
      if (shrink.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x8 + 2, vertical: Ds.space.x8),
          decoration: BoxDecoration(
              color: Ds.c.warningSoft, borderRadius: Ds.r.rButton),
          child: Row(children: [
            Icon(Icons.trending_down, size: Ds.space.x16, color: Ds.c.warning),
            SizedBox(width: Ds.space.x8),
            Flexible(
              child: Text(shrink,
                  style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w600, color: Ds.c.warning)),
            ),
          ]),
        ),
      ],
      SizedBox(height: Ds.space.x12),
      // Worker chips — or the empty state when nothing is reporting yet.
      if (workers.isEmpty)
        Text(c('dev_queue.workers_none'),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary))
      else
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [for (final w in workers) _WorkerChip(worker: w, service: service)],
        ),
      // Quota / load caption.
      if (quota.isNotEmpty || load.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Row(children: [
          if (quota.isNotEmpty)
            Text(quota, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          if (quota.isNotEmpty && load.isNotEmpty)
            Text('   ·   ',
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          if (load.isNotEmpty)
            Text(load, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        ]),
      ],
    ]);
  }

  Future<void> _openSettings(BuildContext context) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Ds.c.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Ds.r.rSheet.topLeft)),
      builder: (_) => _PoolSettingsSheet(config: _config, service: service),
    );
    if (changed == true) onChanged();
  }
}

/// One worker: id, its live command (# + title, tap → detail), model·effort and
/// ETA-left. Idle workers are muted with no command line. All strings backend.
class _WorkerChip extends StatelessWidget {
  final Map<String, dynamic> worker;
  final DevQueueService service;
  const _WorkerChip({required this.worker, required this.service});

  @override
  Widget build(BuildContext context) {
    final id = (worker['id'] ?? '').toString();
    final cmd = worker['command_id'];
    final building = cmd != null;
    final title = (worker['title'] ?? '').toString();
    final lane = (worker['lane'] ?? '').toString();
    final meta = (worker['meta'] ?? '').toString();
    final eta = (worker['eta_display'] ?? '').toString();
    final tone = building ? statusTone('building') : statusTone('paused');

    final chip = Container(
      constraints: BoxConstraints(minWidth: Ds.space.x48 * 3),
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: building ? Ds.c.infoSoft : Ds.c.bg,
        borderRadius: Ds.r.rButton,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: Ds.space.x8,
            height: Ds.space.x8,
            decoration: BoxDecoration(color: tone.fg, shape: BoxShape.circle),
          ),
          SizedBox(width: Ds.space.x8),
          Text(id,
              style: Ds.t.caption.copyWith(
                  fontWeight: FontWeight.w700, color: Ds.c.text)),
          if (building) ...[
            SizedBox(width: Ds.space.x8),
            Text('#$cmd',
                style: Ds.t.caption.copyWith(
                    fontWeight: FontWeight.w700, color: Ds.c.textSecondary)),
          ],
          if (lane.isNotEmpty) ...[
            SizedBox(width: Ds.space.x8),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                  color: Ds.c.brandSoft, borderRadius: Ds.r.rChip),
              child: Text(lane,
                  style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w700, color: Ds.c.brand)),
            ),
          ],
        ]),
        if (!building)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(c('dev_queue.workers_idle'),
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ),
        if (building && title.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: Ds.space.x48 * 4),
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption.copyWith(color: Ds.c.text)),
            ),
          ),
        if (building && (meta.isNotEmpty || eta.isNotEmpty))
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(
                [meta, eta].where((s) => s.isNotEmpty).join('  ·  '),
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ),
      ]),
    );

    if (!building) return chip;
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) =>
              DevQueueDetail(id: asInt(cmd), service: service))),
      borderRadius: Ds.r.rButton,
      child: chip,
    );
  }
}

/// PIN-gated pool settings: cap, auto-scale, billing mode, idle shutdown. Every
/// change is a single `pool_set(patch, pin)` — the app decides nothing, it only
/// collects the patch and forwards the PIN.
class _PoolSettingsSheet extends StatefulWidget {
  final Map<String, dynamic> config;
  final DevQueueService service;
  const _PoolSettingsSheet({required this.config, required this.service});

  @override
  State<_PoolSettingsSheet> createState() => _PoolSettingsSheetState();
}

class _PoolSettingsSheetState extends State<_PoolSettingsSheet> {
  late int _cap;
  late bool _auto;
  late String _billing;
  late final TextEditingController _idle;
  late final TextEditingController _weekly;
  late final TextEditingController _session;
  late bool _routingEnabled;
  late final TextEditingController _opusLanes;
  late final TextEditingController _sonnetLanes;
  bool _busy = false;

  Map<String, dynamic> get _routing =>
      (widget.config['routing'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _lanes =>
      (_routing['lanes'] as Map?)?.cast<String, dynamic>() ?? const {};

  int get _min => asInt(widget.config['min']) == 0 ? 1 : asInt(widget.config['min']);
  int get _max => asInt(widget.config['max']) == 0 ? 8 : asInt(widget.config['max']);

  @override
  void initState() {
    super.initState();
    _cap = asInt(widget.config['cap']).clamp(_min, _max);
    _auto = widget.config['auto'] == true;
    _billing = (widget.config['billing_mode'] ?? 'max_subscription').toString();
    _idle = TextEditingController(
        text: '${asInt(widget.config['idle_shutdown_min'])}');
    _weekly = TextEditingController(
        text: '${asInt(widget.config['quota_shrink_pct'])}');
    _session = TextEditingController(
        text: '${asInt(widget.config['quota_shrink_session_pct'])}');
    _routingEnabled = _routing['enabled'] == true;
    _opusLanes = TextEditingController(text: '${asInt(_lanes['opus'])}');
    _sonnetLanes = TextEditingController(text: '${asInt(_lanes['sonnet'])}');
  }

  @override
  void dispose() {
    _idle.dispose();
    _weekly.dispose();
    _session.dispose();
    _opusLanes.dispose();
    _sonnetLanes.dispose();
    super.dispose();
  }

  Future<String?> _askPin() async {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(c('dev_queue.gcp_pin_confirm')),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          obscureText: true,
          decoration: InputDecoration(hintText: c('dev_queue.gcp_pin_hint')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(c('dev_queue.btn_cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, ctl.text.trim()),
              style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
              child: Text(c('dev_queue.gcp_unlock'))),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final pin = await _askPin();
    if (pin == null || pin.isEmpty) return;
    setState(() => _busy = true);
    try {
      final res = await widget.service.poolSet({
        'cap': _cap,
        'auto': _auto,
        'billing_mode': _billing,
        'idle_shutdown_min': int.tryParse(_idle.text.trim()) ??
            asInt(widget.config['idle_shutdown_min']),
        'quota_shrink_pct': int.tryParse(_weekly.text.trim()) ??
            asInt(widget.config['quota_shrink_pct']),
        'quota_shrink_session_pct': int.tryParse(_session.text.trim()) ??
            asInt(widget.config['quota_shrink_session_pct']),
        // pool_set shallow-merges the top level, so routing is sent whole.
        'routing': {
          ..._routing,
          'enabled': _routingEnabled,
          'lanes': {
            ..._lanes,
            'opus': int.tryParse(_opusLanes.text.trim()) ?? asInt(_lanes['opus']),
            'sonnet':
                int.tryParse(_sonnetLanes.text.trim()) ?? asInt(_lanes['sonnet']),
          },
        },
      }, pin);
      if (!mounted) return;
      if (res['ok'] == false) {
        showToast(context, c('dev_queue.gcp_pin_failed'), isError: true);
        setState(() => _busy = false);
        return;
      }
      showToast(context, c('dev_queue.pool_saved'));
      Navigator.pop(context, true);
    } catch (e) {
      // Backend range/PIN checks RAISE with a plain message — surface it verbatim.
      if (mounted) {
        final msg = e is PostgrestException ? e.message : e.toString();
        showToast(context, msg, isError: true);
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x24, Ds.space.x16, Ds.space.x24, Ds.space.x32),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c('dev_queue.workers_settings'),
            style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: Ds.c.text)),
        SizedBox(height: Ds.space.x24),
        // Cap slider.
        _label(c('dev_queue.pool_cap'), '$_cap'),
        Slider(
          value: _cap.toDouble(),
          min: _min.toDouble(),
          max: _max.toDouble(),
          divisions: (_max - _min).clamp(1, 20),
          activeColor: Ds.c.brand,
          label: '$_cap',
          onChanged: _busy ? null : (v) => setState(() => _cap = v.round()),
        ),
        _hint(c('dev_queue.pool_cap_hint')),
        SizedBox(height: Ds.space.x16),
        // Auto-scale toggle.
        Row(children: [
          Expanded(child: _label(c('dev_queue.pool_auto'), '')),
          Switch(
            value: _auto,
            activeTrackColor: Ds.c.brand,
            onChanged: _busy ? null : (v) => setState(() => _auto = v),
          ),
        ]),
        _hint(c('dev_queue.pool_auto_hint')),
        SizedBox(height: Ds.space.x16),
        // Billing-mode selector.
        _label(c('dev_queue.pool_billing'), ''),
        SizedBox(height: Ds.space.x8),
        Wrap(spacing: Ds.space.x8, children: [
          _billingChoice('max_subscription', c('dev_queue.pool_billing_max')),
          _billingChoice('api', c('dev_queue.pool_billing_api')),
        ]),
        _hint(c('dev_queue.pool_billing_hint')),
        SizedBox(height: Ds.space.x16),
        // Parallel-pause threshold — weekly usage %.
        _label(c('dev_queue.pool_weekly'), ''),
        SizedBox(height: Ds.space.x8),
        _numField(_weekly),
        _hint(c('dev_queue.pool_weekly_hint')),
        SizedBox(height: Ds.space.x16),
        // Parallel-pause threshold — 5h session usage %.
        _label(c('dev_queue.pool_session'), ''),
        SizedBox(height: Ds.space.x8),
        _numField(_session),
        _hint(c('dev_queue.pool_session_hint')),
        SizedBox(height: Ds.space.x16),
        // Idle shutdown minutes.
        _label(c('dev_queue.pool_idle'), ''),
        SizedBox(height: Ds.space.x8),
        _numField(_idle),
        _hint(c('dev_queue.pool_idle_hint')),
        SizedBox(height: Ds.space.x16),
        // Lane routing: send small specs to the Sonnet lane, large to Opus.
        Row(children: [
          Expanded(child: _label(c('dev_queue.pool_routing'), '')),
          Switch(
            value: _routingEnabled,
            activeTrackColor: Ds.c.brand,
            onChanged: _busy ? null : (v) => setState(() => _routingEnabled = v),
          ),
        ]),
        _hint(c('dev_queue.pool_routing_hint')),
        if (_routingEnabled) ...[
          SizedBox(height: Ds.space.x12),
          Row(children: [
            Expanded(child: _label(c('dev_queue.pool_lane_opus'), '')),
            _numField(_opusLanes),
          ]),
          SizedBox(height: Ds.space.x12),
          Row(children: [
            Expanded(child: _label(c('dev_queue.pool_lane_sonnet'), '')),
            _numField(_sonnetLanes),
          ]),
        ],
        SizedBox(height: Ds.space.x24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy ? null : _save,
            style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                minimumSize: Size(0, Ds.touch.minTarget)),
            child: _busy
                ? SizedBox(
                    width: Ds.space.x16,
                    height: Ds.space.x16,
                    child: const CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(c('dev_queue.btn_save_edit'),
                    style: Ds.t.body.copyWith(
                        fontWeight: FontWeight.w600, color: Colors.white)),
          ),
        ),
      ]),
    );
  }

  Widget _billingChoice(String value, String label) {
    final sel = _billing == value;
    return ChoiceChip(
      label: Text(label),
      selected: sel,
      onSelected: _busy ? null : (_) => setState(() => _billing = value),
      selectedColor: Ds.c.successSoft,
      backgroundColor: Ds.c.surface,
      labelStyle: Ds.t.caption.copyWith(
          fontWeight: FontWeight.w600,
          color: sel ? Ds.c.success : Ds.c.textSecondary),
      shape: RoundedRectangleBorder(
        borderRadius: Ds.r.rChip,
        side: BorderSide(color: Ds.c.divider),
      ),
    );
  }

  Widget _label(String k, String v) => Row(children: [
        Text(k,
            style: Ds.t.body.copyWith(fontWeight: FontWeight.w600, color: Ds.c.text)),
        if (v.isNotEmpty) ...[
          const Spacer(),
          Text(v,
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w700, color: Ds.c.brand)),
        ],
      ]);

  Widget _hint(String s) => Padding(
        padding: EdgeInsets.only(top: Ds.space.x4),
        child: Text(s, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      );

  // A small numeric input (idle minutes / usage thresholds). The backend
  // range-validates on save and renders any error verbatim.
  Widget _numField(TextEditingController ctl) => SizedBox(
        width: Ds.space.x48 * 2,
        child: TextField(
          controller: ctl,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          style: Ds.t.body,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: Ds.c.bg,
            enabledBorder: OutlineInputBorder(
              borderRadius: Ds.r.rButton,
              borderSide: BorderSide(color: Ds.c.divider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: Ds.r.rButton,
              borderSide: BorderSide(color: Ds.c.brand),
            ),
          ),
        ),
      );
}
