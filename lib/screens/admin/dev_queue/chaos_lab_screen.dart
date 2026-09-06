import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/session_recorder.dart';
import '../../../services/ui_copy.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// CHANGE #638 — the Chaos lab, and it is a PRINTER.
///
/// Two halves, one payload. The seven chaos scenarios with the last run's
/// verdict on each; and the recorded walkthroughs, live and past, each with its
/// own promote decision. `chaos_home()` writes every word on this screen: the
/// title, the subtitle, the test-mode line, the session line, the run chip and
/// its counts, each scenario's label, blurb, expectation, verdict WORD and
/// verdict TONE, each evidence row's own label and value, the duration string,
/// the recording chips, "3 steps", every disabled_reason, the two empty states
/// and the footnote.
///
/// Nothing here counts, pluralises, orders, or decides that a scenario "looks
/// red". An eighth scenario is one INSERT into chaos_scenario — a screen that
/// recomputed any of this would start lying the moment somebody adds it.
///
/// The only local decisions are the two every Dev Queue surface takes: which
/// glyph to draw, and how to turn a tone NAME into the fixed palette.
typedef ChaosLoad = Future<Map<String, dynamic>> Function();

class ChaosLabScreen extends StatefulWidget {
  final DevQueueService? service;

  /// Test seam. When absent the screen builds its own service on first load —
  /// never in initState, so a VM test never touches Supabase.instance.
  final ChaosLoad? load;

  const ChaosLabScreen({super.key, this.service, this.load});

  @override
  State<ChaosLabScreen> createState() => _ChaosLabScreenState();
}

class _ChaosLabScreenState extends State<ChaosLabScreen> {
  DevQueueService? _svcCache;
  DevQueueService get _svc => _svcCache ??= (widget.service ?? DevQueueService());

