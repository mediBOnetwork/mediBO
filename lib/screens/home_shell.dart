import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../models/cart_model.dart';
import '../theme.dart';
import '../url_sync.dart';
import '../user_state.dart';
import '../util.dart';
import '../widgets/animations.dart';
import 'auth/login_screen.dart';
import 'bulk_upload_screen.dart';
import 'cart_screen.dart';
import 'orders_screen.dart';
import 'profile_screen.dart';
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
  bool _loginOpen = false;
  int _scrollTrigger = 0;
  int _scrollToTopTrigger = 0;
  bool _searchLoading = false;

  // Desktop scroll state (header shadow only — fires setState at most twice per visit)
  bool _desktopScrolled = false;

  // Desktop sidebar: populated once storefront loads its CatalogMeta
  CatalogMeta? _desktopMeta;

  @override
  void initState() {
    super.initState();
    _initFromUrl();
    listenPopState(_applyPath);
  }

  // ── URL helpers ─────────────────────────────────────────────────────────────

  static String _catToSlug(String cat) => cat.toLowerCase().replaceAll(' ', '-');
  static String _slugToCat(String slug) => slug.toUpperCase().replaceAll('-', ' ');

  String _urlForState() {
    if (_index == 1) return '/orders';
    if (_index == 2) return '/bulk-upload';
    if (_category != 'All') return '/c/${_catToSlug(_category)}';
    return '/';
  }

  // Read the URL on first load and set initial shell state.
  void _initFromUrl() {
    final query = currentSearch();
    if (query.contains('code=')) {
      // OAuth callback — strip the code once Supabase has processed it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) replaceUrl('/');
      });
      return;
    }
    final path = currentPath();
    if (path.startsWith('/c/')) {
      _category = _slugToCat(path.substring(3));
    } else if (path == '/orders') {
      _index = 1;
    } else if (path == '/bulk-upload') {
      _index = 2;
    }
  }

  // Respond to browser back / forward navigation.
  void _applyPath(String path) {
    if (!mounted) return;
    setState(() {
      if (path.startsWith('/c/')) {
        _category = _slugToCat(path.substring(3));
        _index = 0;
        _cartOpen = false;
        _scrollToTopTrigger++;
      } else if (path == '/orders') {
        _index = 1;
        _cartOpen = false;
      } else if (path == '/bulk-upload') {
        _index = 2;
        _cartOpen = false;
      } else {
        _category = 'All';
        _index = 0;
        _cartOpen = false;
        _scrollToTopTrigger++;
      }
    });
  }

  // Change tab and push the matching URL to browser history.
  void _setIndex(int i) {
    setState(() {
      _index = i;
      _cartOpen = false;
    });
    pushUrl(_urlForState());
  }

  void _onMetaLoaded(CatalogMeta meta) {
    if (mounted) setState(() => _desktopMeta = meta);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _selectCategory(String c) {
    setState(() {
      _category = c;
      _query = '';
      _searchCtrl.clear();
      _index = 0;
      _cartOpen = false;
      _scrollToTopTrigger++; // scroll to top of product list on every category change
    });
    pushUrl(c == 'All' ? '/' : '/c/${_catToSlug(c)}');
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= 900;

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
            showCategoryTiles: false,
            onMetaLoaded: _onMetaLoaded,
            onFooterSearch: () => setState(() => _scrollToTopTrigger++),
            onFooterBulkUpload: () => _setIndex(2),
            onFooterOrders: () => _setIndex(1),
            onFooterCart: () => setState(() => _cartOpen = true),
          ),
          const OrdersScreen(),
          const BulkUploadScreen(),
        ];

        if (isDesktop) return _buildDesktop(pages);
        return _buildMobile(pages);
      },
    );
  }

  // ─── Mobile / tablet layout (< 900px) ────────────────────────────────────

  Widget _buildMobile(List<Widget> pages) {
    return Scaffold(
      backgroundColor: Colors.white,
      bottomNavigationBar: _cartOpen
          ? null
          : _MobileBottomBar(
              index: _index,
              cartOpen: _cartOpen,
              onCartTap: () => setState(() => _cartOpen = true),
              onNavTap: (i) {
                switch (i) {
                  case 0:
                  case 1:
                    _setIndex(0);
                  case 2:
                    _setIndex(1);
                  case 3:
                    _setIndex(2);
                }
              },
            ),
      body: Stack(
        children: [
          Column(
            children: [
              _LocationHeader(
                onCart: () => setState(() => _cartOpen = true),
              ),
              _MobileSearchBar(
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
              _MobileCategoryChips(
                meta: _desktopMeta,
                selected: _category,
                onCategoryTap: (key) => _selectCategory(key),
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
              onOrderPlaced: () => _setIndex(1),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Desktop layout (≥ 900px) ────────────────────────────────────────────

  Widget _buildDesktop(List<Widget> pages) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Column(
            children: [
              _DesktopHeader(
                searchCtrl: _searchCtrl,
                isLoading: _searchLoading,
                scrolled: _desktopScrolled,
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
                onHome: () => _setIndex(0),
                onBulk: () => _setIndex(2),
                onOrders: () => _setIndex(1),
                onCart: () => setState(() => _cartOpen = true),
                onLogin: () => setState(() => _loginOpen = true),
                index: _index,
                cartOpen: _cartOpen,
              ),
              Expanded(
                // NotificationListener only fires setState when crossing the
                // 400px threshold — at most twice per session, never per-frame.
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (_index != 0) return false;
                    final newScrolled = n.metrics.pixels > 400;
                    if (newScrolled != _desktopScrolled) {
                      setState(() => _desktopScrolled = newScrolled);
                    }
                    return false;
                  },
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_index == 0)
                        _DesktopCategorySidebar(
                          meta: _desktopMeta,
                          selected: _category,
                          onCategorySelected: _selectCategory,
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
              ),
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: RepaintBoundary(
                    child: _WebDiscountBar(
                      onTap: () => setState(() => _cartOpen = true),
                    ),
                  ),
                ),
              ),
            ),
          ),
          LoginPanel(
            open: _loginOpen,
            onClose: () => setState(() => _loginOpen = false),
          ),
          RepaintBoundary(
            child: CartPanel(
              open: _cartOpen,
              onClose: () => setState(() => _cartOpen = false),
              onOrderPlaced: () => _setIndex(1),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Location header ───────────────────────

class _LocationHeader extends StatelessWidget {
  final VoidCallback onCart;
  const _LocationHeader({required this.onCart});

  @override
  Widget build(BuildContext context) {
    final cartItems = AppState.of(context).distinctItems;
    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 70),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(bottom: BorderSide(color: Brand.border)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Row(
          children: [
            // LEFT: profile avatar
            _MobileProfileAvatar(),
            // CENTER: logo
            Expanded(
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1B5E20),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Icon(Icons.add, color: Colors.white, size: 17),
                    ),
                    const SizedBox(width: 7),
                    RichText(
                      text: const TextSpan(
                        children: [
                          TextSpan(
                            text: 'medi',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1B5E20),
                              letterSpacing: -0.3,
                            ),
                          ),
                          TextSpan(
                            text: 'BO',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF4CAF50),
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
            // RIGHT: cart icon
            _MobileCartIcon(cartItems: cartItems, onCart: onCart),
          ],
        ),
      ),
    );
  }
}


// ─────────────────────── Mobile profile avatar (left) ───────────────────────

class _MobileProfileAvatar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);
    final profile = auth.profile;
    final initial = (profile?.displayName.isNotEmpty == true)
        ? profile!.displayName[0].toUpperCase()
        : null;

    return PressEffect(
      scale: 0.92,
      child: GestureDetector(
        onTap: () {
          if (!auth.isAuthenticated) {
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => const LoginScreen()));
          } else {
            Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ProfileScreen()));
          }
        },
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1D9E75), Color(0xFF0F4C35)],
            ),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF1D9E75).withValues(alpha: 0.35),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Center(
            child: initial != null
                ? Text(
                    initial,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: Colors.white,
                      height: 1,
                    ),
                  )
                : const Icon(Icons.person_rounded,
                    color: Colors.white, size: 20),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Mobile cart icon (right) ────────────────────────────

