import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../utils/render_log.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// CMD #1820 — the Token dashboard: where every token and rupee went.
///
/// This screen is a PRINTER. `dev_token_report()` returns the title, the scope
/// chips, the headline, the self-check, every section with its own columns and
/// rows, and every cell string — rupees, token counts, percentages, ratios and
/// em-dashes included. Nothing here adds, divides, formats a number, pluralises
/// a word or picks a colour: a tone NAME is resolved to the design palette and
/// that is the whole of this file's judgement.
///
/// Two structural rules, both deliberate:
///   * sections render in PAYLOAD ORDER — no sort, no reordering by importance;
///   * a section whose `kind` this build has never heard of is skipped in
///     silence, so the backend can add one without a deploy.
class TokenDashboardScreen extends StatefulWidget {
  final DevQueueService? service;

  /// Injected only by the protected test, which hands over a payload instead of
  /// making a network call. Production always leaves this null.
  final Future<Map<String, dynamic>> Function(String scope)? loader;

  const TokenDashboardScreen({super.key, this.service, this.loader});

  @override
  State<TokenDashboardScreen> createState() => _TokenDashboardScreenState();
}

class _TokenDashboardScreenState extends State<TokenDashboardScreen> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();
  Map<String, dynamic> _r = const {};
  String _scope = 'today';
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = widget.loader != null
          ? await widget.loader!(_scope)
          : await _svc.tokenReport(_scope);
      if (!mounted) return;
      setState(() {
        _r = r;
        _error = (r['ok'] == false) ? (r['message'] ?? '').toString() : '';
        _loading = false;
      });
      RenderLog.write('token_dashboard_sections', _sections.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _sections => ((_r['sections'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();

  String _s(Map m, String k) => (m[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final scope = (_r['scope'] as Map?)?.cast<String, dynamic>() ?? const {};
    final options = ((scope['options'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_r, 'title').isEmpty ? ' ' : _s(_r, 'title'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
          children: [
            if (options.isNotEmpty) _scopeBar(options),
            if (_loading) ...[
              SizedBox(height: Ds.space.x16),
              ..._skeletons(),
            ] else if (_error.isNotEmpty)
              _errorCard()
            else ...[
              SizedBox(height: Ds.space.x16),
              _headline(),
              SizedBox(height: Ds.space.x24),
              for (final s in _sections) ..._section(s),
              if (_s(_r, 'footnote').isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                Text(_s(_r, 'footnote'), style: Ds.t.caption),
              ],
            ],
          ],
        ),
      ),
    );
  }

  // ── the scope picker: the backend names the windows and says which is on ──
  Widget _scopeBar(List<Map<String, dynamic>> options) => Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: [
          for (final o in options)
            _ScopeChip(
              label: _s(o, 'label'),
              selected: o['selected'] == true,
              onTap: () {
                setState(() => _scope = _s(o, 'key'));
                _load();
              },
            ),
        ],
      );

  Widget _headline() {
    final h = (_r['headline'] as Map?)?.cast<String, dynamic>() ?? const {};
    final sc = (_r['selfcheck'] as Map?)?.cast<String, dynamic>() ?? const {};
    final tone = toneByName(_s(sc, 'tone'));
    return _Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_s(h, 'label'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Text(_s(h, 'value'), style: Ds.t.display),
        SizedBox(height: Ds.space.x4),
        Text(_s(h, 'sub'), style: Ds.t.bodySecondary),
        if (_s(_r, 'basis_label').isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Text(_s(_r, 'basis_label'), style: Ds.t.caption),
        ],
        if (sc.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration:
                BoxDecoration(color: tone.bg, borderRadius: Ds.r.rButton),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text(_s(sc, 'label'),
                        style: Ds.t.bodyStrong.copyWith(color: tone.fg))),
                Text(_s(sc, 'value'),
                    style: Ds.t.bodyStrong.copyWith(color: tone.fg)),
              ]),
              if (_s(sc, 'sub').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(_s(sc, 'sub'),
                    style: Ds.t.caption.copyWith(color: tone.fg)),
              ],
            ]),
          ),
        ],
        SizedBox(height: Ds.space.x12),
        Row(children: [
          if (_s(_r, 'zone_label').isNotEmpty)
            ToneChip(label: _s(_r, 'zone_label'), tone: toneByName('neutral')),
          if (_s(_r, 'date_label').isNotEmpty) ...[
            SizedBox(width: Ds.space.x8),
            ToneChip(label: _s(_r, 'date_label'), tone: toneByName('neutral')),
          ],
        ]),
      ]),
    );
  }

  // ── one section, by the kind the payload declares ────────────────────────
  List<Widget> _section(Map<String, dynamic> s) {
    final kind = _s(s, 'kind');
    final rows = ((s['rows'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    // Forward compatibility: a kind this build cannot draw is skipped whole,
    // never rendered as an empty box with a heading over it.
    if (kind != 'table' && kind != 'bars' && kind != 'tiles') return const [];
    return [
      _Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_s(s, 'title'), style: Ds.t.subtitle),
          if (_s(s, 'sub').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(s, 'sub'), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x12),
          if (rows.isEmpty)
            Text(_s(s, 'empty_label'), style: Ds.t.bodySecondary)
          else if (kind == 'table')
            _table(s, rows)
          else if (kind == 'bars')
            _bars(rows)
          else
            _tiles(rows),
        ]),
      ),
      SizedBox(height: Ds.space.x16),
    ];
  }

  // A table wide enough to need it scrolls itself; the page never does.
  Widget _table(Map<String, dynamic> s, List<Map<String, dynamic>> rows) {
    final cols = ((s['columns'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: _minTableWidth(cols.length)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            children: [
              for (var i = 0; i < cols.length; i++)
                _cellBox(
                  first: i == 0,
                  child: Text(_s(cols[i], 'label'),
                      textAlign: _align(_s(cols[i], 'align')),
                      style: Ds.t.caption),
                ),
            ],
          ),
          Divider(color: Ds.c.divider, height: Ds.space.x16),
          for (final r in rows) ..._tableRow(cols, r),
        ]),
      ),
    );
  }

  List<Widget> _tableRow(
      List<Map<String, dynamic>> cols, Map<String, dynamic> r) {
    final cells = ((r['cells'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    final tone = r['tone'] == null ? null : toneByName(_s(r, 'tone'));
    return [
      Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < cells.length; i++)
                _cellBox(
                  first: i == 0,
                  child: Column(
                    crossAxisAlignment: i == 0
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.end,
                    children: [
                      Text(_s(cells[i], 'text'),
                          textAlign: _align(_s(cells[i], 'align')),
                          style: tone == null || i > 0
                              ? Ds.t.body
                              : Ds.t.bodyStrong.copyWith(color: tone.fg)),
                      if (_s(cells[i], 'sub').isNotEmpty)
                        Text(_s(cells[i], 'sub'), style: Ds.t.caption),
                    ],
                  ),
                ),
            ],
          ),
          if (_s(r, 'sub').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(r, 'sub'), style: Ds.t.caption),
          ],
        ]),
      ),
      Divider(color: Ds.c.divider, height: Ds.space.x4),
    ];
  }

  Widget _cellBox({required bool first, required Widget child}) => first
      ? SizedBox(width: _firstColWidth, child: child)
      : SizedBox(width: _colWidth, child: child);

  double get _firstColWidth => Ds.space.x48 * 4;
  double get _colWidth => Ds.space.x32 * 3;
  double _minTableWidth(int cols) =>
      _firstColWidth + (cols <= 1 ? 0 : (cols - 1) * _colWidth);

  TextAlign _align(String a) => a == 'right' ? TextAlign.right : TextAlign.left;

  // A bar's width is the backend's own `pct`. Dart never derives it from the
  // numbers beside it — the value column is a formatted string, not a number.
  Widget _bars(List<Map<String, dynamic>> rows) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in rows) ...[
            Row(children: [
              Expanded(child: Text(_s(r, 'label'), style: Ds.t.body)),
              Text(_s(r, 'value'), style: Ds.t.bodyStrong),
            ]),
            SizedBox(height: Ds.space.x4),
            ClipRRect(
              borderRadius: Ds.r.rChip,
              child: LinearProgressIndicator(
                value: _pct(r) / 100.0,
                minHeight: Ds.space.x8,
                backgroundColor: Ds.c.divider,
                valueColor:
                    AlwaysStoppedAnimation<Color>(toneByName(_s(r, 'tone')).fg),
              ),
            ),
            if (_s(r, 'sub').isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(_s(r, 'sub'), style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x12),
          ],
        ],
      );

  double _pct(Map<String, dynamic> r) {
    final v = r['pct'];
    if (v is num) return v.toDouble().clamp(0, 100).toDouble();
    return 0;
  }

  Widget _tiles(List<Map<String, dynamic>> rows) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in rows) ...[
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(_s(r, 'label'), style: Ds.t.body)),
              Text(_s(r, 'value'),
                  style: Ds.t.bodyStrong
                      .copyWith(color: toneByName(_s(r, 'tone')).fg)),
            ]),
            if (_s(r, 'sub').isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(_s(r, 'sub'), style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x16),
          ],
        ],
      );

  // Loading is a skeleton, not a bare spinner (design QA, check 6).
  List<Widget> _skeletons() => [
        for (var i = 0; i < 3; i++) ...[
          Container(
            height: Ds.space.x48 * 2,
            decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1),
          ),
          SizedBox(height: Ds.space.x16),
        ],
      ];

  Widget _errorCard() => _Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_error, style: Ds.t.body),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
                onPressed: _load, child: Text(_s(_r, 'retry_label').isEmpty
                    ? 'Retry'
                    : _s(_r, 'retry_label'))),
          ),
        ]),
      );
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1),
        child: child,
      );
}

class _ScopeChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ScopeChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: Ds.r.rChip,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x12),
          decoration: BoxDecoration(
            color: selected ? Ds.c.brandSoft : Ds.c.surface,
            borderRadius: Ds.r.rChip,
            border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
          ),
          child: Text(label,
              style: selected
                  ? Ds.t.bodyStrong.copyWith(color: Ds.c.brand)
                  : Ds.t.body),
        ),
      );
}
