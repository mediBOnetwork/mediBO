// CMD #467 row 155 — the partner audit trail, made readable.
//
// partner_audit() has always written a good record: who opened what, in which
// zone, and every refusal. The only reader was the console's Activity card —
// the last 25 rows for one partner, no filter, no paging, no date range. An
// `open_denied`, the one entry that says a partner is probing a feature it was
// never granted, dropped off the bottom of that list within a day and could
// never be searched for again.
//
// This screen is one RPC printed verbatim. `admin_partner_audit_list()` sends
// the heading, the three filter option lists with their own counts and their
// own `selected` flag, each row's single composed line and its tone, the count
// label, the denied banner and the paging flag. Nothing here formats a date,
// pluralises a count, decides what an action is called, or works out whether
// there are more rows — every one of those was the backend's answer.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/partner_state.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

/// Tone -> colour, the same mapping the console uses. A tone this build has
/// never heard of falls back to the neutral pair rather than throwing.
class PartnerAuditTone {
  PartnerAuditTone._();

  static Color fg(String tone) => switch (tone) {
        'success' => Ds.c.success,
        'danger' => Ds.c.danger,
        'warning' => Ds.c.warning,
        'info' => Ds.c.info,
        _ => Ds.c.textSecondary,
      };

  static Color bg(String tone) => switch (tone) {
        'success' => Ds.c.successSoft,
        'danger' => Ds.c.dangerSoft,
        'warning' => Ds.c.warningSoft,
        'info' => Ds.c.infoSoft,
        _ => Ds.c.bg,
      };
}

class PartnerAuditLogScreen extends StatefulWidget {
  const PartnerAuditLogScreen({
    super.key,
    required this.partnerId,
    this.rpc,
  });

  final int partnerId;

  /// Test seam. Null in production -> the real RPC.
  final PartnerRpc? rpc;

  @override
  State<PartnerAuditLogScreen> createState() => _PartnerAuditLogScreenState();
}

class _PartnerAuditLogScreenState extends State<PartnerAuditLogScreen> {
  Map<String, dynamic>? _payload;
  final List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _paging = false;
  bool _failed = false;

  // The three filters. Their VALUES come from the payload's option lists; this
  // state only remembers which one was tapped so the next call can carry it.
  String _feature = '';
  String _action = '';
  int _days = 30;

