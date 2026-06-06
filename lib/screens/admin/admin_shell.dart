import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/medicine_repository.dart';
import '../../services/fcm_service.dart';
import '../../theme.dart';
import '../../user_state.dart';
import '../../util.dart';
import '../storefront_screen.dart';
import 'admin_add_medicine_screen.dart';
import 'admin_alert_overlay.dart';
import 'admin_customer_screen.dart';
import 'admin_dashboard_screen.dart';
import 'admin_manage_admins_screen.dart';
import 'admin_pending_bills_screen.dart';

// ── View state ────────────────────────────────────────────────────────────────

enum _AdminView { homepage, dashboard, section }

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
  _AdminView _view = _AdminView.dashboard;
  int _pendingBillsCount = 0;

  // Homepage catalogue state
  final MedicineRepository _repo = MedicineRepository();
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  String _category = 'All';
  int _scrollTrigger = 0;
  int _scrollToTopTrigger = 0;
  bool _searchLoading = false;
  CatalogMeta? _desktopMeta;

  @override
  void initState() {
    super.initState();
    _loadPendingCount();
    _initFcm();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _initFcm() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) FcmService.init(userId);
    });
  }

  void _navigateToCustomerOrders() {
    if (!mounted) return;
    setState(() { _view = _AdminView.section; _index = 2; });
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

  // ── Logo tap (context-aware navigation) ──────────────────────────────────

  void _onLogoTap() {
    if (!mounted) return;
    setState(() {
      switch (_view) {
        case _AdminView.dashboard:
          // Dashboard → show medibo.in homepage with admin header
          _view = _AdminView.homepage;
        case _AdminView.homepage:
          // Homepage → back to admin dashboard
          _view = _AdminView.dashboard;
        case _AdminView.section:
          // Any admin section → go to admin dashboard
          _view = _AdminView.dashboard;
      }
    });
  }

  String get _logoTooltip {
    switch (_view) {
      case _AdminView.dashboard:
        return 'Go to Homepage';
      case _AdminView.homepage:
        return 'Go to Admin Dashboard';
      case _AdminView.section:
        return 'Go to Admin Dashboard';
    }
  }

  // ── Routing ───────────────────────────────────────────────────────────────

  void _navigateQuickLink(BuildContext ctx, String route, bool isSuperAdmin) {
    if (!mounted) return;
    switch (route) {
      case 'logout':
        UserState.read(ctx).signOut();
        return;
      case 'home':
        setState(() => _view = _AdminView.dashboard);
        return;
      case 'add_medicine':
        setState(() { _view = _AdminView.section; _index = 0; });
        return;
      case 'suppliers':
        setState(() { _view = _AdminView.section; _index = 1; });
        return;
      case 'customers':
        setState(() { _view = _AdminView.section; _index = 2; });
        return;
      case 'bills':
        setState(() { _view = _AdminView.section; _index = 3; });
        return;
      case 'manage_admins':
        if (!isSuperAdmin) {
          ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
            content: Text('Only super-admins can manage admin accounts'),
            backgroundColor: Color(0xFFDC2626),
          ));
          return;
        }
        setState(() { _view = _AdminView.section; _index = 4; });
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
    if (_view == _AdminView.homepage) {
      return _buildHomepageBody();
    }
    if (_view == _AdminView.dashboard) {
      return QuickLinkNavigator(
        navigate: (route) => _navigateQuickLink(context, route, isSuperAdmin),
        child: const AdminDashboardScreen(),
      );
    }
    // section
    final nav = _effectiveNav(isSuperAdmin);
    if (_index == 0) return const AdminAddMedicineScreen();
    if (_index == 2) return const AdminCustomerScreen();
    if (_index == 3) return PendingBillsScreen(onCountChanged: _loadPendingCount);
    if (isSuperAdmin && _index == 4) return const AdminManageAdminsScreen();
    if (_index < nav.length) {
      return _PageBody(title: nav[_index].pageTitle, icon: nav[_index].icon);
    }
    return QuickLinkNavigator(
      navigate: (route) => _navigateQuickLink(context, route, isSuperAdmin),
      child: const AdminDashboardScreen(),
    );
  }

  Widget _buildHomepageBody() {
    return Column(
      children: [
        _AdminSearchBar(
          controller: _searchCtrl,
          isLoading: _searchLoading,
          onSearch: (v) {
            if (!mounted) return;
            setState(() {
              final q = v.trim();
              _category = 'All';
              if (q.length >= 2) {
                _query = v;
              } else {
                _query = '';
                _scrollToTopTrigger++;
              }
            });
          },
          onScrollToResults: () {
            if (mounted) setState(() => _scrollTrigger++);
          },
        ),
        _AdminCategoryChips(
          meta: _desktopMeta,
          selected: _category,
          onCategoryTap: (key) {
            if (!mounted) return;
            setState(() { _category = key; _query = ''; _searchCtrl.clear(); });
          },
        ),
        Expanded(
          child: StorefrontScreen(
            query: _query,
            category: _category,
            onCategorySelected: (c) {
              if (!mounted) return;
              setState(() { _category = c; _query = ''; _searchCtrl.clear(); });
            },
            onSuggestionTap: (s) {
              if (!mounted) return;
              setState(() { _query = s; _searchCtrl.text = s; _category = 'All'; });
            },
            repo: _repo,
            scrollTrigger: _scrollTrigger,
            scrollToTopTrigger: _scrollToTopTrigger,
            onLoadingChanged: (loading) {
              if (mounted) {
                setState(() => _searchLoading = loading && _query.trim().isNotEmpty);
              }
            },
            showCategoryTiles: false,
            onMetaLoaded: (meta) {
              if (mounted) setState(() => _desktopMeta = meta);
            },
          ),
        ),
      ],
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
            _DesktopHeader(
              onLogoTap: _onLogoTap,
              logoTooltip: _logoTooltip,
              isSuperAdmin: isSuperAdmin,
              onQuickLink: (route) => _navigateQuickLink(ctx, route, isSuperAdmin),
              onLogout: () => UserState.read(ctx).signOut(),
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
          message: _logoTooltip,
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
        onTap: (i) => setState(() { _view = _AdminView.section; _index = i; }),
        items: nav.asMap().entries.map((e) {
          final i = e.key;
          final n = e.value;
          final hasBadge = i == 3 && _pendingBillsCount > 0;
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

// ── Desktop header ────────────────────────────────────────────────────────────
// Logo (context-aware) | Add Medicine | Suppliers | Customers | Bills🔴 |
// Quick Links | Logout

class _DesktopHeader extends StatelessWidget {
  final VoidCallback onLogoTap;
  final VoidCallback onLogout;
  final String logoTooltip;
  final bool isSuperAdmin;
  final ValueChanged<String> onQuickLink;
  final int pendingBillsCount;

  const _DesktopHeader({
    required this.onLogoTap,
    required this.onQuickLink,
    required this.onLogout,
    required this.isSuperAdmin,
    required this.logoTooltip,
    this.pendingBillsCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        boxShadow: [
          BoxShadow(color: Color(0x08000000), blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          // Logo — context-aware navigation
          Tooltip(
            message: logoTooltip,
            child: GestureDetector(
              onTap: onLogoTap,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  child: RichText(
                    text: const TextSpan(children: [
                      TextSpan(
                        text: 'mediBO',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1B7A43)),
                      ),
                    ]),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 20),
          Container(width: 1, height: 24, color: const Color(0xFFE5E7EB)),
          const SizedBox(width: 8),

          // ── Primary nav row
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _HdrBtn(
                  label: 'Add Medicine',
                  icon: Icons.medication_outlined,
                  onTap: () => onQuickLink('add_medicine'),
                ),
                _HdrBtn(
                  label: 'Suppliers',
                  icon: Icons.inventory_2_outlined,
                  onTap: () => onQuickLink('suppliers'),
                ),
                _HdrBtn(
                  label: 'Customers',
                  icon: Icons.people_outline,
                  onTap: () => onQuickLink('customers'),
                ),
                _BillsHdrBtn(
                  count: pendingBillsCount,
                  onTap: () => onQuickLink('bills'),
                ),
              ]),
            ),
          ),

          const SizedBox(width: 8),

          _QuickLinksButton(
            isSuperAdmin: isSuperAdmin,
            onSelected: onQuickLink,
          ),
          const SizedBox(width: 8),

          InkWell(
            onTap: onLogout,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFFECACA)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: const [
                Icon(Icons.logout, size: 14, color: Color(0xFFDC2626)),
                SizedBox(width: 5),
                Text('Logout',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFFDC2626))),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Admin search bar (homepage catalogue view) ────────────────────────────────

class _AdminSearchBar extends StatefulWidget {
  final TextEditingController controller;
  final bool isLoading;
  final ValueChanged<String> onSearch;
  final VoidCallback onScrollToResults;

  const _AdminSearchBar({
    required this.controller,
    required this.isLoading,
    required this.onSearch,
    required this.onScrollToResults,
  });

  @override
  State<_AdminSearchBar> createState() => _AdminSearchBarState();
}

class _AdminSearchBarState extends State<_AdminSearchBar> {
  Timer? _debounce;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChange);
    _hasText = widget.controller.text.isNotEmpty;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    _debounce?.cancel();
    super.dispose();
  }

  void _onControllerChange() {
    final hasText = widget.controller.text.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => widget.onSearch(v));
  }

  void _submitNow() {
    _debounce?.cancel();
    final text = widget.controller.text;
    widget.onSearch(text);
    if (text.trim().length >= 2) widget.onScrollToResults();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _clearSearch() {
    _debounce?.cancel();
    widget.controller.clear();
    widget.onSearch('');
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Icon(Icons.search, color: Color(0xFF9CA3AF), size: 20),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                onChanged: _onChanged,
                onSubmitted: (_) => _submitNow(),
                textInputAction: TextInputAction.search,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontSize: 14, color: Brand.ink),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: 'Search for medicines',
                  hintStyle: TextStyle(color: Brand.inkMuted, fontSize: 14),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 13),
                  filled: false,
                ),
              ),
            ),
            if (widget.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Brand.green),
                ),
              )
            else if (_hasText)
              IconButton(
                onPressed: _clearSearch,
                icon: const Icon(Icons.close, size: 18, color: Color(0xFF6B7280)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              )
            else
              GestureDetector(
                onTap: _submitNow,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: Icon(Icons.search, color: Color(0xFF9CA3AF), size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ── Admin category chips (homepage catalogue view) ────────────────────────────

class _AdminCategoryChips extends StatelessWidget {
  final CatalogMeta? meta;
  final String selected;
  final ValueChanged<String> onCategoryTap;

  const _AdminCategoryChips({
    required this.meta,
    required this.selected,
    required this.onCategoryTap,
  });

  @override
  Widget build(BuildContext context) {
    final m = meta;
    if (m == null) {
      return Container(
        color: Colors.white,
        height: 48,
        child: const Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: Brand.green),
          ),
        ),
      );
    }

    final cats = List<CategoryCount>.from(m.categories)
      ..sort((a, b) => b.count.compareTo(a.count));

    return Container(
      color: Colors.white,
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        itemCount: cats.length + 1,
        itemBuilder: (ctx, i) {
          final isAll = i == 0;
          final key = isAll ? 'All' : cats[i - 1].name;
          final label = isAll ? 'All' : prettyCategory(cats[i - 1].name);
          final style = isAll
              ? const CategoryStyle(Brand.mint, Brand.green, Icons.grid_view_rounded)
              : categoryStyle(key);
          final isSelected = selected == key;

          return Padding(
            padding: EdgeInsets.only(right: i < cats.length ? 8 : 0),
            child: GestureDetector(
              onTap: () => onCategoryTap(key),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                decoration: BoxDecoration(
                  color: isSelected ? style.fg : style.bg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(style.icon, size: 13,
                        color: isSelected ? Colors.white : style.fg),
                    const SizedBox(width: 5),
                    Text(label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isSelected ? Colors.white : style.fg,
                        )),
                  ],
                ),
              ),
            ),
          );
        },
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
