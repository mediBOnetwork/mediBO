import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #229 — the admin surface over order closure.
///
/// Closure itself never happens here. It is decided in the backend by
/// `_order_close_state` / `_supplier_settle_state` and executed by triggers
/// and `order_lifecycle_tick()`. This screen only prints what those two
/// engines already returned: the gates, the blockers, the closed stamp, the
/// backfill count, and — when a human takes responsibility for a blocked
/// order — the override, whose reason the backend requires and logs.
///
/// Every string here (titles, tabs, gate names, empty states, the override
/// copy, the toast) arrives in the payload from the `order_closure_label`
/// table. The only thing this file maps is a backend `tone` onto a token.
class AdminOrderClosureScreen extends StatefulWidget {
  const AdminOrderClosureScreen({super.key});

  @override
  State<AdminOrderClosureScreen> createState() =>
      _AdminOrderClosureScreenState();
}

/// The backend names a tone; the token layer owns what that colour is.
Color _toneColor(Object? tone) {
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

Color _toneSoft(Object? tone) {
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

/// The two supplier tabs render supplier orders; everything else renders
/// customer orders. The backend tells us which via each row's own `kind`, so
/// this is only used to pick the detail RPC argument.
String _kindOf(Map row) => '${row['kind'] ?? 'order'}';

class _AdminOrderClosureScreenState extends State<AdminOrderClosureScreen> {
  Map<String, dynamic>? _data;
  Object? _error;
  bool _loading = true;
  String _tab = 'blocked';

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
      final res = await Supabase.instance.client.rpc('admin_order_closure_list',
          params: {'p_filter': _tab, 'p_limit': 60});
      setState(() {
        _data = Map<String, dynamic>.from(res as Map);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final tabs = (d?['tabs'] as List?) ?? const [];
    final rows = (d?['rows'] as List?) ?? const [];

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        foregroundColor: Ds.c.text,
        elevation: 0,
        title: Text('${d?['title'] ?? ''}',
            style: Ds.t.title.copyWith(color: Ds.c.text)),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: Column(children: [
          if (tabs.isNotEmpty)
            Container(
              width: double.infinity,
              color: Ds.c.surface,
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16, vertical: Ds.space.x8),
              child: Wrap(
                spacing: Ds.space.x8,
                runSpacing: Ds.space.x8,
                children: [
                  for (final t in tabs)
                    _TabChip(
                      label: '${(t as Map)['label'] ?? ''}',
                      selected: _tab == '${t['key']}',
                      onTap: () {
                        setState(() => _tab = '${t['key']}');
                        _load();
                      },
                    ),
                ],
              ),
            ),
          Expanded(child: _body(d, rows)),
        ]),
      ),
    );
  }

  Widget _body(Map<String, dynamic>? d, List rows) {
    // Reachability proof: a canvas app cannot be clicked by any tool, so the
    // screen reports itself. `curl https://medibo.in/render-log` shows
    // c229_order_closure_screen once an admin has opened it.
    RenderLog.write('c229_order_closure_screen', 1);
    if (_loading) return const _Skeleton();
    if (_error != null || d?['ok'] != true) {
      return _ErrorState(
        message: '${d?['error'] ?? _error ?? ''}',
        retryLabel: '${d?['retry_label'] ?? ''}',
        onRetry: _load,
      );
    }
    RenderLog.write('c229_order_closure_rows', rows.length);
    final backfill = Map<String, dynamic>.from((d?['backfill'] as Map?) ?? {});

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        if ('${d?['subtitle'] ?? ''}'.isNotEmpty)
          Text('${d?['subtitle']}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        SizedBox(height: Ds.space.x16),
        _BackfillCard(backfill: backfill, note: '${d?['auto_note'] ?? ''}'),
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
            child: Text('${d?['empty_label'] ?? ''}',
                textAlign: TextAlign.center,
                style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
          )
        else
          for (final r in rows) ...[
            _ClosureCard(
              row: Map<String, dynamic>.from(r as Map),
              onOpen: () => _openDetail(Map<String, dynamic>.from(r)),
            ),
            SizedBox(height: Ds.space.x12),
          ],
      ],
    );
  }

  Future<void> _openDetail(Map<String, dynamic> row) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (_) => _ClosureDetailSheet(kind: _kindOf(row), id: '${row['id']}'),
    );
    if (mounted) _load();
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Ds.r.chip),
        // CHANGE #229 (auto-heal) — a Container with `alignment:` set expands
        // to fill the loose constraints Wrap hands it, so all four tabs came
        // out full-width and stacked, eating 260px of a 1280px screen. Align
        // with widthFactor: 1 sizes to the label instead, and the SizedBox
        // keeps the 44px touch target the design contract requires.
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          decoration: BoxDecoration(
            color: selected ? Ds.c.brandSoft : Ds.c.bg,
            borderRadius: BorderRadius.circular(Ds.r.chip),
            border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
          ),
          child: SizedBox(
            height: Ds.touch.minTarget,
            child: Align(
              alignment: Alignment.center,
              widthFactor: 1,
              child: Text(label,
                  style: Ds.t.caption.copyWith(
                      color: selected ? Ds.c.brand : Ds.c.textSecondary,
                      fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      );
}

class _ToneChip extends StatelessWidget {
  final String label;
  final Object? tone;
  const _ToneChip({required this.label, this.tone});

  @override
  Widget build(BuildContext context) => Container(
        padding:
            EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: _toneSoft(tone),
          borderRadius: BorderRadius.circular(Ds.r.chip),
        ),
        child: Text(label,
            style: Ds.t.caption
                .copyWith(color: _toneColor(tone), fontWeight: FontWeight.w600)),
      );
}

/// The "would close today" count. It is a REPORT — nothing on this card acts.
class _BackfillCard extends StatelessWidget {
  final Map<String, dynamic> backfill;
  final String note;
  const _BackfillCard({required this.backfill, required this.note});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: BorderRadius.circular(Ds.r.card),
          boxShadow: Ds.elevation.e1,
        ),
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${backfill['label'] ?? ''}',
              style:
                  Ds.t.body.copyWith(color: Ds.c.text, fontWeight: FontWeight.w700)),
          SizedBox(height: Ds.space.x8),
          Text('${backfill['orders_label'] ?? ''}',
              style: Ds.t.body.copyWith(color: Ds.c.text)),
          Text('${backfill['suppliers_label'] ?? ''}',
              style: Ds.t.body.copyWith(color: Ds.c.text)),
          SizedBox(height: Ds.space.x8),
          Text('${backfill['note'] ?? ''}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(note, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ],
        ]),
      );
}

