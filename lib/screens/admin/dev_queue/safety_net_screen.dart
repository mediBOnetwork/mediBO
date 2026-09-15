import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// CHANGE #636 — the machine-generated safety net.
///
/// This screen is a PRINTER. `autotest_safety_net_home()` is the whole page:
/// the title, the four tiles, every section heading, every row's title, sub
/// line and badge, and the tone each one wears. Nothing here counts a check,
/// formats a number, pluralises a word or decides that something is bad — a
/// count of "37,280 checks" is a backend string, and a red row is red because
/// the payload said `tone: danger`.
///
/// Reachable at: Dev Queue → Runner control card (tap to expand) → Safety net.
class SafetyNetScreen extends StatefulWidget {
  final DevQueueService? service;
  const SafetyNetScreen({super.key, this.service});

  @override
  State<SafetyNetScreen> createState() => _SafetyNetScreenState();
}

class _SafetyNetScreenState extends State<SafetyNetScreen> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    Map<String, dynamic> p = const {};
    try {
      p = await _svc.safetyNetHome();
    } catch (_) {/* an empty payload draws the empty state, never a crash */}
    if (!mounted) return;
    setState(() {
      _p = p;
      _loading = false;
    });
  }

  Future<void> _run() async {
    setState(() => _running = true);
    try {
      await _svc.safetyNetRun();
    } catch (_) {/* the reload below reports whatever actually landed */}
    if (!mounted) return;
    setState(() => _running = false);
    await _load();
  }

  List<Map<String, dynamic>> _list(String key) =>
      ((_p[key] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();

  String _s(String key) => (_p[key] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final tiles = _list('tiles');
    final sections = _list('sections');
    final run = (_p['run'] as Map?)?.cast<String, dynamic>() ?? const {};
    final hasRun = (_p['has_run'] ?? false) == true;

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        elevation: 0,
        foregroundColor: Ds.c.text,
        title: Text(_s('title'), style: Ds.t.subtitle),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: Ds.c.divider),
        ),
      ),
      body: _loading
          ? _skeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                    Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
                children: [
                  if (_s('subtitle').isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(bottom: Ds.space.x16),
                      child: Text(_s('subtitle'), style: Ds.t.caption),
                    ),
                  if (hasRun) _runHeader(run),
                  if (!hasRun) _emptyState(),
                  if (tiles.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x16),
                    _tileGrid(tiles),
                  ],
                  SizedBox(height: Ds.space.x24),
                  _runButton(),
                  for (final s in sections) ...[
                    SizedBox(height: Ds.space.x24),
                    _section(s),
                  ],
                  if (_s('footnote').isNotEmpty) ...[
                    SizedBox(height: Ds.space.x24),
                    Text(_s('footnote'), style: Ds.t.caption),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              height: Ds.space.x48 + Ds.space.x24,
              margin: EdgeInsets.only(bottom: Ds.space.x12),
              decoration: BoxDecoration(
                  color: Ds.c.surface, borderRadius: Ds.r.rCard),
            ),
        ],
      );

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: child,
      );

  Widget _emptyState() => _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_s('empty_title'), style: Ds.t.body),
          SizedBox(height: Ds.space.x4),
          Text(_s('empty_sub'), style: Ds.t.caption),
        ]),
      );

  Widget _runHeader(Map<String, dynamic> run) {
    final tone = toneByName((run['status_tone'] ?? 'info').toString());
    return _card(
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${run['label'] ?? ''}', style: Ds.t.body),
            SizedBox(height: Ds.space.x4),
            Text('${run['when_label'] ?? ''} · ${run['seed_label'] ?? ''}',
                style: Ds.t.caption),
          ]),
        ),
        SizedBox(width: Ds.space.x12),
        ToneChip(label: '${run['status_label'] ?? ''}', tone: tone),
      ]),
    );
  }

  Widget _tileGrid(List<Map<String, dynamic>> tiles) => LayoutBuilder(
        builder: (context, box) {
          final cols = box.maxWidth >= 720 ? 4 : 2;
          final gap = Ds.space.x12;
          final w = (box.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final t in tiles) SizedBox(width: w, child: _tile(t)),
            ],
          );
        },
      );

  Widget _tile(Map<String, dynamic> t) {
    final tone = toneByName((t['tone'] ?? 'info').toString());
    return Container(
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${t['label'] ?? ''}', style: Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Text('${t['value'] ?? ''}',
            style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
        SizedBox(height: Ds.space.x4),
        Align(
          alignment: Alignment.centerLeft,
          child: ToneChip(label: '${t['sub'] ?? ''}', tone: tone),
        ),
      ]),
    );
  }

  Widget _runButton() => SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: ElevatedButton(
          onPressed: _running ? null : _run,
          style: ElevatedButton.styleFrom(
            backgroundColor: Ds.c.brand,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          child: Text(_running ? _s('running_label') : _s('run_label'),
              style: Ds.t.body.copyWith(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ),
      );

  Widget _section(Map<String, dynamic> s) {
    final rows = ((s['rows'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${s['title'] ?? ''}', style: Ds.t.subtitle),
      SizedBox(height: Ds.space.x8),
      _card(
        child: rows.isEmpty
            ? Text(_s('empty_row'), style: Ds.t.caption)
            : Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0)
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
                        child: Container(height: 1, color: Ds.c.divider),
                      ),
                    _row(rows[i]),
                  ],
                ],
              ),
      ),
    ]);
  }

  Widget _row(Map<String, dynamic> r) {
    final tone = toneByName((r['tone'] ?? 'info').toString());
    final badge = (r['badge'] ?? '').toString();
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${r['title'] ?? ''}', style: Ds.t.body),
          if ('${r['sub'] ?? ''}'.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text('${r['sub']}', style: Ds.t.caption),
          ],
        ]),
      ),
      if (badge.isNotEmpty) ...[
        SizedBox(width: Ds.space.x12),
        ToneChip(label: badge, tone: tone),
      ],
    ]);
  }
}
