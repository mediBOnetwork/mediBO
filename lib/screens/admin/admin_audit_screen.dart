// CHANGE #394 — the Audit trail.
//
// Nobody recorded who changed what. This screen is the reading end of the
// audit_log built in the same change, and it is a pure renderer: every string
// on it — the title, the filter labels, the action wording, the IST timestamp,
// the "Before → After" field lines, the empty state — arrives from
// `admin_audit_screen()`. Dart formats nothing and decides nothing, including
// whether the caller is allowed to be here: `ok:false` renders the backend's
// own refusal copy rather than a Dart string.
//
// Tapping a row opens that entity's FULL history from `admin_audit_entity()`,
// which is the question an audit trail actually gets asked: not "what happened
// at 4pm" but "what has ever happened to this bill".
//
// CHANGE #397 — each row also carries the backend's verdict on whether it can
// be taken back (`row['undo']`). The card shows an Undo button when the backend
// says can:true, and the reason IT gives when it says can:false — money entries
// are never reversible here, a closed window says so, and an entry that has
// already been undone says that. Dart decides none of it.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// Injected in tests; null in production means the real RPCs.
typedef AuditRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

class AdminAuditScreen extends StatefulWidget {
  const AdminAuditScreen({super.key, this.rpc});

  final AuditRpc? rpc;

  @override
  State<AdminAuditScreen> createState() => _AdminAuditScreenState();
}

