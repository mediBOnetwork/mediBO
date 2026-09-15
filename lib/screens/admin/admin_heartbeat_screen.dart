// CHANGE #468 — Daily heartbeat: the canary's own window.
//
// Every morning one synthetic order walks the entire live pipeline — order,
// payment, inquiry, a SIMULATED supplier answer, supplier order, collect,
// count, bag, pack, bill, rider, delivery, close — and every stage asserts the
// state it was supposed to produce, inside its own timeout. The first failure
// stops the run and fires an urgent alert naming the stage. A green run leaves
// one summary line.
//
// THE APP RENDERS. IT NEVER DECIDES. The title, the subtitle, every status
// label, the summary line, the stage names, the timeouts, the "artifacts
// cleaned up" sentence, the schedule, the two button captions and the empty
// state all arrive inside `heartbeat_home()` / `heartbeat_run_detail()`. There
// is no display string, no status→label switch and no duration arithmetic in
// this file. The one thing chosen locally is what every screen chooses
// locally: a backend TONE NAME resolved to the fixed design palette.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// Resolves a backend tone name to the design palette. The server decides
/// which colour a chip wears; the app only knows what the names mean.
({Color bg, Color fg}) _tone(String name) {
  switch (name) {
    case 'success':
      return (bg: Ds.c.successSoft, fg: Ds.c.success);
    case 'warning':
      return (bg: Ds.c.warningSoft, fg: Ds.c.warning);
    case 'danger':
      return (bg: Ds.c.dangerSoft, fg: Ds.c.danger);
    case 'brand':
      return (bg: Ds.c.brandSoft, fg: Ds.c.brand);
    case 'info':
      return (bg: Ds.c.infoSoft, fg: Ds.c.info);
    default:
      return (bg: Ds.c.bg, fg: Ds.c.textSecondary);
  }
}

/// Thin RPC layer — one call per method, payload returned untouched.
class HeartbeatService {
  HeartbeatService({SupabaseClient? client})
      : _c = client ?? Supabase.instance.client;

  final SupabaseClient _c;

  Map<String, dynamic> _asMap(dynamic raw) {
    final v = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> home() async =>
      _asMap(await _c.rpc('heartbeat_home'));

  Future<Map<String, dynamic>> detail(int runId) async =>
      _asMap(await _c.rpc('heartbeat_run_detail', params: {'p_run': runId}));

  /// One door for both buttons. `run` sends no break stage; `drill` sends the
  /// stage the backend should break on purpose. Which stage that is comes back
  /// from the payload, never from a literal here.
  Future<Map<String, dynamic>> runNow({String? breakStage}) async => _asMap(
      await _c.rpc('heartbeat_run_now', params: {'p_break_stage': breakStage}));
}

/// A backend-toned pill. Absent label → absent pill, so a run with nothing to
/// say about its cleanup simply shows no cleanup chip.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.tone});

  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final t = _tone(tone);
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: t.bg, borderRadius: Ds.r.rChip),
      child: Text(label,
          style:
              Ds.t.caption.copyWith(color: t.fg, fontWeight: FontWeight.w600)),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: child,
    );
    if (onTap == null) return box;
    return InkWell(
        onTap: onTap, borderRadius: Ds.r.rCard, child: box);
  }
}

class AdminHeartbeatScreen extends StatefulWidget {
  const AdminHeartbeatScreen({super.key, this.service});

  final HeartbeatService? service;

  @override
  State<AdminHeartbeatScreen> createState() => _AdminHeartbeatScreenState();
}

class _AdminHeartbeatScreenState extends State<AdminHeartbeatScreen> {
  late final HeartbeatService _svc = widget.service ?? HeartbeatService();

  Map<String, dynamic>? _p;
  bool _loading = true;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final p = await _svc.home();
      if (!mounted) return;
      setState(() {
        _p = p;
        _error = '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> _rows(dynamic raw) => raw is List
      ? raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false)
      : const <Map<String, dynamic>>[];

  Future<void> _fire(Map<String, dynamic> action) async {
    if (_busy) return;
    setState(() => _busy = true);
    // The drill's break stage is the payload's own: the LAST stage the backend
    // listed. Nothing here knows a stage key by name.
    String? breakStage;
    if ((action['key'] ?? '') == 'drill') {
      final stages = _rows(_p?['stages']);
      if (stages.isNotEmpty) {
        breakStage = (stages.last['key'] ?? '').toString();
      }
    }
    Map<String, dynamic> res = const {};
    try {
      res = await _svc.runNow(breakStage: breakStage);
    } catch (e) {
      res = {'summary_line': e.toString()};
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final line = (res['summary_line'] ?? '').toString();
    if (line.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(line)));
    }
    await _load();
  }

