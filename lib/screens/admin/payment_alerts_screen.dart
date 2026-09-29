// CMD #2250 — "Payment alerts" (design frames 5–6 and 33–37).
//
// One RPC draws the whole screen: payment_alerts_screen() returns the partner
// phone's own block (listening / stopped reporting + the three fix steps), the
// outcome filter chips with their counts, and every alert already rendered by
// payment_alert_state. The outcome chip, the "why it matched" line, the write-
// off and the button set on the detail sheet are all backend strings — this
// screen decides none of them.
//
// Change-basis: it refreshes on a realtime event from payment_alerts /
// payment_claims / payment_expected, on a pull-to-refresh and on an action.
// There is no timer anywhere; an idle screen makes no requests.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'payment_ui.dart';

class PaymentAlertsScreen extends StatefulWidget {
  final Future<Map<String, dynamic>> Function(String? filter)? screenRpc;
  final Future<Map<String, dynamic>> Function(
      String alertId, String action, String? claimId)? actRpc;
  final Future<Map<String, dynamic>> Function(String device, bool on)? setRpc;
  final bool listenRealtime;

  const PaymentAlertsScreen({
    super.key,
    this.screenRpc,
    this.actRpc,
    this.setRpc,
    this.listenRealtime = true,
  });

  @override
  State<PaymentAlertsScreen> createState() => _PaymentAlertsScreenState();
}

