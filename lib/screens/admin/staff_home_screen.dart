// CHANGE #1016 — one home tab, rendered.
//
// `staff_home(tab)` is ONE payload: the sections of the home (Money, More),
// or the extras that sit beside a page's own tab row (Customers, Suppliers,
// Fulfill). Titles, section names, tile labels, badges, the search hint, the
// empty state, the "Recent" row and the Money "right now" line all arrive
// written; this file lays them out and hands taps back as the backend's own
// tile map, so the SAME tap handler the dashboard registry uses opens them.
//
// Nothing here has a Supabase import. The loader is injected, which is what
// lets the protected test pump every state on the Dart VM with an inline
// payload — the way every protected test in this repo works.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import 'nav_registry_view.dart';

/// `staff_home(tab)`.
typedef StaffHomeLoad = Future<Map<String, dynamic>> Function(String tabKey);

/// A tile was tapped. The backend's own map, untouched — the caller reads
/// `route_key` / `deep_link` / `tool_key` / `feature_key` from it.
typedef StaffTileTap = void Function(Map<String, dynamic> tile);

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

List<Map<String, dynamic>> _list(Map<String, dynamic> m, String k) =>
    (m[k] as List?)
        ?.whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList() ??
    const <Map<String, dynamic>>[];

/// The full home page (Money, More): title, search (More), recents, the
/// Money "right now" line, then every section in payload order.
class StaffHomeScreen extends StatefulWidget {
  const StaffHomeScreen({
    super.key,
    required this.tabKey,
    required this.load,
    required this.onOpen,
    this.active = true,
    this.onUnusedReport,
  });

  final String tabKey;
  final StaffHomeLoad load;
  final StaffTileTap onOpen;

  /// False while another page is showing — the IndexedStack builds every
  /// child, and a home that fetches unseen is a request nobody asked for.
  final bool active;

  /// The dead-feature report (super admin). Rendered only when the payload
  /// carries `unused_report_label`, so the backend decides who sees it.
  final VoidCallback? onUnusedReport;

  @override
  State<StaffHomeScreen> createState() => _StaffHomeScreenState();
}

class _StaffHomeScreenState extends State<StaffHomeScreen> {
  Map<String, dynamic> _home = const {};
  bool _loading = true;
  bool _fetched = false;
  String _query = '';
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.active) _fetch();
  }

  @override
  void didUpdateWidget(StaffHomeScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !_fetched) _fetch();
    if (widget.active && old.active == false && _fetched) _fetch();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    _fetched = true;
    try {
      final m = await widget.load(widget.tabKey);
      if (!mounted) return;
      setState(() {
        _home = m;
        _loading = false;
      });
      RenderLog.write('c1016_home_${widget.tabKey}',
          'sections=${_list(m, 'sections').length};items=${_s(m, 'items_count')}');
    } catch (_) {
      // The previous payload stays on screen — the cache is a render
      // fallback, never an authority.
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The sections, with the search applied. A filter over the backend's own
  /// list is rendering, not deciding: nothing is added, reworded or reordered.
  List<Map<String, dynamic>> _sections() {
    final all = _list(_home, 'sections');
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return all;
    final out = <Map<String, dynamic>>[];
    for (final s in all) {
      final items = _list(s, 'items')
          .where((t) =>
              _s(t, 'label').toLowerCase().contains(q) ||
              _s(t, 'description').toLowerCase().contains(q))
          .toList();
      if (items.isEmpty) continue;
      out.add({...s, 'items': items});
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final ok = _home['ok'] == true;
    final sections = _sections();
    final recents = _list(_home, 'recents');
    final stats = _list(_home, 'stats');
    final isMore = widget.tabKey == 'more';
    return LayoutBuilder(builder: (ctx, box) {
      final hpad = box.maxWidth < 600 ? Ds.space.x16 : Ds.space.x24;
      return ListView(
        key: Key('c1016_home_${widget.tabKey}'),
        padding: EdgeInsets.fromLTRB(hpad, Ds.space.x16, hpad, Ds.space.x48),
        children: [
          Text(_s(_home, 'title'), style: Ds.t.title),
          if (_s(_home, 'subtitle').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(_home, 'subtitle'), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x16),
          if (isMore) ...[
            _SearchField(
              controller: _search,
              hint: _s(_home, 'search_hint'),
              onChanged: (v) => setState(() => _query = v),
            ),
            SizedBox(height: Ds.space.x24),
          ],
          if (_loading && _home.isEmpty)
            const _HomeSkeleton()
          else if (!ok)
            Text(_s(_home, 'message').isNotEmpty
                ? _s(_home, 'message')
                : _s(_home, 'empty_label'),
                style: Ds.t.bodySecondary)
          else ...[
            if (stats.isNotEmpty) ...[
              _SectionLabel(_s(_home, 'stats_label')),
              _StatsRow(stats: stats, onOpen: widget.onOpen),
              SizedBox(height: Ds.space.x24),
            ],
            if (recents.isNotEmpty && _query.trim().isEmpty) ...[
              _SectionLabel(_s(_home, 'recents_label')),
              _TileWrap(tiles: recents, onOpen: widget.onOpen),
              SizedBox(height: Ds.space.x24),
            ],
            if (sections.isEmpty)
              Text(
                  _query.trim().isEmpty
                      ? _s(_home, 'empty_label')
                      : _s(_home, 'search_empty'),
                  style: Ds.t.bodySecondary)
            else
              for (final s in sections) ...[
                _SectionLabel(_s(s, 'label'), sublabel: _s(s, 'sublabel')),
                _TileWrap(tiles: _list(s, 'items'), onOpen: widget.onOpen),
                SizedBox(height: Ds.space.x24),
              ],
            if (_s(_home, 'unused_report_label').isNotEmpty &&
                widget.onUnusedReport != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: widget.onUnusedReport,
                  icon: const Icon(Icons.insights_outlined),
                  label: Text(_s(_home, 'unused_report_label')),
                ),
              ),
          ],
        ],
      );
    });
  }
}

