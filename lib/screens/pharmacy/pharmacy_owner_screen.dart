// CHANGE #419 — the screens the owner checks at night.
//
// Three surfaces behind one tab bar, and not one of them computes anything:
//
//   • DASHBOARD — the range toggle sends back the KEY the backend gave it, and
//     every tile is a label, a value string and a caption the backend composed.
//     Dart never divides sales by bills to make an average.
//   • BENCHMARK — the cohort floor is the BACKEND's answer. `state` is
//     'too_small' / 'opted_out' / 'no_gap' / 'ready' and each one arrives with
//     its own sentence; this screen has no wording of its own to fall back on,
//     so a refusal can never be softened or explained away here.
//   • RADAR — the headline, the class rows and the SKU list are payload order.
//     "Add all" sends exactly the ids that were on screen.
//
// Every tab label is the payload's own title, so renaming a surface is an
// UPDATE to ui_copy, not a deploy.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/pharmacy_owner_api.dart';
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

// ── shared furniture ────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  final Color? background;
  const _Card({required this.child, this.background});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: background ?? Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: child,
      );
}

/// An empty / refused state: the backend's sentence, its hint, and nothing else.
class _StateBlock extends StatelessWidget {
  final String message;
  final String hint;
  const _StateBlock({required this.message, required this.hint});

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.isNotEmpty) Text(message, style: Ds.t.bodyStrong),
            if (message.isNotEmpty && hint.isNotEmpty)
              SizedBox(height: Ds.space.x8),
            if (hint.isNotEmpty) Text(hint, style: Ds.t.caption),
          ],
        ),
      );
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 5; i++) ...[
            Container(
              height: Ds.space.x48 + Ds.space.x24,
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

// ── 1. the dashboard ────────────────────────────────────────────────────────

class OwnerDashboardView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final void Function(String rangeKey) onRange;

  const OwnerDashboardView({
    super.key,
    required this.payload,
    required this.onRange,
  });

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return _StateBlock(message: _s(payload, 'message'), hint: '');
    }
    final tiles = _rows(payload['tiles']);
    final sections = _rows(payload['sections']);
    RenderLog.write('c419_owner_tiles', tiles.length);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(payload, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        _RangeChips(payload: payload, onRange: onRange),
        SizedBox(height: Ds.space.x24),
        if (payload['has_sales'] == false)
          _StateBlock(
            message: _s(payload, 'empty'),
            hint: _s(payload, 'empty_hint'),
          )
        else ...[
          LayoutBuilder(
            builder: (context, box) {
              final columns = box.maxWidth >= 640 ? 3 : 2;
              return GridView.count(
                crossAxisCount: columns,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: Ds.space.x12,
                crossAxisSpacing: Ds.space.x12,
                childAspectRatio: 1.6,
                children: [for (final t in tiles) _Tile(tile: t)],
              );
            },
          ),
          for (final section in sections) ...[
            SizedBox(height: Ds.space.x24),
            _Section(section: section),
          ],
        ],
      ],
    );
  }
}

class _RangeChips extends StatelessWidget {
  final Map<String, dynamic> payload;
  final void Function(String rangeKey) onRange;
  const _RangeChips({required this.payload, required this.onRange});

  @override
  Widget build(BuildContext context) {
    final ranges = _rows(payload['ranges']);
    return Wrap(
      spacing: Ds.space.x8,
      children: [
        for (final r in ranges)
          InkWell(
            onTap: () => onRange(_s(r, 'key')),
            borderRadius: Ds.r.rChip,
            child: Container(
              constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
              alignment: Alignment.center,
              padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16,
                vertical: Ds.space.x8,
              ),
              decoration: BoxDecoration(
                color: r['selected'] == true ? Ds.c.brandSoft : Ds.c.surface,
                borderRadius: Ds.r.rChip,
                border: Border.all(
                  color: r['selected'] == true ? Ds.c.brand : Ds.c.divider,
                ),
              ),
              child: Text(
                _s(r, 'label'),
                style: r['selected'] == true ? Ds.t.bodyStrong : Ds.t.body,
              ),
            ),
          ),
      ],
    );
  }
}

