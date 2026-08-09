import 'package:flutter/material.dart';

import '../../utils/render_log.dart';

/// One item in an admin nav surface.
class AdminNavEntry {
  final String label;
  final IconData icon;

  /// Route key for `_handleAdminNav`, for entries that push a screen.
  final String? route;

  const AdminNavEntry(this.label, this.icon, {this.route});
}

/// The five primary sections of the WIDE shell's top row, in render order.
///
/// The wide shell starts at 900 px, and at that width this row plus the logo
/// and the profile chip already needs nearly all of it. Anything added here
/// clips rather than wraps — which is why the WhatsApp screens live in
/// [kAdminOverflowNav] behind a "More" popup instead of as two more links.
const kAdminTopNav = <AdminNavEntry>[
  AdminNavEntry('Dashboard', Icons.dashboard_outlined),
  AdminNavEntry('WhatsApp', Icons.forum_outlined),
  AdminNavEntry('Customers', Icons.people_outline),
  AdminNavEntry('Suppliers', Icons.inventory_2_outlined),
  AdminNavEntry('Fulfillment', Icons.local_shipping_outlined),
];

/// The NARROW shell's bottom bar, in render order. Five tabs is the ceiling —
/// a sixth makes every label wrap at 360 px. New destinations go in the profile
/// sheet ([AdminProfileMenuTiles]), never here.
///
/// Note the last label is 'Fulfill', not 'Fulfillment': it is the only one that
/// fits the narrow tab. That is why this list is separate from [kAdminTopNav]
/// rather than shared.
const kAdminBottomNav = <AdminNavEntry>[
  AdminNavEntry('Dashboard', Icons.dashboard_outlined),
  AdminNavEntry('WhatsApp', Icons.forum_outlined),
  AdminNavEntry('Customers', Icons.people_outline),
  AdminNavEntry('Suppliers', Icons.inventory_2_outlined),
  AdminNavEntry('Fulfill', Icons.local_shipping_outlined),
];

/// Destinations that do not fit the top row, shown in its "More" popup AND —
/// as the same list, not a second copy — in the mobile profile sheet via
/// [AdminProfileMenuTiles]. Between those two surfaces every entry here is
/// reachable at every viewport.
///
/// All five WhatsApp screens live here rather than in [kAdminTopNav]. The top
/// row is already at its ceiling: see that list's comment — at 900 px it plus
/// the logo and the profile chip needs nearly the whole width, and even at
/// 1024 px five more links of this length clip rather than wrap.
///
/// Every entry MUST have a `route`, and that key MUST have a case in
/// `_handleAdminNav` in home_shell.dart. A key with no case renders a perfect
/// row that does nothing on tap — the #645/#646 bug, three deploys deep.
const kAdminOverflowNav = <AdminNavEntry>[
  AdminNavEntry('WhatsApp Templates', Icons.description_outlined,
      route: 'wa_templates'),
  AdminNavEntry('WhatsApp Campaigns', Icons.campaign_outlined,
      route: 'wa_campaigns'),
  AdminNavEntry('Segments', Icons.filter_alt_outlined, route: 'wa_segments'),
  AdminNavEntry('Sequences', Icons.timeline_outlined, route: 'wa_drips'),
  AdminNavEntry('WhatsApp Ops', Icons.settings_suggest_outlined,
      route: 'wa_ops'),
  // Sibling of registration approvals: the customer account/data-deletion
  // queue. Its badge count comes from admin_deletion_request_count(), passed in
  // as a plain int so this file keeps its Supabase-free, VM-testable isolation.
  AdminNavEntry('Deletion Requests', Icons.person_remove_outlined,
      route: 'deletion_requests'),
];

/// The wide shell's "More" popup, sitting after Fulfillment in the top row.
///
/// A popup rather than two more links: see [kAdminTopNav] — at the 900 px
/// where the wide shell begins, two extra links clip the row.
class AdminMoreNavMenu extends StatelessWidget {
  final ValueChanged<String> onNav;

  /// Live count for the Deletion Requests entry (admin_deletion_request_count).
  final int deletionCount;

  const AdminMoreNavMenu({
    super.key,
    required this.onNav,
    this.deletionCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'More',
      offset: const Offset(0, 40),
      onSelected: onNav,
      itemBuilder: (_) => [
        for (final e in kAdminOverflowNav)
          PopupMenuItem<String>(
            value: e.route,
            // min + Flexible: the popup constrains its items, and these two
            // labels are long enough to clip against a narrow one.
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              (e.route == 'deletion_requests' && deletionCount > 0)
                  ? Badge(
                      label: Text('$deletionCount'),
                      child: Icon(e.icon,
                          size: 16, color: const Color(0xFF374151)))
                  : Icon(e.icon, size: 16, color: const Color(0xFF374151)),
              const SizedBox(width: 10),
              Flexible(
                child: Text(e.label,
                    style: const TextStyle(
                        fontSize: 14, color: Color(0xFF374151))),
              ),
            ]),
          ),
      ],
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.more_horiz, size: 16, color: Color(0xFF374151)),
            SizedBox(width: 5),
            Text('More',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF374151))),
          ],
        ),
      ),
    );
  }
}

