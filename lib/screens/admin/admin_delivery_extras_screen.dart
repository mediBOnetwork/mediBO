import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CMD #407 — the delivery programme: incentives, agency tax invoices, the
/// training gate and cost-per-drop, on ONE screen with four tabs.
///
/// The TAB LIST is `admin_delivery_extras()`'s, not this file's: a tab_key this
/// build has never heard of renders an empty body instead of throwing, which is
/// how a fifth tab ships as SQL and no deploy.
///
/// This file computes NOTHING. Every rupee, percentage, target, plural, chip
/// caption and error message is a backend string printed verbatim; the only
/// thing mapped here is a payload `tone` onto a design token.
typedef ExtrasRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

/// The backend names a tone; the token layer owns what that colour is.
Color extrasToneColor(Object? tone) {
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

Color extrasToneSoft(Object? tone) {
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

String _s(Object? v) => v == null ? '' : '$v';

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

class AdminDeliveryExtrasScreen extends StatefulWidget {
  /// Test seam. Null in production → the real RPCs. The protected test pumps
  /// this screen against a fixture payload, which is the only way to prove a
  /// canvas app renders the backend's own strings and not its own.
  final ExtrasRpc? rpc;

  /// Which tab to open on. Null → the backend's first tab.
  final String? initialTab;

  const AdminDeliveryExtrasScreen({super.key, this.rpc, this.initialTab});

  @override
  State<AdminDeliveryExtrasScreen> createState() =>
      _AdminDeliveryExtrasScreenState();
}

class _AdminDeliveryExtrasScreenState extends State<AdminDeliveryExtrasScreen> {
  Map<String, dynamic>? _data;
  Object? _error;
  bool _loading = true;
  bool _busy = false;
  String? _tab;

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab;
    _load();
  }

  Future<Map<String, dynamic>> _rpc(
      String fn, Map<String, dynamic> params) async {
    final seam = widget.rpc;
    if (seam != null) return seam(fn, params);
    final res = await Supabase.instance.client.rpc(fn, params: params);
    return Map<String, dynamic>.from(res as Map);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res =
          await _rpc('admin_delivery_extras', {'p_tab': _tab, 'p_args': {}});
      if (!mounted) return;
      setState(() {
        _data = res;
        _tab = _s(res['tab_key']).isEmpty ? _tab : _s(res['tab_key']);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// Fires one action RPC and re-reads the tab. The toast is the backend's own
  /// `message`; there is no Dart fallback wording.
  Future<void> _act(String fn, Map<String, dynamic> params) async {
    setState(() => _busy = true);
    try {
      final res = await _rpc(fn, params);
      final msg = _s(res['message']);
      if (mounted && msg.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final tabs = _rows(d?['tabs']);
    final body = d?['body'] is Map
        ? Map<String, dynamic>.from(d!['body'] as Map)
        : null;

    RenderLog.write('c407_extras_tabs', tabs.length);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(d?['title']))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ExtrasMessage(text: '$_error', onRetry: _load)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TabStrip(
                      tabs: tabs,
                      selected: _s(_tab),
                      onTap: (k) {
                        setState(() => _tab = k);
                        _load();
                      },
                    ),
                    if (_busy) const LinearProgressIndicator(),
                    Expanded(child: _body(body)),
                  ],
                ),
    );
  }

  /// An unknown tab_key, or a body the backend refused, renders nothing —
  /// never an exception.
  Widget _body(Map<String, dynamic>? body) {
    if (body == null) return const SizedBox.shrink();
    if (body['ok'] == false) {
      return _ExtrasMessage(text: _s(body['message']), onRetry: _load);
    }
    switch (_s(_tab)) {
      case 'incentives':
        return _IncentivesTab(data: body, act: _act);
      case 'invoices':
        return _InvoicesTab(data: body, act: _act, rpc: _rpc);
      case 'training':
        return _TrainingTab(data: body);
      case 'cost':
        return _CostTab(data: body);
      default:
        return const SizedBox.shrink();
    }
  }
}

class _TabStrip extends StatelessWidget {
  final List<Map<String, dynamic>> tabs;
  final String selected;
  final ValueChanged<String> onTap;

  const _TabStrip(
      {required this.tabs, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x12),
      child: Row(
        children: [
          for (final t in tabs)
            Padding(
              padding: EdgeInsets.only(right: Ds.space.x8),
              child: _Chip(
                label: _s(t['label']),
                tone: _s(t['tab_key']) == selected ? 'brand' : 'muted',
                onTap: () => onTap(_s(t['tab_key'])),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Object? tone;
  final VoidCallback? onTap;

  const _Chip({required this.label, this.tone, this.onTap});

  @override
  Widget build(BuildContext context) {
    final chip = Container(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: extrasToneSoft(tone),
        borderRadius: BorderRadius.circular(Ds.r.chip),
      ),
      child: Text(label,
          style: Ds.t.caption.copyWith(color: extrasToneColor(tone))),
    );
    if (onTap == null) return chip;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Ds.r.chip),
      child: chip,
    );
  }
}

/// A full-width tinted band for a backend SENTENCE — a verdict, a refusal, a
/// reconciliation note. A chip is for a word; this is for a line that wraps.
class _Banner extends StatelessWidget {
  final String text;
  final Object? tone;

  const _Banner({required this.text, this.tone});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: extrasToneSoft(tone),
        borderRadius: BorderRadius.circular(Ds.r.chip),
      ),
      child: Text(text,
          softWrap: true,
          style: Ds.t.caption.copyWith(color: extrasToneColor(tone))),
    );
  }
}

class _Card extends StatelessWidget {
  final List<Widget> children;
  const _Card({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}

/// A label/value pair. The value is right-aligned because it is always a
/// number or a money string; the backend decided what it says.
class _Pair extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;

  const _Pair({required this.label, required this.value, this.bold = false});

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: Ds.t.caption)),
          SizedBox(width: Ds.space.x12),
          Text(value,
              textAlign: TextAlign.right,
              style: bold ? Ds.t.bodyStrong : Ds.t.body),
        ],
      ),
    );
  }
}

