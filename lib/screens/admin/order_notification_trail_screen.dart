// CMD #1987 — Message trail: why an order's WhatsApp did or did not go.
//
// Order CPO140926CHA101O1 had five notification attempts on 14 Sep and not one
// of them reached the pharmacy: two were swallowed by a dedupe keyed on the
// RECIPIENT rather than the order, three reported route_disabled on routes that
// were switched on but had no template bound, and the ledger recorded two of
// them as "sent" with no provider id to point at. Nobody could see any of that
// without opening the database.
//
// This screen is that view. It renders ONE payload, order_notification_trail():
//   • mode 'list'      — the active zone + active date's orders, each with its
//                        own one-line summary, so the screen is usable without
//                        knowing a code;
//   • mode 'order'     — every attempt on one order, newest first, each row
//                        carrying the path that tried to carry it, the status
//                        and the reason;
//   • mode 'not_found' — the backend's own empty copy.
//
// Every string on this page is the backend's. The labels and tones of the
// status / path / reason chips come from notif_trail_label, so re-wording
// "Duplicate" is an UPDATE, not a deploy. This file decides exactly two things:
// which of the three modes to lay out, and what a tone name paints as.
//
// Mobile-first: laid out at 360 px first — one column, the search field full
// width above the list, every chip in a Wrap so a long reason never pushes the
// row sideways, and no tap target under 44 px.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

/// The one backend call this surface makes, behind a test seam.
class OrderNotificationTrailTransport {
  OrderNotificationTrailTransport._();

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)? rpc;

  static Future<dynamic> call(String fn, [Map<String, dynamic>? params]) {
    final t = rpc;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }
}

class OrderNotificationTrailScreen extends StatefulWidget {
  /// Opens straight onto one order when the caller already knows it.
  final String? orderId;
  final String? orderCode;

  const OrderNotificationTrailScreen({super.key, this.orderId, this.orderCode});

  @override
  State<OrderNotificationTrailScreen> createState() =>
      _OrderNotificationTrailScreenState();
}

