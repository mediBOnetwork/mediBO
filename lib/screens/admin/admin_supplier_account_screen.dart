// CHANGE #402 — the admin side of the supplier account layer.
//
// Two things that must be visible to a human at mediBO, on one screen:
//
//   1. PAYOUT APPROVALS. A supplier's new bank/UPI details do NOTHING until
//      someone here approves them. The card shows the name-match verdict the
//      backend computed (no penny drop, no rupee moved) next to the details
//      currently in use, so the decision is made with both in front of you.
//
//   2. HINDI COVERAGE. A supplier key with no Hindi value falls back to
//      English — correct behaviour, and invisible unless something counts it.
//      This is the count, per surface, with the missing keys listed and
//      editable in place: typing the Hindi here is live on the next boot, with
//      no deploy.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/supplier_account_state.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

class AdminSupplierAccountScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final SupplierRpc? rpc;
  const AdminSupplierAccountScreen({super.key, this.rpc});

  @override
  State<AdminSupplierAccountScreen> createState() =>
      _AdminSupplierAccountScreenState();
}

class _AdminSupplierAccountScreenState extends State<AdminSupplierAccountScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);
  Map<String, dynamic>? _queue;
  Map<String, dynamic>? _report;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : SupplierApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final q = await _call('admin_supplier_payout_queue', const {});
    final r = await _call('ui_language_report', {'p_lang': 'hi', 'p_limit': 300});
    if (!mounted) return;
    setState(() {
      _queue = q;
      _report = r;
    });
  }

  void _toast(Map<String, dynamic> r) {
    final msg = supplierStr(r, 'message');
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: supplierTone(r['tone']),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        title: Text(c('admin_supplier_account.title')),
        bottom: TabBar(
          controller: _tabs,
          labelColor: Ds.c.brand,
          unselectedLabelColor: Ds.c.textSecondary,
          indicatorColor: Ds.c.brand,
          tabs: [
            Tab(text: c('admin_supplier_account.tab_payouts')),
            Tab(text: c('admin_supplier_account.tab_language')),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _queue == null
              ? const Center(child: CircularProgressIndicator())
              : AdminPayoutQueueView(
                  payload: _queue!,
                  onReview: (id, decision, note) async {
                    final r = await _call('admin_supplier_payout_review',
                        {'p_id': id, 'p_decision': decision, 'p_note': note});
                    _toast(r);
                    await _load();
                  },
                ),
          _report == null
              ? const Center(child: CircularProgressIndicator())
              : AdminHindiCoverageView(
                  payload: _report!,
                  onSave: (key, value) async {
                    final r = await _call('ui_i18n_set',
                        {'p_key': key, 'p_lang': 'hi', 'p_value': value});
                    _toast(r);
                    await _load();
                  },
                ),
        ],
      ),
    );
  }
}

/// Pure view — a payload in, a queue drawn. No Supabase.
class AdminPayoutQueueView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final Future<void> Function(int id, String decision, String note) onReview;

  const AdminPayoutQueueView({
    super.key,
    required this.payload,
    required this.onReview,
  });

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Center(
            child: Text(supplierStr(payload, 'message'),
                style: Ds.t.bodySecondary)),
      );
    }
    final rows = supplierRows(payload['rows']);
    RenderLog.write('c402_payout_queue', rows.length);
    if (rows.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Center(
            child: Text(supplierStr(payload, 'empty'), style: Ds.t.caption)),
      );
    }
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(supplierStr(payload, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        for (final row in rows) ...[
          _QueueCard(row: row, payload: payload, onReview: onReview),
          SizedBox(height: Ds.space.x16),
        ],
      ],
    );
  }
}

class _QueueCard extends StatefulWidget {
  final Map<String, dynamic> row;
  final Map<String, dynamic> payload;
  final Future<void> Function(int id, String decision, String note) onReview;
  const _QueueCard({
    required this.row,
    required this.payload,
    required this.onReview,
  });

  @override
  State<_QueueCard> createState() => _QueueCardState();
}

