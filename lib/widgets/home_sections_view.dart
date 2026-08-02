import 'package:flutter/material.dart';

import '../data/medicine_repository.dart';
import '../models/home_sections.dart';
import 'animations.dart';
import 'compact_product_card.dart';

/// CHANGE #637 — the sectioned customer home feed.
///
/// One RPC (`storefront_home_v2`) returns an ordered list of sections; this
/// widget walks that list and paints each one with the layout the backend
/// named. It does not sort, filter, re-title, or decide which sections a
/// viewer gets — reordering the home page is an UPDATE in Postgres.
///
/// Navigation is injected rather than hardcoded: category and company taps go
/// back up to HomeShell, which owns the category/search state. Only the
/// product route is pushed directly, because `/product/:id` is a real named
/// route (CHANGE #636) and the card already owns that contract.
class HomeSectionsView extends StatefulWidget {
  /// Test seam: supply the payload instead of calling the RPC. Same shape as
  /// [ProductDetailScreen.loader].
  final Future<HomeSections> Function()? loader;

  /// A category tile / See-all(category) was tapped. HomeShell turns this into
  /// its existing category selection + /c/<slug> URL push.
  final ValueChanged<String> onCategoryTap;

  /// A company tile was tapped. HomeShell prefills and submits a search.
  final ValueChanged<String> onCompanyTap;

  /// Rendered as the last item of the feed. The home page keeps its trust
  /// badges and footer this way without a second scrollable — the feed is one
  /// lazy ListView, so sections below the fold are never built.
  final Widget? footer;

  const HomeSectionsView({
    super.key,
    this.loader,
    required this.onCategoryTap,
    required this.onCompanyTap,
    this.footer,
  });

  /// Last successful payload, kept for the life of the app session.
  ///
  /// Back-navigation from a product page rebuilds this widget; without the
  /// memo that would refetch and reset the scroll offset. Cached to avoid a
  /// refetch — never used to answer a question, and always replaced wholesale
  /// by a refresh.
  static HomeSections? _memo;

  @visibleForTesting
  static void resetMemo() => _memo = null;

  @override
  State<HomeSectionsView> createState() => _HomeSectionsViewState();
}

class _HomeSectionsViewState extends State<HomeSectionsView> {
  HomeSections? _data;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final memo = HomeSectionsView._memo;
    if (memo != null) {
      _data = memo;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final load = widget.loader ?? () => MedicineRepository().fetchHomeSections();
    HomeSections res;
    try {
      res = await load();
    } catch (_) {
      res = HomeSections.failed;
    }
    if (!mounted) return;
    if (res.ok) HomeSectionsView._memo = res;
    setState(() {
      _data = res;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;

    // Nothing yet — first load. A refresh keeps the old feed on screen
    // instead of flashing back to a skeleton.
    if (d == null) return const _FeedSkeleton();

    // ok:false — the search bar and chips above this widget stay put; this
    // block is the only thing that changes. Never a blank page, never a throw.
    if (!d.ok) return _Retry(onRetry: _load);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        key: const PageStorageKey('home-sections'),
        // AlwaysScrollable so the pull gesture works even on a short feed.
        physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics()),
        padding: const EdgeInsets.only(top: 8, bottom: 96),
        itemCount: d.sections.length + (widget.footer == null ? 0 : 1),
        itemBuilder: (_, i) {
          if (i >= d.sections.length) return widget.footer!;
          return _SectionBlock(
            section: d.sections[i],
            onCategoryTap: widget.onCategoryTap,
            onCompanyTap: widget.onCompanyTap,
          );
        },
      ),
    );
  }
}

// ── One section ──────────────────────────────────────────────────────────────

class _SectionBlock extends StatelessWidget {
  final HomeSection section;
  final ValueChanged<String> onCategoryTap;
  final ValueChanged<String> onCompanyTap;

  const _SectionBlock({
    required this.section,
    required this.onCategoryTap,
    required this.onCompanyTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(section: section),
          const SizedBox(height: 12),
          switch (section.layout) {
            HomeSectionLayout.rail => _Rail(
                section: section,
                onCategoryTap: onCategoryTap,
              ),
            // A category tile hands back `key` — the RAW category name the
            // chips already use ("ANTI INFECTIVES"), not the pretty label.
            HomeSectionLayout.iconGrid => _TileGrid(
                tiles: section.tiles,
                crossAxisCount: 4,
                labelSize: 13,
                centered: false,
                valueOf: (t) => t.key,
                onTap: onCategoryTap,
              ),
            // A company tile hands back `label`, because there is no
            // company-filtered listing to send `key` to: the fallback is a
            // search, and the searchable string is the printed company name.
            HomeSectionLayout.brandGrid => _TileGrid(
                tiles: section.tiles,
                crossAxisCount: 3,
                labelSize: 12,
                centered: true,
                valueOf: (t) => t.label,
                onTap: onCompanyTap,
              ),
            // Unreachable: unknown layouts are dropped at parse time. Kept so
            // this switch stays exhaustive if the enum grows.
            HomeSectionLayout.unknown => const SizedBox.shrink(),
          },
        ],
      ),
    );
  }
}

/// title with [HomeSection.accentWord] in brand green + subtitle, both verbatim.
class SectionHeader extends StatelessWidget {
  final HomeSection section;
  const SectionHeader({super.key, required this.section});