class _Tile extends StatelessWidget {
  final Map<String, dynamic> tile;
  const _Tile({required this.tile});

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_s(tile, 'label'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                _s(tile, 'value'),
                style: Ds.t.title.copyWith(color: _tone(tile['tone'])),
              ),
            ),
            SizedBox(height: Ds.space.x4),
            Flexible(
              child: Text(
                _s(tile, 'sub'),
                style: Ds.t.caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}

class _Section extends StatelessWidget {
  final Map<String, dynamic> section;
  const _Section({required this.section});

  @override
  Widget build(BuildContext context) {
    final rows = _rows(section['rows']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_s(section, 'heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        _Card(
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0)
                  Divider(height: Ds.space.x24, color: Ds.c.divider),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_s(rows[i], 'name'), style: Ds.t.body),
                          SizedBox(height: Ds.space.x4),
                          Text(_s(rows[i], 'qty_label'), style: Ds.t.caption),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Text(_s(rows[i], 'value_label'), style: Ds.t.bodyStrong),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ── 2. the benchmark ────────────────────────────────────────────────────────

class OwnerBenchmarkView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final void Function(bool sharing) onSharing;
  final bool busy;

  const OwnerBenchmarkView({
    super.key,
    required this.payload,
    required this.onSharing,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return _StateBlock(message: _s(payload, 'message'), hint: '');
    }
    final cards = _rows(payload['cards']);
    final sharing = payload['sharing'] == true;
    RenderLog.write('c419_bench_cards', cards.length);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(payload, 'subtitle'), style: Ds.t.caption),
        if (_s(payload, 'cohort_label').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(_s(payload, 'cohort_label'), style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x24),
        // A refusal, an opt-out and "you are level" are all just a message and
        // a hint the backend wrote. The screen tells them apart by looking at
        // whether there are cards, never by inspecting `state` and inventing
        // copy of its own.
        if (cards.isEmpty)
          _StateBlock(
            message: _s(payload, 'message'),
            hint: _s(payload, 'hint'),
          )
        else
          for (final card in cards) ...[
            _BenchCard(card: card),
            SizedBox(height: Ds.space.x12),
          ],
        SizedBox(height: Ds.space.x24),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(payload, 'privacy'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x12),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Ds.c.brand),
                    shape: RoundedRectangleBorder(
                      borderRadius: Ds.r.rButton,
                    ),
                  ),
                  onPressed: busy ? null : () => onSharing(!sharing),
                  child: Text(
                    _s(payload, 'toggle_label'),
                    style: Ds.t.bodyStrong.copyWith(color: Ds.c.brand),
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

class _BenchCard extends StatelessWidget {
  final Map<String, dynamic> card;
  const _BenchCard({required this.card});

  @override
  Widget build(BuildContext context) => _Card(
        background: _toneSoft(card['tone']),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(card, 'headline'), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x8),
            Text(_s(card, 'hint'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                Expanded(child: Text(_s(card, 'mine_label'), style: Ds.t.body)),
                Text(_s(card, 'cohort_label'), style: Ds.t.bodyStrong),
              ],
            ),
          ],
        ),
      );
}

// ── 3. the demand radar ─────────────────────────────────────────────────────

class OwnerRadarView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final void Function(List<Map<String, dynamic>> items) onAdd;
  final bool busy;

  const OwnerRadarView({
    super.key,
    required this.payload,
    required this.onAdd,
    this.busy = false,
  });

  /// Exactly the rows that were on screen, with the qty the backend suggested.
  static List<Map<String, dynamic>> itemsOf(
    Iterable<Map<String, dynamic>> rows,
  ) => [
        for (final r in rows) {'medicine_id': r['medicine_id'], 'qty': r['qty']},
      ];

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return _StateBlock(message: _s(payload, 'message'), hint: '');
    }
    final rows = _rows(payload['rows']);
    final classes = _rows(payload['classes']);
    RenderLog.write('c419_radar_rows', rows.length);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(payload, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        if (rows.isEmpty && classes.isEmpty)
          _StateBlock(
            message: _s(payload, 'message'),
            hint: _s(payload, 'hint'),
          )
        else ...[
          _Card(
            background: Ds.c.brandSoft,
            child: Text(_s(payload, 'headline'), style: Ds.t.bodyStrong),
          ),
          if (classes.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            Text(_s(payload, 'class_heading'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            _Card(
              child: Column(
                children: [
                  for (var i = 0; i < classes.length; i++) ...[
                    if (i > 0)
                      Divider(height: Ds.space.x24, color: Ds.c.divider),
                    Row(
                      children: [
                        Expanded(
                          child: Text(_s(classes[i], 'label'),
                              style: Ds.t.body),
                        ),
                        SizedBox(width: Ds.space.x12),
                        Text(_s(classes[i], 'units_label'),
                            style: Ds.t.caption),
                        SizedBox(width: Ds.space.x12),
                        Text(
                          _s(classes[i], 'delta_label'),
                          style: Ds.t.bodyStrong
                              .copyWith(color: _tone(classes[i]['tone'])),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (rows.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            Text(_s(payload, 'sku_heading'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape:
                      RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: busy ? null : () => onAdd(itemsOf(rows)),
                child: Text(_s(payload, 'add_all_label')),
              ),
            ),
            SizedBox(height: Ds.space.x12),
            for (final row in rows) ...[
              _RadarRow(
                row: row,
                busy: busy,
                onAdd: () => onAdd(itemsOf([row])),
              ),
              SizedBox(height: Ds.space.x12),
            ],
          ],
        ],
      ],
    );
  }
}

class _RadarRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onAdd;
  final bool busy;
  const _RadarRow({required this.row, required this.onAdd, required this.busy});

  @override
  Widget build(BuildContext context) => _Card(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(row, 'name'), style: Ds.t.body),
                  SizedBox(height: Ds.space.x4),
                  Row(
                    children: [
                      Text(_s(row, 'units_label'), style: Ds.t.caption),
                      SizedBox(width: Ds.space.x8),
                      Text(
                        _s(row, 'delta_label'),
                        style:
                            Ds.t.caption.copyWith(color: _tone(row['tone'])),
                      ),
                    ],
                  ),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(row, 'stock_label'), style: Ds.t.caption),
                ],
              ),
            ),
            SizedBox(width: Ds.space.x12),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Ds.c.brand),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: busy ? null : onAdd,
                child: Text(
                  _s(row, 'add_label'),
                  style: Ds.t.bodyStrong.copyWith(color: Ds.c.brand),
                ),
              ),
            ),
          ],
        ),
      );
}

