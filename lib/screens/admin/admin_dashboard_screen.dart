import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
import '../../services/ui_copy.dart';
import 'admin_ops_board_screen.dart';
import 'command_palette.dart';   // CHANGE #325
import 'nav_registry_view.dart'; // CHANGE #325
import 'dev_queue/dev_queue_screen.dart'; // CHANGE #349 — openDevTool
import 'admin_customer_360_screen.dart';  // CHANGE #396
import 'admin_stock_on_hand_screen.dart'; // CHANGE #396

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  int _pendingBills = 0;
  int _totalMedicines = 0;
  bool _loading = true;

  // CHANGE #325 — the whole nav, from nav_registry(). Sections, labels, icons,
  // order, live counts and the role composition all arrive here; this screen
  // renders them and nothing else.
  Map<String, dynamic> _nav = const {};

  // #58 — the stuck board's headline, read straight from admin_ops_board().
  // Six counts with no age could never get worse by being ignored; this one
  // does, so it sits FIRST on the admin home and carries its own wording.
  Map<String, dynamic> _ops = const {};

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadNav();
    _loadOpsBoard();
  }

  Future<void> _loadStats() async {
    try {
      // CHANGE #594 — six separate .count() queries became one RPC.
      final raw = await Supabase.instance.client.rpc('admin_dashboard_counts');
      final c = (raw is List ? raw.first : raw) as Map;
      int n(String k) => (c[k] as num?)?.toInt() ?? 0;
      if (mounted) {
        setState(() {
          _totalMedicines = n('medicines');
          _pendingBills   = n('pending_bills');
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

  /// CHANGE #325 (spec 5) — the dead-feature report. Sits under the feature
  /// list because that is the question it answers about the list above it.
  Future<void> _openUnusedReport() async {
    Map<String, dynamic> report = const {};
    try {
      final raw = await Supabase.instance.client.rpc('nav_unused_report');
      report = Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);
    } catch (_) {
      return;
    }
    if (!mounted) return;
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
            color: _pendingBills > 0 ? const Color(0xFFDC2626) : const Color(0xFF6B7280),
          ),
          _StatCard(
            label: c('admin_dashboard.stat_medicines'),
            value: '$_totalMedicines',
            icon: Icons.medication_outlined,
            color: const Color(0xFF1B7A43),
          ),
        ]),
      ],
    );
  }

  static Widget _sectionLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: Color(0xFF9CA3AF),
            letterSpacing: 1.0,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final isNarrow = box.maxWidth < 600;
      final hpad = isNarrow ? 16.0 : 28.0;

      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(hpad, 24, hpad, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Builder(builder: (_) {
              RenderLog.write('titles_removed_dashboard', 'true');
              return const SizedBox(height: 8);
            }),

            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: CircularProgressIndicator(
                      color: Color(0xFF1B7A43), strokeWidth: 2.5),
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // CHANGE #545 — THE admin date filter. One picker, here,
                  // directly above ORDER HOURS; every date-scoped tab follows
                  // it via AdminDateScope. No tab has one of its own.
                  //
                  // CHANGE #609 — the zone filter sits immediately beside it,
                  // same treatment, and follows the same rule: the selection is
                  // server-side state, so the tabs read it by refetching their
                  // own RPC, not by being handed a zone. AdminZonePicker
                  // renders nothing at all when zone_picker() says show:false,
                  // so the Wrap collapses to just the date control.
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: const [
                        AdminDatePicker(bare: true),
                        AdminZonePicker(),
                      ],
                    ),
                  ),
                  // CHANGE #325 — the command palette. One search box above
                  // everything else: it jumps to any screen, order, customer,
                  // supplier or medicine, so nothing needs to be hunted for.
                  _PaletteButton(
                      label: _label('search_button'), onTap: _openPalette),
                  SizedBox(height: Ds.space.x16),
                  // #58 — "what is stuck right now", first thing on the
                  // admin home and one tap from the full board.
                  if (_ops.isNotEmpty) _OpsBoardCard(payload: _ops),
                  const OrderHoursCard(),
                  const NotificationsCard(),
                  _sectionLabel(_label('action_required')),
                  _buildActionRequired(),
                  const SizedBox(height: 28),
                  _sectionLabel(c('admin_dashboard.section_overview')),
                  _buildOverview(),
                  const SizedBox(height: 28),
                  _sectionLabel(_label('all_features')),
                  // CHANGE #325 — "Quick Navigation" was eight hand-written
                  // tiles while thirty features hid in the profile dropdown.
                  // It is now every registered feature, categorised, ordered
                  // and role-composed by the backend.
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
              ),
          ],
        ),
      );
    });
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
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF3F4F6)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 22, color: color),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value,
              style: const TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
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






// ── CHANGE #325: the command-palette entry point ─────────────────────────────

class _PaletteButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PaletteButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c325_palette_button', 1);
    return InkWell(
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
          Icon(Icons.search, size: Ds.space.x24, color: Ds.c.textSecondary),
          SizedBox(width: Ds.space.x12),
          Expanded(child: Text(label, style: Ds.t.bodySecondary)),
        ]),
      ),
    );
  }
}
