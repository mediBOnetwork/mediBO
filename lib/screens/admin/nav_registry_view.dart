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
/// in Postgres: an IconData is a font codepoint, not a string.
///
/// CHANGE #349 — it is a MAP now, not a switch, because the switch had no way
/// to answer the only question that mattered: *does this key resolve?* It
/// always returned something, so a registry row naming a key nobody had
/// implemented drew `Icons.widgets_outlined` on a pale tinted square — which
/// is exactly what Om reported as "an empty pale square" across most of the
/// dashboard. A map can be asked, and [navIconResolves] asks it.
///
/// The keys here are mirrored by the `ui_icon` table. `nav_icon_audit()` +
/// the `nav_icons_resolve` regression-guard behaviour fail the BUILD if the
/// registry names a key the catalogue does not hold, and
/// `test/protected/nav_icon_resolve_test.dart` fails if this map and the
/// catalogue drift apart. Neither side can move alone.
const Map<String, IconData> kNavIcons = <String, IconData>{
  'truck':            Icons.local_shipping_outlined,
  'alert':            Icons.notifications_active_outlined,
  'task':             Icons.task_alt_outlined,
  'qr':               Icons.qr_code_2,
  'autorenew':        Icons.autorenew,
  'people':           Icons.people_outline,
  'inventory':        Icons.inventory_2_outlined,
  'person_add':       Icons.person_add_outlined,
  'add_business':     Icons.add_business_outlined,
  'badge':            Icons.badge_outlined,
  'business':         Icons.business_outlined,
  'link_off':         Icons.link_off,
  'person_remove':    Icons.person_remove_outlined,
  'medication':       Icons.medication_outlined,
  'rupee':            Icons.currency_rupee,
  'percent':          Icons.percent,
  'stars':            Icons.stars_outlined,
  'moped':            Icons.delivery_dining_outlined,
  'route':            Icons.alt_route,
  'forum':            Icons.forum_outlined,
  'description':      Icons.description_outlined,
  'campaign':         Icons.campaign_outlined,
  'filter':           Icons.filter_alt_outlined,
  'timeline':         Icons.timeline_outlined,
  'settings_suggest': Icons.settings_suggest_outlined,
  'fact_check':       Icons.fact_check_outlined,
  'notifications':    Icons.notifications_outlined,
  'phonelink_ring':   Icons.phonelink_ring_outlined,
  'payments':         Icons.payments_outlined,
  'receipt':          Icons.receipt_long_outlined,
  'account_balance':  Icons.account_balance_outlined,
  'trending_up':      Icons.trending_up,
  'handshake':        Icons.handshake_outlined,
  'admin_panel':      Icons.admin_panel_settings_outlined,
  'terminal':         Icons.terminal,
  'rule':             Icons.rule_outlined,
  'rule_folder':      Icons.rule_folder_outlined,
  'schedule':         Icons.schedule_outlined,
  'person':           Icons.person_outline,
  'logout':           Icons.logout,
  'book':             Icons.menu_book_outlined,
  'settings':         Icons.settings_outlined,
  'search':           Icons.search,
  'wallet':           Icons.account_balance_wallet_outlined,
  'store':            Icons.storefront_outlined,
  'bag':              Icons.shopping_bag_outlined,
  'package':          Icons.inventory_outlined,
  // CHANGE #349 — the Dev Queue tools, now registry rows like everything else.
  'bug':              Icons.bug_report_outlined,
  'map':              Icons.map_outlined,
  'key':              Icons.vpn_key_outlined,
  'cloud':            Icons.cloud_outlined,
  'memory':           Icons.memory_outlined,
  'shop':             Icons.shop_outlined,
  'drafts':           Icons.drafts_outlined,
  'build':            Icons.build_outlined,
  'science':          Icons.science_outlined,
  'history':          Icons.history,
  'dashboard':        Icons.dashboard_outlined,
  'tools':            Icons.handyman_outlined,
};

/// Does the backend's key name a glyph this build can actually draw?
bool navIconResolves(String? key) =>
    key != null && key.isNotEmpty && kNavIcons.containsKey(key);

/// The glyph for [key]. Unknown keys still return something so nothing throws
/// — but prefer [NavGlyph], which shows the feature's own initial instead of a
/// meaningless generic square when the key does not resolve.
IconData navIcon(String? key) =>
    kNavIcons[key ?? ''] ?? Icons.widgets_outlined;