  void _openRun(Map<String, dynamic> run) {
    final id = run['id'];
    if (id is! int) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _RunSheet(service: _svc, runId: id),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final title = (p?['title'] ?? '').toString();

    if (_loading) {
      return Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(title: Text(title)),
        body: ListView(
          padding: EdgeInsets.all(Ds.space.x16),
          children: [
            for (var i = 0; i < 4; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                  height: Ds.space.x48 + Ds.space.x32,
                  decoration: BoxDecoration(
                      color: Ds.c.surface, borderRadius: Ds.r.rCard),
                ),
              ),
          ],
        ),
      );
    }

    if (p == null || _error.isNotEmpty || (p['ok'] != true)) {
      final heading = (p?['error_title'] ?? '').toString();
      return Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(heading, style: Ds.t.subtitle, textAlign: TextAlign.center),
                SizedBox(height: Ds.space.x8),
                Text(_error, style: Ds.t.caption, textAlign: TextAlign.center),
                SizedBox(height: Ds.space.x24),
                OutlinedButton(
                  onPressed: _load,
                  child: Text((p?['retry_label'] ?? '').toString()),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final runs = _rows(p['runs']);
    final stages = _rows(p['stages']);
    final actions = _rows(p['actions']);
    final last = p['last'] is Map
        ? Map<String, dynamic>.from(p['last'] as Map)
        : null;

    RenderLog.write('c468_heartbeat_screen', 1);
    RenderLog.write('c468_heartbeat_runs', runs.length);
    RenderLog.write('c468_heartbeat_stages', stages.length);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(title)),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.all(Ds.space.x16),
          children: [
            Text((p['subtitle'] ?? '').toString(), style: Ds.t.bodySecondary),
            SizedBox(height: Ds.space.x8),
            Text((p['schedule_label'] ?? '').toString(), style: Ds.t.caption),
            if ((p['disabled_note'] ?? '').toString().isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              _Pill(
                  label: (p['disabled_note'] ?? '').toString(),
                  tone: 'warning'),
            ],
            SizedBox(height: Ds.space.x24),

            if (last != null) _LastRunCard(run: last, onTap: () => _openRun(last)),
            if (last == null)
              _Card(
                child: Text((p['empty_label'] ?? '').toString(),
                    style: Ds.t.bodySecondary),
              ),

            SizedBox(height: Ds.space.x24),
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) SizedBox(height: Ds.space.x12),
              _ActionButton(
                  action: actions[i],
                  busy: _busy,
                  onTap: () => _fire(actions[i])),
            ],

            SizedBox(height: Ds.space.x32),
            Text((p['section_runs'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            for (final r in runs) ...[
              _RunRow(run: r, onTap: () => _openRun(r)),
              SizedBox(height: Ds.space.x8),
            ],

            SizedBox(height: Ds.space.x32),
            Text((p['section_stages'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < stages.length; i++) ...[
                    if (i > 0) Divider(height: Ds.space.x24, color: Ds.c.divider),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text((stages[i]['label'] ?? '').toString(),
                                  style: Ds.t.bodyStrong),
                              if ((stages[i]['note'] ?? '')
                                  .toString()
                                  .isNotEmpty) ...[
                                SizedBox(height: Ds.space.x4),
                                Text((stages[i]['note'] ?? '').toString(),
                                    style: Ds.t.caption),
                              ],
                            ],
                          ),
                        ),
                        SizedBox(width: Ds.space.x12),
                        Text((stages[i]['timeout_label'] ?? '').toString(),
                            style: Ds.t.caption),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(height: Ds.space.x32),
          ],
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton(
      {required this.action, required this.busy, required this.onTap});

  final Map<String, dynamic> action;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = (action['label'] ?? '').toString();
    final hint = (action['hint'] ?? '').toString();
    final isBrand = (action['tone'] ?? '') == 'brand';
    final button = SizedBox(
      width: double.infinity,
      height: Ds.touch.minTarget,
      child: isBrand
          ? FilledButton(onPressed: busy ? null : onTap, child: Text(label))
          : OutlinedButton(onPressed: busy ? null : onTap, child: Text(label)),
    );
    if (hint.isEmpty) return button;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        button,
        SizedBox(height: Ds.space.x4),
        Text(hint, style: Ds.t.caption),
      ],
    );
  }
}