  Map<String, dynamic> _payload = const {};
  bool _loading = true;
  bool _busy = false;
  String _error = '';
  final Set<String> _open = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final p =
          widget.load != null ? await widget.load!() : await _svc.chaosHome();
      if (!mounted) return;
      setState(() {
        _payload = p;
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

  String _s(String key) => (_payload[key] ?? '').toString();

  List<Map<String, dynamic>> _list(dynamic raw) => ((raw as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  Map<String, dynamic> _map(dynamic raw) =>
      Map<String, dynamic>.from((raw as Map?) ?? const <String, dynamic>{});

  /// Every toast on this screen is the backend's own `message`. There is no
  /// Dart wording to fall back to, on purpose: a refusal nobody wrote is a
  /// refusal nobody can change without a deploy.
  void _say(Map<String, dynamic> reply) {
    final msg = (reply['message'] ?? '').toString();
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _guard(Future<Map<String, dynamic>> Function() run) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _say(await run());
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _runAll() => _guard(() => _svc.chaosRunAll());

  Future<void> _startRecording() => _guard(() async {
        final reply = await _svc.recordingStart('');
        final id = reply['recording_id'];
        if (id is int) {
          SessionRecorder.instance.start(
            id,
            ({required kind, required screen, required action, required ok}) =>
                _svc.recordingStep(
                  recording: id,
                  kind: kind,
                  screen: screen,
                  action: action,
                  ok: ok,
                ),
          );
        }
        return reply;
      });

  Future<void> _stopRecording(int id, {required bool broke}) => _guard(() async {
        SessionRecorder.instance.stop();
        return _svc.recordingStop(id, outcome: broke ? 'broke' : 'ok');
      });

  Future<void> _promote(int id, String label) =>
      _guard(() => _svc.recordingPromote(id, title: label));

  @override
  Widget build(BuildContext context) {
    final mode = _map(_payload['test_mode']);
    final session = _map(_payload['session']);
    final run = _map(_payload['run']);
    final action = _map(_payload['action']);
    final scenarios = _list(_payload['scenarios']);
    final rec = _map(_payload['recording']);
    final gaps = _map(_payload['gaps']);

    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(_s('title'),
            style: Ds.t.subtitle
                .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
        actions: [
          Semantics(
            identifier: 'chaos_lab_refresh',
            button: true,
            child: IconButton(
              icon: const Icon(Icons.refresh, color: kBrand),
              onPressed: _busy ? null : _load,
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const _ChaosSkeleton()
            : _error.isNotEmpty
                ? _ChaosError(message: _error, onRetry: _load)
                : RefreshIndicator(
                    color: kBrand,
                    onRefresh: _load,
                    child: ListView(
                      padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16,
                          Ds.space.x16, Ds.space.x32),
                      children: [
                        _headCard(mode, session, run, action),
                        SizedBox(height: Ds.space.x24),
                        if (scenarios.isEmpty)
                          Padding(
                            padding:
                                EdgeInsets.symmetric(vertical: Ds.space.x32),
                            child: Text(_s('scenarios_empty'),
                                textAlign: TextAlign.center,
                                style: Ds.t.body.copyWith(color: kTextLo)),
                          )
                        else
                          for (final s in scenarios) _scenarioCard(s),
                        SizedBox(height: Ds.space.x24),
                        _recordingSection(rec),
                        SizedBox(height: Ds.space.x24),
                        _gapsSection(gaps),
                        SizedBox(height: Ds.space.x24),
                        Text(_s('footnote'),
                            style: Ds.t.caption.copyWith(color: kTextLo)),
                      ],
                    ),
                  ),
      ),
    );
  }

  // ── the head: test mode, the session, the last run, and the one button ────

  Widget _headCard(Map<String, dynamic> mode, Map<String, dynamic> session,
      Map<String, dynamic> run, Map<String, dynamic> action) {
    final modeTone = toneByName((mode['tone'] ?? 'neutral').toString());
    final runTone = toneByName((run['chip_tone'] ?? 'neutral').toString());
    final enabled = action['enabled'] == true && !_busy;
    final why = (action['disabled_reason'] ?? '').toString();
    return DqCard(
      accent: modeTone.fg,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(_s('subtitle'), style: Ds.t.body.copyWith(color: kTextHi)),
          ),
          SizedBox(width: Ds.space.x8),
          ToneChip(
              label: (mode['label'] ?? '').toString(),
              tone: modeTone,
              icon: Icons.science_outlined),
        ]),
        SizedBox(height: Ds.space.x8),
        Text((mode['sub'] ?? '').toString(),
            style: Ds.t.caption.copyWith(color: kTextLo)),
        SizedBox(height: Ds.space.x16),
        _line((session['label'] ?? '').toString(),
            (session['sub'] ?? '').toString(), Icons.timelapse_outlined),
        if (run['has'] == true) ...[
          SizedBox(height: Ds.space.x12),
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((run['label'] ?? '').toString(),
                        style: Ds.t.body.copyWith(
                            color: kTextHi, fontWeight: FontWeight.w600)),
                    SizedBox(height: Ds.space.x4),
                    Text((run['sub'] ?? '').toString(),
                        style: Ds.t.caption.copyWith(color: kTextLo)),
                    if ((run['counts_label'] ?? '').toString().isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text((run['counts_label'] ?? '').toString(),
                          style: Ds.t.caption.copyWith(color: kTextLo)),
                    ],
                  ]),
            ),
            SizedBox(width: Ds.space.x8),
            ToneChip(label: (run['chip'] ?? '').toString(), tone: runTone),
          ]),
        ],
        SizedBox(height: Ds.space.x16),
        Semantics(
          identifier: 'chaos_run_all',
          button: true,
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: enabled ? _runAll : null,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.bolt_outlined, size: 18),
              label: Text((action['label'] ?? '').toString()),
              style: ElevatedButton.styleFrom(
                backgroundColor: kBrand,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
            ),
          ),
        ),
        if (!enabled && why.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(why, style: Ds.t.caption.copyWith(color: kTextLo)),
        ],
      ]),
    );
  }

  Widget _line(String label, String sub, IconData glyph) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(glyph, size: 16, color: kTextLo),
      SizedBox(width: Ds.space.x8),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Ds.t.body.copyWith(color: kTextHi)),
          if (sub.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(sub, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
        ]),
      ),
    ]);
  }

  // ── one scenario ─────────────────────────────────────────────────────────

  Widget _scenarioCard(Map<String, dynamic> s) {
    final key = (s['key'] ?? '').toString();
    final tone = toneByName((s['verdict_tone'] ?? 'neutral').toString());
    final evidence = _list(s['evidence']);
    final expanded = _open.contains(key);
    final summary = (s['summary'] ?? '').toString();
    final gap = (s['gap_label'] ?? '').toString();
    final duration = (s['duration_label'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DqCard(
        onTap: evidence.isEmpty
            ? null
            : () => setState(() =>
                expanded ? _open.remove(key) : _open.add(key)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((s['label'] ?? '').toString(),
                        style: Ds.t.body.copyWith(
                            color: kTextHi, fontWeight: FontWeight.w600)),
                    SizedBox(height: Ds.space.x4),
                    Text((s['family_label'] ?? '').toString(),
                        style: Ds.t.caption.copyWith(color: kTextLo)),
                  ]),
            ),
            SizedBox(width: Ds.space.x8),
            ToneChip(label: (s['verdict_label'] ?? '').toString(), tone: tone),
          ]),
          SizedBox(height: Ds.space.x12),
          Text((s['blurb'] ?? '').toString(),
              style: Ds.t.caption.copyWith(color: kTextLo)),
          SizedBox(height: Ds.space.x8),
          _line((s['expect_label'] ?? '').toString(), '',
              Icons.check_circle_outline),
          if (summary.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(color: tone.bg, borderRadius: Ds.r.rButton),
              child: Text(summary,
                  style: Ds.t.caption.copyWith(color: tone.fg)),
            ),
          ],
          if (duration.isNotEmpty || gap.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
              if (duration.isNotEmpty)
                Text(duration, style: Ds.t.caption.copyWith(color: kTextLo)),
              if (gap.isNotEmpty)
                Text(gap,
                    style: Ds.t.caption.copyWith(
                        color: toneByName('danger').fg,
                        fontWeight: FontWeight.w600)),
            ]),
          ],
          if (expanded && evidence.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            for (final e in evidence)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x4),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 150,
                        child: Text((e['label'] ?? '').toString(),
                            style: Ds.t.caption.copyWith(color: kTextLo)),
                      ),
                      Expanded(
                        child: Text((e['value'] ?? '').toString(),
                            style: Ds.t.caption.copyWith(color: kTextHi)),
                      ),
                    ]),
              ),
          ],
        ]),
      ),
    );
  }

  // ── recorded walkthroughs ────────────────────────────────────────────────

  Widget _recordingSection(Map<String, dynamic> rec) {
    final live = _map(rec['live']);
    final start = _map(rec['start']);
    final stop = _map(rec['stop']);
    final rows = _list(rec['rows']);
    final liveOn = live['has'] == true;
    final liveId = live['id'] is int ? live['id'] as int : null;
    final canStart = start['enabled'] == true && !_busy;
    final why = (start['disabled_reason'] ?? '').toString();
    final steps = _list(live['steps']);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text((rec['title'] ?? '').toString(),
          style:
              Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
      SizedBox(height: Ds.space.x8),
      Text((rec['blurb'] ?? '').toString(),
          style: Ds.t.caption.copyWith(color: kTextLo)),
      SizedBox(height: Ds.space.x12),
      DqCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (liveOn) ...[
            Row(children: [
              Expanded(
                child: Text((live['label'] ?? '').toString(),
                    style: Ds.t.body.copyWith(
                        color: kTextHi, fontWeight: FontWeight.w600)),
              ),
              ToneChip(
                  label: (live['step_label'] ?? '').toString(),
                  tone: toneByName('brand'),
                  spinning: true),
            ]),
            SizedBox(height: Ds.space.x12),
            if (steps.isEmpty)
              Text((live['steps_empty'] ?? '').toString(),
                  style: Ds.t.caption.copyWith(color: kTextLo))
            else
              for (final st in steps)
                Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x4),
                  child: Row(children: [
                    SizedBox(
                      width: 28,
                      child: Text('${st['n']}',
                          style: Ds.t.caption.copyWith(color: kTextLo)),
                    ),
                    Expanded(
                      child: Text((st['label'] ?? '').toString(),
                          style: Ds.t.caption.copyWith(
                              color: toneByName((st['tone'] ?? 'neutral').toString())
                                  .fg)),
                    ),
                    Text((st['sub'] ?? '').toString(),
                        style: Ds.t.caption.copyWith(color: kTextLo)),
                  ]),
                ),
            SizedBox(height: Ds.space.x16),
            Row(children: [
              Expanded(
                child: Semantics(
                  identifier: 'chaos_recording_stop',
                  button: true,
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      onPressed: (stop['enabled'] == true && liveId != null && !_busy)
                          ? () => _stopRecording(liveId, broke: false)
                          : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: kBrand,
                        side: const BorderSide(color: kBrand),
                        shape:
                            RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                      ),
                      child: Text((stop['label'] ?? '').toString()),
                    ),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Semantics(
                  identifier: 'chaos_recording_broke',
                  button: true,
                  child: SizedBox(
                    height: 44,
                    child: OutlinedButton(
                      onPressed: (stop['enabled'] == true && liveId != null && !_busy)
                          ? () => _stopRecording(liveId, broke: true)
                          : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: toneByName('danger').fg,
                        side: BorderSide(color: toneByName('danger').fg),
                        shape:
                            RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                      ),
                      child: Text((rec['broke_label'] ?? '').toString()),
                    ),
                  ),
                ),
              ),
            ]),
          ] else ...[
            Semantics(
              identifier: 'chaos_recording_start',
              button: true,
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: canStart ? _startRecording : null,
                  icon: const Icon(Icons.fiber_manual_record_outlined, size: 18),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kBrand,
                    side: const BorderSide(color: kBrand),
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  label: Text((start['label'] ?? '').toString()),
                ),
              ),
            ),
            if (!canStart && why.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(why, style: Ds.t.caption.copyWith(color: kTextLo)),
            ],
          ],
        ]),
      ),
      SizedBox(height: Ds.space.x12),
      if (rows.isEmpty)
        Padding(
          padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
          child: Text((rec['empty_label'] ?? '').toString(),
              textAlign: TextAlign.center,
              style: Ds.t.body.copyWith(color: kTextLo)),
        )
      else
        for (final r in rows) _recordingRow(r),
    ]);
  }

  Widget _recordingRow(Map<String, dynamic> r) {
    final promote = _map(r['promote']);
    final id = r['id'] is int ? r['id'] as int : null;
    final can = promote['can'] == true && id != null && !_busy;
    final why = (promote['disabled_reason'] ?? '').toString();
    final journey = (r['journey_label'] ?? '').toString();
    final note = (r['note'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DqCard(
        padding: EdgeInsets.all(Ds.space.x12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((r['label'] ?? '').toString(),
                        style: Ds.t.body.copyWith(
                            color: kTextHi, fontWeight: FontWeight.w600)),
                    SizedBox(height: Ds.space.x4),
                    Text((r['sub'] ?? '').toString(),
                        style: Ds.t.caption.copyWith(color: kTextLo)),
                  ]),
            ),
            SizedBox(width: Ds.space.x8),
            ToneChip(
                label: (r['chip'] ?? '').toString(),
                tone: toneByName((r['chip_tone'] ?? 'neutral').toString())),
          ]),
          SizedBox(height: Ds.space.x8),
          Text((r['steps_label'] ?? '').toString(),
              style: Ds.t.caption.copyWith(color: kTextLo)),
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(note, style: Ds.t.caption.copyWith(color: kTextHi)),
          ],
          if (journey.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(journey,
                style: Ds.t.caption.copyWith(
                    color: toneByName('success').fg,
                    fontWeight: FontWeight.w600)),
          ],
          if (can) ...[
            SizedBox(height: Ds.space.x12),
            Semantics(
              identifier: 'chaos_recording_promote',
              button: true,
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton.icon(
                  onPressed: () => _promote(id, (r['label'] ?? '').toString()),
                  icon: const Icon(Icons.playlist_add_check_outlined, size: 18),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kBrand,
                    side: const BorderSide(color: kBrand),
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  label: Text((promote['label'] ?? '').toString()),
                ),
              ),
            ),
          ] else if (why.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(why, style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
        ]),
      ),
    );
  }

  // ── what the two halves have filed ───────────────────────────────────────

  Widget _gapsSection(Map<String, dynamic> gaps) {
    final rows = _list(gaps['rows']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text((gaps['label'] ?? '').toString(),
          style:
              Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
      SizedBox(height: Ds.space.x12),
      if (rows.isEmpty)
        Text((gaps['empty_label'] ?? '').toString(),
            style: Ds.t.caption.copyWith(color: kTextLo))
      else
        for (final g in rows)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: DqCard(
              padding: EdgeInsets.all(Ds.space.x12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((g['title'] ?? '').toString(),
                            style: Ds.t.body.copyWith(color: kTextHi)),
                        SizedBox(height: Ds.space.x4),
                        Text((g['sub'] ?? '').toString(),
                            style: Ds.t.caption.copyWith(color: kTextLo)),
                      ]),
                ),
                SizedBox(width: Ds.space.x8),
                ToneChip(
                    label: (g['chip'] ?? '').toString(),
                    tone: toneByName((g['chip_tone'] ?? 'neutral').toString())),
              ]),
            ),
          ),
    ]);
  }
}

class _ChaosSkeleton extends StatelessWidget {
  const _ChaosSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (var i = 0; i < 5; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: 96,
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: Ds.r.rCard,
                  border: Border.all(color: kBorder)),
            ),
          ),
      ],
    );
  }
}

class _ChaosError extends StatelessWidget {
  const _ChaosError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // The backend's own words, not a Dart fallback sentence.
          Text(message,
              textAlign: TextAlign.center,
              style: Ds.t.caption.copyWith(color: kTextLo)),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: 44,
            child: OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: kBrand),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton)),
              child: Text(c('dev_queue.retry'),
                  style: Ds.t.body
                      .copyWith(color: kBrand, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
      ),
    );
  }
}
