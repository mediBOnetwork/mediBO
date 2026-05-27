import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../theme.dart';
import '../widgets/animations.dart';
import 'bulk_upload_screen.dart';
import 'cart_screen.dart';
import 'orders_screen.dart';
import 'storefront_screen.dart';

/// App shell: 1mg-style header (location + logo + cart), full-width search bar,
/// horizontal quick-nav chips, the active page, and a persistent bottom promo bar.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final MedicineRepository _repo = MedicineRepository();
  final TextEditingController _searchCtrl = TextEditingController();

  int _index = 0; // 0 = storefront, 1 = orders, 2 = bulk upload
  String _query = '';
  String _category = 'All';
  bool _cartOpen = false;
  int _scrollTrigger = 0;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _selectCategory(String c) => setState(() {
        _category = c;
        _query = '';
        _searchCtrl.clear();
        _index = 0;
        _cartOpen = false;
      });

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final cart = AppState.of(context);

    final pages = [
      StorefrontScreen(
        query: _query,
        category: _category,
        onCategorySelected: _selectCategory,
        onSuggestionTap: (s) => setState(() {
          _query = s;
          _searchCtrl.text = s;
          _category = 'All';
          _index = 0;
        }),
        repo: _repo,
        scrollTrigger: _scrollTrigger,
      ),
      const OrdersScreen(),
      const BulkUploadScreen(),
    ];

    final bottomNavIndex =
        _cartOpen ? 2 : _index == 1 ? 3 : _index == 2 ? 4 : 0;

    return Scaffold(
      backgroundColor: Colors.white,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _BottomPromoBar(),
          if (isMobile)
            BottomNavigationBar(
              currentIndex: bottomNavIndex,
              type: BottomNavigationBarType.fixed,
              selectedItemColor: Brand.green,
              unselectedItemColor: Brand.inkMuted,
              selectedFontSize: 10,
              unselectedFontSize: 10,
              elevation: 8,
              onTap: (i) => setState(() {
                switch (i) {
                  case 0:
                  case 1:
                    _index = 0;
                    _cartOpen = false;
                  case 2:
                    _cartOpen = true;
                  case 3:
                    _index = 1;
                    _cartOpen = false;
                  case 4:
                    _index = 2;
                    _cartOpen = false;
                }
              }),
              items: [
                const BottomNavigationBarItem(
                  icon: Icon(Icons.home_outlined),
                  activeIcon: Icon(Icons.home),
                  label: 'Home',
                ),
                const BottomNavigationBarItem(
                  icon: Icon(Icons.grid_view_outlined),
                  activeIcon: Icon(Icons.grid_view),
                  label: 'Catalogue',
                ),
                BottomNavigationBarItem(
                  icon: Badge(
                    isLabelVisible: cart.totalUnits > 0,
                    label: Text('${cart.totalUnits}'),
                    child: const Icon(Icons.shopping_cart_outlined),
                  ),
                  activeIcon: Badge(
                    isLabelVisible: cart.totalUnits > 0,
                    label: Text('${cart.totalUnits}'),
                    child: const Icon(Icons.shopping_cart),
                  ),
                  label: 'Cart',
                ),
                BottomNavigationBarItem(
                  icon: Badge(
                    isLabelVisible: cart.orders.isNotEmpty,
                    label: Text('${cart.orders.length}'),
                    child: const Icon(Icons.receipt_long_outlined),
                  ),
                  activeIcon: Badge(
                    isLabelVisible: cart.orders.isNotEmpty,
                    label: Text('${cart.orders.length}'),
                    child: const Icon(Icons.receipt_long),
                  ),
                  label: 'Orders',
                ),
                const BottomNavigationBarItem(
                  icon: Icon(Icons.upload_file_outlined),
                  activeIcon: Icon(Icons.upload_file),
                  label: 'Bulk',
                ),
              ],
            ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              _LocationHeader(
                cartUnits: cart.totalUnits,
                onCart: () => setState(() => _cartOpen = true),
              ),
              _SearchBarRow(
                controller: _searchCtrl,
                onSearch: (v) => setState(() {
                  _query = v;
                  _category = 'All';
                  _index = 0;
                }),
                onScrollToResults: () => setState(() => _scrollTrigger++),
              ),
              _QuickNavRow(
                index: _index,
                cartOpen: _cartOpen,
                onPharmacy: () => setState(() {
                  _index = 0;
                  _cartOpen = false;
                }),
                onCatalogue: () => setState(() {
                  _index = 0;
                  _cartOpen = false;
                }),
                onOrders: () => setState(() {
                  _index = 1;
                  _cartOpen = false;
                }),
                onBulk: () => setState(() {
                  _index = 2;
                  _cartOpen = false;
                }),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0.03, 0),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(_index),
                    child: pages[_index],
                  ),
                ),
              ),
            ],
          ),
          CartPanel(
            open: _cartOpen,
            onClose: () => setState(() => _cartOpen = false),
            onOrderPlaced: () => setState(() {
              _cartOpen = false;
              _index = 1;
            }),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Location header ───────────────────────

/// Top row: location pin + "Raipur" + dropdown (left) ·
/// mediBO wordmark (centre) · cart icon with badge (right).
class _LocationHeader extends StatelessWidget {
  final int cartUnits;
  final VoidCallback onCart;
  const _LocationHeader({required this.cartUnits, required this.onCart});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Brand.border)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          // Location selector (visual only — location picker is out of scope)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.location_on, color: Brand.green, size: 20),
              SizedBox(width: 4),
              Text(
                'Raipur',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Brand.ink,
                ),
              ),
              Icon(Icons.keyboard_arrow_down,
                  color: Brand.inkMuted, size: 18),
            ],
          ),
          const Spacer(),
          // mediBO wordmark
          RichText(
            text: const TextSpan(
              children: [
                TextSpan(
                  text: 'medi',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: Brand.ink,
                    letterSpacing: -0.3,
                  ),
                ),
                TextSpan(
                  text: 'BO',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Brand.green,
                    letterSpacing: -0.3,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          // Cart icon with item count badge
          PressEffect(
            child: InkWell(
              onTap: onCart,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Badge(
                  isLabelVisible: cartUnits > 0,
                  label: Text(
                    '$cartUnits',
                    style: const TextStyle(fontSize: 10),
                  ),
                  child: const Icon(
                    Icons.shopping_cart_outlined,
                    size: 26,
                    color: Brand.ink,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Full-width search bar ───────────────────────

/// Full-width search bar: single rounded container holding a search icon,
/// the text field, and an integrated green "Search" button.
/// Fires [onSearch] for every debounced keystroke; fires [onScrollToResults]
/// only on explicit submit (button tap or Enter key).
class _SearchBarRow extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSearch;
  final VoidCallback onScrollToResults;

  const _SearchBarRow({
    required this.controller,
    required this.onSearch,
    required this.onScrollToResults,
  });

  @override
  State<_SearchBarRow> createState() => _SearchBarRowState();
}

class _SearchBarRowState extends State<_SearchBarRow> {
  final FocusNode _focus = FocusNode();
  bool _focused = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _focused = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      widget.onSearch(v);
    });
  }

  void _submitNow() {
    _debounce?.cancel();
    widget.onSearch(widget.controller.text);
    widget.onScrollToResults();
    _focus.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: Brand.field,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _focused ? Brand.green : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.search, color: Brand.inkMuted, size: 20),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                onChanged: _onChanged,
                onSubmitted: (_) => _submitNow(),
                textInputAction: TextInputAction.search,
                style: const TextStyle(fontSize: 14, color: Brand.ink),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Search for medicines, brands & manufacturers…',
                  hintStyle: TextStyle(color: Brand.inkMuted, fontSize: 14),
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(vertical: 13),
                  filled: false,
                ),
              ),
            ),
            GestureDetector(
              onTap: _submitNow,
              child: Container(
                margin: const EdgeInsets.all(5),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                decoration: BoxDecoration(
                  color: Brand.green,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Search',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Quick-nav chips ───────────────────────

/// Horizontally scrollable row of coloured nav cards:
/// Pharmacy · Catalogue · Bulk Order · Orders.
class _QuickNavRow extends StatelessWidget {
  final int index;
  final bool cartOpen;
  final VoidCallback onPharmacy;
  final VoidCallback onCatalogue;
  final VoidCallback onOrders;
  final VoidCallback onBulk;

  const _QuickNavRow({
    required this.index,
    required this.cartOpen,
    required this.onPharmacy,
    required this.onCatalogue,
    required this.onOrders,
    required this.onBulk,
  });

  @override
  Widget build(BuildContext context) {
    final isHome = index == 0 && !cartOpen;
    return Container(
      width: double.infinity,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 14),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _NavChip(
              icon: Icons.local_pharmacy,
              label: 'Pharmacy',
              bg: Brand.mint,
              fg: Brand.green,
              selected: isHome,
              onTap: onPharmacy,
            ),
            _NavChip(
              icon: Icons.grid_view_rounded,
              label: 'Catalogue',
              bg: const Color(0xFFE8F1FF),
              fg: const Color(0xFF2563EB),
              selected: false,
              onTap: onCatalogue,
            ),
            _NavChip(
              icon: Icons.upload_file_outlined,
              label: 'Bulk Order',
              bg: const Color(0xFFFFF1E6),
              fg: const Color(0xFFEA7317),
              selected: index == 2 && !cartOpen,
              onTap: onBulk,
            ),
            _NavChip(
              icon: Icons.receipt_long_outlined,
              label: 'Orders',
              bg: const Color(0xFFECEBFF),
              fg: const Color(0xFF4F46E5),
              selected: index == 1 && !cartOpen,
              onTap: onOrders,
            ),
          ],
        ),
      ),
    );
  }
}

