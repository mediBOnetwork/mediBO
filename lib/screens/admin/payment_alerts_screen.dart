// CMD #1930 — THE PAYMENT ALERTS QUEUE.
//
// #1929 reads the partner phone's payment notifications and matches most of
// them by itself. This is the screen for the ones it could not decide, and it
// decides nothing of its own:
//
//   * the rows, their status chips, their tones and every label arrive
//     finished from payment_alerts_screen();
//   * "Link to claim" opens the backend's OWN ranked candidate list
//     (payment_alert_link_options) — the ranking, and the wording of how far
//     each candidate is from the alert, are the backend's;
//   * every button on a card is present only because the payload named it:
//     a matched alert sends an empty retry/ignore label and the button is gone.
//
// Nothing here is computed, pluralised, formatted or coloured by Dart.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/payment_alerts_service.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import 'payment_alert_rules_screen.dart';
import 'payment_devices_section.dart';

String _s(Object? v) => v == null ? '' : v.toString().trim();

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

/// The backend's tone words, mapped onto the design tokens and nowhere else.
Color payAlertTone(String tone) {
  switch (tone) {
    case 'bad':
    case 'danger':
      return Ds.c.danger;
    case 'warn':
    case 'warning':
      return Ds.c.warning;
    case 'good':
    case 'success':
      return Ds.c.success;
    case 'info':
      return Ds.c.info;
    default:
      return Ds.c.textSecondary;
  }
}

Color payAlertToneSoft(String tone) {
  switch (tone) {
    case 'bad':
    case 'danger':
      return Ds.c.dangerSoft;
    case 'warn':
    case 'warning':
      return Ds.c.warningSoft;
    case 'good':
    case 'success':
      return Ds.c.successSoft;
    case 'info':
      return Ds.c.infoSoft;
    default:
      return Ds.c.bg;
  }
}

class PaymentAlertsScreen extends StatefulWidget {
  const PaymentAlertsScreen({
    super.key,
    this.rpc,
    this.devicesRpc,
    this.screenRpc,
    this.setStatusRpc,
    this.isSuperAdmin = false,
  });

  /// Injected in tests so the screen is proven against a payload, not a network.
  final PayAlertRpc? rpc;

  /// CMD #2050 — the Devices section's own narrow seam. It is deliberately NOT
  /// [rpc]: a test that pumps the queue against a queue payload must not have
  /// that payload answer the device list too.
  final PayAlertRpc? devicesRpc;

  /// CMD #1929's two narrow doors, kept verbatim: the protected suite pumps
  /// this screen through them, and a rewrite that widened the injection point
  /// must not also change the contract a green test already pins. Either is
  /// consulted before [rpc] for the one call it stands for.
  final Future<Map<String, dynamic>> Function(String? status)? screenRpc;
  final Future<Map<String, dynamic>> Function(String id, String status)?
      setStatusRpc;

  /// Only a super admin is offered the parser editor. The RPCs behind it gate
  /// on the role themselves and render their own refusal — this only decides
  /// whether the door is drawn.
  final bool isSuperAdmin;

  @override
  State<PaymentAlertsScreen> createState() => _PaymentAlertsScreenState();
}