class _LastRunCard extends StatelessWidget {
  const _LastRunCard({required this.run, required this.onTap});

  final Map<String, dynamic> run;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Card(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _Pill(
                label: (run['status_label'] ?? '').toString(),
                tone: (run['status_tone'] ?? '').toString()),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: Text((run['when_label'] ?? '').toString(),
                  style: Ds.t.caption, textAlign: TextAlign.right),
            ),
          ]),
          SizedBox(height: Ds.space.x12),
          Text((run['summary_line'] ?? '').toString(), style: Ds.t.body),
          SizedBox(height: Ds.space.x12),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              _Pill(label: (run['stage_label'] ?? '').toString(), tone: 'info'),
              _Pill(
                  label: (run['duration_label'] ?? '').toString(),
                  tone: 'neutral'),
              _Pill(
                  label: (run['alert_label'] ?? '').toString(),
                  tone: (run['alert_tone'] ?? '').toString()),
              _Pill(
                  label: (run['clean_label'] ?? '').toString(),
                  tone: (run['clean_tone'] ?? '').toString()),
            ],
          ),
        ],
      ),
    );
  }
}

class _RunRow extends StatelessWidget {
  const _RunRow({required this.run, required this.onTap});

  final Map<String, dynamic> run;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _Card(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Pill(
              label: (run['status_label'] ?? '').toString(),
              tone: (run['status_tone'] ?? '').toString()),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((run['summary_line'] ?? '').toString(),
                    style: Ds.t.body, maxLines: 3),
                SizedBox(height: Ds.space.x4),
                Text(
                    '${(run['when_label'] ?? '')} · ${(run['stage_label'] ?? '')}',
                    style: Ds.t.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One run, stage by stage — the backend's own list, in its own order.
class _RunSheet extends StatefulWidget {
  const _RunSheet({required this.service, required this.runId});

  final HeartbeatService service;
  final int runId;

  @override
  State<_RunSheet> createState() => _RunSheetState();
}

class _RunSheetState extends State<_RunSheet> {
  Map<String, dynamic>? _p;

  @override
  void initState() {
    super.initState();
    widget.service.detail(widget.runId).then((p) {
      if (mounted) setState(() => _p = p);
    }).catchError((_) {
      if (mounted) setState(() => _p = <String, dynamic>{});
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) {
      return SizedBox(
        height: Ds.space.x48 * 4,
        child: Center(
          child: SizedBox(
            width: Ds.space.x48 * 4,
            height: Ds.space.x12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                  color: Ds.c.bg, borderRadius: Ds.r.rChip),
            ),
          ),
        ),
      );
    }
    final run = p['run'] is Map
        ? Map<String, dynamic>.from(p['run'] as Map)
        : <String, dynamic>{};
    final stages = p['stages'] is List
        ? (p['stages'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList(growable: false)
        : const <Map<String, dynamic>>[];

    RenderLog.write('c468_heartbeat_detail_stages', stages.length);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((run['summary_line'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x8),
            Text((run['when_label'] ?? '').toString(), style: Ds.t.caption),
            SizedBox(height: Ds.space.x24),
            Text((p['section_stages'] ?? '').toString(), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x12),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: stages.length,
                separatorBuilder: (_, _) =>
                    Divider(height: Ds.space.x24, color: Ds.c.divider),
                itemBuilder: (_, i) {
                  final s = stages[i];
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text((s['label'] ?? '').toString(),
                                style: Ds.t.body),
                            if ((s['error'] ?? '').toString().isNotEmpty) ...[
                              SizedBox(height: Ds.space.x4),
                              Text((s['error'] ?? '').toString(),
                                  style:
                                      Ds.t.caption.copyWith(color: Ds.c.danger)),
                            ],
                          ],
                        ),
                      ),
                      SizedBox(width: Ds.space.x12),
                      Text((s['ms_label'] ?? '').toString(), style: Ds.t.caption),
                      SizedBox(width: Ds.space.x8),
                      _Pill(
                          label: (s['status_label'] ?? '').toString(),
                          tone: (s['status_tone'] ?? '').toString()),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
