import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/fcm_service.dart';
import '../../theme.dart';
import '../../user_state.dart';
import 'admin_add_medicine_screen.dart';
import 'admin_alert_overlay.dart';
import 'admin_customer_screen.dart';
import 'admin_dashboard_screen.dart';
import 'admin_manage_admins_screen.dart';
import 'admin_pending_bills_screen.dart';

// ── View state ────────────────────────────────────────────────────────────────

enum _AdminView { dashboard, section }

// ── Nav entry ────────────────────────────────────────────────────────────────

class _NavEntry {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String pageTitle;
  const _NavEntry(this.icon, this.activeIcon, this.label, this.pageTitle);
}

const _kNavBase = [
  _NavEntry(Icons.dashboard_outlined, Icons.dashboard,
      'Dashboard', 'Dashboard'),
  _NavEntry(Icons.medication_outlined, Icons.medication,
      'Add Medicine', 'Add Medicine Details'),
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
  final int? initialSection;
  const AdminShell({super.key, this.initialSection});

  @override
  State<AdminShell> createState() => _AdminShellState();
}

class _AdminShellState extends State<AdminShell> {
  int _index = 0;
  _AdminView _view = _AdminView.dashboard;
  int _pendingBillsCount = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialSection != null) {
      _view = _AdminView.section;
      _index = widget.initialSection!;
    }
    _loadPendingCount();
    _initFcm();
  }

  void _initFcm() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) FcmService.init(userId);
    });
  }

  void _navigateToCustomerOrders() {
    if (!mounted) return;
    setState(() { _view = _AdminView.section; _index = 3; });
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

  // ── Logo tap → always go to medibo.in homepage ───────────────────────────

  void _onLogoTap() {
    Navigator.of(context).maybePop();
  }

  // ── Routing ───────────────────────────────────────────────────────────────

  void _navigateQuickLink(BuildContext ctx, String route, bool isSuperAdmin) {
    if (!mounted) return;
    switch (route) {
      case 'logout':
        UserState.read(ctx).signOut();
        return;
      case 'home':
        Navigator.of(ctx).maybePop();
        return;
      case 'dashboard':
        setState(() { _view = _AdminView.dashboard; _index = 0; });
        return;
      case 'add_medicine':
        setState(() { _view = _AdminView.section; _index = 1; });
        return;
      case 'suppliers':
        setState(() { _view = _AdminView.section; _index = 2; });
        return;
      case 'customers':
        setState(() { _view = _AdminView.section; _index = 3; });
        return;
      case 'bills':
        setState(() { _view = _AdminView.section; _index = 4; });
        return;
      case 'manage_admins':
        if (!isSuperAdmin) {
          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
            content: Text('Only super-admins can manage admin accounts'),
            backgroundColor: Color(0xFFDC2626),
          ));
          return;
        }
        setState(() { _view = _AdminView.section; _index = 5; });
        return;
      case 'add_supplier':
        Navigator.of(ctx).push(MaterialPageRoute(
          builder: (_) => const _QuickLinkPlaceholder(
              title: 'Add Supplier', icon: Icons.add_business_outlined),
        ));
        return;
      case 'add_customer':
        Navigator.of(ctx).push(MaterialPageRoute(
          builder: (_) => const _QuickLinkPlaceholder(
              title: 'Add Customer', icon: Icons.person_add_outlined),
        ));
        return;
    }
  }

  // ── Body ─────────────────────────────────────────────────────────────────

  Widget _buildBody(bool isSuperAdmin) {
    if (_view == _AdminView.dashboard) {
      return QuickLinkNavigator(
        navigate: (route) => _navigateQuickLink(context, route, isSuperAdmin),
        child: const AdminDashboardScreen(),
      );
    }
    // section
    final nav = _effectiveNav(isSuperAdmin);
    if (_index == 0) return QuickLinkNavigator(
      navigate: (route) => _navigateQuickLink(context, route, isSuperAdmin),
      child: const AdminDashboardScreen(),
    );
    if (_index == 1) return const AdminAddMedicineScreen();
    if (_index == 3) return const AdminCustomerScreen();
    if (_index == 4) return PendingBillsScreen(onCountChanged: _loadPendingCount);
    if (isSuperAdmin && _index == 5) return const AdminManageAdminsScreen();
    if (_index < nav.length) {
      return _PageBody(title: nav[_index].pageTitle, icon: nav[_index].icon);
    }
    return QuickLinkNavigator(
      navigate: (route) => _navigateQuickLink(context, route, isSuperAdmin),
      child: const AdminDashboardScreen(),
    );
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

  // ── Desktop layout ────────────────────────────────────────────────────────

  Widget _buildDesktop(BuildContext ctx, bool isSuperAdmin) {
    return AdminAlertOverlay(
      onOrderTap: _navigateToCustomerOrders,
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F6F8),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _AdminNewDesktopHeader(
              onLogoTap: _onLogoTap,
              onNav: (route) => _navigateQuickLink(ctx, route, isSuperAdmin),
              pendingBillsCount: _pendingBillsCount,
            ),
            Expanded(child: _buildBody(isSuperAdmin)),
          ],
        ),
      ),
    );
  }

  // ── Mobile layout ─────────────────────────────────────────────────────────

  Widget _buildMobile(BuildContext ctx, bool isSuperAdmin) {
    final nav = _kNavBase;
    final safeIndex = _index.clamp(0, nav.length - 1);
    if (safeIndex != _index) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _index = safeIndex);
      });
    }
    return AdminAlertOverlay(
      onOrderTap: _navigateToCustomerOrders,
      child: Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        title: Tooltip(
          message: 'Go to Homepage',
          child: GestureDetector(
            onTap: _onLogoTap,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: RichText(
                text: const TextSpan(children: [
                  TextSpan(
                    text: 'mediBO',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF1B7A43)),
                  ),
                ]),
              ),
            ),
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Color(0xFF374151)),
            tooltip: 'More options',
            onSelected: (route) => _navigateQuickLink(ctx, route, isSuperAdmin),
            itemBuilder: (_) => [
              if (isSuperAdmin)
                const PopupMenuItem(
                  value: 'manage_admins',
                  child: _PopupRow(
                    icon: Icons.admin_panel_settings_outlined,
                    label: 'Manage Admins',
                    color: Color(0xFF1B7A43),
                  ),
                ),
              const PopupMenuItem(
                value: 'add_supplier',
                child: _PopupRow(
                    icon: Icons.add_business_outlined, label: 'Add Supplier'),
              ),
              const PopupMenuItem(
                value: 'add_customer',
                child: _PopupRow(
                    icon: Icons.person_add_outlined, label: 'Add Customer'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'logout',
                child: _PopupRow(
                    icon: Icons.logout,
                    label: 'Logout',
                    color: Color(0xFFDC2626)),
              ),
            ],
          ),
        ],
      ),
      body: _buildBody(isSuperAdmin),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: safeIndex,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFF1B7A43),
        unselectedItemColor: const Color(0xFF9CA3AF),
        selectedFontSize: 10,
        unselectedFontSize: 10,
        elevation: 8,
        onTap: (i) => setState(() {
          _index = i;
          _view = i == 0 ? _AdminView.dashboard : _AdminView.section;
        }),
        items: nav.asMap().entries.map((e) {
          final i = e.key;
          final n = e.value;
          final hasBadge = i == 4 && _pendingBillsCount > 0;
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
    ));
  }
}

