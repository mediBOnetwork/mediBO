import 'dart:async'; // CHANGE #813 — the 30-second refresh cadence

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart'; // CHANGE #813 — WhatsApp share

import '../pharmacy/khata_screen.dart'; // CMD #415 — the khata book
import '../pharmacy/pharmacy_refill_screen.dart'; // CMD #417 — refills & counter
import '../pharmacy/pharmacy_variance_screen.dart';
import '../pharmacy/rx_scan_screen.dart'; // CMD #418
import '../pharmacy/pharmacy_parcel_count_screen.dart'; // CMD #431
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/admin_date_picker.dart';
import 'package:pharma_b2b/widgets/admin_zone_picker.dart'; // CHANGE #609
import 'package:pharma_b2b/widgets/order_hours_card.dart';
import 'package:pharma_b2b/widgets/notifications_card.dart';
import '../../design_tokens.dart';
import '../../models/c529_admin_gaps.dart';
import '../../widgets/crashes_card.dart'; // CHANGE #473
import '../../widgets/dashboard_v2_card.dart'; // CHANGE #812
import '../../services/ui_copy.dart';
import '../../services/staff_nav.dart'; // CHANGE #1016 — the layout flag
import 'admin_ops_board_screen.dart';
import 'command_palette.dart';   // CHANGE #325
import 'nav_registry_view.dart'; // CHANGE #325
import 'dev_queue/dev_queue_screen.dart'; // CHANGE #349 — openDevTool
import 'admin_customer_360_screen.dart';  // CHANGE #396
import 'admin_stock_on_hand_screen.dart'; // CHANGE #396
import 'admin_support_inbox_screen.dart'; // CMD #452 — feature_gaps #132

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  int _pendingBills = 0;
  // CHANGE #529 gap 21 — a bill that resolves to no supplier can never be
  // zoned, so a zone-scoped admin never counted it. It is its own bucket now,
  // and its wording is the BACKEND's (never a Dart string).
  UnresolvedBillsTile _unresolved = const UnresolvedBillsTile(count: 0, label: '');
  bool _loading = true;

  // CHANGE #325 — the whole nav, from nav_registry(). Sections, labels, icons,
  // order, live counts and the role composition all arrive here; this screen
  // renders them and nothing else.
  Map<String, dynamic> _nav = const {};

  // #58 — the stuck board's headline, read straight from admin_ops_board().
  // Six counts with no age could never get worse by being ignored; this one
  // does, so it sits FIRST on the admin home and carries its own wording.
  Map<String, dynamic> _ops = const {};

  // CHANGE #812 — the whole dashboard head in ONE payload: today's strip with
  // deltas and 7-day sparklines, the needs-you queue, the stage funnel, the
  // promised ring, alerts, quick actions and (super admin) the zone cards.
  // Every string, number and tone in it is the backend's.
  Map<String, dynamic> _dash = const {};

  // CHANGE #813 — the dashboard refreshes itself on the BACKEND's cadence
  // (`refresh_ms`), and the header prints the payload's own "Updated 12:41"
  // stamp so a stale screen is visible rather than silent.
  Timer? _refresh;
  int _refreshMs = 0;

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadNav();
    _loadOpsBoard();
    _loadDashboard();
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  /// Restart the timer only when the cadence itself changed, so a refresh
  /// never resets its own clock.
  void _armRefresh(int ms) {
    if (ms <= 0 || ms == _refreshMs) return;
    _refreshMs = ms;
    _refresh?.cancel();
    _refresh = Timer.periodic(
        Duration(milliseconds: ms), (_) => _loadDashboard());
  }

  /// CHANGE #813 — a long press on a number opens the backend's own WhatsApp
  /// share link. The sentence and the URL are both in the payload; nothing is
  /// composed here.
  Future<void> _shareMetric(Map<String, dynamic> share) async {
    final url = (share['url'] ?? '').toString();
    if (url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      // A blocked pop-up leaves the dashboard exactly as it was.
    }
  }

  /// CHANGE #812 — dashboard_v2(). A failure leaves the rest of the home
  /// intact: the card simply does not appear.
  Future<void> _loadDashboard() async {
    try {
      final raw = await Supabase.instance.client.rpc('dashboard_v2');
      final m = (raw is List ? raw.first : raw);
      if (mounted && m is Map) {
        setState(() => _dash = Map<String, dynamic>.from(m));
        _armRefresh((m['refresh_ms'] as num?)?.toInt() ?? 0);
      }
    } catch (_) {
      // No card rather than a broken one.
    }
  }

  /// CHANGE #812 — one of needs_you's own {rpc, args} actions, run verbatim.
  /// The wording of whatever comes back is the backend's too.
  Future<void> _runDashboardAction(Map<String, dynamic> action) async {
    final fn = (action['rpc'] ?? '').toString();
    if (fn.isEmpty) return;
    final args = (action['args'] is Map)
        ? Map<String, dynamic>.from(action['args'] as Map)
        : const <String, dynamic>{};
    try {
      final raw = await Supabase.instance.client.rpc(fn, params: args);
      final m = (raw is List ? raw.first : raw);
      final message =
          (m is Map ? (m['message'] ?? m['toast'] ?? '') : '').toString();
      if (mounted && message.isNotEmpty) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      // The row stays as it was; the next refresh is the truth.
    }
    await _loadDashboard();
  }

  /// CHANGE #812 — universal_search(): order code, phone, pharmacy, supplier,
  /// product. A superset of the palette's screen jumping, so the box on the
  /// dashboard finds the THING you are holding.
  Future<Map<String, dynamic>> _universalSearch(String query) async {
    final raw = await Supabase.instance.client
        .rpc('universal_search', params: {'p_q': query});
    return Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
  }

  Future<void> _loadStats() async {
    try {
      // CHANGE #594 — six separate .count() queries became one RPC.
      final raw = await Supabase.instance.client.rpc('admin_dashboard_counts');
      final c = (raw is List ? raw.first : raw) as Map;
      int n(String k) => (c[k] as num?)?.toInt() ?? 0;
      if (mounted) {
        setState(() {
          _pendingBills   = n('pending_bills');
          _unresolved     = UnresolvedBillsTile.from(Map<String, dynamic>.from(c));
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// CHANGE #325 — one call for the entire dashboard nav.
  Future<void> _loadNav() async {
    try {
      final raw = await Supabase.instance.client.rpc('nav_registry');
      final map = Map<String, dynamic>.from(
          (raw is List ? raw.first : raw) as Map);
      if (mounted) setState(() => _nav = map);
    } catch (_) {
      // A failed nav call leaves the previous payload on screen rather than
      // blanking the dashboard — the offline rule: the cache is a render
      // fallback, never an authority.
    }
  }

  List<Map<String, dynamic>> _list(String key) =>
      (_nav[key] as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const <Map<String, dynamic>>[];

  String _label(String key) =>
      ((_nav['labels'] as Map?)?[key] ?? '').toString();

  /// Every open goes through nav_open() first: it is the usage log that ranks
  /// tiles, and it is the HARD GATE at the door — a screen that is not in the
  /// registry cannot be opened through it.
  void _openTile(Map<String, dynamic> tile) {
    final featureKey = (tile['feature_key'] ?? '').toString();
    if (featureKey.isNotEmpty) {
      Supabase.instance.client
          .rpc('nav_open', params: {'p_feature_key': featureKey})
          .catchError((_) => null);
    }
    // CHANGE #349 — a Dev Queue tool is a registry row now, so the palette
    // finds it by name like any screen. It does not go through the shell's
    // route table: these tools are pushed directly, which is also why the
    // palette can reach them without the Dev Queue screen being open.
    final toolKey = (tile['tool_key'] ?? '').toString();
    if (toolKey.isNotEmpty) {
      if (!openDevTool(context, toolKey)) {
        final message = c('dev_tools.not_registered');
        if (message.isNotEmpty) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text(message)));
        }
      }
      return;
    }
    // CHANGE #395 — a registry row may name a REAL named route instead of a
    // shell route key. `_handleAdminNav`'s switch has no default branch, so a
    // key it has never heard of renders a perfect tile that does nothing on
    // tap — the #645/#646 bug, and the reason every new screen used to need an
    // edit in home_shell.dart before its tile worked. A deep_link that is an
    // ordinary path is pushed straight onto the navigator, so registering a
    // screen that already has a route in main.dart is now a pure INSERT.
    //
    // `/admin/go/<key>` is excluded on purpose: that form is the shell's own
    // parking route and must keep going through the switch.
    final deep = (tile['deep_link'] ?? '').toString();
    if (deep.startsWith('/') && !deep.startsWith('/admin/go/')) {
      Navigator.of(context).pushNamed(deep);
      return;
    }
    final route = (tile['route_key'] ?? '').toString();
    if (route.isEmpty) return;
    // CHANGE #396 — the two screens that carry a subject with them. Like a Dev
    // Queue tool they are PUSHED rather than swapped into the shell's tab
    // table, because the palette hands the subject down in `seed` (a customer
    // id) and a tab index cannot carry one.
    if (route == 'customer_360') {
      final seed = (tile['seed'] ?? '').toString();
      if (seed.isEmpty) {
        // No subject: the registry tile itself. Ask for one the way the rest
        // of the app does — through the palette.
        _openPalette();
        return;
      }
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => AdminCustomer360Screen(customerId: seed)));
      return;
    }
    if (route == 'stock_on_hand') {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const AdminStockOnHandScreen()));
      return;
    }
    // CMD #413 — the two pharmacy shop-management screens. Pushed rather than
    // swapped into the shell's tab table for the same reason as the two above:
    // they are a pharmacy's own surfaces reached from the admin console, not
    // admin tabs. Who may actually see what inside them is the backend's
    // answer — pharmacy_expiry_home() and pharmacy_variance_report() each
    // refuse in their own words, and the screen renders that refusal.
    {
      final shield = PharmacyShieldTiles.screenFor(route);
      if (shield != null) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => shield));
        return;
      }
    }
    // CMD #415 — the pharmacy's khata book. Pushed rather than swapped into the
    // shell's tab table for the same reason as the pharmacy screens above: it
    // is a shop's own ledger reached from the admin console, not an admin tab.
    // khata_home() gates on the caller's own pharmacy and renders its own
    // refusal, so there is no role test here.
    if (route == 'khata') {
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const KhataScreen()));
      return;
    }
    // CMD #417 — the refill console (reminders, storefront, AI counter).
    // Same push, same reason as the khata book above: refill_home() gates on
    // the caller's own pharmacy and renders its own refusal.
    if (route == 'refill') {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const PharmacyRefillScreen()));
      return;
    }
    // CMD #431 — counting an arrived parcel against its bill. Same push, same
    // reason: pharmacy_parcel_home() resolves the caller's own pharmacy and
    // refuses in its own words, so there is no role test here either.
    if (route == 'pharmacy_parcel') {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const ParcelCountHomeScreen()));
      return;
    }
    // CMD #452 — the customer support inbox (feature_gaps #132). Pushed, not
    // swapped into the shell's tab table, for the same reason as the screens
    // above: support_inbox() refuses a non-admin in its own words and the
    // screen renders that refusal, so there is no role test here.
    if (route == 'support_inbox') {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const AdminSupportInboxScreen()));
      return;
    }
    // CMD #418 — the prescription scanner, same push, same reason.
    if (route == 'rx_scan') {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const RxScanScreen()));
      return;
    }
    QuickLinkNavigator.of(context)?.navigate(route);
  }

  Future<Map<String, dynamic>> _togglePin(String featureKey) async {
    try {
      final raw = await Supabase.instance.client
          .rpc('nav_pin_toggle', params: {'p_feature_key': featureKey});
      final map = Map<String, dynamic>.from(
          (raw is List ? raw.first : raw) as Map);
      await _loadNav();
      return map;
    } catch (_) {
      return const <String, dynamic>{};
    }
  }

  Future<Map<String, dynamic>> _search(String query) async {
    final raw = await Supabase.instance.client
        .rpc('nav_search', params: {'p_q': query});
    return Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
  }

  /// CHANGE #812 — the entity search, its own sheet. The palette above stays
  /// the SCREEN jumper (it leads with features and Dev Queue tools); this one
  /// is the order code / phone / pharmacy / supplier / product box, and it is
  /// the one a partner can open too.
  void _openUniversalSearch() {
    showUniversalSearch(
      context,
      search: _universalSearch,
      onPick: _openTile,
      placeholder: c('usearch.placeholder'),
    );
  }

  /// CHANGE #325 (spec 5) — the dead-feature report. Sits under the feature
  /// list because that is the question it answers about the list above it.
  /// CHANGE #1016 — under the v2 layout it is offered at the foot of the More
  /// grid instead ([openUnusedReport]); the sheet and its RPC are unchanged.
  Future<void> _openUnusedReport() => openUnusedReport(context);

  static Future<void> openUnusedReport(BuildContext context) async {
    Map<String, dynamic> report = const {};
    try {
      final raw = await Supabase.instance.client.rpc('nav_unused_report');
      report = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
    } catch (_) {
      return;
    }
    if (!context.mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (_) => NavUnusedReportSheet(report: report),
    );
  }

  void _openPalette() {
    showCommandPalette(
      context,
      search: _search,
      onPick: _openTile,
      hint: _label('search_hint'),
      title: _label('search_title'),
    );
  }

  /// CHANGE #325 — action-first tiles. The list, the counts and the phrase
  /// under each number ("10 bills to review") are all `nav_registry()`'s
  /// `action_tiles`; there is no hand-written card here any more, and a tile
  /// only exists while its badge_source has something to answer.
  /// The board is a separate read so a slow scan never delays the counts, and
  /// a failure leaves the rest of the home intact — the card simply does not
  /// appear. Nothing here is computed: the RPC hands over every string.
  Future<void> _loadOpsBoard() async {
    try {
      final raw = await Supabase.instance.client
          .rpc('admin_ops_board', params: {'p_top': 0});
      final m = (raw is List ? raw.first : raw);
      if (mounted && m is Map && m['ok'] == true) {
        setState(() => _ops = Map<String, dynamic>.from(m));
      }
    } catch (_) {
      // No card rather than a broken one.
    }
  }

  Widget _buildActionRequired() {
    return NavActionTiles(
      tiles: _list('action_tiles'),
      emptyLabel: _label('empty_actions'),
      onOpen: _openTile,
    );
  }

  Widget _buildOverview() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(spacing: 16, runSpacing: 16, children: [
          _StatCard(
            label: c('admin_dashboard.stat_pending_bills'),
            value: '$_pendingBills',
            icon: Icons.inbox_outlined,
            color: _pendingBills > 0 ? Ds.c.danger : Ds.c.textSecondary,
          ),
          if (_unresolved.show)
            _StatCard(
              label: _unresolved.label,
              value: '${_unresolved.count}',
              icon: Icons.link_off_outlined,
              color: Ds.c.warning,
            ),
          // CHANGE #812 — the static medicines tile is gone. A catalogue size
          // that changes once a week was never a thing to DO, and it cost a
          // count(*) over 563k rows on every admin home load.
        ]),
      ],
    );
  }

  // CHANGE #813 — tokens, not literals: a dark palette is an `ui_design_set`
  // patch (CHANGE #66), and it can only reach a screen that holds no colours
  // of its own.
  static Widget _sectionLabel(String text) => Padding(
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

  @override
  Widget build(BuildContext context) {
    // CHANGE #1016 — the dashboard is the SEE tab: today's strip, needs-you,
    // the funnel, the alerts and the universal search. Every registry entry
    // that used to sit under them (the categorised feature grid, the action
    // tiles, the overview counts, the unused-feature report) has a home of its
    // own now — Customers / Suppliers / Fulfill / Money / More — and is drawn
    // there by staff_home(). The old body stays reachable behind the
    // staff_layout_v1 app_settings flag for seven days; which layout to draw
    // is staff_nav().layout, never a Dart rule.
    return ValueListenableBuilder<StaffNavPayload>(
      valueListenable: StaffNav.value,
      builder: (_, nav, _) => _buildBody(context, legacy: nav.isLegacy),
    );
  }

  Widget _buildBody(BuildContext context, {required bool legacy}) {
    RenderLog.write('c1016_dashboard_layout', legacy ? 'v1' : 'v2');
    return LayoutBuilder(builder: (ctx, box) {
      final isNarrow = box.maxWidth < 600;
      final hpad = isNarrow ? 16.0 : Ds.space.x24;
      final header = (_dash['header'] is Map)
          ? Map<String, dynamic>.from(_dash['header'] as Map)
          : const <String, dynamic>{};

      // CHANGE #813 — ONE sticky header: it says when and where you are
      // ("Today · Raipur Zone"), it carries the date and zone pickers — the
      // only copy of them in the console — and it collapses to a single line
      // as the page scrolls. Under it, the universal search bar.
      final slivers = <Widget>[
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickyDashHeader(
            title: (header['title'] ?? '').toString(),
            subLabel: (header['sub_label'] ?? '').toString(),
            updatedLabel: (_dash['updated_label'] ?? '').toString(),
            hpad: hpad,
            onZoneChanged: _loadDashboard,
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(hpad, Ds.space.x16, hpad, Ds.space.x32),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Builder(builder: (_) {
                RenderLog.write('titles_removed_dashboard', 'true');
                return const SizedBox.shrink();
              }),
              // The entity door, full width, directly under the header: order
              // code, phone, pharmacy, supplier or product. Its wording is
              // universal_search()'s own hint, never a Dart literal.
              _SearchBar(
                key: const Key('c813_search_bar'),
                label: (header['search_hint'] ?? '').toString().isNotEmpty
                    ? (header['search_hint'] ?? '').toString()
                    : c('usearch.placeholder'),
                onTap: _openUniversalSearch,
                paletteLabel: _label('search_button'),
                onPalette: _openPalette,
              ),
              SizedBox(height: Ds.space.x24),
              if (_loading && _dash.isEmpty)
                // Loading is a shape, not a spinner.
                const DashboardV2Skeleton()
              else ...[
                DashboardV2Card(
                  payload: _dash,
                  onOpen: _openTile,
                  onAction: _runDashboardAction,
                  onShare: _shareMetric,
                ),
                if (_dash.isNotEmpty) SizedBox(height: Ds.space.x24),
                if (_ops.isNotEmpty) _OpsBoardCard(payload: _ops),
                const OrderHoursCard(),
                const NotificationsCard(),
                const CrashesCard(),
                // CHANGE #1016 — the pre-#1016 body, only while the
                // staff_layout_v1 flag is on. Under v2 these entries live on
                // their own tabs; drawing them here again would be the second
                // surface the change removes.
                if (legacy) ...[
                  _sectionLabel(_label('action_required')),
                  _buildActionRequired(),
                  SizedBox(height: Ds.space.x24),
                  _sectionLabel(c('admin_dashboard.section_overview')),
                  _buildOverview(),
                  SizedBox(height: Ds.space.x24),
                  _sectionLabel(_label('all_features')),
                  NavSections(
                    sections: _list('sections'),
                    pinned: _list('pinned'),
                    pinnedLabel: _label('pinned'),
                    pinHint: _label('pin_hint'),
                    onOpen: _openTile,
                    onPin: _togglePin,
                  ),
                  TextButton.icon(
                    onPressed: _openUnusedReport,
                    icon: const Icon(Icons.insights_outlined),
                    label: Text(_label('unused_report')),
                  ),
                ],
              ],
            ]),
          ),
        ),
      ];

      return CustomScrollView(slivers: slivers);
    });
  }
}