class _ClosureCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onOpen;
  const _ClosureCard({required this.row, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final blockers = (row['blockers'] as List?) ?? const [];
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(Ds.r.card),
      child: Container(
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: BorderRadius.circular(Ds.r.card),
          boxShadow: Ds.elevation.e1,
        ),
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${row['order_code'] ?? ''}',
                  style: Ds.t.subtitle
                      .copyWith(color: Ds.c.text, fontWeight: FontWeight.w700)),
            ),
            _ToneChip(
                label: '${row['status_label'] ?? ''}', tone: row['status_tone']),
          ]),
          SizedBox(height: Ds.space.x4),
          Text('${row['buyer_label'] ?? ''}',
              style: Ds.t.body.copyWith(color: Ds.c.text)),
          SizedBox(height: Ds.space.x4),
          Text('${row['closed_label'] ?? row['placed_label'] ?? ''}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          if ('${row['override_badge'] ?? ''}'.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            _ToneChip(label: '${row['override_badge']}', tone: 'info'),
          ],
          if (blockers.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text('${row['blockers_label'] ?? ''}',
                style: Ds.t.caption.copyWith(
                    color: Ds.c.textSecondary, fontWeight: FontWeight.w600)),
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                for (final b in blockers)
                  _ToneChip(
                      label: '${(b as Map)['label'] ?? ''}', tone: b['tone']),
              ],
            ),
          ],
        ]),
      ),
    );
  }
}

class _ClosureDetailSheet extends StatefulWidget {
  final String kind;
  final String id;
  const _ClosureDetailSheet({required this.kind, required this.id});

  @override
  State<_ClosureDetailSheet> createState() => _ClosureDetailSheetState();
}