/// The admin action rows of the mobile profile sheet, plus the row widget the
/// whole sheet is built from.
///
/// This lives in its own file deliberately. home_shell.dart transitively pulls
/// in web-only libraries (package:web / dart:html), so anything imported from
/// it cannot be loaded by a Dart VM widget test — the same trap that left five
/// test files silently never compiling before #635. Keeping these rows here,
/// behind nothing heavier than material.dart and RenderLog, is what makes them
/// testable at a phone viewport without a network or a Supabase session.
///
/// Every row dismisses the sheet and then hands its route key to [nav]. Those
/// key strings must stay in step with `_handleAdminNav`'s switch in
/// home_shell.dart, which is what actually opens the screen: a row whose key
/// that switch does not handle renders perfectly and does nothing on tap. That
/// was exactly the bug being fixed when this widget was extracted — #645/#646
/// added WhatsApp Templates and Campaigns to the desktop-only nav row, and the
/// router had no case for either.
class AdminProfileMenuTiles extends StatelessWidget {
  final bool isSuperAdmin;
  final ValueChanged<String> nav;

  /// Live count for the Deletion Requests tile (admin_deletion_request_count).
  final int deletionCount;

  const AdminProfileMenuTiles({
    super.key,
    required this.isSuperAdmin,
    required this.nav,
    this.deletionCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isSuperAdmin)
          AdminSheetTile(
            icon: Icons.admin_panel_settings_outlined,
            label: 'Manage Admins',
            color: const Color(0xFF1B7A43),
            onTap: () { Navigator.pop(context); nav('manage_admins'); },
          ),
        if (isSuperAdmin)
          Builder(builder: (_) {
            RenderLog.write('c209_upi_tile_rendered', 1);
            return AdminSheetTile(
              icon: Icons.qr_code_outlined,
              label: 'Payment and Partner',
              color: const Color(0xFF1B7A43),
              onTap: () { Navigator.pop(context); nav('payment_upi'); },
            );
          }),
        AdminSheetTile(
          icon: Icons.add_business_outlined,
          label: 'Add Supplier',
          onTap: () { Navigator.pop(context); nav('add_supplier'); },
        ),
        AdminSheetTile(
          icon: Icons.person_add_outlined,
          label: 'Add Customer',
          onTap: () { Navigator.pop(context); nav('add_customer'); },
        ),
        Builder(builder: (_) { RenderLog.write('c206_dropdown_addmed', 1); return const SizedBox.shrink(); }),
        AdminSheetTile(
          icon: Icons.medication_outlined,
          label: 'Add Medicine',
          onTap: () { Navigator.pop(context); nav('add_medicine'); },
        ),
        AdminSheetTile(
          icon: Icons.badge_outlined,
          label: 'MR Registrations',
          onTap: () { Navigator.pop(context); nav('mr'); },
        ),
        AdminSheetTile(
          icon: Icons.business_outlined,
          label: 'Company Registrations',
          onTap: () { Navigator.pop(context); nav('companies'); },
        ),
        AdminSheetTile(
          icon: Icons.delivery_dining_outlined,
          label: 'Delivery Partners',
          onTap: () { Navigator.pop(context); nav('delivery_partners'); },
        ),
        // #645/#646 shipped the WhatsApp screens but wired them only into
        // admin_shell.dart's wide-viewport link row, so a phone had no way in.
        //
        // These rows are now GENERATED from [kAdminOverflowNav] rather than
        // hand-written, so the popup and the sheet cannot drift: adding a
        // WhatsApp screen to that one list reaches both viewports at once, and
        // a label added to only one surface is no longer possible.
        //
        // None is gated on isSuperAdmin: every one of these screens calls RPCs
        // that gate on get_my_role() and renders the backend's not_authorized
        // answer itself.
        for (final e in kAdminOverflowNav)
          AdminSheetTile(
            icon: e.icon,
            label: e.label,
            badgeCount:
                e.route == 'deletion_requests' ? deletionCount : 0,
            onTap: () { Navigator.pop(context); nav(e.route ?? ''); },
          ),
      ],
    );
  }
}

/// One row of the profile sheet. Was `_SheetTile` in home_shell.dart; moved
/// here unchanged so this file is self-contained.
class AdminSheetTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  /// When > 0, a badge on the leading icon (used by the Deletion Requests tile).
  final int badgeCount;

  const AdminSheetTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = const Color(0xFF374151),
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Row(children: [
          badgeCount > 0
              ? Badge(label: Text('$badgeCount'), child: Icon(icon, size: 20, color: color))
              : Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: color)),
        ]),
      ),
    );
  }
}
