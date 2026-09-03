import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../code_resolver_page.dart';

/// CHANGE #471 — Money › Reconciliation.
///
/// The nightly run compares the money surfaces against each other and records
/// anything that disagrees, to the paisa. This screen prints that answer and
/// decides nothing: every heading, sentence, rupee figure, status word, tone
/// and button label arrives from `recon_home()` / `recon_run_detail()` already
/// worded and formatted. There is not one rupee sign in this file.
///
/// The one judgement the app is allowed to make is navigation, and even that
/// is bounded: a finding is tappable only when its backend `route` is one this
/// build actually has a destination for. An unknown route renders as plain
/// text rather than a chip that goes nowhere — a new route in the payload is
/// forward-compatible by construction.
typedef ReconRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

Future<Map<String, dynamic>> _liveRpc(
    String fn, Map<String, dynamic> params) async {
  final raw = await Supabase.instance.client.rpc(fn, params: params);
  final row = raw is List ? (raw.isEmpty ? const {} : raw.first) : raw;
  return Map<String, dynamic>.from((row ?? const {}) as Map);
}

class ReconScreen extends StatefulWidget {
  final ReconRpc? rpc;
  const ReconScreen({super.key, this.rpc});

  @override
  State<ReconScreen> createState() => _ReconScreenState();
}

class _ReconScreenState extends State<ReconScreen> {
  late final ReconRpc _rpc = widget.rpc ?? _liveRpc;