class _ClosureDetailSheetState extends State<_ClosureDetailSheet> {
  Map<String, dynamic>? _d;
  Object? _error;
  bool _loading = true;
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
      final res = await Supabase.instance.client.rpc(
          'admin_order_closure_detail',
          params: {'p_kind': widget.kind, 'p_id': widget.id});
      setState(() {
        _d = Map<String, dynamic>.from(res as Map);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// The override. The reason is not validated here — the backend refuses a
  /// thin one and hands back its own message, which is what gets shown.
  Future<void> _override(Map<String, dynamic> ov) async {
    final ctrl = TextEditingController();
    final go = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: Ds.c.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Ds.r.card)),
        title: Text('${ov['action_label'] ?? ''}',
            style: Ds.t.subtitle.copyWith(color: Ds.c.text)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${ov['hint'] ?? ''}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: ctrl,
            maxLines: 3,
            style: Ds.t.body.copyWith(color: Ds.c.text),
            decoration: InputDecoration(
              filled: true,
              fillColor: Ds.c.bg,
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(Ds.r.button)),
            ),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text('${ov['cancel_label'] ?? ''}')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ds.c.danger),
            onPressed: () => Navigator.pop(dctx, true),
            child: Text('${ov['confirm_label'] ?? ''}'),
          ),
        ],
      ),
    );
    if (go != true) return;

    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('${ov['rpc']}',
          params: widget.kind == 'supplier_order'
              ? {'p_supplier_order_id': widget.id, 'p_reason': ctrl.text}
              : {'p_order_id': widget.id, 'p_reason': ctrl.text});
      final m = Map<String, dynamic>.from(res as Map);
      final toast = '${m['error'] != null ? m['toast'] ?? m['error'] : m['toast'] ?? ''}';
      if (mounted && toast.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(toast)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: _loading
            ? const _Skeleton()
            : (_error != null || d?['ok'] != true)
                ? _ErrorState(
                    message: '${d?['error'] ?? _error ?? ''}',
                    retryLabel: '',
                    onRetry: _load)
                : _content(d!),
      ),
    );
  }

  Widget _content(Map<String, dynamic> d) {
    final gates = (d['gates'] as List?) ?? const [];
    final ov = d['override'];

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      shrinkWrap: true,
      children: [
        Row(children: [
          Expanded(
            child: Text('${d['order_code'] ?? ''}',
                style: Ds.t.title.copyWith(color: Ds.c.text)),
          ),
          _ToneChip(
              label: '${d['status_label'] ?? ''}', tone: d['status_tone']),
        ]),
        SizedBox(height: Ds.space.x4),
        Text('${d['buyer_label'] ?? ''}',
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        if ('${d['closed_label'] ?? ''}'.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text('${d['closed_label']}',
              style: Ds.t.caption.copyWith(color: Ds.c.success)),
        ],
        if ('${d['closed_reason'] ?? ''}'.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text('${d['closed_reason']}',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        ],
        SizedBox(height: Ds.space.x24),
        for (final g in gates) _GateRow(gate: Map<String, dynamic>.from(g as Map)),
        if (ov is Map) ...[
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Ds.c.danger,
                side: BorderSide(color: Ds.c.danger),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(Ds.r.button)),
              ),
              onPressed: _busy
                  ? null
                  : () => _override(Map<String, dynamic>.from(ov)),
              child: Text('${ov['action_label'] ?? ''}'),
            ),
          ),
        ],
        SizedBox(height: Ds.space.x16),
      ],
    );
  }
}

class _GateRow extends StatelessWidget {
  final Map<String, dynamic> gate;
  const _GateRow({required this.gate});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: Ds.space.x8,
            height: Ds.space.x8,
            margin: EdgeInsets.only(top: Ds.space.x8, right: Ds.space.x12),
            decoration: BoxDecoration(
                color: _toneColor(gate['tone']), shape: BoxShape.circle),
          ),
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${gate['label'] ?? ''}',
                  style: Ds.t.body
                      .copyWith(color: Ds.c.text, fontWeight: FontWeight.w600)),
              Text('${gate['status_label'] ?? ''}',
                  style: Ds.t.caption.copyWith(color: _toneColor(gate['tone']))),
              if ('${gate['detail'] ?? ''}'.isNotEmpty)
                Text('${gate['detail']}',
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            ]),
          ),
        ]),
      );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: EdgeInsets.all(Ds.space.x16),
        itemCount: 4,
        separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
        itemBuilder: (_, __) => Container(
          height: Ds.space.x48 + Ds.space.x32,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: BorderRadius.circular(Ds.r.card),
          ),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  const _ErrorState(
      {required this.message, required this.retryLabel, required this.onRetry});

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x32),
        children: [
          Text(message,
              textAlign: TextAlign.center,
              style: Ds.t.body.copyWith(color: Ds.c.danger)),
          if (retryLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
            ),
          ],
        ],
      );
}
