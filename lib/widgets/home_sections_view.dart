import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../data/medicine_repository.dart';
import '../models/home_sections.dart';
import '../models/storefront_p3.dart';
import '../theme.dart';
import 'animations.dart';
import 'compact_product_card.dart';

/// CHANGE #637 — the sectioned customer home feed.
///
/// One RPC (`storefront_home_v2`) returns an ordered list of sections; this
/// widget walks that list and paints each one with the layout the backend
/// named. It does not sort, filter, re-title, or decide which sections a
/// viewer gets — reordering the home page is an UPDATE in Postgres.
///
/// Category taps go back up to HomeShell, which owns the category state and
/// its URL. Product and company taps push their own named routes
/// (`/product/:id` from CHANGE #636, `/company/:key` from CHANGE #638),
/// because those are real routes with their own screens.
class HomeSectionsView extends StatefulWidget {
  /// Test seam: supply the payload instead of calling the RPC.
  final Future<HomeSections> Function()? loader;

  /// A category tile / See-all(category) was tapped. HomeShell turns this into
  /// its existing category selection and the matching URL push.
  final ValueChanged<String> onCategoryTap;

  /// Test seam: the back-in-stock strip payload.
  final Future<BackInStock> Function()? notificationsLoader;

  /// Test seam: what `stock_notify_seen` does. Production calls the RPC.
  final Future<void> Function(List<int> ids)? onSeen;

  /// Rendered as the last item of the feed. The home page keeps its trust
  /// badges and footer this way without a second scrollable — the feed is one
  /// lazy ListView, so sections below the fold are never built.
  final Widget? footer;

