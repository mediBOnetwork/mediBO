// CHANGE #395 — Returns, refunds and cancellation.
//
// Money could leave mediBO and never come back. This is the surface that ends
// that: record a return against a billed line, watch the credit note land on
// the invoice at the SAME discount slab the bill used, refund what was actually
// collected, and cancel an order with a reason that releases its stock and its
// open supplier inquiry lines.
//
// It renders `order_returns_panel()` and `returns_orders_list()` VERBATIM. Every
// label, chip, tone, amount, empty state and enabled/disabled flag arrives in
// the payload — this file computes no money, pluralises nothing, and holds no
// display string of its own.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/returns_service.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../services/idempotency.dart';

/// Backend tone name -> the token pair the design system paints it with.
/// The backend names the MEANING; only the palette lives here.
({Color fg, Color bg}) _tone(String? name) {
  switch (name) {
    case 'success':
      return (fg: Ds.c.success, bg: Ds.c.successSoft);
    case 'warning':
      return (fg: Ds.c.warning, bg: Ds.c.warningSoft);
    case 'danger':
      return (fg: Ds.c.danger, bg: Ds.c.dangerSoft);
    default:
      return (fg: Ds.c.info, bg: Ds.c.infoSoft);
  }
}

String _s(Object? v) => v == null ? '' : v.toString();
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

// ─────────────────────────────────────────────────────────────────────────────
// Shared small pieces
// ─────────────────────────────────────────────────────────────────────────────

class ToneChip extends StatelessWidget {
  final String label;
  final String? tone;
  const ToneChip(this.label, this.tone, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = _tone(tone);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: t.bg, borderRadius: Ds.r.rChip),
      child: Text(label, style: Ds.t.caption.copyWith(color: t.fg)),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: child,
      );
}

/// Loading is a skeleton, never a bare spinner (design QA rule 6).
class _Skeleton extends StatelessWidget {
  final int lines;
  const _Skeleton({this.lines = 3});

  @override
  Widget build(BuildContext context) => Column(
        children: List.generate(
          lines,
          (_) => Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: Ds.touch.listRowMinHeight,
              decoration: BoxDecoration(
                  color: Ds.c.divider, borderRadius: Ds.r.rCard),
            ),
          ),
        ),
      );
}

/// The error state prints the BACKEND's copy plus a Retry, never a Dart string.
class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState(this.message, this.onRetry);

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message.isEmpty ? c('returns.err_generic') : message,
                style: Ds.t.body),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                  onPressed: onRetry, child: Text(c('returns.retry'))),
            ),
          ],
        ),
      );
}

class _Empty extends StatelessWidget {
  final String label;
  const _Empty(this.label);

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
        child: Text(label, style: Ds.t.bodySecondary),
      );
}

