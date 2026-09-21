import 'dart:async';

import 'package:flutter/material.dart';

import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/product.dart';
import '../models/shell_nav.dart';
import '../models/storefront_p3.dart';
import '../utils/render_log.dart';
import '../widgets/animations.dart';
import '../widgets/compact_product_card.dart';
import '../widgets/product_card_grid.dart';
import 'catalogue_screen.dart';

/// CMD #2118 — the third argument is the "Search in this company" term.
/// Empty is the plain catalogue; the RPC, not this screen, decides what a term
/// matches.
typedef CompanyPageLoader =
    Future<CompanyPage> Function(String key, int offset, String q);

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

  /// CMD #2118 — the term in "Search in this company". It is sent to the RPC;
  /// nothing is filtered here.
  String _q = '';
  Timer? _debounce;
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
    _debounce?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// CMD #2118 — every keystroke re-asks the BACKEND for this company's
  /// products. Debounced so a phone keyboard does not fire a request a letter,
  /// and guarded on the term so a slow answer to an old term cannot land.
  void _onQuery(String v) {
    _debounce?.cancel();
    final q = v.trim();
    setState(() => _q = q);
    _debounce = Timer(const Duration(milliseconds: 260), () async {
      final page = await _loader(widget.companyKey, 0, q);
      if (!mounted || _q != q) return;
      setState(() {
        _first = page;
        _items
          ..clear()
          ..addAll(page.items);
        _seenIds
          ..clear()
          ..addAll(page.items.map((p) => p.id));
        _hasMore = page.hasMore;
        _nextOffset = page.offset + page.items.length;
      });
    });
  }

  CompanyPageLoader get _loader =>
      widget.loader ??
      (key, offset, q) => MedicineRepository()
          .fetchCompanyPage(key, offset: offset, limit: _pageSize, q: q);

  Future<void> _load() async {
    final page = await _loader(widget.companyKey, 0, _q);
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

    final page = await _loader(widget.companyKey, _nextOffset, _q);
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
                  query: _q,
                  onQuery: _onQuery,
                ),
    );
  }
}

/// CMD #2118 — the company page, rebuilt.
///
/// What #799 shipped put the name in the pinned bar AND in the collapsing
/// header underneath it, so an open page said the company's name twice, and
/// the salt chips lived inside the part that collapses — which is why they
/// were sliced in half by the first row of the grid on the way down.
///
/// Now: the name is in the bar and nowhere else. Under it, in the scroll and
/// not in a collapsing box, sit the count sentence, "Search in this company",
/// and the salts in a row with its own fixed height and its own padding. Every
/// string is the payload's.
class _Header extends StatelessWidget {
  final CompanyPage page;
  final CompanySaltCloud cloud;
  final String query;
  final ValueChanged<String> onQuery;

  const _Header({
    required this.page,
    required this.cloud,
    required this.query,
    required this.onQuery,
  });

  /// The chips' band. Fixed, with padding above and below, so the row is a row
  /// and not whatever is left between two other things.
  static const double chipsH = 36;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (page.countLabel.isNotEmpty) ...[
              Text(page.countLabel, style: Ds.t.caption),
              SizedBox(height: Ds.space.x12),
            ],
            Semantics(
              identifier: 'company_search_box',
              textField: true,
              child: TextField(
                onChanged: onQuery,
                textInputAction: TextInputAction.search,
                style: Ds.t.body,
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: Ds.c.surface,
                  hintText: page.searchHint,
                  hintStyle: Ds.t.body.copyWith(color: Ds.c.textSecondary),
                  prefixIcon: Icon(Icons.search, color: Ds.c.textSecondary),
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x12),
                  border: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.brand),
                  ),
                ),
              ),
            ),
            if (cloud.has) ...[
              SizedBox(height: Ds.space.x16),
              Text(cloud.title, style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
              SizedBox(
                height: chipsH,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: cloud.items.length,
                  separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
                  itemBuilder: (context, i) => InkWell(
                    // A salt in the cloud opens the catalogue's own salt
                    // listing. Pushed directly with the route as a seed rather
                    // than through a URL: the Catalogue is a page of the
                    // shell's IndexedStack, and pushing a named path would
                    // land on the shell's boot parse instead of this salt.
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => _SaltListing(
                          title: cloud.items[i].label,
                          backLabel: page.backLabel,
                          route: CatalogueRoute(
                              listKind: 'salt', listKey: cloud.items[i].key),
                        ),
                      ),
                    ),
                    borderRadius: Ds.r.rChip,
                    child: Container(
                      padding:
                          EdgeInsets.symmetric(horizontal: Ds.space.x12),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Ds.c.bg,
                        borderRadius: Ds.r.rChip,
                        border: Border.all(
                            color: Ds.c.divider, width: Ds.space.hairline),
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
            SizedBox(height: Ds.space.x8),
          ],
        ),
      );
}

class _Body extends StatelessWidget {
  final CompanyPage page;
  final CompanySaltCloud cloud;
  final List<Product> items;
  final ScrollController scroll;
  final bool loadingMore;
  final String query;
  final ValueChanged<String> onQuery;

  const _Body({
    required this.page,
    required this.cloud,
    required this.items,
    required this.scroll,
    required this.loadingMore,
    required this.query,
    required this.onQuery,
  });

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c2118_company_page',
        'q=$query;items=${items.length};salts=${cloud.has ? cloud.items.length : 0}');
    return LayoutBuilder(
      builder: (context, c) {
        final gridW = c.maxWidth - Ds.space.x16 * 2;
        return CustomScrollView(
          controller: scroll,
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: Ds.c.surface,
              surfaceTintColor: Ds.c.surface,
              foregroundColor: Ds.c.text,
              elevation: 0,
              leading: IconButton(
                tooltip: page.backLabel,
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              // CMD #2118 — the company's name, once on the page.
              title: Text(page.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.subtitle),
            ),
            SliverToBoxAdapter(
              child: _Header(
                page: page,
                cloud: cloud,
                query: query,
                onQuery: onQuery,
              ),
            ),
            if (items.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x24),
                  child: Text(page.emptyLabel, style: Ds.t.caption),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                sliver: SliverGrid(
                  // CMD #2122 — the same card, and the same extent, as every
                  // other grid.
                  gridDelegate: ProductCardGrid.delegateFor(gridW),
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
                height: Ds.space.x48,
                child: Center(
                  child: loadingMore
                      ? SizedBox(
                          width: Ds.space.x24,
                          height: Ds.space.x24,
                          child: const CircularProgressIndicator(
                              strokeWidth: 2),
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
            final cross = ProductCardGrid.columnsFor(c.maxWidth - 32);
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
                  gridDelegate: ProductCardGrid.delegateFor(c.maxWidth - 32),
                  itemCount: cross * 2,
                  itemBuilder: (_, _) => const CompactCardSkeleton(),
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
          actions: [
            // CMD #2021 — same door as the product page: a company page is a
            // pushed route (CHANGE #638), so the bottom bar is not on screen
            // here. Pops back to the shell and asks for the home root.
            IconButton(
              icon: Icon(Icons.home_outlined, color: Ds.c.textSecondary),
              onPressed: () => ShellHomeSignal.goHome(context),
            ),
          ],
        ),
        body: CatalogueScreen(active: true, initialRoute: route),
      );
}