/// The compact form: one horizontal row of the home's extra doors, drawn
/// above the Customers / Suppliers / Fulfill pages' own tab rows. Draws
/// nothing at all when the payload has no items for this login.
class StaffHomeStrip extends StatefulWidget {
  const StaffHomeStrip({
    super.key,
    required this.tabKey,
    required this.load,
    required this.onOpen,
    this.active = true,
  });

  final String tabKey;
  final StaffHomeLoad load;
  final StaffTileTap onOpen;
  final bool active;

  @override
  State<StaffHomeStrip> createState() => _StaffHomeStripState();
}

class _StaffHomeStripState extends State<StaffHomeStrip> {
  Map<String, dynamic> _home = const {};
  bool _fetched = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _fetch();
  }

  @override
  void didUpdateWidget(StaffHomeStrip old) {
    super.didUpdateWidget(old);
    if (widget.active && !_fetched) _fetch();
  }

  Future<void> _fetch() async {
    _fetched = true;
    try {
      final m = await widget.load(widget.tabKey);
      if (mounted) setState(() => _home = m);
      RenderLog.write(
          'c1016_strip_${widget.tabKey}', _s(m, 'items_count'));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final tiles = <Map<String, dynamic>>[
      for (final s in _list(_home, 'sections')) ..._list(s, 'items'),
    ];
    if (_home['ok'] != true || tiles.isEmpty) return const SizedBox.shrink();
    return Container(
      key: Key('c1016_strip_${widget.tabKey}'),
      color: Ds.c.surface,
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x8),
      child: Row(children: [
        Text(_s(_home, 'strip_label'), style: Ds.t.caption),
        SizedBox(width: Ds.space.x12),
        Expanded(
          child: SizedBox(
            height: Ds.space.x48 - Ds.space.x8,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: tiles.length,
              separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
              itemBuilder: (_, i) => _Chip(tile: tiles[i], onOpen: widget.onOpen),
            ),
          ),
        ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.tile, required this.onOpen});
  final Map<String, dynamic> tile;
  final StaffTileTap onOpen;

  @override
  Widget build(BuildContext context) {
    final count = (tile['badge_count'] as num?)?.toInt() ?? 0;
    return Semantics(
      button: true,
      label: _s(tile, 'label'),
      child: InkWell(
        onTap: () => onOpen(tile),
        borderRadius: Ds.r.rChip,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.space.x48 - Ds.space.x8),
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
          decoration: BoxDecoration(
            color: Ds.c.bg,
            borderRadius: Ds.r.rChip,
            border: Border.all(color: Ds.c.divider),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            NavGlyph(row: tile, box: Ds.space.x16, glyph: Ds.space.x16),
            SizedBox(width: Ds.space.x8),
            Text(_s(tile, 'label'), style: Ds.t.bodyStrong),
            if (count > 0) ...[
              SizedBox(width: Ds.space.x8),
              _Badge(count: count),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: Ds.c.brandSoft,
          borderRadius: Ds.r.rChip,
        ),
        child: Text('$count',
            style: Ds.t.caption.copyWith(
                color: Ds.c.brand, fontWeight: FontWeight.w600)),
      );
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.sublabel = ''});
  final String text;
  final String sublabel;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Row(children: [
          Text(text,
              style: Ds.t.caption.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Ds.c.textSecondary,
                  letterSpacing: 1.0)),
          if (sublabel.isNotEmpty) ...[
            SizedBox(width: Ds.space.x8),
            Text(sublabel, style: Ds.t.caption),
          ],
        ]),
      );
}

