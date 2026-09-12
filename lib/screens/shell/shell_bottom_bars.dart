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
/// CHANGE #630 — the bar is a REGISTRY, not five hand-written slots.
///
/// Om: "customer bottom-nav sequence changes to exactly Home · Catalogue ·
/// Bulk · Orders · My Shop. Registry sort_order owns it; do not hardcode the
/// order in Dart." Until now the five slots were a Dart list literal AND the
/// selected slot was a hand-written `index == 11 ? 2 : index == 1 ? 3 : ...`
/// ladder — two expressions that had to agree, so re-ordering the bar was a
/// two-place edit with a wrong answer available in between. Both facts are one
/// `customer_nav_slot` row each now: the row carries the shell page it opens,
/// which makes the ladder a lookup and the order an UPDATE.
///
/// The ONE thing that stays here is `icon_key` → glyph. A row cannot carry an
/// IconData, so the map below is the same arrangement `kNavIcons` already uses
/// for the admin registry — an unknown key draws a neutral glyph rather than
/// throwing, so a new slot ships without a deploy even if its icon waits for one.
const Map<String, ({IconData icon, IconData active})> _kBottomNavGlyphs = {
  'home': (icon: Icons.home_outlined, active: Icons.home),
  'grid': (icon: Icons.grid_view_outlined, active: Icons.grid_view),
  'upload_file': (icon: Icons.upload_file_outlined, active: Icons.upload_file),
  'receipt': (icon: Icons.receipt_long_outlined, active: Icons.receipt_long),
  'storefront': (icon: Icons.storefront_outlined, active: Icons.storefront),
};

class _MobileBottomBar extends StatelessWidget {
  /// The shell page currently showing.
  final int index;
  final bool cartOpen;
  final VoidCallback onCartTap;

  /// CHANGE #536 QA round 3 (finding 301) — the bar hands back the PAGE, not
  /// the slot it was tapped at.
  ///
  /// It used to hand back the slot index, which forced the shell to map it
  /// through its own copy of the slot->page list a SECOND time. Two call sites
  /// of one map is a drift waiting to happen, and QA proved it: a signed-out
  /// visitor tapping the fourth tab landed on Bulk upload while every test
  /// stayed green. The map is read in exactly one place — `pageOf`, below —
  /// so the list that decides which items exist IS the list that decides where
  /// they go.
  final ValueChanged<int> onPageTap;

  /// `customer_nav().slots`, in the backend's order, rendered verbatim.
  ///
  /// CHANGE #630 — the bar is a REGISTRY, not five hand-written slots. Om:
  /// "customer bottom-nav sequence changes to exactly Home · Catalogue · Bulk ·
  /// Orders · My Shop. Registry sort_order owns it; do not hardcode the order
  /// in Dart." The five slots used to be a Dart list literal (`pagesFor`) next
  /// to five hand-written `BottomNavigationBarItem`s — two expressions that had
  /// to agree, so re-ordering the bar was a two-place edit with a wrong answer
  /// available in between. Both are one `customer_nav_slot` row each now: the
  /// row carries its label, its icon, its badge and the shell page it opens, so
  /// re-ordering the bar is an UPDATE and hiding a slot cannot leave a hole.
  ///
  /// WHO is offered My Shop is the same row's decision (`visibility`), resolved
  /// against the caller inside `customer_nav()`. That rule is #536 QA round 2 —
  /// an admin and a signed-out visitor must not be shown a tab whose RPC would
  /// refuse them (customer_shop_home() has no EXECUTE for anon) — and keeping
  /// it on the row is what stops a hidden slot from leaving a hole in a list
  /// the bar also indexes by position.
  final List<Map<String, dynamic>> slots;

  const _MobileBottomBar({
    required this.index,
    required this.cartOpen,
    required this.onCartTap,
    required this.onPageTap,
    required this.slots,
  });

  /// The page a slot opens: the row's own `page_index`, never its position.
  /// The single source of truth the bar draws from and the shell navigates by.
  static int pageOf(Map<String, dynamic> slot) =>
      (slot['page_index'] as num?)?.toInt() ?? 0;

