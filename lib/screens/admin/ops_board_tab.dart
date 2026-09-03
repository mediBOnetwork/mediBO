// lib/screens/admin/ops_board_tab.dart — CHANGE #688
//
// The Ops board tab in the Fulfilment console, for admins AND for a partner
// (the partner fence lets a partner user through ops_board / ops_order_detail /
// ops_sla_config_get and nothing else, and the RPC clamps them to their own
// zone).
//
// This half owns only the plumbing: the RPC calls, the zone scope, the live
// refresh and the two sheets. Every pixel is drawn by OpsBoardView, which has
// no Supabase in it so the protected test can render the same widget from a
// hand-written payload.
//
// LIVE: the poll interval is the BACKEND's (`refresh_ms`, 30 s today, an
// ui_copy row away from being anything else) and a fulfilment realtime event
// refreshes immediately — the same pattern the rest of this console uses.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../fulfill/fulfill_lookups.dart';
import '../../services/admin_zone_scope.dart';
import '../../services/fulfill_realtime.dart';
import '../../utils/render_log.dart';
import 'ops_board_view.dart';

class OpsBoardTab extends StatefulWidget {
  const OpsBoardTab({super.key});

  @override
  State<OpsBoardTab> createState() => OpsBoardTabState();
}

class OpsBoardTabState extends State<OpsBoardTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  Map<String, dynamic> _payload = const {};
  bool _loading = true;
  String _error = '';
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    FulfillLookups.instance.ensureLoaded();
    AdminZoneScope.instance.addListener(_onZoneChanged);
    AdminZoneScope.instance.ensureLoaded();
    FulfillRealtime.instance.addListener(_onRealtime);
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    AdminZoneScope.instance.removeListener(_onZoneChanged);
    FulfillRealtime.instance.removeListener(_onRealtime);
    super.dispose();
  }

  /// Refetch, for the host tab bar when this tab is opened.
  Future<void> reload() => _load();

  void _onZoneChanged() => _load();

  void _onRealtime(Set<String> changed) {
    // Any fulfilment write can move an order to a different stage, which is a
    // different clock — so the board refetches rather than guessing.
    if (mounted) _load();
  }

  void _rearm(int ms) {
    _poll?.cancel();
    _poll = Timer(Duration(milliseconds: ms), () {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    if (mounted && _payload.isEmpty) setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('ops_board', params: {
        'p_zone': AdminZoneScope.instance.selectedZoneId,
      });
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() {
        _payload = m;
        _loading = false;
        _error = '';
      });
      final counts = m['counts'] is Map ? Map<String, dynamic>.from(m['counts'] as Map) : const {};
      RenderLog.write(
          'c688_ops_board',
          'ok=${m['ok']};rows=${opsRows(m['rows']).length};'
          'red=${counts['red'] ?? 0};amber=${counts['amber'] ?? 0};green=${counts['green'] ?? 0};'
          'zone=${m['zone_id'] ?? ''};can_edit=${m['can_edit_sla'] == true}');
      _rearm((m['refresh_ms'] as num?)?.toInt() ?? 30000);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
      RenderLog.write('c688_ops_board_err', e.toString());
      _rearm(30000);
    }
  }

  // ── the row tap: one order's stage timeline ────────────────────────────────

  Future<void> _openOrder(Map<String, dynamic> row) async {
    final id = row['order_id']?.toString() ?? '';
    if (id.isEmpty) return;
    Map<String, dynamic> detail = const {};
    try {
      final res = await Supabase.instance.client
          .rpc('ops_order_detail', params: {'p_order_id': id});
      detail = res is Map ? Map<String, dynamic>.from(res) : const {};
    } catch (e) {
      RenderLog.write('c688_ops_detail_err', e.toString());
      return;
    }
    if (!mounted) return;
    RenderLog.write('c688_ops_detail', 'ok=${detail['ok']};order=$id');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: OpsOrderDetailView(payload: detail),
        ),
      ),
    );
  }

  // ── the SLA editor: super admin only, and it needs no deploy ───────────────

  Future<void> _openSlaEditor() async {
    Map<String, dynamic> cfg = const {};
    try {
      final res = await Supabase.instance.client.rpc('ops_sla_config_get',
          params: {'p_zone': AdminZoneScope.instance.selectedZoneId});
      cfg = res is Map ? Map<String, dynamic>.from(res) : const {};
    } catch (e) {
      RenderLog.write('c688_ops_sla_err', e.toString());
      return;
    }
    if (!mounted) return;
    RenderLog.write('c688_ops_sla',
        'ok=${cfg['ok']};rows=${opsRows(cfg['rows']).length};can_edit=${cfg['can_edit'] == true}');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _SlaSheet(
          config: cfg, zoneId: AdminZoneScope.instance.selectedZoneId),
    );
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_loading && _payload.isEmpty) return const _BoardSkeleton();

    if (_error.isNotEmpty && _payload.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(FulfillLookups.instance.ui('ops_board_error'),
              textAlign: TextAlign.center, style: Ds.t.body),
          SizedBox(height: Ds.space.x12),
          OutlinedButton(
            onPressed: _load,
            child: Text(FulfillLookups.instance.ui('ops_board_retry')),
          ),
        ]),
      );
    }

    return Container(
      color: Ds.c.bg,
      child: OpsBoardView(
        payload: _payload,
        onTapRow: _openOrder,
        onEditSla: _openSlaEditor,
      ),
    );
  }
}

