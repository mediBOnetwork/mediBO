// CHANGE #323 — the partner's own settlement statement.
//
// A fulfilment partner sees exactly one thing here: the statements for THEIR
// zone. The zone is never picked — `partner_statement()` resolves it from the
// partner's own region_partners row and the row policies underneath refuse
// anything else, so a forged period id gets the backend's refusal copy rather
// than somebody else's money.
//
// The screen renders the SAME statement body the admin reads
// (`settlementStatementBody`), because due / transferred / pending are one
// payload in both Razorpay Route lanes. What the partner does NOT get is the
// admin's actions: `is_admin` and `can_settle` are false in their payload, so
// Record and Settle are simply absent.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/partner_state.dart';
import '../../utils/render_log.dart';
import '../admin/settlement_screen.dart';

class PartnerStatementScreen extends StatefulWidget {
  const PartnerStatementScreen({super.key, this.rpc});

  /// Test seam. Null in production -> the real RPCs.
  final PartnerRpc? rpc;

  @override
  State<PartnerStatementScreen> createState() => _PartnerStatementScreenState();
}

class _PartnerStatementScreenState extends State<PartnerStatementScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  int? _periodId;

  PartnerRpc get _rpc => widget.rpc ?? PartnerApi.call;

  Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> p;
    try {
      p = _asMap(await _rpc('partner_statement',
          _periodId == null ? const {} : {'p_period_id': _periodId}));
    } catch (_) {
      p = const <String, dynamic>{};
    }
    if (!mounted) return;
    setState(() {
      _payload = p;
      _loading = false;
    });
    RenderLog.write('c323_partner_statement', 'painted');
    RenderLog.write('c323_partner_periods',
        '${((_asMap(p['periods'])['rows']) as List?)?.length ?? 0}');
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    final refused = p != null && p['ok'] == false;
    if (_loading) return settlementSkeleton();
    if (refused) {
      return settlementMessage((p['message'] ?? '').toString(), 'danger');
    }
    final periods = _asMap(p?['periods']);
    final statement = _asMap(p?['statement']);
    final rows = (periods['rows'] as List?) ?? const [];

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          Text((p?['subtitle'] ?? '').toString(), style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x24),
          settlementSection(
            heading: (periods['heading'] ?? '').toString(),
            rows: rows,
            emptyText: (periods['empty_text'] ?? '').toString(),
            onTap: (r) {
              final id = r['period_id'];
              setState(() =>
                  _periodId = id is int ? id : int.tryParse('${id ?? ''}'));
              _load();
            },
          ),
          if (statement.isNotEmpty && statement['ok'] != false) ...[
            SizedBox(height: Ds.space.x24),
            Text((statement['heading'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x8),
            settlementChip((statement['status_label'] ?? '').toString(),
                (statement['status_tone'] ?? '').toString()),
            if (statement['negative'] == true) ...[
              SizedBox(height: Ds.space.x16),
              settlementMessage(
                  (statement['negative_text'] ?? '').toString(), 'warning'),
            ],
            SizedBox(height: Ds.space.x16),
            settlementTiles((statement['tiles'] as List?) ?? const []),
            SizedBox(height: Ds.space.x24),
            settlementSection(
              heading: (_asMap(statement['costs'])['heading'] ?? '').toString(),
              rows: (_asMap(statement['costs'])['rows'] as List?) ?? const [],
              emptyText: '',
            ),
            SizedBox(height: Ds.space.x24),
            settlementSection(
              heading: (_asMap(statement['orders'])['heading'] ?? '').toString(),
              rows: (_asMap(statement['orders'])['rows'] as List?) ?? const [],
              emptyText:
                  (_asMap(statement['orders'])['empty_text'] ?? '').toString(),
            ),
            SizedBox(height: Ds.space.x24),
            settlementSection(
              heading:
                  (_asMap(statement['payments'])['heading'] ?? '').toString(),
              rows: (_asMap(statement['payments'])['rows'] as List?) ?? const [],
              emptyText:
                  (_asMap(statement['payments'])['empty_text'] ?? '').toString(),
            ),
          ] else if (rows.isEmpty) ...[
            SizedBox(height: Ds.space.x24),
            settlementMessage((p?['empty_text'] ?? '').toString(), null),
          ],
          SizedBox(height: Ds.space.x24),
          Text((p?['footnote'] ?? '').toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x32),
        ],
      ),
    );
  }
}
