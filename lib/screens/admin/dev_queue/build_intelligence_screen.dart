import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../utils/render_log.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// CMD #1824 — Build intelligence: what the registry has learned, and what it
/// is now enforcing.
///
/// This screen is a PRINTER. `dev_build_intelligence()` returns the title, the
/// window it measures over, two headline tiles, and every section with its own
/// rows — repeat causes with their before/after counts, waste classes with the
/// knob each maps to, open proposals, and the lessons that have stopped
/// earning their place. Every label, number, percentage, tone and empty state
/// is a backend string. Nothing here divides, rounds, pluralises, compares a
/// count to a threshold or picks a colour: a tone NAME is resolved to the
/// design palette and that is the whole of this file's judgement.
///
/// Structural rules, all deliberate:
///   * tiles and rows render in PAYLOAD ORDER — no sort, no ranking;
///   * `has:false` on the payload draws nothing at all;
///   * an absent sub-line is omitted, never dashed;
///   * a section whose `kind` this build has never heard of is skipped in
///     silence, so the backend can add one without a deploy;
///   * the only two taps — Apply and Dismiss on a proposal — send the
///     proposal's own id and print the backend's `message` back.
class BuildIntelligenceScreen extends StatefulWidget {
  final DevQueueService? service;

  /// Injected only by the protected test, which hands over a payload instead
  /// of making a network call. Production always leaves these null.
  final Future<Map<String, dynamic>> Function()? loader;
  final Future<Map<String, dynamic>> Function(int id, String pin)? applier;
  final Future<Map<String, dynamic>> Function(int id)? dismisser;

  const BuildIntelligenceScreen(
      {super.key, this.service, this.loader, this.applier, this.dismisser});

  @override
  State<BuildIntelligenceScreen> createState() =>
      _BuildIntelligenceScreenState();
}

