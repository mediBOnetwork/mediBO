// CHANGE #325 — the dashboard IS the nav, and the registry IS the dashboard.
//
// Om's complaint: every new feature landed in the profile dropdown, which grew
// to ~30 items, while the dashboard — the thing that exists so a feature is one
// tap away — stayed a hand-written list of eight tiles. From this change the
// dropdown holds only View Profile and Logout, and everything else is drawn
// from `nav_registry()`: categories, labels, icons, order, live counts and the
// role composition all arrive in the payload.
//
// Nothing in this file decides what an admin can see. It has no Supabase
// import and no role test — it renders `nav_registry()`'s answer and hands
// taps back. That is also what makes it pump on the Dart VM in a widget test
// with an inline payload, the way every protected test in this repo works.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// The backend's `icon_key` → a glyph. This is the ONE thing that cannot live
/// in Postgres: an IconData is a font codepoint, not a string. Everything else
/// about a tile — its label, its category, its order, its count and its phrase
/// — comes down in the payload. An unknown key falls back to a neutral tile
/// rather than throwing, so the backend can register a screen with a brand-new
/// icon_key and it still renders (forward compatibility, same rule the home
/// feed follows for unknown layouts).
IconData navIcon(String? key) {
  switch (key) {
    case 'truck':            return Icons.local_shipping_outlined;
    case 'alert':            return Icons.notifications_active_outlined;
    case 'task':             return Icons.task_alt_outlined;
    case 'qr':               return Icons.qr_code_2;
    case 'autorenew':        return Icons.autorenew;
    case 'people':           return Icons.people_outline;
    case 'inventory':        return Icons.inventory_2_outlined;
    case 'person_add':       return Icons.person_add_outlined;
    case 'add_business':     return Icons.add_business_outlined;
    case 'badge':            return Icons.badge_outlined;
    case 'business':         return Icons.business_outlined;
    case 'link_off':         return Icons.link_off;
    case 'person_remove':    return Icons.person_remove_outlined;
    case 'medication':       return Icons.medication_outlined;
    case 'rupee':            return Icons.currency_rupee;
    case 'percent':          return Icons.percent;
    case 'stars':            return Icons.stars_outlined;
    case 'moped':            return Icons.delivery_dining_outlined;
    case 'route':            return Icons.alt_route;
    case 'forum':            return Icons.forum_outlined;
    case 'description':      return Icons.description_outlined;
    case 'campaign':         return Icons.campaign_outlined;
    case 'filter':           return Icons.filter_alt_outlined;
    case 'timeline':         return Icons.timeline_outlined;
    case 'settings_suggest': return Icons.settings_suggest_outlined;
    case 'fact_check':       return Icons.fact_check_outlined;
    case 'notifications':    return Icons.notifications_outlined;
    case 'phonelink_ring':   return Icons.phonelink_ring_outlined;
    case 'payments':         return Icons.payments_outlined;
    case 'receipt':          return Icons.receipt_long_outlined;
    case 'account_balance':  return Icons.account_balance_outlined;
    case 'trending_up':      return Icons.trending_up;
    case 'handshake':        return Icons.handshake_outlined;
    case 'admin_panel':      return Icons.admin_panel_settings_outlined;
    case 'terminal':         return Icons.terminal;
    case 'rule':             return Icons.rule_outlined;
    case 'rule_folder':      return Icons.rule_folder_outlined;
    case 'schedule':         return Icons.schedule_outlined;
    case 'person':           return Icons.person_outline;
    case 'logout':           return Icons.logout;
    case 'book':             return Icons.menu_book_outlined;
    case 'settings':         return Icons.settings_outlined;
    case 'search':           return Icons.search;
    default:                 return Icons.widgets_outlined;
  }
}

/// A tap on a registry tile. [tile] is the backend's own map, handed back
/// untouched so the caller reads `route_key` / `deep_link` / `feature_key`
/// from the payload rather than from anything this file inferred.
typedef NavTileTap = void Function(Map<String, dynamic> tile);

/// Long-press → `nav_pin_toggle(feature_key)`. Returns the RPC's reply so the
/// toast text is the backend's `message`, never a string written here.
typedef NavPinToggle = Future<Map<String, dynamic>> Function(String featureKey);

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

