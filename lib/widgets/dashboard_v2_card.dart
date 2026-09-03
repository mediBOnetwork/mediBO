// CHANGE #812 — the dashboard, rendered.
//
// `dashboard_v2(p_date, p_zone)` is ONE payload that feeds super admin, admin
// and partner from the same code path. Nothing in this file decides anything:
// every number arrives formatted (`value_display`, `delta_display`), every
// sentence arrives written (`greeting`, `first_thing`, `over_label`,
// `sub_label`), every tone arrives named (`good` / `warn` / `bad` / `danger`),
// and every tap carries the backend's own `route_key` / `deep_link` / `action`.
//
// The one thing Dart does here is draw: bars for the funnel, a polyline for a
// sparkline, an arc for the promised ring. Those are pixels, not decisions.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// A tap on anything the payload marked with a route: the caller decides how a
/// route_key / deep_link is opened, exactly as the nav tiles already do.
typedef DashboardOpen = void Function(Map<String, dynamic> target);

/// Running one of the backend's own `action` blocks ({rpc, args}).
typedef DashboardAction = Future<void> Function(Map<String, dynamic> action);

/// CHANGE #813 — a long press on a number shares it. The sentence and the
/// wa.me URL are both the payload's (`metric.share`); the host only opens it,
/// which is also why this widget stays plugin-free and unit-testable.
typedef DashboardShare = void Function(Map<String, dynamic> share);

Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

List<Map<String, dynamic>> _rows(Object? v) => (v is List)
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

/// The four tones the backend names, and nothing else. An unknown tone reads
/// as neutral rather than throwing or inventing a colour.
Color _ink(String tone) => switch (tone) {
      'good' || 'success' => Ds.c.success,
      'warn' || 'warning' => Ds.c.warning,
      'bad' || 'danger' => Ds.c.danger,
      'info' => Ds.c.info,
      _ => Ds.c.textSecondary,
    };

Color _wash(String tone) => switch (tone) {
      'good' || 'success' => Ds.c.successSoft,
      'warn' || 'warning' => Ds.c.warningSoft,
      'bad' || 'danger' => Ds.c.dangerSoft,
      'info' => Ds.c.infoSoft,
      _ => Ds.c.bg,
    };

/// The whole dashboard head: greeting, alerts, today strip, needs-you, funnel,
/// promised ring, quick actions and (super admin only) the zone cards.
class DashboardV2Card extends StatelessWidget {
  final Map<String, dynamic> payload;
  final DashboardOpen onOpen;
  final DashboardAction onAction;

  /// Optional so a caller that cannot share (a test, an embedded preview)
  /// simply renders a number that does not offer it.
  final DashboardShare? onShare;