class _AdminAuditScreenState extends State<AdminAuditScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  /// Filter key → chosen value. Sent back verbatim; the backend owns which
  /// keys exist and what they mean.
  final Map<String, String> _applied = {};
  final List<Map<String, dynamic>> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
      String fn, Map<String, dynamic> params) async {
    if (widget.rpc != null) return widget.rpc!(fn, params);
    final res = await Supabase.instance.client.rpc(fn, params: params);
    return Map<String, dynamic>.from(res as Map);
  }

  Future<void> _load({bool append = false}) async {
    setState(() {
      _loading = true;
      if (!append) _error = null;
    });
    try {
      final params = <String, dynamic>{..._applied};
      if (append) params['offset'] = _data?['next_offset'] ?? 0;
      final res = await _call('admin_audit_screen', {'p': params});
      if (!mounted) return;
      setState(() {
        _data = res;
        if (!append) _rows.clear();
        _rows.addAll(List<Map<String, dynamic>>.from(
            (res['rows'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map))));
        _loading = false;
      });
      RenderLog.write('audit_rows', _rows.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// The Undo path. The confirmation copy, the button captions and the result
  /// banner are all the backend's; this only asks and reports.
  Future<void> _undo(Map<String, dynamic> row) async {
    final undo = Map<String, dynamic>.from(
        (row['undo'] as Map? ?? const {}));
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (_) => _UndoConfirmSheet(undo: undo),
    );
    if (ok != true || !mounted) return;

    final res = await _call('admin_undo_audit', {'p_audit_id': row['id']});
    if (!mounted) return;
    final message = res['message']?.toString() ?? '';
    if (message.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
    await _load();
  }

  Future<void> _openHistory(Map<String, dynamic> row) async {
    final res = await _call('admin_audit_entity', {
      'p_entity_type': row['entity_type'],
      'p_entity_id': row['entity_id'],
    });
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (_) => _HistorySheet(data: res),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        elevation: 0,
        title: Text(d?['title']?.toString() ?? '', style: Ds.t.title),
      ),
      body: _body(d),
    );
  }

  Widget _body(Map<String, dynamic>? d) {
    if (_loading && _rows.isEmpty) return const _Skeleton();
    if (_error != null) return _Message(text: _error!, onRetry: () => _load());
    if (d == null) return const SizedBox.shrink();
    if (d['ok'] != true) {
      return _Message(text: d['message']?.toString() ?? '');
    }

    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
        children: [
          Text(d['subtitle']?.toString() ?? '', style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x16),
          _Filters(
            filters: List<Map<String, dynamic>>.from((d['filters'] as List? ?? const [])
                .map((e) => Map<String, dynamic>.from(e as Map))),
            applied: _applied,
            onPick: (key, value) {
              setState(() {
                if (value.isEmpty) {
                  _applied.remove(key);
                } else {
                  _applied[key] = value;
                }
              });
              _load();
            },
          ),
          SizedBox(height: Ds.space.x24),
          Text(d['count_label']?.toString() ?? '', style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          if (_rows.isEmpty)
            _Empty(
                title: d['empty_title']?.toString() ?? '',
                hint: d['empty_hint']?.toString() ?? '')
          else
            ..._rows.map((r) => Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x12),
                  child: AuditRowCard(
                    row: r,
                    beforeLabel: d['before_label']?.toString() ?? '',
                    afterLabel: d['after_label']?.toString() ?? '',
                    onTap: () => _openHistory(r),
                    onUndo: () => _undo(r),
                  ),
                )),
          if (d['has_more'] == true) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.space.x48,
              child: OutlinedButton(
                onPressed: _loading ? null : () => _load(append: true),
                child: Text(d['more_label']?.toString() ?? ''),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One recorded change. Everything printed here is a backend string; the only
/// decision Dart makes is which token a backend `tone` maps to.
class AuditRowCard extends StatelessWidget {
  const AuditRowCard({
    super.key,
    required this.row,
    required this.beforeLabel,
    required this.afterLabel,
    this.onTap,
    this.onUndo,
  });

  final Map<String, dynamic> row;
  final String beforeLabel;
  final String afterLabel;
  final VoidCallback? onTap;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final changes = List<Map<String, dynamic>>.from(
        (row['changes'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    return Material(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      child: InkWell(
        borderRadius: Ds.r.rCard,
        onTap: onTap,
        child: Container(
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
                    child: Text(
                      '${row['title'] ?? ''} ${row['entity_label'] ?? ''}'.trim(),
                      style: Ds.t.subtitle,
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                  ToneChip(
                      label: row['action_label']?.toString() ?? '',
                      tone: row['tone']?.toString() ?? ''),
                ],
              ),
              SizedBox(height: Ds.space.x4),
              Text(
                '${row['actor_label'] ?? ''} · ${row['when_label'] ?? ''}',
                style: Ds.t.caption,
              ),
              if (changes.isEmpty)
                Padding(
                  padding: EdgeInsets.only(top: Ds.space.x8),
                  child: Text(row['changes_label']?.toString() ?? '',
                      style: Ds.t.bodySecondary),
                )
              else
                ...changes.map((ch) => Padding(
                      padding: EdgeInsets.only(top: Ds.space.x8),
                      child: _ChangeLine(
                          change: ch, beforeLabel: beforeLabel, afterLabel: afterLabel),
                    )),
              _UndoFooter(
                  undo: Map<String, dynamic>.from(row['undo'] as Map? ?? const {}),
                  onUndo: onUndo),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChangeLine extends StatelessWidget {
  const _ChangeLine(
      {required this.change, required this.beforeLabel, required this.afterLabel});

  final Map<String, dynamic> change;
  final String beforeLabel;
  final String afterLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(change['label']?.toString() ?? '', style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _ValuePill(caption: beforeLabel, value: change['before']?.toString() ?? ''),
            Icon(Icons.arrow_forward, size: Ds.space.x16, color: Ds.c.textSecondary),
            _ValuePill(
                caption: afterLabel,
                value: change['after']?.toString() ?? '',
                highlight: true),
          ],
        ),
      ],
    );
  }
}

class _ValuePill extends StatelessWidget {
  const _ValuePill(
      {required this.caption, required this.value, this.highlight = false});

  final String caption;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: highlight ? Ds.c.brandSoft : Ds.c.bg,
        borderRadius: Ds.r.rChip,
      ),
      child: Text('$caption $value', style: Ds.t.caption),
    );
  }
}

/// The row's Undo affordance — a button when the backend allows it, its own
/// refusal line when it does not, and nothing at all when it says neither.
class _UndoFooter extends StatelessWidget {
  const _UndoFooter({required this.undo, required this.onUndo});

  final Map<String, dynamic> undo;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final can = undo['can'] == true && onUndo != null;
    final blocked = undo['blocked_label']?.toString() ?? '';
    if (!can && blocked.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x12),
      child: can
          ? SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton.icon(
                onPressed: onUndo,
                icon: const Icon(Icons.undo),
                label: Text(undo['label']?.toString() ?? ''),
              ),
            )
          : Text(blocked, style: Ds.t.caption),
    );
  }
}

