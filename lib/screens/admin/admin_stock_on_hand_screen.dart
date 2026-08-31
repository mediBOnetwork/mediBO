import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// CHANGE #396 — Stock on hand.
///
/// mediBO buys per order, so the number that matters is the goods NO live
/// order has claimed: a supplier over-supplied, an order was cancelled after
/// receipt, a delivery came back, or a receipt has simply sat unpacked while
/// its order went quiet. `stock_on_hand` derives all of that from the live
/// fulfilment tables and returns every heading, chip, tone, age string and
/// already-formatted ₹ figure. This file computes nothing — not an age, not a
/// total, not a rupee sign.
class AdminStockOnHandScreen extends StatefulWidget {
  const AdminStockOnHandScreen({super.key});

  /// Test seam — feed payloads in without Supabase.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcOverride;

  @override
  State<AdminStockOnHandScreen> createState() => _AdminStockOnHandScreenState();
}

class _AdminStockOnHandScreenState extends State<AdminStockOnHandScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _busy = false;
  String _error = '';
  String _kind = '';
  final TextEditingController _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) {
    final o = AdminStockOnHandScreen.rpcOverride;
    if (o != null) return o(fn, params);
    return params == null
        ? Supabase.instance.client.rpc(fn)
        : Supabase.instance.client.rpc(fn, params: params);
  }

  Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final m = _asMap(await _rpc('stock_on_hand', {
        'p_q': _q.text.trim(),
        'p_kind': _kind,
        'p_limit': 200,
        'p_offset': 0,
      }));
      if (!mounted) return;
      setState(() {
        _data = m;
        _loading = false;
      });
      RenderLog.write('c396_stock_screen', 'painted');
      RenderLog.write(
          'c396_stock_rows', '${(m['rows'] as List?)?.length ?? 0}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _rescan() async {
    setState(() => _busy = true);
    try {
      final m = _asMap(await _rpc('stock_rescan'));
      final msg = (m['message'] ?? '').toString();
      if (mounted && msg.isNotEmpty) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
      // the reload below shows whatever the backend really has
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Color _tone(String? tone) {
    switch (tone) {
      case 'brand':
        return Ds.c.brand;
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.text;
    }
  }

  Color _toneSoft(String? tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.bg;
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final refused = d != null && d['ok'] == false;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text((d?['title'] ?? '').toString()),
        actions: [
          if (d != null && !refused)
            TextButton(
              onPressed: _busy ? null : _rescan,
              child: Text((d['refresh_label'] ?? '').toString()),
            ),
        ],
      ),
      body: _loading
          ? _skeleton()
          : refused
              ? _message((d['message'] ?? '').toString())
              : _error.isNotEmpty
                  ? _retry()
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _body(d ?? const <String, dynamic>{}),
                    ),
    );
  }

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 6; i++)
            Container(
              height: Ds.space.x48,
              margin: EdgeInsets.only(bottom: Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                border: Border.all(color: Ds.c.divider),
              ),
            ),
        ],
      );

  Widget _message(String text) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(text, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
        ),
      );

  Widget _retry() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
              SizedBox(height: Ds.space.x16),
              FilledButton(
                  onPressed: _load,
                  child: Text((_data?['retry_label'] ?? '').toString())),
            ],
          ),
        ),
      );

  Widget _body(Map<String, dynamic> d) {
    final rows = (d['rows'] as List?) ?? const [];
    final kinds = (d['kinds'] as List?) ?? const [];
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text((d['subtitle'] ?? '').toString(), style: Ds.t.bodySecondary),
        SizedBox(height: Ds.space.x16),
        _tiles((d['tiles'] as List?) ?? const []),
        SizedBox(height: Ds.space.x24),
        _search(),
        if (kinds.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          _kindChips(kinds),
        ],
        SizedBox(height: Ds.space.x16),
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
            child: Text((d['empty_label'] ?? '').toString(),
                style: Ds.t.bodySecondary, textAlign: TextAlign.center),
          )
        else
          for (final r in rows)
            if (r is Map) _lotCard(Map<String, dynamic>.from(r), d),
        SizedBox(height: Ds.space.x32),
      ],
    );
  }

  Widget _tiles(List<dynamic> tiles) => LayoutBuilder(
        builder: (context, box) {
          final cols = box.maxWidth >= 640 ? 4 : 2;
          final gap = Ds.space.x12;
          final w = (box.maxWidth - gap * (cols - 1)) / cols;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final t in tiles)
                if (t is Map)
                  SizedBox(
                    width: w,
                    child: _tile(Map<String, dynamic>.from(t)),
                  ),
            ],
          );
        },
      );

  Widget _tile(Map<String, dynamic> t) => Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text((t['label'] ?? '').toString(),
                style: Ds.t.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
            SizedBox(height: Ds.space.x8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text((t['value'] ?? '').toString(),
                  style: Ds.t.title.copyWith(
                      color: _tone((t['tone'] ?? '').toString()))),
            ),
          ],
        ),
      );

  Widget _search() => SizedBox(
        height: Ds.space.x48,
        child: TextField(
          controller: _q,
          onSubmitted: (_) => _load(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              icon: const Icon(Icons.arrow_forward),
              onPressed: _load,
            ),
          ),
        ),
      );

  Widget _kindChips(List<dynamic> kinds) => Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: [
          for (final k in kinds)
            if (k is Map)
              ChoiceChip(
                selected: _kind == (k['key'] ?? '').toString(),
                label: Text((k['chip_label'] ?? '').toString(),
                    style: Ds.t.caption),
                onSelected: (on) {
                  setState(() => _kind = on ? (k['key'] ?? '').toString() : '');
                  _load();
                },
              ),
        ],
      );

  Widget _lotCard(Map<String, dynamic> r, Map<String, dynamic> d) => Container(
        margin: EdgeInsets.only(bottom: Ds.space.x12),
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text((r['product_name'] ?? '').toString(),
                      style: Ds.t.bodyStrong),
                ),
                SizedBox(width: Ds.space.x12),
                Text((r['value_display'] ?? '').toString(),
                    style: Ds.t.bodyStrong),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            Row(
              children: [
                _chip((r['age_label'] ?? '').toString(),
                    (r['age_tone'] ?? '').toString()),
                SizedBox(width: Ds.space.x8),
                _chip((r['source_label'] ?? '').toString(), 'info'),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            Text((r['qty_rate_display'] ?? '').toString(),
                style: Ds.t.bodySecondary),
            SizedBox(height: Ds.space.x4),
            Text((r['batch_label'] ?? '').toString(), style: Ds.t.caption),
            Text((r['expiry_label'] ?? '').toString(), style: Ds.t.caption),
            if ((r['source_order_label'] ?? '').toString().isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text((r['source_order_label'] ?? '').toString(),
                  style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x12),
            SizedBox(
              height: Ds.space.x48,
              child: OutlinedButton(
                onPressed: _busy ? null : () => _writeOff(r, d),
                child: Text((d['writeoff_label'] ?? '').toString()),
              ),
            ),
          ],
        ),
      );

  Widget _chip(String label, String tone) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: _toneSoft(tone),
          borderRadius: Ds.r.rChip,
        ),
        child: Text(label, style: Ds.t.caption.copyWith(color: _tone(tone))),
      );

  Future<void> _writeOff(Map<String, dynamic> r, Map<String, dynamic> d) async {
    setState(() => _busy = true);
    try {
      final m = _asMap(await _rpc('stock_write_off', {
        'p_lot_id': r['lot_id'],
        'p_reason': (d['writeoff_label'] ?? '').toString(),
      }));
      final msg = (m['message'] ?? '').toString();
      if (mounted && msg.isNotEmpty) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
      // the reload shows the true state either way
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }
}