  /// The attention count on the My Shop icon, redrawn whenever the notifier
  /// changes and absent entirely while the backend says there is nothing to
  /// say. Never a spinner and never a zero.
  static Widget _shopBadge(Widget icon) => ValueListenableBuilder(
        valueListenable: ShopBadge.value,
        builder: (context, _, child) => Badge(
          isLabelVisible: ShopBadge.show && ShopBadge.label.isNotEmpty,
          label: Text(ShopBadge.label),
          child: icon,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    // A bar needs at least two destinations to exist; until the registry
    // answers, draw nothing rather than a guessed bar.
    if (slots.length < 2) return const SizedBox.shrink();
    // Which slot is lit is a LOOKUP over the same list the taps resolve
    // through, so hiding a slot cannot leave a page pointing at one that no
    // longer exists (a hidden page 11 finds no slot and falls back to Home).
    final found = slots.indexWhere((s) => pageOf(s) == index);
    final bottomNavIndex = found < 0 ? 0 : found;
    return BottomNavigationBar(
      currentIndex: bottomNavIndex,
      type: BottomNavigationBarType.fixed,
      selectedItemColor: Brand.green,
      unselectedItemColor: Brand.inkMuted,
      selectedFontSize: 10,
      unselectedFontSize: 10,
      elevation: 8,
      // The one map, read once, used for both halves of the question: which
      // slots exist (below) and where each one goes (here).
      onTap: (i) {
        if (i >= 0 && i < slots.length) onPageTap(pageOf(slots[i]));
      },
      items: [
        for (final s in slots)
          BottomNavigationBarItem(
            icon: _glyph(s, cart, active: false),
            activeIcon: _glyph(s, cart, active: true),
            // The word is the backend's, from ui_copy, like every other label.
            label: (s['label'] ?? '').toString(),
          ),
      ],
    );
  }

  /// `icon_key` -> glyph, plus the row's own badge.
  ///
  /// A row cannot carry an IconData, so the glyph map is the same arrangement
  /// `kNavIcons` already uses for the admin registry — an unknown key draws a
  /// neutral glyph rather than throwing, so a new slot ships without a deploy
  /// even if its icon waits for one. WHICH slot carries a badge, and which
  /// badge, is the ROW's answer (`badge_key`), never a guess made here.
  Widget _glyph(Map<String, dynamic> slot, CartModel cart,
      {required bool active}) {
    final pair = _kBottomNavGlyphs[(slot['icon_key'] ?? '').toString()];
    final icon = Icon(pair == null
        ? Icons.widgets_outlined
        : (active ? pair.active : pair.icon));
    switch ((slot['badge_key'] ?? '').toString()) {
      case 'cart':
        // CHANGE #799 — the badge PULSES when the count changes. Motion with a
        // meaning: an add that happened three screens away (a catalogue card,
        // a quick peek) has to be visible where the cart lives, or the only
        // feedback for the tap is the row the finger is already covering.
        return _CartBadgePulse(
          count: cart.orders.length,
          child: icon,
        );
      case 'shop':
        return _shopBadge(icon);
      default:
        return icon;
    }
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


/// CHANGE #799 — the bottom bar's cart badge, and the one beat it grows for
/// when the count changes.
///
/// The animation is driven by the COUNT, not by the add: any route into the
/// cart — a catalogue card, the quick peek, the product page, a restored
/// draft — moves this badge, because all of them move the number.
class _CartBadgePulse extends StatefulWidget {
  final int count;
  final Widget child;
  const _CartBadgePulse({required this.count, required this.child});

  @override
  State<_CartBadgePulse> createState() => _CartBadgePulseState();
}

class _CartBadgePulseState extends State<_CartBadgePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Ds.motion.standard,
    lowerBound: 1.0,
    upperBound: 1.35,
  );

  @override
  void didUpdateWidget(covariant _CartBadgePulse old) {
    super.didUpdateWidget(old);
    // Only a RISE pulses. Removing a line is not a moment to celebrate, and a
    // badge that jumps on every decrement is noise.
    if (widget.count > old.count) {
      _c.forward(from: 1.0).then((_) {
        if (mounted) _c.reverse();
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Badge(
        isLabelVisible: widget.count > 0,
        label: ScaleTransition(
          scale: _c,
          child: Text('${widget.count}'),
        ),
        child: widget.child,
      );
}
