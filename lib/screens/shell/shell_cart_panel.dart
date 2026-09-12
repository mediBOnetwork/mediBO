part of '../home_shell.dart';

// CHANGE #327 · LAYER 1 — sharded out of home_shell.dart.
//
// The slide-in cart panel and its clear-cart confirmation.
//
// It is a `part`, not a new library, on purpose: nearly every widget in
// the shell is library-private and used by the others, so extracting them
// into real libraries would force ~40 classes public and rewrite every
// reference. A part shares the library's imports and its privacy scope, so
// this is a pure move — and it gives this concern its own leasable path, so
// a cart command and a login command stop fighting over one file.
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

class _CartPanelContent extends StatefulWidget {
  final double width;
  final VoidCallback onClose;
  final VoidCallback onOrderPlaced;
  const _CartPanelContent({
    required this.width,
    required this.onClose,
    required this.onOrderPlaced,
  });

  @override
  State<_CartPanelContent> createState() => _CartPanelContentState();
}

class _CartPanelContentState extends State<_CartPanelContent> {
  bool _searchActive = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';

  // CMD #1912 — one anchor for both overlays: the "..." button. The menu
  // hangs off it, and so does the confirm the menu opens, so the confirmation
  // appears exactly where the action was tapped.
  final LayerLink _clearCartLink = LayerLink();
  OverlayEntry? _clearCartOverlay;
  OverlayEntry? _menuOverlay;

