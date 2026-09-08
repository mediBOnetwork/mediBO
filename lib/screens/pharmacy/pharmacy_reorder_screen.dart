// CHANGE #414 — "what to reorder", worked out from what actually sold.
//
// The owner's real question is not "how many did I sell" — it is "what runs out
// before I can replace it". So the backend turns POS history into a per-day
// rate, that rate plus what is on the shelf into a DATE, and that date into a
// sentence: "Finishes Thursday". This screen prints those sentences.
//
// It computes nothing and it groups nothing: `group_key` on each row and the
// `groups` list in the payload decide the sections and their order, so a bucket
// this build has never heard of still renders, and a threshold change is an
// UPDATE rather than a deploy.
//
// One tap fills the cart. Nothing here places an order — that is the backend's
// rule and the spec's, and it is why the toast says so out loud.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/pos_api.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import 'pharmacy_inference_screen.dart';  // CHANGE #424

String _rs(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

List<Map<String, dynamic>> _rrows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

Color _rtone(Object? tone) => switch ((tone ?? '').toString()) {
      'success' => Ds.c.success,
      'warning' => Ds.c.warning,
      'danger' => Ds.c.danger,
      'info' => Ds.c.info,
      _ => Ds.c.textSecondary,
    };

Color _rtoneSoft(Object? tone) => switch ((tone ?? '').toString()) {
      'success' => Ds.c.successSoft,
      'warning' => Ds.c.warningSoft,
      'danger' => Ds.c.dangerSoft,
      'info' => Ds.c.infoSoft,
      _ => Ds.c.bg,
    };

/// The pure view: hand it a payload, it draws it.
class PharmacyReorderView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final Map<String, dynamic> draft;
  final void Function(Map<String, dynamic> row) onAdd;
  final VoidCallback onAddAll;
  final void Function(String action) onDraftAction;
  final bool busy;

  const PharmacyReorderView({
    super.key,
    required this.payload,
    required this.onAdd,
    required this.onAddAll,
    required this.onDraftAction,
    this.draft = const {},
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Center(
            child: Text(_rs(payload, 'message'), style: Ds.t.bodySecondary)),
      );
    }
    final rows = _rrows(payload['rows']);
    final groups = _rrows(payload['groups']);
    RenderLog.write('c414_reorder_rows', rows.length);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_rs(payload, 'title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x4),
        Text(_rs(payload, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        _WindowChips(payload: payload),
        // CHANGE #424 — "what is probably left" belongs next to "what to
        // reorder": the same purchase history answers both questions. The
        // label is ui_copy, so clearing the copy removes the entry.
        SizedBox(height: Ds.space.x16),
        InferenceEntryTile(label: c('infer424.tile_label')),
        if (draft['has'] == true) ...[
          SizedBox(height: Ds.space.x24),
          _DraftCard(draft: draft, busy: busy, onAction: onDraftAction),
        ],
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
            child: Center(
                child: Text(_rs(payload, 'empty'),
                    textAlign: TextAlign.center, style: Ds.t.caption)),
          )
        else ...[
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: busy ? null : onAddAll,
              child: Text(_rs(payload, 'add_all_label')),
            ),
          ),
          SizedBox(height: Ds.space.x24),
          // Sections come from `groups`, in the payload's order. A row whose
          // group_key is not in the list is still shown, at the end, rather
          // than silently dropped — a SKU about to run out must never vanish
          // because a bucket was renamed.
          for (final g in groups) ...[
            if (rows.any((r) => _rs(r, 'group_key') == _rs(g, 'key'))) ...[
              _GroupHeading(label: _rs(g, 'label'), tone: g['tone']),
              SizedBox(height: Ds.space.x12),
              for (final r
                  in rows.where((r) => _rs(r, 'group_key') == _rs(g, 'key'))) ...[
                _ReorderRow(row: r, busy: busy, onAdd: () => onAdd(r)),
                SizedBox(height: Ds.space.x12),
              ],
              SizedBox(height: Ds.space.x12),
            ],
          ],
          for (final r in rows.where((r) =>
              !groups.any((g) => _rs(g, 'key') == _rs(r, 'group_key')))) ...[
            _ReorderRow(row: r, busy: busy, onAdd: () => onAdd(r)),
            SizedBox(height: Ds.space.x12),
          ],
        ],
      ],
    );
  }
}

class _WindowChips extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _WindowChips({required this.payload});

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: [
          if (_rs(payload, 'window_display').isNotEmpty)
            _Chip(
                label:
                    '${_rs(payload, 'window_label')} · ${_rs(payload, 'window_display')}'),
          if (_rs(payload, 'cover_display').isNotEmpty)
            _Chip(
                label:
                    '${_rs(payload, 'cover_label')} · ${_rs(payload, 'cover_display')}'),
        ],
      );
}

class _GroupHeading extends StatelessWidget {
  final String label;
  final Object? tone;
  const _GroupHeading({required this.label, required this.tone});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Container(
            width: Ds.space.x8,
            height: Ds.space.x8,
            decoration:
                BoxDecoration(color: _rtone(tone), shape: BoxShape.circle),
          ),
          SizedBox(width: Ds.space.x8),
          Text(label, style: Ds.t.subtitle),
        ],
      );
}

