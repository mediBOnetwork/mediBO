import 'dart:async';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:js' as js;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../data/medicine_repository.dart';
import '../models/product.dart';
import '../theme.dart';
import '../util.dart';
import '../widgets/animations.dart';
import '../widgets/product_card.dart';
import 'about_screen.dart';
import 'contact_screen.dart';

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
  // Incremented by the parent on explicit search submit (button / Enter).
  // StorefrontScreen scrolls to the results section whenever this changes.
  final int scrollTrigger;
  // Incremented when the search is cleared or drops below 2 chars.
  // StorefrontScreen smoothly scrolls back to the top whenever this changes.
  final int scrollToTopTrigger;
  // Called with true when a load starts, false when it completes or errors.
  final ValueChanged<bool>? onLoadingChanged;

  // When false (desktop), the category tile grid is hidden; the shell sidebar
  // handles category filtering instead.
  final bool showCategoryTiles;
  // Called once after CatalogMeta loads so the shell can populate its sidebar.
  final ValueChanged<CatalogMeta>? onMetaLoaded;

  // Footer navigation callbacks.
  final VoidCallback? onFooterSearch;
  final VoidCallback? onFooterBulkUpload;
  final VoidCallback? onFooterOrders;
  final VoidCallback? onFooterCart;

  const StorefrontScreen({
    super.key,
    required this.query,
    required this.category,
    required this.onCategorySelected,
    required this.onSuggestionTap,
    required this.repo,
    this.scrollTrigger = 0,
    this.scrollToTopTrigger = 0,
    this.onLoadingChanged,
    this.showCategoryTiles = true,
    this.onMetaLoaded,
    this.onFooterSearch,
    this.onFooterBulkUpload,
    this.onFooterOrders,
    this.onFooterCart,
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

  // Captcha-gated pagination: 1 = first 100 shown, 2 = up to 200 shown.
  int _paginationPage = 1;
  bool _captchaLoading = false;
  // true while products are being drip-fed one-by-one after captcha
  bool _addingItems = false;
  // items at/above this index get the slide-in entrance animation
  int _animatedFrom = 0;

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
    if (old.scrollTrigger != widget.scrollTrigger) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scrollToProducts());
    }
    if (old.scrollToTopTrigger != widget.scrollToTopTrigger) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scrollToTop());
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
      widget.onMetaLoaded?.call(meta);
    } catch (e) {
      if (!mounted) return;
      setState(() => _metaError = e);
    }
  }

  Future<void> _resetAndLoad() async {
    final token = ++_loadToken;
    widget.onLoadingChanged?.call(true);
    setState(() {
      _items.clear();
      _loadingFirst = true;
      _loadingMore = false;
      _reachedEnd = false;
      _pageError = null;
      _suggestions = [];
      _paginationPage = 1;
      _captchaLoading = false;
      _addingItems = false;
      _animatedFrom = 0;
    });
    try {
      final page = await widget.repo.fetchPage(
        category: widget.category,
        query: widget.query,
        offset: 0,
      );
      if (token != _loadToken || !mounted) return;
      widget.onLoadingChanged?.call(false);
      setState(() {
        _items
          ..clear()
          ..addAll(page);
        _loadingFirst = false;
        _reachedEnd = page.length < MedicineRepository.pageSize;
      });
      _maybeAutoFill();
      // After results arrive for a real search query, scroll to the grid.
      if (widget.query.trim().length >= 2) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) { if (mounted) _scrollToProducts(); });
      }
      if (page.isEmpty && widget.query.trim().isNotEmpty) {
        _loadSuggestions();
      }
    } catch (e) {
      if (token != _loadToken || !mounted) return;
      widget.onLoadingChanged?.call(false);
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
    if (_loadingFirst || _loadingMore || _reachedEnd || _addingItems) return;
    if (_paginationPage == 1 && _items.length >= 100) return;
    if (_paginationPage == 2 && _items.length >= 200) return;
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
    if (pos.pixels >= pos.maxScrollExtent - pos.viewportDimension * 0.7) _loadMore();
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

  Future<void> _onLoadMorePressed() async {
    if (_captchaLoading || _addingItems) return;
    setState(() => _captchaLoading = true);
    final captchaToken = await _showRecaptcha();
    if (!mounted) return;
    if (captchaToken == null) {
      setState(() => _captchaLoading = false);
      return;
    }
    final loadToken = _loadToken;
    final offset = _items.length;
    try {
      final page = await widget.repo.fetchPage(
        category: widget.category,
        query: widget.query,
        offset: offset,
        limit: 100,
      );
      if (loadToken != _loadToken || !mounted) return;
      // Record where new items start so _gridBody can animate them,
      // then switch from captcha-spinner to the drip-feed phase.
      setState(() {
        _animatedFrom = _items.length;
        _captchaLoading = false;
        _addingItems = true;
      });
      // Drip-feed each product one at a time so cards slide in individually.
      for (var i = 0; i < page.length; i++) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (loadToken != _loadToken || !mounted) return;
        setState(() => _items.add(page[i]));
      }
      if (loadToken != _loadToken || !mounted) return;
      setState(() {
        _paginationPage = 2;
        _addingItems = false;
        _reachedEnd = page.length < 100;
      });
      // Scroll to the bottom so the last batch of new products is visible.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOut,
          );
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _captchaLoading = false;
        _addingItems = false;
      });
    }
  }

  Future<String?> _showRecaptcha() {
    final completer = Completer<String?>();
    // ignore: deprecated_member_use
    final jsCallback = js.JsFunction.withThis((dynamic _, dynamic token) {
      if (!completer.isCompleted) {
        // JS strings cross the interop boundary as dynamic, not Dart String —
        // convert via toString() and treat empty/null as cancelled.
        final t = token?.toString();
        completer.complete((t != null && t.isNotEmpty) ? t : null);
      }
    });
    js.context.callMethod('showRecaptcha', [jsCallback]);
    return completer.future;
  }

  void _scrollToProducts() {
    final ctx = _productsKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 450), curve: Curves.easeOut);
    }
  }

  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0,
        duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
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
          _Hero(
            onShopNow: _scrollToProducts,
            onUploadOrder: widget.onFooterBulkUpload,
            medicineCount: _meta?.total,
          ),
          if (widget.showCategoryTiles)
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
                paginationPage: _paginationPage,
                captchaLoading: _captchaLoading,
                onLoadMore: _onLoadMorePressed,
                addingItems: _addingItems,
                animatedFrom: _animatedFrom,
              ),
            ),
          ),
          const _TrustBadges(),
          _Footer(
            categories: _categoryNames,
            onCategory: widget.onCategorySelected,
            onSearch: widget.onFooterSearch,
            onBulkUpload: widget.onFooterBulkUpload,
            onOrders: widget.onFooterOrders,
            onCart: widget.onFooterCart,
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
  final int? medicineCount;
  final VoidCallback? onUploadOrder;
  const _Hero({required this.onShopNow, this.medicineCount, this.onUploadOrder});

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

  String _formatCount(int? n) {
    if (n == null || n == 0) return '...';
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return '${buf.toString()}+';
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
                onPressed: onUploadOrder,
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('Upload Order'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 26),
        Wrap(
          spacing: 28,
          runSpacing: 12,
          children: [
            _HeroStat(value: _formatCount(medicineCount), label: 'Medicines'),
            const _HeroStat(value: '2 hr', label: 'Fast Delivery'),
            const _HeroStat(value: '100%', label: 'Genuine'),
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
    return SizedBox(
      height: 260,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.network(
              'https://images.unsplash.com/photo-1584308666744-24d5c474f2ae?w=400',
              fit: BoxFit.cover,
              loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return Container(
                  color: const Color(0xFF1F6F52),
                  child: const Center(
                    child: CircularProgressIndicator(
                        color: Colors.white38, strokeWidth: 2),
                  ),
                );
              },
              errorBuilder: (ctx, _, __) => Container(
                color: const Color(0xFF1F6F52),
                child: const Center(
                  child: Icon(Icons.medication_liquid,
                      size: 110, color: Colors.white24),
                ),
              ),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 80,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [Colors.black45, Colors.transparent],
                  ),
                ),
              ),
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
                  itemBuilder: (ctx, i) => const _SkeletonTile(),
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
    final iconSz  = compact ? 26.0 : 32.0;
    final nameFs  = compact ? 10.0 : 11.0;
    final countFs = compact ?  9.0 : 10.0;

    return PressEffect(
      scale: 0.92,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          // The colored background fills the entire card.
          decoration: BoxDecoration(
            color: style.bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? style.fg : Colors.transparent,
              width: selected ? 2 : 0,
            ),
          ),
          padding: EdgeInsets.symmetric(vertical: compact ? 8 : 10, horizontal: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Icon centered on the colored card.
              Icon(style.icon, size: iconSz, color: style.fg),
              SizedBox(height: compact ? 5 : 7),
              Text(
                category == 'All' ? 'All' : prettyCategory(category),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: nameFs,
                  fontWeight: FontWeight.w700,
                  color: style.fg,
                  height: 1.15,
                ),
              ),
              SizedBox(height: compact ? 3 : 4),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 6.0 : 8.0,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: style.fg,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: countFs,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
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
  final int paginationPage;
  final bool captchaLoading;
  final VoidCallback onLoadMore;
  final bool addingItems;
  final int animatedFrom;
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
    required this.paginationPage,
    required this.captchaLoading,
    required this.onLoadMore,
    required this.addingItems,
    required this.animatedFrom,
  });

  String _buildSubtitle() {
    final q = query.trim();
    if (q.isEmpty) {
      return 'Showing ${items.length} of $categoryTotal products';
    }
    // At the 200-item cap for search
    if (paginationPage == 2 && (reachedEnd || items.length >= 200)) {
      return 'Showing ${items.length} results for “$q” — try a more specific term';
    }
    // All results fit within the first page
    if (reachedEnd) {
      final n = items.length;
      return '$n result${n == 1 ? '' : 's'} found for “$q”';
    }
    // Loading or capped at 100 with more available
    final shown = items.length >= 100 ? '100+' : '${items.length}+';
    return 'Showing $shown results for “$q”';
  }

  @override
  Widget build(BuildContext context) {
    final searching = query.trim().isNotEmpty;
    final title = searching ? 'Search Results' : (category == 'All' ? 'Best Sellers' : prettyCategory(category));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(title: title, subtitle: _buildSubtitle()),
        const SizedBox(height: 20),
        // Cross-fade the grid on category change OR on each new search query.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            alignment: Alignment.topCenter,
            children: [...previousChildren, ?currentChild],
          ),
          child: KeyedSubtree(
            key: ValueKey('grid-$category-${query.trim()}'),
            child: _gridBody(),
          ),
        ),
        const SizedBox(height: 24),
        _buildPaginationFooter(),
      ],
    );
  }

  Widget _buildPaginationFooter() {
    if (captchaLoading || loadingMore || addingItems) {
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
    final isSearch = query.trim().isNotEmpty;
    if (paginationPage == 2 && (reachedEnd || items.length >= 200)) {
      final msg = isSearch
          ? '🔍 Too many results? Try a more specific search term'
          : '🔍 Use Search Feature For More Products';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(
            msg,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }
    if (paginationPage == 1 && items.length >= 100 && !reachedEnd) {
      final label = isSearch ? 'Load More Results' : 'Load More Products';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: OutlinedButton(
            onPressed: onLoadMore,
            style: OutlinedButton.styleFrom(
              foregroundColor: Brand.green,
              side: const BorderSide(color: Brand.green),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
            ),
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
    }
    if (reachedEnd && items.length > MedicineRepository.pageSize) {
      final msg = isSearch
          ? 'All results shown for "${query.trim()}"'
          : "You've reached the end of this category";
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text(
            msg,
            style: const TextStyle(color: Brand.inkMuted, fontSize: 12),
          ),
        ),
      );
    }
    return const SizedBox(height: 4);
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
          itemBuilder: (context, i) {
            final card = ProductCard(product: items[i], isBestSeller: i < 3);
            // "Load More" batch: each card slides in as it's added (no delay —
            // the 50 ms stagger comes from the drip-feed loop in state).
            if (animatedFrom > 0 && i >= animatedFrom) {
              return EntranceAnimator(
                key: ValueKey(items[i].id),
                delay: Duration.zero,
                child: card,
              );
            }
            // First page: stagger entrance on initial load.
            if (i < MedicineRepository.pageSize) {
              return EntranceAnimator(
                key: ValueKey(items[i].id),
                delay: Duration(milliseconds: (i * 30).clamp(0, 420)),
                child: card,
              );
            }
            return KeyedSubtree(key: ValueKey(items[i].id), child: card);
          },
        );
      },
    );
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
        ? 'No medicines found for "${query.trim()}"'
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
  final VoidCallback? onSearch;
  final VoidCallback? onBulkUpload;
  final VoidCallback? onOrders;
  final VoidCallback? onCart;

  const _Footer({
    required this.categories,
    required this.onCategory,
    this.onSearch,
    this.onBulkUpload,
    this.onOrders,
    this.onCart,
  });

  static const _kBg = Color(0xFF1B5E20);
  static const _kAccent = Color(0xFF4CAF50);
  static const _kLink = Color(0xFFA5D6A7);
  static const _kHeading = TextStyle(
    color: Colors.white,
    fontSize: 14,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.1,
  );
  static const _kLinkStyle = TextStyle(
    color: _kLink,
    fontSize: 13,
    height: 1.6,
  );

  @override
  Widget build(BuildContext context) {
    final shown = categories.take(8).toList();
    return Container(
      width: double.infinity,
      color: _kBg,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kMaxContent),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LayoutBuilder(
                  builder: (ctx, c) {
                    final wide = c.maxWidth >= 600;
                    if (wide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _brandCol()),
                          Expanded(child: _categoryCol(shown)),
                          Expanded(child: _servicesCol()),
                          Expanded(child: _quickCol(context)),
                        ],
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _brandCol(),
                        const SizedBox(height: 32),
                        _categoryCol(shown),
                        const SizedBox(height: 32),
                        _servicesCol(),
                        const SizedBox(height: 32),
                        _quickCol(context),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 40),
                Divider(color: Colors.white.withValues(alpha: 0.15)),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: LayoutBuilder(
                    builder: (ctx, c) {
                      final wide = c.maxWidth >= 600;
                      if (wide) {
                        return Row(
                          children: [
                            Text(
                              '© 2026 mediBO | All rights reserved',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 12),
                            ),
                            const Spacer(),
                            Text(
                              'Drug License: 20B — WLF20B2025CT000337  ·  21B — WLF21B2025CT000337',
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.45),
                                  fontSize: 11),
                            ),
                          ],
                        );
                      }
                      return Column(
                        children: [
                          Text(
                            '© 2026 mediBO | All rights reserved',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Drug License: 20B — WLF20B2025CT000337  ·  21B — WLF21B2025CT000337',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 11),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _brandCol() {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.local_pharmacy, color: _kAccent, size: 24),
              SizedBox(width: 8),
              Text('mediBO',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Your trusted B2B pharmacy distributor. Genuine medicines delivered to pharmacies & clinics.',
            textAlign: TextAlign.center,
            style: TextStyle(color: _kLink, fontSize: 12, height: 1.6),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.call, size: 13, color: _kAccent),
              SizedBox(width: 6),
              Text('9329252090', style: _kLinkStyle),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.mail, size: 13, color: _kAccent),
              SizedBox(width: 6),
              Text('medibonetwork@gmail.com', style: _kLinkStyle),
            ],
          ),
        ],
      ),
    );
  }

  Widget _categoryCol(List<String> shown) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('SHOP BY CATEGORY', style: _kHeading),
        const SizedBox(height: 16),
        for (final c in shown)
          _footerLink(prettyCategory(c), () => onCategory(c)),
      ],
    );
  }

  Widget _servicesCol() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('OUR SERVICES', style: _kHeading),
        const SizedBox(height: 16),
        _footerLink('Search Medicines', onSearch),
        _footerLink('Bulk Upload', onBulkUpload),
        _footerLink('My Orders', onOrders),
        _footerLink('Cart', onCart),
      ],
    );
  }

  Widget _quickCol(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('QUICK LINKS', style: _kHeading),
        const SizedBox(height: 16),
        _footerLink('About Us', () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const AboutScreen()))),
        _footerLink('Contact Us', () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const ContactScreen()))),
      ],
    );
  }

  static Widget _footerLink(String label, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        child: Text(label, style: _kLinkStyle),
      ),
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
