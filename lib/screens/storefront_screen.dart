import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../data/medicine_repository.dart';
import '../models/product.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/animations.dart';
import '../widgets/product_card.dart';

const double _kMaxContent = 1200;

/// The mediBO storefront: hero, dynamic category tiles, an infinite-scroll
/// product grid, trust badges and footer.
///
/// Categories + counts come live from [MedicineRepository.fetchCatalogMeta];
/// products load [MedicineRepository.pageSize] at a time and keep paging in as
/// the user scrolls. Search/category filter state lives in the shell and is
/// passed down — changing either resets the grid to page one.
class StorefrontScreen extends StatefulWidget {
  final String query;
  final String category;
  final ValueChanged<String> onCategorySelected;
  final ValueChanged<String> onSuggestionTap;
  final MedicineRepository repo;

  const StorefrontScreen({
    super.key,
    required this.query,
    required this.category,
    required this.onCategorySelected,
    required this.onSuggestionTap,
    required this.repo,
  });

  @override
  State<StorefrontScreen> createState() => _StorefrontScreenState();
}

class _StorefrontScreenState extends State<StorefrontScreen> {
  // Web uses a plain controller — no ballistic momentum after wheel events.
  // Mobile uses MomentumScrollController for touch-fling deceleration.
  late final ScrollController _scroll =
      kIsWeb ? ScrollController() : MomentumScrollController();
  final GlobalKey _productsKey = GlobalKey();

  // Category metadata (tiles + counts).
  CatalogMeta? _meta;
  Object? _metaError;

  // Paginated product list for the current filter.
  final List<Product> _items = [];
  int _loadToken = 0; // invalidates in-flight requests on filter change
  bool _loadingFirst = true;
  bool _loadingMore = false;
  bool _reachedEnd = false;
  Object? _pageError;
  List<String> _suggestions = [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadMeta();
    _resetAndLoad();
  }

  @override
  void didUpdateWidget(StorefrontScreen old) {
    super.didUpdateWidget(old);
    if (old.category != widget.category || old.query != widget.query) {
      _resetAndLoad();
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadMeta() async {
    try {
      final meta = await widget.repo.fetchCatalogMeta();
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _metaError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _metaError = e);
    }
  }

  Future<void> _resetAndLoad() async {
    final token = ++_loadToken;
    setState(() {
      _items.clear();
      _loadingFirst = true;
      _loadingMore = false;
      _reachedEnd = false;
      _pageError = null;
      _suggestions = [];
    });
    try {
      final page = await widget.repo.fetchPage(
        category: widget.category,
        query: widget.query,
        offset: 0,
      );
      if (token != _loadToken || !mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page);
        _loadingFirst = false;
        _reachedEnd = page.length < MedicineRepository.pageSize;
      });
      _maybeAutoFill();
      if (page.isEmpty && widget.query.trim().isNotEmpty) {
        _loadSuggestions();
      }
    } catch (e) {
      if (token != _loadToken || !mounted) return;
      setState(() {
        _loadingFirst = false;
        _pageError = e;
      });
    }
  }

  Future<void> _loadSuggestions() async {
    final suggestions = await widget.repo.fetchSuggestions(widget.query);
    if (!mounted) return;
    setState(() => _suggestions = suggestions);
  }

  Future<void> _loadMore() async {
    if (_loadingFirst || _loadingMore || _reachedEnd) return;
    final token = _loadToken;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.repo.fetchPage(
        category: widget.category,
        query: widget.query,
        offset: _items.length,
      );
      if (token != _loadToken || !mounted) return;
      setState(() {
        _items.addAll(page);
        _loadingMore = false;
        _reachedEnd = page.length < MedicineRepository.pageSize;
      });
      _maybeAutoFill();
    } catch (e) {
      if (token != _loadToken || !mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.pixels >= pos.maxScrollExtent - 800) _loadMore();
  }

  /// If the freshly loaded content barely fills the viewport, pull another
  /// page so there's always something to scroll into.
  void _maybeAutoFill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final pos = _scroll.position;
      if (!_reachedEnd &&
          !_loadingMore &&
          !_loadingFirst &&
          pos.maxScrollExtent <= pos.viewportDimension * 0.6) {
        _loadMore();
      }
    });
  }

  void _scrollToProducts() {
    final ctx = _productsKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 450), curve: Curves.easeOut);
    }
  }

  int _categoryTotal() {
    final meta = _meta;
    if (meta == null) return _items.length;
    if (widget.category == 'All') return meta.total;
    for (final c in meta.categories) {
      if (c.name == widget.category) return c.count;
    }
    return _items.length;
  }

  List<String> get _categoryNames =>
      _meta?.categories.map((c) => c.name).toList(growable: false) ??
      const <String>[];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scroll,
      physics: platformScrollPhysics(),
      child: Column(
        children: [
          _Hero(onShopNow: _scrollToProducts),
          _Section(
            child: _CategoryTiles(
              meta: _meta,
              metaError: _metaError,
              selected: widget.category,
              onRetry: _loadMeta,
              onSelected: (c) {
                widget.onCategorySelected(c);
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => _scrollToProducts());
              },
            ),
          ),
          _Section(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
            child: const _PromoStrip(),
          ),
          Container(
            key: _productsKey,
            color: Brand.section,
            width: double.infinity,
            child: _Section(
              child: _ProductsSection(
                items: _items,
                categoryTotal: _categoryTotal(),
                query: widget.query,
                category: widget.category,
                loadingFirst: _loadingFirst,
                loadingMore: _loadingMore,
                reachedEnd: _reachedEnd,
                error: _pageError,
                suggestions: _suggestions,
                onClear: () => widget.onCategorySelected('All'),
                onRetry: _resetAndLoad,
                onSuggestionTap: widget.onSuggestionTap,
              ),
            ),
          ),
          const _TrustBadges(),
          _Footer(
            categories: _categoryNames,
            onCategory: widget.onCategorySelected,
          ),
        ],
      ),
    );
  }
}

