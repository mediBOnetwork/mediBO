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
import '../../models/order_timeline_view.dart';
import '../orders/order_hold_sheet.dart';
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
    // CHANGE #689 (feature_gaps #75) — the second half of the answer. The
    // stage grid says which SLA is breaching; order_timeline() says what
    // happened, who did it and what one tap would do about it. It is fetched
    // beside the detail (not inside it) so an ops_order_detail that the ops
    // board already trusts is never held hostage by a timeline that fails.
    Map<String, dynamic> timeline = const {};
    try {
      final res = await Supabase.instance.client
          .rpc('order_timeline', params: {'p_order_id': id});
      timeline = res is Map ? Map<String, dynamic>.from(res) : const {};
    } catch (e) {
      RenderLog.write('c689_timeline_err', e.toString());
    }
    if (!mounted) return;
    RenderLog.write('c688_ops_detail', 'ok=${detail['ok']};order=$id');
    RenderLog.write('c689_timeline',
        'access=${timeline['access'] ?? ''};events=${timeline['event_count'] ?? 0};can_act=${timeline['can_act'] == true}');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: _TimelineHost(detail: detail, timeline: timeline, orderId: id),
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
    RenderLog.write(
        'cmd1845_stage_deadlines',
        'ok=${cfg['ok']};rows=${opsRows(cfg['rows']).length};'
        'modes=${opsRows(cfg['modes']).length};can_edit=${cfg['can_edit'] == true}');
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => StageDeadlineSheetView(
        config: cfg,
        zoneId: AdminZoneScope.instance.selectedZoneId,
        formatTime: _timeLabel,
        onSave: _saveDeadlines,
      ),
    );
    if (saved == true) await _load();
  }

  /// CMD #1845 — a time the super admin just picked is worded by the BACKEND.
  /// A 12-hour string built in Dart is exactly what this change removed, so the
  /// picker's own hour/minute go to ops_time_label and the reply is printed.
  Future<String> _timeLabel(int hour, int minute) async {
    try {
      final res = await Supabase.instance.client
          .rpc('ops_time_label', params: {'p_hour': hour, 'p_minute': minute});
      final m = res is Map ? Map<String, dynamic>.from(res) : const {};
      return m['label']?.toString() ?? '';
    } catch (e) {
      RenderLog.write('cmd1845_time_label_err', e.toString());
      return '';
    }
  }

  Future<Map<String, dynamic>> _saveDeadlines(
      Map<String, dynamic> payload) async {
    try {
      final res = await Supabase.instance.client
          .rpc('ops_sla_config_set', params: {'p': payload});
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      RenderLog.write('cmd1845_stage_deadlines_save',
          'ok=${m['ok']};saved=${m['saved'] ?? 0};skipped=${m['skipped'] ?? 0}');
      return m;
    } catch (e) {
      RenderLog.write('cmd1845_stage_deadlines_save_err', e.toString());
      return <String, dynamic>{'ok': false, 'message': ''};
    }
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

/// Holds the timeline payload for the open sheet so an action's own reply — the
/// backend hands the whole fresh timeline back — repaints it without a second
/// round trip, and without the board behind it reloading.
class _TimelineHost extends StatefulWidget {
  final Map<String, dynamic> detail;
  final Map<String, dynamic> timeline;
  final String orderId;

  const _TimelineHost({
    required this.detail,
    required this.timeline,
    required this.orderId,
  });

  @override
  State<_TimelineHost> createState() => _TimelineHostState();
}

class _TimelineHostState extends State<_TimelineHost> {
  late Map<String, dynamic> _timeline = widget.timeline;
  late Map<String, dynamic> _detail = widget.detail;

  /// CHANGE #708 — the hold door on the ops card. The sheet is the SAME one
  /// the pharmacy uses; who may write is decided inside order_hold() by role,
  /// zone and the stage gate, so there is no admin-only copy of it here.
  Future<void> _openHold() async {
    final changed = await showOrderHoldSheet(context, widget.orderId);
    if (changed) await _refreshDetail();
  }

  Future<void> _releaseStock(String reason) async {
    try {
      final res = await Supabase.instance.client.rpc('order_hold_stock_release',
          params: {'p_order_id': widget.orderId, 'p_reason': reason});
      final m = res is Map ? Map<String, dynamic>.from(res) : const {};
      RenderLog.write('c708_stock_release', 'ok=${m['ok']}');
      final msg = (m['message'] ?? '').toString();
      if (msg.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor:
              m['ok'] == true ? Ds.c.brand : Ds.c.danger,
        ));
      }
    } catch (e) {
      RenderLog.write('c708_stock_release_err', e.toString());
    }
    await _refreshDetail();
  }

  Future<void> _refreshDetail() async {
    try {
      final res = await Supabase.instance.client
          .rpc('ops_order_detail', params: {'p_order_id': widget.orderId});
      if (!mounted) return;
      setState(() =>
          _detail = res is Map ? Map<String, dynamic>.from(res) : _detail);
    } catch (e) {
      RenderLog.write('c688_ops_detail_err', e.toString());
    }
  }

  Future<TimelineActionResult> _act(
      TimelineAction action, Map<String, dynamic> extra) async {
    // The event named the rpc and carried the args. Dart adds only what the
    // backend ASKED for by name (a picked rider), and chooses nothing.
    final args = Map<String, dynamic>.from(action.args);
    if (extra.isNotEmpty) {
      final inner = args['p_args'] is Map
          ? Map<String, dynamic>.from(args['p_args'] as Map)
          : <String, dynamic>{};
      inner.addAll(extra);
      args['p_args'] = inner;
    }
    try {
      final res =
          await Supabase.instance.client.rpc(action.rpc, params: args);
      RenderLog.write('c689_timeline_act',
          'kind=${action.kind};ok=${res is Map ? res['ok'] : null}');
      return TimelineActionResult.from(res);
    } catch (e) {
      RenderLog.write('c689_timeline_act_err', e.toString());
      return TimelineActionResult.from(
          {'ok': false, 'message': e.toString(), 'choices': const []});
    }
  }

  @override
  Widget build(BuildContext context) => OpsOrderDetailView(
        payload: _detail,
        timeline: _timeline,
        onTimelineAct: _act,
        onTimelineRefreshed: (t) => setState(() => _timeline = t),
        onHold: _openHold,
        onReleaseStock:
            (((_detail['hold_stock'] as Map?)?['can_release'] == true))
                ? _releaseStock
                : null,
      );
}