class _PaymentAlertsScreenState extends State<PaymentAlertsScreen> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;
  String _error = '';
  /// The refusal carries its OWN retry wording; the last good payload's copy
  /// must not be what the error box prints, and neither may a Dart literal.
  String _retryLabel = '';
  String _filter = '';
  String _busy = '';
  /// Which switch is mid-flight. One at a time: the screen reloads after each
  /// save, because the backend recomputes the count line and the allow-list.
  String _switching = '';
  bool _appsOpen = false;

  Future<Map<String, dynamic>> _call(
    String fn,
    Map<String, dynamic> args,
  ) async {
    if (fn == 'payment_alerts_screen' && widget.screenRpc != null) {
      final status = args['p_status'];
      return widget.screenRpc!(status is String ? status : null);
    }
    if (fn == 'payment_alert_set_status' && widget.setStatusRpc != null) {
      return widget.setStatusRpc!(
        '${args['p_alert_id'] ?? ''}',
        '${args['p_status'] ?? ''}',
      );
    }
    return (widget.rpc ?? payAlertLiveRpc)(fn, args);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> res;
    try {
      res = await _call('payment_alerts_screen', {
        if (_filter.isNotEmpty) 'p_status': _filter,
      });
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _retryLabel = _s(res['retry_label']);
      if (res['ok'] == true) {
        _payload = res;
        _error = '';
      } else {
        _error = _s(res['message']).isNotEmpty
            ? _s(res['message'])
            : _s(res['error']);
      }
    });
    RenderLog.write('c1930_alert_rows', _rows(_payload['rows']).length);
  }

  Future<void> _act(String alertId, String fn, Map<String, dynamic> args) async {
    setState(() => _busy = alertId);
    Map<String, dynamic> res;
    try {
      res = await _call(fn, args);
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _busy = '');
    final msg = _s(res['toast']).isNotEmpty ? _s(res['toast']) : _s(res['message']);
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    await _load();
  }

  Future<void> _openLinkSheet(Map<String, dynamic> row) async {
    final alertId = _s(row['alert_id']);
    setState(() => _busy = alertId);
    Map<String, dynamic> res;
    try {
      res = await _call('payment_alert_link_options', {'p_alert_id': alertId});
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _busy = '');
    if (res['ok'] != true) {
      final msg = _s(res['message']).isNotEmpty ? _s(res['message']) : _s(res['error']);
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
      return;
    }
    RenderLog.write('c1930_link_sheet', 1);
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _LinkSheet(payload: res),
    );
    if (picked != null && picked.isNotEmpty) {
      await _act(alertId, 'payment_alert_link', {
        'p_alert_id': alertId,
        'p_claim_id': picked,
      });
    }
  }

  /// One app on or off. The patch is the id and the flag — the same shape the
  /// parser screen sends — and the screen reloads so the count line, the
  /// device allow-list and the switch all come back from the backend.
  Future<void> _setApp(Map<String, dynamic> app, bool on) async {
    final key = 'app_${_s(app['id'])}';
    setState(() => _switching = key);
    Map<String, dynamic> res;
    try {
      res = await _call('payment_alert_rule_save', {
        'p_patch': {'id': app['id'], 'enabled': on},
      });
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _switching = '');
    _toast(res);
    await _load();
  }

  Future<void> _setUtr(bool on) async {
    setState(() => _switching = 'utr');
    Map<String, dynamic> res;
    try {
      res = await _call('payment_alert_utr_set', {'p_on': on});
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _switching = '');
    _toast(res);
    await _load();
  }

  /// The backend's own word for what just happened, or nothing.
  void _toast(Map<String, dynamic> res) {
    final msg = _s(res['toast']).isNotEmpty
        ? _s(res['toast'])
        : _s(res['message']).isNotEmpty
            ? _s(res['message'])
            : _s(res['error']);
    if (msg.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final filters = _rows(_payload['filters']);
    final rows = _rows(_payload['rows']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(_payload['title'])),
        actions: [
          if (widget.isSuperAdmin)
            IconButton(
              tooltip: c('pay_alert.rules_label'),
              icon: const Icon(Icons.rule_folder_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PaymentAlertRulesScreen(rpc: widget.rpc),
                ),
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        // A Column inside a scroll view, not a lazy ListView: the queue is
        // capped at 60 rows by the RPC, and a card that is merely OFF-SCREEN
        // must still exist — "the row never built" and "Dart dropped the row"
        // look identical from the outside, and the second is the bug this
        // screen exists to make impossible.
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
            if (_s(_payload['subtitle']).isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x4),
                child: Text(_s(_payload['subtitle']), style: Ds.t.caption),
              ),
            if (_s(_payload['count_label']).isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x16),
                child: Text(_s(_payload['count_label']), style: Ds.t.caption),
              ),
            // CMD #2093 — what is collecting the money, before anything about
            // what was heard. Both lines are the backend's.
            if (_map(_payload['header']).isNotEmpty) ...[
              _CollectionHeader(block: _map(_payload['header'])),
              SizedBox(height: Ds.space.x12),
            ],
            // CMD #2093 — the switch that killed the ₹50,000 PhonePe ad.
            if (_map(_payload['utr']).isNotEmpty) ...[
              _UtrCard(
                block: _map(_payload['utr']),
                busy: _switching == 'utr',
                onChanged: _setUtr,
              ),
              SizedBox(height: Ds.space.x12),
            ],
            // CMD #2093 — which apps this phone is even allowed to read.
            if (_map(_payload['apps']).isNotEmpty) ...[
              _AppsCard(
                block: _map(_payload['apps']),
                open: _appsOpen,
                switching: _switching,
                onToggleOpen: () => setState(() => _appsOpen = !_appsOpen),
                onChanged: _setApp,
              ),
              SizedBox(height: Ds.space.x12),
            ],
            // CMD #2050 — the Devices section. Nothing fed this queue before
            // it existed: payment_alert_device had zero rows because no screen
            // ever paired a phone. Drawn ABOVE the queue so an empty queue is
            // explained by the thing that causes it.
            PaymentDevicesSection(rpc: widget.devicesRpc),
            if (filters.isNotEmpty) ...[
              _FilterRow(
                filters: filters,
                active: _s(_payload['active_filter']),
                onTap: (k) {
                  setState(() => _filter = k);
                  _load();
                },
              ),
              SizedBox(height: Ds.space.x16),
            ],
            if (_loading)
              const _Skeleton()
            else if (_error.isNotEmpty)
              _ErrorBox(message: _error, retryLabel: _retryLabel, onRetry: _load)
            else if (rows.isEmpty)
              _EmptyBox(
                label: _s(_payload['empty_label']),
                hint: _s(_payload['empty_hint']),
              )
            else
              for (final r in rows)
                Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x12),
                  child: _AlertCard(
                    row: r,
                    busy: _busy == _s(r['alert_id']),
                    onLink: () => _openLinkSheet(r),
                    onIgnore: () => _act(_s(r['alert_id']), 'payment_alert_set_status', {
                      'p_alert_id': _s(r['alert_id']),
                      'p_status': 'ignored',
                    }),
                    onRetry: () => _act(_s(r['alert_id']), 'payment_alert_set_status', {
                      'p_alert_id': _s(r['alert_id']),
                      'p_status': 'new',
                    }),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── The filter chips ─────────────────────────────────────────────────────────
// The caption of each chip is ONE backend string (chip_label): Dart never joins
// a label to a count.
class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.filters, required this.active, required this.onTap});

  final List<Map<String, dynamic>> filters;
  final String active;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final f in filters)
            Padding(
              padding: EdgeInsets.only(right: Ds.space.x8),
              child: _Chip(
                label: _s(f['chip_label']).isNotEmpty
                    ? _s(f['chip_label'])
                    : _s(f['label']),
                selected: _s(f['key']) == active,
                onTap: () => onTap(_s(f['key'])),
              ),
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        decoration: BoxDecoration(
          color: selected ? Ds.c.brand : Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
        ),
        child: Text(
          label,
          style: Ds.t.body.copyWith(color: selected ? Ds.c.surface : Ds.c.text),
        ),
      ),
    );
  }
}

