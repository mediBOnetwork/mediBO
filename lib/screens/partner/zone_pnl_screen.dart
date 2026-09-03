import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';

/// CHANGE #694 — Zone P&L (feature_gaps #157).
///
/// The same screen serves mediBO and the partner, because it is the same
/// payload: `zone_pnl()` returns one slice per zone the caller may see —
/// every zone for an admin, its own for a partner — with the cost lines
/// already filtered by `pnl_line_type.partner_visible`.
///
/// Nothing here is money arithmetic. Every rupee, every percentage, the split
/// sentence, the period labels and the margin tone arrive as strings from the
/// backend, which computes them from `pnl_order_v` and the settlement ledger
/// so the numbers reconcile with the partner's own statement.
class ZonePnlScreen extends StatefulWidget {
  const ZonePnlScreen({super.key});

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<ZonePnlScreen> createState() => _ZonePnlScreenState();
}

class _ZonePnlScreenState extends State<ZonePnlScreen> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  String _period = 'month';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ZonePnlScreen.rpc('zone_pnl', {'p_period': _period});
      if (!mounted) return;
      setState(() {
        _p = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _pickPeriod(String key) {
    if (key.isEmpty || key == _period) return;
    setState(() {
      _period = key;
      _loading = true;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
          title: Text((_p['title'] ?? '').toString(), style: Ds.t.subtitle)),
      body: SafeArea(
        child: _loading
            ? ZonePnlView.skeleton()
            : RefreshIndicator(
                onRefresh: _load,
                child: ZonePnlView(payload: _p, onPeriod: _pickPeriod),
              ),
      ),
    );
  }
}

/// The rendered P&L, split from the screen so a protected test can pump a
/// payload with no Supabase and no timers.
class ZonePnlView extends StatelessWidget {
  const ZonePnlView({super.key, required this.payload, this.onPeriod});

  final Map<String, dynamic> payload;
  final ValueChanged<String>? onPeriod;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  static List<Map<String, dynamic>> _list(Map<String, dynamic> m, String k) =>
      ((m[k] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);

  static Widget skeleton() => Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 4; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                    height: Ds.space.x48,
                    decoration: BoxDecoration(
                        color: Ds.c.surface, borderRadius: Ds.r.rCard)),
              ),
          ],
        ),
      );

  Color _tone(String tone) => switch (tone) {
        'danger' => Ds.c.danger,
        'success' => Ds.c.success,
        _ => Ds.c.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] != true) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(_s(payload, 'message'),
              textAlign: TextAlign.center, style: Ds.t.body),
        ),
      );
    }

    final zones = _list(payload, 'zones');
    final periods = _list(payload, 'period_options');
    final labels = Map<String, dynamic>.from(
        (payload['tile_labels'] as Map?) ?? const <String, dynamic>{});

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(payload, 'subtitle'), style: Ds.t.body),
        // The partner is told, in the backend's words, why its list is shorter.
        if (_s(payload, 'view_note').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s(payload, 'view_note'), style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x16),
        // The period picker is the payload's own list, and which one is
        // selected is the payload's own flag — never a local index.
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final p in periods)
              ChoiceChip(
                label: Text(_s(p, 'label')),
                selected: p['active'] == true,
                onSelected:
                    onPeriod == null ? null : (_) => onPeriod!(_s(p, 'key')),
              ),
          ],
        ),
        SizedBox(height: Ds.space.x24),
        if (zones.isEmpty)
          Text(_s(payload, 'empty_note'), style: Ds.t.caption)
        else
          for (final z in zones) ...[
            _ZoneCard(zone: z, labels: labels, tone: _tone, payload: payload),
            SizedBox(height: Ds.space.x16),
          ],
        if (_list(payload, 'trend').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(_s(payload, 'trend_heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          _Trend(points: _list(payload, 'trend')),
        ],
        SizedBox(height: Ds.space.x24),
        Text(_s(payload, 'reconcile_note'), style: Ds.t.caption),
      ],
    );
  }
}

class _ZoneCard extends StatelessWidget {
  const _ZoneCard({
    required this.zone,
    required this.labels,
    required this.tone,
    required this.payload,
  });

  final Map<String, dynamic> zone;
  final Map<String, dynamic> labels;
  final Color Function(String) tone;
  final Map<String, dynamic> payload;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  Widget _tile(String label, String value, {Color? colour}) => Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(value, style: Ds.t.body.copyWith(color: colour)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final lines = ((zone['lines'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s(zone, 'zone_name'), style: Ds.t.subtitle),
              ),
              Text(_s(zone, 'split_label'), style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x16),
          Wrap(
            spacing: Ds.space.x24,
            runSpacing: Ds.space.x12,
            children: [
              _tile('${labels['revenue'] ?? ''}', _s(zone, 'revenue_display')),
              _tile('${labels['gross'] ?? ''}', _s(zone, 'gross_display')),
              _tile('${labels['margin'] ?? ''}', _s(zone, 'margin_display'),
                  colour: tone(_s(zone, 'margin_tone'))),
              _tile('${labels['orders'] ?? ''}', _s(zone, 'orders')),
              _tile('${labels['partner'] ?? ''}', _s(zone, 'partner_display')),
              _tile('${labels['medibo'] ?? ''}', _s(zone, 'medibo_display')),
            ],
          ),
          if (lines.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            Text((payload['costs_heading'] ?? '').toString(),
                style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            for (final l in lines)
              Padding(
                padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
                child: Row(
                  children: [
                    Expanded(child: Text(_s(l, 'label'), style: Ds.t.body)),
                    SizedBox(width: Ds.space.x12),
                    // The sign is the backend's and it is already in the
                    // string: nothing here decides what is a cost.
                    Text(_s(l, 'amount_display'), style: Ds.t.body),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// The trend, drawn from the payload's own points. The bar heights are the
/// only thing computed on this side, and they are geometry, not money.
class _Trend extends StatelessWidget {
  const _Trend({required this.points});

  final List<Map<String, dynamic>> points;

  /// The tallest a bar may draw. The box below is this PLUS the two caption
  /// lines and the gaps between them — summed from the parts it lays out with,
  /// never a round number typed here (#636's lesson: a hardcoded extent
  /// overflows silently the moment a part grows).
  static const double barMax = 88;
  static const double _captionLine = 18;

  static double get extent =>
      barMax + (_captionLine * 2) + (Ds.space.x4 * 3) + 4;

  @override
  Widget build(BuildContext context) {
    final maxRev = points
        .map((p) => (p['revenue'] as num?)?.toDouble() ?? 0)
        .fold<double>(0, (a, b) => b > a ? b : a);
    return SizedBox(
      height: extent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final p in points)
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('${p['revenue_display'] ?? ''}',
                        style: Ds.t.caption, maxLines: 1),
                    SizedBox(height: Ds.space.x4),
                    Container(
                      height: maxRev <= 0
                          ? 4
                          : 4 +
                              (barMax - 4) *
                                  (((p['revenue'] as num?)?.toDouble() ?? 0) /
                                      maxRev),
                      decoration: BoxDecoration(
                        color: Ds.c.brand,
                        borderRadius: Ds.r.rChip,
                      ),
                    ),
                    SizedBox(height: Ds.space.x4),
                    Text('${p['label'] ?? ''}',
                        style: Ds.t.caption, maxLines: 1),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