  const DashboardV2Card({
    super.key,
    required this.payload,
    required this.onOpen,
    required this.onAction,
    this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    if (payload.isEmpty || payload['ok'] != true) {
      final message = _s(payload, 'message');
      if (message.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x16),
        child: Text(message, style: Ds.t.bodySecondary),
      );
    }

    final strip = _m(payload['strip']);
    final needs = _m(payload['needs_you']);
    final funnel = _m(payload['funnel']);
    final promised = _m(payload['promised']);
    final actions = _m(payload['quick_actions']);
    final zones = _m(payload['zone_cards']);
    final alerts = _rows(payload['alerts']);

    // Boot-time proof: a string in the bundle only proves the code compiled.
    // These counts are written when the card actually paints on the live site.
    try {
      RenderLog.write(
          'c812_dashboard',
          'metrics=${_rows(strip['metrics']).length};'
              'tappable=${_rows(strip['metrics']).where((m) => m['can_open'] == true).length};'
              'tones=${_rows(needs['items']).map((i) => _s(i, 'tone')).toSet().join('|')};'
              'needs=${_rows(needs['items']).length};'
              'stages=${_rows(funnel['stages']).length};'
              'alerts=${alerts.length};'
              'actions=${_rows(actions['items']).length};'
              'zones=${_rows(zones['cards']).length}');
    } catch (_) {}

    // CHANGE #813 — one scannable column on a phone; on a tablet or in
    // landscape the SAME blocks split into two, so nothing is re-ordered and
    // no block exists only in one layout.
    return LayoutBuilder(builder: (ctx, box) {
      final twoCol = box.maxWidth >= 900;
      final strip1 = _TodayStrip(strip: strip, onOpen: onOpen, onShare: onShare);
      final quick = _QuickActions(block: actions, onOpen: onOpen);
      final needsCard =
          _NeedsYou(block: needs, onAction: onAction, onOpen: onOpen);
      final funnelCard =
          _FunnelCard(block: funnel, promised: promised, onOpen: onOpen);
      final zoneCards = _rows(zones['cards']).isEmpty
          ? const SizedBox.shrink()
          : _ZoneCards(block: zones, onAction: onAction, onOpen: onOpen);

      final head = <Widget>[
        _Greeting(payload: payload),
        for (final a in alerts) _AlertBanner(alert: a),
        if (alerts.isNotEmpty) SizedBox(height: Ds.space.x8),
      ];

      if (twoCol) {
        return Column(
          key: const Key('c812_dashboard'),
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ...head,
            strip1,
            SizedBox(height: Ds.space.x24),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    quick,
                    if (_rows(actions['items']).isNotEmpty)
                      SizedBox(height: Ds.space.x24),
                    needsCard,
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x24),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    funnelCard,
                    if (_rows(zones['cards']).isNotEmpty) ...[
                      SizedBox(height: Ds.space.x24),
                      zoneCards,
                    ],
                  ],
                ),
              ),
            ]),
          ],
        );
      }

      return Column(
        key: const Key('c812_dashboard'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...head,
          strip1,
          SizedBox(height: Ds.space.x24),
          quick,
          if (_rows(actions['items']).isNotEmpty) SizedBox(height: Ds.space.x24),
          needsCard,
          SizedBox(height: Ds.space.x24),
          funnelCard,
          if (_rows(zones['cards']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            zoneCards,
          ],
        ],
      );
    });
  }
}

// ── Greeting + first thing ───────────────────────────────────────────────────

class _Greeting extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _Greeting({required this.payload});

  @override
  Widget build(BuildContext context) {
    final greeting = _s(payload, 'greeting');
    final first = _s(payload, 'first_thing');
    if (greeting.isEmpty && first.isEmpty) return const SizedBox.shrink();
    // The sentence is joined by the backend's own two halves; the em dash is
    // punctuation between two payload strings, not a phrase of its own.
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(greeting,
              key: const Key('c812_greeting'), style: Ds.t.display),
          if (first.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(first,
                key: const Key('c812_first_thing'), style: Ds.t.bodySecondary),
          ],
        ],
      ),
    );
  }
}

// ── Alert banner ─────────────────────────────────────────────────────────────

class _AlertBanner extends StatelessWidget {
  final Map<String, dynamic> alert;
  const _AlertBanner({required this.alert});

  @override
  Widget build(BuildContext context) {
    final label = _s(alert, 'label');
    if (label.isEmpty) return const SizedBox.shrink();
    final tone = _s(alert, 'tone');
    final ink = _ink(tone);
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: _wash(tone),
          borderRadius: Ds.r.rChip,
          border: Border.all(color: ink.withValues(alpha: 0.30)),
        ),
        child: Row(children: [
          Icon(Icons.error_outline, size: 16, color: ink),
          SizedBox(width: Ds.space.x8),
          Expanded(
              child: Text(label,
                  style: Ds.t.caption.copyWith(color: ink))),
        ]),
      ),
    );
  }
}

// ── Today strip ──────────────────────────────────────────────────────────────

class _TodayStrip extends StatelessWidget {
  final Map<String, dynamic> strip;
  final DashboardOpen onOpen;
  final DashboardShare? onShare;
  const _TodayStrip({required this.strip, required this.onOpen, this.onShare});

  @override
  Widget build(BuildContext context) {
    final metrics = _rows(strip['metrics']);
    if (metrics.isEmpty) return const SizedBox.shrink();
    final hint = _s(strip, 'share_hint');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SectionTitle(_s(strip, 'title')),
        if (hint.isNotEmpty && onShare != null) ...[
          SizedBox(height: Ds.space.x4),
          Text(hint, key: const Key('c813_share_hint'), style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x12),
        LayoutBuilder(builder: (ctx, box) {
          // Proportional, never a hard-coded tile width: two up on a phone,
          // three on a tablet, all five in a row on a desktop.
          final perRow = box.maxWidth >= 1000
              ? 5
              : box.maxWidth >= 700
                  ? 3
                  : 2;
          final gap = Ds.space.x12;
          final w = (box.maxWidth - gap * (perRow - 1)) / perRow;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final m in metrics)
                SizedBox(
                    width: w,
                    child: _MetricTile(
                        metric: m, onOpen: onOpen, onShare: onShare)),
            ],
          );
        }),
      ],
    );
  }
}