  @override
  void dispose() {
    _closeClearCartPopover();
    _closeMenu();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    if (_searchActive) FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) {
        _searchCtrl.clear();
        _searchQuery = '';
      }
    });
  }

  // CMD #1912 — the overflow. Clear Cart was a red pill in the header of every
  // cart visit for an action taken almost never; it is now one entry behind
  // "...", and it still opens the same confirm before anything is destroyed.
  void _openMenu() {
    _closeMenu();
    final entry = OverlayEntry(
      builder: (_) => _CartOverflowMenu(
        link: _clearCartLink,
        onDismissed: () { if (mounted) _closeMenu(); },
        onClearCart: () {
          _closeMenu();
          _openClearCartPopover();
        },
      ),
    );
    _menuOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  void _closeMenu() {
    _menuOverlay?.remove();
    _menuOverlay = null;
  }

  void _openClearCartPopover() {
    _closeClearCartPopover();
    final appState = AppState.of(context);
    final entry = OverlayEntry(
      builder: (_) => _ClearCartPopover(
        link: _clearCartLink,
        onDismissed: () { if (mounted) _closeClearCartPopover(); },
        onClear: () { appState.clear(); },
      ),
    );
    _clearCartOverlay = entry;
    Overlay.of(context).insert(entry);
  }

  void _closeClearCartPopover() {
    _clearCartOverlay?.remove();
    _clearCartOverlay = null;
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final mq = MediaQuery.of(context);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Cart header ──────────────────────────────────────────────
          Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFEEF0F2))),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
              child: Row(
                children: [
                  // Back arrow — always visible in both states
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.arrow_back_ios_new,
                        size: 18, color: Color(0xFF111827)),
                    tooltip: c('home_shell.close_cart'),
                  ),
                  // Animated area: full-width search field OR collapsed toolbar.
                  // LayoutBuilder provides the exact available width so the
                  // collapsed Row (which has Expanded children) lays out correctly
                  // inside the AnimatedSwitcher's Stack layout.
                  Expanded(
                    child: LayoutBuilder(
                      builder: (ctx, bc) => ClipRect(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 280),
                          switchInCurve: Curves.easeInOut,
                          switchOutCurve: Curves.easeInOut,
                          layoutBuilder: (cur, prev) => Stack(
                            alignment: Alignment.centerLeft,
                            children: [...prev, if (cur != null) cur],
                          ),
                          transitionBuilder: (child, anim) {
                            // Search field slides in from right + fades.
                            if (child.key == const ValueKey('search')) {
                              return SlideTransition(
                                position: Tween<Offset>(
                                  begin: const Offset(0.25, 0),
                                  end: Offset.zero,
                                ).animate(anim),
                                child: FadeTransition(
                                    opacity: anim, child: child),
                              );
                            }
                            // Collapsed toolbar just fades.
                            return FadeTransition(
                                opacity: anim, child: child);
                          },
                          child: _searchActive
                              // ── Search-open: back arrow + full-width field ──
                              ? TextField(
                                  key: const ValueKey('search'),
                                  controller: _searchCtrl,
                                  autofocus: true,
                                  onChanged: (v) =>
                                      setState(() => _searchQuery = v),
                                  decoration: InputDecoration(
                                    hintText: c('home_shell.search_in_cart'),
                                    hintStyle: const TextStyle(
                                        color: Color(0xFF9CA3AF),
                                        fontSize: 13),
                                    isDense: true,
                                    contentPadding:
                                        const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 9),
                                    filled: true,
                                    fillColor: const Color(0xFFF9FAFB),
                                    // Search icon lives inside field as prefix
                                    prefixIcon: const Icon(Icons.search,
                                        size: 18, color: Color(0xFF9CA3AF)),
                                    prefixIconConstraints:
                                        const BoxConstraints(
                                            minWidth: 36, minHeight: 36),
                                    border: OutlineInputBorder(
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                          color: Color(0xFFE5E7EB)),
                                    ),
                                    enabledBorder: OutlineInputBorder(
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                          color: Color(0xFFE5E7EB)),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius:
                                          BorderRadius.circular(8),
                                      borderSide: const BorderSide(
                                          color: Color(0xFF1B5E20),
                                          width: 1.5),
                                    ),
                                    // Single X: clear text → close search
                                    suffixIcon: IconButton(
                                      icon: const Icon(Icons.close,
                                          size: 16,
                                          color: Color(0xFF9CA3AF)),
                                      onPressed: () {
                                        if (_searchQuery.isNotEmpty) {
                                          setState(() {
                                            _searchCtrl.clear();
                                            _searchQuery = '';
                                          });
                                        } else {
                                          _toggleSearch();
                                        }
                                      },
                                    ),
                                  ),
                                )
                              // ── Collapsed: title + Clear Cart + search btn ──
                              : SizedBox(
                                  key: const ValueKey('collapsed'),
                                  width: bc.maxWidth,
                                  child: Row(
                                    children: [
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          // CHANGE #559: header string comes
                                          // from cart_state(), never Dart.
                                          cart.header ?? '',
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF1E293B),
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                        ),
                                      ),
                                      GestureDetector(
                                        onTap: _toggleSearch,
                                        child: Container(
                                          width: 34,
                                          height: 34,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                                color: Ds.c.divider),
                                          ),
                                          child: Icon(Icons.search,
                                              size: 17,
                                              color: Ds.c.textSecondary),
                                        ),
                                      ),
                                      // CMD #1912 — "..." replaces the red
                                      // Clear Cart pill. Both overlays hang
                                      // off this one anchor.
                                      CompositedTransformTarget(
                                        link: _clearCartLink,
                                        child: IconButton(
                                          onPressed: _openMenu,
                                          tooltip: c('home_shell.cart_menu'),
                                          iconSize: 20,
                                          color: Ds.c.textSecondary,
                                          icon: const Icon(Icons.more_vert),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: MediaQuery(
              data: mq.copyWith(size: Size(widget.width, mq.size.height)),
              child: CartScreen(
                onOrderPlaced: widget.onOrderPlaced,
                externalSearchQuery: _searchActive ? _searchQuery : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Cart overflow menu — CMD #1912 ──────────────────────────────────────────
//
// One entry today: Clear Cart. It is here rather than in the header because a
// destructive action that is taken almost never should not be the loudest
// thing on a screen the customer opens to check their basket. Choosing it
// still opens the confirm; nothing is cleared from this menu.
class _CartOverflowMenu extends StatelessWidget {
  final LayerLink link;
  final VoidCallback onDismissed;
  final VoidCallback onClearCart;

  const _CartOverflowMenu({
    required this.link,
    required this.onDismissed,
    required this.onClearCart,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismissed,
            child: const SizedBox.expand(),
          ),
        ),
        CompositedTransformFollower(
          link: link,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: Offset(0, Ds.space.x4),
          showWhenUnlinked: false,
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                border: Border.all(color: Ds.c.divider),
                boxShadow: Ds.elevation.e2,
              ),
              child: InkWell(
                borderRadius: Ds.r.rCard,
                onTap: onClearCart,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x16, vertical: Ds.space.x12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.remove_shopping_cart,
                          size: 18, color: Ds.c.danger),
                      SizedBox(width: Ds.space.x12),
                      Text(
                        c('home_shell.clear_cart'),
                        style: Ds.t.body.copyWith(color: Ds.c.danger),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Clear-cart popover ───────────────────────────────────────────────────────

class _ClearCartPopover extends StatefulWidget {
  final LayerLink link;
  final VoidCallback onDismissed;
  final VoidCallback onClear;

  const _ClearCartPopover({
    required this.link,
    required this.onDismissed,
    required this.onClear,
  });

  @override
  State<_ClearCartPopover> createState() => _ClearCartPopoverState();
}

class _ClearCartPopoverState extends State<_ClearCartPopover>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _fade;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scale = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _fade = _ctrl;
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    await _ctrl.animateTo(0,
        duration: const Duration(milliseconds: 180), curve: Curves.easeIn);
    widget.onDismissed();
  }

  Future<void> _handleClearAll() async {
    if (_dismissing) return;
    _dismissing = true;
    widget.onClear(); // clear immediately, synchronously
    await _ctrl.animateTo(0,
        duration: const Duration(milliseconds: 180), curve: Curves.easeIn);
    widget.onDismissed();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Tap-outside barrier
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _dismiss,
            child: const SizedBox.expand(),
          ),
        ),
        // Floating popover anchored to the Clear Cart button
        CompositedTransformFollower(
          link: widget.link,
          targetAnchor: Alignment.bottomRight,
          followerAnchor: Alignment.topRight,
          offset: const Offset(0, 6),
          showWhenUnlinked: false,
          child: ScaleTransition(
            scale: _scale,
            alignment: Alignment.topRight,
            child: FadeTransition(
              opacity: _fade,
              child: Material(
                color: Colors.transparent,
                elevation: 0,
                child: Container(
                  width: 272,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 20,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: _ConfirmContent(
                    onCancel: _dismiss,
                    onClearAll: _handleClearAll,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ConfirmContent extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback onClearAll;
  const _ConfirmContent(
      {super.key, required this.onCancel, required this.onClearAll});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          c('home_shell.this_will_clear_all_items'),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 13,
            color: Color(0xFF6B7280),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: onCancel,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDCFCE7),
                  foregroundColor: const Color(0xFF15803D),
                  minimumSize: const Size(0, 44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  elevation: 0,
                  shadowColor: Colors.transparent,
                ),
                child: Text(c('home_shell.cancel'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: onClearAll,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFDC2626),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(c('home_shell.clear_all'),
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────── Login panel (web desktop) ───────────────────────