/// The fallback initial for a payload row.
///
/// The backend composes `icon_letter` (it is a display string, so it is SQL's
/// job). This only slices the row's own `label` when an older payload has no
/// icon_letter — it never invents a word.
String navIconLetter(Map<String, dynamic> row) {
  final given = (row['icon_letter'] ?? '').toString().trim();
  if (given.isNotEmpty) return given.characters.first.toUpperCase();
  final label = (row['label'] ?? row['title'] ?? '').toString().trim();
  if (label.isEmpty) return '?';
  return label.characters.first.toUpperCase();
}

/// CHANGE #349 — the ONE place a nav glyph is drawn.
///
/// It exists because a tinted square with nothing in it is the worst possible
/// answer to "which feature is this?", and it was the answer most of the
/// dashboard gave. Now: a resolvable key draws its icon; anything else draws
/// the feature's own initial, at the same size, in the same square. Both are
/// legible; neither is blank. The box is explicitly `Alignment.center`, so the
/// glyph is laid out loose and centred rather than squeezed by the box's own
/// tight constraints.
class NavGlyph extends StatelessWidget {
  final Map<String, dynamic> row;
  final double box;
  final double glyph;
  final Color? color;
  final Color? background;

  const NavGlyph({
    super.key,
    required this.row,
    required this.box,
    required this.glyph,
    this.color,
    this.background,
  });

  @override
  Widget build(BuildContext context) {
    final key = (row['icon_key'] ?? '').toString();
    final fg = color ?? Ds.c.brand;
    final resolved = navIconResolves(key);
    return Container(
      width: box,
      height: box,
      alignment: Alignment.center,
      decoration: background == null
          ? null
          : BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(Ds.r.button),
            ),
      child: resolved
          ? Icon(kNavIcons[key], size: glyph, color: fg)
          : Text(navIconLetter(row),
              style: Ds.t.bodyStrong.copyWith(fontSize: glyph, color: fg)),
    );
  }
}

/// CHANGE #325 — the two identity rows the profile dropdown may hold, cached
/// for the whole app.
///
/// The dropdown is drawn in four places across two viewports, none of which
/// own a Supabase call. Rather than plumb the payload down four widget layers,
/// the shell loads `nav_registry().profile_menu` once at boot and parks it
/// here. It is a RENDER CACHE, never an authority: the backend decides what
/// may appear on that surface (a CHECK constraint rejects surface='profile'
/// for anything but identity), and an empty list simply draws no rows.
class NavProfileMenu {
  NavProfileMenu._();

  static final ValueNotifier<List<Map<String, dynamic>>> items =
      ValueNotifier<List<Map<String, dynamic>>>(
          const <Map<String, dynamic>>[]);

  /// Adopt the rows from a `nav_registry()` payload. Anything unparseable
  /// leaves the previous rows alone rather than blanking the menu.
  static void adopt(Object? payload) {
    if (payload is! Map) return;
    final raw = payload['profile_menu'];
    if (raw is! List) return;
    items.value = raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
    // CHANGE #325 — live proof for the ONE surface whose claim would otherwise
    // rest on source-reading alone. The paint-time key (c325_profile_menu_rows)
    // only fires when someone opens the sheet, and a headless verifier cannot
    // tap a canvas app — so it never appears in the render-log. This fires at
    // BOOT and asserts a different, honest thing: the payload arrived and the
    // backend admitted exactly N rows onto the profile surface. Two is the
    // number the CHECK constraint permits; anything else means the gate moved.
    RenderLog.write('c325_profile_menu_loaded', items.value.length);
    _writeIconProof(payload);
  }

  /// CHANGE #349 — boot-time proof for the dashboard defect.
  ///
  /// The tiles themselves paint on a canvas a headless verifier cannot read,
  /// and their paint-time keys only fire once someone has the dashboard open.
  /// This runs on the SAME payload at boot and asserts the honest thing: how
  /// many tiles arrived, and how many of them name an icon this build cannot
  /// draw. `unresolved=0` is the fix; anything else is the bug still live.
  static void _writeIconProof(Map payload) {
    var tiles = 0;
    var unresolved = 0;
    void count(Object? rows) {
      if (rows is! List) return;
      for (final r in rows.whereType<Map>()) {
        tiles++;
        if (!navIconResolves((r['icon_key'] ?? '').toString())) unresolved++;
      }
    }

    for (final section in (payload['sections'] as List? ?? const [])
        .whereType<Map>()) {
      count(section['items']);
    }
    count(payload['action_tiles']);
    count(payload['pinned']);
    RenderLog.write('c349_nav_icons', 'tiles=$tiles unresolved=$unresolved');
  }
}