  @override
  Widget build(BuildContext context) {
    final (before, accent, after) = section.titleParts;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111827),
                height: 1.25,
              ),
              children: [
                TextSpan(text: before),
                if (accent.isNotEmpty)
                  TextSpan(
                    text: accent,
                    style: const TextStyle(color: Color(0xFF1B7A43)),
                  ),
                TextSpan(text: after),
              ],
            ),
          ),
          if (section.subtitle.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              section.subtitle,
              style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w500,
                color: Color(0xFF9CA3AF),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── rail ─────────────────────────────────────────────────────────────────────

class _Rail extends StatelessWidget {
  final HomeSection section;
  final ValueChanged<String> onCategoryTap;

  const _Rail({required this.section, required this.onCategoryTap});

  static const double cardW = 156;
  static const double _gap = 12;

  @override
  Widget build(BuildContext context) {
    final seeAll = section.seeAll;
    final n = section.cards.length + (seeAll == null ? 0 : 1);

    return SizedBox(
      // Fixed height derived from the card's own constant — the rail never
      // measures its children, so scrolling it costs no layout.
      height: CompactProductCard.extent,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemExtent: cardW + _gap,
        itemCount: n,
        itemBuilder: (context, i) {
          if (i >= section.cards.length) {
            return _SeeAllPill(
              width: cardW,
              onTap: () => _navigate(context, seeAll!),
            );
          }
          final p = section.cards[i];
          return Padding(
            padding: const EdgeInsets.only(right: _gap),
            child: CompactProductCard(
              product: p,
              onTap: () =>
                  Navigator.of(context).pushNamed('/product/${p.id}'),
            ),
          );
        },
      ),
    );
  }

  void _navigate(BuildContext context, SeeAll s) {
    // The backend names the destination type; the app maps it to the
    // navigation it already has. An unrecognised type does nothing rather
    // than guessing a screen.
    switch (s.type) {
      case 'category':
        onCategoryTap(s.key);
      case 'search':
        onCategoryTap(s.key);
    }
  }
}

class _SeeAllPill extends StatelessWidget {
  final double width;
  final VoidCallback onTap;
  const _SeeAllPill({required this.width, required this.onTap});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 12),
        child: SizedBox(
          width: width,
          child: Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(24),
              onTap: onTap,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFF1B7A43)),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'See all',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF1B7A43),
                      ),
                    ),
                    SizedBox(width: 2),
                    Icon(Icons.chevron_right,
                        size: 16, color: Color(0xFF1B7A43)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

// ── icon_grid / brand_grid ───────────────────────────────────────────────────

class _TileGrid extends StatelessWidget {
  final List<HomeTile> tiles;
  final int crossAxisCount;
  final double labelSize;
  final bool centered;

  /// What this grid hands back on tap — `key` for categories, `label` for
  /// companies. Kept explicit so it is never inferred from a styling flag.
  final String Function(HomeTile) valueOf;
  final ValueChanged<String> onTap;

  const _TileGrid({
    required this.tiles,
    required this.crossAxisCount,
    required this.labelSize,
    required this.centered,
    required this.valueOf,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: crossAxisCount,
          mainAxisExtent: 92,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: tiles.length,
        itemBuilder: (_, i) => _Tile(
          tile: tiles[i],
          labelSize: labelSize,
          centered: centered,
          tapValue: valueOf(tiles[i]),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final HomeTile tile;
  final double labelSize;
  final bool centered;
  final String tapValue;
  final ValueChanged<String> onTap;

  const _Tile({
    required this.tile,
    required this.labelSize,
    required this.centered,
    required this.tapValue,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final align =
        centered ? CrossAxisAlignment.center : CrossAxisAlignment.start;

    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFEDEFF2)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: align,
        children: [
          // Optional icon slot — deliberately empty. The backend sends no icon
          // key yet, and picking one per category in Dart would be the app
          // deciding what a category looks like.
          Flexible(
            child: Text(
              tile.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: TextStyle(
                fontSize: labelSize,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF1F2937),
              ),
            ),
          ),
          if (tile.countLabel.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              tile.countLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: const TextStyle(
                fontSize: 10,
                color: Color(0xFF9CA3AF),
              ),
            ),
          ],
        ],
      ),
    );

    // No key from the backend means no destination — the tile renders but does
    // not pretend to be tappable.
    if (!tile.tappable) return body;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => onTap(tapValue),
      child: body,
    );
  }
}

// ── states ───────────────────────────────────────────────────────────────────

class _Retry extends StatelessWidget {
  final VoidCallback onRetry;
  const _Retry({required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 48),
        child: Column(
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 34, color: Color(0xFFC7CBD1)),
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1B7A43),
                side: const BorderSide(color: Color(0xFF1B7A43)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
}

/// Two headers and one rail of card skeletons — the same geometry the loaded
/// feed uses, so nothing shifts when the payload lands.
class _FeedSkeleton extends StatelessWidget {
  const _FeedSkeleton();

  @override
  Widget build(BuildContext context) => Shimmer(
        child: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 8),
          children: [
            const _SkeletonHeader(),
            const SizedBox(height: 12),
            SizedBox(
              height: CompactProductCard.extent,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemExtent: _Rail.cardW + 12,
                itemCount: 4,
                itemBuilder: (_, __) => const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: CompactCardSkeleton(),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const _SkeletonHeader(),
          ],
        ),
      );
}

class _SkeletonHeader extends StatelessWidget {
  const _SkeletonHeader();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(width: 170, height: 22, radius: 6),
            SizedBox(height: 6),
            SkeletonBox(width: 120, height: 11, radius: 4),
          ],
        ),
      );
}