// ── CHANGE #813: the sticky header ───────────────────────────────────────────
//
// "Today · Raipur Zone" is the BACKEND's sentence (dashboard_v2().header.title)
// — this delegate only draws it, and shrinks: at full height it carries the
// date, the zone pickers and the updated stamp; pinned at the top of a scrolled
// page it keeps the title and the pickers, because a filter you cannot see is a
// filter you forget you set.
class _StickyDashHeader extends SliverPersistentHeaderDelegate {
  final String title;
  final String subLabel;
  final String updatedLabel;
  final double hpad;
  final VoidCallback onZoneChanged;

  const _StickyDashHeader({
    required this.title,
    required this.subLabel,
    required this.updatedLabel,
    required this.hpad,
    required this.onZoneChanged,
  });

  // The two extents are measured, not guessed: 12 top pad + a 20px title line
  // + 8 + a 44px picker rail + 8 bottom = 96 collapsed, plus the 4+17 date line
  // = 120 expanded. A sliver header that overflows its own extent paints the
  // yellow stripes, so these are deliberately a few pixels loose.
  @override
  double get maxExtent => 128;

  @override
  double get minExtent => 100;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final t = ((maxExtent - shrinkOffset) / (maxExtent - minExtent))
        .clamp(0.0, 1.0);
    return Material(
      color: Ds.c.bg,
      elevation: shrinkOffset > 0 ? 1 : 0,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            hpad, Ds.space.x12, hpad, Ds.space.x8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(children: [
              Expanded(
                child: Text(title,
                    key: const Key('c813_header_title'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.title),
              ),
              if (updatedLabel.isNotEmpty)
                Text(updatedLabel,
                    key: const Key('c813_updated'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.caption),
            ]),
            // The date line fades out as the header collapses; the pickers
            // never do.
            if (t > 0.35 && subLabel.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Opacity(
                opacity: t,
                child: Text(subLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.caption),
              ),
            ],
            SizedBox(height: Ds.space.x8),
            // A rail, not a Wrap: a second line of chips on a 360px phone
            // would push the header past its own extent. It scrolls sideways
            // instead, and the pickers never leave the header.
            SizedBox(
              height: 44,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const AdminDatePicker(bare: true),
                    SizedBox(width: Ds.space.x8),
                    AdminZonePicker(onChanged: onZoneChanged),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_StickyDashHeader old) =>
      old.title != title ||
      old.subLabel != subLabel ||
      old.updatedLabel != updatedLabel ||
      old.hpad != hpad;
}

// ── CHANGE #813: the one search bar ──────────────────────────────────────────
//
// #812 put the entity search behind a quiet text button so it would not read as
// a second identical box. The spec asks for ONE bar under the header, so this
// is that bar — the entity door — with the screen jumper kept as its trailing
// icon rather than a second full-width control.
class _SearchBar extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final String paletteLabel;
  final VoidCallback onPalette;

  const _SearchBar({
    super.key,
    required this.label,
    required this.onTap,
    required this.paletteLabel,
    required this.onPalette,
  });

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c325_palette_button', 1);
    return Row(children: [
      Expanded(
        child: InkWell(
          key: const Key('c812_search_button'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(Ds.r.button),
          child: Container(
            height: Ds.space.x48,
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            decoration: BoxDecoration(
              color: Ds.c.bg,
              borderRadius: BorderRadius.circular(Ds.r.button),
              border: Border.all(color: Ds.c.divider),
            ),
            child: Row(children: [
              Icon(Icons.search,
                  size: Ds.space.x24, color: Ds.c.textSecondary),
              SizedBox(width: Ds.space.x12),
              Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.bodySecondary)),
            ]),
          ),
        ),
      ),
      SizedBox(width: Ds.space.x8),
      Tooltip(
        message: paletteLabel,
        child: IconButton(
          key: const Key('c813_palette_button'),
          onPressed: onPalette,
          iconSize: Ds.space.x24,
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: Icon(Icons.bolt_outlined, color: Ds.c.textSecondary),
        ),
      ),
    ]);
  }
}

