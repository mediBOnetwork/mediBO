import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// cmd #299 — PART 3: what every notification costs, and what push saved.
///
/// The screen computes NOTHING. `notif_cost_dashboard(p_days)` returns the
/// title, the subtitle, the range label, four total tiles, the savings line and
/// one row per event — every rupee already formatted `₹0.00` in Postgres from
/// the rates in `notification_cost_config`. Change a rate there and this screen
/// reprices with no deploy.
class NotifyCostScreen extends StatefulWidget {
  const NotifyCostScreen({super.key});

  /// Test seam: feed a payload in without Supabase. Same idea as
  /// NotificationsCard.rpcOverride.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcOverride;

  @override
  State<NotifyCostScreen> createState() => _NotifyCostScreenState();
}

class _NotifyCostScreenState extends State<NotifyCostScreen> {
  /// The windows the admin can look through. The LABEL for the selected one is
  /// the backend's `range_label`, never assembled here.
  static const _windows = <int>[7, 30, 90];

  Map<String, dynamic>? _data;
  bool _loading = true;
  String _error = '';
  int _days = 30;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) {
    final o = NotifyCostScreen.rpcOverride;
    if (o != null) return o(fn, params);
    return params == null
        ? Supabase.instance.client.rpc(fn)
        : Supabase.instance.client.rpc(fn, params: params);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final res = await _rpc('notif_cost_dashboard', {'p_days': _days});
      final m = res is Map
          ? Map<String, dynamic>.from(res)
          : const <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _data = m;
        _loading = false;
      });
      RenderLog.write('c299_cost_rows', '${(m['rows'] as List?)?.length ?? 0}');
      RenderLog.write('c299_cost_screen', 'painted');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
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
    final d = _data;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text((d?['title'] ?? '').toString(), style: Ds.t.subtitle),
        backgroundColor: Ds.c.surface,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: (d?['range_label'] ?? '').toString(),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? _skeleton()
          : _error.isNotEmpty
              ? _errorState()
              : RefreshIndicator(onRefresh: _load, child: _body(d)),
    );
  }

  Widget _body(Map<String, dynamic>? d) {
    final totals = (d?['totals'] as List?) ?? const [];
    final rows = (d?['rows'] as List?) ?? const [];
    final savings = d?['savings'] is Map
        ? Map<String, dynamic>.from(d!['savings'] as Map)
        : const <String, dynamic>{};

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text((d?['subtitle'] ?? '').toString(), style: Ds.t.bodySecondary),
        SizedBox(height: Ds.space.x16),
        _rangePicker((d?['range_label'] ?? '').toString()),
        SizedBox(height: Ds.space.x24),
        if (totals.isNotEmpty) _totalsGrid(totals),
        if (savings.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _savingsCard(savings),
        ],
        SizedBox(height: Ds.space.x32),
        Text((d?['rows_heading'] ?? '').toString(), style: Ds.t.bodyStrong),
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty)
          _emptyState((d?['empty_text'] ?? '').toString())
        else
          for (final r in rows)
            if (r is Map) _eventRow(Map<String, dynamic>.from(r)),
        SizedBox(height: Ds.space.x24),
        Text((d?['footnote'] ?? '').toString(), style: Ds.t.caption),
        SizedBox(height: Ds.space.x32),
      ],
    );
  }

  /// The only thing this picker sends is a number of days. The words next to it
  /// are the backend's.
  Widget _rangePicker(String rangeLabel) => Row(
        children: [
          for (final w in _windows)
            Padding(
              padding: EdgeInsets.only(right: Ds.space.x8),
              child: ChoiceChip(
                label: Text('$w', style: Ds.t.caption),
                selected: _days == w,
                onSelected: (_) {
                  if (_days == w) return;
                  setState(() => _days = w);
                  _load();
                },
              ),
            ),
          Expanded(
            child: Text(rangeLabel,
                textAlign: TextAlign.right, style: Ds.t.caption),
          ),
        ],
      );

  Widget _totalsGrid(List<dynamic> totals) => LayoutBuilder(
        builder: (context, box) {
          final cols = box.maxWidth >= 640 ? 4 : 2;
          final gap = Ds.space.x12;
          final w = (box.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final t in totals)
                if (t is Map)
                  SizedBox(
                      width: w, child: _totalTile(Map<String, dynamic>.from(t))),
            ],
          );
        },
      );

  Widget _totalTile(Map<String, dynamic> t) {
    final tone = (t['tone'] ?? '').toString();
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text((t['label'] ?? '').toString(),
              style: Ds.t.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
          SizedBox(height: Ds.space.x8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text((t['value'] ?? '').toString(),
                style: Ds.t.title.copyWith(color: _tone(tone))),
          ),
        ],
      ),
    );
  }

  Widget _savingsCard(Map<String, dynamic> s) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.successSoft,
          borderRadius: Ds.r.rCard,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text((s['label'] ?? '').toString(), style: Ds.t.caption),
            SizedBox(height: Ds.space.x4),
            Text((s['value'] ?? '').toString(),
                style: Ds.t.title.copyWith(color: Ds.c.success)),
            SizedBox(height: Ds.space.x8),
            Text((s['note'] ?? '').toString(), style: Ds.t.caption),
          ],
        ),
      );

  Widget _eventRow(Map<String, dynamic> r) => Container(
        margin: EdgeInsets.only(bottom: Ds.space.x8),
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text((r['label'] ?? '').toString(), style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x4),
                  Text(
                    [
                      (r['sends_label'] ?? '').toString(),
                      (r['mix_label'] ?? '').toString(),
                    ].where((s) => s.isNotEmpty).join('  ·  '),
                    style: Ds.t.caption,
                  ),
                ],
              ),
            ),
            SizedBox(width: Ds.space.x12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text((r['cost_display'] ?? '').toString(),
                    style: Ds.t.bodyStrong),
                SizedBox(height: Ds.space.x4),
                Text('${r['share_pct'] ?? 0}%', style: Ds.t.caption),
              ],
            ),
          ],
        ),
      );

  Widget _emptyState(String text) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x24),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Text(text, textAlign: TextAlign.center, style: Ds.t.bodySecondary),
      );

  Widget _errorState() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(c('notif_cost.error'),
                  textAlign: TextAlign.center, style: Ds.t.bodySecondary),
              SizedBox(height: Ds.space.x16),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                    onPressed: _load, child: Text(c('notif_cost.retry'))),
              ),
            ],
          ),
        ),
      );

  /// A skeleton, not a bare spinner — the shape of the answer while it loads.
  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 6; i++)
            Container(
              height: Ds.space.x48,
              margin: EdgeInsets.only(bottom: Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                border: Border.all(color: Ds.c.divider),
              ),
            ),
        ],
      );
}
