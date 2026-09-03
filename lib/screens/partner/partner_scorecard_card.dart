// CHANGE #693 — the partner scorecard card (feature_gaps row 156).
//
// ONE widget, rendered on BOTH sides: the partner's own console and the admin's
// Partners ranking. So the number a partner is paid on and the number an
// operator ranks them by can never drift apart — they are the same payload.
//
// The card computes NOTHING. Every metric name, every formatted value, the
// target, the progress fraction, the tone, the status word, the bonus rupees
// and the month itself are fields of `partner_scorecard()`. A metric with no
// data arrives as `has_value:false` and prints the backend's own sentence
// rather than a zero that would read like a failure.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/partner_state.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import 'partner_ui.dart';

String _s(Object? v) => v == null ? '' : v.toString();

Map<String, dynamic> asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

List<Map<String, dynamic>> asRows(dynamic v) => (v is List)
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

/// One metric line: the label, what it measured, and how far that is from the
/// target the backend sent.
class PartnerMetricRow extends StatelessWidget {
  const PartnerMetricRow({super.key, required this.metric});

  final Map<String, dynamic> metric;

  @override
  Widget build(BuildContext context) {
    final hasValue = metric['has_value'] == true;
    final hasTarget = metric['has_target'] == true;
    final tone = _s(metric['tone']);
    final progress = (metric['progress'] is num)
        ? (metric['progress'] as num).toDouble().clamp(0.0, 1.0)
        : 0.0;

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(_s(metric['label']), style: Ds.t.body)),
              SizedBox(width: Ds.space.x12),
              Text(
                hasValue ? _s(metric['value_label']) : _s(metric['no_value_label']),
                style: Ds.t.bodyStrong.copyWith(color: partnerToneColor(tone)),
                textAlign: TextAlign.right,
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          ClipRRect(
            borderRadius: Ds.r.rChip,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: Ds.space.x8,
              backgroundColor: Ds.c.bg,
              valueColor: AlwaysStoppedAnimation<Color>(partnerToneColor(tone)),
            ),
          ),
          SizedBox(height: Ds.space.x4),
          Row(
            children: [
              Expanded(
                child: Text(
                  hasTarget
                      ? '${_s(metric['target_caption'])} ${_s(metric['target_label'])}'
                      : _s(metric['sample_label']),
                  style: Ds.t.caption,
                ),
              ),
              Text(_s(metric['status_label']),
                  style: Ds.t.caption.copyWith(color: partnerToneColor(tone))),
            ],
          ),
        ],
      ),
    );
  }
}

/// The whole card: score, metrics, incentives. `dense` drops the headings for
/// the admin list, where the partner's name is already the row above it.
class PartnerScorecardCard extends StatelessWidget {
  const PartnerScorecardCard({
    super.key,
    required this.payload,
    this.dense = false,
    this.trailing,
  });

  final Map<String, dynamic> payload;
  final bool dense;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    if (payload.isEmpty) return const SizedBox.shrink();
    if (payload['ok'] != true) {
      return PartnerNotice(text: _s(payload['message']));
    }
    final metrics = asRows(payload['metrics']);
    final bonuses = asRows(payload['bonuses']);

    return PartnerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(dense ? _s(payload['partner_label']) : _s(payload['heading']),
                        style: Ds.t.subtitle),
                    SizedBox(height: Ds.space.x4),
                    Text(
                      dense
                          ? _s(payload['zone_label'])
                          : '${_s(payload['month_label'])} · ${_s(payload['zone_label'])}',
                      style: Ds.t.caption,
                    ),
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x12),
              if (payload['has_score'] == true)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(_s(payload['score_label']),
                        style: Ds.t.display.copyWith(
                            color: partnerToneColor(_s(payload['score_tone'])))),
                    Text(_s(payload['score_caption']), style: Ds.t.caption),
                  ],
                ),
              if (trailing != null) ...[
                SizedBox(width: Ds.space.x12),
                trailing!,
              ],
            ],
          ),
          if (!dense) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(payload['subtitle']), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x24),
          if (metrics.isEmpty)
            Text(_s(payload['empty_label']), style: Ds.t.bodySecondary)
          else ...[
            if (!dense) ...[
              Text(_s(payload['metrics_heading']), style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x12),
            ],
            for (final m in metrics) PartnerMetricRow(metric: m),
          ],
          if (payload['has_bonus'] == true) ...[
            SizedBox(height: Ds.space.x8),
            Row(
              children: [
                Expanded(
                  child: Text(_s(payload['bonus_heading']), style: Ds.t.bodyStrong),
                ),
                Text(_s(payload['bonus_total_label']), style: Ds.t.bodyStrong),
              ],
            ),
            SizedBox(height: Ds.space.x4),
            Text(_s(payload['bonus_total_caption']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            for (final b in bonuses)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_s(b['label']), style: Ds.t.body),
                          SizedBox(height: Ds.space.x4),
                          Text(
                            '${_s(b['metric_label'])} · ${_s(b['threshold_label'])}',
                            style: Ds.t.caption,
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(_s(b['bonus_label']), style: Ds.t.bodyStrong),
                        SizedBox(height: Ds.space.x4),
                        PartnerChip(
                            text: _s(b['status_label']), tone: _s(b['tone'])),
                      ],
                    ),
                  ],
                ),
              ),
            Text(_s(payload['settlement_note']), style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

/// The partner's own destination (`route_key: partner_scorecard`). One RPC,
/// one card. A partner asking for somebody else's id is clamped to its own by
/// `partner_scorecard()` itself, so this screen sends no id at all.
class PartnerScorecardScreen extends StatefulWidget {
  const PartnerScorecardScreen({super.key, this.rpc, this.partnerId});

  /// Test seam. Null in production -> the real RPC.
  final PartnerRpc? rpc;

  /// Only ever set by an operator surface; a partner login ignores it backend-side.
  final int? partnerId;

  @override
  State<PartnerScorecardScreen> createState() => _PartnerScorecardScreenState();
}

class _PartnerScorecardScreenState extends State<PartnerScorecardScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;

  PartnerRpc get _rpc => widget.rpc ?? PartnerApi.call;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> p;
    try {
      p = asMap(await _rpc('partner_scorecard',
          widget.partnerId == null ? const {} : {'p_partner': widget.partnerId}));
    } catch (_) {
      p = const <String, dynamic>{};
    }
    if (!mounted) return;
    setState(() {
      _payload = p;
      _loading = false;
    });
    RenderLog.write('c693_partner_scorecard', 'painted');
    RenderLog.write(
        'c693_scorecard_metrics', '${asRows(p['metrics']).length}');
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const PartnerSkeleton(rows: 3);
    final p = _payload ?? const <String, dynamic>{};
    if (p['ok'] != true) {
      // The backend's own refusal when it answered; its own load-failure copy
      // when it did not. Never a Dart sentence.
      final msg = _s(p['message']);
      return PartnerNotice(
        text: msg.isEmpty ? c('pscore.load_failed') : msg,
        onRetry: _load,
        retryLabel: msg.isEmpty ? c('pscore.retry') : '',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [PartnerScorecardCard(payload: p)],
      ),
    );
  }
}
