// CMD #1891 — every "Also here" door, on the Dashboard, in six named sections.
//
// The doors that used to hide in a horizontal chip strip above Customers,
// Suppliers and Fulfill are drawn here instead. `dashboard_home()` is ONE
// payload: the sections in the order they print, their labels, their empty
// lines, and inside each the tiles with their badge count and the tone that
// badge wears. Nothing on this screen is decided here — not the order, not the
// wording, not which section survives being empty (`show_when_empty`), not
// which tile carries a badge (needs_now only ever ships badged tiles).
//
// Nothing here imports Supabase: the loader is injected, so the protected test
// pumps every state on the Dart VM with an inline payload.
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../screens/admin/nav_registry_view.dart';
import '../utils/render_log.dart';

/// `dashboard_home()`.
typedef DashboardHomeLoad = Future<Map<String, dynamic>> Function();

/// A tile was tapped — the backend's own map, untouched.
typedef DashboardTileTap = void Function(Map<String, dynamic> tile);

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

List<Map<String, dynamic>> _list(Map<String, dynamic> m, String k) =>
    (m[k] as List?)
        ?.whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList() ??
    const <Map<String, dynamic>>[];

/// The six sections, rendered in payload order.
class DashboardHomeSections extends StatefulWidget {
  const DashboardHomeSections({
    super.key,
    required this.load,
    required this.onOpen,
  });

  final DashboardHomeLoad load;
  final DashboardTileTap onOpen;

  @override
  State<DashboardHomeSections> createState() => _DashboardHomeSectionsState();
}

class _DashboardHomeSectionsState extends State<DashboardHomeSections> {
  Map<String, dynamic> _home = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    try {
      final m = await widget.load();
      if (!mounted) return;
      setState(() {
        _home = m;
        _loading = false;
      });
      RenderLog.write('c1891_dashboard_sections',
          '${_list(m, 'sections').length};items=${_s(m, 'items_count')}');
    } catch (_) {
      // The previous payload stays on screen — a failed refresh is not an
      // empty dashboard.
      if (mounted) setState(() => _loading = false);
    }
  }

  /// A section prints when it has tiles, or when the backend said it prints
  /// empty (needs_now: "nothing needs you right now" is an answer).
  List<Map<String, dynamic>> _visible() => [
        for (final s in _list(_home, 'sections'))
          if (_list(s, 'items').isNotEmpty || s['show_when_empty'] == true) s,
      ];

  @override
  Widget build(BuildContext context) {
    if (_loading && _home.isEmpty) return const DashboardSectionsSkeleton();
    if (_home['ok'] != true) return const SizedBox.shrink();
    final sections = _visible();
    if (sections.isEmpty) return const SizedBox.shrink();
    return Column(
      key: const Key('c1891_dashboard_sections'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in sections) ...[
          _SectionLabel(_s(s, 'label')),
          if (_list(s, 'items').isEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Text(_s(s, 'empty_label'), style: Ds.t.bodySecondary),
            )
          else
            _TileWrap(tiles: _list(s, 'items'), onOpen: widget.onOpen),
          SizedBox(height: Ds.space.x24),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Text(
          text,
          style: Ds.t.caption.copyWith(
            fontWeight: FontWeight.w700,
            color: Ds.c.textSecondary,
            letterSpacing: 1.0,
          ),
        ),
      );
}

/// Tiles share the row: the column count comes from the width on offer, so a
/// phone gets two across and a desktop as many as fit.
double dashboardTileWidth(double maxWidth, double gap, double minTile) {
  final cols = (maxWidth / (minTile + gap)).floor().clamp(1, 6);
  return (maxWidth - gap * (cols - 1)) / cols;
}

class _TileWrap extends StatelessWidget {
  const _TileWrap({required this.tiles, required this.onOpen});
  final List<Map<String, dynamic>> tiles;
  final DashboardTileTap onOpen;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final w = dashboardTileWidth(
            box.maxWidth, Ds.space.x12, Ds.space.x48 * 3);
        return Wrap(
          spacing: Ds.space.x12,
          runSpacing: Ds.space.x12,
          children: [
            for (final t in tiles)
              SizedBox(
                  width: w, child: DashboardHomeTile(tile: t, onOpen: onOpen)),
          ],
        );
      });
}

/// One tile: glyph, label, and the badge the payload asked for — count and
/// tone both. A tile with no badge simply has none.
class DashboardHomeTile extends StatelessWidget {
  const DashboardHomeTile({
    super.key,
    required this.tile,
    required this.onOpen,
  });

  final Map<String, dynamic> tile;
  final DashboardTileTap onOpen;

  static Color toneColor(String tone) => switch (tone) {
        'bad' => Ds.c.danger,
        'warn' => Ds.c.warning,
        'good' => Ds.c.success,
        _ => Ds.c.brand,
      };

  static Color toneSoft(String tone) => switch (tone) {
        'bad' => Ds.c.dangerSoft,
        'warn' => Ds.c.warningSoft,
        'good' => Ds.c.successSoft,
        _ => Ds.c.brandSoft,
      };

  @override
  Widget build(BuildContext context) {
    final count = (tile['badge_count'] as num?)?.toInt() ?? 0;
    final tone = _s(tile, 'badge_tone');
    final phrase = _s(tile, 'badge_label');
    return Semantics(
      button: true,
      label: _s(tile, 'label'),
      child: InkWell(
        key: Key('c1891_tile_${_s(tile, 'feature_key')}'),
        onTap: () => onOpen(tile),
        borderRadius: Ds.r.rCard,
        child: Container(
          constraints:
              BoxConstraints(minHeight: Ds.space.x48 + Ds.space.x16),
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
              color: count > 0 ? toneColor(tone) : null,
              background: count > 0 ? toneSoft(tone) : Ds.c.brandSoft,
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
                        style: Ds.t.caption.copyWith(color: toneColor(tone)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (count > 0) ...[
              SizedBox(width: Ds.space.x8),
              _Badge(count: count, tone: tone),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, required this.tone});
  final int count;
  final String tone;
  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: DashboardHomeTile.toneSoft(tone),
          borderRadius: Ds.r.rChip,
        ),
        child: Text('$count',
            style: Ds.t.caption.copyWith(
                color: DashboardHomeTile.toneColor(tone),
                fontWeight: FontWeight.w600)),
      );
}

/// Loading is a shape, not a spinner.
class DashboardSectionsSkeleton extends StatelessWidget {
  const DashboardSectionsSkeleton({super.key});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final w = dashboardTileWidth(
            box.maxWidth, Ds.space.x12, Ds.space.x48 * 3);
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