// ── #58 — the stuck-work card ────────────────────────────────────────────────
//
// The register row asked for a worst-first board of every stuck object to BE
// the admin home. This is its head: the backend's own headline, the worst
// queue named, and one tap into AdminOpsBoardScreen for the full list. It reads
// admin_ops_board() with p_top: 0 — the counts, none of the example rows —
// because the home only needs the verdict, and the board screen is where the
// objects live.
//
// Every string is the payload's. There is no count assembled here, no age
// computed here and no ranking decided here.
class _OpsBoardCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _OpsBoardCard({required this.payload});

  @override
  Widget build(BuildContext context) {
    String s(String k) => (payload[k] ?? '').toString();
    final tone = s('headline_tone');
    final ink = switch (tone) {
      'good' => Ds.c.success,
      'warn' => Ds.c.warning,
      'bad' => Ds.c.danger,
      _ => Ds.c.info,
    };
    final wash = switch (tone) {
      'good' => Ds.c.successSoft,
      'warn' => Ds.c.warningSoft,
      'bad' => Ds.c.dangerSoft,
      _ => Ds.c.infoSoft,
    };

    // Boot-time proof (same pattern as #325's profile surface): a string in the
    // bundle only proves the code compiled. This key is written when the card
    // actually paints on the admin home, so render_verify.js can assert the
    // entry point exists on the live build rather than in the source.
    try {
      RenderLog.write('c356_ops_board',
          'headline=${s('headline_label')};classes=${payload['items'] is List ? (payload['items'] as List).length : 0}');
    } catch (_) {}

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: InkWell(
        key: const Key('admin_home_ops_board'),
        borderRadius: Ds.r.rCard,
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AdminOpsBoardScreen(
              onNavigate: (route) =>
                  QuickLinkNavigator.of(context)?.navigate(route),
            ),
          ),
        ),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: wash,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: ink.withValues(alpha: 0.30)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(s('title'), style: Ds.t.subtitle),
                  SizedBox(height: Ds.space.x4),
                  Text(s('headline_label'),
                      key: const Key('admin_home_ops_headline'),
                      style: Ds.t.display.copyWith(color: ink)),
                  SizedBox(height: Ds.space.x4),
                  Text(s('subtitle'), style: Ds.t.caption),
                  if (s('worst_label').isNotEmpty) ...[
                    SizedBox(height: Ds.space.x8),
                    Text(s('worst_label'),
                        style: Ds.t.caption
                            .copyWith(color: ink, fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: ink),
          ]),
        ),
      ),
    );
  }
}