class _MetricTile extends StatelessWidget {
  final Map<String, dynamic> metric;
  final DashboardOpen onOpen;
  final DashboardShare? onShare;
  const _MetricTile({required this.metric, required this.onOpen, this.onShare});

  /// The arrow is the payload's `delta_arrow`, never a sign test on `delta`:
  /// "money out went up" is a WARN arrow, and only the backend knows that.
  static const _arrows = <String, IconData>{
    'up': Icons.arrow_upward,
    'down': Icons.arrow_downward,
    'flat': Icons.remove,
  };

  @override
  Widget build(BuildContext context) {
    final tone = _s(metric, 'delta_tone');
    final spark = (metric['spark'] is List)
        ? (metric['spark'] as List).whereType<num>().map((n) => n.toDouble()).toList()
        : const <double>[];
    final share = _m(metric['share']);
    final canOpen = metric['can_open'] == true;
    final canShare = onShare != null &&
        share['has'] == true &&
        _s(share, 'url').isNotEmpty;
    final arrow = _arrows[_s(metric, 'delta_arrow')];

    final body = Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_s(metric, 'label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(_s(metric, 'value_display'),
                key: Key('c812_metric_${_s(metric, 'key')}'),
                style: Ds.t.title),
          ),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            height: 24,
            child: CustomPaint(
              size: const Size(double.infinity, 24),
              painter: _SparkPainter(values: spark, color: _ink(tone)),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          Row(children: [
            if (arrow != null) ...[
              Icon(arrow,
                  key: Key('c813_arrow_${_s(metric, 'key')}'),
                  size: 14,
                  color: tone == 'neutral' ? Ds.c.textSecondary : _ink(tone)),
              SizedBox(width: Ds.space.x4),
            ],
            Expanded(
              child: Text(_s(metric, 'delta_display'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption.copyWith(
                      color:
                          tone == 'neutral' ? Ds.c.textSecondary : _ink(tone))),
            ),
          ]),
        ],
      ),
    );

    if (!canOpen && !canShare) return body;
    // A number that leads somewhere is a door: tap opens the backend's own
    // list, long press hands its share block up. Never a dead tile.
    return InkWell(
      key: Key('c813_metric_tap_${_s(metric, 'key')}'),
      borderRadius: Ds.r.rCard,
      onTap: canOpen ? () => onOpen(metric) : null,
      onLongPress: canShare ? () => onShare!(share) : null,
      child: body,
    );
  }
}

/// Seven days as a polyline. It plots the array it is given and nothing more —
/// no smoothing, no derived label, no axis it invented.
class _SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  const _SparkPainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce(math.min);
    final hi = values.reduce(math.max);
    final span = (hi - lo).abs() < 0.000001 ? 1.0 : (hi - lo);
    final dx = size.width / (values.length - 1);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = dx * i;
      final y = size.height - ((values[i] - lo) / span) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.values != values || old.color != color;
}

// ── Quick actions ────────────────────────────────────────────────────────────

class _QuickActions extends StatelessWidget {
  final Map<String, dynamic> block;
  final DashboardOpen onOpen;
  const _QuickActions({required this.block, required this.onOpen});