// ── Desktop header (new style — matches homepage _AdminDesktopHeader) ─────────
// logo | Spacer | Dashboard | Add Medicine | Suppliers | Customers | Bills | Hello Account

class _AdminNewDesktopHeader extends StatelessWidget {
  final VoidCallback onLogoTap;
  final ValueChanged<String> onNav;
  final int pendingBillsCount;

  const _AdminNewDesktopHeader({
    required this.onLogoTap,
    required this.onNav,
    this.pendingBillsCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: 76,
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(color: Color(0x0A000000), blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Logo
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onLogoTap,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B5E20),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.add, color: Colors.white, size: 24),
                    ),
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
          // Nav tabs
          _DesktopNavLink(label: 'Dashboard', icon: Icons.dashboard_outlined, selected: false, onTap: () => onNav('dashboard')),
          const SizedBox(width: 2),
          _DesktopNavLink(label: 'Add Medicine', icon: Icons.medication_outlined, selected: false, onTap: () => onNav('add_medicine')),
          const SizedBox(width: 2),
          _DesktopNavLink(label: 'Suppliers', icon: Icons.inventory_2_outlined, selected: false, onTap: () => onNav('suppliers')),
          const SizedBox(width: 2),
          _DesktopNavLink(label: 'Customers', icon: Icons.people_outline, selected: false, onTap: () => onNav('customers')),
          const SizedBox(width: 2),
          _BillsNavLink(count: pendingBillsCount, onTap: () => onNav('bills')),
          const SizedBox(width: 8),
          _AdminProfileChip(),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

// ── Header nav button ─────────────────────────────────────────────────────────

class _HdrBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  const _HdrBtn({
    required this.label,
    required this.icon,
    required this.onTap,
    this.color = const Color(0xFF374151),
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500, color: color)),
        ]),
      ),
    );
  }
}

