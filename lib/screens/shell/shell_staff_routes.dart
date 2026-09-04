// lib/screens/shell/shell_staff_routes.dart — CHANGE #1016
//
// The doors the shared staff shell had been promising and did not have, and
// the four hooks the six-tab layout needs from the shell.
//
// #653 merged the partner into the admin interface and #657 deleted the
// routed Partner page, but the resolver that page used (partnerDestination in
// partner_home_screen.dart) was the ONLY thing that opened seven partner
// screens: My documents, My staff, Workers, Expenses, Supplier payments,
// Returns to supplier and the partner's own settlement statement. Every one
// of them stayed a registry tile — surface_route even declared some of them
// as home_shell doors — and every one fell through the shell's switch into
// "route unavailable". This file is that door.
//
// WHY A SEPARATE FILE. home_shell.dart is capped at 2,000 lines by its own
// guard and shell_extra_routes.dart is the shard other commands are writing
// into today; a second shard costs the shell one four-line lookup and gives
// the partner doors a leasable path of their own. The reachability gate
// (test/protected/admin_nav_reachability_test.dart) reads this file's arms
// exactly as it reads shell_extra_routes.dart's.
//
// Authorisation is NOT here. Each screen's RPCs zone-clamp a partner and
// refuse anyone else in their own words; the door being open to a role decides
// nothing about what that role reads or writes.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/access.dart';
import '../../services/staff_nav.dart';
import '../../utils/render_log.dart';
import '../../widgets/pulse_badge.dart';
import '../admin/admin_dashboard_screen.dart' show AdminDashboardScreen;
import '../admin/admin_nav_entries.dart';
import '../admin/admin_ops_queues_screen.dart';
import '../admin/dev_queue/dev_queue_screen.dart' show openDevTool;
import '../admin/staff_home_screen.dart';
import '../partner/partner_documents_screen.dart';
import '../partner/partner_expense_screen.dart';
import '../partner/partner_home_screen.dart' show PartnerFeaturePage;
import '../partner/partner_returns_screen.dart';
import '../partner/partner_staff_screen.dart';
import '../partner/partner_statement_screen.dart';
import '../partner/partner_supplier_payment_screen.dart';
import '../partner/partner_workers_screen.dart';

/// The page title is the label the ACCESS MATRIX gave the route
/// (`access_boot().routes[<route>].label`) — the registry's own word, so
/// renaming "My staff" is an UPDATE and never a deploy.
String _title(String routeKey) => Access.instance.routeLabel(routeKey);

/// These screens are TAB BODIES — a bounded box, no Scaffold of their own —
/// so each is pushed inside [PartnerFeaturePage], the same frame the retired
/// partner resolver used.
Widget _page(String routeKey, Widget child) =>
    PartnerFeaturePage(title: _title(routeKey), child: child);

Map<String, dynamic> _asMap(Object? raw) =>
    Map<String, dynamic>.from((raw is List ? raw.first : raw) as Map);

/// The screen a route_key opens, or null when this table does not own it.
/// Null means "keep looking": the shell's own switch and its backend-worded
/// default branch stay in charge of an unknown route.
/// The four row actions of Stuck work, each its own RPC (CHANGE #459).
const Map<String, String> _opsQueueActionRpc = {
  'resend': 'admin_oos_resend',
  'close': 'admin_oos_close',
  'rescan': 'admin_pending_rescan',
  'ack': 'admin_alert_ack',
};

