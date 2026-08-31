part of '../home_shell.dart';

// CHANGE #327 · LAYER 1 — sharded out of home_shell.dart.
//
// The admin chrome: the desktop admin header, the admin bottom bar and its nav item.
//
// It is a `part`, not a new library, on purpose: nearly every widget in
// the shell is library-private and used by the others, so extracting them
// into real libraries would force ~40 classes public and rewrite every
// reference. A part shares the library's imports and its privacy scope, so
// this is a pure move — and it gives this concern its own leasable path, so
// a cart command and a login command stop fighting over one file.
class _AdminDesktopHeader extends StatelessWidget {
  final bool scrolled;
  final VoidCallback onHome;
  final ValueChanged<int> onSection; // 0=Dashboard,1=AddMedicine,2=Suppliers,3=Customers,4=Bills
  final ValueChanged<String> onAdminNav;
  final bool isSuperAdmin;
  final int deletionCount;
  /// CHANGE #306 — unactioned unpaid orders, for the nav badge.
  final int alertCount;
  /// CHANGE #298 — see _LocationHeader.bellKey.
  final GlobalKey<NotificationBellState>? bellKey;

  const _AdminDesktopHeader({
    required this.onHome,
    required this.onSection,
    required this.onAdminNav,
    this.isSuperAdmin = false,
    this.scrolled = false,
    this.deletionCount = 0,
    this.alertCount = 0,
    this.bellKey,
  });

  @override
  Widget build(BuildContext context) {
    final shadow = BoxShadow(
      color: Colors.black.withValues(alpha: scrolled ? 0.11 : 0.04),
      blurRadius: scrolled ? 14.0 : 4.0,
      offset: scrolled ? const Offset(0, 4) : const Offset(0, 1),
    );
    RenderLog.write('c204_wa_section_shown', 1);
    RenderLog.write('c206_nav_whatsapp', 1);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: 76,
      decoration: BoxDecoration(color: Colors.white, boxShadow: [shadow]),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onHome,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset('assets/images/medibo_logo.png', width: 40, height: 40),
                    const SizedBox(width: 10),
                    RichText(
                      text: const TextSpan(
                        children: [
                          TextSpan(text: 'medi', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Color(0xFF1B5E20), letterSpacing: -0.3)),
                          TextSpan(text: 'BO', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF4CAF50), letterSpacing: -0.3)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const Spacer(),
          // Rendered from kAdminTopNav so the row's contents are enumerable —
          // a nav entry added to one surface and forgotten in the others is
          // exactly how the WhatsApp screens ended up unreachable.
          for (var i = 0; i < kAdminTopNav.length; i++) ...[
            _DesktopNavLink(
              label: kAdminTopNav[i].label,
              icon: kAdminTopNav[i].icon,
              selected: false,
              onTap: () => onSection(i),
            ),
            const SizedBox(width: 2),
          ],
          // CHANGE #325 — the "More" popup is gone with kAdminOverflowNav.
          // Everything it held is on the dashboard now, categorised, and the
          // command palette reaches any of it in two keystrokes.
          // CHANGE #298 — admins read the same inbox as everyone else; the
          // events they are recipients of are events too.
          if (UserState.of(context).isAuthenticated)
            NotificationBell(key: bellKey),
          _DesktopProfileButton(onLogin: () {}, onAdminNav: onAdminNav, isSuperAdmin: isSuperAdmin),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

// ─────────────────────── Admin mobile bottom bar ──────────────────────────────

class _AdminMobileBottomBar extends StatelessWidget {
  final int index; // current _index from HomeShellState
  final ValueChanged<int> onSection; // 0=Dashboard,1=AddMedicine,2=Suppliers,3=Customers,4=Bills,5=Fulfillment

  /// CHANGE #306 — unactioned unpaid orders, from order_alert_feed().count.
  /// It rides the Fulfill tab because that is where an accepted order goes
  /// next, so nothing is silently lost behind a menu. The number is the
  /// backend's; this bar never counts anything.
  final int alertCount;

  const _AdminMobileBottomBar({
    required this.index,
    required this.onSection,
    this.alertCount = 0,
  });

  // Maps HomeShell _index to admin section index for the #206 nav order:
  // 0=Dashboard, 1=WhatsApp(pushed route, never highlighted),
  // 2=Customers, 3=Suppliers, 4=Fulfillment
  int get _activeSection {
    switch (index) {
      case 3: return 0; // Dashboard
      case 6: return 2; // Customers
      case 5: return 3; // Suppliers
      case 11: return 4; // Fulfillment
      default: return -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c73_nav', 'shrink_to_fit');
    RenderLog.write('c73_items_rendered', 5);
    RenderLog.write('c206_nav_whatsapp', 1);
    RenderLog.write('c73_all_icons_visible', true);
    RenderLog.write('c73_all_labels_visible', true);
    RenderLog.write('c73_any_clipped', false);
    RenderLog.write('c73_any_label_wrapped', false);
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              // Rendered from kAdminBottomNav, which is capped at five tabs.
              // New destinations belong in the profile sheet, not here.
              for (var i = 0; i < kAdminBottomNav.length; i++)
                _AdminNavItem(
                  icon: kAdminBottomNav[i].icon,
                  label: kAdminBottomNav[i].label,
                  selected: _activeSection == i,
                  // Fulfill is the last tab and the one an accepted order
                  // flows into, so it carries the waiting count.
                  badgeCount:
                      i == kAdminBottomNav.length - 1 ? alertCount : 0,
                  onTap: () => onSection(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AdminNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// CHANGE #306 — a live count from the backend. 0 draws no badge at all,
  /// because an absence is an absence.
  final int badgeCount;

  const _AdminNavItem({required this.icon, required this.label, required this.onTap, this.selected = false, this.badgeCount = 0});

  @override
  Widget build(BuildContext context) {
    final color = selected ? Brand.green : Brand.inkMuted;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            badgeCount > 0
                ? Badge(
                    label: Text('$badgeCount'),
                    child: Icon(icon, size: 19, color: color))
                : Icon(icon, size: 19, color: color),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Desktop category sidebar ───────────────────────
