// lib/screens/admin/order_timeline_screen.dart — CHANGE #689 (feature_gaps #75)
//
// feature_gaps #75 opens with a literal question: "An admin answering 'where is
// CPO260726NIT123O1' today has to read orders, order_items, inquiry,
// supplier_orders, bag_allocations, receiving_log and wa_send_attempts
// separately." So this screen asks it as a question. Type the code, get the
// order's whole life in one list, with the person responsible on every line and
// a one-tap action on the step it is stuck at.
//
// Two RPCs and no logic. order_timeline_search() gates the caller, clamps a
// partner to their zone and returns the matching orders already worded and
// ordered; order_timeline() returns the events. The title, the hint, the button
// caption, the empty sentence and the "most recent orders" heading are all
// payload strings — this screen writes none of them, so changing the wording is
// an UPDATE on ui_copy, not a deploy.
//
// The same list is drawn by OrderEventTimeline here, in the ops board's row-tap
// sheet, and in the customer's Track sheet. One payload, one widget, three
// doors.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../models/order_timeline_view.dart';
import '../../utils/render_log.dart';
import '../../widgets/order_event_timeline.dart';

class OrderTimelineScreen extends StatefulWidget {
  /// A code or id the caller already had (a deep link's seed). Empty opens the
  /// search on the most recent orders, which is what the backend returns for
  /// an empty query.
  final String seed;

  const OrderTimelineScreen({super.key, this.seed = ''});

  @override
  State<OrderTimelineScreen> createState() => _OrderTimelineScreenState();
}

class _OrderTimelineScreenState extends State<OrderTimelineScreen> {
  late final TextEditingController _q = TextEditingController(text: widget.seed);
  Map<String, dynamic> _search = const {};
  Map<String, dynamic> _timeline = const {};
  String _openId = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _find();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client
          .rpc('order_timeline_search', params: {'p_query': _q.text.trim()});
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() {
        _search = m;
        _loading = false;
      });
      RenderLog.write('c689_search',
          'ok=${m['ok']};rows=${m['row_count'] ?? 0}');
      // One hit is not a list, it is an answer — open it.
      final rows = _rows;
      if (rows.length == 1) await _open(rows.first['order_id']?.toString() ?? '');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c689_search_err', e.toString());
    }
  }

  List<Map<String, dynamic>> get _rows {
    final r = _search['rows'];
    return r is List
        ? r.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : const <Map<String, dynamic>>[];
  }

  Future<void> _open(String orderId) async {
    if (orderId.isEmpty) return;
    setState(() {
      _openId = orderId;
      _timeline = const {};
    });
    try {
      final res = await Supabase.instance.client
          .rpc('order_timeline', params: {'p_order_id': orderId});
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() => _timeline = m);
      RenderLog.write('c689_timeline',
          'access=${m['access'] ?? ''};events=${m['event_count'] ?? 0};can_act=${m['can_act'] == true}');
    } catch (e) {
      RenderLog.write('c689_timeline_err', e.toString());
    }
  }

  Future<TimelineActionResult> _act(
      TimelineAction action, Map<String, dynamic> extra) async {
    final args = Map<String, dynamic>.from(action.args);
    if (extra.isNotEmpty) {
      final inner = args['p_args'] is Map
          ? Map<String, dynamic>.from(args['p_args'] as Map)
          : <String, dynamic>{};
      inner.addAll(extra);
      args['p_args'] = inner;
    }
    try {
      final res = await Supabase.instance.client.rpc(action.rpc, params: args);
      RenderLog.write('c689_timeline_act',
          'kind=${action.kind};ok=${res is Map ? res['ok'] : null}');
      return TimelineActionResult.from(res);
    } catch (e) {
      RenderLog.write('c689_timeline_act_err', e.toString());
      return TimelineActionResult.from(
          {'ok': false, 'message': e.toString(), 'choices': const []});
    }
  }

  String _s(Map<String, dynamic> m, String k) => m[k]?.toString() ?? '';

  @override
  Widget build(BuildContext context) {
    final refused = _search['ok'] == false;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(_search, 'title'), style: Ds.t.subtitle),
        backgroundColor: Ds.c.surface,
      ),
      body: refused
          ? Center(
              child: Padding(
                padding: EdgeInsets.all(Ds.space.x24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(_s(_search, 'title'),
                      style: Ds.t.subtitle, textAlign: TextAlign.center),
                  SizedBox(height: Ds.space.x8),
                  Text(_s(_search, 'message'),
                      style: Ds.t.caption, textAlign: TextAlign.center),
                ]),
              ),
            )
          : ListView(
              padding: EdgeInsets.all(Ds.space.x16),
              children: [
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _q,
                      onSubmitted: (_) => _find(),
                      decoration: InputDecoration(
                        hintText: _s(_search, 'hint'),
                        filled: true,
                        fillColor: Ds.c.bg,
                        border: OutlineInputBorder(borderRadius: Ds.r.rChip),
                      ),
                    ),
                  ),
                  SizedBox(width: Ds.space.x12),
                  SizedBox(
                    height: Ds.space.x32 + Ds.space.x16,
                    child: FilledButton(
                      onPressed: _loading ? null : _find,
                      child: Text(_s(_search, 'button_label')),
                    ),
                  ),
                ]),
                SizedBox(height: Ds.space.x16),
                if (_loading)
                  Padding(
                    padding: EdgeInsets.all(Ds.space.x24),
                    child: const Center(child: CircularProgressIndicator()),
                  )
                else if (_rows.isEmpty)
                  Text(_s(_search, 'empty_label'), style: Ds.t.caption)
                else ...[
                  if (_s(_search, 'list_label').isNotEmpty) ...[
                    Text(_s(_search, 'list_label'), style: Ds.t.caption),
                    SizedBox(height: Ds.space.x8),
                  ],
                  for (final r in _rows) ...[
                    InkWell(
                      onTap: () => _open(_s(r, 'order_id')),
                      borderRadius: Ds.r.rChip,
                      child: Container(
                        padding: EdgeInsets.all(Ds.space.x12),
                        decoration: BoxDecoration(
                          color: _openId == _s(r, 'order_id')
                              ? Ds.c.brandSoft
                              : Ds.c.surface,
                          borderRadius: Ds.r.rChip,
                        ),
                        child: Row(children: [
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_s(r, 'order_code'), style: Ds.t.body),
                                  SizedBox(height: Ds.space.x4),
                                  Text(
                                    [
                                      _s(r, 'customer'),
                                      _s(r, 'placed_label'),
                                      _s(r, 'status_label'),
                                    ].where((e) => e.isNotEmpty).join(' · '),
                                    style: Ds.t.caption,
                                  ),
                                ]),
                          ),
                          SizedBox(width: Ds.space.x8),
                          Text(_s(r, 'amount_display'), style: Ds.t.body),
                        ]),
                      ),
                    ),
                    SizedBox(height: Ds.space.x8),
                  ],
                ],
                if (_timeline.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x24),
                  OrderEventTimeline(
                    view: OrderTimelineView.from(_timeline),
                    onAct: _act,
                    onRefreshed: (t) => setState(() => _timeline = t),
                  ),
                ],
              ],
            ),
    );
  }
}
