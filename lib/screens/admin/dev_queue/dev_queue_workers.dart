import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'restart_safety.dart';
import 'dev_queue_detail.dart';
import 'dev_queue_service.dart';
import 'pool_settings_fields.dart';
import '../../../utils/render_log.dart';

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
  /// CHANGE #1366 — `dev_ctl_get().disk` (runner_disk_state), already a label,
  /// a value string, a sub-line and a tone name. The card computes no
  /// percentage and knows no threshold: a disk that filled to 99% for 21 hours
  /// was invisible here because nothing on this card was ever asked to say so.
  final Map<String, dynamic> disk;
  final DevQueueService service;
  final VoidCallback onChanged;
  const WorkerGridCard({
    super.key,
    required this.pool,
    this.disk = const {},
    required this.service,
    required this.onChanged,
  });

  Map<String, dynamic> get _config =>
      (pool['config'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _state =>
      (pool['state'] as Map?)?.cast<String, dynamic>() ?? const {};

  PoolLiveness get _live => PoolLiveness(_state);
  List<Map<String, dynamic>> get _workers => _live.workers;

  // CMD #1949 — `/admin/dev-queue?panel=runner&sheet=pool` opens the Pool
  // settings sheet on land, once per page load, so the registry-driven sheet can
  // be photographed headlessly (a Flutter canvas cannot be tapped).
  static bool _sheetAutoOpened = false;

  @override
  Widget build(BuildContext context) {
    if (!_sheetAutoOpened && Uri.base.queryParameters['sheet'] == 'pool') {
      _sheetAutoOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) _openSettings(context);
      });
    }
    final workers = _workers;
    final active = asInt(_state['active_workers']);
    final cap = asInt(_config['cap']);
    final shrink = (_state['shrink_display'] ?? '').toString();
    // CHANGE #1662 — Remote Control flapping. The sentence, and the tone it is
    // painted in, are dev_rc_health()'s; the card decides nothing, not even
    // whether there is a problem. Absent key = no banner, never a placeholder.
    final rcBanner = (_state['rc_banner'] ?? '').toString();
    final rcTone = (_state['rc_banner_tone'] ?? '').toString();
    final quota = (_state['quota_display'] ?? '').toString();
    final load = (_state['load_display'] ?? '').toString();
    // CHANGE #1149 — "branch: on · 2h 14m" / "branch: off" is the backend's
    // sentence (build_branch_state().display, forwarded by the supervisor).
    final branch = (_state['branch_display'] ?? '').toString();
    // CHANGE #233B — the backend blanks workers/counts/countdowns and hands
    // down this one line the moment the pool's own heartbeat goes stale, so a
    // stopped VM can never keep drawing a live worker grid.
    final stale = _live.staleDisplay;

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
      // Disk line. Present whenever the backend has a reading; absent (has:false)
      // draws nothing rather than a dash, so "not measured" never reads as "0%".
      if ((disk['has'] ?? false) == true) ...[
        SizedBox(height: Ds.space.x8),
        RunnerDiskLine(disk: disk),
      ],
      // Offline banner — same shape as the shrink banner, danger tone.
      if (stale.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x8 + 2, vertical: Ds.space.x8),
          decoration: BoxDecoration(
              color: Ds.c.dangerSoft, borderRadius: Ds.r.rButton),
          child: Row(children: [
            Icon(Icons.cloud_off_outlined,
                size: Ds.space.x16, color: Ds.c.danger),
            SizedBox(width: Ds.space.x8),
            Flexible(
              child: Text(stale,
                  style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w600, color: Ds.c.danger)),
            ),
          ]),
        ),
      ],
      // Remote Control flapping banner — the backend's own sentence.
      if (rcBanner.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        _RcBanner(text: rcBanner, tone: rcTone),
      ],
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
      // Quota / load / build-branch caption — each segment is a backend string.
      if (quota.isNotEmpty || load.isNotEmpty || branch.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final seg in [quota, load, branch].where((s) => s.isNotEmpty))
              Text(seg,
                  key: seg == branch ? const Key('c1149_branch_line') : null,
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ],
        ),
      ],
    ]);
  }

  Future<void> _openSettings(BuildContext context) async {
    final changed = await showPoolSettingsSheet(context, _config, service);
    if (changed == true) onChanged();
  }
}

