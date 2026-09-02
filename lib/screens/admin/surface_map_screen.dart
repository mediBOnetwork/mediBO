// lib/screens/admin/surface_map_screen.dart — CHANGE #570
//
// The surface map: every feature mediBO has, the audience it was registered
// for, and the audience that can actually reach it — plus every place those
// two disagree.
//
// WHY IT EXISTS. Om's report was "features built for user type X appear on
// other user types' surfaces, and features built for X are missing from X".
// Three leaks and two gaps were found and fixed in the same change, but a
// one-off sweep only fixes the rows that were wrong that morning. This screen
// is the standing answer: surface_map_audit() re-derives the whole mapping on
// every open, and rg behaviour test c570_surface_map fails the deploy if the
// drift count is anything other than zero.
//
// THIS FILE DECIDES NOTHING. Every heading, every audience string, every
// problem sentence and the empty state are the payload's. Dart contributes
// layout and the tone -> Ds token lookup, and a tone this build has never
// heard of falls back to neutral rather than throwing.
//
// Reachability: feature_registry row admin.surface_map (surface dashboard,
// category system, roles_allowed {super_admin}) -> route_key 'surface_map' ->
// the case in home_shell's _handleAdminNav. Admin & System on the dashboard.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

/// A single RPC call. Injectable so the protected test can drive the screen
/// with real-shaped payloads and no Supabase — the same seam the delivery
/// waves and supplier records screens use.
typedef SurfaceMapRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

class SurfaceMapScreen extends StatefulWidget {
  final SurfaceMapRpc? rpc;

  const SurfaceMapScreen({super.key, this.rpc});

  @override
  State<SurfaceMapScreen> createState() => _SurfaceMapScreenState();
}