/// Centers content to [_kMaxContent] with standard horizontal padding.
class _Section extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _Section({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kMaxContent),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final String? trailing;
  const _SectionHeader({required this.title, required this.subtitle, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w800, color: Brand.ink)),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: const TextStyle(fontSize: 13, color: Brand.inkMuted)),
            ],
          ),
        ),
        if (trailing != null)
          Row(
            children: [
              Text(trailing!,
                  style: const TextStyle(
                      color: Brand.green, fontWeight: FontWeight.w700, fontSize: 13)),
              const Icon(Icons.arrow_forward, size: 15, color: Brand.green),
            ],
          ),
      ],
    );
  }
}

// ─────────────────────────── Hero ───────────────────────────

class _Hero extends StatelessWidget {
  final VoidCallback onShopNow;
  const _Hero({required this.onShopNow});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Brand.greenDark, Brand.greenDarker],
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kMaxContent),
          child: LayoutBuilder(
            builder: (context, c) {
              final wide = c.maxWidth >= 820;
              final text = _heroText(context, wide: wide);
              return Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: wide ? 44 : 28,
                ),
                child: wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(flex: 6, child: text),
                          const SizedBox(width: 32),
                          const Expanded(flex: 5, child: _HeroArt()),
                        ],
                      )
                    : text,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _heroText(BuildContext context, {bool wide = true}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text('● New Arrivals',
              style: TextStyle(
                  color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 18),
        Text(
          'Health, Delivered\nwith Care',
          style: TextStyle(
              color: Colors.white,
              fontSize: wide ? 44 : 30,
              height: 1.1,
              fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 14),
        Text(
          'Genuine medicines & wellness products delivered to your '
          'doorstep in hours.',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: wide ? 15 : 13,
              height: 1.4),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            PressEffect(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Brand.greenDark,
                ),
                onPressed: onShopNow,
                icon: const Icon(Icons.storefront, size: 18),
                label: const Text('Shop Now'),
              ),
            ),
            PressEffect(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                ),
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Prescription upload — coming soon')),
                ),
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Upload Rx'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 26),
        Wrap(
          spacing: 28,
          runSpacing: 12,
          children: const [
            _HeroStat(value: '4,400+', label: 'Medicines'),
            _HeroStat(value: '2 hr', label: 'Fast Delivery'),
            _HeroStat(value: '100%', label: 'Genuine'),
          ],
        ),
      ],
    );
  }
}

