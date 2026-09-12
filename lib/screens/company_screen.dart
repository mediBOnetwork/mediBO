import 'package:flutter/material.dart';

import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/product.dart';
import '../models/storefront_p3.dart';
import '../widgets/animations.dart';
import '../widgets/compact_product_card.dart';
import 'catalogue_screen.dart';

typedef CompanyPageLoader = Future<CompanyPage> Function(String key, int offset);

/// Test seam for the header's salt cloud (#799) — its own call, its own seam.
typedef CompanySaltCloudLoader = Future<CompanySaltCloud> Function(String key);

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

  /// Test seam for the salt cloud.
  final CompanySaltCloudLoader? cloudLoader;

  const CompanyScreen({
    super.key,
    required this.companyKey,
    this.loader,
    this.cloudLoader,
  });

  @override
  State<CompanyScreen> createState() => _CompanyScreenState();
}

class _CompanyScreenState extends State<CompanyScreen> {
  final _scroll = ScrollController();
  final List<Product> _items = [];
  final Set<String> _seenIds = <String>{};

  CompanyPage? _first;
  CompanySaltCloud _cloud = CompanySaltCloud.none;
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
    // The cloud lands into a header that is already on screen. It is
    // best-effort in the strongest sense: a failure here must never be able to
    // touch the products, so even constructing the repository is inside the
    // try (it reaches for Supabase, which a widget test does not have).
    if (!page.ok) return;
    try {
      final load = widget.cloudLoader ??
          (String k) => MedicineRepository().fetchCompanySaltCloud(k);
      final cloud = await load(widget.companyKey);
      if (mounted) setState(() => _cloud = cloud);
    } catch (_) {
      // No cloud. The header simply draws name + count, which is what a
      // company with no salt data draws anyway.
    }
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

    // CHANGE #799 — the header is a COLLAPSING sliver, not an AppBar plus a
    // block under it. Expanded it is the company's identity: the logo box, the
    // name, the count and the salt cloud. Scrolled, it becomes a slim bar with
    // the name alone, so the products get the screen back.
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: _loading
          ? const _CompanySkeleton()
          : (first == null || !first.ok)
              ? _NotFound(page: first)
              : _Body(
                  page: first,
                  cloud: _cloud,
                  items: _items,
                  scroll: _scroll,
                  loadingMore: _loadingMore,
                ),
    );
  }
}

/// The company's identity, and the salts it makes. Every string is the
/// payload's; the only thing decided here is how tall it is when open.
class _CompanyHeader extends StatelessWidget {
  final CompanyPage page;
  final CompanySaltCloud cloud;
  const _CompanyHeader({required this.page, required this.cloud});

  static const double _expanded = 188;
  static const double _logo = 44;
  static const double _cloud = 32;

  @override
  Widget build(BuildContext context) => SliverAppBar(
        pinned: true,
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        foregroundColor: Ds.c.text,
        elevation: 0,
        expandedHeight: cloud.has ? _expanded : _expanded - _cloud * 2,
        leading: IconButton(
          tooltip: page.backLabel,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(page.label,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: Ds.t.subtitle),
        flexibleSpace: FlexibleSpaceBar(
          collapseMode: CollapseMode.pin,
          // The background is laid out at the EXPANDED height and then
          // squeezed as the bar collapses, so it must be allowed to be too
          // tall for a frame. A non-scrolling scroll view clips instead of
          // throwing — the alternative is a 4px overflow stripe every time
          // somebody scrolls a company page.
          background: SafeArea(
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: Padding(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x16, Ds.space.x48, Ds.space.x16, Ds.space.x8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // The logo box. There is no company artwork in the
                      // catalogue, so the payload's own initial is the honest
                      // mark — the same rule the nav registry follows.
                      Container(
                        width: _logo,
                        height: _logo,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Ds.c.bg,
                          borderRadius: Ds.r.rCard,
                          border: Border.all(color: Ds.c.divider),
                        ),
                        child: Text(page.iconLetter, style: Ds.t.title),
                      ),
                      SizedBox(width: Ds.space.x12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(page.label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Ds.t.title),
                            if (page.countLabel.isNotEmpty)
                              Text(page.countLabel, style: Ds.t.caption),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (cloud.has) ...[
                    SizedBox(height: Ds.space.x12),
                    Text(cloud.title, style: Ds.t.caption),
                    SizedBox(height: Ds.space.x8),
                    SizedBox(
                      height: _cloud,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: cloud.items.length,
                        separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
                        itemBuilder: (context, i) => InkWell(
                          // A salt in the cloud opens the catalogue's own salt
                          // listing. Pushed directly with the route as a seed
                          // rather than through a URL: the Catalogue is a page
                          // of the shell's IndexedStack, and pushing a named
                          // path would land on the shell's boot parse instead
                          // of this salt.
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => _SaltListing(
                                title: cloud.items[i].label,
                                backLabel: page.backLabel,
                                route: CatalogueRoute(
                                    listKind: 'salt',
                                    listKey: cloud.items[i].key),
                              ),
                            ),
                          ),
                          borderRadius: Ds.r.rChip,
                          child: Container(
                            padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Ds.c.bg,
                              borderRadius: Ds.r.rChip,
                              border: Border.all(color: Ds.c.divider),
                            ),
                            child: Text(cloud.items[i].label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Ds.t.caption.copyWith(color: Ds.c.text)),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        ),
      );
}

class _Body extends StatelessWidget {
  final CompanyPage page;
  final CompanySaltCloud cloud;
  final List<Product> items;
  final ScrollController scroll;
  final bool loadingMore;

  const _Body({
    required this.page,
    required this.cloud,
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
            _CompanyHeader(page: page, cloud: cloud),
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


/// CHANGE #799 — one salt's products, opened from a company's salt cloud.
///
/// It is the Catalogue screen with its route pre-seeded, not a second listing:
/// the same RPC, the same cards, the same filter sentence. A salt page that
/// drifted from the catalogue's own would be two answers to one question.
class _SaltListing extends StatelessWidget {
  final String title;
  final String backLabel;
  final CatalogueRoute route;
  const _SaltListing({
    required this.title,
    required this.backLabel,
    required this.route,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(
          backgroundColor: Ds.c.surface,
          surfaceTintColor: Ds.c.surface,
          foregroundColor: Ds.c.text,
          elevation: 0,
          leading: IconButton(
            tooltip: backLabel,
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          title: Text(title,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: Ds.t.subtitle),
        ),
        body: CatalogueScreen(active: true, initialRoute: route),
      );
}
