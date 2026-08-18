import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #226 — the admin surface over the automatic customer-billing chain.
///
/// It renders `admin_bill_pipeline_list` / `admin_bill_pipeline` and decides
/// nothing: every label, every stage name, every chip and every action caption
/// arrives in the payload (from the `bill_pipeline_label` table). The only
/// thing this file maps is a backend `tone` string onto a design token.
class AdminBillPipelineScreen extends StatefulWidget {
  const AdminBillPipelineScreen({super.key});

  @override
  State<AdminBillPipelineScreen> createState() => _AdminBillPipelineScreenState();
}

/// The backend names a tone; the token layer owns what that colour is.
Color _toneColor(Object? tone) {
  switch ('$tone') {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'info':
      return Ds.c.info;
    case 'brand':
      return Ds.c.brand;
    default:
      return Ds.c.textSecondary;
  }
}

Color _toneSoft(Object? tone) {
  switch ('$tone') {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'info':
      return Ds.c.infoSoft;
    case 'brand':
      return Ds.c.brandSoft;
    default:
      return Ds.c.bg;
  }
}

class _AdminBillPipelineScreenState extends State<AdminBillPipelineScreen> {
  Map<String, dynamic>? _data;
  Object? _error;
  bool _loading = true;
  String _tab = 'active';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('admin_bill_pipeline_list', params: {'p_filter': _tab, 'p_limit': 100});
      setState(() {
        _data = Map<String, dynamic>.from(res as Map);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final tabs = (d?['tabs'] as List?) ?? const [];
    final rows = (d?['rows'] as List?) ?? const [];

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        foregroundColor: Ds.c.text,
        elevation: 0,
        title: Text('${d?['title'] ?? ''}',
            style: Ds.t.title.copyWith(color: Ds.c.text)),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: Column(children: [
          if (tabs.isNotEmpty)
            Container(
              width: double.infinity,
              color: Ds.c.surface,
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16, vertical: Ds.space.x8),
              child: Wrap(
                spacing: Ds.space.x8,
                runSpacing: Ds.space.x8,
                children: [
                  for (final t in tabs)
                    _TabChip(
                      label: '${(t as Map)['label'] ?? ''}',
                      selected: _tab == '${t['key']}',
                      onTap: () {
                        setState(() => _tab = '${t['key']}');
                        _load();
                      },
                    ),
                ],
              ),
            ),
          if ((d?['subtitle'] ?? '').toString().isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x16, Ds.space.x12, Ds.space.x16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('${d?['subtitle']}',
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
              ),
            ),
          Expanded(child: _body(d, rows)),
        ]),
      ),
    );
  }

  Widget _body(Map<String, dynamic>? d, List rows) {
    // Reachability proof: a canvas app cannot be clicked by a tool, so the
    // screen reports itself instead. `curl https://medibo.in/render-log` shows
    // c226_bill_pipeline_screen once an admin has opened it.
    RenderLog.write('c226_bill_pipeline_screen', 1);
    if (_loading) return const _Skeleton();
    if (_error != null || d?['ok'] != true) {
      return _ErrorState(
        message: '${d?['error'] ?? _error ?? ''}',
        retryLabel: '${d?['retry_label'] ?? ''}',
        onRetry: _load,
      );
    }
    if (rows.isEmpty) {
      return _EmptyState(label: '${d?['empty_label'] ?? ''}');
    }
    RenderLog.write('c226_bill_pipeline_rows', rows.length);
    return ListView.separated(
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: rows.length,
      separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
      itemBuilder: (_, i) => _OrderCard(
        row: Map<String, dynamic>.from(rows[i] as Map),
        onOpen: () => _openDetail('${rows[i]['order_id']}'),
      ),
    );
  }

  Future<void> _openDetail(String orderId) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (_) => _PipelineDetailSheet(orderId: orderId),
    );
    if (mounted) _load();
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Ds.r.chip),
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x8),
          decoration: BoxDecoration(
            color: selected ? Ds.c.brandSoft : Ds.c.bg,
            borderRadius: BorderRadius.circular(Ds.r.chip),
            border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
          ),
          child: Text(label,
              style: Ds.t.caption.copyWith(
                  color: selected ? Ds.c.brand : Ds.c.textSecondary,
                  fontWeight: FontWeight.w600)),
        ),
      );
}