/// The Action Required block: only the features that have a live count to
/// answer, each one opening the screen that answers it. A tile with no count
/// is not an action — it lives in its category section below instead.
class NavActionTiles extends StatelessWidget {
  final List<Map<String, dynamic>> tiles;
  final String emptyLabel;
  final NavTileTap onOpen;

  const NavActionTiles({
    super.key,
    required this.tiles,
    required this.emptyLabel,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c325_action_tiles', tiles.length);
    if (tiles.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
        child: Text(emptyLabel, style: Ds.t.caption),
      );
    }
    return Wrap(
      spacing: Ds.space.x12,
      runSpacing: Ds.space.x12,
      children: [for (final t in tiles) _ActionTile(tile: t, onOpen: onOpen)],
    );
  }
}

class _ActionTile extends StatelessWidget {
  final Map<String, dynamic> tile;
  final NavTileTap onOpen;

  const _ActionTile({required this.tile, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final count = (tile['badge_count'] as num?)?.toInt() ?? 0;
    // The phrase under the number is the backend's `badge_label` — "10 bills to
    // review" is composed in SQL from the count and the feature's own noun, so
    // the app never pluralises anything.
    final phrase = _s(tile, 'badge_label');
    return Semantics(
      button: true,
      label: phrase,
      child: InkWell(
        onTap: () => onOpen(tile),
        borderRadius: BorderRadius.circular(Ds.r.card),
        child: Container(
          width: 180,
          constraints: BoxConstraints(minHeight: Ds.space.x48 + Ds.space.x32),
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: BorderRadius.circular(Ds.r.card),
            border: Border.all(color: Ds.c.divider),
            boxShadow: Ds.elevation.e1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: Ds.space.x32 + Ds.space.x4,
                height: Ds.space.x32 + Ds.space.x4,
                decoration: BoxDecoration(
                  color: Ds.c.brandSoft,
                  borderRadius: BorderRadius.circular(Ds.r.button),
                ),
                child: Icon(navIcon(_s(tile, 'icon_key')),
                    size: Ds.space.x16 + Ds.space.x4, color: Ds.c.brand),
              ),
              SizedBox(height: Ds.space.x12),
              Text('$count',
                  style: Ds.t.display.copyWith(color: Ds.c.brand)),
              SizedBox(height: Ds.space.x4),
              Text(phrase.isEmpty ? _s(tile, 'label') : phrase,
                  style: Ds.t.caption, maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

/// The categorised, collapsible body of the dashboard. Sections and their
/// order come from `nav_category`; the items inside one come already sorted by
/// the backend (pinned first, then what this admin actually opens, then the
/// registry's own order) and are rendered in payload order — no client sort.
class NavSections extends StatefulWidget {
  final List<Map<String, dynamic>> sections;
  final List<Map<String, dynamic>> pinned;
  final String pinnedLabel;
  final String pinHint;
  final NavTileTap onOpen;
  final NavPinToggle onPin;

  const NavSections({
    super.key,
    required this.sections,
    required this.pinned,
    required this.pinnedLabel,
    required this.pinHint,
    required this.onOpen,
    required this.onPin,
  });

  @override
  State<NavSections> createState() => _NavSectionsState();
}

class _NavSectionsState extends State<NavSections> {
  /// Collapsed sections, by the backend's own category_key. Everything starts
  /// open: the whole point of the change is that a feature is visible without
  /// hunting for it, so collapsing is a choice the admin makes, not a default
  /// they have to undo.
  final Set<String> _collapsed = <String>{};

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c325_nav_sections', widget.sections.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.pinned.isNotEmpty) ...[
          _SectionHeader(
            label: widget.pinnedLabel,
            icon: Icons.push_pin_outlined,
            collapsed: false,
            onTap: null,
          ),
          SizedBox(height: Ds.space.x12),
          _TileWrap(
              tiles: widget.pinned, onOpen: widget.onOpen, onPin: widget.onPin),
          SizedBox(height: Ds.space.x24),
        ],
        for (final section in widget.sections) ...[
          Builder(builder: (_) {
            final key = _s(section, 'category_key');
            final items = (section['items'] as List?)
                    ?.whereType<Map>()
                    .map((e) => Map<String, dynamic>.from(e))
                    .toList() ??
                const <Map<String, dynamic>>[];
            // An empty section is skipped silently — the same forward-compat
            // rule the home feed follows, so the backend can register a
            // category before any feature lands in it.
            if (items.isEmpty) return const SizedBox.shrink();
            final isCollapsed = _collapsed.contains(key);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _SectionHeader(
                  label: _s(section, 'label'),
                  icon: navIcon(_s(section, 'icon_key')),
                  collapsed: isCollapsed,
                  onTap: () => setState(() {
                    if (!_collapsed.remove(key)) _collapsed.add(key);
                  }),
                ),
                if (!isCollapsed) ...[
                  SizedBox(height: Ds.space.x12),
                  _TileWrap(
                      tiles: items,
                      onOpen: widget.onOpen,
                      onPin: widget.onPin),
                ],
                SizedBox(height: Ds.space.x24),
              ],
            );
          }),
        ],
        Text(widget.pinHint, style: Ds.t.caption),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool collapsed;
  final VoidCallback? onTap;

  const _SectionHeader({
    required this.label,
    required this.icon,
    required this.collapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Ds.r.button),
      child: Container(
        height: Ds.space.x48,
        alignment: Alignment.centerLeft,
        child: Row(children: [
          Icon(icon, size: Ds.space.x16 + Ds.space.x4, color: Ds.c.textSecondary),
          SizedBox(width: Ds.space.x8),
          Expanded(child: Text(label, style: Ds.t.subtitle)),
          if (onTap != null)
            Icon(collapsed ? Icons.expand_more : Icons.expand_less,
                size: Ds.space.x24, color: Ds.c.textSecondary),
        ]),
      ),
    );
  }
}

class _TileWrap extends StatelessWidget {
  final List<Map<String, dynamic>> tiles;
  final NavTileTap onOpen;
  final NavPinToggle onPin;

  const _TileWrap(
      {required this.tiles, required this.onOpen, required this.onPin});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Ds.space.x12,
      runSpacing: Ds.space.x12,
      children: [
        for (final t in tiles) NavTile(tile: t, onOpen: onOpen, onPin: onPin),
      ],
    );
  }
}