// ── One alert ────────────────────────────────────────────────────────────────
class _AlertCard extends StatelessWidget {
  const _AlertCard({
    required this.row,
    required this.busy,
    required this.onLink,
    required this.onIgnore,
    required this.onRetry,
  });

  final Map<String, dynamic> row;
  final bool busy;
  final VoidCallback onLink;
  final VoidCallback onIgnore;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tone = _s(row['status_tone']);
    final ignoreLabel = _s(row['ignore_label']);
    final linkLabel = _s(row['link_label']);
    final retryLabel = _s(row['retry_match_label']);
    final orderCode = _s(row['order_code']);
    final customer = _s(row['customer_label']);
    final reason = _s(row['match_reason']);

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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(_s(row['amount_label']), style: Ds.t.title),
              ),
              SizedBox(width: Ds.space.x8),
              _StatusPill(label: _s(row['status_label']), tone: tone),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          // app_label is which app sent it; source_label is HOW it was read
          // (a parser rule, or the AI fallback). Both are backend words and
          // both belong on the card — the second is how an admin knows which
          // rule to go and fix.
          // Two words, two Text widgets: joining them in Dart would invent a
          // separator the backend never sent, and neither half could then be
          // reworded by an ui_copy UPDATE on its own.
          Wrap(
            spacing: Ds.space.x12,
            children: [
              if (_s(row['app_label']).isNotEmpty)
                Text(_s(row['app_label']), style: Ds.t.caption),
              if (_s(row['source_label']).isNotEmpty)
                Text(_s(row['source_label']), style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          _KeyLine(label: _s(row['posted_label'])),
          _KeyLine(label: _s(row['utr_label'])),
          _KeyLine(label: _s(row['sender_label'])),
          if (orderCode.isNotEmpty || customer.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: payAlertToneSoft('success'),
                borderRadius: Ds.r.rButton,
              ),
              // CMD #1929 pinned this as ONE line, customer then code: the
              // matched claim reads as a sentence, not as two stacked fields.
              child: Text(
                [customer, orderCode].where((w) => w.isNotEmpty).join(' · '),
                style: Ds.t.bodyStrong,
              ),
            ),
          ],
          if (reason.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(reason, style: Ds.t.caption),
          ],
          if (busy) ...[
            SizedBox(height: Ds.space.x12),
            const LinearProgressIndicator(minHeight: 2),
          ] else if (linkLabel.isNotEmpty ||
              ignoreLabel.isNotEmpty ||
              retryLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            // Wrap, not Row: at 360 px three actions do not fit one line, and a
            // button that clips is a button nobody presses.
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                if (linkLabel.isNotEmpty)
                  // The card offers a link only while the alert is still
                  // open, and the payload says so by sending the label at all.
                  _Action(label: linkLabel, primary: true, onTap: onLink),
                if (retryLabel.isNotEmpty)
                  _Action(label: retryLabel, primary: false, onTap: onRetry),
                if (ignoreLabel.isNotEmpty)
                  _Action(
                    label: ignoreLabel,
                    primary: false,
                    icon: Icons.block,
                    onTap: onIgnore,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _KeyLine extends StatelessWidget {
  const _KeyLine({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x4),
      child: Text(label, style: Ds.t.body),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.tone});
  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x12,
        vertical: Ds.space.x4,
      ),
      decoration: BoxDecoration(
        color: payAlertToneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(
        label,
        style: Ds.t.caption.copyWith(color: payAlertTone(tone)),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.primary,
    required this.onTap,
    this.icon,
  });
  final String label;
  final bool primary;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final text = Text(label);
    return SizedBox(
      height: 44,
      child: primary
          ? FilledButton(onPressed: onTap, child: text)
          : icon == null
              ? OutlinedButton(onPressed: onTap, child: text)
              : OutlinedButton.icon(
                  onPressed: onTap,
                  icon: Icon(icon, size: 18),
                  label: text,
                ),
    );
  }
}

