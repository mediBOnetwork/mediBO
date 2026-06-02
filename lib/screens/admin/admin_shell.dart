import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../user_state.dart';
import 'admin_add_medicine_screen.dart';
import 'admin_manage_admins_screen.dart';
import 'admin_pending_bills_screen.dart';

// ── Nav entry ────────────────────────────────────────────────────────────────

class _NavEntry {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String pageTitle;
  const _NavEntry(this.icon, this.activeIcon, this.label, this.pageTitle);
}

const _kNavBase = [
  _NavEntry(Icons.medication_outlined, Icons.medication,
      'Add Medicine', 'Add Medicine Details'),
  _NavEntry(Icons.receipt_long_outlined, Icons.receipt_long,
      'Orders', 'Orders'),
  _NavEntry(Icons.help_outline, Icons.help,
      'Inquiry', 'Inquiry'),
  _NavEntry(Icons.inventory_2_outlined, Icons.inventory_2,
      'Suppliers', 'Supplier Dashboard'),
  _NavEntry(Icons.people_outline, Icons.people,
      'Customers', 'Customer Dashboard'),
  _NavEntry(Icons.inbox_outlined, Icons.inbox,
      'Bills', 'Pending Bills'),
];

const _kNavAdmins = _NavEntry(
  Icons.admin_panel_settings_outlined,
  Icons.admin_panel_settings,
  'Admins', 'Manage Admins',
);

List<_NavEntry> _effectiveNav(bool isSuperAdmin) =>
    isSuperAdmin ? [..._kNavBase, _kNavAdmins] : _kNavBase;

// ── Admin shell ──────────────────────────────────────────────────────────────

class AdminShell extends StatefulWidget {
  const AdminShell({super.key});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _index = 0;
  int _pendingBillsCount = 0;

  @override
  void initState() {
    super.initState();
    _loadPendingCount();
  }

  Future<void> _loadPendingCount() async {
    try {
      final res = await Supabase.instance.client
          .from('pending_bills')
          .select('id')
          .eq('status', 'pending');
      if (mounted) setState(() => _pendingBillsCount = (res as List).length);
    } catch (_) {}
  }