/// A skeleton, not a bare spinner: the board's own shape while it loads.
class _BoardSkeleton extends StatelessWidget {
  const _BoardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Ds.c.bg,
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < 5; i++) ...[
          Container(
            height: Ds.touch.listRowMinHeight,
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
            ),
          ),
          SizedBox(height: Ds.space.x12),
        ],
      ]),
    );
  }
}

/// The SLA panel. Minutes per stage, saved straight back to sla_config — the
/// board picks the new number up on its next refresh, with no deploy.
class _SlaSheet extends StatefulWidget {
  final Map<String, dynamic> config;
  final int? zoneId;

  const _SlaSheet({required this.config, this.zoneId});

  @override
  State<_SlaSheet> createState() => _SlaSheetState();
}

class _SlaSheetState extends State<_SlaSheet> {
  final Map<String, TextEditingController> _ctrl = {};
  bool _saving = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    for (final r in opsRows(widget.config['rows'])) {
      _ctrl[r['stage_key']?.toString() ?? ''] = TextEditingController(
          text: (r['sla_minutes'] as num?)?.toInt().toString() ?? '');
    }
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final rows = <Map<String, dynamic>>[];
    for (final r in opsRows(widget.config['rows'])) {
      final k = r['stage_key']?.toString() ?? '';
      final v = int.tryParse(_ctrl[k]?.text.trim() ?? '');
      if (k.isEmpty || v == null) continue;
      rows.add({'stage_key': k, 'sla_minutes': v, 'amber_pct': r['amber_pct']});
    }
    try {
      final res = await Supabase.instance.client.rpc('ops_sla_config_set',
          params: {
            'p': {'zone_id': widget.zoneId, 'rows': rows}
          });
      final m = res is Map ? Map<String, dynamic>.from(res) : const {};
      RenderLog.write(
          'c688_ops_sla_save', 'ok=${m['ok']};saved=${m['saved'] ?? 0}');
      if (!mounted) return;
      if (m['ok'] == true) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        _saving = false;
        _message = m['message']?.toString() ?? '';
      });
    } catch (e) {
      RenderLog.write('c688_ops_sla_save_err', e.toString());
      if (!mounted) return;
      setState(() => _saving = false);
    }
  }

  String _s(Map<String, dynamic> m, String k) => m[k]?.toString() ?? '';

  @override
  Widget build(BuildContext context) {
    final cfg = widget.config;
    final rows = opsRows(cfg['rows']);
    final canEdit = cfg['can_edit'] == true;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_s(cfg, 'title'), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x4),
              Text(
                  [_s(cfg, 'subtitle'), _s(cfg, 'zone_label')]
                      .where((e) => e.isNotEmpty)
                      .join(' · '),
                  style: Ds.t.caption),
            ]),
          ),
          SizedBox(height: Ds.space.x16),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: rows.length,
              separatorBuilder: (_, _) => SizedBox(height: Ds.space.x12),
              itemBuilder: (_, i) {
                final r = rows[i];
                final k = r['stage_key']?.toString() ?? '';
                return Row(children: [
                  Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_s(r, 'label'), style: Ds.t.body),
                          Text(
                              [_s(r, 'owner_label'), _s(r, 'source_label')]
                                  .where((e) => e.isNotEmpty)
                                  .join(' · '),
                              style: Ds.t.caption),
                        ]),
                  ),
                  SizedBox(width: Ds.space.x12),
                  SizedBox(
                    width: Ds.touch.minTarget * 2,
                    child: TextField(
                      controller: _ctrl[k],
                      enabled: canEdit && !_saving,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.right,
                      style: Ds.t.body,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: _s(cfg, 'minutes_label'),
                        contentPadding: EdgeInsets.symmetric(
                            horizontal: Ds.space.x8, vertical: Ds.space.x8),
                      ),
                    ),
                  ),
                ]);
              },
            ),
          ),
          if (_message.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_message, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: (!canEdit || _saving) ? null : _save,
              child: Text(canEdit
                  ? _s(cfg, 'save_label')
                  : _s(cfg, 'readonly_message')),
            ),
          ),
        ]),
      ),
    );
  }
}