/// Confirmation before a reversal. Sheet, not dialog, and every word backend.
class _UndoConfirmSheet extends StatelessWidget {
  const _UndoConfirmSheet({required this.undo});

  final Map<String, dynamic> undo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(undo['confirm_title']?.toString() ?? '', style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(undo['confirm_body']?.toString() ?? '', style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x24),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(undo['cancel_label']?.toString() ?? ''),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(undo['confirm_cta']?.toString() ?? ''),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The backend names a tone; this is the only place a tone becomes a colour.
class ToneChip extends StatelessWidget {
  const ToneChip({super.key, required this.label, required this.tone});

  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    Color bg;
    switch (tone) {
      case 'success':
        bg = Ds.c.successSoft;
        break;
      case 'danger':
        bg = Ds.c.dangerSoft;
        break;
      case 'warning':
        bg = Ds.c.warningSoft;
        break;
      case 'info':
        bg = Ds.c.infoSoft;
        break;
      default:
        bg = Ds.c.bg;
    }
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
      child: Text(label, style: Ds.t.caption),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters(
      {required this.filters, required this.applied, required this.onPick});

  final List<Map<String, dynamic>> filters;
  final Map<String, String> applied;
  final void Function(String key, String value) onPick;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: filters.map((f) {
        final key = f['key']?.toString() ?? '';
        final options = List<Map<String, dynamic>>.from(
            (f['options'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
        final current = applied[key] ?? '';
        final label = options
                .firstWhere((o) => (o['value']?.toString() ?? '') == current,
                    orElse: () => const {})['label']
                ?.toString() ??
            '';
        return SizedBox(
          height: Ds.space.x48,
          child: PopupMenuButton<String>(
            tooltip: f['label']?.toString() ?? '',
            onSelected: (v) => onPick(key, v),
            itemBuilder: (_) => options
                .map((o) => PopupMenuItem<String>(
                      value: o['value']?.toString() ?? '',
                      child: Text(o['label']?.toString() ?? '', style: Ds.t.body),
                    ))
                .toList(),
            // No `alignment:` here on purpose — a Container with an alignment
            // EXPANDS to its constraints, which turned every filter chip into
            // a full-width bar inside the Wrap. Shrink-wrapping the Row is
            // what makes them read as chips.
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rChip,
                border: Border.all(
                    color: current.isEmpty ? Ds.c.divider : Ds.c.brand),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${f['label'] ?? ''}: $label', style: Ds.t.caption),
                  SizedBox(width: Ds.space.x4),
                  Icon(Icons.expand_more,
                      size: Ds.space.x16, color: Ds.c.textSecondary),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _HistorySheet extends StatelessWidget {
  const _HistorySheet({required this.data});

  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final rows = List<Map<String, dynamic>>.from(
        (data['rows'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(data['title']?.toString() ?? '', style: Ds.t.title),
            SizedBox(height: Ds.space.x4),
            Text(data['subtitle']?.toString() ?? '', style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            Flexible(
              child: rows.isEmpty
                  ? _Empty(
                      title: data['empty_title']?.toString() ?? '',
                      hint: data['empty_hint']?.toString() ?? '')
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: rows.length,
                      separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
                      itemBuilder: (_, i) => AuditRowCard(
                        row: rows[i],
                        beforeLabel: data['before_label']?.toString() ?? '',
                        afterLabel: data['after_label']?.toString() ?? '',
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text(hint, style: Ds.t.bodySecondary),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              SizedBox(height: Ds.space.x16),
              OutlinedButton(onPressed: onRetry, child: const Icon(Icons.refresh)),
            ],
          ],
        ),
      ),
    );
  }
}

/// A skeleton, not a bare spinner — the loading state keeps the page's shape.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: 5,
      separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
      itemBuilder: (_, __) => Container(
        height: Ds.space.x48 * 2,
        decoration: BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
      ),
    );
  }
}
