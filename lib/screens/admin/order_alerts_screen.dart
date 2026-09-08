// CHANGE #306 — Admin ▸ More ▸ New-order alerts.
//
// The Om-facing surface over the whole feature: what is waiting right now and
// the Accept / Reject on each one, every threshold and timing behind the ring,
// the credit policy, per-customer limits, and the purchase-gate decisions that
// explain why a line did or did not reach a supplier.
//
// Every string on this screen — the title, each field's label, the state and
// stage chips, the block sentences, the Save caption — arrives from
// order_alert_settings() / customer_credit_list(). This file words nothing and
// computes nothing.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../models/order_alert_fsi.dart';
import '../../services/order_alert_service.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

class OrderAlertsScreen extends StatefulWidget {
  const OrderAlertsScreen({super.key});

  @override
  State<OrderAlertsScreen> createState() => _OrderAlertsScreenState();
}

class _OrderAlertsScreenState extends State<OrderAlertsScreen> {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _credit;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  final _fields = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  SupabaseClient get _db => Supabase.instance.client;

  Map<String, dynamic>? _asMap(Object? raw) {
    final m = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return m is Map ? Map<String, dynamic>.from(m) : null;
  }

  /// CHANGE #307 — Android's own answer about the full-screen-intent grant.
  /// Unknown until the channel replies, and re-read every time the admin
  /// comes back from Settings.
  FsiDeviceState _fsi = FsiDeviceState.unknown;

  FsiCopy get _fsiCopy =>
      FsiCopy(((_data?['fsi'] as Map?) ?? const {}).cast<String, dynamic>());

