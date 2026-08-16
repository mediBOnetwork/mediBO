// CHANGE #174 — "Product pricing": the admin surface that turns a product from
// MRP-only into a real B2B listing.
//
// mediBO sells on PTR ± discount + GST, but no PTR data exists yet — it arrives
// two ways: automatically off supplier bills (a trigger on bill_lines), and by
// hand here, top-selling products first. The moment a row is saved the
// storefront, the PDP and the cart start showing net rate and margin for it.
// Nothing else has to happen and nothing has to be deployed.
//
// Backend-owned, as every screen is: `admin_pricing_list()` returns the title,
// the subtitle, the coverage line, every field label, the status chip's words
// AND its two colours. This file lays those out. It computes no price, formats
// no money and words no status — the one number it produces is the qty the
// admin typed, sent straight back to `product_pricing_upsert()`.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

class PricingBackfillScreen extends StatefulWidget {
  /// Test seam: production goes to Supabase, a test supplies a payload.
  final Future<Map<String, dynamic>> Function(String search, int offset)? loader;

  /// Test seam for the save call.
  final Future<Map<String, dynamic>> Function(
      int productId, Map<String, dynamic> fields)? saver;

  const PricingBackfillScreen({super.key, this.loader, this.saver});

  @override
  State<PricingBackfillScreen> createState() => _PricingBackfillScreenState();
}

class _PricingBackfillScreenState extends State<PricingBackfillScreen> {
  Map<String, dynamic> _payload = const {};
  final List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String _query = '';
  int _offset = 0;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(String search, int offset) async {
    final load = widget.loader ??
        (String s, int o) async {
          final res = await Supabase.instance.client.rpc(
            'admin_pricing_list',
            params: {'p_search': s, 'p_offset': o, 'p_limit': 40},
          );
          return Map<String, dynamic>.from(
              (res is List ? res.first : res) as Map);
        };
    return load(search, offset);
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final m = await _call(_query, more ? _offset : 0);
      if (!mounted) return;
      final rows = ((m['rows'] as List?) ?? const [])
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      setState(() {
        _payload = m;
        if (!more) _rows.clear();
        _rows.addAll(rows);
        _offset = (m['next_offset'] as num?)?.toInt() ?? _rows.length;
        _loading = false;
        _loadingMore = false;
      });
      RenderLog.write('c174_pricing_admin',
          'rows=${_rows.length};coverage=${_coverage['pct'] ?? ''}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.toString();
      });
    }
  }

  Map<String, dynamic> get _coverage =>
      (_payload['coverage'] as Map?)?.cast<String, dynamic>() ?? const {};

  String _label(String key) =>
      ((_payload['labels'] as Map?)?[key] ?? '').toString();

  Future<void> _save(Map<String, dynamic> row, Map<String, dynamic> fields) async {
    final id = (row['product_id'] as num).toInt();
    final save = widget.saver ??
        (int pid, Map<String, dynamic> f) async {
          final res = await Supabase.instance.client.rpc(
            'product_pricing_upsert',
            params: {'p_product_id': pid, 'p_fields': f, 'p_source': 'manual'},
          );
          return Map<String, dynamic>.from(
              (res is List ? res.first : res) as Map);
        };
    final res = await save(id, fields);
    if (!mounted) return;
    if (res['ok'] == true) {
      showToast(context, _label('saved'));
      // Re-read rather than patching the row locally: pricing_ready, the net
      // rate and the coverage percentage are all the backend's answers.
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        elevation: 0.5,
        title: Text((_payload['title'] ?? '').toString(), style: Ds.t.subtitle),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorState(message: _error!, onRetry: _load)
              : _body(),
    );
  }

  Widget _body() {
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
      children: [
        _CoverageCard(
          subtitle: (_payload['subtitle'] ?? '').toString(),
          label: (_coverage['label'] ?? '').toString(),
          detail: (_coverage['detail'] ?? '').toString(),
          pct: ((_coverage['pct'] as num?)?.toDouble() ?? 0) / 100.0,
        ),
        SizedBox(height: Ds.space.x16),
        TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: _label('search_hint'),
            prefixIcon: const Icon(Icons.search),
          ),
          onSubmitted: (v) {
            _query = v.trim();
            _load();
          },
        ),
        SizedBox(height: Ds.space.x16),
        if (_rows.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
            child: Text(_label('empty'),
                textAlign: TextAlign.center, style: Ds.t.bodySecondary),
          ),
        for (final r in _rows) ...[
          _PricingRowCard(
            row: r,
            label: _label,
            onSave: (fields) => _save(r, fields),
          ),
          SizedBox(height: Ds.space.x12),
        ],
        if (_payload['has_more'] == true)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x8),
            child: OutlinedButton(
              onPressed: _loadingMore ? null : () => _load(more: true),
              child: Text(_label('more')),
            ),
          ),
      ],
    );
  }
}