  void _navigateQuickLink(BuildContext ctx, String route, bool isSuperAdmin) {
    if (!mounted) return;
    if (route == 'logout') {
      UserState.read(ctx).signOut();
      return;
    }
    if (route == 'manage_admins' && !isSuperAdmin) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text('Only super-admins can manage admin accounts'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }
    Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => switch (route) {
        'manage_admins' => const AdminManageAdminsScreen(),
        'add_supplier' => const _QuickLinkPlaceholder(
            title: 'Add Supplier',
            icon: Icons.add_business_outlined),
        'add_customer' => const _QuickLinkPlaceholder(
            title: 'Add Customer',
            icon: Icons.person_add_outlined),
        _ => const _QuickLinkPlaceholder(
            title: 'Coming Soon',
            icon: Icons.construction_outlined),
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    final isSuperAdmin = auth.isSuperAdmin;

    return LayoutBuilder(builder: (ctx, c) {
      if (c.maxWidth >= 768) return _buildDesktop(ctx, isSuperAdmin);
      return _buildMobile(ctx, isSuperAdmin);
    });
  }

  // ── Web/desktop layout ───────────────────────────────────────────────────

  Widget _buildDesktop(BuildContext ctx, bool isSuperAdmin) {
    final nav = _effectiveNav(isSuperAdmin);
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _DesktopHeader(
            currentIndex: _index,
            nav: nav,
            onNavTap: (i) => setState(() => _index = i),
            isSuperAdmin: isSuperAdmin,
            onQuickLink: (route) => _navigateQuickLink(ctx, route, isSuperAdmin),
            onLogout: () => UserState.read(ctx).signOut(),
            pendingBillsCount: _pendingBillsCount,
          ),
          Expanded(child: _buildBody(isSuperAdmin)),
        ],
      ),
    );
  }

  Widget _buildBody(bool isSuperAdmin) {
    final nav = _effectiveNav(isSuperAdmin);
    if (_index == 0) return const AdminAddMedicineScreen();
    if (_index == 5) return PendingBillsScreen(onCountChanged: _loadPendingCount);
    if (isSuperAdmin && _index == 6) return const AdminManageAdminsScreen();
    if (_index < nav.length) return _PageBody(title: nav[_index].pageTitle, icon: nav[_index].icon);
    return const _PageBody(title: 'Coming Soon', icon: Icons.construction_outlined);
  }

  // ── Mobile layout ────────────────────────────────────────────────────────

  Widget _buildMobile(BuildContext ctx, bool isSuperAdmin) {
    final nav = _effectiveNav(isSuperAdmin);
    // Clamp _index to valid range when nav length changes
    final safeIndex = _index.clamp(0, nav.length - 1);
    if (safeIndex != _index) WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _index = safeIndex);
    });
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        title: RichText(
          text: const TextSpan(
            children: [
              TextSpan(
                text: 'mediBO',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1B5E20),
                ),
              ),
              TextSpan(
                text: ' Admin',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF6B7280),
                ),
              ),
            ],
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Color(0xFF374151)),
            tooltip: 'Quick links',
            onSelected: (route) => _navigateQuickLink(ctx, route, isSuperAdmin),
            itemBuilder: (_) => [
              if (isSuperAdmin)
                const PopupMenuItem(
                  value: 'manage_admins',
                  child: _PopupRow(
                    icon: Icons.admin_panel_settings_outlined,
                    label: 'Manage Admins',
                    color: Color(0xFF1B5E20),
                  ),
                ),
              const PopupMenuItem(
                value: 'add_supplier',
                child: _PopupRow(
                  icon: Icons.add_business_outlined,
                  label: 'Add Supplier',
                ),
              ),
              const PopupMenuItem(
                value: 'add_customer',
                child: _PopupRow(
                  icon: Icons.person_add_outlined,
                  label: 'Add Customer',
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: _PopupRow(
                  icon: Icons.logout,
                  label: 'Logout',
                  color: Color(0xFFDC2626),
                ),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(isSuperAdmin),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: safeIndex,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF1B5E20),
        unselectedItemColor: const Color(0xFF9CA3AF),
        selectedFontSize: 10,
        unselectedFontSize: 10,
        elevation: 8,
        onTap: (i) => setState(() => _index = i),
        items: nav.asMap().entries.map((e) {
              final i = e.key;
              final n = e.value;
              final hasBadge = i == 5 && _pendingBillsCount > 0;
              return BottomNavigationBarItem(
                icon: hasBadge
                    ? Badge(label: Text('$_pendingBillsCount'), child: Icon(n.icon))
                    : Icon(n.icon),
                activeIcon: hasBadge
                    ? Badge(label: Text('$_pendingBillsCount'), child: Icon(n.activeIcon))
                    : Icon(n.activeIcon),
                label: n.label,
              );
            }).toList(),
      ),
    );
  }
}

// ── Desktop header ───────────────────────────────────────────────────────────

class _DesktopHeader extends StatelessWidget {
  final int currentIndex;
  final List<_NavEntry> nav;
  final ValueChanged<int> onNavTap;
  final ValueChanged<String> onQuickLink;
  final VoidCallback onLogout;
  final bool isSuperAdmin;
  final int pendingBillsCount;