class _BuildIntelligenceScreenState extends State<BuildIntelligenceScreen> {
  late final DevQueueService _svc = widget.service ?? DevQueueService();
  Map<String, dynamic> _r = const {};
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
          ? await widget.loader!()
          : await _svc.buildIntelligence();
      if (!mounted) return;
      setState(() {
        _r = r;
        _error = (r['ok'] == false) ? (r['message'] ?? '').toString() : '';
        _loading = false;
      });
      RenderLog.write('build_intel_tiles', _tiles.length);
      RenderLog.write('build_intel_sections', _sections.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  List<Map<String, dynamic>> _maps(dynamic v) => ((v as List?) ?? const [])
      .whereType<Map>()
      .map((e) => e.cast<String, dynamic>())
      .toList();

  List<Map<String, dynamic>> get _tiles => _maps(_r['tiles']);
  List<Map<String, dynamic>> get _sections => _maps(_r['sections']);

  String _s(Map m, String k) => (m[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final has = _r['has'] != false;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar:
          AppBar(title: Text(_s(_r, 'title').isEmpty ? ' ' : _s(_r, 'title'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
          children: [
            if (_loading)
              ..._skeletons()
            else if (_error.isNotEmpty)
              _errorCard()
            else if (has) ...[
              _header(),
              SizedBox(height: Ds.space.x16),
              for (final t in _tiles) ..._tile(t),
              SizedBox(height: Ds.space.x8),
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

  // ── the window: the panel says what it is measuring over ──────────────
  Widget _header() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_s(_r, 'subtitle').isNotEmpty)
            Text(_s(_r, 'subtitle'), style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x8),
          Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
            if (_s(_r, 'window_label').isNotEmpty)
              ToneChip(
                  label: _s(_r, 'window_label'), tone: toneByName('neutral')),
            if (_s(_r, 'since_label').isNotEmpty)
              ToneChip(
                  label: _s(_r, 'since_label'), tone: toneByName('neutral')),
          ]),
          if (_s(_r, 'window_hint').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(_r, 'window_hint'), style: Ds.t.caption),
          ],
        ],
      );

  // ── a headline tile: label, the backend's value, its sub-line, its tone ─
  List<Widget> _tile(Map<String, dynamic> t) {
    if (t['has'] == false) return const [];
    final tone = toneByName(_s(t, 'tone'));
    return [
      _Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_s(t, 'label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(_s(t, 'value'), style: Ds.t.title.copyWith(color: tone.fg)),
          if (_s(t, 'sub').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(t, 'sub'), style: Ds.t.bodySecondary),
          ],
        ]),
      ),
      SizedBox(height: Ds.space.x12),
    ];
  }

  // ── one section, by the kind the payload declares ──────────────────────
  List<Widget> _section(Map<String, dynamic> s) {
    final kind = _s(s, 'kind');
    if (kind != 'rows' && kind != 'proposals') return const [];
    final rows = _maps(s['rows']);
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
          else
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(color: Ds.c.divider, height: Ds.space.x16),
              kind == 'proposals' ? _proposal(rows[i]) : _row(rows[i]),
            ],
        ]),
      ),
      SizedBox(height: Ds.space.x16),
    ];
  }

  // A plain row: label on the left, the backend's value on the right in the
  // backend's tone, then the optional before/after + enforcing chips and the
  // optional sub-line. Absence is absence.
  Widget _row(Map<String, dynamic> r) {
    final tone = toneByName(_s(r, 'tone'));
    final chips = <String>[
      if (_s(r, 'before_label').isNotEmpty) _s(r, 'before_label'),
      if (_s(r, 'after_label').isNotEmpty) _s(r, 'after_label'),
      if (_s(r, 'knob_label').isNotEmpty) _s(r, 'knob_label'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(_s(r, 'label'), style: Ds.t.body)),
        SizedBox(width: Ds.space.x12),
        Text(_s(r, 'value'),
            textAlign: TextAlign.right,
            style: Ds.t.bodyStrong.copyWith(color: tone.fg)),
      ]),
      if (chips.isNotEmpty || _s(r, 'enforcing_label').isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
          for (final c in chips) ToneChip(label: c, tone: toneByName('neutral')),
          if (_s(r, 'enforcing_label').isNotEmpty)
            ToneChip(label: _s(r, 'enforcing_label'), tone: tone),
        ]),
      ],
      if (_s(r, 'sub').isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(_s(r, 'sub'), style: Ds.t.caption),
      ],
      if (_s(r, 'text').isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(_s(r, 'text'), style: Ds.t.bodySecondary),
      ],
    ]);
  }

  // A proposal row: the same printer plus two actions the backend allows.
  Widget _proposal(Map<String, dynamic> r) {
    final tone = toneByName(_s(r, 'tone'));
    final id = r['id'] is int ? r['id'] as int : int.tryParse(_s(r, 'id'));
    final canApply = r['can_apply'] == true && id != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(_s(r, 'label'), style: Ds.t.body)),
        SizedBox(width: Ds.space.x12),
        Text(_s(r, 'value'),
            textAlign: TextAlign.right,
            style: Ds.t.bodyStrong.copyWith(color: tone.fg)),
      ]),
      if (_s(r, 'sub').isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(_s(r, 'sub'), style: Ds.t.caption),
      ],
      if (_s(r, 'opened_label').isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(_s(r, 'opened_label'), style: Ds.t.caption),
      ],
      if (canApply) ...[
        SizedBox(height: Ds.space.x12),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () => _apply(id, _s(r, 'apply_label')),
                child: Text(_s(r, 'apply_label')),
              ),
            ),
          ),
          if (_s(r, 'dismiss_label').isNotEmpty) ...[
            SizedBox(width: Ds.space.x12),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: () => _dismiss(id),
                child: Text(_s(r, 'dismiss_label')),
              ),
            ),
          ],
        ]),
      ],
    ]);
  }

  // Apply asks for the safety PIN and forwards it; the backend verifies it
  // and its `message` is what the toast prints — success or refusal alike.
  Future<void> _apply(int id, String title) async {
    final pin = await _askPin(title);
    if (pin == null || !mounted) return;
    final res = widget.applier != null
        ? await widget.applier!(id, pin)
        : await _svc.buildProposalApply(id, pin);
    _toast(res);
    await _load();
  }

  Future<void> _dismiss(int id) async {
    final res = widget.dismisser != null
        ? await widget.dismisser!(id)
        : await _svc.buildProposalDismiss(id);
    _toast(res);
    await _load();
  }

  void _toast(Map<String, dynamic> res) {
    if (!mounted) return;
    final msg = _s(res, 'message');
    if (msg.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<String?> _askPin(String title) async {
    // No controller: the sheet's own field reports its text and nothing has
    // to be disposed while the sheet is still animating away.
    var typed = '';
    final v = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16, Ds.space.x16,
            MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          TextField(
            onChanged: (t) => typed = t,
            obscureText: true,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(hintText: _s(_r, 'pin_hint')),
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: () => Navigator.of(ctx).pop(typed.trim()),
              child: Text(title),
            ),
          ),
        ]),
      ),
    );
    return (v == null || v.isEmpty) ? null : v;
  }

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
                onPressed: _load,
                child: Text(_s(_r, 'retry_label').isEmpty
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
