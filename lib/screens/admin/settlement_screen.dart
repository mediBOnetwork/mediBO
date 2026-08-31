import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';

/// CHANGE #323 — Partner settlement.
///
/// This screen computes NOTHING. Not a rupee, not a percentage, not a status
/// word, not an option label. `settlement_dashboard`, `settlement_zones`,
/// `settlement_cost_types`, `settlement_periods`, `settlement_statement` and
/// `settlement_config_get` each return their own headings, tiles, field
/// labels, dropdown options, empty states and already-formatted ₹ figures.
///
/// The three decisions that live here are which tab is open, which period is
/// being read, and what the admin typed into a sheet — everything else is the
/// payload, printed verbatim.
///
/// Two rules the screen only RENDERS, never re-implements:
///   • the split is applied to the PERIOD total, so a loss-making order nets
///     off inside its period instead of being settled on its own;
///   • a period under water pays nothing and hands the shortfall to the next
///     statement as an explicit "brought forward" tile.
class SettlementScreen extends StatefulWidget {
  const SettlementScreen({super.key});

  /// Test seam: feed payloads in without Supabase, exactly as PnlScreen does.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcOverride;

  @override
  State<SettlementScreen> createState() => _SettlementScreenState();
}

class _SettlementScreenState extends State<SettlementScreen> {
  static const _windows = <int>[7, 30, 90];

