// CMD #1891 — every "Also here" door, on the Dashboard, in six named sections.
// CMD #1892 — the layout those sections wear: needs-you-now as full-width rows
// with a coloured left bar, everything else as a square tile grid.
//
// `dashboard_home()` is ONE payload: the sections in the order they print,
// their labels, their empty lines, and inside each the tiles with their badge
// count and the tone that badge wears. Nothing on this screen is decided here —
// not the order, not the wording, not which section survives being empty
// (`show_when_empty`), not which tile carries a badge (needs_now only ever
// ships badged tiles). #1892 adds no string of its own: it chooses the SHAPE
// each section is drawn in from the section's own key, and the shapes'
// dimensions come off the Ds token scale.
//
// Nothing here imports Supabase: the loader is injected, so the protected test
// pumps every state on the Dart VM with an inline payload.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../fulfill/supplier_toggle_chips.dart'; // CMD #1941
import '../screens/admin/nav_registry_view.dart';
import '../utils/render_log.dart';

/// `dashboard_home()`.
typedef DashboardHomeLoad = Future<Map<String, dynamic>> Function();

/// A tile was tapped — the backend's own map, untouched.
typedef DashboardTileTap = void Function(Map<String, dynamic> tile);

/// CMD #1893 — a tile was held down. The Pin / Unpin sheet is the host's, not
/// the tile's: the tile only reports which one was held.
typedef DashboardTileHold = void Function(Map<String, dynamic> tile);

/// CMD #1941 — a pill in the AUTOMATION block was tapped. The screen runs
/// `dashboard_automation_set(key, next)` and hands back whatever it replied;
/// the block re-draws from that reply, so the ON/OFF word on screen is always
/// the one the SERVER just wrote, never a locally flipped guess.
typedef DashboardAutomationSet = Future<Map<String, dynamic>> Function(
    String key, bool next);

/// The Bundle pill's extra affordance — `dashboard_automation_action(key)`.
typedef DashboardAutomationAct = Future<Map<String, dynamic>> Function(
    String key);

/// A sentence the backend sent, shown as a toast. The wording is never this
/// widget's; it only decides whether the toast is an error one.
typedef DashboardToast = void Function(String message, bool isError);

/// The section drawn as full-width rows rather than as a tile grid. It is the
/// one section whose items are all badged, so a row can afford to spend the
/// whole width on "what" and "how many".
const String kNeedsNowSection = 'needs_now';

/// The content column never grows past this on a wide screen — a 6-across grid
/// stretched over a 2000px monitor is a row of postage stamps with a metre of
/// air between them. A layout bound, not a design token.
const double kDashboardMaxWidth = 1100;

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

List<Map<String, dynamic>> _list(Map<String, dynamic> m, String k) =>
    (m[k] as List?)
        ?.whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList() ??
    const <Map<String, dynamic>>[];

/// Columns in the tile grid: three across on a phone, five on a tablet, six on
/// a desktop. The tile keeps its square, so the count is what changes.
int dashboardTileColumns(double maxWidth) {
  if (maxWidth < 600) return 3;
  if (maxWidth < 900) return 5;
  return 6;
}

/// Width one tile gets once [dashboardTileColumns] have been laid out with
/// [gap] between them.
double dashboardTileWidth(double maxWidth, double gap) {
  final cols = dashboardTileColumns(maxWidth);
  return (maxWidth - gap * (cols - 1)) / cols;
}

/// The six sections, rendered in payload order.
class DashboardHomeSections extends StatefulWidget {
  const DashboardHomeSections({
    super.key,
    required this.load,
    required this.onOpen,
    this.onHold,
    this.revision,
    this.automationSet,
    this.automationAction,
    this.onToast,
  });

  final DashboardHomeLoad load;
  final DashboardTileTap onOpen;

  /// CMD #1941 — the AUTOMATION block's two doors. Null on a surface that does
  /// not offer the toggles; the block then never draws, whatever the payload
  /// said.
  final DashboardAutomationSet? automationSet;
  final DashboardAutomationAct? automationAction;
  final DashboardToast? onToast;

