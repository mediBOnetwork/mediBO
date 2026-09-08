// CHANGE #318 — Admin ▸ Discount slabs.
//
// The ladder every customer bill is priced at: "above ₹2,999 → 3%", and so on
// up. Adding a sixth slab is an INSERT through admin_discount_slab_save(), not
// a deploy — which is the whole point of this screen existing.
//
// This file words NOTHING and computes NOTHING. The title, the subtitle, the
// commitment note, every field label and hint, every row's amount/percent/
// effective/status label AND its colour tone, the button captions, the delete
// confirmation, the empty state and every toast arrive from
// admin_discount_slabs() / _save() / _set_active() / _delete(). A tone is a
// design-token NAME (success/info/neutral), never a hex, so a recolour via
// ui_design_set() carries this screen with it.
//
// All four RPCs are injected, so the screen carries no Supabase import and
// pumps on the Dart VM; discount_slabs_service.dart supplies the live calls.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'feature_gaps_screen.dart' show toneColor, toneSoft;

/// `admin_discount_slabs()`.
typedef SlabsListRpc = Future<Map<String, dynamic>> Function();

/// `admin_discount_slab_save(p jsonb)`.
typedef SlabsSaveRpc =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> patch);

/// `admin_discount_slab_set_active(p_id, p_active)`.
typedef SlabsActiveRpc =
    Future<Map<String, dynamic>> Function(int id, bool active);

/// `admin_discount_slab_delete(p_id)`.
typedef SlabsDeleteRpc = Future<Map<String, dynamic>> Function(int id);

class AdminDiscountSlabsScreen extends StatefulWidget {
  final SlabsListRpc listRpc;
  final SlabsSaveRpc saveRpc;
  final SlabsActiveRpc setActiveRpc;
  final SlabsDeleteRpc deleteRpc;

  const AdminDiscountSlabsScreen({
    super.key,
    required this.listRpc,
    required this.saveRpc,
    required this.setActiveRpc,
    required this.deleteRpc,
  });

  @override
  State<AdminDiscountSlabsScreen> createState() =>
      _AdminDiscountSlabsScreenState();
}

class _AdminDiscountSlabsScreenState extends State<AdminDiscountSlabsScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _s(String key) => '${_data?[key] ?? ''}';

  List<Map<String, dynamic>> get _rows => ((_data?['rows'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  List<Map<String, dynamic>> get _fields =>
      ((_data?['fields'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final payload = await widget.listRpc();
      if (!mounted) return;
      setState(() {
        _data = payload;
        _loading = false;
      });
      RenderLog.write('c318_discount_slabs', '${_rows.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Every mutation answers with the WHOLE screen again, so the list after a
  /// save is the server's list, never a locally patched copy of it.
  Future<void> _apply(Future<Map<String, dynamic>> call) async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> res;
    try {
      res = await call;
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': '$e'};
    }
    if (!mounted) return;
    final message = '${res['toast'] ?? res['message'] ?? ''}';
    setState(() {
      _busy = false;
      if (res['ok'] == true) _data = res;
    });
    if (message.isNotEmpty) {
      showToast(context, message, isError: res['ok'] != true);
    }
  }

  Future<void> _edit(Map<String, dynamic>? row) async {
    final patch = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => SlabEditorSheet(
        fields: _fields,
        row: row,
        saveLabel: _s('save_label'),
        cancelLabel: _s('cancel_label'),
        title: row == null ? _s('add_label') : _s('edit_label'),
        today: _s('today'),
      ),
    );
    if (patch == null || !mounted) return;
    await _apply(widget.saveRpc(patch));
  }

  Future<void> _confirmDelete(Map<String, dynamic> row) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Ds.c.surface,
        title: Text(_s('delete_label'), style: Ds.t.subtitle),
        content: Text(_s('delete_confirm'), style: Ds.t.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_s('cancel_label')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Ds.c.danger),
            child: Text(_s('delete_label')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _apply(widget.deleteRpc((row['id'] as num?)?.toInt() ?? 0));
  }

  @override
  Widget build(BuildContext context) {
    final notAuthorized = _data != null && _data!['ok'] != true;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s('title'), style: Ds.t.subtitle),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      floatingActionButton: (_loading || notAuthorized)
          ? null
          : FloatingActionButton.extended(
              onPressed: _busy ? null : () => _edit(null),
              backgroundColor: Ds.c.brand,
              icon: const Icon(Icons.add),
              label: Text(_s('add_label')),
            ),
      body: _loading
          ? const _SlabSkeleton()
          : _error != null
              ? _SlabError(message: _error!, onRetry: _load)
              : notAuthorized
                  ? Padding(
                      padding: EdgeInsets.all(Ds.space.x16),
                      child: _SlabEmpty(
                          title: '${_data?['message'] ?? ''}', body: ''),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: EdgeInsets.all(Ds.space.x16),
                        children: [
                          if (_s('subtitle').isNotEmpty) ...[
                            Text(_s('subtitle'), style: Ds.t.bodySecondary),
                            SizedBox(height: Ds.space.x12),
                          ],
                          if (_s('commitment_note').isNotEmpty) ...[
                            _CommitmentNote(text: _s('commitment_note')),
                            SizedBox(height: Ds.space.x24),
                          ],
                          ..._body(),
                          SizedBox(height: Ds.space.x48),
                        ],
                      ),
                    ),
    );
  }

  List<Widget> _body() {
    final rows = _rows;
    if (rows.isEmpty) {
      return [_SlabEmpty(title: _s('empty_title'), body: _s('empty_hint'))];
    }
    return [
      for (final row in rows)
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: SlabCard(
            row: row,
            editLabel: _s('edit_label'),
            deleteLabel: _s('delete_label'),
            busy: _busy,
            onEdit: () => _edit(row),
            onToggle: () => _apply(widget.setActiveRpc(
                (row['id'] as num?)?.toInt() ?? 0, row['toggle_to'] == true)),
            onDelete: () => _confirmDelete(row),
          ),
        ),
    ];
  }
}