class _OrderNotificationTrailScreenState
    extends State<OrderNotificationTrailScreen> {
  Map<String, dynamic>? _p;
  String? _error;
  bool _loading = true;

  late final TextEditingController _search =
      TextEditingController(text: widget.orderCode ?? '');

  String? _orderId;

  @override
  void initState() {
    super.initState();
    _orderId = widget.orderId;
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final code = _search.text.trim();
      final res = await OrderNotificationTrailTransport.call(
        'order_notification_trail',
        <String, dynamic>{
          'p_order_id': _orderId,
          'p_order_code': code.isEmpty ? null : code,
        },
      );
      final map = (res is Map) ? Map<String, dynamic>.from(res) : null;
      if (!mounted) return;
      setState(() {
        _p = map;
        _loading = false;
      });
      RenderLog.write('notif_trail_mode', map?['mode']);
      RenderLog.write(
          'notif_trail_rows',
          (map?['rows'] as List?)?.length ??
              (map?['orders'] as List?)?.length ??
              0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _openOrder(String? id, String? code) {
    setState(() {
      _orderId = id;
      _search.text = code ?? '';
    });
    _load();
  }

  void _backToList() {
    setState(() {
      _orderId = null;
      _search.text = '';
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final forbidden = p != null && p['ok'] == false;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(
            (p?['title'] as String?) ?? c('notif_trail.nav_label'),
            style: Ds.t.subtitle),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x48),
          children: [
            if (p?['subtitle'] != null)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Text('${p!['subtitle']}', style: Ds.t.caption),
              ),
            _SearchBar(
              controller: _search,
              hint: '${(p?['search'] as Map?)?['hint'] ?? ''}',
              buttonLabel: '${(p?['search'] as Map?)?['button_label'] ?? ''}',
              onSubmit: () {
                _orderId = null;
                _load();
              },
            ),
            SizedBox(height: Ds.space.x24),
            if (_loading)
              const _TrailSkeleton()
            else if (_error != null)
              _ErrorBlock(message: _error!, onRetry: _load)
            else if (forbidden)
              _EmptyBlock(
                  label: '${p['message'] ?? ''}', hint: '')
            else if (p == null)
              _EmptyBlock(label: c('notif_trail.loading'), hint: '')
            else
              ..._modeChildren(p),
          ],
        ),
      ),
    );
  }

  List<Widget> _modeChildren(Map<String, dynamic> p) {
    switch ('${p['mode']}') {
      case 'list':
        final orders = (p['orders'] as List?) ?? const [];
        if (orders.isEmpty) {
          return [
            _EmptyBlock(
                label: '${p['empty_label'] ?? ''}',
                hint: '${p['empty_hint'] ?? ''}')
          ];
        }
        return [
          _SectionLabel('${p['rows_label'] ?? ''}'),
          SizedBox(height: Ds.space.x12),
          for (final o in orders)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: _OrderCard(
                data: Map<String, dynamic>.from(o as Map),
                onTap: () => _openOrder(
                    '${(o)['id']}', '${(o)['code_label'] ?? ''}'),
              ),
            ),
        ];
      case 'order':
        final rows = (p['rows'] as List?) ?? const [];
        return [
          _OrderHeader(
            order: Map<String, dynamic>.from((p['order'] as Map?) ?? const {}),
            summaryLabel: '${p['summary_label'] ?? ''}',
            summaryTone: '${p['summary_tone'] ?? 'neutral'}',
            onBack: _backToList,
          ),
          SizedBox(height: Ds.space.x24),
          if (rows.isEmpty)
            _EmptyBlock(
                label: '${p['empty_label'] ?? ''}',
                hint: '${p['empty_hint'] ?? ''}')
          else ...[
            _SectionLabel('${p['rows_label'] ?? ''}'),
            SizedBox(height: Ds.space.x12),
            for (final r in rows)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: _AttemptCard(
                    data: Map<String, dynamic>.from(r as Map)),
              ),
          ],
        ];
      default:
        return [
          _EmptyBlock(
              label: '${p['empty_label'] ?? ''}',
              hint: '${p['empty_hint'] ?? ''}')
        ];
    }
  }
}

// ── tone ─────────────────────────────────────────────────────────────────────
// The only computation this file is allowed: a tone NAME the backend sent turned
// into the token pair it paints as.

class _Tone {
  final Color bg;
  final Color fg;
  const _Tone(this.bg, this.fg);

  static _Tone of(String? name) {
    switch (name) {
      case 'success':
        return _Tone(Ds.c.successSoft, Ds.c.success);
      case 'warning':
        return _Tone(Ds.c.warningSoft, Ds.c.warning);
      case 'danger':
        return _Tone(Ds.c.dangerSoft, Ds.c.danger);
      case 'info':
        return _Tone(Ds.c.infoSoft, Ds.c.info);
      default:
        return _Tone(Ds.c.bg, Ds.c.textSecondary);
    }
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String? tone;
  const _Chip(this.label, this.tone);

  @override
  Widget build(BuildContext context) {
    final t = _Tone.of(tone);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: t.bg, borderRadius: Ds.r.rChip),
      child: Text(label, style: Ds.t.caption.copyWith(color: t.fg)),
    );
  }
}

// ── pieces ───────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(text, style: Ds.t.caption);
}

class _Card extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _Card({required this.child, this.onTap});

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: child,
    );
    if (onTap == null) return box;
    return Material(
      color: Colors.transparent,
      child: InkWell(
          onTap: onTap, borderRadius: Ds.r.rCard, child: box),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final String buttonLabel;
  final VoidCallback onSubmit;

  const _SearchBar({
    required this.controller,
    required this.hint,
    required this.buttonLabel,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    // 360 px first: the field takes the row and the button sits under it, so a
    // long hint never squeezes either into two words per line.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          textInputAction: TextInputAction.search,
          textCapitalization: TextCapitalization.characters,
          onSubmitted: (_) => onSubmit(),
          decoration: InputDecoration(hintText: hint),
        ),
        SizedBox(height: Ds.space.x12),
        SizedBox(
          height: Ds.space.x48,
          child: FilledButton(
            onPressed: onSubmit,
            child: Text(buttonLabel),
          ),
        ),
      ],
    );
  }
}