class _ToneChip extends StatelessWidget {
  final String label;
  final Object? tone;
  const _ToneChip({required this.label, this.tone});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: _toneSoft(tone),
          borderRadius: BorderRadius.circular(Ds.r.chip),
        ),
        child: Text(label,
            style: Ds.t.caption
                .copyWith(color: _toneColor(tone), fontWeight: FontWeight.w600)),
      );
}

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onOpen;
  const _OrderCard({required this.row, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final chips = (row['chips'] as List?) ?? const [];
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(Ds.r.card),
      child: Container(
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: BorderRadius.circular(Ds.r.card),
          boxShadow: Ds.elevation.e1,
        ),
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${row['order_code'] ?? ''}',
                  style: Ds.t.subtitle.copyWith(
                      color: Ds.c.text, fontWeight: FontWeight.w700)),
            ),
            _ToneChip(
                label: '${row['stage_label'] ?? ''}', tone: row['stage_tone']),
          ]),
          SizedBox(height: Ds.space.x4),
          Text('${row['buyer_label'] ?? ''}',
              style: Ds.t.body.copyWith(color: Ds.c.text)),
          SizedBox(height: Ds.space.x4),
          Text('${row['placed_label'] ?? ''}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          if (chips.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                for (final ch in chips)
                  _ToneChip(
                      label: '${(ch as Map)['label'] ?? ''}',
                      tone: ch['tone']),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}

class _PipelineDetailSheet extends StatefulWidget {
  final String orderId;
  const _PipelineDetailSheet({required this.orderId});

  @override
  State<_PipelineDetailSheet> createState() => _PipelineDetailSheetState();
}