class _NavChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;
  final bool selected;
  final VoidCallback onTap;

  const _NavChip({
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: PressEffect(
        scale: 0.93,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 78,
            padding:
                const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            decoration: BoxDecoration(
              color: selected ? fg.withValues(alpha: 0.10) : bg,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? fg : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 26, color: fg),
                const SizedBox(height: 5),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: fg,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Bottom promo bar ───────────────────────

/// Persistent green strip shown above the bottom navigation bar on all sizes.
class _BottomPromoBar extends StatelessWidget {
  const _BottomPromoBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Brand.green,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(Icons.local_offer, color: Colors.white, size: 14),
          SizedBox(width: 6),
          Text(
            'Get 10% off on first order',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          SizedBox(width: 8),
          Text(
            '· Use code HEALTH10',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Cart panel ───────────────────────

/// Right-edge slide-in cart sheet with a fading scrim. Driven by an explicit
/// AnimationController so the panel + scrim move together.
class CartPanel extends StatefulWidget {
  final bool open;
  final VoidCallback onClose;
  final VoidCallback onOrderPlaced;
  const CartPanel({
    super.key,
    required this.open,
    required this.onClose,
    required this.onOrderPlaced,
  });

  @override
  State<CartPanel> createState() => _CartPanelState();
}

class _CartPanelState extends State<CartPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
    reverseDuration: const Duration(milliseconds: 240),
    value: widget.open ? 1 : 0,
  );
  late final Animation<double> _t = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didUpdateWidget(CartPanel old) {
    super.didUpdateWidget(old);
    if (widget.open && !old.open) _c.forward();
    if (!widget.open && old.open) _c.reverse();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.sizeOf(context).width;
    final panelW = screenW < 520 ? screenW : 420.0;

    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        final t = _t.value;
        if (t == 0) return const SizedBox.shrink();
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: widget.onClose,
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45 * t),
                ),
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: panelW,
              child: Transform.translate(
                offset: Offset(panelW * (1 - t), 0),
                child: Material(
                  elevation: 16,
                  color: Colors.white,
                  child: _CartPanelContent(
                    width: panelW,
                    onClose: widget.onClose,
                    onOrderPlaced: widget.onOrderPlaced,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CartPanelContent extends StatelessWidget {
  final double width;
  final VoidCallback onClose;
  final VoidCallback onOrderPlaced;
  const _CartPanelContent({
    required this.width,
    required this.onClose,
    required this.onOrderPlaced,
  });

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final mq = MediaQuery.of(context);
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.shopping_cart, color: Brand.green, size: 22),
                const SizedBox(width: 10),
                const Text('Your Order',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Text('${cart.totalUnits} packs',
                    style: const TextStyle(
                        fontSize: 13, color: Brand.inkMuted)),
                const Spacer(),
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close),
                  tooltip: 'Close',
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: MediaQuery(
              data: mq.copyWith(size: Size(width, mq.size.height)),
              child: CartScreen(onOrderPlaced: onOrderPlaced),
            ),
          ),
        ],
      ),
    );
  }
}