  Map<String, dynamic>? _dash;
  bool _loading = true;
  bool _busy = false;
  String _error = '';
  int _days = 30;
  String _tab = 'overview';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) {
    final o = SettlementScreen.rpcOverride;
    if (o != null) return o(fn, params);
    return params == null
        ? Supabase.instance.client.rpc(fn)
        : Supabase.instance.client.rpc(fn, params: params);
  }

  Map<String, dynamic> asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final m = asMap(await _rpc('settlement_dashboard', {'p_days': _days}));
      if (!mounted) return;
      setState(() {
        _dash = m;
        _loading = false;
      });
      RenderLog.write('c323_settlement_screen', 'painted');
      RenderLog.write(
          'c323_settlement_tiles', '${(m['tiles'] as List?)?.length ?? 0}');
      RenderLog.write('c323_settlement_zones',
          '${((asMap(m['zones'])['rows']) as List?)?.length ?? 0}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _toast(Map<String, dynamic> res) {
    final msg = (res['message'] ?? '').toString();
    if (msg.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _recalculate() async {
    setState(() => _busy = true);
    try {
      _toast(asMap(await _rpc('settlement_recalculate', {'p_days': _days})));
    } catch (_) {
      // The dashboard's own error copy covers this on the reload below.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  // ── The one switch: how the partner is actually paid ─────────────────────

  Future<void> _openRoute() async {
    final cfg = asMap(_dash?['route']);
    if (cfg['ok'] == false) {
      _toast(cfg);
      return;
    }
    var route = (cfg['route_mode'] ?? '').toString();
    var cadence = (cfg['default_cadence'] ?? '').toString();
    var autoClose = cfg['auto_close'] == true;
    final fields = asMap(cfg['fields']);

    await _sheet(
      heading: (cfg['heading'] ?? '').toString(),
      saveLabel: (cfg['save_label'] ?? '').toString(),
      builder: (setSheet) => [
        _dropdown(
          label: (fields['route_mode'] ?? '').toString(),
          value: route,
          options: (cfg['route_options'] as List?) ?? const [],
          onChanged: (v) => setSheet(() => route = v),
        ),
        _dropdown(
          label: (fields['cadence'] ?? '').toString(),
          value: cadence,
          options: (cfg['cadence_options'] as List?) ?? const [],
          onChanged: (v) => setSheet(() => cadence = v),
        ),
        SwitchListTile(
          key: const ValueKey('stl_auto_close'),
          contentPadding: EdgeInsets.zero,
          value: autoClose,
          title: Text((fields['auto_close'] ?? '').toString(), style: Ds.t.body),
          onChanged: (v) => setSheet(() => autoClose = v),
        ),
      ],
      onSave: () async {
        _toast(asMap(await _rpc('settlement_config_set', {
          'p_patch': {
            'route_mode': route,
            'default_cadence': cadence,
            'auto_close': autoClose,
          }
        })));
        await _load();
      },
    );
  }

  // ── One zone's deal ───────────────────────────────────────────────────────

  Future<void> _openZone(Map<String, dynamic> row) async {
    final z = asMap(_dash?['zones']);
    final fields = asMap(z['fields']);
    var mode = (row['mode'] ?? 'self').toString();
    var cadence = (row['cadence'] ?? 'same_day').toString();
    var partnerId = row['partner_id'];
    var split = '${row['split_pct'] ?? ''}';

    await _sheet(
      heading: (row['label'] ?? '').toString(),
      saveLabel: (z['save_label'] ?? '').toString(),
      builder: (setSheet) => [
        _dropdown(
          label: (fields['mode'] ?? '').toString(),
          value: mode,
          options: (z['mode_options'] as List?) ?? const [],
          onChanged: (v) => setSheet(() => mode = v),
        ),
        if (mode == 'partner')
          _dropdown(
            label: (fields['partner'] ?? '').toString(),
            value: '${partnerId ?? ''}',
            options: [
              for (final p in (z['partners'] as List?) ?? const [])
                if (p is Map) {'key': '${p['id']}', 'label': p['label']}
            ],
            onChanged: (v) => setSheet(() => partnerId = int.tryParse(v)),
          ),
        if (mode == 'partner')
          _field(
            key: 'stl_zone_split',
            label: (fields['split'] ?? '').toString(),
            initial: split,
            onChanged: (v) => split = v,
          ),
        _dropdown(
          label: (fields['cadence'] ?? '').toString(),
          value: cadence,
          options: (z['cadence_options'] as List?) ?? const [],
          onChanged: (v) => setSheet(() => cadence = v),
        ),
      ],
      onSave: () async {
        _toast(asMap(await _rpc('settlement_zone_set', {
          'p_zone_id': row['zone_id'],
          'p_patch': {
            'mode': mode,
            'partner_id': partnerId,
            'split_pct': num.tryParse(split),
            'cadence': cadence,
          }
        })));
        await _load();
      },
    );
  }

  // ── One cost type — editing an existing one, or adding a brand-new one ────

  Future<void> _openCostType(Map<String, dynamic>? row) async {
    final ct = asMap(_dash?['cost_types']);
    if (ct['ok'] == false) {
      _toast(ct);
      return;
    }
    final fields = asMap(ct['fields']);
    final isNew = row == null;
    var slug = (row?['slug'] ?? '').toString();
    var label = (row?['label'] ?? '').toString();
    var basis = (row?['basis'] ?? 'flat').toString();
    var base = '${row?['default_value'] ?? ''}';
    var rate = '${row?['rate_value'] ?? ''}';
    var active = row == null ? true : row['active'] == true;

    await _sheet(
      heading: isNew
          ? (ct['add_label'] ?? '').toString()
          : (row['label'] ?? '').toString(),
      saveLabel: (ct['save_label'] ?? '').toString(),
      builder: (setSheet) => [
        if (isNew)
          _field(
            key: 'stl_ct_slug',
            label: (fields['slug'] ?? '').toString(),
            initial: slug,
            numeric: false,
            onChanged: (v) => slug = v,
          ),
        _field(
          key: 'stl_ct_label',
          label: (fields['label'] ?? '').toString(),
          initial: label,
          numeric: false,
          onChanged: (v) => label = v,
        ),
        _dropdown(
          label: (fields['basis'] ?? '').toString(),
          value: basis,
          options: (ct['basis_options'] as List?) ?? const [],
          onChanged: (v) => setSheet(() => basis = v),
        ),
        _field(
          key: 'stl_ct_base',
          label: (fields['base'] ?? '').toString(),
          initial: base,
          onChanged: (v) => base = v,
        ),
        if (basis != 'flat')
          _field(
            key: 'stl_ct_rate',
            label: (fields['rate'] ?? '').toString(),
            initial: rate,
            onChanged: (v) => rate = v,
          ),
        SwitchListTile(
          key: const ValueKey('stl_ct_active'),
          contentPadding: EdgeInsets.zero,
          value: active,
          title: Text((fields['active'] ?? '').toString(), style: Ds.t.body),
          onChanged: (v) => setSheet(() => active = v),
        ),
      ],
      onSave: () async {
        _toast(asMap(await _rpc('settlement_cost_type_save', {
          'p_patch': {
            'slug': isNew ? slug : row['slug'],
            'label': label,
            'basis': basis,
            'default_value': num.tryParse(base),
            'rate_value': num.tryParse(rate),
            'active': active,
          }
        })));
        await _load();
      },
    );
  }

  Future<void> _openPeriod(dynamic periodId) async {
    if (periodId == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SettlementStatementPage(
        periodId: periodId is int ? periodId : int.tryParse('$periodId') ?? 0,
        rpc: _rpc,
      ),
    ));
    if (mounted) await _load();
  }

  // ── Shared sheet + input scaffolding ──────────────────────────────────────

  Future<void> _sheet({
    required String heading,
    required String saveLabel,
    required List<Widget> Function(void Function(void Function()) setSheet)
        builder,
    required Future<void> Function() onSave,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      builder: (sheetCtx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: EdgeInsets.only(
            left: Ds.space.x16,
            right: Ds.space.x16,
            top: Ds.space.x24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(heading, style: Ds.t.subtitle),
                SizedBox(height: Ds.space.x16),
                ...builder(setSheet),
                SizedBox(height: Ds.space.x16),
                SizedBox(
                  width: double.infinity,
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      await onSave();
                    },
                    child: Text(saveLabel),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field({
    required String key,
    required String label,
    required String initial,
    required ValueChanged<String> onChanged,
    bool numeric = true,
  }) =>
      Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: TextFormField(
          key: ValueKey(key),
          initialValue: initial,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(decimal: true)
              : TextInputType.text,
          style: Ds.t.body,
          decoration: InputDecoration(labelText: label, isDense: true),
          onChanged: onChanged,
        ),
      );

  /// The options, their words and their order are all the backend's. An option
  /// the payload did not send cannot be picked here.
  Widget _dropdown({
    required String label,
    required String value,
    required List<dynamic> options,
    required ValueChanged<String> onChanged,
  }) {
    final keys = [
      for (final o in options)
        if (o is Map) '${o['key']}'
    ];
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DropdownButtonFormField<String>(
        key: ValueKey('stl_dd_$label'),
        initialValue: keys.contains(value) ? value : null,
        isExpanded: true,
        style: Ds.t.body,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [
          for (final o in options)
            if (o is Map)
              DropdownMenuItem<String>(
                value: '${o['key']}',
                child: Text('${o['label'] ?? ''}',
                    style: Ds.t.body, overflow: TextOverflow.ellipsis),
              ),
        ],
        onChanged: (v) {
          if (v != null) onChanged(v);
        },
      ),
    );
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
          IconButton(
            tooltip: (asMap(d?['route'])['heading'] ?? '').toString(),
            onPressed: _loading || refused ? null : _openRoute,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: (d?['recalculate_label'] ?? '').toString(),
            onPressed: _loading || _busy || refused ? null : _recalculate,
            icon: const Icon(Icons.calculate_outlined),
          ),
          IconButton(
            tooltip: (d?['refresh_label'] ?? '').toString(),
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? settlementSkeleton()
          : _error.isNotEmpty
              ? _errorState()
              : refused
                  ? settlementMessage((d['message'] ?? '').toString(), 'danger')
                  : RefreshIndicator(onRefresh: _load, child: _body(d)),
    );
  }

  Widget _body(Map<String, dynamic>? d) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          Text((d?['subtitle'] ?? '').toString(), style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x16),
          _rangePicker((d?['range_label'] ?? '').toString()),
          SizedBox(height: Ds.space.x16),
          _tabBar((d?['tabs'] as List?) ?? const []),
          SizedBox(height: Ds.space.x24),
          ..._tabBody(d),
          SizedBox(height: Ds.space.x24),
          Text((d?['footnote'] ?? '').toString(), style: Ds.t.caption),
          SizedBox(height: Ds.space.x32),
        ],
      );

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
                    onSelected: (_) =>
                        setState(() => _tab = (t['key'] ?? '').toString()),
                  ),
                ),
          ],
        ),
      );

  List<Widget> _tabBody(Map<String, dynamic>? d) {
    switch (_tab) {
      case 'zones':
        final z = asMap(d?['zones']);
        return [
          settlementSection(
            heading: (z['heading'] ?? '').toString(),
            rows: (z['rows'] as List?) ?? const [],
            emptyText: (z['empty_text'] ?? '').toString(),
            onTap: (r) => _openZone(r),
          ),
        ];
      case 'costs':
        final ct = asMap(d?['cost_types']);
        return [
          settlementSection(
            heading: (ct['heading'] ?? '').toString(),
            note: (ct['note'] ?? '').toString(),
            rows: (ct['rows'] as List?) ?? const [],
            emptyText: (ct['empty_text'] ?? '').toString(),
            onTap: (r) => _openCostType(r),
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              key: const ValueKey('stl_add_cost_type'),
              onPressed: () => _openCostType(null),
              child: Text((ct['add_label'] ?? '').toString()),
            ),
          ),
        ];
      case 'periods':
        final p = asMap(d?['periods']);
        return [
          settlementSection(
            heading: (p['heading'] ?? '').toString(),
            note: (p['note'] ?? '').toString(),
            rows: (p['rows'] as List?) ?? const [],
            emptyText: (p['empty_text'] ?? '').toString(),
            onTap: (r) => _openPeriod(r['period_id']),
          ),
        ];
      default:
        final tiles = (d?['tiles'] as List?) ?? const [];
        final roll = asMap(d?['month_rollup']);
        return [
          if (tiles.isNotEmpty) settlementTiles(tiles),
          if (d?['has_data'] != true) ...[
            SizedBox(height: Ds.space.x24),
            settlementMessage((d?['empty_text'] ?? '').toString(), null),
          ],
          SizedBox(height: Ds.space.x24),
          settlementSection(
            heading: (roll['heading'] ?? '').toString(),
            rows: (roll['rows'] as List?) ?? const [],
            emptyText: (roll['empty_text'] ?? '').toString(),
          ),
        ];
    }
  }

  Widget _errorState() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                  (_dash?['error_text'] ?? '').toString().isNotEmpty
                      ? (_dash!['error_text']).toString()
                      : c('settlement.error'),
                  textAlign: TextAlign.center,
                  style: Ds.t.bodySecondary),
              SizedBox(height: Ds.space.x16),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: _load,
                  child: Text((_dash?['retry_text'] ?? '').toString().isNotEmpty
                      ? (_dash!['retry_text']).toString()
                      : c('settlement.retry')),
                ),
              ),
            ],
          ),
        ),
      );
}