  /// CMD #1893 — long-press a tile to pin or unpin it. Null on a surface that
  /// has no Quick actions row to pin into.
  final DashboardTileHold? onHold;

  /// Ticks when a pin changed, so the sections redraw with the new
  /// `pin_action_label` the backend now returns for that tile.
  final ValueListenable<int>? revision;

  @override
  State<DashboardHomeSections> createState() => _DashboardHomeSectionsState();
}

class _DashboardHomeSectionsState extends State<DashboardHomeSections> {
  Map<String, dynamic> _home = const {};
  bool _loading = true;

  /// CMD #1941 — `dashboard_home().automation`, replaced wholesale by whatever
  /// `dashboard_automation_set()` replies. Never patched field by field.
  Map<String, dynamic> _automation = const {};

  /// Pills whose RPC is in flight; those spin and refuse taps.
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    widget.revision?.addListener(_fetch);
    _fetch();
  }

  @override
  void dispose() {
    widget.revision?.removeListener(_fetch);
    super.dispose();
  }

  Future<void> _fetch() async {
    try {
      final m = await widget.load();
      if (!mounted) return;
      setState(() {
        _home = m;
        _automation = (m['automation'] is Map)
            ? Map<String, dynamic>.from(m['automation'] as Map)
            : const {};
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

  /// CMD #1941 — the AUTOMATION pills. `show:false` (a login that may not
  /// switch them) and a surface with no `automationSet` both mean no block.
  List<SupplierToggleChip> get _autoChips =>
      (widget.automationSet == null || _automation['show'] != true)
          ? const []
          : SupplierToggleChip.listFrom(_automation['items']);

  /// Tap. The reply IS the new state — including a refusal, which re-draws the
  /// pill exactly as the server still has it.
  Future<void> _runAutomation(
      String key, Future<Map<String, dynamic>> Function() call) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      final res = await call();
      if (!mounted) return;
      final ok = res['ok'] == true;
      final next = (res['automation'] is Map)
          ? Map<String, dynamic>.from(res['automation'] as Map)
          : null;
      setState(() {
        if (next != null) _automation = next;
        _busy.remove(key);
      });
      final msg = (ok ? (res['toast'] ?? '') : (res['message'] ?? '')).toString();
      if (msg.isNotEmpty) widget.onToast?.call(msg, !ok);
      RenderLog.write('c1941_automation_set', '$key=$ok');
    } catch (_) {
      // A failed call leaves the previous answer on screen; it never invents
      // one, and the pill stops spinning.
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  /// A section prints when it has tiles, or when the backend said it prints
  /// empty. Which is which is `show_when_empty`, a column, not a Dart rule.
  List<Map<String, dynamic>> _visible() => [
        for (final s in _list(_home, 'sections'))
          if (_list(s, 'items').isNotEmpty || s['show_when_empty'] == true) s,
      ];

  @override
  Widget build(BuildContext context) {
    if (_loading && _home.isEmpty) return const DashboardSectionsSkeleton();
    if (_home['ok'] != true) return const SizedBox.shrink();
    final sections = _visible();
    final autoChips = _autoChips;
    if (sections.isEmpty && autoChips.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c1892_dashboard_layout', sections.length);
    return Column(
      key: const Key('c1891_dashboard_sections'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // CMD #1941 — AUTOMATION first: the toggles that used to hide under the
        // Supplier inquiry and Supplier orders sub-tabs, where a phone could
        // not reach them. Its heading is the payload's, like every other one.
        if (autoChips.isNotEmpty) ...[
          DashboardSectionLabel(_s(_automation, 'label')),
          Builder(builder: (_) {
            RenderLog.write('c1941_automation_block', autoChips.length);
            return SupplierToggleChipRow(
              key: const Key('c1941_automation'),
              chips: autoChips,
              busyKeys: _busy,
              onToggle: (chip, next) => _runAutomation(
                  chip.key, () => widget.automationSet!(chip.key, next)),
              onAction: widget.automationAction == null
                  ? null
                  : (chip) => _runAutomation(
                      chip.key, () => widget.automationAction!(chip.key)),
              onSettings: (chip) => showAutomationSettingsSheet(
                context,
                chip,
                onToggle: (c, next) => _runAutomation(
                    c.key, () => widget.automationSet!(c.key, next)),
                onAction: widget.automationAction == null
                    ? null
                    : (c) => _runAutomation(
                        c.key, () => widget.automationAction!(c.key)),
              ),
            );
          }),
          SizedBox(height: Ds.space.x24),
        ],
        for (final s in sections) ...[
          DashboardSectionLabel(_s(s, 'label')),
          if (_list(s, 'items').isEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Text(_s(s, 'empty_label'), style: Ds.t.bodySecondary),
            )
          else if (_s(s, 'key') == kNeedsNowSection)
            _NeedsNowRows(
                tiles: _list(s, 'items'),
                onOpen: widget.onOpen,
                onHold: widget.onHold)
          else
            DashboardTileGrid(
                tiles: _list(s, 'items'),
                onOpen: widget.onOpen,
                onHold: widget.onHold),
          SizedBox(height: Ds.space.x24),
        ],
      ],
    );
  }
}

/// The row heading every dashboard row wears — the six sections and, since
/// CMD #1893, Quick actions and Recently used too. One class, so a personal row
/// can never drift away from a section heading.
class DashboardSectionLabel extends StatelessWidget {
  const DashboardSectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Text(
          text,
          style: Ds.t.caption.copyWith(
            fontWeight: FontWeight.w600,
            color: Ds.c.textSecondary,
            letterSpacing: 1.0,
          ),
        ),
      );
}

// ── Needs you now ────────────────────────────────────────────────────────────

/// Full-width rows, worst first (the backend already ordered them). The bar
/// down the left is the payload's tone: a breach is red, due-soon is amber.
class _NeedsNowRows extends StatelessWidget {
  const _NeedsNowRows({required this.tiles, required this.onOpen, this.onHold});
  final List<Map<String, dynamic>> tiles;
  final DashboardTileTap onOpen;
  final DashboardTileHold? onHold;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final t in tiles)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: DashboardNeedsNowRow(
                  tile: t, onOpen: onOpen, onHold: onHold),
            ),
        ],
      );
}