/// CHANGE #325 — DEEP LINKS (spec 6). `/admin/go/<route_key>` is parked here
/// by main.dart's route resolver and consumed by the shell on its first frame.
///
/// It exists because the two halves of a deep link live in different places:
/// main.dart knows the URL but owns no route table, and the shell owns the
/// route table but never sees the URL. One nullable string, read exactly once,
/// is the whole handshake — and it means every registered screen has a real
/// address that a push notification or a WhatsApp button can point at.
class PendingAdminNav {
  PendingAdminNav._();

  static String? route;

  /// CMD #421 — the SUBJECT the route carries, when it has one. A customer 360
  /// link is `/admin/go/customer_360/<pharmacy id>`, and the id is the whole
  /// point of the link: a route key on its own opens a screen that has nothing
  /// to show. It is the same `seed` nav_search puts on a palette result, kept
  /// beside the route rather than smuggled into it, so a route key stays a
  /// route key and nothing has to parse one back apart.
  static String? seed;

  /// Read-and-clear: a deep link fires once, never again on the next rebuild.
  ///
  /// This clears the ROUTE only. The shell parks a link straight back when the
  /// account is not allowed to open it yet ("not ours to open"), and a subject
  /// that was dropped on that first pass could never be recovered — the URL is
  /// long gone by then. The subject is cleared by [takeSeed], which the shell
  /// calls only when it is actually opening the screen.
  static String? take() {
    final r = route;
    route = null;
    return r;
  }

  /// Read-and-clear the subject. Call it at the moment the screen opens.
  static String? takeSeed() {
    final s = seed;
    seed = null;
    return s;
  }

  /// Park a link. [seedValue] is optional because most routes are a whole
  /// destination by themselves; an empty string parks nothing rather than a
  /// subject made of no characters.
  static void park(String routeKey, [String? seedValue]) {
    route = routeKey;
    seed = (seedValue == null || seedValue.isEmpty) ? null : seedValue;
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
              NavGlyph(
                row: tile,
                box: Ds.space.x32 + Ds.space.x4,
                glyph: Ds.space.x16 + Ds.space.x4,
                background: Ds.c.brandSoft,
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
            row: const <String, dynamic>{'icon_key': 'task', 'label': 'Pinned'},
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
                  row: section,
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
  final Map<String, dynamic> row;
  final bool collapsed;
  final VoidCallback? onTap;

  const _SectionHeader({
    required this.label,
    required this.row,
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
          NavGlyph(
              row: row,
              box: Ds.space.x16 + Ds.space.x4,
              glyph: Ds.space.x16 + Ds.space.x4,
              color: Ds.c.textSecondary),
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

/// CHANGE #325 (spec 5) — "a monthly report of features nobody opened".
///
/// `nav_unused_report()` counts opens over its own window and names every
/// registered feature with zero. This is the surface that makes it readable:
/// the title, the window label, every row's note and the all-clear line are
/// the backend's, so the report can change its window or its wording without
/// a deploy.
class NavUnusedReportSheet extends StatelessWidget {
  final Map<String, dynamic> report;

  const NavUnusedReportSheet({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final items = (report['items'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList() ??
        const <Map<String, dynamic>>[];
    RenderLog.write('c325_unused_report', items.length);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x4),
              child: Text(_s(report, 'title'), style: Ds.t.title),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              child: Text(_s(report, 'window_label'), style: Ds.t.caption),
            ),
            SizedBox(height: Ds.space.x16),
            if (items.isEmpty)
              Padding(
                padding: EdgeInsets.all(Ds.space.x16),
                child: Text(_s(report, 'empty_label'), style: Ds.t.caption),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(bottom: Ds.space.x24),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final row = items[i];
                    return Container(
                      constraints: BoxConstraints(minHeight: Ds.space.x48),
                      padding: EdgeInsets.symmetric(
                          horizontal: Ds.space.x16, vertical: Ds.space.x8),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_s(row, 'label'), style: Ds.t.body),
                              Text(_s(row, 'category'), style: Ds.t.caption),
                            ],
                          ),
                        ),
                        Text(_s(row, 'note'), style: Ds.t.caption),
                      ]),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
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
    final icon = NavGlyph(
        row: tile,
        box: Ds.space.x16 + Ds.space.x4,
        glyph: Ds.space.x16 + Ds.space.x4);
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
            alignment: Alignment.center,
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
