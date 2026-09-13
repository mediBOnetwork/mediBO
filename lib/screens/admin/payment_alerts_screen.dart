// CMD #1929 — Payment alerts.
//
// The partner's phone forwards every payment notification it sees; the backend
// parses it, matches it to a pending claim and verifies the payment by itself.
// This screen is the window onto that: it renders ONE payload
// (payment_alerts_screen) verbatim and computes nothing.
//
// Nothing here is zone- or date-aware on purpose. The RPC reads
// admin_active_zone() / admin_active_date() itself, so the header picker is
// the only place either lives.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

class PaymentAlertsScreen extends StatefulWidget {
  /// Injected so the widget test can render a payload without Supabase.
  final Future<Map<String, dynamic>> Function(String? status)? screenRpc;
  final Future<Map<String, dynamic>> Function(String alertId, String status)?
      setStatusRpc;

  const PaymentAlertsScreen({super.key, this.screenRpc, this.setStatusRpc});

  @override
  State<PaymentAlertsScreen> createState() => _PaymentAlertsScreenState();
}

class _PaymentAlertsScreenState extends State<PaymentAlertsScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String? _error;
  String _filter = '';
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _callScreen(String? status) async {
    if (widget.screenRpc != null) return widget.screenRpc!(status);
    final raw = await Supabase.instance.client.rpc(
      'payment_alerts_screen',
      params: {'p_status': status},
    );
    return (raw as Map).cast<String, dynamic>();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await _callScreen(_filter.isEmpty ? null : _filter);
      if (!mounted) return;
      setState(() {
        _payload = p;
        _loading = false;
        // ok:false is a payload too — its own message is what we show.
        _error = (p['ok'] == true) ? null : (p['message'] ?? '').toString();
      });
      RenderLog.write('pay_alert_rows', (p['rows'] as List?)?.length ?? 0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _setStatus(String alertId, String status) async {
    setState(() => _busy.add(alertId));
    try {
      if (widget.setStatusRpc != null) {
        await widget.setStatusRpc!(alertId, status);
      } else {
        await Supabase.instance.client.rpc('payment_alert_set_status',
            params: {'p_alert_id': alertId, 'p_status': status});
      }
      await _load();
    } catch (_) {
      // The list reload below is the only truth; a failed write just leaves
      // the row as the backend still has it.
    } finally {
      if (mounted) setState(() => _busy.remove(alertId));
    }
  }

  Color _toneBg(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'muted':
        return Ds.c.bg;
      default:
        return Ds.c.infoSoft;
    }
  }

  Color _toneFg(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'muted':
        return Ds.c.textSecondary;
      default:
        return Ds.c.info;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload ?? const <String, dynamic>{};
    final rows = (p['rows'] as List?)?.whereType<Map>().toList() ?? const [];
    final filters = (p['filters'] as List?)?.whereType<Map>().toList() ?? const [];

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text((p['title'] ?? '').toString(), style: Ds.t.subtitle),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.all(Ds.space.x16),
          children: [
            if ((p['subtitle'] ?? '').toString().isNotEmpty) ...[
              Text((p['subtitle']).toString(), style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
            ],
            if (filters.isNotEmpty) ...[
              _FilterRow(
                filters: filters,
                active: _filter,
                onPick: (k) {
                  setState(() => _filter = k);
                  _load();
                },
              ),
              SizedBox(height: Ds.space.x8),
            ],
            if ((p['count_label'] ?? '').toString().isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Text((p['count_label']).toString(), style: Ds.t.caption),
              ),
            if (_loading)
              ...List<Widget>.generate(3, (_) => const _AlertSkeleton())
            else if (_error != null && _error!.isNotEmpty)
              _ErrorCard(
                message: _error!,
                retryLabel: (p['retry_label'] ?? 'Retry').toString(),
                onRetry: _load,
              )
            else if (rows.isEmpty)
              _EmptyCard(
                label: (p['empty_label'] ?? '').toString(),
                hint: (p['empty_hint'] ?? '').toString(),
              )
            else
              for (final r in rows)
                Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x12),
                  child: _AlertCard(
                    row: r.cast<String, dynamic>(),
                    busy: _busy.contains((r['alert_id'] ?? '').toString()),
                    toneBg: _toneBg((r['status_tone'] ?? '').toString()),
                    toneFg: _toneFg((r['status_tone'] ?? '').toString()),
                    onRetry: () =>
                        _setStatus((r['alert_id']).toString(), 'new'),
                    onIgnore: () =>
                        _setStatus((r['alert_id']).toString(), 'ignored'),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final List<Map> filters;
  final String active;
  final ValueChanged<String> onPick;
  const _FilterRow(
      {required this.filters, required this.active, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final f in filters)
            Padding(
              padding: EdgeInsets.only(right: Ds.space.x8),
              child: _Chip(
                // chip_label is the whole caption, label + count already
                // joined by the backend. Nothing is composed here.
                label: (f['chip_label'] ?? '').toString(),
                selected: (f['key'] ?? '').toString() == active,
                onTap: () => onPick((f['key'] ?? '').toString()),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: selected ? Ds.c.brandSoft : Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
        ),
        child: Text(label,
            style: selected
                ? Ds.t.body.copyWith(color: Ds.c.brand)
                : Ds.t.bodySecondary),
      ),
    );
  }
}

class _AlertCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool busy;
  final Color toneBg;
  final Color toneFg;
  final VoidCallback onRetry;
  final VoidCallback onIgnore;

  const _AlertCard({
    required this.row,
    required this.busy,
    required this.toneBg,
    required this.toneFg,
    required this.onRetry,
    required this.onIgnore,
  });

  @override
  Widget build(BuildContext context) {
    final matched = (row['status'] ?? '').toString() == 'matched';
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text((row['amount_label'] ?? '').toString(),
                    style: Ds.t.title),
              ),
              SizedBox(width: Ds.space.x8),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration: BoxDecoration(color: toneBg, borderRadius: Ds.r.rChip),
                child: Text((row['status_label'] ?? '').toString(),
                    style: Ds.t.caption.copyWith(color: toneFg)),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text((row['sender_label'] ?? '').toString(), style: Ds.t.body),
          SizedBox(height: Ds.space.x12),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x4,
            children: [
              _Meta(text: (row['app_label'] ?? '').toString()),
              _Meta(text: (row['posted_label'] ?? '').toString()),
              _Meta(text: (row['source_label'] ?? '').toString()),
              _Meta(text: (row['utr_label'] ?? '').toString()),
            ],
          ),
          if ((row['customer_label'] ?? '').toString().isNotEmpty ||
              (row['order_code'] ?? '').toString().isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              [
                (row['customer_label'] ?? '').toString(),
                (row['order_code'] ?? '').toString(),
              ].where((s) => s.isNotEmpty).join(' · '),
              style: Ds.t.body.copyWith(color: Ds.c.brand),
            ),
          ],
          if ((row['match_reason'] ?? '').toString().isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text((row['match_reason']).toString(), style: Ds.t.caption),
          ],
          if (!matched) ...[
            SizedBox(height: Ds.space.x16),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      onPressed: busy ? null : onRetry,
                      child:
                          Text((row['retry_match_label'] ?? '').toString()),
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: IconButton(
                    tooltip: (row['ignore_label'] ?? '').toString(),
                    onPressed: busy ? null : onIgnore,
                    icon: Icon(Icons.block, color: Ds.c.textSecondary),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final String text;
  const _Meta({required this.text});
  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rChip),
      child: Text(text, style: Ds.t.caption),
    );
  }
}

class _AlertSkeleton extends StatelessWidget {
  const _AlertSkeleton();
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      height: Ds.space.x48 * 2,
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
    );
  }
}

class _EmptyCard extends StatelessWidget {
  final String label;
  final String hint;
  const _EmptyCard({required this.label, required this.hint});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Ds.t.body),
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(hint, style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  const _ErrorCard(
      {required this.message, required this.retryLabel, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: Ds.t.body),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
          ),
        ],
      ),
    );
  }
}