  const HomeSectionsView({
    super.key,
    this.loader,
    required this.onCategoryTap,
    this.notificationsLoader,
    this.onSeen,
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
  BackInStock _backInStock = BackInStock.empty;
  bool _seenSent = false;

  /// CHANGE #678 — paging happens sideways, not downwards.
  ///
  /// A rail grows as you scroll RIGHT, up to the ceiling the backend set. The
  /// vertical page does not grow at all: a grid holds what it was given and
  /// ends in a Show-all button. #677 paged the page itself, and the result was
  /// a storefront you could never scroll to the bottom of.
  final ScrollController _scroll = ScrollController();

  /// One in-flight request per section, keyed by section id — two rails may
  /// page at once without either seeing the other's half-applied result.
  final Set<String> _paging = <String>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    final memo = HomeSectionsView._memo;
    if (memo != null) {
      _data = memo;
    }
    // The strip is per-viewer and clears once seen, so it is always fetched
    // fresh — it is never served from the sections memo.
    _load(sectionsFromMemo: memo != null);
  }

  Future<void> _load({bool sectionsFromMemo = false}) async {
    final loadSections =
        widget.loader ?? () => MedicineRepository().fetchHomeSections();
    final loadNotifs =
        widget.notificationsLoader ??
        () => MedicineRepository().myStockNotifications();

    // Labels are needed by the Notify control on any out-of-stock card, and
    // cards carry none of their own. Fetched alongside, never per card.
    if (widget.notificationsLoader == null) {
      unawaited(MedicineRepository().loadStorefrontLabels());
    }

    HomeSections sections;
    BackInStock strip;
    try {
      final results = await Future.wait([
        sectionsFromMemo
            ? Future.value(HomeSectionsView._memo!)
            : loadSections(),
        loadNotifs(),
      ]);
      sections = results[0] as HomeSections;
      strip = results[1] as BackInStock;
    } catch (_) {
      sections = sectionsFromMemo
          ? HomeSectionsView._memo!
          : HomeSections.failed;
      strip = BackInStock.empty;
    }

    if (!mounted) return;
    if (sections.ok) HomeSectionsView._memo = sections;
    setState(() {
      _data = sections;
      _backInStock = strip;
    });

    _reportSeen();
  }

  /// Appends one page to [id]. Called by a rail that has been scrolled near
  /// its right-hand end. Whether there is more to fetch is [HomeSection
  /// .canPageMore] — the backend's `infinite` and `total`, never a count kept
  /// here.
  Future<void> _pageSection(String id) async {
    if (_paging.contains(id)) return;
    final d = _data;
    if (d == null || !d.ok) return;

    final i = d.sections.indexWhere((s) => s.id == id);
    if (i < 0 || !d.sections[i].canPageMore) return;

    _paging.add(id);
    final section = d.sections[i];
    try {
      final more = await MedicineRepository().fetchHomeMore(
        section.feedKey,
        offset: section.nextOffset,
        limit: section.pageSize,
      );
      if (!mounted || more.items.isEmpty) return;
      // Re-find by id: a refresh may have replaced the list while this was in
      // flight, and appending to a stale index would graft a page onto the
      // wrong section.
      final now = _data;
      if (now == null || !now.ok) return;
      final j = now.sections.indexWhere((s) => s.id == id);
      if (j < 0) return;
      final next = List<HomeSection>.of(now.sections);
      next[j] = now.sections[j].appending(more.items, more.nextOffset);
      final grown = HomeSections(
        ok: true,
        sections: next,
        header: now.header,
        hero: now.hero,
      );
      // The memo grows with it, so coming back from a product page lands on the
      // same feed the user had scrolled, not a reset one.
      HomeSectionsView._memo = grown;
      setState(() => _data = grown);
    } finally {
      _paging.remove(id);
    }
  }

  /// The strip has been built, so it has been seen. Fire-and-forget: the ids
  /// go back exactly as the backend sent them, and a failure is silent because
  /// the user has already been shown the products.
  void _reportSeen() {
    if (_seenSent || !_backInStock.show) return;
    _seenSent = true;
    final ids = _backInStock.ids;
    if (ids.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final report =
          widget.onSeen ?? (list) => MedicineRepository().stockNotifySeen(list);
      unawaited(report(ids));
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
    if (!d.ok) return _Retry(onRetry: () => _load());

    // CHANGE #673 — the hero is the first row of the feed rather than a
    // separate widget above it, so it scrolls with the content and costs no
    // second scrollable. `show` is the backend's decision, not "is the title
    // non-empty".
    final hero = d.hero.show ? 1 : 0;

    // The strip sits ABOVE Best Sellers, and only when the backend sent
    // products for it.
    final strip = _backInStock.show ? 1 : 0;

    final lead = hero + strip;

    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView.builder(
        key: const PageStorageKey('home-sections'),
        controller: _scroll,
        // AlwaysScrollable so the pull gesture works even on a short feed.
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.only(bottom: 96),
        // CHANGE #678a — build two screens ahead of the viewport.
        //
        // The default builds a section only as its top edge arrives, so the
        // row you were scrolling towards assembled under your thumb. Two
        // screens of lead time means it is already painted when it appears —
        // no placeholder, no pop-in, and nothing to animate away.
        scrollCacheExtent: const ScrollCacheExtent.pixels(2400),
        itemCount: lead + d.sections.length + (widget.footer == null ? 0 : 1),
        itemBuilder: (_, i) {
          if (hero == 1 && i == 0) {
            return HomeHeroBanner(
              hero: d.hero,
              onCta: () => widget.onCategoryTap('All'),
            );
          }
          if (strip == 1 && i == hero) {
            return _StripBlock(strip: _backInStock);
          }
          final si = i - lead;
          if (si >= d.sections.length) return widget.footer!;
          final section = d.sections[si];
          return _SectionBlock(
            // CHANGE #678a — keyed by the backend's section id. Without it
            // Flutter recycles one rail's State onto the next section as they
            // scroll past, and the incoming rail inherits the outgoing one's
            // scroll offset — which is what made rails slide sideways by
            // themselves and then fetch a page nobody asked for.
            key: ValueKey(section.id),
            section: section,
            onCategoryTap: widget.onCategoryTap,
            onNeedMore: () => unawaited(_pageSection(section.id)),
          );
        },
      ),
    );
  }
}

/// CHANGE #673 — the hero banner.
///
/// Every word and every colour is [HomeHero], straight from
/// `storefront_home_v2()`. Rewording the promise or restyling the banner is an
/// UPDATE to `storefront_ui_label` / `storefront_theme`.
///
/// The prop icons are the one thing chosen here, and only as a glyph for a
/// backend NAME — an unrecognised name renders the label with no icon rather
/// than a guessed one, so a new prop can ship to an old build.
class HomeHeroBanner extends StatelessWidget {
  final HomeHero hero;
  final VoidCallback onCta;
  const HomeHeroBanner({super.key, required this.hero, required this.onCta});