class _MobileCartIcon extends StatefulWidget {
  final int cartItems;
  final VoidCallback onCart;
  const _MobileCartIcon({required this.cartItems, required this.onCart});

  @override
  State<_MobileCartIcon> createState() => _MobileCartIconState();
}

class _MobileCartIconState extends State<_MobileCartIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _badgeCtrl;
  late final Animation<double> _badgeScale;
  int _prevCount = 0;

  @override
  void initState() {
    super.initState();
    _prevCount = widget.cartItems;
    _badgeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _badgeScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.4), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.4, end: 0.85), weight: 30),
      TweenSequenceItem(
        tween: Tween(begin: 0.85, end: 1.0)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 40,
      ),
    ]).animate(_badgeCtrl);
  }

  @override
  void didUpdateWidget(_MobileCartIcon old) {
    super.didUpdateWidget(old);
    if (widget.cartItems != _prevCount) {
      _badgeCtrl.forward(from: 0);
      _prevCount = widget.cartItems;
    }
  }

  @override
  void dispose() {
    _badgeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PressEffect(
      scale: 0.92,
      child: GestureDetector(
        onTap: widget.onCart,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Brand.mint,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFBBF7D0), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Brand.green.withValues(alpha: 0.18),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(Icons.shopping_bag_outlined,
                  color: Brand.green, size: 20),
            ),
            if (widget.cartItems > 0)
              Positioned(
                top: -2,
                right: -2,
                child: ScaleTransition(
                  scale: _badgeScale,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                    child: Center(
                      child: Text(
                        widget.cartItems > 9 ? '9+' : '${widget.cartItems}',
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          height: 1,
                        ),
                      ),
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

// ─────────────────────── Mobile search bar (pill style) ───────────────────────

class _MobileSearchBar extends StatefulWidget {
  final TextEditingController controller;
  final bool isLoading;
  final ValueChanged<String> onSearch;
  final VoidCallback onScrollToResults;

  const _MobileSearchBar({
    required this.controller,
    required this.isLoading,
    required this.onSearch,
    required this.onScrollToResults,
  });

  @override
  State<_MobileSearchBar> createState() => _MobileSearchBarState();
}

class _MobileSearchBarState extends State<_MobileSearchBar> {
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
                keyboardType: TextInputType.text,
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
                    size: 18, color: Color(0xFF6B7280)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 40, minHeight: 40),
              )
            else
              GestureDetector(
                onTap: _submitNow,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: Icon(Icons.search,
                      color: Color(0xFF9CA3AF), size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Mobile category chips row ───────────────────────

class _MobileCategoryChips extends StatelessWidget {
  final CatalogMeta? meta;
  final String selected;
  final ValueChanged<String> onCategoryTap;

  const _MobileCategoryChips({
    required this.meta,
    required this.selected,
    required this.onCategoryTap,
  });

  @override
  Widget build(BuildContext context) {
    final m = meta;
    if (m == null) {
      // Slim placeholder while meta is loading
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

    // "All" first, then categories sorted by count desc
    final cats = List<CategoryCount>.from(m.categories)
      ..sort((a, b) => b.count.compareTo(a.count));

    return Container(
      color: Colors.white,
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
        itemCount: cats.length + 1, // +1 for "All"
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
                    Icon(
                      style.icon,
                      size: 13,
                      color: isSelected ? Colors.white : style.fg,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isSelected ? Colors.white : style.fg,
                      ),
                    ),
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

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) {
        _searchCtrl.clear();
        _searchQuery = '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cart panel header: ← Cart · search toggle
          Container(
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFF3F4F6))),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 8, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: widget.onClose,
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
                      GestureDetector(
                        onTap: _toggleSearch,
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _searchActive
                                ? const Color(0xFFEFF6FF)
                                : Colors.transparent,
                            border: Border.all(
                              color: _searchActive
                                  ? const Color(0xFF3B82F6)
                                  : const Color(0xFFE5E7EB),
                            ),
                          ),
                          child: Icon(
                            _searchActive ? Icons.close : Icons.search,
                            size: 18,
                            color: _searchActive
                                ? const Color(0xFF3B82F6)
                                : const Color(0xFF374151),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ),
                ),
                if (_searchActive)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      onChanged: (v) => setState(() => _searchQuery = v),
                      decoration: InputDecoration(
                        hintText: 'Search in cart…',
                        hintStyle: const TextStyle(
                            color: Color(0xFF9CA3AF), fontSize: 13),
                        prefixIcon: const Icon(Icons.search,
                            size: 18, color: Color(0xFF9CA3AF)),
                        suffixIcon: _searchQuery.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.close,
                                    size: 16, color: Color(0xFF9CA3AF)),
                                onPressed: () => setState(() {
                                  _searchCtrl.clear();
                                  _searchQuery = '';
                                }),
                              )
                            : null,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: Color(0xFFE5E7EB)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              const BorderSide(color: Color(0xFFE5E7EB)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(
                              color: Color(0xFF1B5E20), width: 1.5),
                        ),
                      ),
                    ),
                  ),
              ],
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

