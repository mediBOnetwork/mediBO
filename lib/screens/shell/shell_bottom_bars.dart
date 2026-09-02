part of '../home_shell.dart';

// CHANGE #327 · LAYER 1 — sharded out of home_shell.dart.
//
// The bars that live at the bottom of the viewport: the mobile nav bar, the sticky cart bar and its desktop floating twin.
//
// It is a `part`, not a new library, on purpose: nearly every widget in
// the shell is library-private and used by the others, so extracting them
// into real libraries would force ~40 classes public and rewrite every
// reference. A part shares the library's imports and its privacy scope, so
// this is a pure move — and it gives this concern its own leasable path, so
// a cart command and a login command stop fighting over one file.
class _MobileBottomBar extends StatelessWidget {
  final int index;
  final bool cartOpen;
  final VoidCallback onCartTap;
  final ValueChanged<int> onNavTap;

  /// CHANGE #536 QA round 2 — whether the My Shop slot is offered at all.
  ///
  /// Round 1 gated the DESKTOP header on `isAuthenticated && !isAdmin` and its
  /// comment claimed the mobile bar already used that rule. It did not: the bar
  /// was picked on `isAdmin` alone, so a SIGNED-OUT visitor was shown a My Shop
  /// tab whose RPC anon holds no EXECUTE on (`customer_shop_home` returns 42501
  /// permission denied), and tapping it painted an empty page with no message
  /// and no way back. One rule, one place, both layouts.
  final bool showMyShop;

  const _MobileBottomBar({
    required this.index,
    required this.cartOpen,
    required this.onCartTap,
    required this.onNavTap,
    required this.showMyShop,
  });

  /// The page each slot opens, in slot order — the single source of truth the
  /// bar draws from and the shell navigates by, so the two can never drift.
  /// Page 0 is Home, 11 My Shop, 1 Orders, 2 Bulk; slot 1 (Catalogue) opens
  /// Home, exactly as it did before this change.
  static List<int> pagesFor(bool showMyShop) =>
      showMyShop ? const [0, 0, 11, 1, 2] : const [0, 0, 1, 2];

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    // CHANGE #536 — five slots for a signed-in shop: Home, Catalogue, My Shop,
    // Orders, Bulk; four for everyone else. The slot a page highlights is read
    // out of the SAME list the shell navigates by, so hiding My Shop cannot
    // leave a page pointing at a slot that no longer exists (a hidden page 11
    // finds no slot and falls back to Home).
    final slots = pagesFor(showMyShop);
    final found = slots.indexOf(index);
    final bottomNavIndex = found < 0 ? 0 : found;
    return BottomNavigationBar(
      currentIndex: bottomNavIndex,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: Brand.green,
      unselectedItemColor: Brand.inkMuted,
      selectedFontSize: 10,
      unselectedFontSize: 10,
      elevation: 8,
      onTap: onNavTap,
      items: [
        BottomNavigationBarItem(
          icon: const Icon(Icons.home_outlined),
          activeIcon: const Icon(Icons.home),
          label: c('home_shell.home'),
        ),
        BottomNavigationBarItem(
          icon: const Icon(Icons.grid_view_outlined),
          activeIcon: const Icon(Icons.grid_view),
          label: c('home_shell.catalogue'),
        ),
        // CHANGE #536 — MY SHOP. The pharmacy suite used to hang off one row in
        // the account dropdown; it is a first-class destination now. The label
        // is ui_copy like every other slot, so renaming the tab is an UPDATE.
        // Offered only to a signed-in non-admin (QA round 2) — see showMyShop.
        if (showMyShop)
          BottomNavigationBarItem(
            icon: const Icon(Icons.storefront_outlined),
            activeIcon: const Icon(Icons.storefront),
            label: c('home_shell.my_shop'),
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
          label: c('home_shell.orders'),
        ),
        BottomNavigationBarItem(
          icon: const Icon(Icons.upload_file_outlined),
          activeIcon: const Icon(Icons.upload_file),
          label: c('home_shell.bulk'),
        ),
      ],
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
    final uniqueItems = cart.distinctItems;

    // CHANGE #615 — the five-tier discount ladder is gone from the backend, so
    // the bar shows the one thing the cart still has: the MRP subtotal line,
    // worded by cart_render(). Left as it was, tier_gap/tier_progress would
    // have read 0 off a payload that no longer carries them and rendered
    // "Add ₹0 more for " over an empty progress bar.
    final Widget leftContent = Text(
      cart.rs('subtotal_line'),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );

    return SlideTransition(
      position: _slideAnim,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: const Color(0xFF1B5E20),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.20),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.max,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: leftContent,
                        ),
                      ),
                      ScaleTransition(
                        scale: _pulseAnim,
                        child: _CartChip(uniqueItems: uniqueItems),
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
      softWrap: false,
      overflow: TextOverflow.clip,
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

class _UnlockedTierText extends StatelessWidget {
  final String unlockedLabel;
  final int nextPct;
  final int remaining;
  const _UnlockedTierText({
    required this.unlockedLabel,
    required this.nextPct,
    required this.remaining,
  });

  @override
  Widget build(BuildContext context) {
    return RichText(
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      text: TextSpan(
        style: const TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, color: Colors.white),
        children: [
          TextSpan(text: '🎉 $unlockedLabel unlocked! Add '),
          TextSpan(
            text: '₹$remaining',
            style: const TextStyle(
              color: Color(0xFFFBBF24),
              fontWeight: FontWeight.w800,
            ),
          ),
          TextSpan(text: ' more to get $nextPct% off'),
        ],
      ),
    );
  }
}