// ── The link sheet: the backend's own ranked candidates ──────────────────────
class _LinkSheet extends StatelessWidget {
  const _LinkSheet({required this.payload});
  final Map<String, dynamic> payload;

  @override
  Widget build(BuildContext context) {
    final rows = _rows(payload['rows']);
    RenderLog.write('c1930_link_rows', rows.length);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(payload['title']), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Text(_s(payload['subtitle']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            if (rows.isEmpty)
              _EmptyBox(
                label: _s(payload['empty_label']),
                hint: _s(payload['empty_hint']),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => SizedBox(height: Ds.space.x8),
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    return InkWell(
                      onTap: () => Navigator.pop(context, _s(r['claim_id'])),
                      borderRadius: Ds.r.rCard,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 44),
                        padding: EdgeInsets.all(Ds.space.x12),
                        decoration: BoxDecoration(
                          color: Ds.c.bg,
                          borderRadius: Ds.r.rCard,
                          border: Border.all(color: Ds.c.divider),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(_s(r['title_label']),
                                      style: Ds.t.bodyStrong),
                                ),
                                SizedBox(width: Ds.space.x8),
                                Text(_s(r['amount_label']), style: Ds.t.bodyStrong),
                              ],
                            ),
                            SizedBox(height: Ds.space.x4),
                            Text('${_s(r['order_label'])}  ·  ${_s(r['time_label'])}',
                                style: Ds.t.caption),
                            SizedBox(height: Ds.space.x4),
                            Text(
                              _s(r['delta_label']),
                              style: Ds.t.caption.copyWith(
                                color: payAlertTone(_s(r['delta_tone'])),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: Text(_s(payload['cancel_label'])),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── States ───────────────────────────────────────────────────────────────────
class _EmptyBox extends StatelessWidget {
  const _EmptyBox({required this.label, required this.hint});
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        children: [
          Text(label, style: Ds.t.body, textAlign: TextAlign.center),
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(hint, style: Ds.t.caption, textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({
    required this.message,
    required this.retryLabel,
    required this.onRetry,
  });

  final String message;
  final String retryLabel;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
        color: Ds.c.dangerSoft,
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        children: [
          Text(message, style: Ds.t.body, textAlign: TextAlign.center),
          if (retryLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              height: 44,
              child: OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
            ),
          ],
        ],
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: 96,
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
              ),
            ),
          ),
      ],
    );
  }
}