  const _DesktopHeader({
    required this.currentIndex,
    required this.nav,
    required this.onNavTap,
    required this.onQuickLink,
    required this.onLogout,
    required this.isSuperAdmin,
    this.pendingBillsCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            child: Row(
              children: [
                // Branding
                RichText(
                  text: const TextSpan(
                    children: [
                      TextSpan(
                        text: 'mediBO',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1B5E20),
                        ),
                      ),
                      TextSpan(
                        text: ' Admin',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 32),
                // Nav tabs
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: List.generate(
                        nav.length,
                        (i) => _NavTab(
                          icon: currentIndex == i
                              ? nav[i].activeIcon
                              : nav[i].icon,
                          label: nav[i].label,
                          selected: currentIndex == i,
                          onTap: () => onNavTap(i),
                          badge: i == 5 ? pendingBillsCount : 0,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                // Quick links dropdown
                _QuickLinksButton(
                  isSuperAdmin: isSuperAdmin,
                  onSelected: onQuickLink,
                ),
                const SizedBox(width: 8),
                // Logout
                TextButton.icon(
                  onPressed: onLogout,
                  icon: const Icon(Icons.logout,
                      size: 15, color: Color(0xFFDC2626)),
                  label: const Text(
                    'Logout',
                    style: TextStyle(
                        fontSize: 13, color: Color(0xFFDC2626)),
                  ),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
        ],
      ),
    );
  }
}

// ── Desktop nav tab ──────────────────────────────────────────────────────────

class _NavTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int badge;

  const _NavTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    Widget iconWidget = Icon(
      icon, size: 15,
      color: selected ? const Color(0xFF1B5E20) : const Color(0xFF6B7280),
    );
    if (badge > 0) {
      iconWidget = Stack(clipBehavior: Clip.none, children: [
        iconWidget,
        Positioned(
          right: -7, top: -5,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFFDC2626),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('$badge',
                style: const TextStyle(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFECFDF5) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              iconWidget,
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? const Color(0xFF1B5E20) : const Color(0xFF6B7280),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Quick links popup ────────────────────────────────────────────────────────

class _QuickLinksButton extends StatelessWidget {
  final bool isSuperAdmin;
  final ValueChanged<String> onSelected;

  const _QuickLinksButton({
    required this.isSuperAdmin,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Quick links',
      offset: const Offset(0, 44),
      onSelected: onSelected,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bolt, size: 15, color: Color(0xFF374151)),
            SizedBox(width: 6),
            Text(
              'Quick Links',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: Color(0xFF374151),
              ),
            ),
            SizedBox(width: 2),
            Icon(Icons.arrow_drop_down,
                size: 18, color: Color(0xFF374151)),
          ],
        ),
      ),
      itemBuilder: (_) => [
        if (isSuperAdmin)
          const PopupMenuItem(
            value: 'manage_admins',
            child: _PopupRow(
              icon: Icons.admin_panel_settings_outlined,
              label: 'Manage Admins',
              color: Color(0xFF1B5E20),
            ),
          ),
        const PopupMenuItem(
          value: 'add_supplier',
          child: _PopupRow(
            icon: Icons.add_business_outlined,
            label: 'Add Supplier',
          ),
        ),
        const PopupMenuItem(
          value: 'add_customer',
          child: _PopupRow(
            icon: Icons.person_add_outlined,
            label: 'Add Customer',
          ),
        ),
      ],
    );
  }
}

// ── Shared popup row ─────────────────────────────────────────────────────────

class _PopupRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _PopupRow({
    required this.icon,
    required this.label,
    this.color = const Color(0xFF374151),
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Text(label,
            style: TextStyle(
                fontSize: 14,
                color: color,
                fontWeight: FontWeight.w500)),
      ],
    );
  }
}

// ── Placeholder page body ────────────────────────────────────────────────────

class _PageBody extends StatelessWidget {
  final String title;
  final IconData icon;

  const _PageBody({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, size: 40, color: const Color(0xFF1B5E20)),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            'Coming soon — this section will be built out.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              color: Color(0xFF6B7280),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Quick-link placeholder screen ────────────────────────────────────────────

class _QuickLinkPlaceholder extends StatelessWidget {
  final String title;
  final IconData icon;

  const _QuickLinkPlaceholder(
      {super.key, required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 20, color: Color(0xFF1B5E20)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Color(0xFF111827),
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(icon, size: 40, color: const Color(0xFF1B5E20)),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Coming soon — this section will be built out.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
            ),
          ],
        ),
      ),
    );
  }
}