Widget? shellStaffRouteScreen(String routeKey) => switch (routeKey) {
      // CHANGE #692 — the partner's own agreement + KYC documents.
      'partner_documents' => const PartnerDocumentsPage(),
      // CHANGE #399 — the partner's own staff, its expenses, its workers.
      'partner_staff' => _page(routeKey, const PartnerStaffScreen()),
      'partner_expenses' => _page(routeKey, const PartnerExpenseScreen()),
      'partner_workers' => _page(routeKey, const PartnerWorkersScreen()),
      // CHANGE #399 — the partner's door onto the supplier payment writer,
      // zone-clamped (partner_sup_record_payment).
      'supplier_payment' => _page(routeKey, const PartnerSupplierPaymentScreen()),
      // CHANGE #710 — stock going back to a supplier and its debit note.
      'supplier_returns' => _page(routeKey, const PartnerReturnsScreen()),
      // CHANGE #323 — the partner's own settlement statement. Its OWN route
      // now: the shared 'settlement' key opens the office console.
      'partner_settlement' => _page(routeKey, const PartnerStatementScreen()),
      // CHANGE #459 — "Stuck work" (Ops queues). Moved here from the shell's
      // switch unchanged: the whole screen is one RPC and the four row actions
      // share one dispatcher. admin_ops_queues() gates itself and the screen
      // renders its refusal.
      'ops_queues' => AdminOpsQueuesScreen(
          loadRpc: () async =>
              _asMap(await Supabase.instance.client.rpc('admin_ops_queues')),
          actionRpc: (action, id) async {
            // A map, not a switch: the reachability gate reads every
            // quoted-key arrow in this file as a route arm, and these are actions.
            final fn = _opsQueueActionRpc[action];
            if (fn == null) return const <String, dynamic>{'ok': false};
            final params = <String, dynamic>{
              'p_id': action == 'rescan' ? id : int.tryParse(id),
            };
            return _asMap(
                await Supabase.instance.client.rpc(fn, params: params));
          },
        ),
      _ => null,
    };

// ─── the six-tab layout's hooks into the shell ──────────────────────────────

/// An old route key lands on its new home. The map is `staff_nav().redirects`
/// — data — so the next merged screen needs no Dart. A link that carries a
/// subject keeps its route when the redirect is `when_no_seed`.
String shellResolveStaffRoute(String route, String? seed) {
  final resolved = StaffNav.value.value
      .resolve(route, hasSeed: (seed ?? '').trim().isNotEmpty);
  if (resolved != route) RenderLog.write('c1016_redirect', '$route>$resolved');
  return resolved;
}

/// The bar entries: `staff_nav().tabs` under the v2 layout, the pre-#1016
/// list while the `staff_layout_v1` flag is on — and, until staff_nav() has
/// answered at all, the same old list, so a slow boot never blanks the bar.
List<AdminNavEntry> shellStaffBarEntries(List<AdminNavEntry> legacy) {
  final nav = StaffNav.value.value;
  if (!nav.ok || nav.isLegacy) return legacy;
  final entries = staffNavEntries(nav);
  return entries.isEmpty ? legacy : entries;
}

/// `staff_home(tab)`.
Future<Map<String, dynamic>> shellStaffHomeLoad(String tab) async =>
    _asMap(await Supabase.instance.client
        .rpc('staff_home', params: {'p_tab': tab}));

/// A tapped tile, opened exactly as the dashboard registry opens one: the
/// usage log first (nav_open is also the hard gate at the door), a Dev Queue
/// tool by its tool_key, a plain named route by its deep link, everything
/// else through the shell's own route table with the tile's subject.
void shellOpenStaffTile(BuildContext context, Map<String, dynamic> tile,
    void Function(String route, [String? seed]) navigate) {
  final featureKey = (tile['feature_key'] ?? '').toString();
  if (featureKey.isNotEmpty) {
    Supabase.instance.client
        .rpc('nav_open', params: {'p_feature_key': featureKey})
        .catchError((_) => null);
  }
  final toolKey = (tile['tool_key'] ?? '').toString();
  if (toolKey.isNotEmpty) {
    openDevTool(context, toolKey);
    return;
  }
  final deep = (tile['deep_link'] ?? '').toString();
  if (deep.startsWith('/') && !deep.startsWith('/admin/go/')) {
    Navigator.of(context).pushNamed(deep);
    return;
  }
  final route = (tile['route_key'] ?? '').toString();
  if (route.isEmpty) return;
  final seed = (tile['seed'] ?? '').toString();
  navigate(route, seed.isEmpty ? null : seed);
}