// ── Stat card ─────────────────────────────────────────────────────────────────

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Row(children: [
        Container(
          width: Ds.space.x48,
          height: Ds.space.x48,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: Ds.r.rChip,
          ),
          child: Icon(icon, size: Ds.space.x24, color: color),
        ),
        SizedBox(width: Ds.space.x12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: Ds.t.title),
          SizedBox(height: Ds.space.x4),
          Text(label, style: Ds.t.caption),
        ])),
      ]),
    );
  }
}

// ── Inherited widget — tiles/cards trigger navigation in AdminShell ────────────

class QuickLinkNavigator extends InheritedWidget {
  /// CMD #421 — [seed] is the SUBJECT the route carries, when it has one: the
  /// pharmacy id on a `customer_360` link, the same value nav_search puts on a
  /// palette result. It is optional because most routes are a whole
  /// destination by themselves, and the shell's route table is the one place
  /// that has to know which is which.
  final void Function(String route, [String? seed]) navigate;

  const QuickLinkNavigator({
    super.key,
    required this.navigate,
    required super.child,
  });

  static QuickLinkNavigator? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<QuickLinkNavigator>();

  @override
  bool updateShouldNotify(QuickLinkNavigator old) => false;
}






// CHANGE #813 — _PaletteButton is gone: the screen jumper now lives as the
// trailing icon on the ONE search bar (_SearchBar above), so the dashboard has
// a single search control instead of two stacked boxes.