class _CartChip extends StatefulWidget {
  final int uniqueItems;
  const _CartChip({required this.uniqueItems});

  @override
  State<_CartChip> createState() => _CartChipState();
}

class _CartChipState extends State<_CartChip> {
  bool _increasing = true;

  @override
  void didUpdateWidget(_CartChip old) {
    super.didUpdateWidget(old);
    _increasing = widget.uniqueItems >= old.uniqueItems;
  }

  @override
  Widget build(BuildContext context) {
    final uniqueItems = widget.uniqueItems;
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
              ClipRect(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  transitionBuilder: (child, animation) {
                    final offset = _increasing
                        ? Tween<Offset>(begin: const Offset(0, -1), end: Offset.zero)
                        : Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero);
                    return SlideTransition(
                      position: offset.animate(
                          CurvedAnimation(parent: animation, curve: Curves.easeOut)),
                      child: FadeTransition(opacity: animation, child: child),
                    );
                  },
                  child: Text(
                    // CHANGE #559: the "N items" pill is cart_state().cta_label.
                    AppState.of(context).ctaLabel ?? '',
                    key: ValueKey(uniqueItems),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
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

// ─────────────────────── Web discount progress bar ───────────────────────

/// Floating rounded-rectangle version of _StickyCartBar for desktop web.
/// Fixed at the bottom of the viewport via Positioned in _buildDesktop's Stack.
/// Slides up when the cart becomes non-empty, slides down when emptied.
class _WebDiscountBar extends StatefulWidget {
  final VoidCallback onTap;
  const _WebDiscountBar({required this.onTap});

  @override
  State<_WebDiscountBar> createState() => _WebDiscountBarState();
}

class _WebDiscountBarState extends State<_WebDiscountBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slideAnim;
  bool _wasVisible = false;

  @override
  void initState() {
    super.initState();
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 2.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = AppState.of(context).distinctItems > 0;
    if (visible && !_wasVisible) {
      _slideCtrl.forward(from: 0);
    } else if (!visible && _wasVisible) {
      _slideCtrl.reverse();
    }
    _wasVisible = visible;
  }

  @override
  void dispose() {
    _slideCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final uniqueItems = cart.distinctItems;

    if (uniqueItems == 0 && !_slideCtrl.isAnimating) {
      return const SizedBox.shrink();
    }

    // CHANGE #615 — the five-tier discount ladder is gone from the backend, so
    // the bar shows the one thing the cart still has: the MRP subtotal line,
    // worded by cart_render(). Left as it was, tier_gap/tier_progress would
    // have read 0 off a payload that no longer carries them and rendered
    // "Add ₹0 more for " over an empty progress bar.
    final Widget leftContent = Text(
      cart.rs('subtotal_line'),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );

    return SlideTransition(
      position: _slideAnim,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1B5E20),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                child: Row(
                  children: [
                    Expanded(child: leftContent),
                    _CartChip(uniqueItems: uniqueItems),
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

// ─────────────────────── Desktop top bar (Row 1) ───────────────────────

// ─────────────────────── Desktop single-row header ───────────────────────