class _OrderCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final VoidCallback onTap;
  const _OrderCard({required this.data, required this.onTap});

  @override
  Widget build(BuildContext context) => _Card(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${data['code_label'] ?? ''}',
                      style: Ds.t.bodyStrong),
                ),
                SizedBox(width: Ds.space.x8),
                Text('${data['when_label'] ?? ''}', style: Ds.t.caption),
              ],
            ),
            SizedBox(height: Ds.space.x4),
            Text('${data['customer_label'] ?? ''}',
                style: Ds.t.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
            SizedBox(height: Ds.space.x12),
            _Chip('${data['summary_label'] ?? ''}', '${data['tone'] ?? ''}'),
          ],
        ),
      );
}

class _OrderHeader extends StatelessWidget {
  final Map<String, dynamic> order;
  final String summaryLabel;
  final String summaryTone;
  final VoidCallback onBack;

  const _OrderHeader({
    required this.order,
    required this.summaryLabel,
    required this.summaryTone,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${order['code_label'] ?? ''}', style: Ds.t.title),
            SizedBox(height: Ds.space.x4),
            Text('${order['customer_label'] ?? ''}', style: Ds.t.bodySecondary),
            SizedBox(height: Ds.space.x4),
            Text('${order['when_label'] ?? ''} · ${order['status_label'] ?? ''}',
                style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                _Chip(summaryLabel, summaryTone),
              ],
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.space.x48,
              child: OutlinedButton(
                onPressed: onBack,
                child: Text(c('notif_trail.back')),
              ),
            ),
          ],
        ),
      );
}

class _AttemptCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _AttemptCard({required this.data});

  Map<String, dynamic>? _sub(String key) {
    final v = data[key];
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  @override
  Widget build(BuildContext context) {
    final status = _sub('status');
    final path = _sub('path');
    final reason = _sub('reason');
    final provider = data['provider_label'];
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text('${data['event_label'] ?? ''}',
                    style: Ds.t.bodyStrong),
              ),
              SizedBox(width: Ds.space.x8),
              Text('${data['when_label'] ?? ''}', style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          // Every chip the payload sent, in a Wrap: at 360 px a long reason
          // drops to its own line instead of shrinking the row.
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              if (status != null)
                _Chip('${status['label']}', '${status['tone']}'),
              if (path != null) _Chip('${path['label']}', '${path['tone']}'),
              if (reason != null)
                _Chip('${reason['label']}', '${reason['tone']}'),
            ],
          ),
          if (status?['note'] != null) ...[
            SizedBox(height: Ds.space.x12),
            Text('${status!['note']}', style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x8),
          Text(
            provider == null
                ? '${data['source_label'] ?? ''}'
                : '${data['source_label'] ?? ''} · $provider',
            style: Ds.t.caption,
          ),
        ],
      ),
    );
  }
}

class _EmptyBlock extends StatelessWidget {
  final String label;
  final String hint;
  const _EmptyBlock({required this.label, required this.hint});

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Ds.t.bodyStrong),
            if (hint.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(hint, style: Ds.t.caption),
            ],
          ],
        ),
      );
}

class _ErrorBlock extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBlock({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: Ds.t.body),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.space.x48,
              child: OutlinedButton(
                onPressed: onRetry,
                child: Text(c('notif_trail.retry')),
              ),
            ),
          ],
        ),
      );
}

/// A skeleton, not a bare spinner: three card-shaped blocks in the rhythm the
/// real rows will land in.
class _TrailSkeleton extends StatelessWidget {
  const _TrailSkeleton();

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Container(
                height: Ds.space.x48 * 2,
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rCard,
                ),
              ),
            ),
        ],
      );
}