class _QueueCardState extends State<_QueueCard> {
  final _note = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _decide(String decision) async {
    final pending = supplierMap(widget.row['pending']);
    final id = pending['id'];
    if (id is! int) return;
    setState(() => _busy = true);
    await widget.onReview(id, decision, _note.text);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payload;
    final pending = supplierMap(widget.row['pending']);
    final current = widget.row['current'] is Map
        ? supplierMap(widget.row['current'])
        : null;

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
          Text(supplierStr(widget.row, 'supplier_name'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          _Details(detail: pending),
          if (supplierStr(pending, 'match_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              supplierStr(pending, 'match_label'),
              style: Ds.t.caption
                  .copyWith(color: supplierTone(pending['match_tone'])),
            ),
          ],
          if (current != null) ...[
            SizedBox(height: Ds.space.x16),
            Text(supplierStr(p, 'current_heading'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x4),
            _Details(detail: current),
          ],
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: _note,
            style: Ds.t.body,
            decoration: InputDecoration(
              hintText: supplierStr(p, 'note_hint'),
              hintStyle: Ds.t.caption,
              filled: true,
              fillColor: Ds.c.bg,
              contentPadding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x12),
              border: OutlineInputBorder(
                borderRadius: Ds.r.rButton,
                borderSide: BorderSide(color: Ds.c.divider),
              ),
            ),
          ),
          SizedBox(height: Ds.space.x12),
          Row(children: [
            Expanded(
              child: SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Ds.c.danger,
                    side: BorderSide(color: Ds.c.danger),
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  onPressed: _busy ? null : () => _decide('reject'),
                  child: Text(supplierStr(p, 'reject_label')),
                ),
              ),
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(
              child: SizedBox(
                height: Ds.touch.minTarget,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  onPressed: _busy ? null : () => _decide('approve'),
                  child: Text(supplierStr(p, 'approve_label')),
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

class _Details extends StatelessWidget {
  final Map<String, dynamic> detail;
  const _Details({required this.detail});

  @override
  Widget build(BuildContext context) {
    final parts = [
      supplierStr(detail, 'account_name'),
      supplierStr(detail, 'account_number_masked'),
      supplierStr(detail, 'ifsc'),
      supplierStr(detail, 'bank_name'),
      supplierStr(detail, 'upi_vpa'),
    ].where((s) => s.isNotEmpty).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(parts.join(' · '), style: Ds.t.body),
        SizedBox(height: Ds.space.x4),
        Text(supplierStr(detail, 'submitted_label'), style: Ds.t.caption),
      ],
    );
  }
}

/// The gap report, and the one control that closes a gap.
class AdminHindiCoverageView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final Future<void> Function(String key, String value) onSave;

  const AdminHindiCoverageView({
    super.key,
    required this.payload,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Center(
            child: Text(supplierStr(payload, 'message'),
                style: Ds.t.bodySecondary)),
      );
    }
    final scopes = supplierRows(payload['scopes']);
    final missing = supplierRows(payload['missing_rows']);
    RenderLog.write('c402_i18n_missing', missing.length);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(supplierStr(payload, 'headline'),
            style: Ds.t.title.copyWith(color: supplierTone(payload['tone']))),
        SizedBox(height: Ds.space.x4),
        Text(supplierStr(payload, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        for (final s in scopes) ...[
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16, vertical: Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
              boxShadow: Ds.elevation.e1,
            ),
            child: Row(children: [
              Expanded(child: Text(supplierStr(s, 'label'), style: Ds.t.body)),
              Text(supplierStr(s, 'detail_label'), style: Ds.t.caption),
              SizedBox(width: Ds.space.x12),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                  color: supplierToneSoft(s['tone']),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(supplierStr(s, 'coverage_label'),
                    style: Ds.t.caption.copyWith(color: supplierTone(s['tone']))),
              ),
            ]),
          ),
          SizedBox(height: Ds.space.x8),
        ],
        SizedBox(height: Ds.space.x24),
        Text(supplierStr(payload, 'missing_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x4),
        Text(supplierStr(payload, 'hint_label'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        if (missing.isEmpty)
          Text(supplierStr(payload, 'empty_label'), style: Ds.t.caption)
        else
          for (final m in missing) ...[
            _MissingRow(
              row: m,
              saveLabel: supplierStr(payload, 'save_label'),
              onSave: onSave,
            ),
            SizedBox(height: Ds.space.x12),
          ],
      ],
    );
  }
}

class _MissingRow extends StatefulWidget {
  final Map<String, dynamic> row;
  final String saveLabel;
  final Future<void> Function(String key, String value) onSave;
  const _MissingRow({
    required this.row,
    required this.saveLabel,
    required this.onSave,
  });

  @override
  State<_MissingRow> createState() => _MissingRowState();
}

class _MissingRowState extends State<_MissingRow> {
  final _value = TextEditingController();

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(supplierStr(widget.row, 'english'), style: Ds.t.body),
          SizedBox(height: Ds.space.x4),
          Text(supplierStr(widget.row, 'key'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _value,
                style: Ds.t.body,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: Ds.c.bg,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x8),
                  border: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider),
                  ),
                ),
              ),
            ),
            SizedBox(width: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: () => widget.onSave(
                    supplierStr(widget.row, 'key'), _value.text),
                child: Text(widget.saveLabel),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
