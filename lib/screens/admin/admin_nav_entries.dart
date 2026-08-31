import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import 'nav_registry_view.dart';

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
List<AdminNavEntry> get kAdminTopNav => <AdminNavEntry>[
      AdminNavEntry(c('admin_nav.top_dashboard'), Icons.dashboard_outlined),
      AdminNavEntry(c('admin_nav.top_whatsapp'), Icons.forum_outlined),
      AdminNavEntry(c('admin_nav.top_customers'), Icons.people_outline),
      AdminNavEntry(c('admin_nav.top_suppliers'), Icons.inventory_2_outlined),
      AdminNavEntry(
          c('admin_nav.top_fulfillment'), Icons.local_shipping_outlined),
    ];

/// The NARROW shell's bottom bar, in render order. Five tabs is the ceiling —
/// a sixth makes every label wrap at 360 px. New destinations go in the profile
/// sheet ([AdminProfileMenuTiles]), never here.
///
/// Note the last label is 'Fulfill', not 'Fulfillment': it is the only one that
/// fits the narrow tab. That is why this list is separate from [kAdminTopNav]
/// rather than shared.
List<AdminNavEntry> get kAdminBottomNav => <AdminNavEntry>[
      AdminNavEntry(c('admin_nav.bottom_dashboard'), Icons.dashboard_outlined),
      AdminNavEntry(c('admin_nav.bottom_whatsapp'), Icons.forum_outlined),
      AdminNavEntry(c('admin_nav.bottom_customers'), Icons.people_outline),
      AdminNavEntry(c('admin_nav.bottom_suppliers'), Icons.inventory_2_outlined),
      AdminNavEntry(
          c('admin_nav.bottom_fulfill'), Icons.local_shipping_outlined),
    ];

/// CHANGE #325 — the profile dropdown, and NOTHING but the profile dropdown.
///
/// This widget used to generate ~20 rows from `kAdminOverflowNav` plus eight
/// hand-written ones, which is how the dropdown reached the thirty items Om
/// counted. Both lists are gone. The rows it draws now are exactly
/// `nav_registry().profile_menu`, and the backend admits only two features
/// onto that surface — a CHECK constraint on `feature_registry` rejects
/// `surface='profile'` for anything that is not View Profile or Logout. A
/// future feature therefore CANNOT leak back in here: there is no list in this
/// file to append it to, and the table would refuse it if there were.
///
/// The labels, the icons, the order and the destructive tone all arrive in the
/// payload; this file renders them and computes nothing.
class AdminProfileMenuTiles extends StatelessWidget {
  /// `nav_registry().profile_menu`, in payload order.
  final List<Map<String, dynamic>> items;

  /// Fires the row's own `route_key`, untouched.
  final ValueChanged<String> nav;

  const AdminProfileMenuTiles({
    super.key,
    required this.items,
    required this.nav,
  });

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c325_profile_menu_rows', items.length);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in items)
          AdminSheetTile(
            icon: navIcon((item['icon_key'] ?? '').toString()),
            label: (item['label'] ?? '').toString(),
            color: (item['tone'] ?? '') == 'danger'
                ? Ds.c.danger
                : const Color(0xFF374151),
            onTap: () {
              Navigator.pop(context);
              nav((item['route_key'] ?? '').toString());
            },
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