// ── Bills nav button with live badge ─────────────────────────────────────────

class _BillsHdrBtn extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const _BillsHdrBtn({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF374151);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (count > 0)
            Badge(
              label: Text('$count'),
              child: const Icon(Icons.inbox_outlined, size: 14, color: color),
            )
          else
            const Icon(Icons.inbox_outlined, size: 14, color: color),
          const SizedBox(width: 4),
          const Text('Bills',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w500, color: color)),
        ]),
      ),
    );
  }
}

// ── Quick Links dropdown ───────────────────────────────────────────────────────

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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: const [
          Icon(Icons.bolt, size: 14, color: Color(0xFF374151)),
          SizedBox(width: 5),
          Text('Quick Links',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF374151))),
          SizedBox(width: 2),
          Icon(Icons.arrow_drop_down, size: 17, color: Color(0xFF374151)),
        ]),
      ),
      itemBuilder: (_) => [
        if (isSuperAdmin)
          const PopupMenuItem(
            value: 'manage_admins',
            child: _PopupRow(
              icon: Icons.admin_panel_settings_outlined,
              label: 'Manage Admins',
              color: Color(0xFF1B7A43),
            ),
          ),
        const PopupMenuItem(
          value: 'add_supplier',
          child: _PopupRow(
              icon: Icons.add_business_outlined, label: 'Add Supplier'),
        ),
        const PopupMenuItem(
          value: 'add_customer',
          child: _PopupRow(
              icon: Icons.person_add_outlined, label: 'Add Customer'),
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
    return Row(children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 10),
      Text(label,
          style: TextStyle(
              fontSize: 14, color: color, fontWeight: FontWeight.w500)),
    ]);
  }
}

// ── Placeholder page body ─────────────────────────────────────────────────────

class _PageBody extends StatelessWidget {
  final String title;
  final IconData icon;

  const _PageBody({required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: const Color(0xFFECFDF5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Icon(icon, size: 40, color: const Color(0xFF1B7A43)),
        ),
        const SizedBox(height: 20),
        Text(title,
            style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111827))),
        const SizedBox(height: 10),
        const Text(
          'Coming soon — this section will be built out.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
        ),
      ]),
    );
  }
}

// ── Quick-link placeholder screen ─────────────────────────────────────────────

class _QuickLinkPlaceholder extends StatelessWidget {
  final String title;
  final IconData icon;

  const _QuickLinkPlaceholder(
      {super.key, required this.title, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 20, color: Color(0xFF1B7A43)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(title,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111827))),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(icon, size: 40, color: const Color(0xFF1B7A43)),
          ),
          const SizedBox(height: 20),
          Text(title,
              style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827))),
          const SizedBox(height: 10),
          const Text(
            'Coming soon — this section will be built out.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
          ),
        ]),
      ),
    );
  }
}

// ── New header helper widgets ─────────────────────────────────────────────────

class _DesktopNavLink extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  const _DesktopNavLink({required this.label, required this.icon, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFECFDF5) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: selected ? const Color(0xFF1B7A43) : const Color(0xFF374151)),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: selected ? const Color(0xFF1B7A43) : const Color(0xFF374151))),
          ]),
        ),
      ),
    );
  }
}

class _BillsNavLink extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _BillsNavLink({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (count > 0)
              Badge(label: Text('$count'), child: const Icon(Icons.inbox_outlined, size: 16, color: Color(0xFF374151)))
            else
              const Icon(Icons.inbox_outlined, size: 16, color: Color(0xFF374151)),
            const SizedBox(width: 6),
            const Text('Bills', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF374151))),
          ]),
        ),
      ),
    );
  }
}

class _AdminProfileChip extends StatelessWidget {
  const _AdminProfileChip();

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    final rawName = auth.profile?.pharmacyName ?? Supabase.instance.client.auth.currentUser?.email ?? 'Account';
    final name = rawName.isNotEmpty ? rawName : 'Account';
    final initial = name[0].toUpperCase();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => UserState.read(context).signOut(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFECFDF5),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            CircleAvatar(
              radius: 14,
              backgroundColor: const Color(0xFF1B7A43),
              child: Text(initial, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Text('Hello $name', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF111827))),
            const SizedBox(width: 4),
            const Icon(Icons.keyboard_arrow_down, size: 16, color: Color(0xFF6B7280)),
          ]),
        ),
      ),
    );
  }
}