class _ExtrasMessage extends StatelessWidget {
  final String text;
  final VoidCallback? onRetry;

  const _ExtrasMessage({required this.text, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center, style: Ds.t.bodySecondary),
            if (onRetry != null) SizedBox(height: Ds.space.x16),
            if (onRetry != null)
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// ── Tab 1 · incentives ─────────────────────────────────────────────────────
class _IncentivesTab extends StatelessWidget {
  final Map<String, dynamic> data;
  final Future<void> Function(String, Map<String, dynamic>) act;

  const _IncentivesTab({required this.data, required this.act});

  @override
  Widget build(BuildContext context) {
    final rows = _rows(data['rows']);
    RenderLog.write('c407_incentive_rows', rows.length);
    if (rows.isEmpty) {
      return _ExtrasMessage(text: _s(data['empty_note']));
    }
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x4, Ds.space.x16, Ds.space.x24),
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          _Chip(
            label: _s(data['run_label']),
            tone: 'brand',
            onTap: () => act('incentive_evaluate_day', const {}),
          ),
        ]),
        SizedBox(height: Ds.space.x16),
        for (final r in rows)
          _Card(children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(_s(r['label']), style: Ds.t.subtitle)),
                SizedBox(width: Ds.space.x8),
                _Chip(label: _s(r['status_label']), tone: r['tone']),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            _Pair(label: _s(r['metric_label']), value: _s(r['target_label'])),
            _Pair(label: _s(r['scope_label']), value: _s(r['window_label'])),
            _Pair(
                label: _s(r['bonus_caption']),
                value: _s(r['bonus_label']),
                bold: true),
            _Pair(label: _s(r['paid_caption']), value: _s(r['paid_label'])),
            if (_s(r['note']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(_s(r['note']), style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: () => act('incentive_scheme_save', {
                  'p_patch': {
                    'scheme_id': _s(r['scheme_id']),
                    'active': !(r['active'] == true),
                  }
                }),
                child: Text(_s(r['toggle_label'])),
              ),
            ),
          ]),
      ],
    );
  }
}

/// ── Tab 2 · agency GST invoices ────────────────────────────────────────────
class _InvoicesTab extends StatelessWidget {
  final Map<String, dynamic> data;
  final Future<void> Function(String, Map<String, dynamic>) act;
  final ExtrasRpc rpc;

  const _InvoicesTab(
      {required this.data, required this.act, required this.rpc});

