// CHANGE #693 — the admin "Partner scorecards" screen (feature_gaps row 156).
//
// Three sections, all rendered verbatim from the backend:
//   1. the month picker, whose options and their labels are the payload's;
//   2. every active fulfilment partner, RANKED — the rank, the score, the tone
//      and the order of the rows are all decided by `admin_partner_scorecards()`
//      so this screen and the partner's own card can never disagree;
//   3. the partner incentive schemes, and the monthly targets behind them.
//
// Targets are super-admin only, and the screen does not decide that either:
// `partner_targets_get()` answers `can_edit`, and `partner_targets_set()`
// refuses anyone else with its own sentence.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/partner_state.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../partner/partner_scorecard_card.dart';
import '../partner/partner_ui.dart';

class AdminPartnerScorecardsScreen extends StatefulWidget {
  const AdminPartnerScorecardsScreen({super.key, this.rpc});

  /// Test seam. Null in production -> the real RPCs.
  final PartnerRpc? rpc;

  @override
  State<AdminPartnerScorecardsScreen> createState() =>
      _AdminPartnerScorecardsScreenState();
}

class _AdminPartnerScorecardsScreenState
    extends State<AdminPartnerScorecardsScreen> {
  Map<String, dynamic>? _payload;
  Map<String, dynamic>? _schemes;
  bool _loading = true;
  String? _month;
  int? _openPartner;

  PartnerRpc get _rpc => widget.rpc ?? PartnerApi.call;

  String _s(Object? v) => v == null ? '' : v.toString();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> p;
    Map<String, dynamic> s;
    try {
      p = asMap(await _rpc('admin_partner_scorecards',
          _month == null ? const {} : {'p_month': _month}));
    } catch (_) {
      p = const <String, dynamic>{};
    }
    try {
      s = asMap(await _rpc('partner_incentive_schemes', const {}));
    } catch (_) {
      s = const <String, dynamic>{};
    }
    if (!mounted) return;
    setState(() {
      _payload = p;
      _schemes = s;
      _month = _s(p['month']).isEmpty ? _month : _s(p['month']);
      _loading = false;
    });
    RenderLog.write('c693_admin_scorecards', 'painted');
    RenderLog.write('c693_scorecard_rows', '${asRows(p['rows']).length}');
  }

  Future<void> _openTargets(int partnerId) async {
    Map<String, dynamic> t;
    try {
      t = asMap(await _rpc('partner_targets_get',
          {'p_partner': partnerId, if (_month != null) 'p_month': _month}));
    } catch (_) {
      t = const <String, dynamic>{};
    }
    if (!mounted) return;
    if (t['ok'] != true) {
      showToast(context, _s(t['message']), isError: true);
      return;
    }
    final rows = asRows(t['rows']);
    final ctrls = <String, TextEditingController>{
      for (final r in rows)
        _s(r['slug']): TextEditingController(
            text: r['is_default'] == true ? '' : _s(r['value'])),
    };
    final canEdit = t['can_edit'] == true;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_s(t['title']), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x4),
              Text('${_s(t['partner_label'])} · ${_s(t['month_label'])}',
                  style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              Text(canEdit ? _s(t['hint']) : _s(t['readonly_note']),
                  style: Ds.t.caption),
              SizedBox(height: Ds.space.x24),
              for (final r in rows) ...[
                TextField(
                  controller: ctrls[_s(r['slug'])],
                  enabled: canEdit,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText:
                        '${_s(r['label'])}  ${_s(r['suffix'])}'.trimRight(),
                    hintText: _s(r['value_label']),
                    helperText: _s(r['direction_label']),
                  ),
                ),
                SizedBox(height: Ds.space.x16),
              ],
              if (canEdit)
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(_s(t['save_label'])),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (saved != true) return;
    final patch = <String, dynamic>{
      for (final e in ctrls.entries) e.key: e.value.text.trim(),
    };
    try {
      final r = asMap(await _rpc('partner_targets_set', {
        'p_partner': partnerId,
        'p_month': _month,
        'p_targets': patch,
      }));
      if (!mounted) return;
      showToast(context, _s(r['message']), isError: r['ok'] != true);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
    await _load();
  }

  Widget _monthBar(Map<String, dynamic> p) {
    final months = asRows(p['months']);
    if (months.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: Ds.touch.minTarget,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: months.length,
        separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
        itemBuilder: (_, i) {
          final m = months[i];
          final on = m['selected'] == true;
          return ChoiceChip(
            selected: on,
            label: Text(_s(m['label'])),
            onSelected: (_) {
              setState(() => _month = _s(m['month']));
              _load();
            },
          );
        },
      ),
    );
  }

  Widget _schemesCard() {
    final s = _schemes ?? const <String, dynamic>{};
    if (s['ok'] != true) return const SizedBox.shrink();
    final rows = asRows(s['rows']);
    return PartnerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(s['title']), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text(_s(s['hint']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          if (rows.isEmpty)
            Text(_s(s['empty_label']), style: Ds.t.bodySecondary)
          else
            for (final r in rows)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_s(r['label']), style: Ds.t.body),
                          SizedBox(height: Ds.space.x4),
                          Text(
                            '${_s(r['scope_label'])} · ${_s(r['metric_label'])} '
                            '${_s(r['threshold_label'])}',
                            style: Ds.t.caption,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(_s(r['bonus_label']), style: Ds.t.bodyStrong),
                        SizedBox(height: Ds.space.x4),
                        PartnerChip(
                            text: _s(r['status_label']), tone: _s(r['tone'])),
                        SizedBox(height: Ds.space.x4),
                        Text('${_s(r['paid_caption'])} ${_s(r['paid_label'])}',
                            style: Ds.t.caption),
                      ],
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload ?? const <String, dynamic>{};
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(p['title']).isEmpty
          ? c('pscore.admin_title')
          : _s(p['title']))),
      body: _loading
          ? const PartnerSkeleton(rows: 4)
          : p['ok'] != true
              ? PartnerNotice(
                  text: _s(p['message']).isEmpty
                      ? c('pscore.load_failed')
                      : _s(p['message']),
                  onRetry: _load,
                  retryLabel: c('pscore.retry'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      Text(_s(p['subtitle']), style: Ds.t.caption),
                      SizedBox(height: Ds.space.x16),
                      _monthBar(p),
                      SizedBox(height: Ds.space.x24),
                      Text(_s(p['count_label']), style: Ds.t.bodyStrong),
                      SizedBox(height: Ds.space.x12),
                      if (asRows(p['rows']).isEmpty)
                        Text(_s(p['empty_label']), style: Ds.t.bodySecondary),
                      for (final row in asRows(p['rows']))
                        _PartnerRankRow(
                          row: row,
                          monthLabel: _s(p['month_label']),
                          targetsLabel: _s(p['targets_label']),
                          expanded: _openPartner ==
                              int.tryParse(_s(row['partner_id'])),
                          onTap: () => setState(() {
                            final id = int.tryParse(_s(row['partner_id']));
                            _openPartner = _openPartner == id ? null : id;
                          }),
                          onTargets: () {
                            final id = int.tryParse(_s(row['partner_id']));
                            if (id != null) _openTargets(id);
                          },
                        ),
                      SizedBox(height: Ds.space.x24),
                      _schemesCard(),
                    ],
                  ),
                ),
    );
  }
}