/// One slab. Amount and percent are the focal pair; the effective date and the
/// status chip are metadata under them.
class SlabCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final String editLabel;
  final String deleteLabel;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const SlabCard({
    super.key,
    required this.row,
    required this.editLabel,
    required this.deleteLabel,
    required this.busy,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final note = '${row['note'] ?? ''}';
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
                child: Text('${row['amount_label'] ?? ''}',
                    style: Ds.t.bodyStrong),
              ),
              SizedBox(width: Ds.space.x8),
              Text('${row['pct_label'] ?? ''}', style: Ds.t.subtitle),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Row(
            children: [
              _StatusChip(
                  label: '${row['status_label'] ?? ''}',
                  tone: row['status_tone']),
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: Text('${row['effective_label'] ?? ''}',
                    style: Ds.t.caption),
              ),
            ],
          ),
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(note, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x8),
          Row(children: [
            _CardAction(label: editLabel, onTap: busy ? null : onEdit),
            _CardAction(
                label: '${row['toggle_label'] ?? ''}',
                onTap: busy ? null : onToggle),
            const Spacer(),
            _CardAction(
                label: deleteLabel,
                colour: Ds.c.danger,
                onTap: busy ? null : onDelete),
          ]),
        ],
      ),
    );
  }
}

class _CardAction extends StatelessWidget {
  final String label;
  final Color? colour;
  final VoidCallback? onTap;
  const _CardAction({required this.label, this.onTap, this.colour});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
          minHeight: Ds.touch.minTarget, minWidth: Ds.touch.minTarget),
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(foregroundColor: colour ?? Ds.c.brand),
        child: Text(label),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Object? tone;
  const _StatusChip({required this.label, this.tone});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(
          color: toneSoft(tone), borderRadius: Ds.r.rChip),
      child: Text(label,
          style: Ds.t.caption.copyWith(color: toneColor(tone))),
    );
  }
}

class _CommitmentNote extends StatelessWidget {
  final String text;
  const _CommitmentNote({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
          color: Ds.c.infoSoft, borderRadius: Ds.r.rCard),
      child: Text(text, style: Ds.t.caption.copyWith(color: Ds.c.info)),
    );
  }
}

/// The add/edit sheet. It draws exactly the fields the backend sent, in the
/// order it sent them — a new column on the ladder is a payload change here.
class SlabEditorSheet extends StatefulWidget {
  final List<Map<String, dynamic>> fields;
  final Map<String, dynamic>? row;
  final String saveLabel;
  final String cancelLabel;
  final String title;
  final String today;

  const SlabEditorSheet({
    super.key,
    required this.fields,
    required this.row,
    required this.saveLabel,
    required this.cancelLabel,
    required this.title,
    required this.today,
  });

  @override
  State<SlabEditorSheet> createState() => _SlabEditorSheetState();
}

class _SlabEditorSheetState extends State<SlabEditorSheet> {
  final Map<String, TextEditingController> _ctl = {};

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      final key = '${f['key'] ?? ''}';
      if (key.isEmpty) continue;
      var seed = '${widget.row?[key] ?? ''}';
      if (seed.isEmpty && key == 'effective_from' && widget.row == null) {
        seed = widget.today;
      }
      _ctl[key] = TextEditingController(text: seed);
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final patch = <String, dynamic>{};
    if (widget.row != null) patch['id'] = '${widget.row!['id']}';
    _ctl.forEach((k, v) => patch[k] = v.text.trim());
    Navigator.pop(context, patch);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
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
            Text(widget.title, style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            for (final f in widget.fields) ..._field(f),
            SizedBox(height: Ds.space.x8),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: _submit,
                style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                child: Text(widget.saveLabel),
              ),
            ),
            SizedBox(height: Ds.space.x8),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(widget.cancelLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _field(Map<String, dynamic> f) {
    final key = '${f['key'] ?? ''}';
    final ctl = _ctl[key];
    if (ctl == null) return const [];
    final hint = '${f['hint'] ?? ''}';
    return [
      TextField(
        controller: ctl,
        keyboardType: '${f['kind']}' == 'number'
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: '${f['label'] ?? ''}',
          helperText: hint.isEmpty ? null : hint,
        ),
      ),
      SizedBox(height: Ds.space.x16),
    ];
  }
}

class _SlabEmpty extends StatelessWidget {
  final String title;
  final String body;
  const _SlabEmpty({required this.title, required this.body});

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
      child: Column(children: [
        Text(title, style: Ds.t.bodyStrong, textAlign: TextAlign.center),
        if (body.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(body, style: Ds.t.caption, textAlign: TextAlign.center),
        ],
      ]),
    );
  }
}

class _SlabError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _SlabError({required this.message, required this.onRetry});

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
            child: FilledButton(
              onPressed: onRetry,
              style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
              child: const Icon(Icons.refresh),
            ),
          ),
        ]),
      ),
    );
  }
}

/// A skeleton, not a bare spinner — the list it stands in for is a short stack
/// of equal cards, so three grey ones read as "loading" without a jump.
class _SlabSkeleton extends StatelessWidget {
  const _SlabSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: Ds.space.x48 + Ds.space.x32,
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1,
              ),
            ),
          ),
      ],
    );
  }
}
