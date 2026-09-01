// CMD #423 — THE BILL VAULT. A Tier-0 pharmacy's stock register, built out of
// the only data it actually has: the bills in its drawer.
//
// THREE DOORS, ONE SCREEN. A mediBO delivery fills the vault by itself and this
// screen simply shows it arriving. An outside distributor's bill is
// photographed at the counter. A shoebox of old bills is emptied in one sitting
// and read afterwards. The cold-start rack photo is the fourth affordance for
// the shop that has none of the three yet.
//
// THIS FILE COMPUTES NOTHING. Every rupee, month name, status chip, plural,
// tone, progress line, capture instruction, match explanation and refusal
// sentence arrives finished from `pharmacy_vault_home()` and its siblings.
// There is no date formatting here, no percentage, no total, no plural rule and
// no decision about whether a line needs a human — `flag`, `needs_review`,
// `can_confirm` and `percent` are all the backend's answers, printed verbatim.
//
// AND IT NEVER HIDES A DOUBT. A line the camera could not read is drawn as
// exactly that, in the backend's words, with the affordance to fix it. The one
// thing that would destroy a pharmacist's trust is a number the app invented,
// so the screen's job is to make the invented number impossible and the
// unreadable one obvious.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_vault_api.dart';
import '../../utils/render_log.dart';
import 'pharmacy_expiry_screen.dart' show toneColor, toneSoft;

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

/// The vault. One RPC in, one screen out.
class PharmacyVaultScreen extends StatefulWidget {
  const PharmacyVaultScreen({super.key, this.rpc});

  /// Injected in tests so the screen is proven against a payload, never a
  /// network.
  final VaultRpc? rpc;

  @override
  State<PharmacyVaultScreen> createState() => _PharmacyVaultScreenState();
}

class _PharmacyVaultScreenState extends State<PharmacyVaultScreen> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;
  String? _month;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null
      ? widget.rpc!(fn, p)
      : PharmacyVaultApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> res;
    try {
      res = await _call('pharmacy_vault_home', {
        if (_month != null) 'p_month': _month,
      });
    } catch (_) {
      res = const {};
    }
    if (!mounted) return;
    setState(() {
      _payload = res;
      _loading = false;
    });
    RenderLog.write('vault_bills', _rows(res['bills']).length);
    RenderLog.write('vault_screen', 1);
  }

  @override
  Widget build(BuildContext context) {
    final ok = _payload['ok'] == true;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(_payload['title'])),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? const _VaultSkeleton()
          : !ok
          ? _Refusal(message: _s(_payload['message']), onRetry: _load)
          : RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    final bills = _rows(_payload['bills']);
    final months = _rows(_payload['months']);
    final batch = _m(_payload['batch']);
    final unquantified = _s(_payload['unquantified_label']);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(_payload['subtitle']), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        _Tiles(tiles: _rows(_payload['tiles'])),
        SizedBox(height: Ds.space.x24),
        _Actions(
          actions: _rows(_payload['actions']),
          onPick: _startDoor,
        ),
        if (batch.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _BatchStrip(batch: batch),
        ],
        if (unquantified.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          _Note(text: unquantified),
        ],
        if (months.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _Months(months: months, onPick: _pickMonth),
        ],
        SizedBox(height: Ds.space.x24),
        if (bills.isEmpty)
          _Empty(text: _s(_payload['empty']))
        else
          ...bills.map(
            (b) => Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: _BillCard(bill: b, onOpen: () => _openBill(b)),
            ),
          ),
      ],
    );
  }

  void _pickMonth(Map<String, dynamic> m) {
    // The key the BACKEND put on the chip — never a date this screen built.
    setState(() => _month = m['selected'] == true ? null : _s(m['month_key']));
    _load();
  }

  /// The door the backend offered, opened with the key the backend gave it.
  Future<void> _startDoor(Map<String, dynamic> action) async {
    final key = _s(action['key']);
    final res = key == 'bulk'
        ? await _call('pharmacy_vault_batch_start', const {})
        : await _call('pharmacy_vault_bill_start', {
            'p_source': key == 'shelf' ? 'shelf' : 'photo',
          });
    if (!mounted) return;
    if (res['ok'] != true) {
      _toast(_s(res['message']));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _CaptureSheet(payload: res, doorKey: key),
    );
    if (mounted) _load();
  }

  Future<void> _openBill(Map<String, dynamic> bill) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VaultBillScreen(
          billId: _s(bill['bill_id']),
          rpc: widget.rpc,
        ),
      ),
    );
    if (mounted) _load();
  }

  void _toast(String msg) {
    if (msg.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

// ─────────────────────────── the pieces ─────────────────────────────────────

class _Tiles extends StatelessWidget {
  const _Tiles({required this.tiles});
  final List<Map<String, dynamic>> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final wide = c.maxWidth >= 560;
        return Wrap(
          spacing: Ds.space.x12,
          runSpacing: Ds.space.x12,
          children: tiles.map((t) {
            final w = wide
                ? (c.maxWidth - Ds.space.x12 * 3) / 4
                : (c.maxWidth - Ds.space.x12) / 2;
            return SizedBox(
              width: w,
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
                    Text(
                      _s(t['value']),
                      style: Ds.t.title.copyWith(
                        color: toneColor(_s(t['tone'])) == Ds.c.textSecondary
                            ? Ds.c.text
                            : toneColor(_s(t['tone'])),
                      ),
                    ),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(t['label']), style: Ds.t.caption),
                  ],
                ),
              ),
            );
          }).toList(),
        );
      },
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.actions, required this.onPick});
  final List<Map<String, dynamic>> actions;
  final void Function(Map<String, dynamic>) onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: actions.map((a) {
        final primary = a['primary'] == true;
        return Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x8),
          child: SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: primary
                ? FilledButton(
                    onPressed: () => onPick(a),
                    style: FilledButton.styleFrom(
                      backgroundColor: Ds.c.brand,
                      shape: RoundedRectangleBorder(
                        borderRadius: Ds.r.rButton,
                      ),
                    ),
                    child: Text(_s(a['label'])),
                  )
                : OutlinedButton(
                    onPressed: () => onPick(a),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Ds.c.brand,
                      side: BorderSide(color: Ds.c.divider),
                      shape: RoundedRectangleBorder(
                        borderRadius: Ds.r.rButton,
                      ),
                    ),
                    child: Text(_s(a['label'])),
                  ),
          ),
        );
      }).toList(),
    );
  }
}