  static const _icons = <String, IconData>{
    'add_shopping_cart': Icons.add_shopping_cart_outlined,
    'question_answer': Icons.question_answer_outlined,
    'local_shipping': Icons.local_shipping_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final items = _rows(block['items']);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SectionTitle(_s(block, 'title')),
        SizedBox(height: Ds.space.x12),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final a in items)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: OutlinedButton.icon(
                  key: Key('c812_action_${_s(a, 'key')}'),
                  onPressed: () => onOpen(a),
                  icon: Icon(_icons[_s(a, 'icon_key')] ?? Icons.bolt_outlined,
                      size: 18),
                  label: Text(_s(a, 'label')),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

// ── Needs you ────────────────────────────────────────────────────────────────

class _NeedsYou extends StatelessWidget {
  final Map<String, dynamic> block;
  final DashboardAction onAction;
  final DashboardOpen onOpen;
  const _NeedsYou(
      {required this.block, required this.onAction, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final items = _rows(block['items']);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _SectionTitle(_s(block, 'title')),
          SizedBox(height: Ds.space.x12),
          if (items.isEmpty)
            Text(_s(block, 'empty_label'),
                key: const Key('c812_needs_empty'), style: Ds.t.bodySecondary)
          else
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) Divider(height: Ds.space.x24, color: Ds.c.divider),
              _NeedsRow(
                  item: items[i], onAction: onAction, onOpen: onOpen),
            ],
        ],
      ),
    );
  }
}

class _NeedsRow extends StatefulWidget {
  final Map<String, dynamic> item;
  final DashboardAction onAction;
  final DashboardOpen onOpen;
  const _NeedsRow(
      {required this.item, required this.onAction, required this.onOpen});

  @override
  State<_NeedsRow> createState() => _NeedsRowState();
}

class _NeedsRowState extends State<_NeedsRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final action = _m(item['action']);
    final tone = _s(item, 'tone');
    // CHANGE #813 — colour carries STATE and nothing else: red overdue, amber
    // due today, green done, grey otherwise. The state is the payload's
    // `tone`; this bar is the only place the row is coloured.
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        key: Key('c813_state_${_s(item, 'id')}'),
        width: 3,
        height: 44,
        margin: EdgeInsets.only(right: Ds.space.x12),
        decoration: BoxDecoration(
          color: _ink(tone),
          borderRadius: Ds.r.rChip,
        ),
      ),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_s(item, 'label'),
                key: Key('c812_needs_${_s(item, 'id')}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x4),
            if (_s(item, 'sub_label').isNotEmpty)
              Text(_s(item, 'sub_label'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.caption),
            SizedBox(height: Ds.space.x4),
            Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x4, children: [
              _Pill(text: _s(item, 'over_label'), tone: tone),
              if (_s(item, 'owner_label').isNotEmpty)
                Text(_s(item, 'owner_label'), style: Ds.t.caption),
            ]),
          ],
        ),
      ),
      SizedBox(width: Ds.space.x8),
      if (action['has'] == true && _s(action, 'label').isNotEmpty)
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
          child: TextButton(
            onPressed: _busy
                ? null
                : () async {
                    // 'rpc' runs the backend's own call; 'route' is a door.
                    if (_s(action, 'kind') == 'rpc' &&
                        _s(action, 'rpc').isNotEmpty) {
                      setState(() => _busy = true);
                      try {
                        await widget.onAction(action);
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                      return;
                    }
                    widget.onOpen({'route_key': _s(action, 'route')});
                  },
            child: Text(_s(action, 'label'),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
    ]);
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final String tone;
  const _Pill({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration:
          BoxDecoration(color: _wash(tone), borderRadius: Ds.r.rChip),
      child: Text(text,
          style: Ds.t.caption
              .copyWith(color: _ink(tone), fontWeight: FontWeight.w500)),
    );
  }
}

// ── Funnel + promised ring ───────────────────────────────────────────────────

class _FunnelCard extends StatelessWidget {
  final Map<String, dynamic> block;
  final Map<String, dynamic> promised;
  final DashboardOpen onOpen;
  const _FunnelCard(
      {required this.block, required this.promised, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final stages = _rows(block['stages']);
    final total = (block['total'] as num?)?.toInt() ?? 0;
    final peak = stages.fold<int>(
        0, (a, s) => math.max(a, (s['count'] as num?)?.toInt() ?? 0));

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: LayoutBuilder(builder: (ctx, box) {
        final wide = box.maxWidth >= 560;
        final ring = _PromisedRing(promised: promised);
        final funnel = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _SectionTitle(_s(block, 'title')),
            SizedBox(height: Ds.space.x12),
            if (stages.isEmpty || total == 0)
              Text(_s(block, 'empty_label'),
                  key: const Key('c812_funnel_empty'),
                  style: Ds.t.bodySecondary)
            else
              for (final s in stages)
                _FunnelBar(stage: s, peak: peak, onOpen: onOpen),
          ],
        );
        if (!wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              funnel,
              SizedBox(height: Ds.space.x24),
              ring,
            ],
          );
        }
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: funnel),
          SizedBox(width: Ds.space.x24),
          ring,
        ]);
      }),
    );
  }
}

