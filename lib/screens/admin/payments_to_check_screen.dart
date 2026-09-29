// CMD #2250 — "UPI payments to check" (design frame 42).
//
// One list of everything a partner still has to decide: the payments a customer
// started from the Pay button whose result the app could not read, and the
// Vyapar alerts that are waiting or unmatched. Every line, chip and button
// label comes from payments_to_check_screen(); Verify / Reject go straight back
// to payments_to_check_act(), which returns the redrawn screen.
//
// Change-basis: realtime on the two tables it reads, plus pull-to-refresh. No
// timer, no polling.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'payment_ui.dart';

class PaymentsToCheckScreen extends StatefulWidget {
  final Future<Map<String, dynamic>> Function()? screenRpc;
  final Future<Map<String, dynamic>> Function(
      String kind, String id, String action)? actRpc;
  final bool listenRealtime;

  const PaymentsToCheckScreen({
    super.key,
    this.screenRpc,
    this.actRpc,
    this.listenRealtime = true,
  });

  @override
  State<PaymentsToCheckScreen> createState() => _PaymentsToCheckScreenState();
}

class _PaymentsToCheckScreenState extends State<PaymentsToCheckScreen> {
  Map<String, dynamic>? _p;
  bool _loading = true;
  String? _error;
  String? _busyId;
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
      final ch = Supabase.instance.client.channel('c2250_pay_check');
      for (final t in const ['payment_alerts', 'payment_expected']) {
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
      // Pull-to-refresh still works without realtime.
    }
  }

  Future<Map<String, dynamic>> _rpcScreen() async {
    if (widget.screenRpc != null) return widget.screenRpc!();
    final r = await Supabase.instance.client.rpc('payments_to_check_screen');
    return Map<String, dynamic>.from(r as Map);
  }

  Future<Map<String, dynamic>> _rpcAct(
      String kind, String id, String action) async {
    if (widget.actRpc != null) return widget.actRpc!(kind, id, action);
    final r = await Supabase.instance.client.rpc('payments_to_check_act',
        params: {'p_kind': kind, 'p_id': id, 'p_action': action});
    return Map<String, dynamic>.from(r as Map);
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final p = await _rpcScreen();
      if (!mounted) return;
      setState(() {
        _p = p;
        _loading = false;
      });
      RenderLog.write('c2250_check_rows', payRows(p['rows']).length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _act(Map<String, dynamic> row, String action) async {
    final id = payStr(row, 'id');
    setState(() => _busyId = id);
    try {
      final r = await _rpcAct(payStr(row, 'kind'), id, action);
      if (!mounted) return;
      setState(() {
        _busyId = null;
        if (r['screen'] is Map) {
          _p = Map<String, dynamic>.from(r['screen'] as Map);
        }
      });
      final msg = payStr(r, 'message');
      if (msg.isNotEmpty && mounted) {
        showToast(context, msg, isError: r['ok'] == false);
      }
      if (r['screen'] == null) await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      showToast(context, e.toString(), isError: true);
    }
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
        children: const [PaySkeleton()],
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
            retryLabel: payStr(p ?? const {}, 'title'),
            onRetry: _load,
          ),
        ],
      );
    }
    final rows = payRows(p['rows']);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        PaySectionLabel(payStr(p, 'section_label')),
        if (rows.isEmpty)
          PayEmpty(
              label: payStr(p, 'empty_label'), hint: payStr(p, 'empty_hint'))
        else
          for (final r in rows) ...[
            Semantics(
              identifier: 'check_row',
              child: PayCard(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(payStr(r, 'title'),
                              style: Ds.t.body
                                  .copyWith(fontWeight: FontWeight.w700)),
                          SizedBox(height: Ds.space.x4),
                          Text(payStr(r, 'sub1'), style: Ds.t.caption),
                          SizedBox(height: Ds.space.x4),
                          Text(payStr(r, 'sub2'), style: Ds.t.caption),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Column(
                      children: [
                        Semantics(
                          identifier: 'check_verify',
                          child: SizedBox(
                            height: Ds.touch.minTarget,
                            child: FilledButton(
                              onPressed: _busyId == payStr(r, 'id')
                                  ? null
                                  : () => _act(r, 'verify'),
                              style: FilledButton.styleFrom(
                                backgroundColor: Ds.c.brand,
                                shape: RoundedRectangleBorder(
                                    borderRadius: Ds.r.rButton),
                              ),
                              child: Text(payStr(r, 'verify_label'),
                                  style: Ds.t.caption.copyWith(
                                      color: Ds.c.surface,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ),
                        ),
                        Semantics(
                          identifier: 'check_reject',
                          child: SizedBox(
                            height: Ds.touch.minTarget,
                            child: TextButton(
                              onPressed: _busyId == payStr(r, 'id')
                                  ? null
                                  : () => _act(r, 'reject'),
                              child: Text(payStr(r, 'reject_label'),
                                  style: Ds.t.caption
                                      .copyWith(color: Ds.c.textSecondary)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(height: Ds.space.x12),
          ],
        SizedBox(height: Ds.space.x16),
        Text(payStr(p, 'hint'), style: Ds.t.caption),
      ],
    );
  }
}