class _ReorderRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool busy;
  final VoidCallback onAdd;
  const _ReorderRow(
      {required this.row, required this.busy, required this.onAdd});

  @override
  Widget build(BuildContext context) => Container(
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
                  child: Text(_rs(row, 'product_name'), style: Ds.t.bodyStrong),
                ),
                SizedBox(width: Ds.space.x8),
                // The whole point of the feature, in the backend's words.
                Text(_rs(row, 'stockout_label'),
                    style: Ds.t.caption.copyWith(color: Ds.c.danger)),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x12,
              runSpacing: Ds.space.x4,
              children: [
                Text(
                    '${_rs(row, 'stock_label')} ${_rs(row, 'stock_display')}',
                    style: Ds.t.caption),
                Text(
                    '${_rs(row, 'velocity_label')} ${_rs(row, 'velocity_display')}',
                    style: Ds.t.caption),
              ],
            ),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                Expanded(
                  child: Text(
                      '${_rs(row, 'suggest_label')} ${_rs(row, 'suggest_qty')}',
                      style: Ds.t.body),
                ),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Ds.c.brand),
                      foregroundColor: Ds.c.brand,
                      shape:
                          RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                    onPressed: busy ? null : onAdd,
                    child: Text(_rs(row, 'add_label')),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

/// The weekly draft. Approving it fills the cart — the note says so, in the
/// backend's words, because "approve" must never read as "order".
class _DraftCard extends StatelessWidget {
  final Map<String, dynamic> draft;
  final bool busy;
  final void Function(String action) onAction;
  const _DraftCard(
      {required this.draft, required this.busy, required this.onAction});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.infoSoft,
          borderRadius: Ds.r.rCard,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_rs(draft, 'title'), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x4),
            Text(_rs(draft, 'note'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Ds.c.brand,
                        shape: RoundedRectangleBorder(
                            borderRadius: Ds.r.rButton),
                      ),
                      onPressed: busy ? null : () => onAction('approve'),
                      child: Text(_rs(draft, 'approve_label')),
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: TextButton(
                    onPressed: busy ? null : () => onAction('skip'),
                    child: Text(_rs(draft, 'skip_label')),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

class _Chip extends StatelessWidget {
  final String label;
  const _Chip({required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration:
            BoxDecoration(color: _rtoneSoft('info'), borderRadius: Ds.r.rChip),
        child: Text(label,
            style: Ds.t.caption.copyWith(color: _rtone('info'))),
      );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          _Bar(width: Ds.space.x48 * 3, height: Ds.space.x24),
          SizedBox(height: Ds.space.x8),
          _Bar(width: double.infinity, height: Ds.space.x16),
          SizedBox(height: Ds.space.x24),
          for (var i = 0; i < 4; i++) ...[
            Container(
              padding: EdgeInsets.all(Ds.space.x16),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Bar(width: Ds.space.x48 * 2, height: Ds.space.x16),
                  SizedBox(height: Ds.space.x8),
                  _Bar(width: Ds.space.x48 * 3, height: Ds.space.x12),
                ],
              ),
            ),
            SizedBox(height: Ds.space.x12),
          ],
        ],
      );
}

class _Bar extends StatelessWidget {
  final double width;
  final double height;
  const _Bar({required this.width, required this.height});

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: height,
        decoration:
            BoxDecoration(color: Ds.c.divider, borderRadius: Ds.r.rChip),
      );
}

// ── the live screen ─────────────────────────────────────────────────────────

class PharmacyReorderScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final PosRpc? rpc;
  const PharmacyReorderScreen({super.key, this.rpc});

  @override
  State<PharmacyReorderScreen> createState() => _PharmacyReorderScreenState();
}

class _PharmacyReorderScreenState extends State<PharmacyReorderScreen> {
  Map<String, dynamic>? _payload;
  Map<String, dynamic> _draft = const {};
  bool _busy = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PosApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await _call('pharmacy_reorder_screen', const {});
    Map<String, dynamic> d = const {};
    try {
      d = await _call('pharmacy_reorder_draft_get', const {});
    } catch (_) {
      // No draft is not an error; the screen simply shows no draft card.
    }
    if (!mounted) return;
    setState(() {
      _payload = p;
      _draft = d;
    });
  }

  void _toast(Map<String, dynamic> r) {
    final msg = (r['message'] ?? '').toString();
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: _rtone(r['tone']),
    ));
  }

  Future<void> _run(Future<Map<String, dynamic>> future) async {
    setState(() => _busy = true);
    final r = await future;
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(r);
    await _load();
  }

  List<Map<String, dynamic>> _itemsOf(Iterable<Map<String, dynamic>> rows) => [
        for (final r in rows)
          {'medicine_id': r['medicine_id'], 'qty': r['suggest_qty']}
      ];

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(p == null ? '' : _rs(p, 'title')),
        backgroundColor: Ds.c.surface,
      ),
      body: p == null
          ? const _Skeleton()
          : PharmacyReorderView(
              payload: p,
              draft: _draft,
              busy: _busy,
              onAdd: (row) => _run(_call('pharmacy_reorder_add',
                  {'p_items': _itemsOf([row])})),
              onAddAll: () => _run(_call('pharmacy_reorder_add',
                  {'p_items': _itemsOf(_rrows(p['rows']))})),
              onDraftAction: (action) => _run(_call(
                  'pharmacy_reorder_draft_act',
                  {'p_id': _draft['id'], 'p_action': action})),
            ),
    );
  }
}
