import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #227 — the written audit of date + zone scope across the whole
/// customer-order → delivered flow, rendered from `admin_scope_audit()`.
///
/// This screen decides nothing. Every title, chip, status word, before/after
/// sentence and banner arrives in the payload (from `ui_copy` via `_scl`), and
/// the pass/fail per RPC is computed in the BACKEND by `scope_contract_status()`
/// against the LIVE function source — so what is drawn here is what is true in
/// the database right now, not what was true when this file was written.
///
/// The only mapping this file owns is a backend `tone` string → a design token,
/// exactly as the bill-pipeline screen does.
class AdminScopeAuditScreen extends StatefulWidget {
  const AdminScopeAuditScreen({super.key});

  @override
  State<AdminScopeAuditScreen> createState() => _AdminScopeAuditScreenState();
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

class _AdminScopeAuditScreenState extends State<AdminScopeAuditScreen> {
  Map<String, dynamic>? _data;
  Object? _error;
  bool _loading = true;

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
      final res =
          await Supabase.instance.client.rpc('admin_scope_audit', params: {});
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
    final stages = (d?['stages'] as List?) ?? const [];

    RenderLog.write('c227_scope_audit_screen', 1);
    RenderLog.write('c227_scope_audit_stages', stages.length);
    final rowCount = stages.fold<int>(
        0, (a, s) => a + (((s as Map)['rows'] as List?)?.length ?? 0));
    RenderLog.write('c227_scope_audit_rows', rowCount);

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
        child: _loading
            ? const _Skeleton()
            : (_error != null
                ? _ErrorState(error: _error, retryLabel: '${d?['retry_label'] ?? ''}', onRetry: _load)
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                        Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
                    children: [
                      _Header(d: d),
                      SizedBox(height: Ds.space.x24),
                      if (stages.isEmpty)
                        _Empty(label: '${d?['empty_label'] ?? ''}')
                      else
                        for (final s in stages) ...[
                          _StageBlock(
                            stage: Map<String, dynamic>.from(s as Map),
                            colBefore: '${d?['col_before'] ?? ''}',
                            colAfter: '${d?['col_after'] ?? ''}',
                          ),
                          SizedBox(height: Ds.space.x24),
                        ],
                    ],
                  )),
      ),
    );
  }
}

/// Banner + the scope line + the rule + the four summary counters.
class _Header extends StatelessWidget {
  final Map<String, dynamic>? d;
  const _Header({required this.d});

  @override
  Widget build(BuildContext context) {
    final summary = (d?['summary'] as List?) ?? const [];
    final tone = d?['banner_tone'];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: _toneSoft(tone),
          borderRadius: Ds.r.rCard,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${d?['banner_label'] ?? ''}',
              style: Ds.t.subtitle.copyWith(color: _toneColor(tone))),
          SizedBox(height: Ds.space.x4),
          Text('${d?['subtitle'] ?? ''}', style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text('${d?['scope_line'] ?? ''}', style: Ds.t.caption),
        ]),
      ),
      SizedBox(height: Ds.space.x16),
      Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: [
          for (final s in summary)
            _SummaryTile(row: Map<String, dynamic>.from(s as Map)),
        ],
      ),
      SizedBox(height: Ds.space.x16),
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${d?['rule_title'] ?? ''}', style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text('${d?['rule_body'] ?? ''}', style: Ds.t.bodySecondary),
        ]),
      ),
    ]);
  }
}

class _SummaryTile extends StatelessWidget {
  final Map<String, dynamic> row;
  const _SummaryTile({required this.row});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${row['value'] ?? ''}',
            style: Ds.t.title.copyWith(color: _toneColor(row['tone']))),
        Text('${row['label'] ?? ''}', style: Ds.t.caption),
      ]),
    );
  }
}

/// One stage of the flow (WhatsApp intake, Pack, Payments …) and its RPCs.
class _StageBlock extends StatelessWidget {
  final Map<String, dynamic> stage;
  final String colBefore;
  final String colAfter;

  const _StageBlock({
    required this.stage,
    required this.colBefore,
    required this.colAfter,
  });

  @override
  Widget build(BuildContext context) {
    final rows = (stage['rows'] as List?) ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.only(left: Ds.space.x4, bottom: Ds.space.x8),
        child: Row(children: [
          Expanded(
              child: Text('${stage['stage'] ?? ''}',
                  style: Ds.t.subtitle.copyWith(color: Ds.c.brand))),
          Text('${stage['count_label'] ?? ''}', style: Ds.t.caption),
        ]),
      ),
      for (final r in rows) ...[
        _RpcCard(
          row: Map<String, dynamic>.from(r as Map),
          colBefore: colBefore,
          colAfter: colAfter,
        ),
        SizedBox(height: Ds.space.x8),
      ],
    ]);
  }
}

class _RpcCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final String colBefore;
  final String colAfter;

  const _RpcCard({
    required this.row,
    required this.colBefore,
    required this.colAfter,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${row['rpc'] ?? ''}', style: Ds.t.body),
                  if ('${row['surface'] ?? ''}'.isNotEmpty)
                    Text('${row['surface']}', style: Ds.t.caption),
                ]),
          ),
          SizedBox(width: Ds.space.x8),
          _Pill(label: '${row['status_label'] ?? ''}', tone: row['status_tone']),
        ]),
        SizedBox(height: Ds.space.x12),
        Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
          _Pill(label: '${row['date_label'] ?? ''}', tone: row['date_tone']),
          _Pill(label: '${row['zone_label'] ?? ''}', tone: row['zone_tone']),
        ]),
        SizedBox(height: Ds.space.x12),
        _BeforeAfter(
            label: colBefore, value: '${row['before_label'] ?? ''}'),
        SizedBox(height: Ds.space.x4),
        _BeforeAfter(label: colAfter, value: '${row['after_label'] ?? ''}'),
        if ('${row['note'] ?? ''}'.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text('${row['note']}', style: Ds.t.caption),
        ],
      ]),
    );
  }
}

class _BeforeAfter extends StatelessWidget {
  final String label;
  final String value;
  const _BeforeAfter({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(
          width: Ds.space.x48 + Ds.space.x16,
          child: Text(label, style: Ds.t.caption)),
      Expanded(child: Text(value, style: Ds.t.bodySecondary)),
    ]);
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Object? tone;
  const _Pill({required this.label, this.tone});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: _toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: _toneColor(tone))),
    );
  }
}

class _Empty extends StatelessWidget {
  final String label;
  const _Empty({required this.label});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x48),
        child: Center(child: Text(label, style: Ds.t.bodySecondary)),
      );
}

/// Loading is a skeleton, never a bare spinner (design QA §6).
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 6; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Container(
                height: Ds.space.x48 + Ds.space.x32,
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rCard,
                ),
              ),
            ),
        ],
      );
}

class _ErrorState extends StatelessWidget {
  final Object? error;
  final String retryLabel;
  final VoidCallback onRetry;
  const _ErrorState(
      {required this.error, required this.retryLabel, required this.onRetry});

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          SizedBox(height: Ds.space.x48),
          Text('$error', style: Ds.t.bodySecondary, textAlign: TextAlign.center),
          SizedBox(height: Ds.space.x16),
          Center(
            child: OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
          ),
        ],
      );
}
