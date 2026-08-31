import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// CHANGE #319 — Profit & loss.
///
/// This screen computes NOTHING. Not a total, not a percentage, not a rupee
/// sign, not a word. `pnl_dashboard`, `pnl_breakdown`, `pnl_alerts` and
/// `pnl_slab_simulate` return every heading, tab label, tile, empty state and
/// already-formatted ₹ figure from Postgres — margin is taxable minus taxable
/// there, GST excluded on both sides, scheme goods amortised. Re-wording or
/// re-costing the P&L is an UPDATE to pnl_label / pnl_cost_config, never a
/// deploy of this file.
///
/// The only decisions here are which tab is selected and how many days the
/// window is — both sent back to the backend as plain numbers.
class PnlScreen extends StatefulWidget {
  const PnlScreen({super.key});

  /// Test seam: feed payloads in without Supabase, exactly as
  /// NotifyCostScreen does.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcOverride;

  @override
  State<PnlScreen> createState() => _PnlScreenState();
}

class _PnlScreenState extends State<PnlScreen> {
  /// The windows the admin can look through. The WORDS beside them are the
  /// backend's `range_label`; these are only numbers to send.
  static const _windows = <int>[7, 30, 90];

  Map<String, dynamic>? _dash;
  Map<String, dynamic>? _tabData; // breakdown / alerts / simulator payload
  bool _loading = true;
  bool _tabLoading = false;
  String _error = '';
  int _days = 30;
  String _tab = 'overview';