class _SurfaceMapScreenState extends State<SurfaceMapScreen> {
  Map<String, dynamic> _data = const {};
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) async {
    if (widget.rpc != null) return widget.rpc!(fn, p);
    final res = await Supabase.instance.client.rpc(fn, params: p);
    return res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final res = await _call('surface_map_audit', const {});
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
      });
      // The two numbers worth having in the render log: that the screen
      // painted at all, and how much drift the backend reported when it did.
      RenderLog.write('c570_surface_map_rows', _sections.fold<int>(
          0, (n, s) => n + _list(s['rows']).length));
      RenderLog.write('c570_surface_map_drift', _drift.length);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  // ── payload readers. Nothing here invents a value that did not arrive. ──
  List<Map<String, dynamic>> _list(dynamic raw) {
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  List<Map<String, dynamic>> get _sections => _list(_data['sections']);
  List<Map<String, dynamic>> get _drift => _list(_data['drift']);
  List<Map<String, dynamic>> get _summary => _list(_data['summary']);

  /// The row captions, from the payload's own `labels` block.
  String _label(String k) {
    final raw = _data['labels'];
    if (raw is! Map) return '';
    return (raw[k] ?? '').toString();
  }

  /// The backend names a tone; this picks the token for it. An unknown tone is
  /// neutral — a payload written after this build shipped must never throw.
  Color _toneFg(String tone) => switch (tone) {
        'success' => Ds.c.success,
        'warning' => Ds.c.warning,
        'danger' => Ds.c.danger,
        'brand' => Ds.c.brand,
        'info' => Ds.c.info,
        _ => Ds.c.textSecondary,
      };

  Color _toneBg(String tone) => switch (tone) {
        'success' => Ds.c.successSoft,
        'warning' => Ds.c.warningSoft,
        'danger' => Ds.c.dangerSoft,
        'brand' => Ds.c.brandSoft,
        'info' => Ds.c.infoSoft,
        _ => Ds.c.bg,
      };

  @override
  Widget build(BuildContext context) {
    // ok:false is the backend refusing this reader. It wrote the sentence; the
    // screen prints it rather than guessing at a reason of its own.
    if (!_loading && _data['ok'] == false) {
      return Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(
          title: Text(_s(_data, 'title'), style: Ds.t.title),
          backgroundColor: Ds.c.surface,
          elevation: 0,
        ),
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x24),
            child: Text(_s(_data, 'message'),
                textAlign: TextAlign.center, style: Ds.t.body),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(_data, 'title'), style: Ds.t.title),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? _skeleton()
            : _failed
                ? _error()
                : ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      Text(_s(_data, 'subtitle'), style: Ds.t.caption),
                      SizedBox(height: Ds.space.x24),
                      _summaryCard(),
                      SizedBox(height: Ds.space.x24),
                      _driftCard(),
                      SizedBox(height: Ds.space.x32),
                      for (final s in _sections) ...[
                        _sectionCard(s),
                        SizedBox(height: Ds.space.x24),
                      ],
                      SizedBox(height: Ds.space.x32),
                    ],
                  ),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        padding: EdgeInsets.all(Ds.space.x16),
        child: child,
      );

  // ── the counters strip. Labels and values are both backend strings; the
  //    drift counter carries its own tone so a clean run is green here and a
  //    dirty one is red without this file knowing what "clean" means.
  Widget _summaryCard() => _card(
        child: Wrap(
          spacing: Ds.space.x24,
          runSpacing: Ds.space.x16,
          children: [
            for (final s in _summary)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_s(s, 'value_label'),
                      style: Ds.t.subtitle.copyWith(
                          color: _toneFg(_s(s, 'tone')))),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(s, 'label'), style: Ds.t.caption),
                ],
              ),
          ],
        ),
      );

  // ── the problems. An empty list is the whole point of the screen, so it gets
  //    the backend's own success sentence rather than a bare "nothing here".
  Widget _driftCard() {
    if (_drift.isEmpty) {
      return _card(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.check_circle_outline,
                size: Ds.space.x24, color: Ds.c.success),
            SizedBox(width: Ds.space.x12),
            Expanded(
                child: Text(_s(_data, 'clean_label'), style: Ds.t.body)),
          ],
        ),
      );
    }
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(_data, 'drift_heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          for (final d in _drift) ...[
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: _toneBg(_s(d, 'tone')),
                borderRadius: Ds.r.rChip,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(d, 'label'),
                      style: Ds.t.bodyStrong
                          .copyWith(color: _toneFg(_s(d, 'tone')))),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(d, 'detail'), style: Ds.t.caption),
                ],
              ),
            ),
            SizedBox(height: Ds.space.x12),
          ],
        ],
      ),
    );
  }

  // ── one registry per section, one feature per row, in payload order. No
  //    client-side sort: the backend already ordered by surface and category,
  //    and re-sorting here would hide a registry that ordered itself wrongly.
  Widget _sectionCard(Map<String, dynamic> s) {
    final rows = _list(s['rows']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_s(s, 'heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty)
          _card(child: Text(_s(s, 'empty_hint'), style: Ds.t.caption))
        else
          _card(
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0)
                    Divider(height: Ds.space.x24, color: Ds.c.divider),
                  _featureRow(rows[i]),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _featureRow(Map<String, dynamic> r) {
    final tone = _s(r, 'tone');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: Ds.space.x8,
          height: Ds.space.x8,
          margin: EdgeInsets.only(top: Ds.space.x8, right: Ds.space.x12),
          decoration: BoxDecoration(
              color: _toneFg(tone), shape: BoxShape.circle),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(r, 'label'), style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x4),
              Text(_s(r, 'feature_key'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
              // The four row captions are the payload's `labels` block, not
              // Dart literals — renaming "Built for" is an UPDATE, not a
              // deploy. A payload that omits one prints nothing for it.
              _kv(_label('intended'), _s(r, 'intended_label')),
              _kv(_label('actual'), _s(r, 'actual_label')),
              _kv(_label('surface'), _s(r, 'surface_label')),
              _kv(_label('route'), _s(r, 'route_label')),
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: Ds.space.x48 + Ds.space.x24,
                child: Text(k, style: Ds.t.caption)),
            Expanded(child: Text(v, style: Ds.t.caption)),
          ],
        ),
      );

  // A skeleton, not a bare spinner (design QA check 6).
  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 4; i++) ...[
            Container(
              height: Ds.space.x48 + Ds.space.x24,
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
              ),
            ),
            SizedBox(height: Ds.space.x16),
          ],
        ],
      );

  Widget _error() => ListView(
        padding: EdgeInsets.all(Ds.space.x24),
        children: [
          // A load that never returned has no payload to print, so the copy
          // comes from the backend's own ui_copy cache instead.
          Text(c('surface_map.load_failed'), style: Ds.t.body),
          SizedBox(height: Ds.space.x24),
          OutlinedButton(onPressed: _load, child: Text(c('surface_map.retry'))),
        ],
      );
}