// ── the live screen ─────────────────────────────────────────────────────────

class PharmacyOwnerScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final PosRpc? rpc;

  /// CHANGE #441 — which tab the deep link opened. A TabBarView builds only
  /// the page in the viewport, so the benchmark and the radar never paint
  /// (and never report) until something selects them. A headless session
  /// cannot tap a canvas, so /pharmacy/owner?tab=1 is how the proof reaches
  /// them. Out-of-range values fall back to the dashboard rather than throw.
  final int initialTab;

  const PharmacyOwnerScreen({super.key, this.rpc, this.initialTab = 0});

  @override
  State<PharmacyOwnerScreen> createState() => _PharmacyOwnerScreenState();
}

class _PharmacyOwnerScreenState extends State<PharmacyOwnerScreen> {
  Map<String, dynamic>? _dash;
  Map<String, dynamic> _bench = const {};
  Map<String, dynamic> _radar = const {};
  String _range = 'today';
  bool _busy = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PharmacyOwnerApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await _call('pharmacy_owner_dashboard', {'p_range': _range});
    Map<String, dynamic> b = const {};
    Map<String, dynamic> r = const {};
    try {
      b = await _call('pharmacy_benchmark', const {});
    } catch (_) {
      // A missing comparison is not a broken dashboard.
    }
    try {
      r = await _call('pharmacy_demand_radar', const {});
    } catch (_) {
      // Same for the radar.
    }
    if (!mounted) return;
    setState(() {
      _dash = d;
      _bench = b;
      _radar = r;
      _range = (d['range'] ?? _range).toString();
    });
  }

  void _toast(Map<String, dynamic> r) {
    final msg = (r['message'] ?? '').toString();
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: _tone(r['tone'])),
    );
  }

  Future<void> _run(Future<Map<String, dynamic>> future) async {
    setState(() => _busy = true);
    final r = await future;
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(r);
    await _load();
  }

  Future<void> _setRange(String key) async {
    if (key.isEmpty) return;
    setState(() => _range = key);
    final d = await _call('pharmacy_owner_dashboard', {'p_range': key});
    if (!mounted) return;
    setState(() => _dash = d);
  }

  @override
  Widget build(BuildContext context) {
    final d = _dash;
    return DefaultTabController(
      length: 3,
      initialIndex: widget.initialTab >= 0 && widget.initialTab < 3
          ? widget.initialTab
          : 0,
      child: Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(
          backgroundColor: Ds.c.surface,
          title: Text(d == null ? '' : _s(d, 'title')),
          bottom: TabBar(
            labelColor: Ds.c.brand,
            unselectedLabelColor: Ds.c.textSecondary,
            indicatorColor: Ds.c.brand,
            tabs: [
              Tab(text: d == null ? '' : _s(d, 'title')),
              Tab(text: _s(_bench, 'title')),
              Tab(text: _s(_radar, 'title')),
            ],
          ),
        ),
        body: d == null
            ? const _Skeleton()
            : TabBarView(
                children: [
                  OwnerDashboardView(payload: d, onRange: _setRange),
                  OwnerBenchmarkView(
                    payload: _bench,
                    busy: _busy,
                    onSharing: (sharing) => _run(_call(
                      'pharmacy_insight_optout_set',
                      {'p_out': !sharing},
                    )),
                  ),
                  OwnerRadarView(
                    payload: _radar,
                    busy: _busy,
                    onAdd: (items) => _run(
                      _call('pharmacy_demand_add', {'p_items': items}),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// The entry tile on the counter screen. Its label is backend copy, so the
/// entry disappears the moment the copy is cleared — no deploy needed.
class OwnerDashboardEntryTile extends StatelessWidget {
  final PosRpc? rpc;
  final String label;
  const OwnerDashboardEntryTile({super.key, required this.label, this.rpc});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c419_owner_entry', 1);
    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => PharmacyOwnerScreen(rpc: rpc),
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
            Icon(Icons.insights, size: Ds.space.x24, color: Ds.c.brand),
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