/// CMD #1940 — the Pool settings sheet is opened from two places (the worker
/// grid's gear and the deploy-lock queue's intervals editor), so the opener is
/// shared. CMD #1949 — the sheet is dev_config_registry rendered verbatim: the
/// opener fetches the editable fields (and a fresh config) from pool_get first;
/// [config] is only the fallback if that read fails. Resolves true when a
/// `pool_set` landed.
Future<bool?> showPoolSettingsSheet(BuildContext context,
    Map<String, dynamic> config, DevQueueService service) async {
  var cfg = config;
  List<PoolSettingField> fields = const [];
  try {
    final res = await service.poolGet();
    cfg = (res['config'] as Map?)?.cast<String, dynamic>() ?? config;
    fields = PoolSettingsFields.parse(res['fields']);
  } catch (e) {
    if (context.mounted) {
      showToast(context, e is PostgrestException ? e.message : e.toString(),
          isError: true);
    }
    return null;
  }
  if (!context.mounted) return null;
  return showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Ds.c.surface,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Ds.r.rSheet.topLeft)),
    builder: (_) =>
        _PoolSettingsSheet(config: cfg, fields: fields, service: service),
  );
}

/// The Remote Control flapping banner (CHANGE #1662).
///
/// A session that keeps being opened and closed is a fact the BACKEND counts
/// (dev_rc_event) and the BACKEND words (dev_rc_health.rc_banner); this widget
/// only prints it. An unknown tone stays neutral rather than guessing a colour,
/// so a new tone added server-side can never paint the card wrong.
class _RcBanner extends StatelessWidget {
  final String text;
  final String tone;
  const _RcBanner({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    final bg = switch (tone) {
      'danger' => Ds.c.dangerSoft,
      'warning' => Ds.c.warningSoft,
      'success' => Ds.c.successSoft,
      _ => Ds.c.infoSoft,
    };
    final fg = switch (tone) {
      'danger' => Ds.c.danger,
      'warning' => Ds.c.warning,
      'success' => Ds.c.success,
      _ => Ds.c.info,
    };
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8 + 2, vertical: Ds.space.x8),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rButton),
      child: Row(children: [
        Icon(Icons.link_off, size: Ds.space.x16, color: fg),
        SizedBox(width: Ds.space.x8),
        Flexible(
          child: Text(text,
              style: Ds.t.caption
                  .copyWith(fontWeight: FontWeight.w600, color: fg)),
        ),
      ]),
    );
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
  final List<PoolSettingField> fields;
  final DevQueueService service;
  const _PoolSettingsSheet({
    required this.config,
    required this.fields,
    required this.service,
  });

  @override
  State<_PoolSettingsSheet> createState() => _PoolSettingsSheetState();
}