/// One ranked partner. Collapsed it is rank + name + score; expanded it is the
/// SAME card the partner sees, so an operator reads exactly what the partner
/// reads.
class _PartnerRankRow extends StatelessWidget {
  const _PartnerRankRow({
    required this.row,
    required this.monthLabel,
    required this.targetsLabel,
    required this.expanded,
    required this.onTap,
    required this.onTargets,
  });

  final Map<String, dynamic> row;
  final String monthLabel;
  final String targetsLabel;
  final bool expanded;
  final VoidCallback onTap;
  final VoidCallback onTargets;

  String _s(Object? v) => v == null ? '' : v.toString();

  @override
  Widget build(BuildContext context) {
    if (expanded) {
      return PartnerScorecardCard(
        payload: <String, dynamic>{
          ...row,
          'ok': true,
          'month_label': monthLabel,
        },
        dense: true,
        trailing: SizedBox(
          height: Ds.touch.minTarget,
          child: OutlinedButton(onPressed: onTargets, child: Text(targetsLabel)),
        ),
      );
    }
    return PartnerCard(
      onTap: onTap,
      child: Row(
        children: [
          SizedBox(
            width: Ds.space.x48,
            child: Text(_s(row['rank_label']), style: Ds.t.bodyStrong),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s(row['partner_label']), style: Ds.t.body),
                SizedBox(height: Ds.space.x4),
                Text(_s(row['zone_label']), style: Ds.t.caption),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                  row['has_score'] == true
                      ? _s(row['score_label'])
                      : _s(row['no_score_label']),
                  style: Ds.t.subtitle
                      .copyWith(color: partnerToneColor(_s(row['score_tone'])))),
              if (row['has_bonus'] == true) ...[
                SizedBox(height: Ds.space.x4),
                Text(_s(row['bonus_total_label']), style: Ds.t.caption),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