class _HeroStat extends StatelessWidget {
  final String value;
  final String label;
  const _HeroStat({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: const TextStyle(
                color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8), fontSize: 12)),
      ],
    );
  }
}

class _HeroArt extends StatelessWidget {
  const _HeroArt();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 260,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1F6F52), Color(0xFF155E40)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Stack(
        children: [
          const Center(
            child: Icon(Icons.medication_liquid, size: 110, color: Colors.white24),
          ),
          Positioned(
            top: 18,
            right: 18,
            child: _FloatingBadge(
              icon: Icons.bolt,
              title: 'Express Delivery',
              subtitle: 'In 2 hours',
            ),
          ),
          Positioned(
            bottom: 18,
            left: 18,
            child: _FloatingBadge(
              icon: Icons.verified_user,
              title: 'Verified Pharmacy',
              subtitle: '100% genuine',
            ),
          ),
        ],
      ),
    );
  }
}

class _FloatingBadge extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _FloatingBadge(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.12),
              blurRadius: 12,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: Brand.green),
          const SizedBox(width: 8),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w700, color: Brand.ink)),
              Text(subtitle,
                  style: const TextStyle(fontSize: 10, color: Brand.inkMuted)),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Category tiles ───────────────────────

class _CategoryTiles extends StatelessWidget {
  final CatalogMeta? meta;
  final Object? metaError;
  final String selected;
  final ValueChanged<String> onSelected;
  final VoidCallback onRetry;
  const _CategoryTiles({
    required this.meta,
    required this.metaError,
    required this.selected,
    required this.onSelected,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
            title: 'Shop by Category',
            subtitle: 'Browse by therapeutic class',
            trailing: 'View All'),
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, constraints) {
            final cols = constraints.maxWidth >= 800
                ? 6
                : constraints.maxWidth >= 500
                    ? 4
                    : 3;
            final compact = constraints.maxWidth < 600;
            final extent = compact ? 100.0 : 120.0;

            if (meta == null && metaError == null) {
              return Shimmer(
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    mainAxisExtent: extent,
                  ),
                  itemCount: 10,
                  itemBuilder: (_, __) => const _SkeletonTile(),
                ),
              );
            }

            if (metaError != null) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.wifi_off_rounded, size: 56, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text("It seems you're offline",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  const Text(
                    'Please check your internet connection and try again',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Brand.inkMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: onRetry,
                    style: FilledButton.styleFrom(backgroundColor: Brand.green),
                    child: const Text('Retry'),
                  ),
                ],
              );
            }

            final categories = meta!.categories;
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                mainAxisExtent: extent,
              ),
              itemCount: 1 + categories.length,
              itemBuilder: (context, idx) {
                if (idx == 0) {
                  return _CategoryTile(
                    category: 'All',
                    count: meta!.total,
                    selected: selected == 'All',
                    compact: compact,
                    onTap: () => onSelected('All'),
                  );
                }
                final cat = categories[idx - 1];
                return _CategoryTile(
                  category: cat.name,
                  count: cat.count,
                  selected: selected == cat.name,
                  compact: compact,
                  onTap: () => onSelected(cat.name),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final String category;
  final int count;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  const _CategoryTile({
    required this.category,
    required this.count,
    required this.selected,
    this.compact = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final style = category == 'All'
        ? const CategoryStyle(Brand.mint, Brand.green, Icons.grid_view_rounded)
        : categoryStyle(category);
    final iconBox = compact ? 40.0 : 52.0;
    final iconSz  = compact ? 20.0 : 26.0;
    final nameFs  = compact ? 10.0 : 11.0;
    final countFs = compact ?  9.0 : 10.0;

    return PressEffect(
      scale: 0.92,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? Brand.green : Brand.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: iconBox,
                height: iconBox,
                decoration: BoxDecoration(
                  color: style.bg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(style.icon, size: iconSz, color: style.fg),
              ),
              SizedBox(height: compact ? 4 : 6),
              Text(
                category == 'All' ? 'All' : prettyCategory(category),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: nameFs,
                  fontWeight: FontWeight.w600,
                  color: selected ? Brand.green : Brand.ink,
                  height: 1.15,
                ),
              ),
              SizedBox(height: compact ? 2 : 3),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 5.0 : 7.0,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: selected ? Brand.green : Brand.mint,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: countFs,
                    fontWeight: FontWeight.w700,
                    color: selected ? Colors.white : Brand.greenDark,
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

// ─────────────────────── Promo strip ───────────────────────

class _PromoStrip extends StatelessWidget {
  const _PromoStrip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Brand.green, Color(0xFF12894A)]),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 12,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.local_offer, color: Colors.white, size: 22),
              SizedBox(width: 10),
              Text('Get 15% off on your first order',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white54),
                ),
                child: const Text('FIRST15',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1)),
              ),
              const SizedBox(width: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Brand.greenDark),
                onPressed: () {},
                child: const Text('Register Now'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Products grid ───────────────────────

class _ProductsSection extends StatelessWidget {
  final List<Product> items;
  final int categoryTotal;
  final String query;
  final String category;
  final bool loadingFirst;
  final bool loadingMore;
  final bool reachedEnd;
  final Object? error;
  final List<String> suggestions;
  final VoidCallback onClear;
  final VoidCallback onRetry;
  final ValueChanged<String> onSuggestionTap;
  const _ProductsSection({
    required this.items,
    required this.categoryTotal,
    required this.query,
    required this.category,
    required this.loadingFirst,
    required this.loadingMore,
    required this.reachedEnd,
    required this.error,
    required this.suggestions,
    required this.onClear,
    required this.onRetry,
    required this.onSuggestionTap,
  });

  @override
  Widget build(BuildContext context) {
    final searching = query.trim().isNotEmpty;
    final filtering = category != 'All' || searching;
    final title = category == 'All' ? 'Best Sellers' : prettyCategory(category);
    final resultCount = items.length;
    final subtitle = searching
        ? 'Showing $resultCount${reachedEnd ? '' : '+'} result${resultCount == 1 ? '' : 's'} for “${query.trim()}”'
        : 'Showing ${items.length} of $categoryTotal products';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _SectionHeader(title: title, subtitle: subtitle),
            ),
            if (filtering)
              TextButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Clear filter'),
              ),
          ],
        ),
        const SizedBox(height: 20),
        // Cross-fade the grid when the category changes; within a category,
        // appended pages update the grid in place.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: [...previousChildren, ?currentChild],
          ),
          child: KeyedSubtree(
            key: ValueKey('grid-$category-$searching'),
            child: _gridBody(),
          ),
        ),
        const SizedBox(height: 24),
        _PageFooter(
          loadingMore: loadingMore,
          reachedEnd: reachedEnd && items.length > MedicineRepository.pageSize,
        ),
      ],
    );
  }

  Widget _gridBody() {
    if (loadingFirst) return const _SkeletonGrid();
    if (error != null) {
      return _InlineError(onRetry: onRetry);
    }
    if (items.isEmpty) return _EmptyResults(query: query, suggestions: suggestions, onSuggestionTap: onSuggestionTap);
    return LayoutBuilder(
      builder: (context, c) {
        final count = c.maxWidth >= 900 ? 4 : c.maxWidth >= 600 ? 3 : 2;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          addAutomaticKeepAlives: false,
          addRepaintBoundaries: true,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: count,
            mainAxisExtent: 375,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
          ),
          itemCount: items.length,
          itemBuilder: (context, i) => EntranceAnimator(
            key: ValueKey(items[i].id),
            delay: Duration(milliseconds: ((i % MedicineRepository.pageSize) * 30)
                .clamp(0, 420)),
            child: ProductCard(product: items[i], isBestSeller: i < 3),
          ),
        );
      },
    );
  }
}