/// Progress for a bulk sitting. The percentage and the "9 of 12 read" line are
/// both the backend's — this bar only draws what it was handed.
class _BatchStrip extends StatelessWidget {
  const _BatchStrip({required this.batch});
  final Map<String, dynamic> batch;

  @override
  Widget build(BuildContext context) {
    final pct = (batch['percent'] is num)
        ? (batch['percent'] as num).toDouble() / 100
        : 0.0;
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
          Text(_s(batch['progress_label']), style: Ds.t.bodyStrong),
          SizedBox(height: Ds.space.x12),
          ClipRRect(
            borderRadius: Ds.r.rChip,
            child: LinearProgressIndicator(
              value: pct,
              minHeight: Ds.space.x8,
              backgroundColor: Ds.c.bg,
              valueColor: AlwaysStoppedAnimation<Color>(Ds.c.brand),
            ),
          ),
          for (final k in const ['review_label', 'duplicate_label'])
            if (_s(batch[k]).isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(_s(batch[k]), style: Ds.t.caption),
            ],
        ],
      ),
    );
  }
}

class _Months extends StatelessWidget {
  const _Months({required this.months, required this.onPick});
  final List<Map<String, dynamic>> months;
  final void Function(Map<String, dynamic>) onPick;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: Ds.touch.minTarget,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: months.length,
        separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
        itemBuilder: (_, i) {
          final m = months[i];
          final on = m['selected'] == true;
          return InkWell(
            onTap: () => onPick(m),
            borderRadius: Ds.r.rChip,
            child: Container(
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              decoration: BoxDecoration(
                color: on ? Ds.c.brandSoft : Ds.c.surface,
                borderRadius: Ds.r.rChip,
                border: Border.all(color: on ? Ds.c.brand : Ds.c.divider),
              ),
              child: Text(
                _s(m['label']),
                style: on ? Ds.t.bodyStrong : Ds.t.body,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BillCard extends StatelessWidget {
  const _BillCard({required this.bill, required this.onOpen});
  final Map<String, dynamic> bill;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final chip = _m(bill['chip']);
    return InkWell(
      onTap: onOpen,
      borderRadius: Ds.r.rCard,
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
              children: [
                Expanded(
                  child: Text(_s(bill['supplier']), style: Ds.t.bodyStrong),
                ),
                SizedBox(width: Ds.space.x8),
                _Chip(label: _s(chip['label']), tone: _s(chip['tone'])),
              ],
            ),
            SizedBox(height: Ds.space.x4),
            Text(_s(bill['meta']), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                Text(_s(bill['source_label']), style: Ds.t.caption),
                const Spacer(),
                Text(_s(bill['lines_label']), style: Ds.t.caption),
                if (bill['has_amount'] == true) ...[
                  SizedBox(width: Ds.space.x12),
                  Text(_s(bill['amount']), style: Ds.t.bodyStrong),
                ],
              ],
            ),
            if (_s(bill['reason']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                _s(bill['reason']),
                style: Ds.t.caption.copyWith(color: Ds.c.warning),
              ),
            ],
            if (_s(bill['error']).isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(
                _s(bill['error']),
                style: Ds.t.caption.copyWith(color: Ds.c.danger),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.tone});
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
        color: toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(
        label,
        style: Ds.t.caption.copyWith(color: toneColor(tone)),
      ),
    );
  }
}

/// The capture sheet: the backend's own instructions, then the shutter. The
/// checklist is a payload array — this widget owns not one word of it.
class _CaptureSheet extends StatelessWidget {
  const _CaptureSheet({required this.payload, required this.doorKey});
  final Map<String, dynamic> payload;
  final String doorKey;

  @override
  Widget build(BuildContext context) {
    final points = (payload['guide_points'] is List)
        ? (payload['guide_points'] as List).map(_s).toList()
        : const <String>[];
    return Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(payload['guide']), style: Ds.t.body),
          if (points.isNotEmpty) SizedBox(height: Ds.space.x16),
          ...points.map(
            (p) => Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: Ds.t.bodySize,
                    color: Ds.c.brand,
                  ),
                  SizedBox(width: Ds.space.x8),
                  Expanded(child: Text(p, style: Ds.t.caption)),
                ],
              ),
            ),
          ),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: Text(_s(payload['message']).isEmpty
                  ? _s(payload['guide']).isEmpty
                        ? ''
                        : _s(payload['guide'])
                  : _s(payload['message'])),
            ),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(Ds.space.x16),
    decoration: BoxDecoration(
      color: Ds.c.warningSoft,
      borderRadius: Ds.r.rCard,
    ),
    child: Text(text, style: Ds.t.caption.copyWith(color: Ds.c.text)),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: Ds.space.x48),
    child: Text(text, textAlign: TextAlign.center, style: Ds.t.bodySecondary),
  );
}