// ─────────────────────── Login panel (web desktop) ───────────────────────

class LoginPanel extends StatefulWidget {
  final bool open;
  final VoidCallback onClose;
  const LoginPanel({super.key, required this.open, required this.onClose});

  @override
  State<LoginPanel> createState() => _LoginPanelState();
}

class _LoginPanelState extends State<LoginPanel>
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
  void didUpdateWidget(LoginPanel old) {
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
                  child: _LoginPanelContent(onClose: widget.onClose),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _LoginPanelContent extends StatefulWidget {
  final VoidCallback onClose;
  const _LoginPanelContent({required this.onClose});

  @override
  State<_LoginPanelContent> createState() => _LoginPanelContentState();
}

class _LoginPanelContentState extends State<_LoginPanelContent> {
  final _emailCtrl = TextEditingController();
  bool _loading = false;
  bool _sent = false;
  String? _error;
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    if (Supabase.instance.client.auth.currentUser != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) { if (mounted) widget.onClose(); });
    }
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((s) {
      if (s.event == AuthChangeEvent.signedIn && mounted) widget.onClose();
    });
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _authSub?.cancel();
    super.dispose();
  }

  Future<void> _googleSignIn() async {
    setState(() { _loading = true; _error = null; });
    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'https://medibo.in',
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Google sign-in failed. Please try again.';
          _loading = false;
        });
      }
    }
  }

  // ignore: unused_element
  Future<void> _sendMagicLink() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Please enter your email address.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      await Supabase.instance.client.auth.signInWithOtp(
        email: email,
        emailRedirectTo: 'https://medibo.in',
      );
      if (mounted) setState(() { _sent = true; _loading = false; });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not send link. Please check your email and try again.';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
          child: Row(
            children: [
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close, size: 22),
                color: const Color(0xFF6B7280),
                onPressed: widget.onClose,
                tooltip: 'Close',
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: _LoginPanelLogo()),
                const SizedBox(height: 28),
                const Text(
                  'Welcome to mediBO',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827),
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'B2B Pharmacy Platform',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Color(0xFF6B7280)),
                ),
                const SizedBox(height: 40),

                // ── Google sign-in ──────────────────────────────────────
                SizedBox(
                  height: 54,
                  child: OutlinedButton(
                    onPressed: _loading ? null : _googleSignIn,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.white,
                      side: const BorderSide(
                          color: Color(0xFFD1D5DB), width: 1.5),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Color(0xFF4285F4),
                              strokeWidth: 2.5,
                            ),
                          )
                        : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _LoginPanelGoogleIcon(),
                              SizedBox(width: 12),
                              Text(
                                'Continue with Google',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF374151),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFFDC2626)),
                  ),
                ],

                // ── Magic link (preserved — re-enable by un-commenting) ──
                // if (_sent) ...[
                //   Container(success state — check your email...),
                // ] else ...[
                //   TextField(controller: _emailCtrl, labelText: 'Email address'...),
                //   SizedBox(height: 16),
                //   FilledButton(onPressed: _sendMagicLink, child: Text('Send Magic Link')),
                //   if (_error != null) Text(_error!)...,
                // ],
                const SizedBox(height: 40),
                const Text(
                  'By continuing you agree to our Terms & Privacy Policy',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11, color: Color(0xFF9CA3AF), height: 1.5),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _LoginPanelLogo extends StatelessWidget {
  const _LoginPanelLogo();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xFF1B5E20),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(Icons.add, color: Colors.white, size: 28),
        ),
        const SizedBox(width: 10),
        RichText(
          text: const TextSpan(
            children: [
              TextSpan(
                text: 'medi',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1B5E20),
                  letterSpacing: -0.3,
                ),
              ),
              TextSpan(
                text: 'BO',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF4CAF50),
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LoginPanelGoogleIcon extends StatelessWidget {
  const _LoginPanelGoogleIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Center(
        child: Text(
          'G',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Color(0xFF4285F4),
            height: 1,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────── Mobile bottom bar ───────────────────────

class _MobileBottomBar extends StatelessWidget {
  final int index;
  final bool cartOpen;
  final VoidCallback onCartTap;
  final ValueChanged<int> onNavTap;

  const _MobileBottomBar({
    required this.index,
    required this.cartOpen,
    required this.onCartTap,
    required this.onNavTap,
  });

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final bottomNavIndex = index == 1 ? 2 : index == 2 ? 3 : 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (cart.distinctItems > 0)
          RepaintBoundary(
            child: _StickyCartBar(onTap: onCartTap),
          ),
        BottomNavigationBar(
          currentIndex: bottomNavIndex,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: Brand.green,
          unselectedItemColor: Brand.inkMuted,
          selectedFontSize: 10,
          unselectedFontSize: 10,
          elevation: 8,
          onTap: onNavTap,
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
  static const _tierFreeDelivery = 999.0;

  static Color _tierBgColor(double total) {
    if (total >= 18999) return const Color(0xFF052E16);
    if (total >= 8999) return const Color(0xFF14532D);
    if (total >= 6999) return const Color(0xFF166534);
    if (total >= 2999) return const Color(0xFF15803D);
    if (total >= 999) return const Color(0xFF16A34A);
    return const Color(0xFF22C55E);
  }
  static const _tier3pct = 2999.0;
  static const _tier5pct = 6999.0;
  static const _tier6pct = 8999.0;
  static const _tier7pct = 18999.0;

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
    final total = cart.mrpTotal;
    final uniqueItems = cart.distinctItems;

    final double progress;
    final Widget leftContent;

    if (total >= _tier7pct) {
      progress = 1.0;
      leftContent = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('🎉', style: TextStyle(fontSize: 13)),
          SizedBox(width: 5),
          Flexible(
            child: Text(
              '7% discount unlocked! (maximum)',
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
    } else if (total >= _tier6pct) {
      progress = (total - _tier6pct) / (_tier7pct - _tier6pct);
      final remaining = (_tier7pct - total).ceil();
      leftContent = _UnlockedTierText(unlockedLabel: '6%', nextPct: 7, remaining: remaining);
    } else if (total >= _tier5pct) {
      progress = (total - _tier5pct) / (_tier6pct - _tier5pct);
      final remaining = (_tier6pct - total).ceil();
      leftContent = _UnlockedTierText(unlockedLabel: '5%', nextPct: 6, remaining: remaining);
    } else if (total >= _tier3pct) {
      progress = (total - _tier3pct) / (_tier5pct - _tier3pct);
      final remaining = (_tier5pct - total).ceil();
      leftContent = _UnlockedTierText(unlockedLabel: '3%', nextPct: 5, remaining: remaining);
    } else if (total >= _tierFreeDelivery) {
      progress = (total - _tierFreeDelivery) / (_tier3pct - _tierFreeDelivery);
      final remaining = (_tier3pct - total).ceil();
      leftContent = _UnlockedTierText(unlockedLabel: 'FREE delivery', nextPct: 3, remaining: remaining);
    } else {
      progress = total > 0 ? total / _tierFreeDelivery : 0.0;
      final remaining = (_tierFreeDelivery - total).ceil();
      leftContent = _DiscountText(
          amount: '₹$remaining', suffix: ' more for FREE delivery');
    }

    return SlideTransition(
      position: _slideAnim,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
          height: 64,
          decoration: BoxDecoration(
            color: _tierBgColor(total),
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
                          color: Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOut,
                        height: 4,
                        width: constraints.maxWidth * progress.clamp(0.0, 1.0),
                        decoration: BoxDecoration(
                          color: Colors.white,
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
      overflow: TextOverflow.ellipsis,
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
  static const _tierFreeDelivery = 999.0;

  static Color _tierBgColor(double total) {
    if (total >= 18999) return const Color(0xFF052E16);
    if (total >= 8999) return const Color(0xFF14532D);
    if (total >= 6999) return const Color(0xFF166534);
    if (total >= 2999) return const Color(0xFF15803D);
    if (total >= 999) return const Color(0xFF16A34A);
    return const Color(0xFF22C55E);
  }
  static const _tier3pct = 2999.0;
  static const _tier5pct = 6999.0;
  static const _tier6pct = 8999.0;
  static const _tier7pct = 18999.0;

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
    final total = cart.mrpTotal;
    final uniqueItems = cart.distinctItems;

    if (uniqueItems == 0 && !_slideCtrl.isAnimating) {
      return const SizedBox.shrink();
    }

    final double progress;
    final Widget leftContent;

    if (total >= _tier7pct) {
      progress = 1.0;
      leftContent = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('🎉', style: TextStyle(fontSize: 13)),
          SizedBox(width: 5),
          Flexible(
            child: Text(
              '7% discount unlocked! (maximum)',
              style: TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    } else if (total >= _tier6pct) {
      progress = (total - _tier6pct) / (_tier7pct - _tier6pct);
      final remaining = (_tier7pct - total).ceil();
      leftContent =
          _UnlockedTierText(unlockedLabel: '6%', nextPct: 7, remaining: remaining);
    } else if (total >= _tier5pct) {
      progress = (total - _tier5pct) / (_tier6pct - _tier5pct);
      final remaining = (_tier6pct - total).ceil();
      leftContent =
          _UnlockedTierText(unlockedLabel: '5%', nextPct: 6, remaining: remaining);
    } else if (total >= _tier3pct) {
      progress = (total - _tier3pct) / (_tier5pct - _tier3pct);
      final remaining = (_tier5pct - total).ceil();
      leftContent =
          _UnlockedTierText(unlockedLabel: '3%', nextPct: 5, remaining: remaining);
    } else if (total >= _tierFreeDelivery) {
      progress = (total - _tierFreeDelivery) / (_tier3pct - _tierFreeDelivery);
      final remaining = (_tier3pct - total).ceil();
      leftContent = _UnlockedTierText(
          unlockedLabel: 'FREE delivery', nextPct: 3, remaining: remaining);
    } else {
      progress = total > 0 ? total / _tierFreeDelivery : 0.0;
      final remaining = (_tierFreeDelivery - total).ceil();
      leftContent =
          _DiscountText(amount: '₹$remaining', suffix: ' more for FREE delivery');
    }

    return SlideTransition(
      position: _slideAnim,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut,
          height: 64,
          decoration: BoxDecoration(
            color: _tierBgColor(total),
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 0),
                  child: Row(
                    children: [
                      Expanded(child: leftContent),
                      _CartChip(uniqueItems: uniqueItems),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: LayoutBuilder(
                  builder: (_, constraints) => Stack(
                    children: [
                      Container(
                        height: 4,
                        width: constraints.maxWidth,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.25),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOut,
                        height: 4,
                        width: constraints.maxWidth * progress.clamp(0.0, 1.0),
                        decoration: BoxDecoration(
                          color: Colors.white,
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

// ─────────────────────── Desktop top bar (Row 1) ───────────────────────

// ─────────────────────── Desktop single-row header ───────────────────────

class _DesktopHeader extends StatefulWidget {
  final TextEditingController searchCtrl;
  final bool isLoading;
  final bool scrolled;
  final ValueChanged<String> onSearch;
  final VoidCallback onScrollToResults;
  final VoidCallback onHome;
  final VoidCallback onBulk;
  final VoidCallback onOrders;
  final VoidCallback onCart;
  final VoidCallback onLogin;
  final int index;
  final bool cartOpen;

  const _DesktopHeader({
    required this.searchCtrl,
    required this.isLoading,
    required this.onSearch,
    required this.onScrollToResults,
    required this.onHome,
    required this.onBulk,
    required this.onOrders,
    required this.onCart,
    required this.onLogin,
    required this.index,
    required this.cartOpen,
    this.scrolled = false,
  });

  @override
  State<_DesktopHeader> createState() => _DesktopHeaderState();
}

class _DesktopHeaderState extends State<_DesktopHeader> {
  Timer? _debounce;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    widget.searchCtrl.addListener(_onControllerChange);
    _hasText = widget.searchCtrl.text.isNotEmpty;
  }

  @override
  void dispose() {
    widget.searchCtrl.removeListener(_onControllerChange);
    _debounce?.cancel();
    super.dispose();
  }

  void _onControllerChange() {
    final hasText = widget.searchCtrl.text.isNotEmpty;
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
    final text = widget.searchCtrl.text;
    widget.onSearch(text);
    if (text.trim().length >= 2) widget.onScrollToResults();
    FocusManager.instance.primaryFocus?.unfocus();
  }

  void _clearSearch() {
    _debounce?.cancel();
    widget.searchCtrl.clear();
    widget.onSearch('');
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    final cartItems = AppState.of(context).distinctItems;
    final isBulk = widget.index == 2 && !widget.cartOpen;
    final isOrders = widget.index == 1 && !widget.cartOpen;

    final shadow = BoxShadow(
      color: Colors.black.withValues(
          alpha: widget.scrolled ? 0.11 : 0.04),
      blurRadius: widget.scrolled ? 14.0 : 4.0,
      offset: widget.scrolled ? const Offset(0, 4) : const Offset(0, 1),
    );
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      height: 76,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [shadow],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. Logo — 250px, padded 24px left, aligns with category sidebar
          SizedBox(
            width: 250,
            child: Padding(
              padding: const EdgeInsets.only(left: 24),
              child: GestureDetector(
                onTap: widget.onHome,
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
                          TextSpan(
                            text: 'medi',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1B5E20),
                              letterSpacing: -0.3,
                            ),
                          ),
                          TextSpan(
                            text: 'BO',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF4CAF50),
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
          ),
          // 2. Search bar — fills all remaining space, 24px margin each side
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                height: 46,
                decoration: BoxDecoration(
                  color: const Color(0xFFF9FAFB),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFD1D5DB)),
                ),
                child: Row(
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14),
                      child: Icon(Icons.search,
                          color: Color(0xFF9CA3AF), size: 20),
                    ),
                    Expanded(
                      child: TextField(
                        controller: widget.searchCtrl,
                        onChanged: _onChanged,
                        onSubmitted: (_) => _submitNow(),
                        textInputAction: TextInputAction.search,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.text,
                        style: const TextStyle(fontSize: 14, color: Brand.ink),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          hintText: 'Search for medicines',
                          hintStyle:
                              TextStyle(color: Brand.inkMuted, fontSize: 14),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(vertical: 14),
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
                              strokeWidth: 2, color: Brand.green),
                        ),
                      )
                    else if (_hasText)
                      IconButton(
                        onPressed: _clearSearch,
                        icon: const Icon(Icons.close,
                            size: 18, color: Color(0xFF6B7280)),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
                    // Green Search button attached to right edge
                    GestureDetector(
                      onTap: _submitNow,
                      child: Container(
                        height: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        decoration: const BoxDecoration(
                          color: Brand.green,
                          borderRadius: BorderRadius.only(
                            topRight: Radius.circular(9),
                            bottomRight: Radius.circular(9),
                          ),
                        ),
                        child: const Center(
                          child: Text(
                            'Search',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 3. Bulk Upload
          _DesktopNavLink(
            label: 'Bulk Upload',
            icon: Icons.upload_file_outlined,
            selected: isBulk,
            onTap: widget.onBulk,
          ),
          const SizedBox(width: 4),
          // 4. Orders
          _DesktopNavLink(
            label: 'Orders',
            icon: Icons.receipt_long_outlined,
            selected: isOrders,
            onTap: widget.onOrders,
          ),
          const SizedBox(width: 8),
          // 5. Cart
          PressEffect(
            child: InkWell(
              onTap: widget.onCart,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Badge(
                      isLabelVisible: cartItems > 0,
                      label: Text('$cartItems',
                          style: const TextStyle(fontSize: 10)),
                      child: const Icon(Icons.shopping_cart_outlined,
                          size: 22, color: Brand.ink),
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      'Cart',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Brand.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          // 6. Auth button (Login or profile dropdown) — far right
          _DesktopProfileButton(onLogin: widget.onLogin),
          const SizedBox(width: 24),
        ],
      ),
    );
  }
}

// ─────────────────────── Profile buttons ────────────────────────────────

/// Desktop: solid green "Login" button when logged out;
/// "Hello [name]" avatar pill with dropdown when logged in.
class _DesktopProfileButton extends StatelessWidget {
  final VoidCallback onLogin;
  const _DesktopProfileButton({required this.onLogin});

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);

    if (!auth.isAuthenticated) {
      return PressEffect(
        child: InkWell(
          onTap: onLogin,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1D9E75),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              'Login',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
      );
    }

    final profile = auth.profile;
    final displayName = profile?.displayName ?? 'Account';
    final initial = displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';
    final shortName =
        displayName.length > 16 ? '${displayName.substring(0, 14)}…' : displayName;

    return PopupMenuButton<String>(
      offset: const Offset(0, 52),
      tooltip: '',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'profile',
          child: const Row(
            children: [
              Icon(Icons.person_outline, size: 16, color: Color(0xFF374151)),
              SizedBox(width: 10),
              Text('View Profile',
                  style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'logout',
          child: const Row(
            children: [
              Icon(Icons.logout, size: 16, color: Color(0xFFDC2626)),
              SizedBox(width: 10),
              Text('Logout',
                  style: TextStyle(fontSize: 14, color: Color(0xFFDC2626))),
            ],
          ),
        ),
      ],
      onSelected: (val) async {
        if (val == 'profile' && context.mounted) {
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const ProfileScreen()));
        }
        if (val == 'logout') await UserState.read(context).signOut();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFECFDF5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFBBF7D0)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                color: Color(0xFF1B5E20),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    height: 1,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Text(
              'Hello $shortName',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.expand_more, size: 16, color: Color(0xFF6B7280)),
          ],
        ),
      ),
    );
  }
}

/// Mobile: compact person icon that opens a profile bottom sheet.
class _MobileProfileButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);

    return PressEffect(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          if (!auth.isAuthenticated) {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LoginScreen()),
            );
          } else {
            _showProfileSheet(context, auth);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: auth.isAuthenticated
              ? Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1B5E20),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person,
                      color: Colors.white, size: 16),
                )
              : const Icon(Icons.person_outline,
                  size: 26, color: Brand.ink),
        ),
      ),
    );
  }

  void _showProfileSheet(BuildContext context, AuthNotifier auth) {
    final profile = auth.profile;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      backgroundColor: Colors.white,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD1D5DB),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Color(0xFF1B5E20),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person,
                      color: Colors.white, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        profile?.displayName ?? 'Account',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),
                      if (profile?.phone.isNotEmpty == true) ...[
                        const SizedBox(height: 2),
                        Text(
                          profile!.phone,
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF6B7280)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 4),
            InkWell(
              onTap: () {
                Navigator.pop(context);
                Navigator.push(context,
                    MaterialPageRoute(builder: (_) => const ProfileScreen()));
              },
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.person_outline,
                        size: 20, color: Color(0xFF374151)),
                    SizedBox(width: 12),
                    Text(
                      'View Profile',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF374151),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            InkWell(
              onTap: () async {
                Navigator.pop(context);
                await auth.signOut();
              },
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding:
                    EdgeInsets.symmetric(horizontal: 4, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.logout,
                        size: 20, color: Color(0xFFDC2626)),
                    SizedBox(width: 12),
                    Text(
                      'Logout',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────── Desktop category sidebar ───────────────────────

class _DesktopCategorySidebar extends StatelessWidget {
  final CatalogMeta? meta;
  final String selected;
  final ValueChanged<String> onCategorySelected;

  const _DesktopCategorySidebar({
    required this.meta,
    required this.selected,
    required this.onCategorySelected,
  });

  @override
  Widget build(BuildContext context) {
    final m = meta;

    // Build items: "All" first, then every category sorted by count desc.
    final items = m == null
        ? <(String, String, int)>[]
        : [
            ('All', 'All Products', m.total),
            ...(List<CategoryCount>.from(m.categories)
                  ..sort((a, b) => b.count.compareTo(a.count)))
                .map((c) => (c.name, prettyCategory(c.name), c.count)),
          ];

    return Container(
      width: 250,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 12),
            child: Text(
              'CATEGORIES',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xFF9CA3AF),
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: m == null
                ? const Center(
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Brand.green),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    children: [
                      for (final (key, label, count) in items)
                        _SidebarCategoryRow(
                          catKey: key,
                          label: label,
                          count: count,
                          isSelected: selected == key,
                          onTap: () => onCategorySelected(key),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _SidebarCategoryRow extends StatelessWidget {
  final String catKey;
  final String label;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarCategoryRow({
    required this.catKey,
    required this.label,
    required this.count,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = catKey == 'All'
        ? const CategoryStyle(Brand.mint, Brand.green, Icons.grid_view_rounded)
        : categoryStyle(catKey);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.only(bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFECFDF5) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: style.bg,
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(style.icon, size: 16, color: style.fg),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight:
                      isSelected ? FontWeight.w700 : FontWeight.w500,
                  color: isSelected ? Brand.green : const Color(0xFF374151),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (count > 0)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? const Color(0xFFDCFCE7)
                      : const Color(0xFFF3F4F6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isSelected
                        ? Brand.green
                        : const Color(0xFF6B7280),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// Simple hover text link (with optional icon) used inside the desktop header
class _DesktopNavLink extends StatefulWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback onTap;

  const _DesktopNavLink({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  @override
  State<_DesktopNavLink> createState() => _DesktopNavLinkState();
}

class _DesktopNavLinkState extends State<_DesktopNavLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final highlight = widget.selected || _hovered;
    final color = highlight ? Brand.green : const Color(0xFF374151);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 16, color: color),
                const SizedBox(width: 5),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight:
                      widget.selected ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