class _PipelineDetailSheetState extends State<_PipelineDetailSheet> {
  Map<String, dynamic>? _d;
  Object? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('admin_bill_pipeline', params: {'p_order_id': widget.orderId});
      setState(() {
        _d = Map<String, dynamic>.from(res as Map);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _act(String key) async {
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('admin_bill_pipeline_action',
          params: {'p_order_id': widget.orderId, 'p_action': key});
      final m = Map<String, dynamic>.from(res as Map);
      if (mounted && '${m['toast'] ?? ''}'.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('${m['toast']}')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: _loading
            ? const _Skeleton()
            : (_error != null || d?['ok'] != true)
                ? _ErrorState(
                    message: '${d?['error'] ?? _error ?? ''}',
                    retryLabel: '',
                    onRetry: _load)
                : _content(d!),
      ),
    );
  }

  Widget _content(Map<String, dynamic> d) {
    final steps = (d['steps'] as List?) ?? const [];
    final unver = Map<String, dynamic>.from((d['unverified'] as Map?) ?? {});
    final uncov = Map<String, dynamic>.from((d['uncovered'] as Map?) ?? {});
    final job = Map<String, dynamic>.from((d['job'] as Map?) ?? {});
    final actions = (d['actions'] as List?) ?? const [];

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      shrinkWrap: true,
      children: [
        Text('${d['order_code'] ?? ''}',
            style: Ds.t.title.copyWith(color: Ds.c.text)),
        SizedBox(height: Ds.space.x4),
        Text('${d['buyer_label'] ?? ''}',
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        SizedBox(height: Ds.space.x24),
        for (final s in steps) _StepRow(step: Map<String, dynamic>.from(s as Map)),
        SizedBox(height: Ds.space.x24),
        _Section(
          label: '${unver['label'] ?? ''}',
          emptyLabel: '${unver['empty_label'] ?? ''}',
          rows: (unver['rows'] as List?) ?? const [],
          line: (r) => '${r['raw_name'] ?? ''}',
          sub: (r) => '${r['supplier_label'] ?? ''} · ${r['reason_label'] ?? ''}',
        ),
        SizedBox(height: Ds.space.x24),
        _Section(
          label: '${uncov['label'] ?? ''}',
          emptyLabel: '${uncov['empty_label'] ?? ''}',
          rows: (uncov['rows'] as List?) ?? const [],
          line: (r) => '${r['product_label'] ?? ''}',
          sub: (r) => '${r['supplier_label'] ?? ''} · ${r['qty_label'] ?? ''}',
        ),
        SizedBox(height: Ds.space.x24),
        Row(children: [
          Expanded(
            child: Text('${job['label'] ?? ''}',
                style: Ds.t.body
                    .copyWith(color: Ds.c.text, fontWeight: FontWeight.w600)),
          ),
          _ToneChip(label: '${job['status_label'] ?? ''}', tone: job['tone']),
        ]),
        if ('${job['attempts_label'] ?? ''}'.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text('${job['attempts_label']}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        ],
        if ('${job['error_label'] ?? ''}'.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text('${job['error_label']}',
              style: Ds.t.caption.copyWith(color: Ds.c.danger)),
        ],
        if ('${d['blocked_label'] ?? ''}'.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          Text('${d['blocked_label']}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        ],
        for (final a in actions) ...[
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _busy ? null : () => _act('${(a as Map)['key']}'),
              style: FilledButton.styleFrom(
                backgroundColor: _toneColor((a as Map)['tone']),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Ds.r.button)),
              ),
              child: Text('${a['label'] ?? ''}'),
            ),
          ),
        ],
        SizedBox(height: Ds.space.x16),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  final Map<String, dynamic> step;
  const _StepRow({required this.step});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: Ds.space.x8,
            height: Ds.space.x8,
            margin: EdgeInsets.only(top: Ds.space.x8, right: Ds.space.x12),
            decoration: BoxDecoration(
                color: _toneColor(step['tone']), shape: BoxShape.circle),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${step['label'] ?? ''}',
                  style: Ds.t.body
                      .copyWith(color: Ds.c.text, fontWeight: FontWeight.w600)),
              Text('${step['status_label'] ?? ''}',
                  style: Ds.t.caption.copyWith(color: _toneColor(step['tone']))),
              if ('${step['detail'] ?? ''}'.isNotEmpty)
                Text('${step['detail']}',
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            ]),
          ),
        ]),
      );
}

class _Section extends StatelessWidget {
  final String label;
  final String emptyLabel;
  final List rows;
  final String Function(Map) line;
  final String Function(Map) sub;
  const _Section({
    required this.label,
    required this.emptyLabel,
    required this.rows,
    required this.line,
    required this.sub,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: Ds.t.body
                  .copyWith(color: Ds.c.text, fontWeight: FontWeight.w600)),
          SizedBox(height: Ds.space.x8),
          if (rows.isEmpty)
            Text(emptyLabel,
                style: Ds.t.caption.copyWith(color: Ds.c.textSecondary))
          else
            for (final r in rows)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(line(r as Map), style: Ds.t.body.copyWith(color: Ds.c.text)),
                      Text(sub(r),
                          style: Ds.t.caption
                              .copyWith(color: Ds.c.textSecondary)),
                    ]),
              ),
        ],
      );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: EdgeInsets.all(Ds.space.x16),
        itemCount: 4,
        separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
        itemBuilder: (_, __) => Container(
          height: Ds.space.x48 + Ds.space.x32,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: BorderRadius.circular(Ds.r.card),
          ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  final String label;
  const _EmptyState({required this.label});
  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x32),
        children: [
          Text(label,
              textAlign: TextAlign.center,
              style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
        ],
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  const _ErrorState(
      {required this.message, required this.retryLabel, required this.onRetry});

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x32),
        children: [
          Text(message,
              textAlign: TextAlign.center,
              style: Ds.t.body.copyWith(color: Ds.c.danger)),
          if (retryLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
            ),
          ],
        ],
      );
}