  Future<void> _readFsi() async {
    final d = await OrderAlertService.instance.fullScreenState();
    if (!mounted) return;
    setState(() => _fsi = d);
    RenderLog.write('c307_fsi', d.known ? (d.granted ? 'granted' : 'denied') : 'unknown');
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = _asMap(await _db.rpc('order_alert_settings'));
      final c = _asMap(await _db.rpc('customer_credit_list'));
      if (!mounted) return;
      for (final f in (s?['fields'] as List? ?? const [])) {
        if (f is! Map) continue;
        final key = f['key'] as String? ?? '';
        final type = f['type'] as String? ?? '';
        if (key.isEmpty || type == 'bool') continue;
        (_fields[key] ??= TextEditingController()).text = '${f['value'] ?? ''}';
      }
      setState(() {
        _data = s;
        _credit = c;
        _loading = false;
      });
      RenderLog.write('c306_alert_screen', '${(s?['open'] as List?)?.length ?? 0}');
      await _readFsi();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _save(Map<String, dynamic> patch) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = _asMap(await _db.rpc('order_alert_settings_set', params: {'p_patch': patch}));
      if (!mounted) return;
      setState(() {
        _data = res ?? _data;
        _busy = false;
      });
      showToast(context, (res?['saved_label'] as String?) ?? '');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, '$e', isError: true);
    }
  }

  Future<void> _act(Map<String, dynamic> item, String action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final res = await OrderAlertService.instance
        .act('${item['order_id']}', action);
    final alertId = (item['alert_id'] as num?)?.toInt();
    if (alertId != null) {
      await OrderAlertService.instance.clearNotification(alertId);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = (res['message'] as String?) ?? '';
    if (msg.isNotEmpty) {
      showToast(context, msg, isError: res['ok'] != true);
    }
    await _load();
  }

  Future<void> _override(Map<String, dynamic> item) async {
    final ctrl = TextEditingController();
    final overrideLabel = (_data?['override_label'] as String?) ?? '';
    final overrideHint = (_data?['override_hint'] as String?) ?? '';
    final reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(overrideLabel, style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(overrideHint, style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          TextField(controller: ctrl, minLines: 2, maxLines: 4),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: Text(overrideLabel),
            ),
          ),
        ]),
      ),
    );
    if (reason == null || !mounted) return;
    try {
      final res = _asMap(await _db.rpc('purchase_override_grant',
          params: {'p_order_id': item['order_id'], 'p_reason': reason}));
      if (!mounted) return;
      showToast(context, (res?['message'] as String?) ?? '', isError: res?['ok'] != true);
      await _load();
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(d?['title'] as String? ?? '', style: Ds.t.subtitle),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const _Skeleton()
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      if ((d?['subtitle'] as String? ?? '').isNotEmpty) ...[
                        Text(d!['subtitle'] as String, style: Ds.t.bodySecondary),
                        SizedBox(height: Ds.space.x24),
                      ],
                      if ((d?['phone_warning'] as String? ?? '').isNotEmpty) ...[
                        _Note(text: d!['phone_warning'] as String, tone: Ds.c.warning),
                        SizedBox(height: Ds.space.x24),
                      ],
                      _section(_sectionLabel('open')),
                      ..._openCards(),
                      SizedBox(height: Ds.space.x32),
                      _section(_sectionLabel('timings')),
                      ..._fieldRows(const ['enabled', 'ring_delay_s', 'rering_after_s',
                        'wa_after_s', 'critical_after_s', 'ring_seconds',
                        'autocancel_after_min', 'admin_wa_phone']),
                      ..._groupSections(),
                      SizedBox(height: Ds.space.x32),
                      _section('${(_cutoff['title'] ?? '')}'),
                      ..._cutoffRows(),
                      SizedBox(height: Ds.space.x32),
                      _section(_sectionLabel('credit')),
                      ..._fieldRows(const ['new_customer_prepaid_only',
                        'established_credit_limit', 'established_min_paid_orders',
                        'enforce_credit_block', 'purchase_gate_enabled']),
                      SizedBox(height: Ds.space.x16),
                      ..._creditRows(),
                      SizedBox(height: Ds.space.x32),
                      _section(_sectionLabel('device')),
                      ..._fsiRows(),
                      SizedBox(height: Ds.space.x32),
                      _section(_sectionLabel('log')),
                      ..._logRows(),
                      SizedBox(height: Ds.space.x48),
                    ],
                  ),
                ),
    );
  }

  String _sectionLabel(String key) =>
      ((_data?['sections'] as Map?)?[key] as String?) ?? '';

  Widget _section(String label) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Text(label, style: Ds.t.title),
      );

  List<Widget> _openCards() {
    final open = (_data?['open'] as List?) ?? const [];
    if (open.isEmpty) {
      return [
        _EmptyState(
          title: _data?['empty_title'] as String? ?? '',
          body: _data?['empty_body'] as String? ?? '',
        ),
      ];
    }
    return open.whereType<Map>().map((raw) {
      final item = Map<String, dynamic>.from(raw);
      return Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: OrderAlertCard(
          item: item,
          busy: _busy,
          onAccept: () => _act(item, 'accept'),
          onReject: () => _act(item, 'reject'),
          onOverride: () => _override(item),
        ),
      );
    }).toList();
  }

  /// CHANGE #307 — whether lock-screen alerts are actually live on THIS
  /// device, in the backend's own words, with the one button that can change
  /// it. The card decides nothing: FsiCopy picks which sentences to print.
  List<Widget> _fsiRows() {
    final copy = _fsiCopy;
    final card = copy.card(_fsi);
    if (card.title.isEmpty && card.body.isEmpty) return const [];

    final tone = switch (card.tone) {
      FsiTone.granted => Ds.c.success,
      FsiTone.denied => Ds.c.warning,
      _ => Ds.c.info,
    };

    return [
      Container(
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: Ds.space.x8,
                  height: Ds.space.x8,
                  margin: EdgeInsets.only(top: Ds.space.x8, right: Ds.space.x12),
                  decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
                ),
                Expanded(child: Text(card.title, style: Ds.t.bodyStrong)),
              ],
            ),
            if (card.body.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(card.body, style: Ds.t.bodySecondary),
            ],
            if (card.note.isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              _Note(text: card.note, tone: tone),
            ],
            if (card.hasAction) ...[
              SizedBox(height: Ds.space.x16),
              Row(children: [
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      onPressed: _busy ? null : _openFsiSettings,
                      child: Text(card.actionLabel),
                    ),
                  ),
                ),
                if (card.recheckLabel.isNotEmpty) ...[
                  SizedBox(width: Ds.space.x8),
                  SizedBox(
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _readFsi,
                      child: Text(card.recheckLabel),
                    ),
                  ),
                ],
              ]),
            ],
          ],
        ),
      ),
    ];
  }

  /// Sends the admin to Android's own screen, then re-reads the grant when
  /// they come back — the answer is the device's, never remembered here.
  Future<void> _openFsiSettings() async {
    await OrderAlertService.instance.openFullScreenSettings();
    await _readFsi();
  }

  /// The point-of-use ask. A sheet, not a dialog, and only when the grant is
  /// both askable and missing — every word from order_alert_fsi().
  Future<void> _maybePromptFsi() async {
    await _readFsi();
    final copy = _fsiCopy;
    if (!copy.shouldPrompt(_fsi)) return;
    if (!mounted) return;
    final p = copy.prompt;
    if (p.title.isEmpty && p.body.isEmpty) return;

    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.title, style: Ds.t.title),
              SizedBox(height: Ds.space.x12),
              Text(p.body, style: Ds.t.bodySecondary),
              SizedBox(height: Ds.space.x24),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(p.ctaLabel),
                ),
              ),
              SizedBox(height: Ds.space.x8),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(p.skipLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (go == true) await _openFsiSettings();
  }

  List<Widget> _fieldRows(List<String> keys) {
    final fields = (_data?['fields'] as List?) ?? const [];
    final byKey = <String, Map<String, dynamic>>{};
    for (final f in fields) {
      if (f is Map) byKey['${f['key']}'] = Map<String, dynamic>.from(f);
    }
    final out = <Widget>[];
    for (final k in keys) {
      final f = byKey[k];
      if (f == null) continue;
      final label = f['label'] as String? ?? '';
      if ((f['type'] as String? ?? '') == 'bool') {
        out.add(SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: Ds.t.body),
          value: f['value'] == true,
          // CHANGE #307 — the ask lands at the point it matters: the moment
          // alerts are switched ON, and only where the grant is missing.
          onChanged: _busy
              ? null
              : (v) async {
                  await _save({k: v});
                  if (k == 'enabled' && v == true) await _maybePromptFsi();
                },
        ));
      } else {
        final ctrl = _fields[k] ??= TextEditingController(text: '${f['value'] ?? ''}');
        out.add(Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                minLines: f['multiline'] == true ? 2 : 1,
                maxLines: f['multiline'] == true ? 5 : 1,
                keyboardType: (f['type'] == 'int' || f['type'] == 'money')
                    ? TextInputType.number
                    : TextInputType.text,
                decoration: InputDecoration(
                  labelText: label,
                  helperText: f['hint'] as String?,
                ),
              ),
            ),
            SizedBox(width: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: _busy ? null : () => _save({k: ctrl.text.trim()}),
                child: Text(_data?['saved_label'] as String? ?? ''),
              ),
            ),
          ]),
        ));
      }
    }
    return out;
  }

  /// CMD #1847 — the sections the BACKEND declares. A new knob is a row in
  /// order_alert_settings().groups; this screen never learns its name.
  List<Widget> _groupSections() {
    final groups = (_data?['groups'] as List?) ?? const [];
    final out = <Widget>[];
    for (final g in groups) {
      if (g is! Map) continue;
      final keys = ((g['fields'] as List?) ?? const [])
          .map((e) => '$e')
          .toList(growable: false);
      final rows = _fieldRows(keys);
      if (rows.isEmpty) continue;
      out.add(SizedBox(height: Ds.space.x32));
      out.add(_section('${g['label'] ?? ''}'));
      out.addAll(rows);
    }
    return out;
  }

  /// CMD #1847 — the orders on the cut-off clock. Every word, every rupee, the
  /// countdown and which buttons exist are order_cutoff_console()'s.
  Map<String, dynamic> get _cutoff =>
      ((_data?['cutoff'] as Map?) ?? const {}).cast<String, dynamic>();

  List<Widget> _cutoffRows() {
    final items = (_cutoff['items'] as List?) ?? const [];
    if (items.isEmpty) {
      return [
        _EmptyState(
          title: '${_cutoff['cutoff_label'] ?? ''}',
          body: '${_cutoff['empty_label'] ?? ''}',
        ),
      ];
    }
    final out = <Widget>[];
    if ('${_cutoff['window_note'] ?? ''}'.isNotEmpty && _cutoff['window_open'] == true) {
      out.add(Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: _Note(text: '${_cutoff['window_note']}', tone: Ds.c.warning),
      ));
    }
    for (final raw in items.whereType<Map>()) {
      final m = Map<String, dynamic>.from(raw);
      out.add(CutoffClockCard(
        item: m,
        busy: _busy,
        onAction: (action, minutes) => _cutoffAct(m, action, minutes),
      ));
    }
    return out;
  }

  Future<void> _cutoffAct(Map<String, dynamic> m, String action, int? minutes) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = _asMap(await _db.rpc('order_cutoff_action', params: {
        'p_order_id': m['order_id'],
        'p_action': action,
        'p_minutes': ?minutes,
      }));
      if (!mounted) return;
      setState(() => _busy = false);
      final msg = (res?['message'] as String?) ?? '';
      if (msg.isNotEmpty) showToast(context, msg, isError: res?['ok'] != true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, '$e', isError: true);
    }
  }

  List<Widget> _creditRows() {
    final items = (_credit?['items'] as List?) ?? const [];
    return items.whereType<Map>().take(12).map((raw) {
      final m = Map<String, dynamic>.from(raw);
      final blocked = m['blocked'] == true;
      return Container(
        margin: EdgeInsets.only(bottom: Ds.space.x8),
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: blocked ? Ds.c.danger : Ds.c.divider),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${m['customer_name'] ?? ''}', style: Ds.t.bodyStrong),
              SizedBox(height: Ds.space.x4),
              Text('${m['outstanding_display'] ?? ''} / ${m['limit_display'] ?? ''}',
                  style: Ds.t.caption),
            ]),
          ),
          IconButton(
            tooltip: '${m['message'] ?? ''}',
            onPressed: _busy ? null : () => _editCredit(m),
            icon: const Icon(Icons.tune),
          ),
        ]),
      );
    }).toList();
  }

  Future<void> _editCredit(Map<String, dynamic> m) async {
    final ctrl = TextEditingController(text: '${m['limit'] ?? 0}');
    bool prepaid = m['prepaid_only'] == true;
    bool never = m['never_auto_cancel'] == true;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: Ds.space.x16,
            right: Ds.space.x16,
            top: Ds.space.x24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${m['customer_name'] ?? ''}', style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x8),
            Text('${m['message'] ?? ''}', style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: (_data?['credit_limit_label'] as String?) ?? '',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: prepaid,
              title: Text((_data?['credit_prepaid_label'] as String?) ?? '',
                  style: Ds.t.body),
              onChanged: (v) => setSheet(() => prepaid = v),
            ),
            // CMD #1847 — this pharmacy is never auto-cancelled at the cut-off.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: never,
              title: Text((_data?['credit_never_label'] as String?) ?? '',
                  style: Ds.t.body),
              onChanged: (v) => setSheet(() => never = v),
            ),
            SizedBox(height: Ds.space.x8),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(_data?['saved_label'] as String? ?? ''),
              ),
            ),
          ]),
        ),
      ),
    );
    if (saved != true || !mounted) return;
    try {
      await _db.rpc('customer_credit_set', params: {
        'p_customer_id': m['customer_id'],
        'p_limit': num.tryParse(ctrl.text.trim()) ?? 0,
        'p_prepaid_only': prepaid,
        'p_never_auto_cancel': never,
      });
      await _load();
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    }
  }

  List<Widget> _logRows() {
    final log = (_data?['log'] as List?) ?? const [];
    if (log.isEmpty) return const [];
    return log.whereType<Map>().map((raw) {
      final m = Map<String, dynamic>.from(raw);
      final allowed = m['allowed'] == true;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(allowed ? Icons.check_circle_outline : Icons.block,
            color: allowed ? Ds.c.success : Ds.c.danger),
        title: Text('${m['order_code'] ?? ''}  ${m['supplier'] ?? ''}', style: Ds.t.body),
        subtitle: Text('${m['reason_label'] ?? m['reason'] ?? ''}', style: Ds.t.caption),
        trailing: Text('${m['when_label'] ?? ''}', style: Ds.t.caption),
      );
    }).toList();
  }
}

