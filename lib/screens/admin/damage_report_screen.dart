import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #709 — what we broke, and how often.
///
/// Four tabs, all of them the payload's: the queue still waiting for a
/// partner's word, then the rate by worker, by supplier and by product. The
/// screen picks no threshold, computes no percentage and colours nothing by a
/// number it read — `tone` and every label arrive from `damage_report()`.
class DamageReportScreen extends StatefulWidget {
  const DamageReportScreen({super.key});

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<DamageReportScreen> createState() => _DamageReportScreenState();
}

class _DamageReportScreenState extends State<DamageReportScreen> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  String _tab = 'queue';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await DamageReportScreen.rpc('damage_report', {'p_days': 30});
      if (!mounted) return;
      setState(() {
        _p = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
      RenderLog.write('c709_damage_report',
          'ok=${_p['ok']};queue=${((_p['queue'] as List?) ?? const []).length}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _decide(Object id, bool confirm) async {
    final res = await DamageReportScreen.rpc(
        'damage_confirm', {'p_damage_id': id, 'p_confirm': confirm});
    final m = res is Map ? Map<String, dynamic>.from(res) : const {};
    if (!mounted) return;
    final msg = (m['message'] ?? '').toString();
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: m['ok'] == true ? Ds.c.brand : Ds.c.danger,
      ));
    }
    await _load();
  }

  List<Map<String, dynamic>> _rows(String key) =>
      ((_p[key] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  @override
  Widget build(BuildContext context) {
    final title = (_p['title'] ?? '').toString();
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(title, style: Ds.t.subtitle)),
      body: SafeArea(
        child: _loading
            ? DamageReportView.skeleton()
            : RefreshIndicator(
                onRefresh: _load,
                child: DamageReportView(
                  payload: _p,
                  tab: _tab,
                  onTab: (k) => setState(() => _tab = k),
                  rows: _rows,
                  onDecide: _decide,
                ),
              ),
      ),
    );
  }
}

/// The rendered report, split from the screen so a protected test can pump a
/// payload with no Supabase and no timers.
class DamageReportView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final String tab;
  final ValueChanged<String> onTab;
  final List<Map<String, dynamic>> Function(String key) rows;
  final Future<void> Function(Object id, bool confirm)? onDecide;

  const DamageReportView({
    super.key,
    required this.payload,
    required this.tab,
    required this.onTab,
    required this.rows,
    this.onDecide,
  });

  static Widget skeleton() => Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 4; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                    height: Ds.space.x48,
                    decoration:
                        BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard)),
              ),
          ],
        ),
      );

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  Color _tone(String tone) => tone == 'danger' ? Ds.c.danger : Ds.c.textSecondary;

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] != true) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(_s(payload, 'message'),
              textAlign: TextAlign.center, style: Ds.t.body),
        ),
      );
    }

    final tabs = ((payload['tabs'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final list = rows(tab);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(payload, 'summary'), style: Ds.t.body),
        SizedBox(height: Ds.space.x4),
        Text(_s(payload, 'total_amount_display'), style: Ds.t.caption),
        // CHANGE #956 — damage the backend has not been able to price yet.
        // The string is composed server-side and is empty when there is
        // nothing unpriced, so this row simply is not there.
        if (_s(payload, 'unvalued_label').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s(payload, 'unvalued_label'),
              style: Ds.t.caption.copyWith(color: Ds.c.warning)),
        ],
        SizedBox(height: Ds.space.x16),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final t in tabs)
              ChoiceChip(
                label: Text('${_s(t, 'label')} (${t['count'] ?? 0})'),
                selected: tab == _s(t, 'key'),
                onSelected: (_) => onTab(_s(t, 'key')),
              ),
          ],
        ),
        SizedBox(height: Ds.space.x16),
        if (list.isEmpty)
          Text(_s(payload, 'empty_note'), style: Ds.t.caption)
        else
          for (final r in list) ...[
            Container(
              padding: EdgeInsets.all(Ds.space.x16),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1,
              ),
              child: tab == 'queue'
                  ? _QueueRow(row: r, onDecide: onDecide)
                  : Row(children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_s(r, 'label'), style: Ds.t.body),
                            SizedBox(height: Ds.space.x4),
                            Text(_s(r, 'summary'), style: Ds.t.caption),
                          ],
                        ),
                      ),
                      SizedBox(width: Ds.space.x12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(_s(r, 'rate_label'),
                              style: Ds.t.body
                                  .copyWith(color: _tone(_s(r, 'tone')))),
                          SizedBox(height: Ds.space.x4),
                          Text(_s(r, 'amount_display'), style: Ds.t.caption),
                          if (_s(r, 'unvalued_label').isNotEmpty) ...[
                            SizedBox(height: Ds.space.x4),
                            Text(_s(r, 'unvalued_label'),
                                style:
                                    Ds.t.caption.copyWith(color: Ds.c.warning)),
                          ],
                        ],
                      ),
                    ]),
            ),
            SizedBox(height: Ds.space.x12),
          ],
      ],
    );
  }
}

class _QueueRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final Future<void> Function(Object id, bool confirm)? onDecide;

  const _QueueRow({required this.row, this.onDecide});

  String _s(String k) => (row[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final id = row['id'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text(_s('product_name'), style: Ds.t.body)),
          SizedBox(width: Ds.space.x8),
          Text(_s('qty'), style: Ds.t.body),
        ]),
        SizedBox(height: Ds.space.x4),
        Text(
          [
            _s('order_code'),
            _s('reason'),
            _s('stage_label'),
            _s('worker_label'),
          ].where((e) => e.isNotEmpty).join(' · '),
          style: Ds.t.caption,
        ),
        if (_s('note').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s('note'), style: Ds.t.caption),
        ],
        if (id != null && onDecide != null) ...[
          SizedBox(height: Ds.space.x12),
          Row(children: [
            Expanded(
              child: SizedBox(
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: () => onDecide!(id as Object, true),
                  child: Text(_s('confirm_label')),
                ),
              ),
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(
              child: SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: () => onDecide!(id as Object, false),
                  child: Text(_s('reject_label')),
                ),
              ),
            ),
          ]),
        ],
      ],
    );
  }
}
