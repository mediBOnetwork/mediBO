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

  /// CMD #2172 (Om) — the shell's hiding slot, handed DOWN so it wraps the NAV
  /// ROW instead of the whole card.
  ///
  /// #2080 wrapped the dock itself, which was right while the dock was only a
  /// nav bar and wrong the moment #2147 joined the banner into the same card:
  /// a scroll took the banner away too. Om's design says only the nav row
  /// slides away and the banner "drops to the bottom as its own rounded card",
  /// so the shell still owns the slot (and the backend flag that turns it on)
  /// and the dock decides what it goes around.
  final Widget Function(Widget navRow)? navSlot;

  const _MobileBottomBar({
    required this.index,
    required this.cartOpen,
    required this.onCartTap,
    required this.onPageTap,
    required this.slots,
    this.navSlot,
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
    // CMD #2147 — the floating dock. Same rows, same order, same pages, same
    // badges; only the drawing changed. The shop badge is a notifier of its
    // own, so the dock listens to it rather than reading it once.
    final found = slots.indexWhere((s) => pageOf(s) == index);
    final bottomNavIndex = found < 0 ? 0 : found;
    return ListenableBuilder(
      // CMD #2147 (Om) — the login / registration ask rides INSIDE the dock
      // card now, so the dock listens to it as well as to the shop badge.
      listenable: Listenable.merge(
          [ShopBadge.value, appRegistrationBar, appUpdateBar]),
      builder: (context, _) => FloatingDock(
        bar: _joinedBar(context),
        navSlot: navSlot,
        activeIndex: bottomNavIndex,
        // The one map, read once, used for both halves of the question: which
        // slots exist (the tabs) and where each one goes (here).
        onTap: (i) {
          if (i >= 0 && i < slots.length) onPageTap(pageOf(slots[i]));
        },
        tabs: [for (final s in slots) _dockTab(s, cart)],
      ),
    );
  }

  /// CMD #2147 (Om) — the guest "… · Login" / "Registration pending ·
  /// Continue" ask as the dock card's top row, or null once the backend says
  /// there is nothing to ask (signed in and approved) — the card then shrinks
  /// back to the dock alone. Every word is the payload's.
  static Widget? _joinedBar(BuildContext context) {
    // ONE bar at a time (CMD #2114): update > login > registration.
    if (appUpdateBar.visible) {
      RenderLog.write('c2147_dock_bar', 'update');
      final busy = appUpdateBar.updating || appUpdateBar.downloaded;
      return DockBarRow(
        key: const ValueKey('c2147_dock_update'),
        // CMD #2172 — the ground and the round icon are `app_update_bar().style`.
        style: BarStyle.from(appUpdateBar.payload),
        label: appUpdateBar.label,
        action: appUpdateBar.downloaded
            ? appUpdateBar.downloadedLabel
            : appUpdateBar.updating
                ? appUpdateBar.updatingLabel
                : appUpdateBar.actionLabel,
        onAction: busy ? () {} : (appUpdateBar.onUpdate ?? () {}),
      );
    }
    if (!appRegistrationBar.visible) return null;
    final login = appRegistrationBar.kind == 'login';
    RenderLog.write('c2147_dock_bar', appRegistrationBar.kind);
    return DockBarRow(
      key: login ? kLoginBarKey : kRegistrationBarKey,
      // CMD #2172 — one block, whichever ask this is: the backend already knows
      // which kind it sent, so Dart no longer picks a glyph from the kind.
      style: BarStyle.from(appRegistrationBar.payload),
      label: appRegistrationBar.label,
      action: appRegistrationBar.actionLabel,
      actionIdentifier: login ? kLoginBarActionId : null,
      onAction: () => openRegistrationBar(context),
    );
  }

  /// A `customer_nav` row → a [DockTab]: its label, its page, its glyph pair
  /// and its badge, all the row's own answers.
  static DockTab _dockTab(Map<String, dynamic> s, CartModel cart) {
    final pair = _kBottomNavGlyphs[(s['icon_key'] ?? '').toString()];
    final badge = switch ((s['badge_key'] ?? '').toString()) {
      'cart' => cart.orders.isEmpty ? '' : '${cart.orders.length}',
      'shop' => ShopBadge.show ? ShopBadge.label : '',
      _ => '',
    };
    return DockTab(
      key: (s['key'] ?? '').toString(),
      label: (s['label'] ?? '').toString(),
      icon: pair?.icon ?? Icons.widgets_outlined,
      activeIcon: pair?.active ?? Icons.widgets,
      badge: badge,
      avatarLetter: s['icon_key'] == 'avatar'
          ? (s['avatar_label'] ?? '').toString()
          : null,
    );
  }

  static Widget _avatarGlyph(String letter, {required bool active}) =>
      Container(
        width: Ds.space.x24,
        height: Ds.space.x24,
        alignment: Alignment.center,
        decoration: BoxDecoration(
            color: active ? Ds.c.brand : Ds.c.textSecondary,
            shape: BoxShape.circle),
        child: letter.isEmpty
            ? Icon(Icons.person, size: Ds.space.x16, color: Ds.c.surface)
            : Text(letter,
                style: Ds.t.caption.copyWith(
                    color: Ds.c.surface, fontWeight: FontWeight.w700, height: 1)),
      );

  /// CMD #2080 — the tab's own handle, for a browser journey.
  ///
  /// The name is the registry row's `slot_key`, so re-ordering the bar or
  /// hiding a slot cannot move it and nothing here has to agree with a list
  /// written somewhere else.
  static Widget _identified(Map<String, dynamic> slot, Widget child) =>
      Semantics(
        // Its OWN node: the bar already wraps each item in a semantics
        // container, and a bare child would merge into that one and take the
        // handle with it.
        container: true,
        identifier: 'nav_slot_${(slot['key'] ?? '').toString()}',
        child: child,
      );

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
    // CMD #2125 — the Profile tab wears the pharmacy's initial, which is
    // customer_nav()'s own `avatar_label`; an empty one draws the person glyph.
    final letter = (slot['avatar_label'] ?? '').toString();
    final icon = slot['icon_key'] == 'avatar'
        ? _avatarGlyph(letter, active: active)
        : Icon(pair == null
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

// ────────────────── The bottom stack (CMD #2051 / #2066) ────────────────────

/// The shell's ONE piece of bottom chrome, positioned.
///
/// #2037 lifted the floating pill by the update card's measured height, which
/// worked only because two widgets agreed on a number: the card was an overlay
/// installed from `MaterialApp.builder` and the pill was `Positioned` inside
/// the shell's own Stack, so neither could see the other and the offset was
/// the only thing holding them apart. #2051 made them one column. #2066 made
/// every height in that column a CONSTANT, so nothing above it ever moves.
///
/// Anchored at `bottom: 0` of the shell body, which is the TOP OF THE BOTTOM
/// NAV, because a Scaffold body ends where its `bottomNavigationBar` begins.
/// So "flush on the nav" needs no number at all — and the stack asks that same
/// Scaffold whether a nav is there, which is how the update bar renders on a
/// shell with tabs and on nothing else.
///
/// CMD #2043 — WHICH page draws the pill is still the registry's answer, not a
/// page number written here. Both call sites used to read `_index == 0`, which
/// was written when Home was the only storefront surface and was never
/// revisited when the Catalogue became page 12: a shopper browsing a company
/// or a salt list had a full cart and no way back to it. `cart_pill` is a
/// column on the slot row, so adding a surface is an UPDATE.
///
/// CMD #2066 — the stack is mounted on the ADMIN/staff shell too, because the
/// update bar belongs wherever there are tabs, whatever tabs that user type
/// has. Staff float no cart pill, so [staff] reserves the pill's space (the
/// geometry is constant for everyone) and draws nothing in it.
Widget shellBottomStack(VoidCallback onTap, int page, {bool staff = false}) =>
    ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: CustomerNav.value,
      // CMD #2147 — with the floating dock the body runs to the screen's
      // bottom (`extendBody`) and hands down the dock's height as its bottom
      // padding: the stack sits just above the dock, on it, never under it.
      builder: (ctx, slots, __) => Positioned(
        left: 0,
        right: 0,
        bottom: bottomNavVisible(ctx) ? MediaQuery.paddingOf(ctx).bottom : 0,
        child: StorefrontBottomStack(
          onCartTap: staff ? null : onTap,
          showPill: !staff && CartPill.floatsOnPage(slots, page),
        ),
      ),
    );

/// CMD #2147 — every customer tab (Home, Orders, Bulk, Catalogue, Profile):
/// their scroll views pad by `MediaQuery` / [BottomStackSpacer], so the page
/// runs behind the View cart pill and the dock with no band anywhere.
const Set<int> _kFloatingPages = {0, 1, 2, 12, 15};

/// CMD #2140 — the page host for every shell tab: staff pages clear the bar,
/// customer tabs clear the bar AND, on a tab that floats it, the View cart
/// pill — so neither ever sits on top of the last card.
Widget shellHost(Widget child, {required bool staff, required int page}) =>
    staff
        ? shellPageHost(child, staff: true)
        : ValueListenableBuilder<List<Map<String, dynamic>>>(
            valueListenable: CustomerNav.value,
            child: child,
            builder: (_, slots, host) => shellPageHost(host!,
                staff: false, pill: CartPill.floatsOnPage(slots, page),
                // CMD #2147 — the tabs whose lists take their bottom room
                // from MediaQuery float behind the pill and the dock.
                float: _kFloatingPages.contains(page)),
          );