/// One alert, drawn from its payload. Shared by this screen and the popup, so
/// the two can never say different things about the same order.
class OrderAlertCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool busy;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;
  final VoidCallback? onOverride;
  final VoidCallback? onDismiss;

  const OrderAlertCard({
    super.key,
    required this.item,
    this.busy = false,
    this.onAccept,
    this.onReject,
    this.onOverride,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final blocked = item['credit_blocked'] == true;
    final critical = item['critical'] == true;
    final canAccept = item['can_accept'] == true;
    final note = (item['credit_note'] as String?) ?? '';

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
        border: Border.all(color: critical ? Ds.c.danger : Ds.c.divider),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x8),
          decoration: BoxDecoration(
            color: item['paid'] == true
                ? Ds.c.successSoft
                : critical
                    ? Ds.c.dangerSoft
                    : Ds.c.warningSoft,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(Ds.r.card),
              topRight: Radius.circular(Ds.r.card),
            ),
          ),
          child: Text('${item['banner'] ?? ''}', style: Ds.t.caption),
        ),
        Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${item['customer'] ?? ''}', style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Row(children: [
              Expanded(
                child: Text('${item['order_code'] ?? ''}', style: Ds.t.caption),
              ),
              Text('${item['amount_display'] ?? ''}', style: Ds.t.bodyStrong),
            ]),
            SizedBox(height: Ds.space.x8),
            Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x4, children: [
              _Chip(text: '${item['risk_label'] ?? ''}'),
              _Chip(text: '${item['stage_label'] ?? ''}'),
              _Chip(text: '${item['age_label'] ?? ''}'),
            ]),
            if (note.isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              _Note(text: note, tone: Ds.c.danger),
            ],
            SizedBox(height: Ds.space.x12),
            Text('${item['accept_note'] ?? ''}', style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            Row(children: [
              if (onDismiss != null) ...[
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      onPressed: busy ? null : onDismiss,
                      child: Text('${item['dismiss_label'] ?? ''}'),
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
              ],
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: busy || item['can_reject'] != true ? null : onReject,
                    style: OutlinedButton.styleFrom(foregroundColor: Ds.c.danger),
                    child: Text('${item['reject_label'] ?? ''}'),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: busy || !canAccept ? null : onAccept,
                    child: Text('${item['accept_label'] ?? ''}'),
                  ),
                ),
              ),
            ]),
            if (blocked && onOverride != null) ...[
              SizedBox(height: Ds.space.x8),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: TextButton(
                  onPressed: busy ? null : onOverride,
                  child: Text('${item['override_label'] ?? ''}'),
                ),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  const _Chip({required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rChip),
      child: Text(text, style: Ds.t.caption),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final Color tone;
  const _Note({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Color.alphaBlend(tone.withValues(alpha: 0.10), Ds.c.surface),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(text, style: Ds.t.caption),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String title;
  final String body;
  const _EmptyState({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
      child: Column(children: [
        Text(title, style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x8),
        Text(body, style: Ds.t.caption, textAlign: TextAlign.center),
      ]),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: List.generate(
        4,
        (_) => Container(
          height: Ds.touch.listRowMinHeight * 2,
          margin: EdgeInsets.only(bottom: Ds.space.x12),
          decoration: BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(message, style: Ds.t.caption, textAlign: TextAlign.center),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton(onPressed: onRetry, child: const Icon(Icons.refresh)),
          ),
        ]),
      ),
    );
  }
}

/// CMD #1847 — one order on the cut-off clock.
///
/// It decides nothing. The state word and its tone, the countdown, the
/// restoration window's own countdown, every rupee and the label on every
/// button are strings in order_cutoff_console()'s payload; a button exists
/// only because the backend sent its `can_*` flag. Once the restoration
/// window shuts the backend stops sending can_restore and the button is gone
/// — the screen never compares a clock of its own.
class CutoffClockCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool busy;
  final void Function(String action, int? minutes) onAction;

  const CutoffClockCard({
    required this.item,
    required this.busy,
    required this.onAction,
  });

  static Color _tone(String tone) {
    switch (tone) {
      case 'danger':
        return Ds.c.dangerSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'success':
        return Ds.c.successSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.bg;
    }
  }

  String _s(String key) => '${item[key] ?? ''}';

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[];
    void add(String flag, String labelKey, String action, {int? minutes}) {
      if (item[flag] != true) return;
      final label = _s(labelKey);
      if (label.isEmpty) return;
      actions.add(SizedBox(
        height: Ds.touch.minTarget,
        child: OutlinedButton(
          onPressed: busy ? null : () => onAction(action, minutes),
          child: Text(label),
        ),
      ));
    }

    add('can_restore', 'restore_label', 'restore');
    add('can_extend_window', 'extend_window_label', 'extend_window');
    add('can_extend', 'extend_label', 'extend');
    add('can_cancel_now', 'cancel_now_label', 'cancel_now');
    add('can_exempt', 'exempt_label', 'exempt');
    add('can_unexempt', 'unexempt_label', 'unexempt');

    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_s('order_code'), style: Ds.t.bodyStrong),
              if (_s('customer').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(_s('customer'), style: Ds.t.caption),
              ],
            ]),
          ),
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x8, vertical: Ds.space.x4),
            decoration: BoxDecoration(
              color: _tone(_s('state_tone')),
              borderRadius: Ds.r.rChip,
            ),
            child: Text(_s('state_label'), style: Ds.t.caption),
          ),
        ]),
        SizedBox(height: Ds.space.x12),
        Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
          _Chip(text: _s('cutoff_label')),
          _Chip(text: _s('countdown')),
          _Chip(text: _s('extended_label')),
          _Chip(text: _s('window_label')),
          _Chip(text: _s('due_label')),
        ]),
        if (actions.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: actions),
        ],
      ]),
    );
  }
}