/// A Customers / Suppliers / Fulfill page with the home's extra doors drawn
/// above its own tab row. Under the v1 flag the page is returned untouched.
Widget shellWithStaffStrip(String tab, Widget page,
    void Function(String route, [String? seed]) navigate) {
  if (StaffNav.value.value.isLegacy) return page;
  return Column(children: [
    Builder(builder: (ctx) => StaffHomeStrip(
          tabKey: tab,
          load: shellStaffHomeLoad,
          onOpen: (t) => shellOpenStaffTile(ctx, t, navigate),
        )),
    Expanded(child: page),
  ]);
}

/// The Money / More page.
Widget shellStaffHomePage(String tab, bool active,
    void Function(String route, [String? seed]) navigate) =>
    Builder(builder: (ctx) => StaffHomeScreen(
          tabKey: tab,
          active: active,
          load: shellStaffHomeLoad,
          onOpen: (t) => shellOpenStaffTile(ctx, t, navigate),
          onUnusedReport: () => AdminDashboardScreen.openUnusedReport(ctx),
        ));

/// CHANGE #1017 (6) — on a wide screen the tabs stand in a rail on the left
/// instead of a bar at the bottom. Same entries, same routes, same badge; only
/// the placement changes. Everything drawn is the row's own label and icon.
class StaffSidebar extends StatelessWidget {
  const StaffSidebar({
    super.key,
    required this.entries,
    required this.index,
    required this.onRoute,
    this.alertCount = 0,
  });
  final List<AdminNavEntry> entries;
  /// The shell's page index — the SAME rule the bottom bar uses to know which
  /// tab is lit, copied verbatim so the two chromes can never disagree.
  final int index;
  final void Function(String route) onRoute;
  final int alertCount;

  String get _activeRoute {
    switch (index) {
        case 3: return 'dashboard';
        case 6: return 'customers';
        case 5: return 'suppliers';
        // CHANGE #1016 — Fulfill is page 10 (11 is My Shop; the old mapping
        // never highlighted the Fulfill tab), and the two new homes.
        case 10: return 'fulfillment';
        case 13: return 'money_home';
        case 14: return 'more';
        default: return '';
      }
  }

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const Key('c1017_staff_sidebar'),
      width: Ds.space.x48 * 2,
      decoration: BoxDecoration(
        color: Ds.c.surface,
        border: Border(right: BorderSide(color: Ds.c.divider)),
      ),
      child: ListView(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
        children: [
          for (final e in entries)
            _StaffRailItem(
              entry: e,
              selected: _activeRoute.isNotEmpty && _activeRoute == (e.route ?? ''),
              badge: e.route == 'fulfillment' ? alertCount : 0,
              onTap: () => onRoute(e.route ?? ''),
            ),
        ],
      ),
    );
  }
}

class _StaffRailItem extends StatelessWidget {
  const _StaffRailItem({required this.entry, required this.selected, required this.badge, required this.onTap});
  final AdminNavEntry entry;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Ds.c.brand : Ds.c.textSecondary;
    return Semantics(
      button: true,
      selected: selected,
      label: entry.label,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget + Ds.space.x16),
          padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
          decoration: BoxDecoration(
            color: selected ? Ds.c.brandSoft : null,
            border: Border(left: BorderSide(color: selected ? Ds.c.brand : Colors.transparent, width: Ds.space.x4)),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            PulseBadge(count: badge, child: Icon(entry.icon, size: Ds.space.x24, color: color)),
            SizedBox(height: Ds.space.x4),
            Text(entry.label, style: Ds.t.caption.copyWith(color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w400),
                maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
          ]),
        ),
      ),
    );
  }
}