  PartnerRpc get _rpc => widget.rpc ?? PartnerApi.call;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({int offset = 0}) async {
    if (offset == 0) {
      setState(() => _loading = true);
    } else {
      setState(() => _paging = true);
    }
    try {
      final res = await _rpc('admin_partner_audit_list', {
        'p_partner_id': widget.partnerId,
        'p_feature': _feature.isEmpty ? null : _feature,
        'p_action': _action.isEmpty ? null : _action,
        'p_days': _days,
        'p_offset': offset,
      });
      if (!mounted) return;
      final page = ((res['rows'] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      setState(() {
        _payload = res;
        if (offset == 0) _rows.clear();
        _rows.addAll(page);
        _loading = false;
        _paging = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _paging = false;
        _failed = _payload == null;
      });
    }
  }

  void _setFilter({String? feature, String? action, int? days}) {
    setState(() {
      if (feature != null) _feature = feature;
      if (action != null) _action = action;
      if (days != null) _days = days;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(
          (p?['title'] ?? '').toString(),
          style: Ds.t.subtitle,
        ),
      ),
      body: _loading
          ? const _AuditSkeleton()
          : p == null
              ? _AuditFailed(onRetry: _failed ? () => _load() : null)
              : PartnerAuditLogView(
                  payload: p,
                  rows: _rows,
                  paging: _paging,
                  onFeature: (v) => _setFilter(feature: v),
                  onAction: (v) => _setFilter(action: v),
                  onRange: (v) => _setFilter(days: v),
                  onMore: () => _load(
                      offset: (p['next_offset'] as num?)?.toInt() ?? _rows.length),
                ),
    );
  }
}

/// The pure render half — an inline payload, no network.
class PartnerAuditLogView extends StatelessWidget {
  const PartnerAuditLogView({
    super.key,
    required this.payload,
    required this.rows,
    required this.onFeature,
    required this.onAction,
    required this.onRange,
    required this.onMore,
    this.paging = false,
  });

  final Map<String, dynamic> payload;
  final List<Map<String, dynamic>> rows;
  final bool paging;
  final void Function(String featureKey) onFeature;
  final void Function(String action) onAction;
  final void Function(int days) onRange;
  final VoidCallback onMore;

  String _s(String k) => (payload[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final features = (payload['features'] as List?) ?? const [];
    final actions = (payload['actions'] as List?) ?? const [];
    final ranges = (payload['ranges'] as List?) ?? const [];
    final hasMore = payload['has_more'] == true;
    final deniedTone = _s('denied_tone');
    final deniedLabel = _s('denied_label');

    try {
      RenderLog.write(
          'c467_partner_audit',
          'ok=${payload['ok'] == true},rows=${rows.length},'
          'total=${(payload['total'] ?? 0)},denied=${(payload['denied_count'] ?? 0)},'
          'more=$hasMore');
    } catch (_) {}

    if (payload['ok'] != true) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Text(_s('message'), style: Ds.t.body),
      );
    }

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        if (_s('subtitle').isNotEmpty) ...[
          Text(_s('subtitle'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
        ],

        // ── the three filters, each a row of chips the backend supplied ──
        _FilterBlock(
          label: _s('filter_range_label'),
          options: [
            for (final r in ranges)
              _ChipSpec(
                label: (r['label'] ?? '').toString(),
                selected: r['selected'] == true,
                onTap: () => onRange(((r['value'] as num?) ?? 30).toInt()),
              ),
          ],
        ),
        SizedBox(height: Ds.space.x16),
        _FilterBlock(
          label: _s('filter_action_label'),
          options: [
            _ChipSpec(
              label: _s('any_action_label'),
              selected: _s('action').isEmpty,
              onTap: () => onAction(''),
            ),
            for (final a in actions)
              _ChipSpec(
                label: '${a['label'] ?? ''} (${a['count'] ?? 0})',
                selected: a['selected'] == true,
                tone: (a['tone'] ?? 'neutral').toString(),
                onTap: () => onAction((a['value'] ?? '').toString()),
              ),
          ],
        ),
        SizedBox(height: Ds.space.x16),
        _FilterBlock(
          label: _s('filter_feature_label'),
          options: [
            _ChipSpec(
              label: _s('any_feature_label'),
              selected: _s('feature').isEmpty,
              onTap: () => onFeature(''),
            ),
            for (final f in features)
              _ChipSpec(
                label: '${f['label'] ?? ''} (${f['count'] ?? 0})',
                selected: f['selected'] == true,
                onTap: () => onFeature((f['value'] ?? '').toString()),
              ),
          ],
        ),

        SizedBox(height: Ds.space.x24),

        // ── the signal the register asked for: refused attempts ──
        if (deniedLabel.isNotEmpty)
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: PartnerAuditTone.bg(deniedTone),
              borderRadius: Ds.r.rCard,
            ),
            child: Text(
              deniedLabel,
              style: Ds.t.body.copyWith(color: PartnerAuditTone.fg(deniedTone)),
            ),
          ),

        SizedBox(height: Ds.space.x16),
        Text(_s('count_label'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),

        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
            child: Text(_s('empty'), style: Ds.t.body),
          ),

        for (final r in rows) PartnerAuditEntry(row: r),

        if (hasMore) ...[
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: Ds.touch.listRowMinHeight,
            child: OutlinedButton(
              onPressed: paging ? null : onMore,
              child: Text(_s('more_label')),
            ),
          ),
        ],
        SizedBox(height: Ds.space.x32),
      ],
    );
  }
}

/// One recorded action. `line` is the whole sentence and it arrives composed —
/// this widget never joins an action to a feature key.
class PartnerAuditEntry extends StatelessWidget {
  const PartnerAuditEntry({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final tone = (row['tone'] ?? 'neutral').toString();
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x8),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: Ds.space.x4,
            height: Ds.space.x32,
            decoration: BoxDecoration(
              color: PartnerAuditTone.fg(tone),
              borderRadius: Ds.r.rChip,
            ),
          ),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((row['line'] ?? '').toString(), style: Ds.t.body),
                SizedBox(height: Ds.space.x4),
                Text((row['at_label'] ?? '').toString(), style: Ds.t.caption),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChipSpec {
  const _ChipSpec({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tone = 'neutral',
  });
  final String label;
  final bool selected;
  final String tone;
  final VoidCallback onTap;
}

class _FilterBlock extends StatelessWidget {
  const _FilterBlock({required this.label, required this.options});
  final String label;
  final List<_ChipSpec> options;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final o in options)
              InkWell(
                onTap: o.onTap,
                borderRadius: Ds.r.rChip,
                child: Container(
                  constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x16, vertical: Ds.space.x8),
                  decoration: BoxDecoration(
                    color: o.selected ? Ds.c.brand : Ds.c.surface,
                    borderRadius: Ds.r.rChip,
                    border: Border.all(
                        color: o.selected ? Ds.c.brand : Ds.c.divider),
                  ),
                  child: Text(
                    o.label,
                    style: Ds.t.caption.copyWith(
                      color: o.selected ? Ds.c.surface : Ds.c.text,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// The server never answered. The words are ui_copy's; only the Retry wiring
/// is this file's.
class _AuditFailed extends StatelessWidget {
  const _AuditFailed({this.onRetry});
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(c('partner_audit.load_failed'),
                style: Ds.t.body, textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.listRowMinHeight,
              child: OutlinedButton(
                onPressed: onRetry,
                child: Text(c('partner_audit.retry')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuditSkeleton extends StatelessWidget {
  const _AuditSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (var i = 0; i < 6; i++)
          Container(
            height: Ds.touch.listRowMinHeight,
            margin: EdgeInsets.only(bottom: Ds.space.x8),
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
            ),
          ),
      ],
    );
  }
}
