// lib/screens/admin/admin_delivery_ops_screen.dart — CHANGE #309
//
// The operations half of the delivery module: rider payouts, doorstep claims,
// pincode serviceability, rider document expiry, and customer ratings.
//
// WHY ONE SCREEN AND NOT FIVE. Each of these is a short list an admin checks
// once or twice a day, on a phone, usually standing up. Five separate screens
// would be five navigations and five loading states for what is one question —
// "is anything wrong with delivery today". admin_delivery_ops() answers it in a
// single payload, so this screen has ONE fetch, ONE error state and ONE retry.
//
// THIS FILE DECIDES NOTHING. Every heading, empty state, chip word, button
// label, colour pair and money string arrives in the payload and is printed
// verbatim. The sections are rendered in the order the BACKEND lists them, and
// a section whose key this file does not recognise is skipped in silence — so
// a sixth section can be added server-side without touching this file, and an
// older app never crashes on a newer payload.
//
// The only thing computed here is layout.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

class AdminDeliveryOpsScreen extends StatefulWidget {
  const AdminDeliveryOpsScreen({super.key});

  @override
  State<AdminDeliveryOpsScreen> createState() => _AdminDeliveryOpsScreenState();
}

class _AdminDeliveryOpsScreenState extends State<AdminDeliveryOpsScreen> {
  Map<String, dynamic> _data = const {};
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final res = await Supabase.instance.client.rpc('admin_delivery_ops');
      if (!mounted) return;
      setState(() {
        _data = res is Map ? Map<String, dynamic>.from(res) : const {};
        _loading = false;
      });
      RenderLog.write('c309_ops_screen', _sections.length);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  List<Map<String, dynamic>> get _sections {
    final raw = _data['sections'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  List<Map<String, dynamic>> _rows(Map<String, dynamic> section) {
    final raw = section['rows'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<void> _rpc(String fn, Map<String, dynamic> params) async {
    try {
      final res = await Supabase.instance.client.rpc(fn, params: params);
      if (!mounted) return;
      // The message is the backend's, including its refusals — "already paid"
      // is a sentence the server wrote, not one composed here.
      final msg = res is Map ? (res['message']?.toString() ?? '') : '';
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
      await _load();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_data['allowed'] == false) return const SizedBox.shrink();

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_data['title']?.toString() ?? '', style: Ds.t.title),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? _skeleton()
            : _failed
                ? _error()
                : ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      if ((_data['subtitle']?.toString() ?? '').isNotEmpty) ...[
                        Text(_data['subtitle']!.toString(), style: Ds.t.caption),
                        SizedBox(height: Ds.space.x24),
                      ],
                      for (final s in _sections) ...[
                        _section(s),
                        SizedBox(height: Ds.space.x24),
                      ],
                    ],
                  ),
      ),
    );
  }

  // A skeleton, not a bare spinner: the shape of the answer is known before it
  // arrives, so the screen does not jump when it lands.
  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 4; i++)
            Container(
              height: 96,
              margin: EdgeInsets.only(bottom: Ds.space.x16),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
              ),
            ),
        ],
      );

  Widget _error() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_data['error_label']?.toString() ?? '',
                style: Ds.t.body, textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x16),
            OutlinedButton(
              onPressed: _load,
              child: Text(_data['retry_label']?.toString() ?? ''),
            ),
          ]),
        ),
      );

  Widget _section(Map<String, dynamic> s) {
    final key = s['key']?.toString() ?? '';
    final rows = _rows(s);

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(s['title']?.toString() ?? '', style: Ds.t.subtitle)),
          if (key == 'payouts' && (s['add_label']?.toString() ?? '').isNotEmpty)
            TextButton(
              onPressed: _openPayoutPeriod,
              child: Text(s['add_label']!.toString()),
            ),
          if (key == 'service' && (s['add_label']?.toString() ?? '').isNotEmpty)
            TextButton(
              onPressed: _addPincode,
              child: Text(s['add_label']!.toString()),
            ),
        ]),
        SizedBox(height: Ds.space.x8),
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x16),
            child: Text(s['empty']?.toString() ?? '', style: Ds.t.caption),
          )
        else
          for (final r in rows) ...[
            // An unknown section key renders nothing rather than throwing:
            // forward compatibility with a payload this build predates.
            switch (key) {
              'payouts' => _payoutRow(r),
              'claims' => _claimRow(r),
              'service' => _serviceRow(r),
              'docs' => _docRow(r),
              'ratings' => _ratingRow(r),
              _ => const SizedBox.shrink(),
            },
            Divider(height: Ds.space.x24, color: Ds.c.divider),
          ],
      ]),
    );
  }

  Widget _chip(String text, Map<String, dynamic> colors) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: 4),
      decoration: BoxDecoration(
        color: _hex(colors['bg']?.toString()) ?? Ds.c.infoSoft,
        borderRadius: Ds.r.rChip,
      ),
      child: Text(text,
          style: Ds.t.caption.copyWith(
            fontWeight: FontWeight.w500,
            color: _hex(colors['fg']?.toString()) ?? Ds.c.info,
          )),
    );
  }

  static Color? _hex(String? h) {
    final v = (h ?? '').trim().replaceFirst('#', '');
    if (v.length != 6) return null;
    final n = int.tryParse('FF$v', radix: 16);
    return n == null ? null : Color(n);
  }

  Map<String, dynamic> _colors(Map<String, dynamic> r, String key) =>
      r[key] is Map ? Map<String, dynamic>.from(r[key] as Map) : const {};

  // ── (4) payouts ───────────────────────────────────────────────────────────
  Widget _payoutRow(Map<String, dynamic> r) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r['partner_name']?.toString() ?? '', style: Ds.t.body),
            Text(
              '${r['period_label'] ?? ''} · ${r['drop_count_label'] ?? ''}',
              style: Ds.t.caption,
            ),
          ]),
        ),
        SizedBox(width: Ds.space.x8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          // Money right-aligned, and it is the backend's own ₹ string.
          Text(r['amount_label']?.toString() ?? '',
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
          SizedBox(height: 4),
          _chip(r['status_chip']?.toString() ?? '', _colors(r, 'status_colors')),
        ]),
        if (r['can_pay'] == true) ...[
          SizedBox(width: Ds.space.x8),
          SizedBox(
            height: 44,
            child: TextButton(
              onPressed: () => _markPaid(r),
              child: Text(r['pay_label']?.toString() ?? ''),
            ),
          ),
        ],
      ]);

  String? _sectionValue(String key, String field) {
    for (final s in _sections) {
      if (s['key'] == key) return s[field]?.toString();
    }
    return null;
  }

  Future<void> _markPaid(Map<String, dynamic> r) async {
    final ctrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16, Ds.space.x16,
            Ds.space.x16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r['partner_name']?.toString() ?? '', style: Ds.t.subtitle),
          Text(r['amount_label']?.toString() ?? '', style: Ds.t.body),
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: 'UTR'),
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(r['pay_label']?.toString() ?? ''),
            ),
          ),
        ]),
      ),
    );
    if (ok != true) return;
    await _rpc('admin_payout_pay', {
      'p_period_id': r['period_id']?.toString(),
      'p_ref': ctrl.text.trim().isEmpty ? null : ctrl.text.trim(),
    });
  }

  Future<void> _openPayoutPeriod() async {
    final partners = (_data['partners'] is List)
        ? (_data['partners'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : <Map<String, dynamic>>[];
    if (partners.isEmpty) return;

    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          for (final p in partners)
            ListTile(
              title: Text(p['name']?.toString() ?? '', style: Ds.t.body),
              onTap: () => Navigator.of(ctx).pop(p),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    await _rpc('admin_payout_open', {'p_partner_id': picked['partner_id']?.toString()});
  }

  // ── (8) claims ────────────────────────────────────────────────────────────
  Widget _claimRow(Map<String, dynamic> r) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${r['order_code'] ?? ''} · ${r['pharmacy'] ?? ''}', style: Ds.t.body),
                Text(
                  '${r['kind_label'] ?? ''} × ${r['qty_label'] ?? ''} · ${r['raised_label'] ?? ''}',
                  style: Ds.t.caption,
                ),
              ]),
            ),
            Text(r['amount_label']?.toString() ?? '',
                style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
          ]),
          if ((r['note']?.toString() ?? '').isNotEmpty)
            Text(r['note']!.toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          Row(children: [
            SizedBox(
              height: 44,
              child: TextButton(
                onPressed: () => _rpc('admin_claim_decide',
                    {'p_claim_id': r['claim_id']?.toString(), 'p_action': 'approve'}),
                child: Text(r['approve_label']?.toString() ?? ''),
              ),
            ),
            SizedBox(width: Ds.space.x8),
            SizedBox(
              height: 44,
              child: TextButton(
                style: TextButton.styleFrom(foregroundColor: Ds.c.danger),
                onPressed: () => _rpc('admin_claim_decide',
                    {'p_claim_id': r['claim_id']?.toString(), 'p_action': 'reject'}),
                child: Text(r['reject_label']?.toString() ?? ''),
              ),
            ),
          ]),
        ],
      );

  // ── (5) serviceability ────────────────────────────────────────────────────
  Widget _serviceRow(Map<String, dynamic> r) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r['pincode']?.toString() ?? '', style: Ds.t.body),
            if ((r['note']?.toString() ?? '').isNotEmpty)
              Text(r['note']!.toString(), style: Ds.t.caption),
          ]),
        ),
        _chip(r['mode_label']?.toString() ?? '', _colors(r, 'mode_colors')),
      ]);

  Future<void> _addPincode() async {
    final pin = TextEditingController();
    String mode = 'serviceable';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16, Ds.space.x16,
              Ds.space.x16 + MediaQuery.of(ctx).viewInsets.bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_sectionValue('service', 'title') ?? '', style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: pin,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'PIN'),
            ),
            SizedBox(height: Ds.space.x16),
            // The three modes are the backend's own enum values.
            Wrap(spacing: Ds.space.x8, children: [
              for (final m in const ['serviceable', 'warn', 'blocked'])
                ChoiceChip(
                  label: Text(m),
                  selected: mode == m,
                  onSelected: (_) => setSheet(() => mode = m),
                ),
            ]),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(_sectionValue('service', 'add_label') ?? ''),
              ),
            ),
          ]),
        ),
      ),
    );
    if (ok != true || pin.text.trim().isEmpty) return;
    await _rpc('admin_serviceability_set',
        {'p_pincode': pin.text.trim(), 'p_mode': mode});
  }

  // ── (6) documents ─────────────────────────────────────────────────────────
  Widget _docRow(Map<String, dynamic> r) {
    final docs = (r['docs'] is List)
        ? (r['docs'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(r['partner_name']?.toString() ?? '', style: Ds.t.body),
      if ((r['block_message']?.toString() ?? '').isNotEmpty)
        Text(r['block_message']!.toString(),
            style: Ds.t.caption.copyWith(color: Ds.c.danger)),
      if ((r['remind_message']?.toString() ?? '').isNotEmpty)
        Text(r['remind_message']!.toString(), style: Ds.t.caption),
      SizedBox(height: Ds.space.x8),
      Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
        for (final d in docs)
          if ((d['chip']?.toString() ?? '').isNotEmpty)
            _chip('${d['label']} · ${d['chip']}', _colors(d, 'chip_colors')),
      ]),
    ]);
  }

  // ── (7) ratings ───────────────────────────────────────────────────────────
  Widget _ratingRow(Map<String, dynamic> r) => Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${r['stars_label'] ?? ''}  ${r['partner_name'] ?? ''}',
                style: Ds.t.body.copyWith(
                    color: r['is_poor'] == true ? Ds.c.danger : Ds.c.text)),
            if ((r['comment']?.toString() ?? '').isNotEmpty)
              Text(r['comment']!.toString(), style: Ds.t.caption),
          ]),
        ),
        Text(r['when_label']?.toString() ?? '', style: Ds.t.caption),
      ]);
}