/// One registry tile. Tap opens; long-press pins or unpins it, and the toast
/// it shows is the RPC's own `message`.
///
/// Stateful only so the long-press can hold the messenger it captured BEFORE
/// awaiting the RPC — reaching for the context after the await is exactly the
/// unmounted-context bug the analyzer flags.
class NavTile extends StatefulWidget {
  final Map<String, dynamic> tile;
  final NavTileTap onOpen;
  final NavPinToggle onPin;

  const NavTile(
      {super.key,
      required this.tile,
      required this.onOpen,
      required this.onPin});

  @override
  State<NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<NavTile> {
  Future<void> _pin() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final reply = await widget.onPin(_s(widget.tile, 'feature_key'));
    final message = (reply['message'] ?? '').toString();
    if (!mounted || message.isEmpty) return;
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final tile = widget.tile;
    final count = (tile['badge_count'] as num?)?.toInt() ?? 0;
    final pinned = tile['pinned'] == true;
    final icon = Icon(navIcon(_s(tile, 'icon_key')),
        size: Ds.space.x16 + Ds.space.x4, color: Ds.c.brand);
    return InkWell(
      onTap: () => widget.onOpen(tile),
      onLongPress: _pin,
      borderRadius: BorderRadius.circular(Ds.r.button),
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.space.x48),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: BorderRadius.circular(Ds.r.button),
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: Ds.space.x32,
            height: Ds.space.x32,
            decoration: BoxDecoration(
              color: Ds.c.brandSoft,
              borderRadius: BorderRadius.circular(Ds.r.button),
            ),
            child: count > 0 ? Badge(label: Text('$count'), child: icon) : icon,
          ),
          SizedBox(width: Ds.space.x8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(_s(tile, 'label'),
                style: Ds.t.bodyStrong,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          if (pinned) ...[
            SizedBox(width: Ds.space.x8),
            Icon(Icons.push_pin, size: Ds.space.x16, color: Ds.c.brand),
          ],
        ]),
      ),
    );
  }
}