  static const Map<String, IconData> _glyphs = {
    'inventory': Icons.inventory_2_rounded,
    'truck': Icons.local_shipping_rounded,
    'verified': Icons.verified_user_rounded,
    'savings': Icons.savings_rounded,
    'support': Icons.support_agent_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final accent = Brand.hex(hero.accent, Brand.accent);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 22),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Rad.band),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Brand.hex(hero.bgTop, Brand.deep),
            Brand.hex(hero.bgBottom, Brand.deepAlt),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hero.eyebrow.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(Rad.pill),
              ),
              child: Text(
                hero.eyebrow,
                style: AppType.eyebrow.copyWith(
                  color: Colors.white,
                  letterSpacing: 1.1,
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],
          if (hero.title.isNotEmpty)
            Text(
              hero.title,
              style: AppType.h3.copyWith(color: Colors.white, height: 1.2),
            ),
          if (hero.cta.isNotEmpty) ...[
            const SizedBox(height: 16),
            _HeroCta(label: hero.cta, accent: accent, onTap: onCta),
          ],
          if (hero.props.isNotEmpty) ...[
            const SizedBox(height: 18),
            Wrap(
              spacing: 14,
              runSpacing: 8,
              children: [
                for (final p in hero.props)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_glyphs[p.icon] != null) ...[
                        Icon(_glyphs[p.icon], size: 13, color: Colors.white70),
                        const SizedBox(width: 5),
                      ],
                      Text(
                        p.label,
                        style: AppType.t1.copyWith(color: Colors.white70),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroCta extends StatelessWidget {
  final String label;
  final Color accent;
  final VoidCallback onTap;
  const _HeroCta({
    required this.label,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: accent,
    borderRadius: BorderRadius.circular(Rad.pill),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Rad.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppType.l4.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.arrow_forward_rounded,
              size: 16,
              color: Colors.white,
            ),
          ],
        ),
      ),
    ),
  );
}

// ── One section ──────────────────────────────────────────────────────────────

class _SectionBlock extends StatelessWidget {
  final HomeSection section;
  final ValueChanged<String> onCategoryTap;

  /// CHANGE #678 — the rail has been scrolled near its end and wants the next
  /// page. Whether one is fetched is decided upstairs, from the payload.
  final VoidCallback onNeedMore;

  const _SectionBlock({
    super.key,
    required this.section,
    required this.onCategoryTap,
    required this.onNeedMore,
  });

  /// The backend named the destination type; the app maps it to navigation it
  /// already has. An unrecognised type does nothing rather than guessing.
  void _navigate(BuildContext context, SeeAll s) {
    switch (s.type) {
      case 'category':
      case 'search':
        onCategoryTap(s.key);
    }
  }