/// Coverage: how much of the catalogue can already show a real net rate.
class _CoverageCard extends StatelessWidget {
  final String subtitle;
  final String label;
  final String detail;
  final double pct;

  const _CoverageCard({
    required this.subtitle,
    required this.label,
    required this.detail,
    required this.pct,
  });

  @override
  Widget build(BuildContext context) {
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
          Text(label, style: Ds.t.display),
          SizedBox(height: Ds.space.x8),
          ClipRRect(
            borderRadius: Ds.r.rChip,
            child: LinearProgressIndicator(
              value: pct.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: Ds.c.divider,
              valueColor: AlwaysStoppedAnimation<Color>(Ds.c.brand),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          Text(detail, style: Ds.t.caption),
          if (subtitle.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(subtitle, style: Ds.t.bodySecondary),
          ],
        ],
      ),
    );
  }
}

/// One product: what it currently is, and four fields to make it real.
class _PricingRowCard extends StatefulWidget {
  final Map<String, dynamic> row;
  final String Function(String) label;
  final Future<void> Function(Map<String, dynamic> fields) onSave;

  const _PricingRowCard({
    required this.row,
    required this.label,
    required this.onSave,
  });

  @override
  State<_PricingRowCard> createState() => _PricingRowCardState();
}

class _PricingRowCardState extends State<_PricingRowCard> {
  late final TextEditingController _ptr;
  late final TextEditingController _gst;
  late final TextEditingController _disc;
  late final TextEditingController _scheme;
  bool _open = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    String s(Object? v) => v == null ? '' : v.toString();
    _ptr = TextEditingController(text: s(widget.row['ptr']));
    _gst = TextEditingController(text: s(widget.row['gst_pct']));
    _disc = TextEditingController(text: s(widget.row['discount_pct']));
    _scheme = TextEditingController(text: s(widget.row['scheme_text']));
  }

  @override
  void dispose() {
    _ptr.dispose();
    _gst.dispose();
    _disc.dispose();
    _scheme.dispose();
    super.dispose();
  }

  /// "10+1" → buy 10, free 1. Parsed here only to SEND it; the engine decides
  /// what a scheme does to a price.
  (double?, double?) _scheme2() {
    final parts = _scheme.text.split('+');
    if (parts.length != 2) return (null, null);
    return (double.tryParse(parts[0].trim()), double.tryParse(parts[1].trim()));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final (buy, free) = _scheme2();
    await widget.onSave({
      'ptr': _ptr.text.trim(),
      'gst_pct': _gst.text.trim(),
      'discount_pct': _disc.text.trim(),
      'scheme_text': _scheme.text.trim(),
      'scheme_buy_qty': buy,
      'scheme_free_qty': free,
    });
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final ready = r['ready'] == true;

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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((r['name'] ?? '').toString(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.body),
                    SizedBox(height: Ds.space.x4),
                    Text(
                      [
                        (r['company'] ?? '').toString(),
                        (r['pack_label'] ?? '').toString(),
                      ].where((s) => s.isNotEmpty).join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.caption,
                    ),
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x12),
              _StatusChip(
                text: (r['status_label'] ?? '').toString(),
                bg: (r['status_bg'] ?? '').toString(),
                fg: (r['status_fg'] ?? '').toString(),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          // What the customer sees right now — the backend's own strings, so
          // this row and the storefront can never disagree.
          Row(
            children: [
              Expanded(
                child: Text((r['mrp_display'] ?? '').toString(),
                    style: Ds.t.bodySecondary),
              ),
              if (ready) ...[
                Text((r['net_display'] ?? '').toString(), style: Ds.t.body),
                SizedBox(width: Ds.space.x12),
                Text((r['margin_label'] ?? '').toString(),
                    style: Ds.t.caption.copyWith(color: Ds.c.brand)),
              ],
            ],
          ),
          if (!_open)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _open = true),
                child: Text(widget.label('save')),
              ),
            ),
          if (_open) ...[
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                Expanded(child: _num(_ptr, widget.label('ptr'))),
                SizedBox(width: Ds.space.x12),
                Expanded(child: _num(_gst, widget.label('gst'))),
              ],
            ),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                Expanded(child: _num(_disc, widget.label('discount'))),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: TextField(
                    controller: _scheme,
                    decoration:
                        InputDecoration(labelText: widget.label('scheme')),
                  ),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: Text(widget.label('save')),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _num(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label),
      );
}

/// Words AND colours from the payload — "Priced" / "MRP only" is a backend
/// verdict about the data, not a client-side null check.
class _StatusChip extends StatelessWidget {
  final String text;
  final String bg;
  final String fg;
  const _StatusChip({required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: Ds.hex(bg, Ds.c.bg),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(text,
          style: Ds.t.caption.copyWith(color: Ds.hex(fg, Ds.c.textSecondary))),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center, style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}