class _FunnelBar extends StatelessWidget {
  final Map<String, dynamic> stage;
  final int peak;
  final DashboardOpen onOpen;
  const _FunnelBar(
      {required this.stage, required this.peak, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final n = (stage['count'] as num?)?.toInt() ?? 0;
    final frac = peak <= 0 ? 0.0 : n / peak;
    return InkWell(
      key: Key('c812_stage_${_s(stage, 'key')}'),
      borderRadius: Ds.r.rChip,
      onTap: () => onOpen(stage),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
        child: Row(children: [
          SizedBox(
            width: 88,
            child: Text(_s(stage, 'label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: Ds.r.rChip,
              child: LinearProgressIndicator(
                value: frac.clamp(0.0, 1.0),
                minHeight: 10,
                backgroundColor: Ds.c.bg,
                valueColor: AlwaysStoppedAnimation<Color>(Ds.c.brand),
              ),
            ),
          ),
          SizedBox(width: Ds.space.x8),
          SizedBox(
            width: 40,
            child: Text(_s(stage, 'count_label'),
                textAlign: TextAlign.right,
                style: Ds.t.bodyStrong),
          ),
        ]),
      ),
    );
  }
}

class _PromisedRing extends StatelessWidget {
  final Map<String, dynamic> promised;
  const _PromisedRing({required this.promised});