class _SectionTitle extends StatelessWidget {
  final String label;
  final Widget? trailing;
  const _SectionTitle(this.label, {this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Row(
          children: [
            Expanded(child: Text(label, style: Ds.t.subtitle)),
            ?trailing,
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. The entry list
// ─────────────────────────────────────────────────────────────────────────────

class ReturnsRefundsScreen extends StatefulWidget {
  /// Optional deep-link: open straight onto one order's panel.
  final String? orderId;
  const ReturnsRefundsScreen({super.key, this.orderId});

  @override
  State<ReturnsRefundsScreen> createState() => _ReturnsRefundsScreenState();
}

class _ReturnsRefundsScreenState extends State<ReturnsRefundsScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    RenderLog.write('c395_list_screen', 1);
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await ReturnsService.ordersList(q: _searchCtrl.text);
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _open(String orderId) {
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
            builder: (_) => _OrderPanelPage(orderId: orderId)))
        .then((_) => _load());
  }

  @override
  Widget build(BuildContext context) {
    // A deep-linked order skips the list entirely.
    if (widget.orderId != null) {
      return _OrderPanelPage(orderId: widget.orderId!);
    }

    final d = _data ?? const <String, dynamic>{};
    final rows = _rows(d['rows']);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(d['title']).isEmpty ? c('returns.list_title') : _s(d['title'])),
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 900;
          return RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: EdgeInsets.symmetric(
                  horizontal: wide ? Ds.space.x32 : Ds.space.x16,
                  vertical: Ds.space.x16),
              children: [
                if (_s(d['subtitle']).isNotEmpty) ...[
                  Text(_s(d['subtitle']), style: Ds.t.bodySecondary),
                  SizedBox(height: Ds.space.x16),
                ],
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: TextField(
                    controller: _searchCtrl,
                    onSubmitted: (_) => _load(),
                    decoration: InputDecoration(
                      hintText: _s(d['search_hint']),
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(height: Ds.space.x24),
                if (_loading)
                  const _Skeleton(lines: 4)
                else if (_error != null)
                  _ErrorState(_error!, _load)
                else if (rows.isEmpty)
                  _Empty(_s(d['empty']))
                else ...[
                  Text(_s(d['count_label']), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x12),
                  for (final r in rows) ...[
                    _OrderRow(row: r, onTap: () => _open(_s(r['order_id']))),
                    SizedBox(height: Ds.space.x12),
                  ],
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _OrderRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onTap;
  const _OrderRow({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final chips = _rows(row['chips']);
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rCard,
      child: _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s(row['order_code']), style: Ds.t.body),
                      SizedBox(height: Ds.space.x4),
                      Text(_s(row['customer']), style: Ds.t.caption),
                    ],
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(_s(row['amount_label']), style: Ds.t.body),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(row['date_label']), style: Ds.t.caption),
                  ],
                ),
              ],
            ),
            if (chips.isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              Wrap(
                spacing: Ds.space.x8,
                runSpacing: Ds.space.x8,
                children: [
                  for (final ch in chips)
                    ToneChip(_s(ch['label']), _s(ch['tone'])),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. The order panel — one RPC, rendered verbatim
// ─────────────────────────────────────────────────────────────────────────────

class _OrderPanelPage extends StatefulWidget {
  final String orderId;
  const _OrderPanelPage({required this.orderId});

  @override
  State<_OrderPanelPage> createState() => _OrderPanelPageState();
}

class _OrderPanelPageState extends State<_OrderPanelPage> {
  Map<String, dynamic>? _p;
  bool _loading = true;
  String? _error;
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
      final p = await ReturnsService.panel(widget.orderId);
      if (!mounted) return;
      setState(() {
        _p = p;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// CHANGE #472 — one key per refund the admin confirmed, held across retries
  /// so a second attempt is the same refund and not a second one.
  String? _refundKey;

  /// Every mutation lands here: run it, print the BACKEND's own message, reload.
  /// Returns whether the backend said ok, which is what tells a keyed action
  /// (#472) that it may retire its client_action_id.
  Future<bool> _run(Future<Map<String, dynamic>> Function() action) async {
    if (_busy) return false;
    setState(() => _busy = true);
    bool ok = false;
    try {
      final r = await action();
      ok = r['ok'] == true;
      if (!mounted) return ok;
      final msg = _s(r['message']);
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor:
              (r['ok'] == true) ? Ds.c.success : Ds.c.danger,
        ));
      }
      await _load();
    } catch (e) {
      if (!mounted) return ok;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString()), backgroundColor: Ds.c.danger));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final p = _p ?? const <String, dynamic>{};
    final headings = (p['headings'] as Map?) ?? const {};
    final empty = (p['empty'] as Map?) ?? const {};
    final actions = (p['actions'] as Map?) ?? const {};
    final money = (p['money'] as Map?) ?? const {};
    final cancellation = p['cancellation'] as Map?;
    final lines = _rows(p['lines']);
    final returns = _rows(p['returns']);
    final refunds = _rows(p['refunds']);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(p['title']).isEmpty ? c('returns.panel_title') : _s(p['title'])),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(2), child: LinearProgressIndicator())
            : null,
      ),
      body: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 900;
        if (_loading) {
          return Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: const _Skeleton(lines: 5),
          );
        }
        if (_error != null) {
          return Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: _ErrorState(_error!, _load),
          );
        }
        return ListView(
          padding: EdgeInsets.symmetric(
              horizontal: wide ? Ds.space.x32 : Ds.space.x16,
              vertical: Ds.space.x16),
          children: [
            Text(_s(p['order_code']), style: Ds.t.title),
            SizedBox(height: Ds.space.x24),

            // ── Money on this order
            _SectionTitle(_s(headings['money'])),
            _Card(
              child: Column(
                children: [
                  _MoneyRow(_s(money['collected_label']), c('refunds.status_processed'),
                      leading: true),
                  SizedBox(height: Ds.space.x8),
                  _MoneyRow(_s(money['refunded_label']), _s(money['refunded_label'])),
                  SizedBox(height: Ds.space.x8),
                  _MoneyRow(_s(money['refundable_label']), _s(money['cap_note'])),
                ],
              ),
            ),
            SizedBox(height: Ds.space.x24),

            // ── Cancellation
            _SectionTitle(_s(headings['cancel'])),
            if (cancellation != null)
              _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ToneChip(_s(cancellation['reason_label']), 'danger'),
                    SizedBox(height: Ds.space.x12),
                    Text(_s(cancellation['released_label']), style: Ds.t.body),
                    if (cancellation['has_refund'] == true) ...[
                      SizedBox(height: Ds.space.x8),
                      Text(_s(cancellation['refund_amount_label']), style: Ds.t.body),
                    ],
                    SizedBox(height: Ds.space.x8),
                    Text(_s(cancellation['at_label']), style: Ds.t.caption),
                  ],
                ),
              )
            else if (p['can_cancel'] == true)
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: Ds.c.danger),
                  onPressed: _busy ? null : _openCancelSheet,
                  child: Text(_s(actions['cancel_order'])),
                ),
              ),
            SizedBox(height: Ds.space.x24),

            // ── Returns
            _SectionTitle(
              _s(headings['returns']),
              trailing: lines.isEmpty
                  ? null
                  : TextButton(
                      onPressed: _busy ? null : () => _openReturnSheet(p),
                      child: Text(_s(actions['add_return']))),
            ),
            if (lines.isEmpty)
              _Empty(_s(empty['lines']))
            else if (returns.isEmpty)
              _Empty(_s(empty['returns']))
            else
              for (final r in returns) ...[
                ReturnCard(
                  row: r,
                  actions: actions,
                  busy: _busy,
                  onApprove: () =>
                      _run(() => ReturnsService.approveReturn(_s(r['id']))),
                  onReject: () =>
                      _run(() => ReturnsService.rejectReturn(_s(r['id']), null)),
                ),
                SizedBox(height: Ds.space.x12),
              ],
            SizedBox(height: Ds.space.x24),

            // ── Refunds
            _SectionTitle(
              _s(headings['refunds']),
              trailing: (money['can_refund'] == true)
                  ? TextButton(
                      onPressed: _busy ? null : () => _openRefundSheet(p),
                      child: Text(_s(actions['refund'])))
                  : null,
            ),
            if (refunds.isEmpty)
              _Empty(_s(empty['refunds']))
            else
              for (final f in refunds) ...[
                RefundCard(
                  row: f,
                  actions: actions,
                  busy: _busy,
                  onSend: () => _run(
                      () => ReturnsService.sendRefundToRazorpay(_s(f['id']))),
                  onMarkPaid: () => _run(
                      () => ReturnsService.markRefundManual(_s(f['id']), null)),
                ),
                SizedBox(height: Ds.space.x12),
              ],
            SizedBox(height: Ds.space.x32),
          ],
        );
      }),
    );
  }

  // ── Sheets (sheets over dialogs — design QA rule 4)

  Future<void> _openReturnSheet(Map<String, dynamic> p) async {
    final reasons = (p['reasons'] as Map?) ?? const {};
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ReturnSheet(
        lines: _rows(p['lines']),
        reasons: _rows(reasons['return']),
        conditions: _rows(reasons['return_condition']),
        title: _s(((p['actions'] as Map?) ?? const {})['add_return']),
      ),
    );
    if (res == null) return;
    await _run(() => ReturnsService.addReturn(
          orderId: widget.orderId,
          orderItemId: _s(res['order_item_id']),
          qty: res['qty'] as num,
          reasonCode: _s(res['reason_code']),
          conditionCode: _s(res['condition_code']),
          note: _s(res['note']),
          photoPath: _s(res['photo_path']),
        ));
  }

  Future<void> _openRefundSheet(Map<String, dynamic> p) async {
    final reasons = (p['reasons'] as Map?) ?? const {};
    final money = (p['money'] as Map?) ?? const {};
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _RefundSheet(
        reasons: _rows(reasons['refund']),
        money: Map<String, dynamic>.from(money),
        title: _s(((p['actions'] as Map?) ?? const {})['refund']),
      ),
    );
    if (res == null) return;
    // CHANGE #472 — one key per refund the admin actually confirmed. _run may
    // be tapped again after a timeout; the same key makes that the SAME refund
    // rather than a second one against the same order.
    _refundKey ??= ActionKey.mint();
    final ok = await _run(() => ReturnsService.requestRefund(
          orderId: widget.orderId,
          amount: res['amount'] as num,
          reasonCode: _s(res['reason_code']),
          method: _s(res['method']),
          note: _s(res['note']),
          clientActionId: _refundKey,
        ));
    if (ok) _refundKey = null;
  }

  Future<void> _openCancelSheet() async {
    final p = _p ?? const <String, dynamic>{};
    final reasons = (p['reasons'] as Map?) ?? const {};
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CancelSheet(
        reasons: _rows(reasons['cancel']),
        title: _s(((p['actions'] as Map?) ?? const {})['cancel_order']),
      ),
    );
    if (res == null) return;
    await _run(() => ReturnsService.cancelOrder(
          orderId: widget.orderId,
          reasonCode: _s(res['reason_code']),
          note: _s(res['note']),
        ));
  }
}

