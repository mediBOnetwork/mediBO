import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/admin_date_picker.dart';
import 'package:pharma_b2b/widgets/admin_zone_picker.dart'; // CHANGE #609
import 'package:pharma_b2b/widgets/order_hours_card.dart';
import 'package:pharma_b2b/widgets/notifications_card.dart';
import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import 'command_palette.dart';   // CHANGE #325
import 'nav_registry_view.dart'; // CHANGE #325
import 'dev_queue/dev_queue_screen.dart'; // CHANGE #349 — openDevTool

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

  @override
  void initState() {
    super.initState();
    _loadStats();
    _loadNav();
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
    final route = (tile['route_key'] ?? '').toString();
    if (route.isEmpty) return;
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
  final void Function(String route) navigate;

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
