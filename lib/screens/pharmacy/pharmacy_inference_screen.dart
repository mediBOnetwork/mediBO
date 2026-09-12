// CHANGE #424 — "what is probably left", without anyone counting anything.
//
// Every number on this screen is an ESTIMATE the backend already turned into a
// sentence: "Around 3 left", "likely 1–6", "About 22 of 30 sold since 12 Aug".
// Dart never formats a quantity, never builds a range, never decides what
// "confident" means and — most importantly — never turns an estimate into a
// bare number that would read as certain. If the backend swaps a SKU onto the
// POS counter's real sales, the only thing that changes here is the label the
// payload sends; the screen cannot tell, which is the design.
//
// The correction sheet is the ground-truth loop: the options are the backend's
// (0 / 2 / 5 / whatever the estimate says), and the tap sends the quantity
// back untouched.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_infer_api.dart';
import '../../services/pos_api.dart';
import '../../utils/render_log.dart';

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

Color _tone(Object? tone) => switch ((tone ?? '').toString()) {
      'success' => Ds.c.success,
      'warning' => Ds.c.warning,
      'danger' => Ds.c.danger,
      'info' => Ds.c.info,
      _ => Ds.c.textSecondary,
    };

Color _toneSoft(Object? tone) => switch ((tone ?? '').toString()) {
      'success' => Ds.c.successSoft,
      'warning' => Ds.c.warningSoft,
      'danger' => Ds.c.dangerSoft,
      'info' => Ds.c.infoSoft,
      _ => Ds.c.bg,
    };

/// The pure view: hand it a payload, it draws it.
class InferenceView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final void Function(Map<String, dynamic> row) onCorrect;

  const InferenceView({
    super.key,
    required this.payload,
    required this.onCorrect,
  });

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Center(
          child: Text(_s(payload, 'message'), style: Ds.t.bodySecondary),
        ),
      );
    }
    final rows = _rows(payload['rows']);
    RenderLog.write('c424_infer_rows', rows.length);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(payload, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
            child: Column(
              children: [
                Text(_s(payload, 'empty'),
                    textAlign: TextAlign.center, style: Ds.t.bodyStrong),
                SizedBox(height: Ds.space.x8),
                Text(_s(payload, 'empty_hint'),
                    textAlign: TextAlign.center, style: Ds.t.caption),
              ],
            ),
          )
        else ...[
          Text(_s(payload, 'heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          for (final row in rows) ...[
            _LotCard(row: row, onCorrect: () => onCorrect(row)),
            SizedBox(height: Ds.space.x12),
          ],
          SizedBox(height: Ds.space.x8),
          Text(_s(payload, 'note'), style: Ds.t.caption),
        ],
      ],
    );
  }
}

class _LotCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onCorrect;
  const _LotCard({required this.row, required this.onCorrect});

  @override
  Widget build(BuildContext context) {
    final range = _s(row, 'range_label');
    final expiry = _s(row, 'expiry_label');
    final batch = _s(row, 'batch_label');
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
              Expanded(child: Text(_s(row, 'name'), style: Ds.t.bodyStrong)),
              SizedBox(width: Ds.space.x12),
              _Chip(
                label: _s(row, 'confidence_label'),
                tone: row['tone'],
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          // The estimate, and the fact that it IS an estimate, both from the
          // payload. A range is drawn only when the backend sent one.
          Text(_s(row, 'left_label'), style: Ds.t.title),
          if (range.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(range, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x8),
          Text(_s(row, 'sold_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(_s(row, 'rate_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Chip(label: _s(row, 'method_label'), tone: 'info'),
              if (batch.isNotEmpty) Text(batch, style: Ds.t.caption),
              if (expiry.isNotEmpty) Text(expiry, style: Ds.t.caption),
            ],
          ),
          // A lot the counter already prices cannot be "corrected" — the
          // backend says so with can_correct, and the button simply is not there.
          if (row['can_correct'] == true) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Ds.c.brand),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: onCorrect,
                child: Text(
                  _s(row, 'ask_title'),
                  style: Ds.t.bodyStrong.copyWith(color: Ds.c.brand),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Object? tone;
  const _Chip({required this.label, this.tone});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x12,
        vertical: Ds.space.x4,
      ),
      decoration: BoxDecoration(
        color: _toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: _tone(tone))),
    );
  }
}