/// Bottom-of-grid status: a spinner while the next page loads, or an
/// end-of-list note once everything for the filter has been shown.
class _PageFooter extends StatelessWidget {
  final bool loadingMore;
  final bool reachedEnd;
  const _PageFooter({required this.loadingMore, required this.reachedEnd});

  @override
  Widget build(BuildContext context) {
    if (loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.6, color: Brand.green),
          ),
        ),
      );
    }
    if (reachedEnd) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text("You've reached the end of this category",
              style: TextStyle(color: Brand.inkMuted, fontSize: 12)),
        ),
      );
    }
    return const SizedBox(height: 4);
  }
}

class _EmptyResults extends StatelessWidget {
  final String query;
  final List<String> suggestions;
  final ValueChanged<String> onSuggestionTap;
  const _EmptyResults({
    this.query = '',
    this.suggestions = const [],
    required this.onSuggestionTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = query.trim().isNotEmpty
        ? 'No results for "${query.trim()}"'
        : 'No products match your search.';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 60),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off, size: 48, color: Brand.inkMuted),
          const SizedBox(height: 12),
          Text(label,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Brand.ink)),
          const SizedBox(height: 6),
          const Text('Check spelling or try a different name.',
              style: TextStyle(color: Brand.inkMuted, fontSize: 13)),
          if (suggestions.isNotEmpty) ...[
            const SizedBox(height: 20),
            const Text('Did you mean:',
                style: TextStyle(
                    color: Brand.inkMuted,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: suggestions
                  .map((s) => ActionChip(
                        label: Text(s,
                            style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500)),
                        onPressed: () => onSuggestionTap(s),
                        backgroundColor: Brand.mint,
                        side: BorderSide(color: Brand.green.withValues(alpha: 0.3)),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  final VoidCallback onRetry;
  const _InlineError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 48),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.wifi_off_rounded, size: 56, color: Colors.grey),
          const SizedBox(height: 16),
          const Text("It seems you're offline",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text(
            'Please check your internet connection and try again',
            textAlign: TextAlign.center,
            style: TextStyle(color: Brand.inkMuted, fontSize: 13),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: onRetry,
            style: FilledButton.styleFrom(backgroundColor: Brand.green),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────── Trust badges ───────────────────────

class _TrustBadges extends StatelessWidget {
  const _TrustBadges();

  @override
  Widget build(BuildContext context) {
    return _Section(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 24,
        runSpacing: 20,
        children: const [
          _TrustItem(
              icon: Icons.verified,
              title: '100% Genuine',
              subtitle: 'Sourced from licensed distributors'),
          _TrustItem(
              icon: Icons.local_shipping,
              title: 'Express Delivery',
              subtitle: '2–4 hour delivery available'),
          _TrustItem(
              icon: Icons.lock,
              title: 'Secure Payments',
              subtitle: 'Encrypted payment gateway'),
          _TrustItem(
              icon: Icons.replay,
              title: 'Easy Returns',
              subtitle: '7-day hassle-free returns'),
        ],
      ),
    );
  }
}

class _TrustItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _TrustItem(
      {required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 250,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
                color: Brand.mint, borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: Brand.green, size: 22),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, color: Brand.ink)),
                Text(subtitle,
                    style: const TextStyle(fontSize: 12, color: Brand.inkMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── Footer ───────────────────────────

class _Footer extends StatelessWidget {
  final List<String> categories;
  final ValueChanged<String> onCategory;
  const _Footer({required this.categories, required this.onCategory});

  @override
  Widget build(BuildContext context) {
    // Show a manageable slice of categories in the footer.
    final shown = categories.take(8).toList();
    return Container(
      width: double.infinity,
      color: Brand.greenDarker,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kMaxContent),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 44),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 48,
                  runSpacing: 32,
                  children: [
                    SizedBox(
                      width: 280,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: const [
                              Icon(Icons.local_pharmacy,
                                  color: Brand.green, size: 26),
                              SizedBox(width: 8),
                              Text('mediBO',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w800)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            'Your trusted B2B pharmacy distributor delivering '
                            'genuine medicines to pharmacies & clinics.',
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 13,
                                height: 1.5),
                          ),
                          const SizedBox(height: 14),
                          const _FooterContact(
                              icon: Icons.call, text: '1800-123-4567 (Toll Free)'),
                          const _FooterContact(
                              icon: Icons.mail, text: 'care@medibo.in'),
                        ],
                      ),
                    ),
                    _FooterLinks(
                      title: 'Shop by Category',
                      links: [for (final c in shown) prettyCategory(c)],
                      values: shown,
                      onTap: onCategory,
                    ),
                    const _FooterLinks(
                      title: 'Our Services',
                      links: [
                        'Upload Prescription',
                        'Book Lab Test',
                        'Track Your Order',
                        'Refill Prescription',
                      ],
                    ),
                    const _FooterLinks(
                      title: 'Company',
                      links: [
                        'About Us',
                        'Careers',
                        'Blog & Health Articles',
                        'Store Locator',
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 36),
                Divider(color: Colors.white.withValues(alpha: 0.12)),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  runSpacing: 12,
                  children: [
                    Text(
                      '© 2026 mediBO Pharmacy Pvt. Ltd. · Lic. No: PH/MH/2024/001234',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 12),
                    ),
                    Wrap(
                      spacing: 8,
                      children: const [
                        _PayChip('Visa'),
                        _PayChip('Mastercard'),
                        _PayChip('UPI'),
                        _PayChip('NetBanking'),
                        _PayChip('COD'),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FooterContact extends StatelessWidget {
  final IconData icon;
  final String text;
  const _FooterContact({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 15, color: Colors.white.withValues(alpha: 0.7)),
          const SizedBox(width: 8),
          Text(text,
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8), fontSize: 13)),
        ],
      ),
    );
  }
}

class _FooterLinks extends StatelessWidget {
  final String title;
  final List<String> links;
  /// Raw values passed to [onTap]; defaults to [links] when omitted.
  final List<String>? values;
  final ValueChanged<String>? onTap;
  const _FooterLinks(
      {required this.title, required this.links, this.values, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(
                color: Colors.white, fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        for (var i = 0; i < links.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              onTap: onTap == null
                  ? null
                  : () => onTap!((values ?? links)[i]),
              child: Text(links[i],
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.72), fontSize: 13)),
            ),
          ),
      ],
    );
  }
}