class _MoneyRow extends StatelessWidget {
  final String amount;
  final String caption;
  final bool leading;
  const _MoneyRow(this.amount, this.caption, {this.leading = false});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: Text(caption, style: Ds.t.caption)),
          SizedBox(width: Ds.space.x12),
          Text(amount, style: leading ? Ds.t.subtitle : Ds.t.body),
        ],
      );
}

class ReturnCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final Map actions;
  final bool busy;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  const ReturnCard({
    super.key,
    required this.row,
    required this.actions,
    required this.busy,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                    child: Text(_s(row['product_name']), style: Ds.t.body)),
                SizedBox(width: Ds.space.x12),
                ToneChip(_s(row['status_label']), _s(row['status_tone'])),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x4,
              children: [
                Text(_s(row['qty_label']), style: Ds.t.caption),
                if (_s(row['reason_label']).isNotEmpty)
                  Text(_s(row['reason_label']), style: Ds.t.caption),
                if (_s(row['condition_label']).isNotEmpty)
                  Text(_s(row['condition_label']), style: Ds.t.caption),
                Text(_s(row['at_label']), style: Ds.t.caption),
              ],
            ),
            if (row['has_credit'] == true) ...[
              SizedBox(height: Ds.space.x12),
              Row(
                children: [
                  Expanded(
                      child: Text(_s(row['slab_label']), style: Ds.t.caption)),
                  Text(_s(row['credit_label']), style: Ds.t.subtitle),
                ],
              ),
            ],
            if (row['can_approve'] == true || row['can_reject'] == true) ...[
              SizedBox(height: Ds.space.x16),
              Row(
                children: [
                  if (row['can_approve'] == true)
                    Expanded(
                      child: SizedBox(
                        height: Ds.touch.minTarget,
                        child: FilledButton(
                            onPressed: busy ? null : onApprove,
                            child: Text(_s(actions['approve']))),
                      ),
                    ),
                  if (row['can_approve'] == true && row['can_reject'] == true)
                    SizedBox(width: Ds.space.x12),
                  if (row['can_reject'] == true)
                    Expanded(
                      child: SizedBox(
                        height: Ds.touch.minTarget,
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                              foregroundColor: Ds.c.danger),
                          onPressed: busy ? null : onReject,
                          child: Text(_s(actions['reject'])),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      );
}

class RefundCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final Map actions;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onMarkPaid;
  const RefundCard({
    super.key,
    required this.row,
    required this.actions,
    required this.busy,
    required this.onSend,
    required this.onMarkPaid,
  });

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child:
                        Text(_s(row['amount_label']), style: Ds.t.subtitle)),
                SizedBox(width: Ds.space.x12),
                ToneChip(_s(row['status_label']), _s(row['status_tone'])),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x4,
              children: [
                Text(_s(row['method_label']), style: Ds.t.caption),
                if (_s(row['reason_label']).isNotEmpty)
                  Text(_s(row['reason_label']), style: Ds.t.caption),
                if (_s(row['provider_refund_id']).isNotEmpty)
                  Text(_s(row['provider_refund_id']), style: Ds.t.caption),
                if (_s(row['utr']).isNotEmpty)
                  Text(_s(row['utr']), style: Ds.t.caption),
                Text(_s(row['at_label']), style: Ds.t.caption),
              ],
            ),
            if (_s(row['error']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(_s(row['error']),
                  style: Ds.t.caption.copyWith(color: Ds.c.danger)),
            ],
            if (row['can_send'] == true || row['can_mark_manual'] == true) ...[
              SizedBox(height: Ds.space.x16),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: busy
                      ? null
                      : (row['can_send'] == true ? onSend : onMarkPaid),
                  child: Text(row['can_send'] == true
                      ? _s(actions['send_refund'])
                      : _s(actions['mark_manual'])),
                ),
              ),
            ],
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. Sheets
// ─────────────────────────────────────────────────────────────────────────────