/// The one-tap truth sheet. Options are the backend's; "another number" opens a
/// field, and whatever the owner types is sent as-is.
class CorrectionSheet extends StatefulWidget {
  final Map<String, dynamic> row;
  final void Function(num left) onPick;
  const CorrectionSheet({super.key, required this.row, required this.onPick});

  @override
  State<CorrectionSheet> createState() => _CorrectionSheetState();
}

class _CorrectionSheetState extends State<CorrectionSheet> {
  final _controller = TextEditingController();
  bool _typing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final options = _rows(row['ask_options']);
    return Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(row, 'ask_title'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(_s(row, 'ask_hint'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          Wrap(
            spacing: Ds.space.x12,
            runSpacing: Ds.space.x12,
            children: [
              for (final o in options)
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: Ds.c.brand),
                      shape:
                          RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                    onPressed: () => widget.onPick(
                      o['qty'] is num ? o['qty'] as num : 0,
                    ),
                    child: Text(_s(o, 'label'),
                        style: Ds.t.bodyStrong.copyWith(color: Ds.c.brand)),
                  ),
                ),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Ds.c.divider),
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  onPressed: () => setState(() => _typing = true),
                  child: Text(_s(row, 'ask_other'), style: Ds.t.body),
                ),
              ),
            ],
          ),
          if (_typing) ...[
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(),
            ),
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: () {
                  final v = num.tryParse(_controller.text.trim());
                  if (v != null) widget.onPick(v);
                },
                child: Text(_s(row, 'ask_save')),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── the live screen ─────────────────────────────────────────────────────────

class PharmacyInferenceScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final PosRpc? rpc;
  const PharmacyInferenceScreen({super.key, this.rpc});

  @override
  State<PharmacyInferenceScreen> createState() =>
      _PharmacyInferenceScreenState();
}

class _PharmacyInferenceScreenState extends State<PharmacyInferenceScreen> {
  Map<String, dynamic>? _payload;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyInferApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await _call('pharmacy_inference_screen', const {'p_limit': 50});
    if (!mounted) return;
    setState(() => _payload = p);
  }

  void _toast(Map<String, dynamic> r) {
    final msg = (r['message'] ?? '').toString();
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: _tone(r['tone'])),
    );
  }

  Future<void> _correct(Map<String, dynamic> row) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ds.c.surface,
      isScrollControlled: true,
      builder: (sheetContext) => CorrectionSheet(
        row: row,
        onPick: (left) async {
          Navigator.pop(sheetContext);
          final r = await _call('pharmacy_lot_correct', {
            'p_lot_id': row['lot_id'],
            'p_left': left,
          });
          if (!mounted) return;
          _toast(r);
          await _load();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        title: Text(p == null ? '' : _s(p, 'title')),
      ),
      body: p == null
          ? const _Skeleton()
          : InferenceView(payload: p, onCorrect: _correct),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 4; i++) ...[
            Container(
              height: Ds.space.x48 * 2,
              decoration: BoxDecoration(
                color: Ds.c.divider,
                borderRadius: Ds.r.rCard,
              ),
            ),
            SizedBox(height: Ds.space.x12),
          ],
        ],
      );
}

/// The entry tile on the counter. Its label is backend copy, so clearing the
/// copy removes the entry with no deploy.
class InferenceEntryTile extends StatelessWidget {
  final PosRpc? rpc;
  final String label;
  const InferenceEntryTile({super.key, required this.label, this.rpc});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c424_infer_entry', 1);
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PharmacyInferenceScreen(rpc: rpc),
        ),
      ),
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16,
          vertical: Ds.space.x12,
        ),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Row(
          children: [
            Icon(Icons.inventory_2_outlined,
                size: Ds.space.x24, color: Ds.c.brand),
            SizedBox(width: Ds.space.x12),
            Expanded(child: Text(label, style: Ds.t.bodyStrong)),
            Icon(Icons.chevron_right,
                size: Ds.space.x24, color: Ds.c.textSecondary),
          ],
        ),
      ),
    );
  }
}