class _PayChip extends StatelessWidget {
  final String label;
  const _PayChip(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85), fontSize: 11)),
    );
  }
}

// ─────────────────────── Loading skeletons ───────────────────────

/// Shimmering placeholder grid shown while the first page of a filter loads.
class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: LayoutBuilder(
        builder: (context, c) {
          final count = c.maxWidth >= 900 ? 4 : c.maxWidth >= 600 ? 3 : 2;
          return GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              mainAxisExtent: 375,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
            ),
            itemCount: count * 2,
            itemBuilder: (context, i) => const _SkeletonCard(),
          );
        },
      ),
    );
  }
}

class _SkeletonTile extends StatelessWidget {
  const _SkeletonTile();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Brand.border),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SkeletonBox(width: 40, height: 40, radius: 10),
          SizedBox(height: 6),
          SkeletonBox(width: 50, height: 9),
          SizedBox(height: 3),
          SkeletonBox(width: 28, height: 8),
        ],
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  const _SkeletonCard();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Brand.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          SizedBox(
            width: double.infinity,
            height: 138,
            child: ColoredBox(color: Brand.border),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(width: 130, height: 14),
                SizedBox(height: 8),
                SkeletonBox(width: 90, height: 11),
                SizedBox(height: 10),
                SkeletonBox(width: 100, height: 11),
                SizedBox(height: 14),
                SkeletonBox(width: 70, height: 16),
                SizedBox(height: 12),
                SkeletonBox(width: double.infinity, height: 38, radius: 10),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