// ── The statement, as its own page ───────────────────────────────────────────
//
// ONE widget, used by the admin and by the partner, because the payload is one
// shape: due / transferred / pending read identically whether Razorpay Route
// moved the money or a human did. The only difference is `can_settle`, which
// the BACKEND decides.

class SettlementStatementPage extends StatefulWidget {
  const SettlementStatementPage({
    super.key,
    required this.periodId,
    required this.rpc,
  });

  final int periodId;
  final Future<dynamic> Function(String fn, Map<String, dynamic>? params) rpc;

  @override
  State<SettlementStatementPage> createState() =>
      _SettlementStatementPageState();
}

class _SettlementStatementPageState extends State<SettlementStatementPage> {
  Map<String, dynamic>? _s;
  bool _loading = true;

  Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> m;
    try {
      m = _asMap(
          await widget.rpc('settlement_statement', {'p_period_id': widget.periodId}));
    } catch (_) {
      m = const <String, dynamic>{};
    }
    if (!mounted) return;
    setState(() {
      _s = m;
      _loading = false;
    });
    RenderLog.write('c323_settlement_statement', 'painted');
  }

  void _toast(Map<String, dynamic> res) {
    final msg = (res['message'] ?? '').toString();
    if (msg.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _record() async {
    final s = _s;
    if (s == null) return;
    var amount = '';
    var reference = '';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((s['record_label'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x8),
            Text((s['route_note'] ?? '').toString(), style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            TextFormField(
              key: const ValueKey('stl_pay_amount'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              style: Ds.t.body,
              decoration: InputDecoration(
                  labelText: (s['amount_label'] ?? '').toString(),
                  isDense: true),
              onChanged: (v) => amount = v,
            ),
            SizedBox(height: Ds.space.x12),
            TextFormField(
              key: const ValueKey('stl_pay_ref'),
              style: Ds.t.body,
              decoration: InputDecoration(
                  labelText: (s['reference_label'] ?? '').toString(),
                  isDense: true),
              onChanged: (v) => reference = v,
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  _toast(_asMap(await widget.rpc('settlement_record_payment', {
                    'p_period_id': widget.periodId,
                    'p_amount': num.tryParse(amount),
                    'p_reference': reference,
                  })));
                  await _load();
                },
                child: Text((s['record_label'] ?? '').toString()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _settle() async {
    _toast(_asMap(
        await widget.rpc('settlement_settle', {'p_period_id': widget.periodId})));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final refused = s != null && s['ok'] == false;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text((s?['heading'] ?? '').toString(), style: Ds.t.subtitle),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? settlementSkeleton()
          : refused
              ? settlementMessage((s['message'] ?? '').toString(), 'danger')
              : settlementStatementBody(
                  s,
                  onRecord: (s?['is_admin'] == true) ? _record : null,
                  onSettle: (s?['can_settle'] == true) ? _settle : null,
                ),
    );
  }
}

/// The statement body, shared by the admin page and the partner screen.
Widget settlementStatementBody(
  Map<String, dynamic>? s, {
  VoidCallback? onRecord,
  VoidCallback? onSettle,
}) {
  Map<String, dynamic> m(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
  final costs = m(s?['costs']);
  final orders = m(s?['orders']);
  final payments = m(s?['payments']);
  return ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: [
      Text((s?['sub'] ?? '').toString(), style: Ds.t.bodySecondary),
      if ((s?['partner'] ?? '').toString().isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text((s?['partner'] ?? '').toString(), style: Ds.t.bodyStrong),
      ],
      SizedBox(height: Ds.space.x16),
      settlementChip((s?['status_label'] ?? '').toString(),
          (s?['status_tone'] ?? '').toString()),
      if (s?['negative'] == true) ...[
        SizedBox(height: Ds.space.x16),
        settlementMessage((s?['negative_text'] ?? '').toString(), 'warning'),
      ],
      SizedBox(height: Ds.space.x24),
      settlementTiles((s?['tiles'] as List?) ?? const []),
      SizedBox(height: Ds.space.x24),
      settlementSection(
        heading: (costs['heading'] ?? '').toString(),
        rows: (costs['rows'] as List?) ?? const [],
        emptyText: '',
      ),
      SizedBox(height: Ds.space.x24),
      settlementSection(
        heading: (orders['heading'] ?? '').toString(),
        rows: (orders['rows'] as List?) ?? const [],
        emptyText: (orders['empty_text'] ?? '').toString(),
      ),
      SizedBox(height: Ds.space.x24),
      settlementSection(
        heading: (payments['heading'] ?? '').toString(),
        rows: (payments['rows'] as List?) ?? const [],
        emptyText: (payments['empty_text'] ?? '').toString(),
      ),
      if (onRecord != null) ...[
        SizedBox(height: Ds.space.x24),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: OutlinedButton(
            key: const ValueKey('stl_record_payment'),
            onPressed: onRecord,
            child: Text((s?['record_label'] ?? '').toString()),
          ),
        ),
      ],
      if (onSettle != null) ...[
        SizedBox(height: Ds.space.x12),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: FilledButton(
            key: const ValueKey('stl_settle'),
            onPressed: onSettle,
            child: Text((s?['settle_label'] ?? '').toString()),
          ),
        ),
      ],
      SizedBox(height: Ds.space.x24),
      Text((s?['footnote'] ?? '').toString(), style: Ds.t.caption),
      SizedBox(height: Ds.space.x32),
    ],
  );
}

// ── Shared render helpers — none of them decide anything ─────────────────────

Color settlementTone(String? tone) {
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

Widget settlementChip(String label, String tone) {
  if (label.isEmpty) return const SizedBox.shrink();
  final fg = settlementTone(tone);
  return Align(
    alignment: Alignment.centerLeft,
    child: Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: Color.alphaBlend(fg.withValues(alpha: 0.12), Ds.c.surface),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: fg)),
    ),
  );
}

Widget settlementTiles(List<dynamic> tiles) => LayoutBuilder(
      builder: (ctx, box) {
        final cols = box.maxWidth >= 900 ? 4 : (box.maxWidth >= 560 ? 3 : 2);
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: Ds.space.x12,
          mainAxisSpacing: Ds.space.x12,
          childAspectRatio: 1.9,
          children: [
            for (final t in tiles)
              if (t is Map) settlementTile(Map<String, dynamic>.from(t)),
          ],
        );
      },
    );

Widget settlementTile(Map<String, dynamic> t) => Container(
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
                    .copyWith(color: settlementTone((t['tone'] ?? '').toString()))),
          ),
        ],
      ),
    );

