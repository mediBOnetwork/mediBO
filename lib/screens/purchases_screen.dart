import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/download_bytes.dart';
import '../utils/render_log.dart';

/// CMD #367 · feature_gaps row 174 — the pharmacy's own purchase analytics.
///
/// One RPC in (`my_purchases_screen`), one payload printed verbatim: the
/// summary tiles, the month bars, the two leaderboards and the register card
/// all arrive already computed and already worded. This screen adds up
/// nothing, formats no money, pluralises no label and decides no colour beyond
/// mapping the backend's own `tone` string onto a design token.
///
/// The register itself is generated server-side too
/// (`purchase_register_export`): CSV for reconciliation, and a complete print
/// document for "save as PDF". The app only hands the bytes to the browser.
class PurchasesScreen extends StatefulWidget {
  const PurchasesScreen({super.key});

  @override
  State<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends State<PurchasesScreen> {
  final _sb = Supabase.instance.client;
  bool _loading = true;
  bool _busy = false;
  Map<String, dynamic>? _p;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await _sb.rpc('my_purchases_screen', params: {'p_months': 12});
      if (!mounted) return;
      setState(() {
        _p = (r is Map) ? Map<String, dynamic>.from(r) : null;
        _loading = false;
      });
      RenderLog.write('purchases_screen', {
        'has_data': _b('has_data'),
        'summary_tiles': _list('summary').length,
        'months': _list('months').length,
        'top_products': _list('top_products').length,
        'register_rows': (_map('register')['row_count'] ?? 0),
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _p = null;
        _loading = false;
      });
    }
  }

  // ── payload readers: absence is '' / [] / {}, never a guess ───────────────
  String _s(String k) => (_p?[k] ?? '').toString();
  bool _b(String k) => _p?[k] == true;
  List<Map<String, dynamic>> _list(String k) {
    final v = _p?[k];
    if (v is! List) return const [];
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Map<String, dynamic> _map(String k) {
    final v = _p?[k];
    return v is Map ? Map<String, dynamic>.from(v) : const {};
  }

  Color _tone(String tone) {
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
        return Ds.c.textSecondary;
    }
  }

  Future<void> _export(String format) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = await _sb.rpc('purchase_register_export',
          params: {'p_format': format, 'p_from': null, 'p_to': null});
      final m = (r is Map) ? Map<String, dynamic>.from(r) : const {};
      if (m['ok'] != true) {
        if (mounted) {
          showToast(context, (m['message'] ?? '').toString(), isError: true);
        }
        return;
      }
      final bytes = utf8.encode((m['content'] ?? '').toString());
      downloadBytes(bytes, (m['filename'] ?? '').toString(),
          (m['mime'] ?? '').toString());
      if (mounted) showToast(context, (m['toast'] ?? '').toString());
    } catch (_) {
      // The backend owns every message; a transport failure gets the same
      // empty-state treatment as a failed load rather than an invented string.
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s('title').isEmpty
            ? (_map('copy')['title'] ?? '').toString()
            : _s('title')),
      ),
      body: _loading
          ? const _PurchasesSkeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: _p == null || !_b('has_data') ? _empty() : _content(),
            ),
    );
  }

  Widget _empty() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          SizedBox(height: Ds.space.x48),
          Icon(Icons.receipt_long_outlined,
              size: Ds.space.x48, color: Ds.c.textSecondary),
          SizedBox(height: Ds.space.x16),
          Text(_s('empty_title'),
              textAlign: TextAlign.center, style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(_s('empty_note'),
              textAlign: TextAlign.center, style: Ds.t.caption),
        ],
      );

  Widget _content() {
    final summary = _list('summary');
    final months = _list('months');
    final products = _list('top_products');
    final companies = _list('top_companies');
    final register = _map('register');

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        if (_s('period_label').isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Text(_s('period_label'), style: Ds.t.caption),
          ),
        _card(
          // Two tiles per row at any width — proportional, never a fixed px.
          child: LayoutBuilder(
            builder: (context, cs) {
              final w = (cs.maxWidth - Ds.space.x16) / 2;
              return Wrap(
                spacing: Ds.space.x16,
                runSpacing: Ds.space.x16,
                children: [
                  for (final t in summary)
                    SizedBox(
                      width: w,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text((t['label'] ?? '').toString(),
                              style: Ds.t.caption),
                          SizedBox(height: Ds.space.x4),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              (t['value'] ?? '').toString(),
                              style: Ds.t.subtitle.copyWith(
                                  color: _tone((t['tone'] ?? '').toString())),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        if (months.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _sectionTitle(_s('months_title')),
          SizedBox(height: Ds.space.x12),
          _card(child: MonthBars(months: months)),
        ],
        if (products.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _sectionTitle(_s('products_title')),
          SizedBox(height: Ds.space.x12),
          _card(
            child: Column(
              children: [
                for (var i = 0; i < products.length; i++)
                  _leaderRow(
                    rank: (products[i]['rank_label'] ?? '').toString(),
                    title: (products[i]['name'] ?? '').toString(),
                    sub: [
                      (products[i]['company'] ?? '').toString(),
                      (products[i]['qty_label'] ?? '').toString(),
                    ].where((s) => s.isNotEmpty).join(' · '),
                    value: (products[i]['spend_display'] ?? '').toString(),
                    note: (products[i]['share_label'] ?? '').toString(),
                    last: i == products.length - 1,
                  ),
              ],
            ),
          ),
        ],
        if (companies.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _sectionTitle(_s('companies_title')),
          SizedBox(height: Ds.space.x12),
          _card(
            child: Column(
              children: [
                for (var i = 0; i < companies.length; i++)
                  _leaderRow(
                    rank: (companies[i]['rank_label'] ?? '').toString(),
                    title: (companies[i]['name'] ?? '').toString(),
                    sub: '',
                    value: (companies[i]['spend_display'] ?? '').toString(),
                    note: (companies[i]['share_label'] ?? '').toString(),
                    last: i == companies.length - 1,
                  ),
              ],
            ),
          ),
        ],
        SizedBox(height: Ds.space.x24),
        _registerCard(register),
        SizedBox(height: Ds.space.x32),
      ],
    );
  }

  Widget _sectionTitle(String s) => Text(s, style: Ds.t.subtitle);

  Widget _card({required Widget child}) => Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: child,
      );

  Widget _leaderRow({
    required String rank,
    required String title,
    required String sub,
    required String value,
    required String note,
    required bool last,
  }) =>
      Container(
        constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
        padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
        decoration: last
            ? null
            : BoxDecoration(
                border: Border(bottom: BorderSide(color: Ds.c.divider)),
              ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: Ds.space.x32,
              child: Text(rank, style: Ds.t.caption),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.body),
                  if (sub.isNotEmpty)
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.caption),
                ],
              ),
            ),
            SizedBox(width: Ds.space.x12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(value,
                    style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
                if (note.isNotEmpty) Text(note, style: Ds.t.caption),
              ],
            ),
          ],
        ),
      );

  Widget _registerCard(Map<String, dynamic> r) =>
      RegisterCard(register: r, busy: _busy, onExport: _export);
}

