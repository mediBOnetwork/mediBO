import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../models/cart_model.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/animations.dart';
import 'bulk_upload_screen.dart';
import 'cart_screen.dart';
import 'orders_screen.dart';
import 'storefront_screen.dart';

/// App shell: responsive — desktop gets a top nav + sidebar, mobile/tablet
/// keeps the existing header + quick-nav chips + bottom nav layout.
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
  int _scrollToTopTrigger = 0;
  bool _searchLoading = false;

  // Cart milestone celebrations
  CartModel? _cartModel;
  double _prevSubtotal = 0;
  bool _celebrateDelivery = false;
  bool _celebrate3pct = false;
  Timer? _deliveryTimer;
  Timer? _discountTimer;

  // Desktop sidebar: populated once storefront loads its CatalogMeta
  CatalogMeta? _desktopMeta;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final cart = AppState.of(context);
    if (_cartModel != cart) {
      _cartModel?.removeListener(_onCartChanged);
      _cartModel = cart;
      cart.addListener(_onCartChanged);
    }
  }

  void _onCartChanged() {
    if (!mounted) return;
    final sub = _cartModel!.subtotal;
    if (_prevSubtotal < 999 && sub >= 999) {
      setState(() => _celebrateDelivery = true);
      _deliveryTimer?.cancel();
      _deliveryTimer = Timer(const Duration(seconds: 10), () {
        if (mounted) setState(() => _celebrateDelivery = false);
      });
    }
    if (_prevSubtotal < 2999 && sub >= 2999) {
      setState(() => _celebrate3pct = true);
      _discountTimer?.cancel();
      _discountTimer = Timer(const Duration(seconds: 10), () {
        if (mounted) setState(() => _celebrate3pct = false);
      });
    }
    _prevSubtotal = sub;
  }

  void _onMetaLoaded(CatalogMeta meta) {
    if (mounted) setState(() => _desktopMeta = meta);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _cartModel?.removeListener(_onCartChanged);
    _deliveryTimer?.cancel();
    _discountTimer?.cancel();
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
    final width = MediaQuery.sizeOf(context).width;
    final isDesktop = width >= 900;
    final cart = AppState.of(context);

    // IndexedStack keeps all screen States alive — no re-fetch on tab switch.
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
        scrollToTopTrigger: _scrollToTopTrigger,
        onLoadingChanged: (loading) {
          if (mounted) {
            setState(() => _searchLoading = loading && _query.trim().isNotEmpty);
          }
        },
        showCategoryTiles: !isDesktop,
        onMetaLoaded: _onMetaLoaded,
      ),
      const OrdersScreen(),
      const BulkUploadScreen(),
    ];

    if (isDesktop) return _buildDesktop(cart, pages);
    return _buildMobile(cart, pages);
  }

  // ─── Mobile / tablet layout (< 900px) ────────────────────────────────────

  Widget _buildMobile(CartModel cart, List<Widget> pages) {
    // 4-item nav: 0=Home, 1=Catalogue, 2=Orders, 3=Bulk
    final bottomNavIndex = _index == 1 ? 2 : _index == 2 ? 3 : 0;

    return Scaffold(
      backgroundColor: Colors.white,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 550),
            reverseDuration: const Duration(milliseconds: 300),
            transitionBuilder: (child, anim) => SizeTransition(
              sizeFactor: CurvedAnimation(
                parent: anim,
                curve: Curves.easeOutBack,
                reverseCurve: Curves.easeIn,
              ),
              axisAlignment: 1.0,
              child: child,
            ),
            child: _celebrateDelivery
                ? _CelebrationBanner(
                    key: const ValueKey('delivery'),
                    message: '🎉 Awesome! You unlocked FREE delivery!',
                    bgColor: const Color(0xFF15803D),
                    textColor: Colors.white,
                  )
                : const SizedBox.shrink(key: ValueKey('delivery-empty')),
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 550),
            reverseDuration: const Duration(milliseconds: 300),
            transitionBuilder: (child, anim) => SizeTransition(
              sizeFactor: CurvedAnimation(
                parent: anim,
                curve: Curves.easeOutBack,
                reverseCurve: Curves.easeIn,
              ),
              axisAlignment: 1.0,
              child: child,
            ),
            child: _celebrate3pct
                ? _CelebrationBanner(
                    key: const ValueKey('3pct'),
                    message: '🎉 Congratulations! You unlocked 3% discount!',
                    bgColor: const Color(0xFFF59E0B),
                    textColor: const Color(0xFF1C1917),
                  )
                : const SizedBox.shrink(key: ValueKey('3pct-empty')),
          ),
          if (cart.distinctItems > 0)
            RepaintBoundary(
              child: _StickyCartBar(
                onTap: () => setState(() => _cartOpen = true),
              ),
            ),
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
                  _index = 1;
                  _cartOpen = false;
                case 3:
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
                cartItems: cart.distinctItems,
                onCart: () => setState(() => _cartOpen = true),
              ),
              _SearchBarRow(
                controller: _searchCtrl,
                isLoading: _searchLoading,
                onSearch: (v) => setState(() {
                  final q = v.trim();
                  _category = 'All';
                  _index = 0;
                  if (q.length >= 2) {
                    _query = v;
                  } else {
                    _query = '';
                    _scrollToTopTrigger++;
                  }
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
                child: IndexedStack(
                  index: _index,
                  children: pages,
                ),
              ),
            ],
          ),
          RepaintBoundary(
            child: CartPanel(
              open: _cartOpen,
              onClose: () => setState(() => _cartOpen = false),
              onOrderPlaced: () => setState(() {
                _cartOpen = false;
                _index = 1;
              }),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Desktop layout (≥ 900px) ────────────────────────────────────────────

  Widget _buildDesktop(CartModel cart, List<Widget> pages) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Column(
            children: [
              _DesktopTopBar(
                index: _index,
                cartItems: cart.distinctItems,
                searchCtrl: _searchCtrl,
                isLoading: _searchLoading,
                onSearch: (v) => setState(() {
                  final q = v.trim();
                  _category = 'All';
                  _index = 0;
                  if (q.length >= 2) {
                    _query = v;
                  } else {
                    _query = '';
                    _scrollToTopTrigger++;
                  }
                }),
                onScrollToResults: () => setState(() => _scrollTrigger++),
                onHome: () => setState(() {
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
                onCart: () => setState(() => _cartOpen = true),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 550),
                reverseDuration: const Duration(milliseconds: 300),
                transitionBuilder: (child, anim) => SizeTransition(
                  sizeFactor: CurvedAnimation(
                    parent: anim,
                    curve: Curves.easeOutBack,
                    reverseCurve: Curves.easeIn,
                  ),
                  axisAlignment: -1.0,
                  child: child,
                ),
                child: _celebrateDelivery
                    ? _CelebrationBanner(
                        key: const ValueKey('delivery'),
                        message: '🎉 Awesome! You unlocked FREE delivery!',
                        bgColor: const Color(0xFF15803D),
                        textColor: Colors.white,
                      )
                    : const SizedBox.shrink(key: ValueKey('delivery-empty')),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 550),
                reverseDuration: const Duration(milliseconds: 300),
                transitionBuilder: (child, anim) => SizeTransition(
                  sizeFactor: CurvedAnimation(
                    parent: anim,
                    curve: Curves.easeOutBack,
                    reverseCurve: Curves.easeIn,
                  ),
                  axisAlignment: -1.0,
                  child: child,
                ),
                child: _celebrate3pct
                    ? _CelebrationBanner(
                        key: const ValueKey('3pct'),
                        message: '🎉 Congratulations! You unlocked 3% discount!',
                        bgColor: const Color(0xFFF59E0B),
                        textColor: const Color(0xFF1C1917),
                      )
                    : const SizedBox.shrink(key: ValueKey('3pct-empty')),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DesktopSidebar(
                      meta: _desktopMeta,
                      selected: _category,
                      onSelected: _selectCategory,
                    ),
                    Expanded(
                      child: IndexedStack(
                        index: _index,
                        children: pages,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          RepaintBoundary(
            child: CartPanel(
              open: _cartOpen,
              onClose: () => setState(() => _cartOpen = false),
              onOrderPlaced: () => setState(() {
                _cartOpen = false;
                _index = 1;
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Location header ───────────────────────

class _LocationHeader extends StatelessWidget {
  final int cartItems;
  final VoidCallback onCart;
  const _LocationHeader({required this.cartItems, required this.onCart});

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
          PressEffect(
            child: InkWell(
              onTap: onCart,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Badge(
                  isLabelVisible: cartItems > 0,
                  label: Text(
                    '$cartItems',
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

class _SearchBarRow extends StatefulWidget {
  final TextEditingController controller;
  final bool isLoading;
  final ValueChanged<String> onSearch;
  final VoidCallback onScrollToResults;

  const _SearchBarRow({
    required this.controller,
    required this.isLoading,
    required this.onSearch,
    required this.onScrollToResults,
  });

  @override
  State<_SearchBarRow> createState() => _SearchBarRowState();
}

class _SearchBarRowState extends State<_SearchBarRow> {
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
    _debounce = Timer(const Duration(milliseconds: 300), () {
      widget.onSearch(v);
    });
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.search, color: Color(0xFF9CA3AF), size: 20),
            ),
            Expanded(
              child: TextField(
                controller: widget.controller,
                onChanged: _onChanged,
                onSubmitted: (_) => _submitNow(),
                textInputAction: TextInputAction.search,
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
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Brand.green,
                  ),
                ),
              )
            else if (_hasText)
              IconButton(
                onPressed: _clearSearch,
                icon: const Icon(Icons.close,
                    size: 20, color: Color(0xFF6B7280)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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

// ─────────────────────── Celebration banner ───────────────────────

class _CelebrationBanner extends StatelessWidget {
  final String message;
  final Color bgColor;
  final Color textColor;
  const _CelebrationBanner({
    super.key,
    required this.message,
    required this.bgColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: bgColor,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: textColor,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ─────────────────────── Cart panel ───────────────────────

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
          // Cart panel header: ← Cart · search icon
          Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFF3F4F6))),
            ),
            padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
            child: Row(
              children: [
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.arrow_back_ios_new,
                      size: 18, color: Color(0xFF111827)),
                  tooltip: 'Close cart',
                ),
                const Expanded(
                  child: Text(
                    'Cart',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF111827),
                    ),
                  ),
                ),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: const Icon(Icons.search,
                      size: 18, color: Color(0xFF374151)),
                ),
                const SizedBox(width: 4),
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

// ─────────────────────── Sticky cart bar (mobile) ───────────────────────

/// Blinkit-style dark-navy bar above the bottom nav on mobile.
/// Slides up on first appearance; cart chip pulses when item count changes.
/// Progress tiers: <₹999 free delivery (blue), ₹999–₹2999 3% (amber),
/// ₹2999–₹6999 5% (amber), ₹6999+ max unlocked (green).
class _StickyCartBar extends StatefulWidget {
  final VoidCallback onTap;
  const _StickyCartBar({required this.onTap});

  @override
  State<_StickyCartBar> createState() => _StickyCartBarState();
}

class _StickyCartBarState extends State<_StickyCartBar>
    with TickerProviderStateMixin {
  static const _navy = Color(0xFF1B2B8C);
  static const _blue = Color(0xFF2563EB);
  static const _amber = Color(0xFFFBBF24);
  static const _freeThreshold = 999.0;
  static const _tier3pct = 2999.0;
  static const _tier5pct = 6999.0;

  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slideAnim;
  late final AnimationController _pulseCtrl;
  late final Animation<double> _pulseAnim;
  int _prevUniqueItems = 0;

  @override
  void initState() {
    super.initState();

    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 550),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideCtrl,
      curve: Curves.elasticOut,
    ));
    _slideCtrl.forward();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _pulseAnim = TweenSequence<double>([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 1.35), weight: 30),
      TweenSequenceItem(
          tween: Tween(begin: 1.35, end: 0.88), weight: 30),
      TweenSequenceItem(
          tween: Tween(begin: 0.88, end: 1.0)
              .chain(CurveTween(curve: Curves.elasticOut)),
          weight: 40),
    ]).animate(_pulseCtrl);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final uniqueItems = AppState.of(context).distinctItems;
    if (uniqueItems != _prevUniqueItems && _prevUniqueItems > 0) {
      _pulseCtrl.forward(from: 0);
    }
    _prevUniqueItems = uniqueItems;
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final total = cart.subtotal;
    final uniqueItems = cart.distinctItems;

    final bool unlocked = total >= _tier5pct;

    final double progress;
    final Color barColor;
    final Widget leftContent;

    if (total >= _tier5pct) {
      progress = 1.0;
      barColor = Colors.white;
      leftContent = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('🎉', style: TextStyle(fontSize: 13)),
          SizedBox(width: 5),
          Flexible(
            child: Text(
              'Max discount unlocked!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else if (total >= _tier3pct) {
      progress = (total - _tier3pct) / (_tier5pct - _tier3pct);
      barColor = _amber;
      final remaining = (_tier5pct - total).ceil();
      leftContent = _DiscountText(
          amount: '₹$remaining', suffix: ' more to get 5% off');
    } else if (total >= _freeThreshold) {
      progress = (total - _freeThreshold) / (_tier3pct - _freeThreshold);
      barColor = _amber;
      final remaining = (_tier3pct - total).ceil();
      leftContent = _DiscountText(
          amount: '₹$remaining', suffix: ' more to get 3% off');
    } else {
      progress = total > 0 ? total / _freeThreshold : 0.0;
      barColor = _blue;
      final remaining = (_freeThreshold - total).ceil();
      leftContent = _DiscountText(
          amount: '₹$remaining', suffix: ' more for FREE delivery');
    }

    return SlideTransition(
      position: _slideAnim,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: unlocked ? const Color(0xFF15803D) : _navy,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 10, 0),
                  child: Row(
                    children: [
                      Expanded(child: leftContent),
                      ScaleTransition(
                        scale: _pulseAnim,
                        child: _CartChip(uniqueItems: uniqueItems),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: LayoutBuilder(
                  builder: (_, constraints) => Stack(
                    children: [
                      Container(
                        height: 4,
                        width: constraints.maxWidth,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.20),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOut,
                        height: 4,
                        width: constraints.maxWidth *
                            progress.clamp(0.0, 1.0),
                        decoration: BoxDecoration(
                          color: barColor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DiscountText extends StatelessWidget {
  final String amount;
  final String suffix;
  const _DiscountText({required this.amount, required this.suffix});

  @override
  Widget build(BuildContext context) {
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white),
        children: [
          const TextSpan(text: 'Add '),
          TextSpan(
            text: amount,
            style: const TextStyle(
              color: Color(0xFFFBBF24),
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: suffix),
        ],
      ),
    );
  }
}

class _CartChip extends StatelessWidget {
  final int uniqueItems;
  const _CartChip({required this.uniqueItems});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: Colors.white.withValues(alpha: 0.25), width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.shopping_cart,
                  color: Colors.white, size: 13),
              const SizedBox(width: 5),
              Text(
                '$uniqueItems item${uniqueItems == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 2),
        const Icon(Icons.chevron_right, color: Colors.white, size: 20),
      ],
    );
  }
}

// ─────────────────────── Desktop top bar ───────────────────────

class _DesktopTopBar extends StatelessWidget {
  final int index;
  final int cartItems;
  final TextEditingController searchCtrl;
  final bool isLoading;
  final ValueChanged<String> onSearch;
  final VoidCallback onScrollToResults;
  final VoidCallback onHome;
  final VoidCallback onCatalogue;
  final VoidCallback onOrders;
  final VoidCallback onBulk;
  final VoidCallback onCart;

  const _DesktopTopBar({
    required this.index,
    required this.cartItems,
    required this.searchCtrl,
    required this.isLoading,
    required this.onSearch,
    required this.onScrollToResults,
    required this.onHome,
    required this.onCatalogue,
    required this.onOrders,
    required this.onBulk,
    required this.onCart,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Brand.border)),
        boxShadow: [
          BoxShadow(
              color: Color(0x08000000), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          GestureDetector(
            onTap: onHome,
            child: RichText(
              text: const TextSpan(
                children: [
                  TextSpan(
                    text: 'medi',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w500,
                      color: Brand.ink,
                      letterSpacing: -0.3,
                    ),
                  ),
                  TextSpan(
                    text: 'BO',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: Brand.green,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: _SearchBarRow(
              controller: searchCtrl,
              isLoading: isLoading,
              onSearch: onSearch,
              onScrollToResults: onScrollToResults,
            ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DesktopNavItem(
                icon: Icons.home_outlined,
                label: 'Home',
                selected: index == 0,
                onTap: onHome,
              ),
              _DesktopNavItem(
                icon: Icons.grid_view_outlined,
                label: 'Catalogue',
                selected: false,
                onTap: onCatalogue,
              ),
              _DesktopNavItem(
                icon: Icons.receipt_long_outlined,
                label: 'Orders',
                selected: index == 1,
                onTap: onOrders,
              ),
              _DesktopNavItem(
                icon: Icons.upload_file_outlined,
                label: 'Bulk',
                selected: index == 2,
                onTap: onBulk,
              ),
            ],
          ),
          const SizedBox(width: 12),
          PressEffect(
            child: InkWell(
              onTap: onCart,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Badge(
                  isLabelVisible: cartItems > 0,
                  label: Text(
                    '$cartItems',
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

class _DesktopNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _DesktopNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 17,
              color: selected ? Brand.green : Brand.inkMuted,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Brand.green : Brand.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Desktop sidebar ───────────────────────

class _DesktopSidebar extends StatelessWidget {
  final CatalogMeta? meta;
  final String selected;
  final ValueChanged<String> onSelected;

  const _DesktopSidebar({
    required this.meta,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Brand.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text(
              'CATEGORIES',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: Brand.inkMuted,
                letterSpacing: 0.8,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: _buildItems(),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildItems() {
    final m = meta;
    if (m == null) {
      return List.generate(
        9,
        (_) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      );
    }
    return [
      _DesktopCategoryItem(
        name: 'All',
        count: m.total,
        selected: selected == 'All',
        style: const CategoryStyle(Brand.mint, Brand.green, Icons.grid_view_rounded),
        onTap: () => onSelected('All'),
      ),
      for (final cat in m.categories)
        _DesktopCategoryItem(
          name: cat.name,
          count: cat.count,
          selected: selected == cat.name,
          style: categoryStyle(cat.name),
          onTap: () => onSelected(cat.name),
        ),
    ];
  }
}

class _DesktopCategoryItem extends StatelessWidget {
  final String name;
  final int count;
  final bool selected;
  final CategoryStyle style;
  final VoidCallback onTap;

  const _DesktopCategoryItem({
    required this.name,
    required this.count,
    required this.selected,
    required this.style,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? style.bg : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? style.fg.withValues(alpha: 0.35) : Colors.transparent,
            width: 1.5,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: style.bg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(style.icon, size: 15, color: style.fg),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                name == 'All' ? 'All Products' : prettyCategory(name),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? style.fg : Brand.ink,
                  height: 1.2,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: selected ? style.fg : const Color(0xFFE5E7EB),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : Brand.inkMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