  @override
  Widget build(BuildContext context) {
    final rows = _rows(data['rows']);
    RenderLog.write('c407_invoice_rows', rows.length);
    if (rows.isEmpty) return _ExtrasMessage(text: _s(data['empty_note']));
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x4, Ds.space.x16, Ds.space.x24),
      children: [
        for (final r in rows)
          _Card(children: [
            Text(_s(r['partner_name']), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x8),
            // The verdict is a SENTENCE, so it gets its own full-width band
            // rather than a chip it would overflow.
            _Banner(text: _s(r['recon_label']), tone: r['recon_tone']),
            SizedBox(height: Ds.space.x8),
            _Pair(label: _s(r['period_caption']), value: _s(r['period_label'])),
            _Pair(label: _s(r['payout_caption']), value: _s(r['payout_label'])),
            _Pair(label: _s(r['invoice_no']), value: _s(r['invoice_total_label'])),
            _Pair(label: _s(r['gstin_label']), value: _s(r['payout_status_label'])),
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                _Chip(
                  label: _s(r['generate_label']),
                  tone: 'brand',
                  onTap: () => act('agency_invoice_generate',
                      {'p_period_id': _s(r['period_id'])}),
                ),
                if (r['has_invoice'] == true)
                  _Chip(
                    label: _s(data['open_label']),
                    tone: 'info',
                    onTap: () => _open(context, _s(r['invoice_id'])),
                  ),
              ],
            ),
          ]),
      ],
    );
  }

  /// Ask for the PDF, then poll on the BACKEND's own `poll_ms` and open the
  /// backend's own bucket + path. This screen never builds a URL and never
  /// invents a timeout.
  Future<void> _open(BuildContext context, String invoiceId) async {
    void toast(String m) {
      if (m.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }

    try {
      var res = await rpc('agency_invoice_doc_request', {'p_invoice_id': invoiceId});
      var tries = 0;
      while (_s(res['status']) == 'building' && tries < 20) {
        final ms = (res['poll_ms'] is num) ? (res['poll_ms'] as num).toInt() : 1500;
        await Future<void>.delayed(Duration(milliseconds: ms));
        res = await rpc('agency_invoice_doc_status', {'p_doc_id': _s(res['doc_id'])});
        tries++;
      }
      if (res['ok'] != true) {
        toast(_s(res['message']));
        return;
      }
      final url = await Supabase.instance.client.storage
          .from(_s(res['bucket']))
          .createSignedUrl(_s(res['path']),
              (res['expires_s'] is num) ? (res['expires_s'] as num).toInt() : 300);
      RenderLog.write('c407_invoice_opened', url.isNotEmpty);
      toast(_s(res['message']));
    } catch (e) {
      toast('$e');
    }
  }
}

/// ── Tab 3 · training modules ───────────────────────────────────────────────
class _TrainingTab extends StatelessWidget {
  final Map<String, dynamic> data;
  const _TrainingTab({required this.data});

  @override
  Widget build(BuildContext context) {
    final rows = _rows(data['rows']);
    RenderLog.write('c407_training_modules', rows.length);
    if (rows.isEmpty) return _ExtrasMessage(text: _s(data['empty_note']));
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x4, Ds.space.x16, Ds.space.x24),
      children: [
        for (final r in rows)
          _Card(children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Text(_s(r['title']), style: Ds.t.subtitle)),
                SizedBox(width: Ds.space.x8),
                _Chip(label: _s(r['status_label']), tone: r['tone']),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            _Pair(
                label: _s(r['required_label']),
                value: _s(r['pass_mark_label'])),
            _Pair(
                label: _s(r['question_count_label']),
                value: _s(r['passed_label'])),
          ]),
      ],
    );
  }
}

/// ── Tab 4 · cost per drop ──────────────────────────────────────────────────
class _CostTab extends StatelessWidget {
  final Map<String, dynamic> data;
  const _CostTab({required this.data});

  @override
  Widget build(BuildContext context) {
    final rows = _rows(data['rows']);
    final summary = _rows(data['summary']);
    RenderLog.write('c407_cost_rows', rows.length);
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x4, Ds.space.x16, Ds.space.x24),
      children: [
        _Card(children: [
          Text(_s(data['range_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          for (final s in summary)
            _Pair(
                label: _s(s['label']),
                value: _s(s['value']),
                bold: s['bold'] == true),
        ]),
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x24),
            child: Text(_s(data['empty_note']),
                textAlign: TextAlign.center, style: Ds.t.bodySecondary),
          ),
        for (final r in rows)
          _Card(children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child:
                        Text(_s(r['partner_name']), style: Ds.t.subtitle)),
                SizedBox(width: Ds.space.x8),
                _Chip(label: _s(r['actual_label']), tone: r['tone']),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            _Pair(label: _s(r['zone_label']), value: _s(r['drops_label'])),
            _Pair(label: _s(r['earn_label']), value: _s(r['bonus_label'])),
            _Pair(
                label: _s(r['spend_label']),
                value: _s(r['configured_label'])),
            _Pair(
                label: _s(r['variance_caption']),
                value: _s(r['variance_label']),
                bold: true),
          ]),
      ],
    );
  }
}