  Map<String, dynamic> _home = const {};
  Map<String, dynamic> _detail = const {};
  bool _loading = true;
  bool _running = false;
  String _error = '';
  int? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({int? runId}) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final home = await _rpc('recon_home', {'p_limit': 20});
      final detail = await _rpc(
          'recon_run_detail', {'p_run_id': runId});
      if (!mounted) return;
      setState(() {
        _home = home;
        _detail = detail;
        _selected = runId ?? _int(detail['run'], 'run_id');
        _loading = false;
      });
      RenderLog.write('c471_recon_screen', 'runs=${_runs.length}');
      RenderLog.write('c471_recon_findings', _findingCount().toString());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _runNow() async {
    setState(() => _running = true);
    Map<String, dynamic> res = const {};
    try {
      res = await _rpc('recon_run_now', {'p_days': null});
    } catch (e) {
      res = {'toast': e.toString()};
    }
    if (!mounted) return;
    setState(() => _running = false);
    final toast = _str(res, 'toast');
    if (toast.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(toast, style: Ds.t.body.copyWith(color: Ds.c.surface))));
    }
    await _load(runId: res['run_id'] is int ? res['run_id'] as int : null);
  }

  // ── payload readers (absence is empty, never a Dart word) ────────────────
  static String _str(Object? m, String k) =>
      (m is Map && m[k] != null) ? m[k].toString() : '';
  static int? _int(Object? m, String k) =>
      (m is Map && m[k] is int) ? m[k] as int : null;
  static List<Map<String, dynamic>> _list(Object? m, String k) {
    if (m is! Map || m[k] is! List) return const [];
    return (m[k] as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  List<Map<String, dynamic>> get _runs => _list(_home, 'runs');
  List<Map<String, dynamic>> get _groups => _list(_detail, 'groups');

  int _findingCount() {
    var n = 0;
    for (final g in _groups) {
      n += _list(g, 'findings').length;
    }
    return n;
  }

  Color _tone(String tone) {
    switch (tone) {
      case 'good':
        return Ds.c.success;
      case 'bad':
        return Ds.c.danger;
      case 'warn':
        return Ds.c.warning;
      default:
        return Ds.c.textSecondary;
    }
  }

  Color _toneSoft(String tone) {
    switch (tone) {
      case 'good':
        return Ds.c.successSoft;
      case 'bad':
        return Ds.c.dangerSoft;
      case 'warn':
        return Ds.c.warningSoft;
      default:
        return Ds.c.bg;
    }
  }

  /// The only routes this build has a destination for. Anything else renders
  /// as text: a chip that goes nowhere is worse than no chip.
  bool _canOpen(Map<String, dynamic> f) =>
      _str(f, 'route') == 'order' &&
      _str(f['route_args'], 'order_code').isNotEmpty &&
      _str(f, 'route_label').isNotEmpty;

  void _open(Map<String, dynamic> f) {
    final code = _str(f['route_args'], 'order_code');
    if (code.isEmpty) return;
    Navigator.push(context,
        MaterialPageRoute(builder: (_) => CodeResolverPage(code: code)));
  }

  @override
  Widget build(BuildContext context) {
    final title = _str(_home, 'title');
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        elevation: 0,
        iconTheme: IconThemeData(color: Ds.c.brand),
        title: Text(title, style: Ds.t.subtitle),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: Ds.c.divider),
        ),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return _skeleton();
    if (_error.isNotEmpty) return _errorState();
    if (!(_home['has_latest'] == true) && _runs.isEmpty) return _emptyState();

    return RefreshIndicator(
      onRefresh: () => _load(runId: _selected),
      color: Ds.c.brand,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
        children: [
          Text(_str(_home, 'subtitle'),
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          SizedBox(height: Ds.space.x16),
          if (_detail['run'] is Map)
            _runCard(Map<String, dynamic>.from(_detail['run'] as Map),
                headline: true),
          SizedBox(height: Ds.space.x16),
          _runButton(),
          SizedBox(height: Ds.space.x24),
          if (_groups.isEmpty)
            _note(_str(_detail, 'empty_label'))
          else
            for (final g in _groups) ...[
              _group(g),
              SizedBox(height: Ds.space.x16),
            ],
          if (_runs.length > 1) ...[
            SizedBox(height: Ds.space.x8),
            for (final r in _runs)
              if (_int(r, 'run_id') != _selected)
                Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x8),
                  child: _runCard(r, headline: false),
                ),
          ],
        ],
      ),
    );
  }

  // ── pieces ───────────────────────────────────────────────────────────────

  Widget _card({required Widget child, VoidCallback? onTap}) {
    final box = Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: child,
    );
    if (onTap == null) return box;
    return InkWell(
        borderRadius: Ds.r.rCard, onTap: onTap, child: box);
  }

  Widget _chip(String label, String tone) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration: BoxDecoration(
            color: _toneSoft(tone), borderRadius: Ds.r.rChip),
        child: Text(label,
            style: Ds.t.caption.copyWith(color: _tone(tone))),
      );

  Widget _runCard(Map<String, dynamic> r, {required bool headline}) {
    final id = _int(r, 'run_id');
    return _card(
      onTap: headline || id == null ? null : () => _load(runId: id),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(_str(r, 'ran_label'),
                style: headline ? Ds.t.subtitle : Ds.t.body),
          ),
          SizedBox(width: Ds.space.x8),
          _chip(_str(r, 'status_label'), _str(r, 'status_tone')),
        ]),
        SizedBox(height: Ds.space.x8),
        Text(_str(r, 'summary_label'),
            style: Ds.t.body.copyWith(color: Ds.c.text)),
        SizedBox(height: Ds.space.x8),
        Text(
            [
              _str(r, 'window_label'),
              _str(r, 'checks_label'),
              _str(r, 'findings_label'),
            ].where((s) => s.isNotEmpty).join('  ·  '),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      ]),
    );
  }

  Widget _runButton() => SizedBox(
        width: double.infinity,
        height: Ds.space.x48,
        child: ElevatedButton(
          onPressed: _running ? null : _runNow,
          style: ElevatedButton.styleFrom(
            backgroundColor: Ds.c.brand,
            foregroundColor: Ds.c.surface,
            elevation: 0,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          child: Text(
              _running
                  ? _str(_home, 'running_label')
                  : _str(_home, 'run_button'),
              style: Ds.t.body.copyWith(color: Ds.c.surface)),
        ),
      );

  Widget _group(Map<String, dynamic> g) {
    final findings = _list(g, 'findings');
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(_str(g, 'label'), style: Ds.t.subtitle)),
          SizedBox(width: Ds.space.x8),
          _chip(_str(g, 'count_label'), _str(g, 'tone')),
        ]),
        SizedBox(height: Ds.space.x4),
        Text(_str(g, 'description'),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        SizedBox(height: Ds.space.x4),
        Text(_str(g, 'sources_label'),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        for (final f in findings) ...[
          SizedBox(height: Ds.space.x16),
          Container(height: 1, color: Ds.c.divider),
          SizedBox(height: Ds.space.x12),
          _finding(f),
        ],
      ]),
    );
  }

  Widget _finding(Map<String, dynamic> f) {
    final tappable = _canOpen(f);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(_str(f, 'entity_label'),
          style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
      SizedBox(height: Ds.space.x4),
      Text(_str(f, 'detail_label'),
          style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      if (f['has_amounts'] == true) ...[
        SizedBox(height: Ds.space.x12),
        Row(children: [
          _amount(_str(_detail, 'expected_caption'), _str(f, 'expected_label'),
              Ds.c.text),
          _amount(_str(_detail, 'actual_caption'), _str(f, 'actual_label'),
              Ds.c.text),
          _amount(_str(_detail, 'diff_caption'), _str(f, 'diff_label'),
              Ds.c.danger),
        ]),
      ],
      if (tappable) ...[
        SizedBox(height: Ds.space.x12),
        SizedBox(
          height: Ds.space.x48,
          child: TextButton(
            onPressed: () => _open(f),
            style: TextButton.styleFrom(
              foregroundColor: Ds.c.brand,
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
              shape:
                  RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            ),
            child: Text(_str(f, 'route_label'),
                style: Ds.t.body.copyWith(color: Ds.c.brand)),
          ),
        ),
      ],
    ]);
  }

  Widget _amount(String caption, String value, Color color) => Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(caption,
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          SizedBox(height: Ds.space.x4),
          Text(value,
              style: Ds.t.body
                  .copyWith(fontWeight: FontWeight.w600, color: color)),
        ]),
      );

  Widget _note(String text) => _card(
      child: Text(text,
          style: Ds.t.body.copyWith(color: Ds.c.textSecondary)));

  Widget _emptyState() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child:
              Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_str(_home, 'empty_title'),
                style: Ds.t.subtitle, textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x8),
            Text(_str(_home, 'empty_hint'),
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x24),
            _runButton(),
          ]),
        ),
      );

  Widget _errorState() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error,
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.space.x48,
              child: OutlinedButton(
                onPressed: () => _load(runId: _selected),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  side: BorderSide(color: Ds.c.brand),
                  shape: RoundedRectangleBorder(
                      borderRadius: Ds.r.rButton),
                ),
                child: Text(_str(_home, 'run_button'),
                    style: Ds.t.body.copyWith(color: Ds.c.brand)),
              ),
            ),
          ]),
        ),
      );

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Container(
                height: Ds.space.x48 * 2,
                decoration: BoxDecoration(
                    color: Ds.c.surface, borderRadius: Ds.r.rCard),
              ),
            ),
        ],
      );
}
