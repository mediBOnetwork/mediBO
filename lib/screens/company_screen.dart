import 'package:flutter/material.dart';

import '../data/medicine_repository.dart';
import '../models/product.dart';
import '../models/storefront_p3.dart';
import '../widgets/animations.dart';
import '../widgets/compact_product_card.dart';

typedef CompanyPageLoader = Future<CompanyPage> Function(String key, int offset);

/// CHANGE #638 — a company's full catalogue at `/company/<key>`.
///
/// Header and count come from the payload verbatim; the grid is the same
/// [CompactProductCard] the home rails and the category listing use. Paging
/// appends by `p_offset` and stops when the BACKEND says `has_more:false` —
/// never when a page happens to come back short, which is wrong on an exact
/// boundary.
class CompanyScreen extends StatefulWidget {
  final String companyKey;

  /// Test seam: supply pages instead of calling the RPC.
  final CompanyPageLoader? loader;

  const CompanyScreen({
    super.key,
    required this.companyKey,
    this.loader,
  });

  @override
  State<CompanyScreen> createState() => _CompanyScreenState();
}

class _CompanyScreenState extends State<CompanyScreen> {
  final _scroll = ScrollController();
  final List<Product> _items = [];
  final Set<String> _seenIds = <String>{};

  CompanyPage? _first;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _nextOffset = 0;

  static const int _pageSize = 24;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  CompanyPageLoader get _loader =>
      widget.loader ??
      (key, offset) => MedicineRepository()
          .fetchCompanyPage(key, offset: offset, limit: _pageSize);

  Future<void> _load() async {
    final page = await _loader(widget.companyKey, 0);
    if (!mounted) return;
    setState(() {
      _first = page;
      _loading = false;
      _items
        ..clear()
        ..addAll(page.items);
      _seenIds
        ..clear()
        ..addAll(page.items.map((p) => p.id));
      _hasMore = page.hasMore;
      _nextOffset = page.offset + page.items.length;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);

    final page = await _loader(widget.companyKey, _nextOffset);
    if (!mounted) return;

    // De-duplicate by id. A repeated offset (double-fire near the boundary, or
    // a shifting sort) must never paint the same product twice.
    final fresh =
        page.items.where((p) => _seenIds.add(p.id)).toList(growable: false);

    setState(() {
      _loadingMore = false;
      if (!page.ok) {
        _hasMore = false;
        return;
      }
      _items.addAll(fresh);
      _hasMore = page.hasMore;
      _nextOffset = page.offset + page.items.length;
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients || _loadingMore || !_hasMore) return;
    // Prefetch a screen early so the boundary never shows an empty gap.
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 600) {
      _loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final first = _first;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Color(0xFF111827)),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: first != null && first.ok
            ? Text(
                first.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827),
                ),
              )
            : null,
      ),
      body: _loading
          ? const _CompanySkeleton()
          : (first == null || !first.ok)
              ? _NotFound(page: first)
              : _Body(
                  page: first,
                  items: _items,
                  scroll: _scroll,
                  loadingMore: _loadingMore,
                ),
    );
  }
}

class _Body extends StatelessWidget {
  final CompanyPage page;
  final List<Product> items;
  final ScrollController scroll;
  final bool loadingMore;

  const _Body({
    required this.page,
    required this.items,
    required this.scroll,
    required this.loadingMore,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cross = c.maxWidth >= 900 ? 4 : c.maxWidth >= 600 ? 3 : 2;
        return CustomScrollView(
          controller: scroll,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      page.label,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                        color: Color(0xFF111827),
                      ),
                    ),
                    if (page.countLabel.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        page.countLabel,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cross,
                  // Same fixed extent as every other grid of these cards.
                  mainAxisExtent: CompactProductCard.extent,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 14,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => CompactProductCard(
                    product: items[i],
                    onTap: () => Navigator.of(context)
                        .pushNamed('/product/${items[i].id}'),
                  ),
                  childCount: items.length,
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 72,
                child: Center(
                  child: loadingMore
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NotFound extends StatelessWidget {
  final CompanyPage? page;
  const _NotFound({required this.page});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.storefront_outlined,
                  size: 44, color: Color(0xFFC7CBD1)),
              const SizedBox(height: 14),
              // The backend sends no copy for this state, so the page stays
              // wordless rather than inventing a sentence.
              OutlinedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF1B7A43),
                  side: const BorderSide(color: Color(0xFF1B7A43)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Icon(Icons.arrow_back, size: 18),
              ),
            ],
          ),
        ),
      );
}

class _CompanySkeleton extends StatelessWidget {
  const _CompanySkeleton();

  @override
  Widget build(BuildContext context) => Shimmer(
        child: LayoutBuilder(
          builder: (context, c) {
            final cross = c.maxWidth >= 900 ? 4 : c.maxWidth >= 600 ? 3 : 2;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              physics: const NeverScrollableScrollPhysics(),
              children: [
                const SkeletonBox(width: 220, height: 22, radius: 6),
                const SizedBox(height: 8),
                const SkeletonBox(width: 110, height: 12, radius: 4),
                const SizedBox(height: 20),
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cross,
                    mainAxisExtent: CompactProductCard.extent,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: cross * 2,
                  itemBuilder: (_, __) => const CompactCardSkeleton(),
                ),
              ],
            );
          },
        ),
      );
}