/// The register card, extracted so the protected suite can pump it with a
/// fixture: which buttons exist, in what order and with what captions is the
/// BACKEND's `formats[]` — never a Dart list of ['csv','pdf'].
class RegisterCard extends StatelessWidget {
  final Map<String, dynamic> register;
  final bool busy;
  final void Function(String format) onExport;
  const RegisterCard({
    super.key,
    required this.register,
    required this.busy,
    required this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final r = register;
    final formats = (r['formats'] is List)
        ? (r['formats'] as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList()
        : const <Map<String, dynamic>>[];
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
          Text((r['title'] ?? '').toString(), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text((r['note'] ?? '').toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          if (r['available'] != true)
            Text((r['empty_note'] ?? '').toString(), style: Ds.t.caption)
          else ...[
            Text((r['count_label'] ?? '').toString(), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            for (final f in formats)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: SizedBox(
                  width: double.infinity,
                  height: Ds.touch.minTarget,
                  child: (f['key'] == 'csv')
                      ? FilledButton.icon(
                          onPressed: busy
                              ? null
                              : () => onExport((f['key'] ?? '').toString()),
                          icon: const Icon(Icons.download_outlined),
                          label: Text((f['label'] ?? '').toString()),
                          style: FilledButton.styleFrom(
                            backgroundColor: Ds.c.brand,
                            shape: RoundedRectangleBorder(
                                borderRadius: Ds.r.rButton),
                          ),
                        )
                      : OutlinedButton.icon(
                          onPressed: busy
                              ? null
                              : () => onExport((f['key'] ?? '').toString()),
                          icon: const Icon(Icons.print_outlined),
                          label: Text((f['label'] ?? '').toString()),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Ds.c.brand,
                            side: BorderSide(color: Ds.c.brand),
                            shape: RoundedRectangleBorder(
                                borderRadius: Ds.r.rButton),
                          ),
                        ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// The month bars. The BACKEND sends `bar_pct` — this widget never divides one
/// month's spend by another's to find the tallest.
class MonthBars extends StatelessWidget {
  final List<Map<String, dynamic>> months;
  const MonthBars({super.key, required this.months});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < months.length; i++)
          Padding(
            padding: EdgeInsets.only(
                bottom: i == months.length - 1 ? 0 : Ds.space.x12),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text((months[i]['label'] ?? '').toString(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.caption),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  flex: 8,
                  child: LayoutBuilder(
                    builder: (context, cs) {
                      final pct =
                          ((months[i]['bar_pct'] ?? 0) as num).toDouble() / 100.0;
                      return Stack(
                        children: [
                          Container(
                            height: Ds.space.x8,
                            decoration: BoxDecoration(
                              color: Ds.c.divider,
                              borderRadius: Ds.r.rChip,
                            ),
                          ),
                          Container(
                            height: Ds.space.x8,
                            width: cs.maxWidth * pct.clamp(0.0, 1.0),
                            decoration: BoxDecoration(
                              color: Ds.c.brand,
                              borderRadius: Ds.r.rChip,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  flex: 5,
                  child: Text(
                    (months[i]['spend_display'] ?? '').toString(),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.caption.copyWith(
                      color: months[i]['is_empty'] == true
                          ? Ds.c.textSecondary
                          : Ds.c.text,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A skeleton, not a bare spinner (design QA check 6).
class _PurchasesSkeleton extends StatelessWidget {
  const _PurchasesSkeleton();
  @override
  Widget build(BuildContext context) {
    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          margin: EdgeInsets.only(bottom: Ds.space.x12),
          decoration: BoxDecoration(
            color: Ds.c.divider,
            borderRadius: Ds.r.rChip,
          ),
        );
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Container(
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [bar(160, Ds.space.x16), bar(120, Ds.space.x24)],
          ),
        ),
        SizedBox(height: Ds.space.x24),
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
              for (var i = 0; i < 5; i++) bar(double.infinity, Ds.space.x16),
            ],
          ),
        ),
      ],
    );
  }
}