Widget settlementSection({
  required String heading,
  required List<dynamic> rows,
  required String emptyText,
  String note = '',
  void Function(Map<String, dynamic> row)? onTap,
}) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (heading.isNotEmpty) Text(heading, style: Ds.t.bodyStrong),
        if (note.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(note, style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty)
          if (emptyText.isNotEmpty)
            settlementMessage(emptyText, null)
          else
            const SizedBox.shrink()
        else
          for (final r in rows)
            if (r is Map)
              settlementRow(Map<String, dynamic>.from(r), onTap: onTap),
      ],
    );

Widget settlementRow(Map<String, dynamic> r,
    {void Function(Map<String, dynamic> row)? onTap}) {
  final body = Container(
    margin: EdgeInsets.only(bottom: Ds.space.x8),
    padding: EdgeInsets.all(Ds.space.x16),
    constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
    decoration: BoxDecoration(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      border: Border.all(color: Ds.c.divider),
    ),
    child: Row(
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
                .copyWith(color: settlementTone((r['value_tone'] ?? '').toString()))),
      ],
    ),
  );
  if (onTap == null) return body;
  return InkWell(
    borderRadius: Ds.r.rCard,
    onTap: () => onTap(r),
    child: body,
  );
}

Widget settlementMessage(String text, String? tone) => Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
        color: tone == null
            ? Ds.c.surface
            : Color.alphaBlend(
                settlementTone(tone).withValues(alpha: 0.12), Ds.c.surface),
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Text(text,
          textAlign: TextAlign.center,
          style: tone == null
              ? Ds.t.bodySecondary
              : Ds.t.body.copyWith(color: settlementTone(tone))),
    );

Widget settlementSkeleton() => ListView(
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