/// One needs-you-now row: the bar, the label, the phrase the backend wrote
/// under it, and the count on the right.
class DashboardNeedsNowRow extends StatelessWidget {
  const DashboardNeedsNowRow({
    super.key,
    required this.tile,
    required this.onOpen,
    this.onHold,
  });

  final Map<String, dynamic> tile;
  final DashboardTileTap onOpen;
  final DashboardTileHold? onHold;

  @override
  Widget build(BuildContext context) {
    final count = (tile['badge_count'] as num?)?.toInt() ?? 0;
    final tone = _s(tile, 'badge_tone');
    final phrase = _s(tile, 'badge_label');
    final bar = DashboardHomeTile.toneColor(tone);
    return Semantics(
      button: true,
      label: _s(tile, 'label'),
      child: InkWell(
        key: Key('c1891_tile_${_s(tile, 'feature_key')}'),
        onTap: () => onOpen(tile),
        onLongPress: onHold == null ? null : () => onHold!(tile),
        borderRadius: Ds.r.rButton,
        child: Container(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rButton,
            boxShadow: Ds.elevation.e1,
          ),
          child: ClipRRect(
            borderRadius: Ds.r.rButton,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // The bar: 4px of the payload's own tone, full height.
                  Container(width: Ds.space.x4, color: bar),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: Ds.space.x16, vertical: Ds.space.x12),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_s(tile, 'label'),
                                  style: Ds.t.bodyStrong,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              if (phrase.isNotEmpty)
                                Text(phrase,
                                    style: Ds.t.caption.copyWith(color: bar),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        SizedBox(width: Ds.space.x12),
                        if (count > 0)
                          Text('$count',
                              style: Ds.t.subtitle.copyWith(color: bar)),
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── The tile grid ────────────────────────────────────────────────────────────

/// The square-tile grid. [columns] overrides the responsive count — Quick
/// actions is 4 across because the payload says `columns: 4`, not because Dart
/// decided a pinned row looks better that way.
class DashboardTileGrid extends StatelessWidget {
  const DashboardTileGrid({
    super.key,
    required this.tiles,
    required this.onOpen,
    this.onHold,
    this.columns,
  });
  final List<Map<String, dynamic>> tiles;
  final DashboardTileTap onOpen;
  final DashboardTileHold? onHold;
  final int? columns;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final gap = Ds.space.x12;
        final cols = columns ?? dashboardTileColumns(box.maxWidth);
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final t in tiles)
              SizedBox(
                  width: w,
                  height: dashboardTileSide,
                  child: DashboardHomeTile(
                      tile: t, onOpen: onOpen, onHold: onHold)),
          ],
        );
      });
}

