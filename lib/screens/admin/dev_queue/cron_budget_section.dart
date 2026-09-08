import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// CHANGE #1361 — what each scheduled task costs, as a share of its own
/// interval.
///
/// Om, 5 Sep: "the app takes minutes per tab while NOTHING is building and the
/// VM is off." The cause was `catalogue_cache_refresh` running every 60 s and
/// taking 22-66 s of it — the database busy for most of every minute, all day,
/// with every user-facing query queued behind it. Nothing in the app said so.
/// The Cron health screen listed each task's last duration, but a duration on
/// its own means nothing: 30 s every four hours is free, 30 s every minute is
/// an outage. The number that predicts starvation is the RATIO, and this panel
/// is that number.
///
/// It decides nothing. `cron_budget_card()` builds the rule sentence, the night
/// window label, each row's percentage, its sub-line and its tone, and the list
/// of parked tasks with the reason each was parked. The panel prints them in
/// payload order.
class CronBudgetSection extends StatefulWidget {
  /// Injectable so the panel can be driven from a fixture.
  final SupabaseClient? client;
  const CronBudgetSection({super.key, this.client});

  @override
  State<CronBudgetSection> createState() => _CronBudgetSectionState();
}

class _CronBudgetSectionState extends State<CronBudgetSection> {
  SupabaseClient get _c => widget.client ?? Supabase.instance.client;
  Map<String, dynamic> _d = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await _c.rpc('cron_budget_card');
      final v = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
      if (!mounted) return;
      setState(() {
        _d = v is Map ? Map<String, dynamic>.from(v) : const {};
        _loading = false;
      });
    } catch (_) {
      // Same contract as every lane on this screen: a panel, never the page.
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    return CronBudgetView(data: _d);
  }
}

/// The pure renderer. Split out from the fetcher above so the protected suite
/// can drive it against a fixture with no Supabase, no network and no timers —
/// and so the ONE thing worth holding down (that every number here is the
/// backend's) is testable at all.
class CronBudgetView extends StatelessWidget {
  final Map<String, dynamic> data;
  const CronBudgetView({super.key, required this.data});

  Map<String, dynamic> get _d => data;

  @override
  Widget build(BuildContext context) {
    if ((_d['has'] ?? false) != true) return const SizedBox.shrink();

    final parked = (_d['parked'] as List?) ?? const [];
    final top = (_d['top'] as List?) ?? const [];

    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text((_d['title'] as String?) ?? '',
                style: Ds.t.subtitle
                    .copyWith(fontWeight: FontWeight.w700, color: kTextHi)),
          ),
          if (((_d['night_label'] as String?) ?? '').isNotEmpty)
            ToneChip(
                label: _d['night_label'] as String, tone: toneByName('info')),
        ]),
        if (((_d['rule_label'] as String?) ?? '').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_d['rule_label'] as String, style: Ds.t.caption),
        ],

        // The ratio table. Payload order — the backend already sorted by the
        // share each task takes, which is not the same order as raw duration.
        if (top.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          for (final r in top) _row(r as Map),
        ],

        SizedBox(height: Ds.space.x24),
        Text((_d['parked_head'] as String?) ?? '',
            style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
        SizedBox(height: Ds.space.x8),
        // An empty list is the backend's own sentence, never a blank space and
        // never one worded here.
        if (parked.isEmpty)
          Text((_d['parked_empty'] as String?) ?? '', style: Ds.t.caption)
        else
          for (final p in parked) _parked(p as Map),
      ]),
    );
  }

  Widget _row(Map r) {
    final tone = toneByName((r['tone'] ?? 'neutral').toString());
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((r['name'] ?? '').toString(),
                style: Ds.t.body.copyWith(fontWeight: FontWeight.w500)),
            if ((r['sub'] ?? '').toString().isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text((r['sub']).toString(), style: Ds.t.caption),
            ],
          ]),
        ),
        SizedBox(width: Ds.space.x12),
        ToneChip(label: (r['value'] ?? '').toString(), tone: tone),
      ]),
    );
  }

  Widget _parked(Map p) {
    final tone = toneByName((p['tone'] ?? 'warning').toString());
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x8),
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(color: tone.bg, borderRadius: Ds.r.rButton),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${p['name'] ?? ''} · ${p['label'] ?? ''}',
            style: Ds.t.bodyStrong.copyWith(color: tone.fg)),
        if ((p['detail'] ?? '').toString().isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text((p['detail']).toString(),
              style: Ds.t.caption.copyWith(color: tone.fg)),
        ],
        if ((p['at_label'] ?? '').toString().isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text((p['at_label']).toString(),
              style: Ds.t.caption.copyWith(color: tone.fg)),
        ],
      ]),
    );
  }
}