  @override
  Widget build(BuildContext context) {
    final pct = (promised['pct'] as num?)?.toDouble() ?? 0;
    return SizedBox(
      width: 168,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _SectionTitle(_s(promised, 'title')),
          SizedBox(height: Ds.space.x12),
          Center(
            child: SizedBox(
              width: 96,
              height: 96,
              child: Stack(alignment: Alignment.center, children: [
                CustomPaint(
                  size: const Size(96, 96),
                  painter: _RingPainter(
                      fraction: (pct / 100).clamp(0.0, 1.0),
                      track: Ds.c.divider,
                      ink: Ds.c.brand),
                ),
                Text(_s(promised, 'label'),
                    key: const Key('c812_ring'),
                    textAlign: TextAlign.center,
                    style: Ds.t.bodyStrong),
              ]),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          Text(_s(promised, 'sub_label'),
              textAlign: TextAlign.left, style: Ds.t.caption),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double fraction;
  final Color track;
  final Color ink;
  const _RingPainter(
      {required this.fraction, required this.track, required this.ink});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final inset = rect.deflate(6);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..color = track;
    canvas.drawArc(inset, 0, math.pi * 2, false, base);
    if (fraction <= 0) return;
    canvas.drawArc(
      inset,
      -math.pi / 2,
      math.pi * 2 * fraction,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..strokeCap = StrokeCap.round
        ..color = ink,
    );
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.fraction != fraction || old.ink != ink || old.track != track;
}

// ── Zone cards (super admin) ─────────────────────────────────────────────────

class _ZoneCards extends StatefulWidget {
  final Map<String, dynamic> block;
  final DashboardAction onAction;
  final DashboardOpen onOpen;
  const _ZoneCards(
      {required this.block, required this.onAction, required this.onOpen});

  @override
  State<_ZoneCards> createState() => _ZoneCardsState();
}

/// CHANGE #813 — the zones are a SWIPE, not a grid. A super admin runs a
/// handful of zones and compares them one at a time; the dots say how many
/// there are and which one is in front.
class _ZoneCardsState extends State<_ZoneCards> {
  final PageController _pages = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cards = _rows(widget.block['cards']);
    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SectionTitle(_s(widget.block, 'title')),
        SizedBox(height: Ds.space.x12),
        SizedBox(
          height: 168,
          child: PageView.builder(
            key: const Key('c813_zone_pager'),
            controller: _pages,
            itemCount: cards.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (_, i) => Padding(
              padding: EdgeInsets.only(
                  right: i == cards.length - 1 ? 0 : Ds.space.x12),
              child: _ZoneCard(
                card: cards[i],
                onAction: widget.onAction,
                onOpen: widget.onOpen,
              ),
            ),
          ),
        ),
        SizedBox(height: Ds.space.x12),
        if (cards.length > 1)
          Row(
            key: const Key('c813_zone_dots'),
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < cards.length; i++)
                Container(
                  width: 8,
                  height: 8,
                  margin: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == _index ? Ds.c.brand : Ds.c.divider,
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _ZoneCard extends StatelessWidget {
  final Map<String, dynamic> card;
  final DashboardAction onAction;
  final DashboardOpen onOpen;
  const _ZoneCard(
      {required this.card, required this.onAction, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final metrics = _rows(card['metrics']);
    final action = _m(card['action']);
    final isCurrent = card['is_current'] == true;
    final body = Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: isCurrent ? Ds.c.brand : Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(_s(card, 'zone_label'),
              key: Key('c812_zone_${card['zone_id']}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          Wrap(
            spacing: Ds.space.x16,
            runSpacing: Ds.space.x8,
            children: [
              for (final m in metrics)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_s(m, 'short_label'), style: Ds.t.caption),
                    Text(_s(m, 'value_display'), style: Ds.t.bodyStrong),
                  ],
                ),
            ],
          ),
          if (action['has'] == true && _s(action, 'label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_s(action, 'label'),
                key: Key('c813_zone_action_${card['zone_id']}'),
                style: Ds.t.caption.copyWith(color: Ds.c.brand)),
          ],
        ],
      ),
    );

    if (action['has'] != true) return body;
    // Tapping a zone card runs the backend's own action — the same server-side
    // scope the picker writes, so the whole console follows the zone.
    return InkWell(
      key: Key('c813_zone_tap_${card['zone_id']}'),
      borderRadius: Ds.r.rCard,
      onTap: () {
        if (_s(action, 'kind') == 'rpc' && _s(action, 'rpc').isNotEmpty) {
          onAction(action);
          return;
        }
        onOpen(card);
      },
      child: body,
    );
  }
}

// ── Skeletons (CHANGE #813) ──────────────────────────────────────────────────
//
// Loading is a SHAPE, not a spinner: the blocks that are about to arrive, in
// their own places, so the page does not jump when the payload lands. There is
// no text here on purpose — a skeleton that guesses wording would be inventing
// copy the backend has not sent yet.

class _SkeletonBox extends StatelessWidget {
  final double height;
  final double? width;
  const _SkeletonBox({required this.height, this.width});

  @override
  Widget build(BuildContext context) => Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: Ds.c.divider,
          borderRadius: Ds.r.rChip,
        ),
      );
}

class DashboardV2Skeleton extends StatelessWidget {
  const DashboardV2Skeleton({super.key});

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const Key('c813_skeleton'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SkeletonBox(height: 24, width: 180),
        SizedBox(height: Ds.space.x8),
        const _SkeletonBox(height: 14, width: 240),
        SizedBox(height: Ds.space.x24),
        LayoutBuilder(builder: (ctx, box) {
          final perRow = box.maxWidth >= 1000
              ? 5
              : box.maxWidth >= 700
                  ? 3
                  : 2;
          final gap = Ds.space.x12;
          final w = (box.maxWidth - gap * (perRow - 1)) / perRow;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < perRow; i++)
                SizedBox(
                  width: w,
                  child: _card(Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _SkeletonBox(height: 12, width: 64),
                      SizedBox(height: Ds.space.x12),
                      const _SkeletonBox(height: 24, width: 48),
                      SizedBox(height: Ds.space.x12),
                      const _SkeletonBox(height: 24),
                    ],
                  )),
                ),
            ],
          );
        }),
        SizedBox(height: Ds.space.x24),
        _card(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SkeletonBox(height: 16, width: 120),
            SizedBox(height: Ds.space.x16),
            for (var i = 0; i < 3; i++) ...[
              const _SkeletonBox(height: 14),
              SizedBox(height: Ds.space.x8),
              const _SkeletonBox(height: 12, width: 160),
              SizedBox(height: Ds.space.x16),
            ],
          ],
        )),
        SizedBox(height: Ds.space.x24),
        _card(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SkeletonBox(height: 16, width: 140),
            SizedBox(height: Ds.space.x16),
            for (var i = 0; i < 4; i++) ...[
              const _SkeletonBox(height: 10),
              SizedBox(height: Ds.space.x12),
            ],
          ],
        )),
      ],
    );
  }
}