class _PaymentAlertsScreenState extends State<PaymentAlertsScreen> {
  Map<String, dynamic>? _p;
  bool _loading = true;
  String _filter = '';
  String? _error;
  RealtimeChannel? _ch;

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.listenRealtime) _subscribe();
  }

  @override
  void dispose() {
    final ch = _ch;
    if (ch != null) Supabase.instance.client.removeChannel(ch);
    super.dispose();
  }

  void _subscribe() {
    try {
      final ch = Supabase.instance.client.channel('c2250_pay_alerts');
      for (final t in const ['payment_alerts', 'payment_claims', 'payment_expected']) {
        ch.onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: t,
          callback: (_) => _load(),
        );
      }
      ch.subscribe();
      _ch = ch;
    } catch (_) {
      // Realtime is an accelerator; pull-to-refresh still works without it.
    }
  }

  Future<Map<String, dynamic>> _rpcScreen(String? f) async {
    if (widget.screenRpc != null) return widget.screenRpc!(f);
    final r = await Supabase.instance.client.rpc('payment_alerts_screen',
        params: {'p_status': (f == null || f.isEmpty) ? null : f});
    return Map<String, dynamic>.from(r as Map);
  }

  Future<Map<String, dynamic>> _rpcAct(
      String alertId, String action, String? claimId) async {
    if (widget.actRpc != null) return widget.actRpc!(alertId, action, claimId);
    final r = await Supabase.instance.client.rpc('payment_alert_act', params: {
      'p_alert_id': alertId,
      'p_action': action,
      'p_claim_id': claimId,
    });
    return Map<String, dynamic>.from(r as Map);
  }

  Future<Map<String, dynamic>> _rpcSet(String device, bool on) async {
    if (widget.setRpc != null) return widget.setRpc!(device, on);
    final r = await Supabase.instance.client.rpc('payment_alert_device_set',
        params: {'p_device': device, 'p_listener_enabled': on});
    return Map<String, dynamic>.from(r as Map);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final p = await _rpcScreen(_filter);
      if (!mounted) return;
      setState(() {
        _p = p;
        _loading = false;
      });
      RenderLog.write('c2250_alert_rows', payRows(p['rows']).length);
      final phone = (p['phone'] is Map) ? Map<String, dynamic>.from(p['phone'] as Map) : const {};
      RenderLog.write('c2250_phone_state', payStr(Map<String, dynamic>.from(phone), 'state'));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _act(Map<String, dynamic> alert, Map<String, dynamic> action) async {
    final key = payStr(action, 'key');
    if (key == 'open_order') {
      Navigator.of(context).maybePop();
      return;
    }
    try {
      final r = await _rpcAct(payStr(alert, 'alert_id'), key, null);
      if (!mounted) return;
      final msg = payStr(r, 'message');
      if (msg.isNotEmpty) showToast(context, msg, isError: r['ok'] == false);
      Navigator.of(context).maybePop();
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  void _openDetail(Map<String, dynamic> a) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(payStr(a, 'amount_label'),
                        style: Ds.t.display.copyWith(fontWeight: FontWeight.w700)),
                  ),
                  PayChip(payStr(a, 'outcome_label'), tone: a['outcome_tone']),
                ],
              ),
              SizedBox(height: Ds.space.x4),
              Text(payStr(a, 'subtitle'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x24),
              for (final r in payRows(a['rows']))
                PayKeyValue(
                    label: payStr(r, 'label'), value: payStr(r, 'value')),
              SizedBox(height: Ds.space.x8),
              Row(
                children: [
                  for (final act in payRows(a['actions'])) ...[
                    Expanded(
                      child: Semantics(
                        identifier: 'alert_act_${payStr(act, 'key')}',
                        child: PayPrimaryButton(
                          label: payStr(act, 'label'),
                          outlined: payStr(act, 'tone') != 'primary',
                          onPressed: () => _act(a, act),
                        ),
                      ),
                    ),
                    if (act != payRows(a['actions']).last)
                      SizedBox(width: Ds.space.x12),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        elevation: 0,
        iconTheme: IconThemeData(color: Ds.c.brand),
        title: Text(payStr(p ?? const {}, 'title'),
            style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: Ds.c.divider),
        ),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          color: Ds.c.brand,
          onRefresh: _load,
          child: _body(p),
        ),
      ),
    );
  }

  Widget _body(Map<String, dynamic>? p) {
    if (_loading) {
      return ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: const [PaySkeleton(lines: 4)],
      );
    }
    if (p == null || p['ok'] != true) {
      return ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          PayError(
            message: payStr(p ?? const {}, 'message').isNotEmpty
                ? payStr(p!, 'message')
                : (_error ?? ''),
            retryLabel: payStr(p ?? const {}, 'retry_label'),
            onRetry: _load,
          ),
        ],
      );
    }

    final phone = (p['phone'] is Map)
        ? Map<String, dynamic>.from(p['phone'] as Map)
        : <String, dynamic>{};
    final rows = payRows(p['rows']);
    final filters = payRows(p['filters']);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        if (phone['ok'] == true) ...[
          _phoneBlock(phone),
          SizedBox(height: Ds.space.x24),
        ],
        if (filters.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final f in filters) ...[
                  Semantics(
                    identifier: 'alert_filter_${payStr(f, 'key')}',
                    child: InkWell(
                      borderRadius: Ds.r.rChip,
                      onTap: () {
                        setState(() => _filter = payStr(f, 'key'));
                        _load();
                      },
                      child: Container(
                        constraints:
                            BoxConstraints(minHeight: Ds.touch.minTarget),
                        alignment: Alignment.center,
                        padding: EdgeInsets.symmetric(
                            horizontal: Ds.space.x16, vertical: Ds.space.x8),
                        decoration: BoxDecoration(
                          color: _filter == payStr(f, 'key')
                              ? Ds.c.brand
                              : Ds.c.surface,
                          borderRadius: Ds.r.rChip,
                          border: Border.all(color: Ds.c.divider),
                        ),
                        child: Text(payStr(f, 'label'),
                            style: Ds.t.caption.copyWith(
                                fontWeight: FontWeight.w600,
                                color: _filter == payStr(f, 'key')
                                    ? Ds.c.surface
                                    : Ds.c.text)),
                      ),
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                ],
              ],
            ),
          ),
        SizedBox(height: Ds.space.x16),
        if (rows.isEmpty)
          PayEmpty(
              label: payStr(p, 'empty_label'), hint: payStr(p, 'empty_hint'))
        else
          for (final a in rows) ...[
            Semantics(
              identifier: 'alert_row',
              child: PayCard(
                onTap: () => _openDetail(a),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(payStr(a, 'amount_label'),
                          style: Ds.t.body
                              .copyWith(fontWeight: FontWeight.w700)),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Expanded(
                      flex: 5,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(payStr(a, 'sender_label'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Ds.t.body
                                  .copyWith(fontWeight: FontWeight.w600)),
                          SizedBox(height: Ds.space.x4),
                          Text(payStr(a, 'list_sub'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Ds.t.caption),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x8),
                    PayChip(payStr(a, 'outcome_label'), tone: a['outcome_tone']),
                  ],
                ),
              ),
            ),
            SizedBox(height: Ds.space.x12),
          ],
      ],
    );
  }

  Widget _phoneBlock(Map<String, dynamic> phone) {
    final banner = (phone['banner'] is Map)
        ? Map<String, dynamic>.from(phone['banner'] as Map)
        : <String, dynamic>{};
    final toggles = payRows(phone['toggles']);
    final apps = payRows(phone['apps']);
    final fix = payRows(phone['fix']);
    final device = payStr(phone, 'device_id');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PayBanner(banner),
        if (fix.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          PaySectionLabel(payStr(phone, 'fix_label')),
          PayCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < fix.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: Ds.c.divider),
                  Padding(
                    padding: EdgeInsets.all(Ds.space.x16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${fix[i]['n']}', style: Ds.t.caption),
                        SizedBox(width: Ds.space.x12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(payStr(fix[i], 'label'),
                                  style: Ds.t.body
                                      .copyWith(fontWeight: FontWeight.w600)),
                              SizedBox(height: Ds.space.x4),
                              Text(payStr(fix[i], 'sub'), style: Ds.t.caption),
                            ],
                          ),
                        ),
                        SizedBox(width: Ds.space.x8),
                        PayChip(payStr(fix[i], 'chip'),
                            tone: fix[i]['done'] == true ? 'success' : 'muted'),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(height: Ds.space.x16),
          Semantics(
            identifier: 'phone_open_settings',
            child: PayPrimaryButton(
              label: payStr(phone, 'settings_label'),
              onPressed: () async {
                final u = Uri.parse('package:');
                try {
                  await launchUrl(u, mode: LaunchMode.externalApplication);
                } catch (_) {
                  if (mounted) {
                    showToast(context, payStr(banner, 'body'));
                  }
                }
              },
            ),
          ),
        ],
        if (toggles.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          PaySectionLabel(payStr(phone, 'phone_label')),
          PayCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < toggles.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: Ds.c.divider),
                  Padding(
                    padding: EdgeInsets.all(Ds.space.x16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(payStr(toggles[i], 'label'),
                                  style: Ds.t.body
                                      .copyWith(fontWeight: FontWeight.w600)),
                              SizedBox(height: Ds.space.x4),
                              Text(payStr(toggles[i], 'sub'),
                                  style: Ds.t.caption),
                            ],
                          ),
                        ),
                        if (payStr(toggles[i], 'kind') == 'switch')
                          Semantics(
                            identifier: 'phone_toggle_${payStr(toggles[i], 'key')}',
                            child: Switch(
                              value: toggles[i]['on'] == true,
                              activeThumbColor: Ds.c.brand,
                              onChanged: device.isEmpty
                                  ? null
                                  : (v) async {
                                      await _rpcSet(device, v);
                                      await _load();
                                    },
                            ),
                          )
                        else
                          PayChip(payStr(toggles[i], 'chip'),
                              tone: toggles[i]['chip_tone']),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (apps.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          PaySectionLabel(payStr(phone, 'apps_label')),
          PayCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < apps.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: Ds.c.divider),
                  Padding(
                    padding: EdgeInsets.all(Ds.space.x16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(payStr(apps[i], 'label'),
                                  style: Ds.t.body
                                      .copyWith(fontWeight: FontWeight.w600)),
                              SizedBox(height: Ds.space.x4),
                              Text(payStr(apps[i], 'sub'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Ds.t.caption),
                            ],
                          ),
                        ),
                        SizedBox(width: Ds.space.x8),
                        PayChip(payStr(apps[i], 'chip'),
                            tone: apps[i]['chip_tone']),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(height: Ds.space.x16),
          Semantics(
            identifier: 'phone_send_test',
            child: PayPrimaryButton(
              label: payStr(phone, 'test_label'),
              outlined: true,
              onPressed: () async {
                try {
                  final r = await Supabase.instance.client.rpc(
                      'upi_test_rupee',
                      params: {'p_pa': null, 'p_pn': null, 'p_mc': null});
                  final m = Map<String, dynamic>.from(r as Map);
                  final url = payStr(m, 'upi_url');
                  if (url.isNotEmpty) {
                    await launchUrl(Uri.parse(url),
                        mode: LaunchMode.externalApplication);
                  } else if (mounted) {
                    showToast(context, payStr(m, 'message'), isError: true);
                  }
                } catch (e) {
                  if (mounted) showToast(context, e.toString(), isError: true);
                }
              },
            ),
          ),
        ],
      ],
    );
  }
}
