// CHANGE #312 — Admin ▸ More ▸ Feature gaps.
//
// The Om-facing surface over the feature_gaps register: every finding the
// per-role journey audits file, counted at the top, filtered by surface / type
// / severity / status, sorted worst-first, and approved or rejected in place.
//
// This file words NOTHING and computes NOTHING. The title, the subtitle, every
// filter chip, every enum's word AND its colour tone, the counts, the field
// labels, the button captions, the empty state and the toast all arrive from
// feature_gaps_list() / feature_gap_set_status(). A tone is a design-token NAME
// (brand/success/warning/danger/info/neutral), never a hex — so a recolour via
// ui_design_set() carries this screen with it.
//
// Both RPCs are injected, so the screen carries no Supabase import and pumps on
// the Dart VM; home_shell supplies the live calls.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

/// `feature_gaps_list(p_surface, p_type, p_severity, p_status, p_sort)`.
typedef FeatureGapsListRpc =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params);

/// `feature_gap_set_status(p_id, p_status)`.
typedef FeatureGapStatusRpc =
    Future<Map<String, dynamic>> Function(int id, String status);

class FeatureGapsScreen extends StatefulWidget {
  final FeatureGapsListRpc listRpc;
  final FeatureGapStatusRpc statusRpc;

  const FeatureGapsScreen({
    super.key,
    required this.listRpc,
    required this.statusRpc,
  });

  @override
  State<FeatureGapsScreen> createState() => _FeatureGapsScreenState();
}

class _FeatureGapsScreenState extends State<FeatureGapsScreen> {
  /// The chosen value of every filter, keyed by the backend's own filter key.
  /// Seeded from the payload on each load, so the SERVER decides the defaults.
  final Map<String, String> _picked = <String, String>{};

  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final payload = await widget.listRpc(<String, dynamic>{
        'p_surface': _picked['surface'] ?? 'all',
        'p_type': _picked['type'] ?? 'all',
        'p_severity': _picked['severity'] ?? 'all',
        'p_status': _picked['status'] ?? 'all',
        'p_sort': _picked['sort'] ?? 'severity',
      });
      if (!mounted) return;
      for (final f in (payload['filters'] as List? ?? const [])) {
        if (f is! Map) continue;
        final key = '${f['key'] ?? ''}';
        final value = f['value'];
        if (key.isNotEmpty && value is String) _picked[key] = value;
      }
      setState(() {
        _data = payload;
        _loading = false;
      });
      RenderLog.write('c312_feature_gaps', '${_rows.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _rows =>
      ((_data?['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  String _s(String key) => '${_data?[key] ?? ''}';

  Future<void> _act(Map<String, dynamic> row, String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic>? res;
    try {
      res = await widget.statusRpc(
          (row['id'] as num?)?.toInt() ?? 0, _statusFor(action));
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': '$e'};
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final message = '${res['message'] ?? ''}';
    if (message.isNotEmpty) {
      showToast(context, message, isError: res['ok'] != true);
    }
    if (res['ok'] == true) await _load();
  }

  /// The register's own vocabulary: an action key IS the status it writes.
  String _statusFor(String action) =>
      action == 'reject' ? 'rejected' : 'approved';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s('title'), style: Ds.t.subtitle),
        actions: [
          IconButton(
            tooltip: _s('refresh'),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const _Skeleton()
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      if (_s('subtitle').isNotEmpty) ...[
                        Text(_s('subtitle'), style: Ds.t.bodySecondary),
                        SizedBox(height: Ds.space.x16),
                      ],
                      _FilterBar(
                        filters: (_data?['filters'] as List?) ?? const [],
                        busy: _busy,
                        onPick: (key, value) {
                          if (_picked[key] == value) return;
                          _picked[key] = value;
                          _load();
                        },
                      ),
                      SizedBox(height: Ds.space.x16),
                      _CountsCard(counts: _data?['counts']),
                      SizedBox(height: Ds.space.x24),
                      ..._body(),
                      SizedBox(height: Ds.space.x48),
                    ],
                  ),
                ),
    );
  }

  List<Widget> _body() {
    final rows = _rows;
    if (rows.isEmpty) {
      return [
        _EmptyState(title: _s('empty_title'), body: _s('empty_body')),
      ];
    }
    final labels = (_data?['field_labels'] as Map?) ?? const {};
    return [
      for (final row in rows)
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: FeatureGapCard(
            row: row,
            fieldLabels: labels,
            busy: _busy,
            onAction: (action) => _act(row, action),
          ),
        ),
    ];
  }
}

/// A backend tone NAME → the design token it stands for. The only mapping in
/// this file, and it maps onto `Ds`, never onto a literal.
Color toneColor(Object? tone) {
  switch ('$tone') {
    case 'brand':
      return Ds.c.brand;
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'info':
      return Ds.c.info;
    default:
      return Ds.c.textSecondary;
  }
}

Color toneSoft(Object? tone) {
  switch ('$tone') {
    case 'brand':
      return Ds.c.brandSoft;
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'info':
      return Ds.c.infoSoft;
    default:
      return Ds.c.bg;
  }
}

/// One compact chip per filter dimension — "Surface: All" — opening the
/// backend's own option list. Five dropdown chips fit one row at 360 px, where
/// five rows of choice chips would not.
class _FilterBar extends StatelessWidget {
  final List<dynamic> filters;
  final bool busy;
  final void Function(String key, String value) onPick;

  const _FilterBar({
    required this.filters,
    required this.busy,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: [
        for (final raw in filters)
          if (raw is Map) _chip(Map<String, dynamic>.from(raw)),
      ],
    );
  }

