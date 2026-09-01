import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #460 / feature_gaps 161 — "55% of the catalogue has no image and the
/// rest hotlinks 1mg's CDN."
///
/// Measured on 562,549 rows: 309,789 with no image at all, 252,760 pointing at
/// onemg.gumlet.io, zero served from our own storage. And the consequence that
/// had never been measured: refresh_storefront_feed() requires a non-empty
/// image, so 43,492 of 75,597 buyable products were not in the storefront feed
/// at all.
///
/// This screen is a printout. `catalogue_health()` returns sections, rows,
/// labels, formatted numbers (Indian grouping, server-side), percentages and a
/// tone per row; the two buttons are the payload's `actions`, and both toasts
/// are the RPCs' own messages. Nothing here divides, formats or decides a
/// colour from a number.
class CatalogueHealthScreen extends StatefulWidget {
  const CatalogueHealthScreen({super.key});

  @override
  State<CatalogueHealthScreen> createState() => _CatalogueHealthScreenState();
}

class _CatalogueHealthScreenState extends State<CatalogueHealthScreen> {
  final _sb = Supabase.instance.client;
  Map<String, dynamic>? _p;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _s(Map m, String k) => (m[k] ?? '').toString();

  List<Map<String, dynamic>> get _sections =>
      ((_p ?? const {})['sections'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _sb.rpc('catalogue_health');
      _p = (res is Map) ? Map<String, dynamic>.from(res) : <String, dynamic>{};
    } catch (_) {
      _p = <String, dynamic>{'ok': false};
    }
    if (!mounted) return;
    setState(() => _loading = false);
    RenderLog.write('catalogue_health', {
      'sections': _sections.length,
      'rows': _sections
          .expand((s) => (s['rows'] as List? ?? const []))
          .length,
      'has_data': (_p ?? const {})['has_data'] == true,
    });
  }

  Future<void> _act(String key) async {
    if (_busy) return;
    setState(() => _busy = true);
    String toast = '';
    bool ok = true;
    try {
      if (key == 'refresh') {
        await _sb.rpc('catalogue_health_refresh');
      } else {
        final res = await _sb.rpc('catalogue_image_queue_build');
        final m = (res is Map) ? Map<String, dynamic>.from(res) : const {};
        ok = m['ok'] == true;
        toast = _s(m, 'message');
      }
    } catch (_) {
      ok = false;
    }
    await _load();
    if (!mounted) return;
    setState(() => _busy = false);
    if (toast.isNotEmpty) showToast(context, toast, isError: !ok);
  }

  Color _tone(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p ?? const {};
    final actions = (p['actions'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(p, 'title'))),
      body: _loading
          ? const _CardsSkeleton()
          : (p['ok'] != true)
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(Ds.space.x24),
                    child: Text(_s(p, 'message'),
                        textAlign: TextAlign.center, style: Ds.t.bodySecondary),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16,
                        Ds.space.x16, Ds.space.x32),
                    children: [
                      Text(_s(p, 'subtitle'), style: Ds.t.bodySecondary),
                      SizedBox(height: Ds.space.x4),
                      Text(_s(p, 'updated_label'), style: Ds.t.caption),
                      SizedBox(height: Ds.space.x24),
                      for (final sec in _sections) ...[
                        _sectionCard(sec),
                        SizedBox(height: Ds.space.x16),
                      ],
                      SizedBox(height: Ds.space.x8),
                      for (final a in actions) ...[
                        SizedBox(
                          height: Ds.touch.minTarget,
                          child: a['key'] == 'queue'
                              ? FilledButton(
                                  onPressed:
                                      _busy ? null : () => _act(_s(a, 'key')),
                                  child: Text(_s(a, 'label')),
                                )
                              : OutlinedButton(
                                  onPressed:
                                      _busy ? null : () => _act(_s(a, 'key')),
                                  child: Text(_s(a, 'label')),
                                ),
                        ),
                        SizedBox(height: Ds.space.x12),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _sectionCard(Map<String, dynamic> sec) {
    final rows = (sec['rows'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.card),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(sec, 'title'), style: Ds.t.subtitle),
          if (_s(sec, 'note').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(sec, 'note'), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x12),
          for (int i = 0; i < rows.length; i++) ...[
            _metricRow(rows[i]),
            if (i != rows.length - 1)
              Divider(height: Ds.space.x24, color: Ds.c.divider),
          ],
        ],
      ),
    );
  }

  Widget _metricRow(Map<String, dynamic> r) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(_s(r, 'label'), style: Ds.t.body)),
        SizedBox(width: Ds.space.x12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(_s(r, 'value'),
                style: Ds.t.bodyStrong.copyWith(color: _tone(_s(r, 'tone')))),
            if (_s(r, 'sub').isNotEmpty)
              Text(_s(r, 'sub'), style: Ds.t.caption),
          ],
        ),
      ],
    );
  }
}

class _CardsSkeleton extends StatelessWidget {
  const _CardsSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (int i = 0; i < 3; i++) ...[
          Container(
            height: Ds.space.x48 * 3,
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: BorderRadius.circular(Ds.r.card),
            ),
          ),
          SizedBox(height: Ds.space.x16),
        ],
      ],
    );
  }
}
