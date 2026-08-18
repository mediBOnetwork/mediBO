import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/render_log.dart';
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
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
        _error = d['ok'] == true ? null : (d['error'] as String?);
      });
      final tasks = (d['tasks'] as List?) ?? const [];
      try {
        RenderLog.write('c273_cron_health', 'tasks=${tasks.length}');
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tasks = (_data['tasks'] as List?) ?? const [];
    final tick = (_data['tick'] as Map?)?.cast<String, dynamic>() ?? const {};
    final guard = (_data['guard'] as Map?)?.cast<String, dynamic>() ?? const {};

    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: kBrand),
        title: Text(
          (_data['title'] as String?) ?? c('dev_queue.cron_health_nav_label'),
          style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: kTextHi),
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
                          Text(_error!,
                              style: Ds.t.body.copyWith(color: Ds.c.danger)),
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
                    SizedBox(height: Ds.space.x16),
                    _tickCard(tick),
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

  Widget _sectionTitle(String s) => Text(s,
      style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: kTextHi));

  Widget _headline() => DqCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((_data['headline'] as String?) ?? '',
                style: Ds.t.body.copyWith(
                    fontWeight: FontWeight.w600, color: kTextHi)),
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                _stat(c('dev_queue.cron_health_runs_hour'),
                    '${_data['runs_last_hour'] ?? 0}'),
                _stat(c('dev_queue.cron_health_db_seconds'),
                    '${_data['db_seconds_last_hour'] ?? 0}'),
                _stat(c('dev_queue.cron_health_peak'),
                    '${_data['peak_concurrent'] ?? 0}'),
              ],
            ),
          ],
        ),
      );

  Widget _stat(String label, String value) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
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
            Text(value,
                style: Ds.t.body.copyWith(
                    fontWeight: FontWeight.w600, color: kTextHi)),
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
                  Text((tick['label'] as String?) ?? '',
                      style: Ds.t.caption.copyWith(color: kTextLo)),
                  SizedBox(height: Ds.space.x4),
                  Text((tick['value_label'] as String?) ?? '',
                      style: Ds.t.body.copyWith(
                          fontWeight: FontWeight.w600, color: kTextHi)),
                  SizedBox(height: Ds.space.x4),
                  Text((tick['at_label'] as String?) ?? '',
                      style: Ds.t.caption.copyWith(color: kTextLo)),
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

  Widget _taskCard(Map<String, dynamic> t) => DqCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text((t['name'] as String?) ?? '',
                      style: Ds.t.body.copyWith(
                          fontWeight: FontWeight.w600, color: kTextHi)),
                ),
                ToneChip(
                  label: (t['mode_label'] as String?) ?? '',
                  tone: toneByName((t['tone'] as String?) ?? 'neutral'),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            Text((t['state_label'] as String?) ?? '',
                style: Ds.t.body.copyWith(color: kTextHi)),
            SizedBox(height: Ds.space.x4),
            Text((t['counts_label'] as String?) ?? '',
                style: Ds.t.caption.copyWith(color: kTextLo)),
            if ((t['note'] as String?)?.isNotEmpty ?? false) ...[
              SizedBox(height: Ds.space.x8),
              Text(t['note'] as String,
                  style: Ds.t.caption.copyWith(color: kTextLo)),
            ],
            if ((t['error'] as String?)?.isNotEmpty ?? false) ...[
              SizedBox(height: Ds.space.x8),
              Text(t['error'] as String,
                  style: Ds.t.caption.copyWith(color: Ds.c.danger)),
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
          Text((guard['label'] as String?) ?? '',
              style: Ds.t.subtitle
                  .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
          SizedBox(height: Ds.space.x8),
          Text((guard['value_label'] as String?) ?? '',
              style: Ds.t.body.copyWith(color: kTextHi)),
          if (recent.isEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(c('dev_queue.cron_health_guard_quiet'),
                style: Ds.t.caption.copyWith(color: kTextLo)),
          ],
          for (final e in recent) ...[
            SizedBox(height: Ds.space.x12),
            Text(
                '${((e as Map)['at_label'] ?? '')} · ${e['kind'] ?? ''} · ${e['job'] ?? ''}',
                style: Ds.t.caption
                    .copyWith(fontWeight: FontWeight.w600, color: kTextHi)),
            SizedBox(height: Ds.space.x4),
            Text('${e['detail'] ?? ''}',
                style: Ds.t.caption.copyWith(color: kTextLo)),
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