// ── Shared bits ──────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Text(text, style: Ds.t.subtitle);
  }
}

// ── Universal search ─────────────────────────────────────────────────────────
//
// One box for an order code, a phone number, a pharmacy, a supplier or a
// product. `universal_search(p_q)` groups and labels the results and decides
// which deep link each row is allowed to carry; this sheet prints them.

typedef UniversalSearchRun = Future<Map<String, dynamic>> Function(String query);

Future<void> showUniversalSearch(
  BuildContext context, {
  required UniversalSearchRun search,
  required DashboardOpen onPick,
  required String placeholder,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (_) => UniversalSearchSheet(
        search: search, onPick: onPick, placeholder: placeholder),
  );
}

class UniversalSearchSheet extends StatefulWidget {
  final UniversalSearchRun search;
  final DashboardOpen onPick;
  final String placeholder;

  const UniversalSearchSheet({
    super.key,
    required this.search,
    required this.onPick,
    required this.placeholder,
  });

  @override
  State<UniversalSearchSheet> createState() => _UniversalSearchSheetState();
}

class _UniversalSearchSheetState extends State<UniversalSearchSheet> {
  Map<String, dynamic> _result = const {};
  bool _loading = false;
  int _seq = 0;

  Future<void> _run(String q) async {
    final mine = ++_seq;
    setState(() => _loading = true);
    Map<String, dynamic> r = const {};
    try {
      r = await widget.search(q);
    } catch (_) {
      r = const {};
    }
    // A slower earlier keystroke must never overwrite a newer answer.
    if (!mounted || mine != _seq) return;
    setState(() {
      _result = r;
      _loading = false;
    });
  }

  static const _icons = <String, IconData>{
    'receipt': Icons.receipt_long_outlined,
    'people': Icons.people_outline,
    'inventory': Icons.inventory_2_outlined,
    'medication': Icons.medication_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final groups = _rows(_result['groups']);
    final empty = _s(_result, 'empty_label');
    final hint = _s(_result, 'hint');
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(
              key: const Key('c812_search_field'),
              autofocus: true,
              onChanged: _run,
              decoration: InputDecoration(
                hintText: widget.placeholder,
                prefixIcon: const Icon(Icons.search),
                // CHANGE #813 — no spinner anywhere on this surface. While a
                // query is in flight the RESULT area shows skeleton rows, so
                // the sheet never spins at the user.
                suffixIcon: null,
              ),
            ),
            SizedBox(height: Ds.space.x12),
            Flexible(
              child: groups.isEmpty
                  ? (_loading
                      ? Padding(
                          padding: EdgeInsets.symmetric(
                              vertical: Ds.space.x16),
                          child: Column(
                            key: const Key('c813_search_skeleton'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < 3; i++) ...[
                                const _SkeletonBox(height: 14),
                                SizedBox(height: Ds.space.x8),
                                const _SkeletonBox(height: 12, width: 180),
                                SizedBox(height: Ds.space.x16),
                              ],
                            ],
                          ),
                        )
                      : Padding(
                          padding: EdgeInsets.all(Ds.space.x24),
                          child: Text(hint.isNotEmpty ? hint : empty,
                              key: const Key('c812_search_empty'),
                              style: Ds.t.bodySecondary),
                        ))
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final g in groups) ...[
                          Padding(
                            padding: EdgeInsets.symmetric(
                                vertical: Ds.space.x8),
                            child:
                                Text(_s(g, 'label'), style: Ds.t.caption),
                          ),
                          for (final item in _rows(g['items']))
                            ListTile(
                              key: Key('c812_hit_${_s(item, 'ref_id')}'),
                              contentPadding: EdgeInsets.zero,
                              minVerticalPadding: 12,
                              leading: Icon(
                                  _icons[_s(item, 'icon_key')] ??
                                      Icons.circle_outlined,
                                  color: Ds.c.textSecondary),
                              title: Text(_s(item, 'title'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Ds.t.body),
                              subtitle: _s(item, 'subtitle').isEmpty
                                  ? null
                                  : Text(_s(item, 'subtitle'),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Ds.t.caption),
                              onTap: () {
                                Navigator.of(context).pop();
                                widget.onPick(item);
                              },
                            ),
                        ],
                      ],
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}