  @override
  Widget build(BuildContext context) {
    // CHANGE #673 — the band. A section with no band colour sits on the page
    // background, which is what makes the banded ones read as separate blocks
    // rather than a continuous wash. Which section gets which colour is a
    // Postgres row, so re-colouring the feed is an UPDATE.
    final band = Brand.hex(section.band, Colors.transparent);
    final accent = Brand.hex(section.accent, Brand.green);

    // CHANGE #678 — one Show-all control for both product layouts, a
    // full-width button under the section. It used to be a card tacked onto
    // the end of the rail, which nobody scrolled 24 cards to reach.
    final seeAll = section.seeAll;
    final showBar = seeAll != null && section.seeAllLabel.isNotEmpty;

    return Container(
      // Full-bleed: the band runs edge to edge, the content inside keeps the
      // 16pt gutter. A band inset from the edges reads as a card, not a band.
      width: double.infinity,
      color: band,
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(section: section),
          const SizedBox(height: 16),
          switch (section.layout) {
            // CHANGE #677 — a vertical grid. The feed was every-section-a-rail,
            // which meant everything sideways and nothing you could sit and
            // browse. Rail vs grid is now a column in `storefront_home_section`,
            // so re-shaping the page is an UPDATE.
            HomeSectionLayout.grid => _ProductGrid(section: section),
            // CHANGE #678 — a rail carries up to the backend's ceiling and
            // fetches the next page as it is scrolled right, so sideways is
            // where depth lives and downwards always ends.
            HomeSectionLayout.rail => _Rail(
              section: section,
              onNeedMore: onNeedMore,
            ),
            // A category tile hands back `key` — the RAW category name the
            // chips already use ("ANTI INFECTIVES"), not the pretty label.
            HomeSectionLayout.iconGrid => _TileGrid(
              tiles: section.tiles,
              crossAxisCount: 4,
              centered: true,
              tinted: true,
              valueOf: (t) => t.key,
              onTap: onCategoryTap,
            ),
            // CHANGE #638 — a company tile now opens the real company page at
            // /company/<key>, so it hands back `key` again. The #637
            // search-prefill fallback is gone: it existed only because no
            // company listing existed yet, and a name search was never the
            // same thing as a company filter.
            HomeSectionLayout.brandGrid => _TileGrid(
              tiles: section.tiles,
              crossAxisCount: 3,
              centered: true,
              tinted: false,
              valueOf: (t) => t.key,
              onTap: (key) => Navigator.of(
                context,
              ).pushNamed('/company/${Uri.encodeComponent(key)}'),
            ),
            // Unreachable: unknown layouts are dropped at parse time. Kept so
            // this switch stays exhaustive if the enum grows.
            HomeSectionLayout.unknown => const SizedBox.shrink(),
          },
          if (showBar) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _SeeAllBar(
                label: section.seeAllLabel,
                accent: accent,
                onTap: () => _navigate(context, seeAll),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// CHANGE #638 — the back-in-stock strip, above Best Sellers.
///
/// Title and products both come from `my_stock_notifications()`; the app does
/// not decide who sees this or what is in it. It renders only when that
/// payload carried products.
class _StripBlock extends StatelessWidget {
  final BackInStock strip;
  const _StripBlock({required this.strip});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Brand.accentSoft,
      padding: const EdgeInsets.symmetric(vertical: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              strip.title,
              textAlign: TextAlign.center,
              style: AppType.h3,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: CompactProductCard.extent,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemExtent: _Rail.cardW + 12,
              itemCount: strip.items.length,
              itemBuilder: (context, i) {
                final p = strip.items[i];
                return Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: CompactProductCard(
                    product: p,
                    onTap: () =>
                        Navigator.of(context).pushNamed('/product/${p.id}'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// CHANGE #673 — the section header, centred and typeset.
///
/// Three things changed and each does work the others cannot:
///
///  * The subtitle became an **eyebrow above the title**, in caps with 1.6px
///    tracking and a rule line either side. Tracking is the whole effect — at
///    letter-spacing 0 it is just small grey text, which is what it was.
///  * The title is [AppType.h3] — 24px w800 at -0.5 tracking. The old 20px
///    w600 at 0 was the single biggest reason the page read as a document
///    rather than a storefront.
///  * The accent word takes the SECTION's own colour, not one green for the
///    whole feed, so each band is a distinct place.
///
/// Every string is still printed verbatim and the accent split is still
/// [HomeSection.accentWord] — never guessed from word position.
class SectionHeader extends StatelessWidget {
  final HomeSection section;
  const SectionHeader({super.key, required this.section});

  @override
  Widget build(BuildContext context) {
    final (before, accentWord, after) = section.titleParts;
    final accent = Brand.hex(section.accent, Brand.green);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (section.subtitle.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Rule(color: accent),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    section.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: AppType.eyebrow.copyWith(color: accent),
                  ),
                ),
                const SizedBox(width: 10),
                _Rule(color: accent, flip: true),
              ],
            ),
            const SizedBox(height: 8),
          ],
          Text.rich(
            TextSpan(
              style: AppType.h3,
              children: [
                TextSpan(text: before),
                if (accentWord.isNotEmpty)
                  TextSpan(
                    text: accentWord,
                    style: TextStyle(color: accent),
                  ),
                TextSpan(text: after),
              ],
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// The short line flanking an eyebrow. Fades out at its far end so it reads as
/// a typographic rule rather than a divider.
class _Rule extends StatelessWidget {
  final Color color;

  /// The right-hand rule fades the other way, so the pair is symmetric about
  /// the eyebrow instead of both leaning left.
  final bool flip;
  const _Rule({required this.color, this.flip = false});

  @override
  Widget build(BuildContext context) {
    final stops = [color.withValues(alpha: 0), color.withValues(alpha: 0.55)];
    return Container(
      width: 26,
      height: 1.5,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: flip ? stops.reversed.toList() : stops,
        ),
      ),
    );
  }
}

// ── rail ─────────────────────────────────────────────────────────────────────

/// CHANGE #678 — the horizontal rail, and the only place the feed grows.
///
/// It starts with the payload's cards and asks for the next page when the user
/// scrolls near its right-hand end, up to the ceiling the backend put in
/// `total`. Nothing here knows what that ceiling is: it asks
/// [HomeSection.canPageMore] and stops when the answer is no.
class _Rail extends StatefulWidget {
  final HomeSection section;
  final VoidCallback onNeedMore;

  const _Rail({required this.section, required this.onNeedMore});

  static const double cardW = 156;
  static const double gap = 12;

  @override
  State<_Rail> createState() => _RailState();
}

class _RailState extends State<_Rail> {
  /// CHANGE #678a — `keepScrollOffset: false`.
  ///
  /// The default is true, and every rail in the feed writes its offset into
  /// the SAME PageStorage bucket — none of them carries a key of its own. A
  /// rail scrolling into view then restored an offset a DIFFERENT rail had
  /// left there, which looked like the row scrolling sideways on its own, and
  /// landing near the end it immediately fetched a page. Nothing was
  /// animating: it was one rail wearing another rail's position.
  final ScrollController _c = ScrollController(keepScrollOffset: false);

  @override
  void initState() {
    super.initState();
    _c.addListener(_onScroll);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Asks for the next page when the end is within about three cards. The
  /// threshold is geometry — it decides WHEN to ask, never whether more exists.
  void _onScroll() {
    if (!_c.hasClients) return;
    if (!widget.section.canPageMore) return;
    final pos = _c.position;
    // Only ever after the user has actually dragged this rail. A rail sitting
    // untouched at 0 must never fetch — on a wide window its whole content
    // fits, maxScrollExtent is 0, and "near the end" would be true at rest.
    if (pos.pixels <= 0) return;
    if (pos.pixels < pos.maxScrollExtent - (_Rail.cardW * 3)) return;
    widget.onNeedMore();
  }

  @override
  Widget build(BuildContext context) {
    final cards = widget.section.cards;

    return SizedBox(
      // Fixed height derived from the card's own constant — the rail never
      // measures its children, so scrolling it costs no layout.
      height: CompactProductCard.extent,
      child: ListView.builder(
        controller: _c,
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemExtent: _Rail.cardW + _Rail.gap,
        itemCount: cards.length,
        itemBuilder: (context, i) {
          final p = cards[i];
          return Padding(
            padding: const EdgeInsets.only(right: _Rail.gap),
            child: CompactProductCard(
              product: p,
              onTap: () => Navigator.of(context).pushNamed('/product/${p.id}'),
            ),
          );
        },
      ),
    );
  }
}

// ── grid ─────────────────────────────────────────────────────────────────────

/// CHANGE #677 — a section rendered as a vertical grid instead of a rail.
///
/// CHANGE #678 — and a FINITE one. It shows exactly the cards the payload
/// carried and never grows: depth belongs to the rails, which scroll sideways,
/// and to the category page behind the Show-all button. A vertical block that
/// keeps loading under the thumb is why the page felt like it had no bottom.
///
/// It measures nothing and decides nothing: the item count is whatever the
/// payload holds, and the column count is the only thing chosen here — from
/// the available width, because that is geometry, not business.
class _ProductGrid extends StatelessWidget {
  final HomeSection section;

  const _ProductGrid({required this.section});

  /// The card is 156 wide in the rail; the grid gives it the same room. Two up
  /// on a phone, more as the window grows — never a hardcoded pixel width.
  static int columnsFor(double width) {
    final n = ((width - 32 + 12) / (168.0)).floor();
    return n.clamp(2, 6);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, c) => GridView.builder(
          shrinkWrap: true,
          // The page is the scrollable. A grid with its own scroll inside a
          // list is the thing that makes a feed feel broken on mobile.
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columnsFor(c.maxWidth),
            mainAxisExtent: CompactProductCard.extent,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: section.cards.length,
          itemBuilder: (context, i) {
            final p = section.cards[i];
            return CompactProductCard(
              product: p,
              onTap: () => Navigator.of(context).pushNamed('/product/${p.id}'),
            );
          },
        ),
      ),
    );
  }
}

/// CHANGE #678 — the Show-all button, under every product section.
///
/// Solid in the section's own accent and full width, because it is the one
/// route out of a section and the previous outline-on-white version read as
/// decoration. The word is the backend's, counts and all ("Show all 3,068
/// products") — the app holds no wording to fall back on, so no label means no
/// button.
class _SeeAllBar extends StatelessWidget {
  final String label;
  final Color accent;
  final VoidCallback onTap;
  const _SeeAllBar({
    required this.label,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: accent,
    borderRadius: BorderRadius.circular(Rad.pill),
    child: InkWell(
      borderRadius: BorderRadius.circular(Rad.pill),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 15),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: AppType.l4.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.arrow_forward_rounded,
              size: 16,
              color: Colors.white,
            ),
          ],
        ),
      ),
    ),
  );
}

// ── icon_grid / brand_grid ───────────────────────────────────────────────────

class _TileGrid extends StatelessWidget {
  final List<HomeTile> tiles;
  final int crossAxisCount;
  final bool centered;