/// CMD #1949 — one control per registry row, drawn in payload order. Labels,
/// help, control kind, range and choices all come from dev_config_registry via
/// pool_get().fields; the sheet only collects the edits and forwards the PIN.
class _PoolSettingsSheetState extends State<_PoolSettingsSheet> {
  final Map<String, dynamic> _values = {};
  final Map<String, TextEditingController> _ctl = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      _values[f.key] = f.value;
      if (f.control == 'number' || f.control == 'text') {
        _ctl[f.key] = TextEditingController(text: f.value?.toString() ?? '');
      }
    }
    RenderLog.write('c1949_pool_fields', widget.fields.length);
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
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
      for (final f in widget.fields) {
        if (f.control == 'number') {
          _values[f.key] =
              PoolSettingsFields.numberValue(_ctl[f.key]!.text, f.value);
        } else if (f.control == 'text') {
          // Sent as typed — the backend parses/validates it (pool_set).
          _values[f.key] = _ctl[f.key]!.text.trim();
        }
      }
      final patch =
          PoolSettingsFields.buildPatch(widget.config, widget.fields, _values);
      final res = await widget.service.poolSet(patch, pin);
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
        if (widget.fields.isEmpty) _hint(c('dev_queue.pool_fields_empty')),
        for (final f in widget.fields) ...[
          _field(f),
          SizedBox(height: Ds.space.x16),
        ],
        SizedBox(height: Ds.space.x8),
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

  Widget _field(PoolSettingField f) {
    switch (f.control) {
      case 'slider':
        final lo = (f.min ?? 0).toDouble();
        final hi = (f.max ?? lo + 1).toDouble();
        final v = asInt(_values[f.key]).toDouble().clamp(lo, hi);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _label(f.label, '${v.round()}'),
          Slider(
            value: v,
            min: lo,
            max: hi,
            divisions: (hi - lo).round().clamp(1, 20),
            activeColor: Ds.c.brand,
            label: '${v.round()}',
            onChanged: _busy
                ? null
                : (x) => setState(() => _values[f.key] = x.round()),
          ),
          if (f.help.isNotEmpty) _hint(f.help),
        ]);
      case 'switch':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: _label(f.label, '')),
            Switch(
              value: _values[f.key] == true,
              activeTrackColor: Ds.c.brand,
              onChanged:
                  _busy ? null : (x) => setState(() => _values[f.key] = x),
            ),
          ]),
          if (f.help.isNotEmpty) _hint(f.help),
        ]);
      case 'choice':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _label(f.label, ''),
          SizedBox(height: Ds.space.x8),
          Wrap(spacing: Ds.space.x8, children: [
            for (final ch in f.choices)
              _choice(f.key, (ch['value'] ?? '').toString(),
                  (ch['label'] ?? ch['value'] ?? '').toString()),
          ]),
          if (f.help.isNotEmpty) _hint(f.help),
        ]);
      case 'text':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _label(f.label, ''),
          SizedBox(height: Ds.space.x8),
          _textField(_ctl[f.key]!),
          if (f.help.isNotEmpty) _hint(f.help),
        ]);
      default: // number
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _label(f.label, ''),
          SizedBox(height: Ds.space.x8),
          _numField(_ctl[f.key]!),
          if (f.help.isNotEmpty) _hint(f.help),
        ]);
    }
  }

  Widget _choice(String key, String value, String label) {
    final sel = (_values[key] ?? '').toString() == value;
    return ChoiceChip(
      label: Text(label),
      selected: sel,
      onSelected: _busy ? null : (_) => setState(() => _values[key] = value),
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
        Expanded(
          child: Text(k,
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w600, color: Ds.c.text)),
        ),
        if (v.isNotEmpty)
          Text(v,
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w700, color: Ds.c.brand)),
      ]);

  Widget _hint(String s) => Padding(
        padding: EdgeInsets.only(top: Ds.space.x4),
        child: Text(s, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      );

  // A full-width text input (e.g. a comma-separated list) — parsed and
  // validated by the backend on save.
  Widget _textField(TextEditingController ctl) => TextField(
        controller: ctl,
        enabled: !_busy,
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
      );

  // A small numeric input. The backend range-validates on save and renders any
  // error verbatim.
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
/// threshold. `has:false` draws nothing — "not measured yet" must never render
/// as a reassuring 0%.
class RunnerDiskLine extends StatelessWidget {
  final Map<String, dynamic> disk;
  const RunnerDiskLine({super.key, required this.disk});

  @override
  Widget build(BuildContext context) {
    if ((disk['has'] ?? false) != true) return const SizedBox.shrink();
    final sub = (disk['sub_line'] ?? '').toString();
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.storage_outlined,
          size: Ds.space.x16, color: Ds.c.textSecondary),
      SizedBox(width: Ds.space.x8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text((disk['label'] ?? '').toString(),
                style: Ds.t.caption.copyWith(
                    fontWeight: FontWeight.w600, color: Ds.c.text)),
            SizedBox(width: Ds.space.x8),
            Flexible(
              child: Text((disk['value'] ?? '').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption
                      .copyWith(color: _diskColor((disk['tone'] ?? '').toString()))),
            ),
          ]),
          if (sub.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(sub, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ],
        ]),
      ),
    ]);
  }

  /// The tone→colour lookup, exposed so the protected test can prove there is
  /// exactly ONE of them and that an unknown tone falls back to neutral.
  static Color debugValueColour(String tone) => _diskColor(tone);

  static Color _diskColor(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
      case 'error':
        return Ds.c.danger;
      default:
        return Ds.c.textSecondary;
    }
  }
}