/// Tiles share the row: the column count comes from the width on offer, so a
/// phone gets two across and a desktop as many as fit — never a fixed pixel
/// width (DESIGN.md: proportional widths, breakpoints 360…1280+).
double _tileWidth(double maxWidth, double gap, double minTile) {
  final cols = (maxWidth / (minTile + gap)).floor().clamp(1, 6);
  return (maxWidth - gap * (cols - 1)) / cols;
}

class _TileWrap extends StatelessWidget {
  const _TileWrap({required this.tiles, required this.onOpen});
  final List<Map<String, dynamic>> tiles;
  final StaffTileTap onOpen;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final w = _tileWidth(box.maxWidth, Ds.space.x12, Ds.space.x48 * 3);
        return Wrap(
          spacing: Ds.space.x12,
          runSpacing: Ds.space.x12,
          children: [
            for (final t in tiles)
              SizedBox(width: w, child: _HomeTile(tile: t, onOpen: onOpen)),
          ],
        );
      });
}

/// One tile. Label, glyph and badge are the payload's; the tap hands the
/// payload's own map back.
class _HomeTile extends StatelessWidget {
  const _HomeTile({required this.tile, required this.onOpen});
  final Map<String, dynamic> tile;
  final StaffTileTap onOpen;

  @override
  Widget build(BuildContext context) {
    final count = (tile['badge_count'] as num?)?.toInt() ?? 0;
    final phrase = _s(tile, 'badge_label');
    return Semantics(
      button: true,
      label: _s(tile, 'label'),
      child: InkWell(
        onTap: () => onOpen(tile),
        borderRadius: Ds.r.rCard,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.space.x48 + Ds.space.x16),
          padding: EdgeInsets.all(Ds.space.x12),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider),
            boxShadow: Ds.elevation.e1,
          ),
          child: Row(children: [
            NavGlyph(
              row: tile,
              box: Ds.space.x32,
              glyph: Ds.space.x16 + Ds.space.x4,
              background: Ds.c.brandSoft,
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_s(tile, 'label'),
                      style: Ds.t.bodyStrong,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  if (count > 0 && phrase.isNotEmpty)
                    Text(phrase,
                        style: Ds.t.caption.copyWith(color: Ds.c.brand),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The Money "right now" line: each stat is a backend sentence with its own
/// tone and the route that answers it.
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.stats, required this.onOpen});
  final List<Map<String, dynamic>> stats;
  final StaffTileTap onOpen;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final w = _tileWidth(box.maxWidth, Ds.space.x12, Ds.space.x48 * 3);
        return Wrap(
        spacing: Ds.space.x12,
        runSpacing: Ds.space.x12,
        children: [
          for (final s in stats)
            InkWell(
              onTap: _s(s, 'route_key').isEmpty ? null : () => onOpen(s),
              borderRadius: Ds.r.rCard,
              child: Container(
                key: Key('c1016_stat_${_s(s, 'key')}'),
                width: w,
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
                    Text(_s(s, 'value_label'),
                        style: Ds.t.title.copyWith(
                            color: switch (_s(s, 'tone')) {
                          'warn' => Ds.c.warning,
                          'bad' => Ds.c.danger,
                          'good' => Ds.c.success,
                          _ => Ds.c.text,
                        })),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(s, 'label'), style: Ds.t.caption),
                  ],
                ),
              ),
            ),
        ],
      );
      });
}

class _SearchField extends StatelessWidget {
  const _SearchField(
      {required this.controller, required this.hint, required this.onChanged});
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: Ds.space.x48,
        child: TextField(
          key: const Key('c1016_more_search'),
          controller: controller,
          onChanged: onChanged,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(Icons.search, color: Ds.c.textSecondary),
            isDense: true,
          ),
        ),
      );
}

/// Loading is a shape, not a spinner.
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final w = _tileWidth(box.maxWidth, Ds.space.x12, Ds.space.x48 * 3);
        return Wrap(
          spacing: Ds.space.x12,
          runSpacing: Ds.space.x12,
          children: [
            for (var i = 0; i < 6; i++)
              Container(
                width: w,
                height: Ds.space.x48 + Ds.space.x16,
                decoration: BoxDecoration(
                  color: Ds.c.bg,
                  borderRadius: Ds.r.rCard,
                ),
              ),
          ],
        );
      });
}