class _SheetFrame extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _SheetFrame({required this.title, required this.children});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(context).viewInsets.bottom + Ds.space.x24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x24),
              ...children,
            ],
          ),
        ),
      );
}

class _ReturnSheet extends StatefulWidget {
  final List<Map<String, dynamic>> lines;
  final List<Map<String, dynamic>> reasons;
  final List<Map<String, dynamic>> conditions;
  final String title;
  const _ReturnSheet({
    required this.lines,
    required this.reasons,
    required this.conditions,
    required this.title,
  });

  @override
  State<_ReturnSheet> createState() => _ReturnSheetState();
}

class _ReturnSheetState extends State<_ReturnSheet> {
  String? _item;
  String? _reason;
  String? _condition;
  final _qty = TextEditingController();
  final _note = TextEditingController();
  final _photo = TextEditingController();

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    _photo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectable =
        widget.lines.where((l) => l['can_return'] == true).toList();
    return _SheetFrame(
      title: widget.title,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _item,
          isExpanded: true,
          items: [
            for (final l in selectable)
              DropdownMenuItem(
                value: _s(l['order_item_id']),
                child: Text(
                  '${_s(l['product_name'])} · ${_s(l['returnable_label'])}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => setState(() => _item = v),
        ),
        SizedBox(height: Ds.space.x16),
        TextField(
          controller: _qty,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        SizedBox(height: Ds.space.x16),
        DropdownButtonFormField<String>(
          initialValue: _reason,
          isExpanded: true,
          items: [
            for (final r in widget.reasons)
              DropdownMenuItem(
                  value: _s(r['code']), child: Text(_s(r['label']))),
          ],
          onChanged: (v) => setState(() => _reason = v),
        ),
        SizedBox(height: Ds.space.x16),
        DropdownButtonFormField<String>(
          initialValue: _condition,
          isExpanded: true,
          items: [
            for (final r in widget.conditions)
              DropdownMenuItem(
                  value: _s(r['code']), child: Text(_s(r['label']))),
          ],
          onChanged: (v) => setState(() => _condition = v),
        ),
        SizedBox(height: Ds.space.x16),
        TextField(controller: _photo),
        SizedBox(height: Ds.space.x16),
        TextField(controller: _note),
        SizedBox(height: Ds.space.x24),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: FilledButton(
            onPressed: (_item == null || num.tryParse(_qty.text) == null)
                ? null
                : () => Navigator.of(context).pop(<String, dynamic>{
                      'order_item_id': _item,
                      'qty': num.parse(_qty.text),
                      'reason_code': _reason,
                      'condition_code': _condition,
                      'note': _note.text,
                      'photo_path': _photo.text,
                    }),
            child: Text(widget.title),
          ),
        ),
      ],
    );
  }
}