/// The tile's square — 88pt, spelled on the spacing scale (48 + 32 + 8) so a
/// backend that re-scales the app re-scales the tile with it.
double get dashboardTileSide => Ds.space.x48 + Ds.space.x32 + Ds.space.x8;

/// One tile: a green line icon on a pale-green disc, the label under it, and —
/// only when the payload sent one — a small badge pill in the top-right corner.
class DashboardHomeTile extends StatelessWidget {
  const DashboardHomeTile({
    super.key,
    required this.tile,
    required this.onOpen,
    this.onHold,
  });

  final Map<String, dynamic> tile;
  final DashboardTileTap onOpen;
  final DashboardTileHold? onHold;

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
    return Semantics(
      button: true,
      label: _s(tile, 'label'),
      child: InkWell(
        key: Key('c1891_tile_${_s(tile, 'feature_key')}'),
        onTap: () => onOpen(tile),
        onLongPress: onHold == null ? null : () => onHold!(tile),
        borderRadius: Ds.r.rButton,
        child: Container(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rButton,
            border: Border.all(color: Ds.c.divider),
            boxShadow: Ds.elevation.e1,
          ),
          child: Stack(children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: Ds.space.x32 + Ds.space.x4,
                    height: Ds.space.x32 + Ds.space.x4,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Ds.c.brandSoft,
                      shape: BoxShape.circle,
                    ),
                    child: NavGlyph(
                      row: tile,
                      box: Ds.space.x24,
                      glyph: Ds.space.x16 + Ds.space.x4,
                      color: Ds.c.brand,
                    ),
                  ),
                  SizedBox(height: Ds.space.x8),
                  Text(
                    _s(tile, 'label'),
                    textAlign: TextAlign.center,
                    style: Ds.t.caption.copyWith(color: Ds.c.text),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (count > 0)
              Positioned(
                top: Ds.space.x4,
                right: Ds.space.x4,
                child: _Badge(count: count),
              ),
          ]),
        ),
      ),
    );
  }
}

/// The badge pill. Red, always: on this page red means "this has a number on
/// it", and nothing else on the tile is allowed to wear it.
class _Badge extends StatelessWidget {
  const _Badge({required this.count});
  final int count;
  @override
  Widget build(BuildContext context) => Container(
        constraints: BoxConstraints(minWidth: Ds.space.x16),
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Ds.c.danger,
          borderRadius: Ds.r.rChip,
        ),
        child: Text('$count',
            style: Ds.t.caption.copyWith(
                color: Ds.c.surface, fontWeight: FontWeight.w600)),
      );
}

/// Loading is a shape, not a spinner: one row band, then a grid of squares.
class DashboardSectionsSkeleton extends StatelessWidget {
  const DashboardSectionsSkeleton({super.key});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final w = dashboardTileWidth(box.maxWidth, Ds.space.x12);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: Ds.space.x48 + Ds.space.x8,
              decoration: BoxDecoration(
                color: Ds.c.bg,
                borderRadius: Ds.r.rButton,
              ),
            ),
            SizedBox(height: Ds.space.x24),
            Wrap(
              spacing: Ds.space.x12,
              runSpacing: Ds.space.x12,
              children: [
                for (var i = 0; i < 6; i++)
                  Container(
                    width: w,
                    height: dashboardTileSide,
                    decoration: BoxDecoration(
                      color: Ds.c.bg,
                      borderRadius: Ds.r.rButton,
                    ),
                  ),
              ],
            ),
          ],
        );
      });
}
