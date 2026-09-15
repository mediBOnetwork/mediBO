import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #173 — the admin side of the reorder suite.
///
/// One RPC in, one screen out. `reorder_admin_overview()` returns the title,
/// the three stat tiles, both section headings, every row's wording (cadence,
/// next run, item count, status label + tone) and the actions each row is
/// allowed to offer. This file decides none of that — it lays the payload out.
///
/// `reorder_admin_sub_update(id, action)` returns the SAME payload shape after
/// the change, so a pause/resume/cancel re-renders from the server's new truth
/// rather than from a locally patched row.
class ReorderAdminScreen extends StatefulWidget {
  const ReorderAdminScreen({super.key});

  @override
  State<ReorderAdminScreen> createState() => _ReorderAdminScreenState();
}

class _ReorderAdminScreenState extends State<ReorderAdminScreen> {
  final _sb = Supabase.instance.client;
  bool _loading = true;
  bool _busy = false;
  Map<String, dynamic> _p = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _sb.rpc('reorder_admin_overview');
      _p = (res is Map) ? Map<String, dynamic>.from(res) : const {};
    } catch (_) {
      _p = const {'ok': false};
    }
    if (!mounted) return;
    setState(() => _loading = false);
    RenderLog.write('reorder_admin', {
      'subs': (_p['subs'] as List?)?.length ?? 0,
      'pending': (_p['pending'] as List?)?.length ?? 0,
    });
  }

  String _s(Map m, String k) => (m[k] ?? '').toString();

  Color _toneFg(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      default:
        return Ds.c.textSecondary;
    }
  }

  Color _toneBg(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      default:
        return Ds.c.bg;
    }
  }

  Future<void> _act(String id, String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await _sb
          .rpc('reorder_admin_sub_update', params: {'p_id': id, 'p_action': action});
      if (res is Map && res['ok'] == true) {
        _p = Map<String, dynamic>.from(res);
      } else if (res is Map && mounted) {
        showToast(context, _s(res, 'message'), isError: true);
      }
    } catch (_) {
      // The next load reports the real state; never invent an error string.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _s(_p, 'title');
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(title.isEmpty ? 'Reorder' : title, style: Ds.t.subtitle),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? _skeleton()
          : (_p['ok'] != true)
              ? _denied()
              : RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _denied() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(_s(_p, 'message'),
              style: Ds.t.body, textAlign: TextAlign.center),
        ),
      );

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: List.generate(
          4,
          (_) => Container(
            height: 72,
            margin: EdgeInsets.only(bottom: Ds.space.x12),
            decoration:
                BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
          ),
        ),
      );

  Widget _body() {
    final subs = (_p['subs'] as List?) ?? const [];
    final pending = (_p['pending'] as List?) ?? const [];
    final stats = (_p['stats'] as List?) ?? const [];
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (stats.isNotEmpty) _statRow(stats),
        SizedBox(height: Ds.space.x24),
        Text(_s(_p, 'subs_title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x12),
        if (subs.isEmpty)
          _note(_s(_p, 'subs_empty'))
        else
          ...subs.map((e) => _subCard(e as Map)),
        SizedBox(height: Ds.space.x24),
        Text(_s(_p, 'pending_title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x12),
        if (pending.isEmpty)
          _note(_s(_p, 'pending_empty'))
        else
          ...pending.map((e) => _pendingCard(e as Map)),
      ],
    );
  }

  Widget _statRow(List stats) => Row(
        children: [
          for (final s in stats) ...[
            Expanded(child: _statTile(s as Map)),
            if (s != stats.last) SizedBox(width: Ds.space.x12),
          ],
        ],
      );

  Widget _statTile(Map s) => Container(
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(s, 'value'),
                style: Ds.t.title.copyWith(color: Ds.c.brandDark)),
            SizedBox(height: Ds.space.x4),
            Text(_s(s, 'label'), style: Ds.t.caption),
          ],
        ),
      );

  Widget _note(String text) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x8),
        child: Text(text, style: Ds.t.caption),
      );

  Widget _subCard(Map s) {
    final actions = (s['actions'] as List?) ?? const [];
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(_s(s, 'customer'),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
            SizedBox(width: Ds.space.x8),
            _pill(_s(s, 'status_label'), _s(s, 'status_tone')),
          ]),
          SizedBox(height: Ds.space.x8),
          Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x4, children: [
            Text(_s(s, 'cadence_label'), style: Ds.t.caption),
            Text(_s(s, 'items_label'), style: Ds.t.caption),
            Text(_s(s, 'next_label'), style: Ds.t.caption),
          ]),
          if (actions.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                for (final a in actions)
                  Padding(
                    padding: EdgeInsets.only(right: Ds.space.x8),
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _act(_s(s, 'id'), _s(a as Map, 'key')),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Ds.c.brand,
                          side: BorderSide(color: Ds.c.brand),
                          shape: RoundedRectangleBorder(
                              borderRadius: Ds.r.rButton),
                        ),
                        child: Text(_s(a as Map, 'label'),
                            style: Ds.t.body.copyWith(color: Ds.c.brand)),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _pendingCard(Map p) => Container(
        margin: EdgeInsets.only(bottom: Ds.space.x12),
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(p, 'customer'),
                      style: Ds.t.body.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  SizedBox(height: Ds.space.x4),
                  Wrap(spacing: Ds.space.x8, children: [
                    Text(_s(p, 'kind_label'), style: Ds.t.caption),
                    Text(_s(p, 'items_label'), style: Ds.t.caption),
                    Text(_s(p, 'age_label'), style: Ds.t.caption),
                  ]),
                ],
              ),
            ),
            SizedBox(width: Ds.space.x8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_s(p, 'amount_display'),
                    style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
                SizedBox(height: Ds.space.x4),
                _pill(_s(p, 'status_label'), _s(p, 'status_tone')),
              ],
            ),
          ],
        ),
      );

  Widget _pill(String text, String tone) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(
            color: _toneBg(tone), borderRadius: Ds.r.rChip),
        child: Text(text,
            style: Ds.t.caption.copyWith(color: _toneFg(tone))),
      );
}
