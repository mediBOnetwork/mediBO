// CMD #1893 — the two PERSONAL rows at the top of the Dashboard: the tiles
// this login pinned, and the ones it opened last.
//
// Both arrive inside the SAME `dashboard_home()` payload that draws the six
// sections below them — `quick` and `recent`, shaped exactly like a section
// (key / label / empty_label / show_when_empty / items) so the tile widget,
// the heading and the grid are all the ones #1891 and #1892 already wrote.
// Nothing on these rows is decided in Dart:
//   * the headings are ui_copy strings,
//   * "Long-press any tile to pin it here" is `quick.empty_label`,
//   * 4 across is `quick.columns`,
//   * "Pin to Quick actions" / "Remove from Quick actions" is each tile's own
//     `pin_action_label`, and the toast after a toggle is nav_pin_toggle()'s
//     `message`,
//   * Recently used hides itself because the backend sent
//     `show_when_empty: false`, not because a Dart branch says so.
//
// Nothing here imports Supabase: the loader and the toggle are injected, so the
// protected test pumps every state on the Dart VM with an inline payload.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';
import 'dashboard_home_sections.dart';

/// `nav_pin_toggle(feature_key)` — returns the backend's own reply, including
/// the message the toast prints.
typedef DashboardPinToggle = Future<Map<String, dynamic>> Function(
    String featureKey);

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

Map<String, dynamic> _map(Map<String, dynamic> m, String k) =>
    m[k] is Map ? Map<String, dynamic>.from(m[k] as Map) : const {};

List<Map<String, dynamic>> _items(Map<String, dynamic> row) =>
    (row['items'] as List?)
        ?.whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList() ??
    const <Map<String, dynamic>>[];

/// ONE `dashboard_home()` round trip feeds both this file's personal rows and
/// the six sections under them. Without it the Dashboard would ask the same
/// question twice on every open — and, worse, could draw a pinned tile from one
/// answer next to a section tile from another.
///
/// [invalidate] is what a pin toggle calls: it drops the held answer and ticks
/// [revision], which both widgets listen to.
class DashboardHomeFeed {
  DashboardHomeFeed(this.fetch);

  final DashboardHomeLoad fetch;
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  Future<Map<String, dynamic>>? _held;

  Future<Map<String, dynamic>> read() => _held ??= fetch();

  void invalidate() {
    _held = null;
    revision.value++;
  }

  void dispose() => revision.dispose();
}

/// Quick actions, then Recently used. Drawn directly under the search field.
class DashboardPersonalRows extends StatefulWidget {
  const DashboardPersonalRows({
    super.key,
    required this.load,
    required this.onOpen,
    this.onHold,
    this.revision,
  });

  final DashboardHomeLoad load;
  final DashboardTileTap onOpen;
  final DashboardTileHold? onHold;
  final ValueListenable<int>? revision;

  @override
  State<DashboardPersonalRows> createState() => _DashboardPersonalRowsState();
}

class _DashboardPersonalRowsState extends State<DashboardPersonalRows> {
  Map<String, dynamic> _home = const {};
  bool _loading = true;

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
        _loading = false;
      });
    } catch (_) {
      // The previous payload stays on screen — a failed refresh is not an
      // empty row.
      if (mounted) setState(() => _loading = false);
    }
  }

  /// A row prints when it has tiles, or when the backend said it prints empty.
  bool _prints(Map<String, dynamic> row) =>
      _items(row).isNotEmpty || row['show_when_empty'] == true;

  @override
  Widget build(BuildContext context) {
    if (_loading && _home.isEmpty) return const DashboardPersonalSkeleton();
    if (_home['ok'] != true) return const SizedBox.shrink();
    final quick = _map(_home, 'quick');
    final recent = _map(_home, 'recent');
    RenderLog.write('c1893_quick', _items(quick).length);
    RenderLog.write('c1893_recent', _items(recent).length);
    if (!_prints(quick) && !_prints(recent)) return const SizedBox.shrink();
    return Column(
      key: const Key('c1893_personal_rows'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_prints(quick)) ...[
          DashboardSectionLabel(_s(quick, 'label')),
          if (_items(quick).isEmpty)
            Padding(
              key: const Key('c1893_quick_empty'),
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Text(_s(quick, 'empty_label'), style: Ds.t.bodySecondary),
            )
          else
            DashboardTileGrid(
              key: const Key('c1893_quick_grid'),
              tiles: _items(quick),
              onOpen: widget.onOpen,
              onHold: widget.onHold,
              columns: (quick['columns'] as num?)?.toInt(),
            ),
          SizedBox(height: Ds.space.x24),
        ],
        if (_prints(recent)) ...[
          DashboardSectionLabel(_s(recent, 'label')),
          DashboardRecentStrip(
            key: const Key('c1893_recent_strip'),
            tiles: _items(recent),
            onOpen: widget.onOpen,
            onHold: widget.onHold,
          ),
          SizedBox(height: Ds.space.x24),
        ],
      ],
    );
  }
}