class _Refusal extends StatelessWidget {
  const _Refusal({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center, style: Ds.t.body),
          SizedBox(height: Ds.space.x16),
          OutlinedButton(onPressed: onRetry, child: const Text('↻')),
        ],
      ),
    ),
  );
}

/// A skeleton, not a bare spinner — the shape of what is coming.
class _VaultSkeleton extends StatelessWidget {
  const _VaultSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: List.generate(
      4,
      (_) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Container(
          height: Ds.space.x48 + Ds.space.x24,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
          ),
        ),
      ),
    ),
  );
}

// ─────────────────────────── one bill, and its doubts ───────────────────────

/// The review lane for ONE bill. Every line the camera was unsure about, with
/// the backend's own words for WHY, and nothing else.
class VaultBillScreen extends StatefulWidget {
  const VaultBillScreen({super.key, required this.billId, this.rpc});
  final String billId;
  final VaultRpc? rpc;

  @override
  State<VaultBillScreen> createState() => _VaultBillScreenState();
}

class _VaultBillScreenState extends State<VaultBillScreen> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null
      ? widget.rpc!(fn, p)
      : PharmacyVaultApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, dynamic> res;
    try {
      res = await _call('pharmacy_vault_bill_get', {
        'p_bill_id': widget.billId,
      });
    } catch (_) {
      res = const {};
    }
    if (!mounted) return;
    setState(() {
      _payload = res;
      _loading = false;
    });
    RenderLog.write('vault_bill_lines', _rows(res['lines']).length);
  }

  @override
  Widget build(BuildContext context) {
    final bill = _m(_payload['bill']);
    final lines = _rows(_payload['lines']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(bill['supplier'])),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? const _VaultSkeleton()
          : _payload['ok'] != true
          ? _Refusal(message: _s(_payload['message']), onRetry: _load)
          : ListView(
              padding: EdgeInsets.all(Ds.space.x16),
              children: [
                Text(_s(bill['meta']), style: Ds.t.caption),
                SizedBox(height: Ds.space.x16),
                ...lines.map(
                  (l) => Padding(
                    padding: EdgeInsets.only(bottom: Ds.space.x12),
                    child: _LineCard(line: l),
                  ),
                ),
                if (bill['can_confirm'] == true) ...[
                  SizedBox(height: Ds.space.x24),
                  SizedBox(
                    width: double.infinity,
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      onPressed: _confirm,
                      style: FilledButton.styleFrom(
                        backgroundColor: Ds.c.brand,
                        shape: RoundedRectangleBorder(
                          borderRadius: Ds.r.rButton,
                        ),
                      ),
                      child: Text(_s(_payload['confirm_label'])),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  Future<void> _confirm() async {
    final res = await _call('pharmacy_vault_bill_confirm', {
      'p_bill_id': widget.billId,
    });
    if (!mounted) return;
    final msg = _s(res['message']);
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    if (res['ok'] == true) Navigator.of(context).pop();
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.line});
  final Map<String, dynamic> line;

  @override
  Widget build(BuildContext context) {
    final needs = line['needs_review'] == true;
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: needs
            ? Border.all(color: toneColor(_s(line['flag_tone'])))
            : Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s(line['product']), style: Ds.t.bodyStrong),
              ),
              if (_s(line['flag_label']).isNotEmpty) ...[
                SizedBox(width: Ds.space.x8),
                _Chip(
                  label: _s(line['flag_label']),
                  tone: _s(line['flag_tone']),
                ),
              ],
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Row(
            children: [
              Expanded(
                child: Text(_s(line['meta']), style: Ds.t.caption),
              ),
              Text(_s(line['qty_label']), style: Ds.t.body),
              if (line['has_cost'] == true) ...[
                SizedBox(width: Ds.space.x12),
                Text(_s(line['cost']), style: Ds.t.bodyStrong),
              ],
            ],
          ),
          if (_s(line['match_label']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(line['match_label']), style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}