class _RefundSheet extends StatefulWidget {
  final List<Map<String, dynamic>> reasons;
  final Map<String, dynamic> money;
  final String title;
  const _RefundSheet(
      {required this.reasons, required this.money, required this.title});

  @override
  State<_RefundSheet> createState() => _RefundSheetState();
}

class _RefundSheetState extends State<_RefundSheet> {
  String? _reason;
  late String _method;
  final _amount = TextEditingController();
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    // The backend picks the default method for this order (Razorpay when there
    // is a Razorpay payment to reverse, manual UPI otherwise).
    _method = _s(widget.money['default_method']);
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SheetFrame(
        title: widget.title,
        children: [
          Text(_s(widget.money['refundable_label']), style: Ds.t.title),
          SizedBox(height: Ds.space.x4),
          Text(_s(widget.money['cap_note']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          SizedBox(height: Ds.space.x16),
          DropdownButtonFormField<String>(
            initialValue: _reason,
            isExpanded: true,
            items: [
              for (final r in widget.reasons)
                DropdownMenuItem(
                    value: _s(r['code']), child: Text(_s(r['label']))),
            ],
            onChanged: (v) => setState(() => _reason = v),
          ),
          SizedBox(height: Ds.space.x16),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                  value: 'razorpay', label: Text(c('refunds.method_razorpay'))),
              ButtonSegment(
                  value: 'manual_upi',
                  label: Text(c('refunds.method_manual_upi'))),
            ],
            selected: <String>{_method},
            onSelectionChanged: (s) => setState(() => _method = s.first),
          ),
          SizedBox(height: Ds.space.x16),
          TextField(controller: _note),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: num.tryParse(_amount.text) == null
                  ? null
                  : () => Navigator.of(context).pop(<String, dynamic>{
                        'amount': num.parse(_amount.text),
                        'reason_code': _reason,
                        'method': _method,
                        'note': _note.text,
                      }),
              child: Text(widget.title),
            ),
          ),
        ],
      );
}

class _CancelSheet extends StatefulWidget {
  final List<Map<String, dynamic>> reasons;
  final String title;
  const _CancelSheet({required this.reasons, required this.title});

  @override
  State<_CancelSheet> createState() => _CancelSheetState();
}

class _CancelSheetState extends State<_CancelSheet> {
  String? _reason;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SheetFrame(
        title: widget.title,
        children: [
          RadioGroup<String>(
            groupValue: _reason,
            onChanged: (v) => setState(() => _reason = v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final r in widget.reasons)
                  RadioListTile<String>(
                    value: _s(r['code']),
                    title: Text(_s(r['label'])),
                  ),
              ],
            ),
          ),
          SizedBox(height: Ds.space.x16),
          TextField(controller: _note),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Ds.c.danger),
              onPressed: _reason == null
                  ? null
                  : () => Navigator.of(context).pop(<String, dynamic>{
                        'reason_code': _reason,
                        'note': _note.text,
                      }),
              child: Text(widget.title),
            ),
          ),
        ],
      );
}