  Widget _chip(Map<String, dynamic> filter) {
    final key = '${filter['key'] ?? ''}';
    final options = ((filter['options'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final value = '${filter['value'] ?? ''}';
    final current = options.firstWhere(
      (o) => '${o['value']}' == value,
      orElse: () => const <String, dynamic>{},
    );
    return PopupMenuButton<String>(
      enabled: !busy,
      tooltip: '${filter['label'] ?? ''}',
      onSelected: (v) => onPick(key, v),
      itemBuilder: (_) => [
        for (final o in options)
          PopupMenuItem<String>(
            value: '${o['value']}',
            child: Text('${o['label'] ?? ''}', style: Ds.t.body),
          ),
      ],
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${filter['label'] ?? ''}', style: Ds.t.caption),
          SizedBox(width: Ds.space.x4),
          Text('${current['label'] ?? ''}', style: Ds.t.bodyStrong),
          Icon(Icons.expand_more, size: Ds.t.bodySize, color: Ds.c.textSecondary),
        ]),
      ),
    );
  }
}

/// The header rollup: the view's total, the register's size, and every
/// non-empty bucket the backend chose to send.
class _CountsCard extends StatelessWidget {
  final Object? counts;
  const _CountsCard({required this.counts});

  @override
  Widget build(BuildContext context) {
    final c = counts is Map ? Map<String, dynamic>.from(counts as Map) : null;
    if (c == null) return const SizedBox.shrink();
    final groups = ((c['groups'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((g) => ((g['items'] as List?) ?? const []).isNotEmpty)
        .toList();
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${c['title'] ?? ''}', style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic, children: [
          Text('${c['total_label'] ?? ''}', style: Ds.t.title),
          SizedBox(width: Ds.space.x8),
          Flexible(
            child: Text('${c['register_label'] ?? ''}',
                style: Ds.t.caption, overflow: TextOverflow.ellipsis),
          ),
        ]),
        for (final g in groups) ...[
          SizedBox(height: Ds.space.x16),
          Text('${g['label'] ?? ''}', style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final raw in (g['items'] as List? ?? const []))
                if (raw is Map)
                  _CountPill(item: Map<String, dynamic>.from(raw)),
            ],
          ),
        ],
      ]),
    );
  }
}

class _CountPill extends StatelessWidget {
  final Map<String, dynamic> item;
  const _CountPill({required this.item});

  @override
  Widget build(BuildContext context) {
    final fg = toneColor(item['tone']);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: toneSoft(item['tone']),
        borderRadius: Ds.r.rChip,
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('${item['label'] ?? ''}',
            style: Ds.t.caption.copyWith(color: fg)),
        SizedBox(width: Ds.space.x8),
        Text('${item['count'] ?? ''}',
            style: Ds.t.bodyStrong.copyWith(color: fg)),
      ]),
    );
  }
}

/// One finding. Every chip, label and button here is a payload string.
class FeatureGapCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final Map fieldLabels;
  final bool busy;
  final ValueChanged<String> onAction;

  const FeatureGapCard({
    super.key,
    required this.row,
    required this.fieldLabels,
    required this.busy,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final actions = ((row['actions'] as List?) ?? const [])
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${row['title'] ?? ''}', style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x8),
        Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
          _Tag(label: '${row['severity_label'] ?? ''}', tone: row['severity_tone']),
          _Tag(label: '${row['type_label'] ?? ''}', tone: row['type_tone']),
          _Tag(label: '${row['surface_label'] ?? ''}', tone: null),
          _Tag(label: '${row['status_label'] ?? ''}', tone: row['status_tone']),
        ]),
        _field(fieldLabels['journey_step'], row['journey_step']),
        _field(fieldLabels['evidence'], row['evidence']),
        _field(fieldLabels['suggestion'], row['suggestion']),
        _field(fieldLabels['effort'], row['effort_guess']),
        _field(fieldLabels['notes'], row['notes']),
        _field(fieldLabels['dev_command'], row['dev_command_id']),
        _field(fieldLabels['found'], row['found_label']),
        if (actions.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          Row(children: [
            for (final a in actions) ...[
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed:
                        busy ? null : () => onAction('${a['action'] ?? ''}'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: toneColor(a['tone']),
                      side: BorderSide(color: toneColor(a['tone'])),
                      shape: RoundedRectangleBorder(
                          borderRadius: Ds.r.rButton),
                    ),
                    child: Text('${a['label'] ?? ''}'),
                  ),
                ),
              ),
              if (a != actions.last) SizedBox(width: Ds.space.x12),
            ],
          ]),
        ],
      ]),
    );
  }

  /// A field with nothing in it is an ABSENCE — it draws no row at all, rather
  /// than a dash this file would have had to invent.
  Widget _field(Object? label, Object? value) {
    final text = '${value ?? ''}';
    if (text.isEmpty || '$label'.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$label', style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Text(text, style: Ds.t.body),
      ]),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Object? tone;
  const _Tag({required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label,
          style: Ds.t.caption.copyWith(color: toneColor(tone))),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String title;
  final String body;
  const _EmptyState({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(children: [
        Text(title, style: Ds.t.subtitle, textAlign: TextAlign.center),
        SizedBox(height: Ds.space.x8),
        Text(body, style: Ds.t.caption, textAlign: TextAlign.center),
      ]),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: List.generate(
        4,
        (_) => Container(
          height: Ds.touch.listRowMinHeight * 2,
          margin: EdgeInsets.only(bottom: Ds.space.x12),
          decoration:
              BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message, style: Ds.t.caption, textAlign: TextAlign.center),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton(
                onPressed: onRetry, child: const Icon(Icons.refresh)),
          ),
        ]),
      ),
    );
  }
}
