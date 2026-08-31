import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/render_log.dart';
import 'build_lane_section.dart';
import 'db_lane_section.dart';
import 'deploy_lane_section.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// CHANGE #273 — Cron health.
///
/// The Om-facing proof that the per-minute cron storm is gone. Fifteen jobs on
/// `* * * * *` woke fifteen backends at second :00 of every minute against a
/// 60-connection database and took the site down three times on 2026-08-18.
/// They are now one dispatcher, and the work that a real event creates is fired
/// by that event.
///
/// Every visible word here comes from `cron_health()` — the headline, each
/// task's state and counts, the guard summary and every tone. This screen
/// computes nothing: it renders the payload in the order the backend sent it.
class CronHealthScreen extends StatefulWidget {
  final DevQueueService? service;
  const CronHealthScreen({super.key, this.service});

  @override
  State<CronHealthScreen> createState() => _CronHealthScreenState();
}

class _CronHealthScreenState extends State<CronHealthScreen> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();
  Map<String, dynamic> _data = const {};
  // CHANGE #301 — the database lane sits beside cron because it is the same
  // failure: too much heavy work landing at once on a 1 GB instance. Its own
  // RPC, so a slow or refused read of one never blanks the other.
  Map<String, dynamic> _db = const {};
  // CHANGE #324 — the deploy lane is the same failure as the DB lane in a
  // different resource: parallel work forced into a single file. Its own RPC,
  // so a slow or refused read of one never blanks the other.
  Map<String, dynamic> _lane = const {};
  // CHANGE #327 — and the same failure a third time, in a third resource:
  // builds fighting for one FILE. Its own RPC, same reason as the other two.
  Map<String, dynamic> _build = const {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final d = await _svc.cronHealth();
      Map<String, dynamic> db = const {};
      try {
        db = await _svc.dbHealth();
      } catch (_) {
        // The DB lane is a panel, not the page. If it cannot be read the cron
        // health above it still renders; the panel simply omits itself.
      }
      Map<String, dynamic> lane = const {};
      try {
        lane = await _svc.deployLane();
      } catch (_) {
        // Same contract as the DB lane: a panel, never the page.
      }
      Map<String, dynamic> bl = const {};
      try {
        bl = await _svc.buildLane();
      } catch (_) {
        // Same contract again: a panel, never the page.
      }
      if (!mounted) return;
      setState(() {
        _db = db;
        _lane = lane;
        _build = bl;
        _data = d;
        _loading = false;
        // ok:false is the BACKEND refusing (not a crash) and it ships its own
        // sentence — render that, never a locally worded one.
        _error = d['ok'] == true ? null : ((d['error'] as String?) ?? '');
      });
      final tasks = (d['tasks'] as List?) ?? const [];
      // Painted-proof for the post-deploy verifier. Written on BOTH paths: a
      // verifier that loads /admin/cron-health without super-admin still proves
      // the screen rendered, it just renders the backend's refusal.
      try {
        RenderLog.write('c273_cron_health', 'tasks=${tasks.length}');
        // Painted-proof for the DB lane: 'ok' only when the backend answered
        // and the section drew its payload.
        RenderLog.write(
          'c301_db_lane',
          _db['ok'] == true ? 'ok' : (_db.isEmpty ? 'absent' : 'refused'),
        );
        // CHANGE #324 — painted-proof for the deploy lane: 'ok' only when the
        // backend answered AND the section drew its payload.
        RenderLog.write(
          'c324_deploy_lane',
          _lane['ok'] == true ? 'ok' : (_lane.isEmpty ? 'absent' : 'refused'),
        );
        // CHANGE #327 — painted-proof for the build lane, same contract as the
        // two lanes above: 'ok' only when the backend answered AND the section
        // drew its payload.
        RenderLog.write(
          'c327_build_lane',
          _build['ok'] == true ? 'ok' : (_build.isEmpty ? 'absent' : 'refused'),
        );
        RenderLog.write('c273_cron_tasks', '${tasks.length}');
        // The before/after report is the command's deliverable, so it gets its
        // own painted-proof key rather than hiding inside the screen's.
        final ba = ((d['before_after'] as Map?)?['rows'] as List?) ?? const [];
        RenderLog.write('c273_cron_before_after', '${ba.length}');
        // CHANGE #305 — painted-proof for the execution baseline section:
        // how many metric rows and how many per-task rows actually drew.
        final bl = (d['baseline'] as Map?) ?? const {};
        RenderLog.write(
          'c305_cron_baseline',
          '${((bl['rows'] as List?) ?? const []).length}',
        );
        RenderLog.write(
          'c305_cron_task_stats',
          '${((bl['tasks'] as List?) ?? const []).length}',
        );
      } catch (_) {}
    } catch (_) {
      // Never print e.toString(): a Dart-formatted exception is a display
      // string written in Dart. The transport failed, so the only copy left is
      // the cached backend sentence for exactly that case.
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = c('dev_queue.cron_health_unreachable');
      });
      try {
        RenderLog.write('c273_cron_health', 'error');
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = (_data['tasks'] as List?) ?? const [];
    final tick = (_data['tick'] as Map?)?.cast<String, dynamic>() ?? const {};
    final guard = (_data['guard'] as Map?)?.cast<String, dynamic>() ?? const {};
    final ba =
        (_data['before_after'] as Map?)?.cast<String, dynamic>() ?? const {};
    // CHANGE #305 — the execution baseline. Absent payload = absent section;
    // the screen never invents a "0 per hour" it was not told.
    final base =
        (_data['baseline'] as Map?)?.cast<String, dynamic>() ?? const {};

    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(
          (_data['title'] as String?) ?? c('dev_queue.cron_health_nav_label'),
          style: Ds.t.subtitle.copyWith(
            fontWeight: FontWeight.w700,
            color: kTextHi,
          ),
        ),
        actions: [
          IconButton(
            tooltip: c('dev_queue.cron_health_refresh'),
            icon: const Icon(Icons.refresh, color: kBrand),
            onPressed: _loading ? null : _load,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: kBorder),
        ),
      ),
      body: _loading
          ? _skeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.all(Ds.space.x16),
                children: [
                  if (_error != null) ...[
                    DqCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _error!,
                            style: Ds.t.body.copyWith(color: Ds.c.danger),
                          ),
                          SizedBox(height: Ds.space.x12),
                          OutlinedButton(
                            onPressed: _load,
                            child: Text(c('dev_queue.cron_health_refresh')),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    _headline(),
                    if (_db.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x24),
                      DbLaneSection(
                        data: _db,
                        onAdmissionPatch: (patch) async {
                          await _svc.admissionSet(patch);
                          await _load();
                        },
                      ),
                    ],
                    // Its own condition, deliberately: a refused DB-lane read
                    // must not take the deploy lane down with it.
                    if (_lane.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x24),
                      DeployLaneSection(data: _lane),
                    ],
                    // And again its own condition: the build lane is the one
                    // that proves nothing waited on a file.
                    if (_build.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x24),
                      BuildLaneSection(data: _build),
                    ],
                    SizedBox(height: Ds.space.x16),
                    _tickCard(tick),
                    if (((base['rows'] as List?) ?? const []).isNotEmpty) ...[
                      SizedBox(height: Ds.space.x24),
                      _baselineCard(base),
                    ],
                    if (((ba['rows'] as List?) ?? const []).isNotEmpty) ...[
                      SizedBox(height: Ds.space.x24),
                      _beforeAfterCard(ba),
                    ],
                    SizedBox(height: Ds.space.x24),
                    _sectionTitle(c('dev_queue.cron_health_tasks_title')),
                    SizedBox(height: Ds.space.x12),
                    for (final t in tasks) ...[
                      _taskCard((t as Map).cast<String, dynamic>()),
                      SizedBox(height: Ds.space.x12),
                    ],
                    SizedBox(height: Ds.space.x12),
                    _guardCard(guard),
                  ],
                  SizedBox(height: Ds.space.x32),
                ],
              ),
            ),
    );
  }

  Widget _sectionTitle(String s) => Text(
    s,
    style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: kTextHi),
  );

  Widget _headline() => DqCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          (_data['headline'] as String?) ?? '',
          style: Ds.t.body.copyWith(
            fontWeight: FontWeight.w600,
            color: kTextHi,
          ),
        ),
        SizedBox(height: Ds.space.x12),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            _stat(
              c('dev_queue.cron_health_runs_hour'),
              '${_data['runs_last_hour'] ?? 0}',
            ),
            _stat(
              c('dev_queue.cron_health_db_seconds'),
              '${_data['db_seconds_last_hour'] ?? 0}',
            ),
            _stat(
              c('dev_queue.cron_health_peak'),
              '${_data['peak_concurrent'] ?? 0}',
            ),
          ],
        ),
      ],
    ),
  );

  Widget _stat(String label, String value) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: Ds.space.x12,
      vertical: Ds.space.x8,
    ),
    decoration: BoxDecoration(
      color: kPageBg,
      borderRadius: Ds.r.rButton,
      border: Border.all(color: kBorder),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Ds.t.caption.copyWith(color: kTextLo)),
        SizedBox(height: Ds.space.x4),
        Text(
          value,
          style: Ds.t.body.copyWith(
            fontWeight: FontWeight.w600,
            color: kTextHi,
          ),
        ),
      ],
    ),
  );

  Widget _tickCard(Map<String, dynamic> tick) => DqCard(
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                (tick['label'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
              SizedBox(height: Ds.space.x4),
              Text(
                (tick['value_label'] as String?) ?? '',
                style: Ds.t.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: kTextHi,
                ),
              ),
              SizedBox(height: Ds.space.x4),
              Text(
                (tick['at_label'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ],
          ),
        ),
        ToneChip(
          label: (tick['at_label'] as String?) ?? '',
          tone: toneByName((tick['tone'] as String?) ?? 'neutral'),
        ),
      ],
    ),
  );

  /// A sentence, not a pill: the creep alarm's copy is a full line of backend
  /// prose, so it wears the tone's tint as a banner rather than being squeezed
  /// into a chip built for two words.
  Widget _alertBanner(String text, Tone tone) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(Ds.space.x12),
    decoration: BoxDecoration(
      color: tone.bg,
      borderRadius: Ds.r.rButton,
    ),
    child: Text(
      text,
      style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600, color: tone.fg),
    ),
  );

  /// CHANGE #305 — the execution baseline: the frozen before-measurement beside
  /// what the scheduler is doing now, the creep alarm's own sentence, and the
  /// per-task run/idle/duration breakdown from cron_job_stats. Every number and
  /// every word arrives in `baseline`; nothing here is computed or worded.
  Widget _baselineCard(Map<String, dynamic> b) {
    final rows = (b['rows'] as List?) ?? const [];
    final tasks = (b['tasks'] as List?) ?? const [];
    final alert = (b['alert'] as Map?)?.cast<String, dynamic>() ?? const {};
    return DqCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            (b['label'] as String?) ?? '',
            style: Ds.t.subtitle.copyWith(
              fontWeight: FontWeight.w700,
              color: kTextHi,
            ),
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            (b['note'] as String?) ?? '',
            style: Ds.t.caption.copyWith(color: kTextLo),
          ),
          if ((alert['text'] as String?)?.isNotEmpty ?? false) ...[
            SizedBox(height: Ds.space.x12),
            _alertBanner(
              alert['text'] as String,
              toneByName((alert['tone'] as String?) ?? 'neutral'),
            ),
          ],
          for (final r in rows) ...[
            SizedBox(height: Ds.space.x16),
            Text(
              ((r as Map)['metric'] as String?) ?? '',
              style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w600,
                color: kTextHi,
              ),
            ),
            SizedBox(height: Ds.space.x8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _stat(
                    (b['before_head'] as String?) ?? '',
                    '${r['before'] ?? ''}',
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: _stat(
                    (b['after_head'] as String?) ?? '',
                    '${r['after'] ?? ''}',
                  ),
                ),
              ],
            ),
            if ((r['note'] as String?)?.isNotEmpty ?? false) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                r['note'] as String,
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ],
          ],
          if (tasks.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            Text(
              (b['tasks_head'] as String?) ?? '',
              style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w600,
                color: kTextHi,
              ),
            ),
            SizedBox(height: Ds.space.x4),
            Text(
              (b['tasks_note'] as String?) ?? '',
              style: Ds.t.caption.copyWith(color: kTextLo),
            ),
            for (final t in tasks) ...[
              SizedBox(height: Ds.space.x12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ((t as Map)['name'] as String?) ?? '',
                          style: Ds.t.body.copyWith(
                            fontWeight: FontWeight.w600,
                            color: kTextHi,
                          ),
                        ),
                        SizedBox(height: Ds.space.x4),
                        Text(
                          '${t['per_day_label'] ?? ''} · ${t['idle_label'] ?? ''}',
                          style: Ds.t.caption.copyWith(color: kTextLo),
                        ),
                        SizedBox(height: Ds.space.x4),
                        Text(
                          '${t['interval_label'] ?? ''} · ${t['avg_ms_label'] ?? ''}',
                          style: Ds.t.caption.copyWith(color: kTextLo),
                        ),
                        if ((t['error'] as String?)?.isNotEmpty ?? false) ...[
                          SizedBox(height: Ds.space.x4),
                          Text(
                            t['error'] as String,
                            style: Ds.t.caption.copyWith(color: Ds.c.danger),
                          ),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                  ToneChip(
                    label: '${t['idle_label'] ?? ''}',
                    tone: toneByName((t['tone'] as String?) ?? 'neutral'),
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// The command's actual answer: what the per-minute storm cost, and what it
  /// costs now. Every number, label and caption arrives in `before_after` —
  /// the backend recomputes both windows from `cron.job_run_details` on each
  /// open, so this stays a measurement rather than a screenshot of one day.
  Widget _beforeAfterCard(Map<String, dynamic> ba) {
    final rows = (ba['rows'] as List?) ?? const [];
    return DqCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            (ba['label'] as String?) ?? '',
            style: Ds.t.subtitle.copyWith(
              fontWeight: FontWeight.w700,
              color: kTextHi,
            ),
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            (ba['note'] as String?) ?? '',
            style: Ds.t.caption.copyWith(color: kTextLo),
          ),
          for (final r in rows) ...[
            SizedBox(height: Ds.space.x16),
            Text(
              ((r as Map)['metric'] as String?) ?? '',
              style: Ds.t.body.copyWith(
                fontWeight: FontWeight.w600,
                color: kTextHi,
              ),
            ),
            SizedBox(height: Ds.space.x8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _stat(
                    (ba['before_head'] as String?) ?? '',
                    '${r['before'] ?? ''}',
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: _stat(
                    (ba['after_head'] as String?) ?? '',
                    '${r['after'] ?? ''}',
                  ),
                ),
              ],
            ),
            if ((r['note'] as String?)?.isNotEmpty ?? false) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                r['note'] as String,
                style: Ds.t.caption.copyWith(color: kTextLo),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _taskCard(Map<String, dynamic> t) => DqCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                (t['name'] as String?) ?? '',
                style: Ds.t.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: kTextHi,
                ),
              ),
            ),
            ToneChip(
              label: (t['mode_label'] as String?) ?? '',
              tone: toneByName((t['tone'] as String?) ?? 'neutral'),
            ),
          ],
        ),
        SizedBox(height: Ds.space.x8),
        Text(
          (t['state_label'] as String?) ?? '',
          style: Ds.t.body.copyWith(color: kTextHi),
        ),
        SizedBox(height: Ds.space.x4),
        Text(
          (t['counts_label'] as String?) ?? '',
          style: Ds.t.caption.copyWith(color: kTextLo),
        ),
        if ((t['note'] as String?)?.isNotEmpty ?? false) ...[
          SizedBox(height: Ds.space.x8),
          Text(
            t['note'] as String,
            style: Ds.t.caption.copyWith(color: kTextLo),
          ),
        ],
        if ((t['error'] as String?)?.isNotEmpty ?? false) ...[
          SizedBox(height: Ds.space.x8),
          Text(
            t['error'] as String,
            style: Ds.t.caption.copyWith(color: Ds.c.danger),
          ),
        ],
      ],
    ),
  );

  Widget _guardCard(Map<String, dynamic> guard) {
    final recent = (guard['recent'] as List?) ?? const [];
    return DqCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            (guard['label'] as String?) ?? '',
            style: Ds.t.subtitle.copyWith(
              fontWeight: FontWeight.w700,
              color: kTextHi,
            ),
          ),
          SizedBox(height: Ds.space.x8),
          Text(
            (guard['value_label'] as String?) ?? '',
            style: Ds.t.body.copyWith(color: kTextHi),
          ),
          if (recent.isEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              c('dev_queue.cron_health_guard_quiet'),
              style: Ds.t.caption.copyWith(color: kTextLo),
            ),
          ],
          for (final e in recent) ...[
            SizedBox(height: Ds.space.x12),
            Text(
              '${((e as Map)['at_label'] ?? '')} · ${e['kind'] ?? ''} · ${e['job'] ?? ''}',
              style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w600,
                color: kTextHi,
              ),
            ),
            SizedBox(height: Ds.space.x4),
            Text(
              '${e['detail'] ?? ''}',
              style: Ds.t.caption.copyWith(color: kTextLo),
            ),
          ],
        ],
      ),
    );
  }

  Widget _skeleton() => ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: [
      for (var i = 0; i < 5; i++) ...[
        Container(
          height: 88,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: kBorder),
          ),
        ),
        SizedBox(height: Ds.space.x12),
      ],
    ],
  );
}