  /// The proposed slab the simulator will replay. Seeded from the backend's
  /// current slab, then edited in place — never invented here.
  final List<Map<String, dynamic>> _proposed = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) {
    final o = PnlScreen.rpcOverride;
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
      final m = _asMap(await _rpc('pnl_dashboard', {'p_days': _days}));
      if (!mounted) return;
      setState(() {
        _dash = m;
        _loading = false;
      });
      RenderLog.write('c319_pnl_screen', 'painted');
      RenderLog.write('c319_pnl_tiles', '${(m['tiles'] as List?)?.length ?? 0}');
      if (_tab != 'overview') await _loadTab();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadTab() async {
    if (_tab == 'overview') {
      setState(() => _tabData = null);
      return;
    }
    setState(() => _tabLoading = true);
    try {
      late final Map<String, dynamic> m;
      if (_tab == 'alerts') {
        m = _asMap(await _rpc('pnl_alerts', {'p_limit': 50}));
      } else if (_tab == 'simulator') {
        m = _asMap(await _rpc('pnl_slab_simulate', {'p_days': _days}));
        _seedProposed(m);
      } else {
        m = _asMap(await _rpc('pnl_breakdown',
            {'p_dim': _tab, 'p_days': _days, 'p_limit': 50}));
      }
      if (!mounted) return;
      setState(() {
        _tabData = m;
        _tabLoading = false;
      });
      RenderLog.write('c319_pnl_tab', _tab);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tabLoading = false;
        _error = e.toString();
      });
    }
  }

  /// The proposal starts as a copy of what is live, so "run" with nothing typed
  /// reproduces today's bills instead of pricing at zero.
  void _seedProposed(Map<String, dynamic> m) {
    if (_proposed.isNotEmpty) return;
    for (final s in (m['current'] as List?) ?? const []) {
      if (s is Map) _proposed.add(Map<String, dynamic>.from(s));
    }
  }

  Future<void> _runSimulation() async {
    setState(() => _tabLoading = true);
    try {
      final m = _asMap(await _rpc('pnl_slab_simulate', {
        'p_slabs': _proposed
            .map((e) => {
                  'min_amount': e['min_amount'],
                  'discount_pct': e['discount_pct'],
                })
            .toList(),
        'p_days': _days,
      }));
      if (!mounted) return;
      setState(() {
        _tabData = m;
        _tabLoading = false;
      });
      RenderLog.write('c319_pnl_sim', 'ran');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tabLoading = false;
        _error = e.toString();
      });
    }
  }

  /// The rates sheet. Every label and the saved toast are the backend's; this
  /// only collects six numbers and posts them back.
  Future<void> _openRates() async {
    final cfg = _asMap(await _rpc('pnl_config_get'));
    if (!mounted) return;
    if (cfg['ok'] == false) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text((cfg['message'] ?? '').toString())));
      return;
    }
    final fields = <Map<String, dynamic>>[
      for (final f in (cfg['fields'] as List?) ?? const [])
        if (f is Map) Map<String, dynamic>.from(f),
    ];
    final edited = <String, dynamic>{};

    // A sheet, not a dialog — the house rule for anything with inputs.
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((cfg['heading'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            for (final f in fields)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: TextFormField(
                  key: ValueKey('pnl_cfg_${f['key']}'),
                  initialValue: '${f['value'] ?? ''}',
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: Ds.t.body,
                  decoration: InputDecoration(
                    labelText: (f['label'] ?? '').toString(),
                    isDense: true,
                  ),
                  onChanged: (v) {
                    final n = num.tryParse(v);
                    if (n != null) edited['${f['key']}'] = n;
                  },
                ),
              ),
            SizedBox(height: Ds.space.x8),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () async {
                  final res = _asMap(
                      await _rpc('pnl_config_set', {'p_patch': edited}));
                  if (!sheetCtx.mounted) return;
                  Navigator.of(sheetCtx).pop();
                  final msg = (res['message'] ?? res['saved_text'] ?? '')
                      .toString();
                  if (msg.isNotEmpty && mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(msg)));
                  }
                  await _load();
                },
                child: Text((cfg['save_label'] ?? '').toString()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// One order's P&L, printed exactly as pnl_order() returns it.
  Future<void> _openOrder(String orderId) async {
    final o = _asMap(await _rpc('pnl_order', {'p_order_id': orderId}));
    if (!mounted) return;
    if (o['ok'] == false) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text((o['message'] ?? '').toString())));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: EdgeInsets.all(Ds.space.x16),
          children: [
            Text((o['title'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Text((o['subtitle'] ?? '').toString(), style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            _tilesGrid((o['tiles'] as List?) ?? const []),
            SizedBox(height: Ds.space.x24),
            _costsCard(_asMap(o['costs'])),
            SizedBox(height: Ds.space.x24),
            _sectionCard(
              heading: (o['lines_heading'] ?? '').toString(),
              rows: (o['lines'] as List?) ?? const [],
              emptyText: (o['empty_text'] ?? '').toString(),
            ),
            SizedBox(height: Ds.space.x24),
          ],
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final d = _dash;
    final refused = d != null && d['ok'] == false;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text((d?['title'] ?? '').toString(), style: Ds.t.subtitle),
        backgroundColor: Ds.c.surface,
        elevation: 0,
        actions: [
          // The rates that turn gross margin into contribution live in
          // pnl_cost_config; this is the door to them, so changing what a
          // payment or a parcel costs never needs a deploy.
          IconButton(
            tooltip: (d?['costs']?['heading'] ?? '').toString(),
            onPressed: _loading ? null : _openRates,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: (d?['range_label'] ?? '').toString(),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? _skeleton()
          : _error.isNotEmpty
              ? _errorState()
              : refused
                  ? _message((d['message'] ?? '').toString(), 'danger')
                  : RefreshIndicator(onRefresh: _load, child: _body(d)),
    );
  }

  Widget _body(Map<String, dynamic>? d) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text((d?['subtitle'] ?? '').toString(), style: Ds.t.bodySecondary),
        SizedBox(height: Ds.space.x16),
        _rangePicker((d?['range_label'] ?? '').toString()),
        SizedBox(height: Ds.space.x16),
        _tabBar((d?['tabs'] as List?) ?? const []),
        SizedBox(height: Ds.space.x24),
        if (_tab == 'overview') ..._overview(d) else ..._tabBody(),
        SizedBox(height: Ds.space.x24),
        Text((d?['footnote'] ?? '').toString(), style: Ds.t.caption),
        SizedBox(height: Ds.space.x32),
      ],
    );
  }

  Widget _rangePicker(String rangeLabel) => Row(
        children: [
          for (final w in _windows)
            Padding(
              padding: EdgeInsets.only(right: Ds.space.x8),
              child: ChoiceChip(
                label: Text('$w', style: Ds.t.caption),
                selected: _days == w,
                onSelected: (_) {
                  if (_days == w) return;
                  setState(() => _days = w);
                  _load();
                },
              ),
            ),
          Expanded(
            child: Text(rangeLabel,
                textAlign: TextAlign.right, style: Ds.t.caption),
          ),
        ],
      );

  /// The tabs are the backend's list, in the backend's order, with the
  /// backend's words. A new dimension appears here by INSERTing a pnl_label row.
  Widget _tabBar(List<dynamic> tabs) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final t in tabs)
              if (t is Map)
                Padding(
                  padding: EdgeInsets.only(right: Ds.space.x8),
                  child: ChoiceChip(
                    label: Text((t['label'] ?? '').toString(),
                        style: Ds.t.caption),
                    selected: _tab == (t['key'] ?? '').toString(),
                    onSelected: (_) {
                      final k = (t['key'] ?? '').toString();
                      if (_tab == k) return;
                      setState(() {
                        _tab = k;
                        _tabData = null;
                      });
                      _loadTab();
                    },
                  ),
                ),
          ],
        ),
      );

  // ── Overview ──────────────────────────────────────────────────────────────

  List<Widget> _overview(Map<String, dynamic>? d) {
    final tiles = (d?['tiles'] as List?) ?? const [];
    final costs = _asMap(d?['costs']);
    final sections = (d?['sections'] as List?) ?? const [];
    final alerts = _asMap(d?['alerts']);
    final hasData = d?['has_data'] == true;

    return [
      if (tiles.isNotEmpty) _tilesGrid(tiles),
      if (!hasData) ...[
        SizedBox(height: Ds.space.x24),
        _message((d?['empty_text'] ?? '').toString(), null),
      ],
      if (costs.isNotEmpty) ...[
        SizedBox(height: Ds.space.x24),
        _costsCard(costs),
      ],
      if ((alerts['rows'] as List?)?.isNotEmpty ?? false) ...[
        SizedBox(height: Ds.space.x24),
        _sectionCard(
          heading: (alerts['heading'] ?? '').toString(),
          note: (alerts['note'] ?? '').toString(),
          rows: (alerts['rows'] as List?) ?? const [],
          emptyText: (alerts['empty_text'] ?? '').toString(),
        ),
      ],
      for (final s in sections)
        if (s is Map) ...[
          SizedBox(height: Ds.space.x24),
          _sectionCard(
            heading: (s['heading'] ?? '').toString(),
            rows: (s['rows'] as List?) ?? const [],
            emptyText: (s['empty_text'] ?? '').toString(),
          ),
        ],
    ];
  }

  // ── Everything that is not the overview ───────────────────────────────────

  List<Widget> _tabBody() {
    if (_tabLoading) return [_skeletonBlock()];
    final t = _tabData;
    if (t == null) return const [];
    if (t['ok'] == false) {
      return [_message((t['message'] ?? '').toString(), 'danger')];
    }
    if (_tab == 'simulator') return _simulator(t);
    return [
      _sectionCard(
        heading: (t['heading'] ?? '').toString(),
        note: (t['note'] ?? '').toString(),
        rows: (t['rows'] as List?) ?? const [],
        emptyText: (t['empty_text'] ?? '').toString(),
        // an order row is the only one with somewhere to go: the bill behind it
        onRowTap: _tab == 'order' ? _openOrder : null,
      ),
    ];
  }

  List<Widget> _simulator(Map<String, dynamic> t) {
    final tiles = (t['tiles'] as List?) ?? const [];
    final rows = (t['rows'] as List?) ?? const [];
    final ran = t['ran'] == true;
    return [
      Text((t['subtitle'] ?? '').toString(), style: Ds.t.bodySecondary),
      SizedBox(height: Ds.space.x16),
      Container(
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
            Text((t['proposed_label'] ?? '').toString(),
                style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x12),
            if (_proposed.isEmpty)
              Text((t['empty_text'] ?? '').toString(), style: Ds.t.caption),
            for (var i = 0; i < _proposed.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${(t['min_ptr_label'] ?? '')} '
                        '${_proposed[i]['min_amount'] ?? ''}',
                        style: Ds.t.caption,
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    SizedBox(
                      width: Ds.space.x48 * 2,
                      child: TextFormField(
                        key: ValueKey('pnl_sim_pct_$i'),
                        initialValue:
                            '${_proposed[i]['discount_pct'] ?? ''}',
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style: Ds.t.body,
                        decoration: InputDecoration(
                          labelText: (t['pct_label'] ?? '').toString(),
                          isDense: true,
                        ),
                        onChanged: (v) => _proposed[i]['discount_pct'] =
                            num.tryParse(v) ?? _proposed[i]['discount_pct'],
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(height: Ds.space.x8),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: _tabLoading ? null : _runSimulation,
                child: Text((t['run_label'] ?? '').toString()),
              ),
            ),
            SizedBox(height: Ds.space.x8),
            Text((t['note'] ?? '').toString(), style: Ds.t.caption),
          ],
        ),
      ),
      if (ran) ...[
        SizedBox(height: Ds.space.x24),
        if (tiles.isNotEmpty) _tilesGrid(tiles),
        SizedBox(height: Ds.space.x24),
        _sectionCard(
          heading: (t['result_heading'] ?? '').toString(),
          rows: rows,
          emptyText: (t['empty_text'] ?? '').toString(),
        ),
      ],
    ];
  }

  // ── Pieces ────────────────────────────────────────────────────────────────

  Widget _tilesGrid(List<dynamic> tiles) => LayoutBuilder(
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
                  SizedBox(width: w, child: _tile(Map<String, dynamic>.from(t))),
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
                  style: Ds.t.title
                      .copyWith(color: _tone((t['tone'] ?? '').toString()))),
            ),
          ],
        ),
      );

  Widget _costsCard(Map<String, dynamic> costs) => Container(
        width: double.infinity,
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
            Text((costs['heading'] ?? '').toString(), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x12),
            for (final r in (costs['rows'] as List?) ?? const [])
              if (r is Map)
                Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text((r['label'] ?? '').toString(),
                            style: Ds.t.body),
                      ),
                      SizedBox(width: Ds.space.x12),
                      Text((r['value'] ?? '').toString(),
                          style: Ds.t.bodyStrong),
                    ],
                  ),
                ),
          ],
        ),
      );

  Widget _sectionCard({
    required String heading,
    required List<dynamic> rows,
    required String emptyText,
    String note = '',
    void Function(String key)? onRowTap,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: Ds.t.bodyStrong),
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(note, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x12),
          if (rows.isEmpty)
            _message(emptyText, null)
          else
            for (final r in rows)
              if (r is Map) _row(Map<String, dynamic>.from(r), onRowTap),
        ],
      );

  Widget _row(Map<String, dynamic> r, [void Function(String key)? onTap]) {
    final card = Container(
        margin: EdgeInsets.only(bottom: Ds.space.x8),
        padding: EdgeInsets.all(Ds.space.x16),
        constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text((r['label'] ?? '').toString(), style: Ds.t.bodyStrong),
                  if ((r['sub'] ?? '').toString().isNotEmpty) ...[
                    SizedBox(height: Ds.space.x4),
                    Text((r['sub'] ?? '').toString(), style: Ds.t.caption),
                  ],
                ],
              ),
            ),
            SizedBox(width: Ds.space.x12),
            Text((r['value'] ?? '').toString(),
                style: Ds.t.bodyStrong
                    .copyWith(color: _tone((r['value_tone'] ?? '').toString()))),
          ],
        ),
      );
    if (onTap == null) return card;
    return InkWell(
      onTap: () => onTap((r['key'] ?? '').toString()),
      borderRadius: Ds.r.rCard,
      child: card,
    );
  }

  Widget _message(String text, String? tone) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x24),
        decoration: BoxDecoration(
          color: tone == 'danger' ? Ds.c.dangerSoft : Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Text(text,
            textAlign: TextAlign.center,
            style: tone == 'danger'
                ? Ds.t.body.copyWith(color: Ds.c.danger)
                : Ds.t.bodySecondary),
      );

  /// The backend's own error copy plus Retry — never a Dart sentence.
  Widget _errorState() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The dashboard payload carries its own error copy, but a load
              // that never returned has no payload — so the fallback is the
              // cached backend copy from ui_copy, still never a Dart sentence.
              Text(
                  (_dash?['error_text'] ?? '').toString().isNotEmpty
                      ? (_dash!['error_text']).toString()
                      : c('pnl.error'),
                  textAlign: TextAlign.center, style: Ds.t.bodySecondary),
              SizedBox(height: Ds.space.x16),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: _load,
                  child: Text(
                      (_dash?['retry_text'] ?? '').toString().isNotEmpty
                          ? (_dash!['retry_text']).toString()
                          : c('pnl.retry')),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [for (var i = 0; i < 6; i++) _skeletonBlock()],
      );

  Widget _skeletonBlock() => Container(
        height: Ds.space.x48,
        margin: EdgeInsets.only(bottom: Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
      );
}
