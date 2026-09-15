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
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../services/partner_state.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'partner_scorecard_card.dart';
import 'settlement_ack_card.dart';
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

  // CMD #466 row 150 — the statement DOCUMENT. The screen holds nothing but
  // "am I waiting"; the kind, the ref, every label, the poll interval and the
  // bucket + path all arrive from the backend.
  bool _docBusy = false;

  // CHANGE #693 — the partner's own scorecard, on the screen the partner
  // already opens to see what it is owed. The card is the SAME widget the
  // admin ranking draws, so the score a partner reads and the score it is
  // ranked on are one payload. An empty map (a build that predates the RPC,
  // or a login with no partner) renders nothing at all.
  Map<String, dynamic> _scorecard = const <String, dynamic>{};

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
    Map<String, dynamic> sc;
    try {
      sc = _asMap(await _rpc('partner_scorecard', const {}));
    } catch (_) {
      sc = const <String, dynamic>{};
    }
    if (!mounted) return;
    setState(() {
      _payload = p;
      _scorecard = sc['ok'] == true ? sc : const <String, dynamic>{};
      _loading = false;
    });
    RenderLog.write('c323_partner_statement', 'painted');
    RenderLog.write('c693_partner_scorecard',
        _scorecard.isEmpty ? 'absent' : 'painted');
    RenderLog.write('c323_partner_periods',
        '${((_asMap(p['periods'])['rows']) as List?)?.length ?? 0}');
  }

  /// Records the acknowledgement and reloads: the CARD's next state comes from
  /// the server, never from what we just sent.
  Future<void> _ack(String state, String note) async {
    final id = _periodId ?? _asMap(_asMap(_payload?['statement']))['period_id'];
    if (id == null) return;
    try {
      final r = _asMap(await _rpc('settlement_ack_set', {
        'p_period_id': id,
        'p_state': state,
        'p_note': note.isEmpty ? null : note,
      }));
      if (!mounted) return;
      final msg = (r['message'] ?? '').toString();
      if (msg.isNotEmpty) {
        showToast(context, msg, isError: r['ok'] != true);
      }
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
    await _load();
  }

  /// Ask for the statement, then poll on the backend's OWN `poll_ms` until it
  /// says ready, and open the file at the bucket and path IT named. The screen
  /// never builds a storage URL and never invents a timeout of its own.
  Future<void> _openDocument(Map<String, dynamic> doc) async {
    if (_docBusy) return;
    setState(() => _docBusy = true);
    try {
      var res = _asMap(await _rpc('partner_doc_request', {
        'p_kind': (doc['kind'] ?? '').toString(),
        'p_ref': (doc['ref'] ?? '').toString(),
      }));
      var guard = 0;
      while (res['ok'] == true &&
          res['status'] == 'building' &&
          guard < 40 &&
          mounted) {
        guard++;
        final ms = int.tryParse('${res['poll_ms'] ?? 1500}') ?? 1500;
        await Future<void>.delayed(Duration(milliseconds: ms));
        res = _asMap(await _rpc('partner_doc_status', {'p_id': res['doc_id']}));
      }
      if (!mounted) return;
      final msg = (res['message'] ?? '').toString();
      if (res['ok'] != true || res['status'] != 'ready') {
        if (msg.isNotEmpty) showToast(context, msg, isError: true);
        return;
      }
      final url = await Supabase.instance.client.storage
          .from((res['bucket'] ?? '').toString())
          .createSignedUrl((res['path'] ?? '').toString(),
              int.tryParse('${res['expires_s'] ?? 300}') ?? 300);
      if (!mounted) return;
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (mounted && msg.isNotEmpty) showToast(context, msg);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _docBusy = false);
    }
  }

  /// The GST treatment of the commission, printed exactly as the backend wrote
  /// it. There is no Dart arithmetic and no Dart wording here — a change of
  /// rate or of the note is an UPDATE, not a deploy.
  Widget _gstCard(Map<String, dynamic> gst) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text((gst['heading'] ?? '').toString(), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          if (gst['registered'] == true) ...[
            for (final r in (gst['lines'] as List?) ?? const [])
              _gstRow(((r as Map)['label'] ?? '').toString(),
                  (r['value'] ?? '').toString(),
                  bold: r['bold'] == true),
            SizedBox(height: Ds.space.x12),
          ],
          Text((gst['note'] ?? '').toString(), style: Ds.t.caption),
        ],
      ),
    );
  }

  Widget _gstRow(String label, String value, {bool bold = false}) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x8),
        child: Row(
          children: [
            Expanded(child: Text(label, style: Ds.t.bodySecondary)),
            Text(value, style: bold ? Ds.t.subtitle : Ds.t.body),
          ],
        ),
      );

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
          if (_scorecard.isNotEmpty) ...[
            PartnerScorecardCard(payload: _scorecard),
            SizedBox(height: Ds.space.x24),
          ],
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
            // CHANGE #400 — Agree / Dispute, above the numbers it is about.
            SettlementAckCard(
              ack: _asMap(statement['ack']),
              onAgree: (n) => _ack('agreed', n),
              onDispute: (n) => _ack('disputed', n),
            ),
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
          if (_asMap(p?['document'])['has'] == true) ...[
            SizedBox(height: Ds.space.x24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                onPressed: _docBusy
                    ? null
                    : () => _openDocument(_asMap(p?['document'])),
                child: Text(_docBusy
                    ? (_asMap(p?['document'])['building_message'] ?? '')
                        .toString()
                    : (_asMap(p?['document'])['button_label'] ?? '').toString()),
              ),
            ),
          ],
          if (_asMap(p?['gst']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            _gstCard(_asMap(p?['gst'])),
          ],
          SizedBox(height: Ds.space.x24),
          Text((p?['footnote'] ?? '').toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x32),
        ],
      ),
    );
  }
}
