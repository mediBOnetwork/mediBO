import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/animations.dart';
import 'bulk_upload_screen.dart';
import 'cart_screen.dart';
import 'orders_screen.dart';
import 'storefront_screen.dart';

/// App shell: promo bar + mediBO header over the active page
/// (storefront / orders), with the cart as a right slide-in panel.
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
      bottomNavigationBar: isMobile
          ? BottomNavigationBar(
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
            )
          : null,
      body: Stack(
        children: [
          Column(
            children: [
              const _PromoBar(),
              _Header(
                controller: _searchCtrl,
                index: _index,
                isMobile: isMobile,
                onSearch: (v) => setState(() {
                  _query = v;
                  _category = 'All';
                  _index = 0;
                  _scrollTrigger++;
                }),
                onLogo: () => setState(() {
                  _index = 0;
                  _cartOpen = false;
                }),
                onCart: () => setState(() => _cartOpen = true),
                onOrders: () => setState(() => _index = 1),
                onBulk: () => setState(() => _index = 2),
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

class _PromoBar extends StatelessWidget {
  const _PromoBar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Brand.greenDark,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Row(
            children: [
              const Icon(Icons.local_shipping, color: Colors.white70, size: 14),
              const SizedBox(width: 6),
              const Flexible(
                child: Text(
                  'Free delivery on orders above ₹500  ·  24/7 customer support',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text('Use code HEALTH10 for 10% off',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final TextEditingController controller;
  final int index;
  final bool isMobile;
  final ValueChanged<String> onSearch;
  final VoidCallback onLogo;
  final VoidCallback onCart;
  final VoidCallback onOrders;
  final VoidCallback onBulk;

  const _Header({
    required this.controller,
    required this.index,
    required this.isMobile,
    required this.onSearch,
    required this.onLogo,
    required this.onCart,
    required this.onOrders,
    required this.onBulk,
  });

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Brand.border)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: LayoutBuilder(
              builder: (context, c) {
                final wide = c.maxWidth >= 860;
                final logo = _Logo(onTap: onLogo);
                final search =
                    _SearchField(controller: controller, onSearch: onSearch);
                final actions = _Actions(
                  cartUnits: cart.totalUnits,
                  cartTotal: cart.grandTotal,
                  ordersCount: cart.orders.length,
                  index: index,
                  onCart: onCart,
                  onOrders: onOrders,
                  onBulk: onBulk,
                );
                if (wide) {
                  return Row(
                    children: [
                      logo,
                      const SizedBox(width: 28),
                      Expanded(child: search),
                      const SizedBox(width: 20),
                      actions,
                    ],
                  );
                }
                return Column(
                  children: [
                    Row(children: [logo, const Spacer(), if (!isMobile) actions]),
                    const SizedBox(height: 10),
                    search,
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  final VoidCallback onTap;
  const _Logo({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressEffect(
      scale: 0.95,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Circular app logo: green circle with a white cross/plus
              Container(
                width: 40,
                height: 40,
                decoration: const BoxDecoration(
                  color: Brand.green,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add,
                    color: Colors.white, size: 26, weight: 700),
              ),
              const SizedBox(width: 10),
              // mediBO logo: "medi" regular dark + "BO" bold green
              RichText(
                text: const TextSpan(
                  children: [
                    TextSpan(
                      text: 'medi',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w500,
                        color: Brand.ink,
                        letterSpacing: -0.3,
                      ),
                    ),
                    TextSpan(
                      text: 'BO',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: Brand.green,
                        letterSpacing: -0.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Search field with a debounce so filtering only fires ~260ms after the user
/// stops typing. The Search button fires immediately.
class _SearchField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSearch;
  const _SearchField({required this.controller, required this.onSearch});

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
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
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: widget.controller,
            onChanged: _onChanged,
            onSubmitted: (_) => _submitNow(),
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              isDense: true,
              hintText: 'Search for medicines, brands & manufacturers…',
              prefixIcon: Icon(Icons.search, color: Brand.inkMuted),
            ),
          ),
        ),
        const SizedBox(width: 8),
        PressEffect(
          child: FilledButton(
            onPressed: _submitNow,
            child: const Text('Search'),
          ),
        ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  final int cartUnits;
  final double cartTotal;
  final int ordersCount;
  final int index;
  final VoidCallback onCart;
  final VoidCallback onOrders;
  final VoidCallback onBulk;

  const _Actions({
    required this.cartUnits,
    required this.cartTotal,
    required this.ordersCount,
    required this.index,
    required this.onCart,
    required this.onOrders,
    required this.onBulk,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PressEffect(
          child: TextButton.icon(
            onPressed: onOrders,
            style: TextButton.styleFrom(
              foregroundColor: index == 1 ? Brand.green : Brand.ink,
            ),
            icon: Badge(
              isLabelVisible: ordersCount > 0,
              label: Text('$ordersCount'),
              child: const Icon(Icons.receipt_long_outlined, size: 20),
            ),
            label: const Text('Orders'),
          ),
        ),
        const SizedBox(width: 4),
        PressEffect(
          child: TextButton.icon(
            onPressed: onBulk,
            style: TextButton.styleFrom(
              foregroundColor: index == 2 ? Brand.green : Brand.ink,
            ),
            icon: const Icon(Icons.upload_file_outlined, size: 20),
            label: const Text('Bulk'),
          ),
        ),
        const SizedBox(width: 8),
        _CartButton(units: cartUnits, total: cartTotal, onTap: onCart),
      ],
    );
  }
}

/// Cart button that pulses (scale bounce) whenever the item count increases —
/// the "added to cart" feedback.
class _CartButton extends StatefulWidget {
  final int units;
  final double total;
  final VoidCallback onTap;
  const _CartButton(
      {required this.units, required this.total, required this.onTap});

  @override
  State<_CartButton> createState() => _CartButtonState();
}

class _CartButtonState extends State<_CartButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
        tween: Tween(begin: 1.0, end: 1.18)
            .chain(CurveTween(curve: Curves.easeOut)),
        weight: 50),
    TweenSequenceItem(
        tween: Tween(begin: 1.18, end: 1.0)
            .chain(CurveTween(curve: Curves.easeIn)),
        weight: 50),
  ]).animate(_c);

  @override
  void didUpdateWidget(_CartButton old) {
    super.didUpdateWidget(old);
    if (widget.units > old.units) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: PressEffect(
        child: FilledButton.icon(
          onPressed: widget.onTap,
          icon: Badge(
            isLabelVisible: widget.units > 0,
            label: Text('${widget.units}'),
            child: const Icon(Icons.shopping_cart_outlined, size: 20),
          ),
          label: Text(widget.units > 0 ? rupees(widget.total) : 'Cart'),
        ),
      ),
    );
  }
}

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
          // Force CartScreen into its narrow (single-column) layout regardless
          // of the full screen width.
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