/// Recently used: ONE horizontal strip, newest first, in the order the payload
/// sent. It scrolls sideways rather than wrapping — six tiles are a strip, not
/// a grid, and the grid below it is where "everything" lives.
class DashboardRecentStrip extends StatelessWidget {
  const DashboardRecentStrip({
    super.key,
    required this.tiles,
    required this.onOpen,
    this.onHold,
  });

  final List<Map<String, dynamic>> tiles;
  final DashboardTileTap onOpen;
  final DashboardTileHold? onHold;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final gap = Ds.space.x12;
        // The same tile width Quick actions uses, so the two rows line up.
        final w = (box.maxWidth - gap * 3) / 4;
        return SizedBox(
          height: dashboardTileSide,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: tiles.length,
            separatorBuilder: (_, _) => SizedBox(width: gap),
            itemBuilder: (_, i) => SizedBox(
              width: w,
              child: DashboardHomeTile(
                  tile: tiles[i], onOpen: onOpen, onHold: onHold),
            ),
          ),
        );
      });
}

/// The Pin / Unpin sheet. A sheet, not a dialog, and it carries exactly one
/// line: the tile's own `pin_action_label`. The toast underneath is
/// nav_pin_toggle()'s `message`.
Future<void> showDashboardPinSheet(
  BuildContext context,
  Map<String, dynamic> tile,
  DashboardPinToggle toggle,
) async {
  final featureKey = _s(tile, 'feature_key');
  if (featureKey.isEmpty) return;
  final action = _s(tile, 'pin_action_label');
  if (action.isEmpty) return;
  RenderLog.write('c1893_pin_sheet', featureKey);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final go = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, 0, Ds.space.x16, Ds.space.x8),
            child: Text(_s(tile, 'label'), style: Ds.t.subtitle),
          ),
          ListTile(
            key: const Key('c1893_pin_action'),
            leading: Icon(
              tile['pinned'] == true
                  ? Icons.push_pin_outlined
                  : Icons.push_pin,
              color: Ds.c.brand,
            ),
            title: Text(action, style: Ds.t.body),
            onTap: () => Navigator.of(ctx).pop(true),
          ),
          SizedBox(height: Ds.space.x8),
        ],
      ),
    ),
  );
  if (go != true) return;
  final reply = await toggle(featureKey);
  final message = _s(reply, 'message');
  if (message.isNotEmpty) {
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Loading is a shape, not a spinner: one heading band and four squares.
class DashboardPersonalSkeleton extends StatelessWidget {
  const DashboardPersonalSkeleton({super.key});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, box) {
        final gap = Ds.space.x12;
        final w = (box.maxWidth - gap * 3) / 4;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: box.maxWidth / 3,
              height: Ds.space.x12,
              decoration:
                  BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rChip),
            ),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                for (var i = 0; i < 4; i++) ...[
                  Container(
                    width: w,
                    height: dashboardTileSide,
                    decoration: BoxDecoration(
                        color: Ds.c.bg, borderRadius: Ds.r.rButton),
                  ),
                  if (i < 3) SizedBox(width: gap),
                ],
              ],
            ),
            SizedBox(height: Ds.space.x24),
          ],
        );
      });
}