// ── CMD #2093: the header, the UTR switch and the app picker ─────────────────
//
// Three blocks, one rule between them: nothing below decides anything. The
// mode, the UPI id, the hint under the switch, the group headings, the order
// of the apps and the count line all arrive finished in the payload. A switch
// here sends a flag and redraws whatever comes back.

/// What is collecting the money right now: the mode, and the UPI id it lands on.
class _CollectionHeader extends StatelessWidget {
  const _CollectionHeader({required this.block});

  final Map<String, dynamic> block;

  @override
  Widget build(BuildContext context) {
    final upi = _s(block['upi_value']);
    RenderLog.write('c2093_mode_header', 1);
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
          // At 360 px the mode pill and the title do not always share a line,
          // so they wrap instead of squeezing the pill to nothing.
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              Text(_s(block['title']), style: Ds.t.caption),
              _StatusPill(
                label: _s(block['mode_label']),
                tone: _s(block['mode_tone']),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Text(_s(block['upi_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(
            upi,
            style: block['has_upi'] == true ? Ds.t.subtitle : Ds.t.body,
          ),
          if (_s(block['upi_name']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(block['upi_name']), style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

/// "Look for UTR". On, a credit with no reference number never reaches the
/// queue — the hint under it says which of the two states is in force, and
/// that sentence is the backend's, not a Dart ternary over two literals.
class _UtrCard extends StatelessWidget {
  const _UtrCard({
    required this.block,
    required this.busy,
    required this.onChanged,
  });

  final Map<String, dynamic> block;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final on = block['on'] == true;
    final canEdit = block['can_edit'] == true;
    RenderLog.write('c2093_utr_toggle', on ? 1 : 0);
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
          Row(
            children: [
              Expanded(child: Text(_s(block['title']), style: Ds.t.subtitle)),
              SizedBox(width: Ds.space.x12),
              SizedBox(
                height: 44,
                child: Center(
                  child: busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Semantics(
                          identifier: 'pay_alert_utr_switch',
                          child: Switch(
                            value: on,
                            onChanged: canEdit ? onChanged : null,
                          ),
                        ),
                ),
              ),
            ],
          ),
          if (_s(block['hint']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(block['hint']), style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

/// Every app rule with a switch, in the backend's order: the merchant apps
/// that hear a real shop payment first, then the banks, then the personal apps
/// that also announce ads and chats. A group heading is drawn when the kind
/// changes — Dart never sorts and never names a group itself.
class _AppsCard extends StatelessWidget {
  const _AppsCard({
    required this.block,
    required this.open,
    required this.switching,
    required this.onToggleOpen,
    required this.onChanged,
  });

  final Map<String, dynamic> block;
  final bool open;
  final String switching;
  final VoidCallback onToggleOpen;
  final void Function(Map<String, dynamic> app, bool on) onChanged;

  @override
  Widget build(BuildContext context) {
    final apps = _rows(block['rows']);
    final canEdit = block['can_edit'] == true;
    RenderLog.write('c2093_app_rows', apps.length);
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
          Semantics(
            identifier: 'pay_alert_apps_header',
            child: InkWell(
              onTap: onToggleOpen,
              borderRadius: Ds.r.rButton,
              // A MINIMUM of 44, never a fixed 44: two lines of text at a
              // large system font size are taller than the touch floor, and a
              // fixed box clips them instead of growing.
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_s(block['title']), style: Ds.t.subtitle),
                          if (_s(block['count_label']).isNotEmpty)
                            Text(_s(block['count_label']), style: Ds.t.caption),
                        ],
                      ),
                    ),
                    Icon(open ? Icons.expand_less : Icons.expand_more),
                  ],
                ),
              ),
            ),
          ),
          if (open) ...[
            if (_s(block['hint']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(_s(block['hint']), style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x8),
            if (apps.isEmpty)
              Text(_s(block['empty_label']), style: Ds.t.body)
            else
              // The heading is drawn where the payload's OWN order changes
              // kind. Dart reads the boundary; it never creates one.
              for (var i = 0; i < apps.length; i++) ...[
                if (i == 0 ||
                    _s(apps[i]['kind_label']) != _s(apps[i - 1]['kind_label'])) ...[
                  SizedBox(height: i == 0 ? Ds.space.x4 : Ds.space.x16),
                  Text(_s(apps[i]['kind_label']), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x4),
                ],
                _AppRow(
                  app: apps[i],
                  canEdit: canEdit && apps[i]['can_edit'] == true,
                  busy: switching == 'app_${_s(apps[i]['id'])}',
                  onChanged: (on) => onChanged(apps[i], on),
                ),
              ],
          ],
        ],
      ),
    );
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.canEdit,
    required this.busy,
    required this.onChanged,
  });

  final Map<String, dynamic> app;
  final bool canEdit;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final on = app['enabled'] == true;
    return ConstrainedBox(
      // A FLOOR of 56, not a fixed height: the row carries two lines of text
      // and still has to leave a 44 px target for the switch inside it, and at
      // a large system font size those two lines are taller than 56.
      constraints: const BoxConstraints(minHeight: 56),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _s(app['label']),
                  style: Ds.t.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _s(app['package_name']),
                  style: Ds.t.caption,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x8),
          Text(
            _s(app['state_label']),
            style: Ds.t.caption.copyWith(color: payAlertTone(_s(app['state_tone']))),
          ),
          SizedBox(
            height: 44,
            child: Center(
              child: busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Semantics(
                      identifier: 'pay_alert_app_${_s(app['id'])}',
                      child: Switch(
                        value: on,
                        onChanged: canEdit ? onChanged : null,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