  /// Category tiles get a tinted disc + icon from [categoryStyle]; company
  /// tiles get a neutral initial disc. Passed explicitly rather than inferred
  /// from [crossAxisCount], which is a layout number and not a meaning.
  final bool tinted;

  /// What this grid hands back on tap — `key` for categories, `label` for
  /// companies. Kept explicit so it is never inferred from a styling flag.
  final String Function(HomeTile) valueOf;
  final ValueChanged<String> onTap;

  const _TileGrid({
    required this.tiles,
    required this.crossAxisCount,
    required this.centered,
    required this.tinted,
    required this.valueOf,
    required this.onTap,
  });

  /// Tall enough for the disc, TWO label lines and the count. The old 92 fit
  /// barely one and a half, which is why long categories rendered as
  /// "Anti Infectiv…" and "Gynaecol ogical" — the tiles were not broken data,
  /// they were a box 30px too short.
  static const double _extent = 116;

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
          mainAxisExtent: _extent,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
        ),
        itemCount: tiles.length,
        itemBuilder: (_, i) => _Tile(
          tile: tiles[i],
          centered: centered,
          tinted: tinted,
          tapValue: valueOf(tiles[i]),
          onTap: onTap,
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final HomeTile tile;
  final bool centered;
  final bool tinted;
  final String tapValue;
  final ValueChanged<String> onTap;

  const _Tile({
    required this.tile,
    required this.centered,
    required this.tinted,
    required this.tapValue,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // The tint is keyed off the category name the backend already sent — the
    // app is not deciding what a category IS, only how to draw the one it was
    // handed. A name with no entry falls back to the neutral style.
    final style = categoryStyle(tile.key.isEmpty ? tile.label : tile.key);

    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(Rad.tile),
        border: Border.all(color: Brand.border),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: centered
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: tinted ? style.bg : Brand.field,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: tinted
                ? Icon(style.icon, size: 20, color: style.fg)
                : Text(
                    // First letter of the company's own name. Not a decision
                    // about the company — a rendering of the string sent.
                    tile.label.isEmpty ? '' : tile.label.characters.first,
                    style: AppType.l2.copyWith(color: Brand.inkMuted),
                  ),
          ),
          const SizedBox(height: 8),
          Flexible(
            child: Text(
              tile.label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: AppType.t2.copyWith(
                color: Brand.ink,
                fontWeight: FontWeight.w700,
                height: 13 / 10,
              ),
            ),
          ),
          if (tile.countLabel.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              tile.countLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: centered ? TextAlign.center : TextAlign.start,
              style: AppType.t2.copyWith(fontSize: 9, color: Brand.inkFaint),
            ),
          ],
        ],
      ),
    );

    // No key from the backend means no destination — the tile renders but does
    // not pretend to be tappable.
    if (!tile.tappable) return body;

    return InkWell(
      borderRadius: BorderRadius.circular(Rad.tile),
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
        const Icon(Icons.cloud_off_rounded, size: 34, color: Brand.inkFaint),
        const SizedBox(height: 14),
        OutlinedButton(
          onPressed: onRetry,
          style: OutlinedButton.styleFrom(
            foregroundColor: Brand.green,
            side: const BorderSide(color: Brand.green),
            shape: const StadiumBorder(),
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
