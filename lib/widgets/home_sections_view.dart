import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/home_sections.dart';
import '../services/payload_cache.dart';
import 'stale_payload.dart';
import '../models/storefront_p3.dart';
import '../utils/render_log.dart';
import '../theme.dart';
import 'animations.dart';
import 'card_layout.dart';
import 'compact_product_card.dart';
import 'product_card_grid.dart';
import 'customer_surface_widgets.dart'; // CHANGE #745 — the home chip strip
import 'product_image.dart';
import 'bottom_stack.dart'; // CMD #2091 — bottomStackLiveOf
import 'update_bar.dart'; // CMD #2091 — the chrome's own controller

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

  /// A "Show all products" / "Browse catalogue" target (category 'All') was
  /// tapped. HomeShell opens the full product grid rather than re-showing the
  /// home feed. Null → the see-all falls back to onCategoryTap.
  final VoidCallback? onBrowseAll;

  /// CMD #2027 — the See-all pill on "Shop by company" was tapped. The shell
  /// opens the catalogue's companies list. Null means the shell did not wire
  /// one, and the pill then does nothing rather than guessing a route.
  final VoidCallback? onOpenCompanies;

  /// Test seam: the back-in-stock strip payload.
  final Future<BackInStock> Function()? notificationsLoader;

  /// Test seam: what `stock_notify_seen` does. Production calls the RPC.
  final Future<void> Function(List<int> ids)? onSeen;

  /// Rendered as the last item of the feed. The home page keeps its trust
  /// badges and footer this way without a second scrollable — the feed is one
  /// lazy ListView, so sections below the fold are never built.
  final Widget? footer;

  /// CMD #2021 — bumped when the shell wants this feed back at the top.
  ///
  /// Home is the ONE scrollable on this screen (see the comment in
  /// storefront_screen.dart's build): the ListView below owns the offset, and
  /// `StorefrontScreen._scroll` has no clients while the feed is showing. So
  /// the shell's existing scroll-to-top signal reached a controller that was
  /// not attached to anything and did nothing at all — which is why tapping
  /// the logo from halfway down the feed left you halfway down the feed.
  final int scrollToTopTrigger;

  const HomeSectionsView({
    super.key,
    this.loader,
    required this.onCategoryTap,
    this.onBrowseAll,
    this.onOpenCompanies,
    this.notificationsLoader,
    this.onSeen,
    this.footer,
    this.scrollToTopTrigger = 0,
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

  /// CMD #1813 — the feed's last SUCCESSFUL payload, kept on the device.
  ///
  /// The session memo below already survived a failed refetch, but it lives in
  /// RAM: a cold start with a slow database had nothing, and the feed painted a
  /// bare Retry button in front of a customer. This controller paints the last
  /// good feed off disk first, refreshes behind it, and retries on the
  /// backend's own backoff. It is bypassed entirely when a test supplies
  /// [widget.loader].
  PayloadController? _payload;

  /// Null until the controller says something. A test that supplies its own
  /// loader has no controller and therefore no status line.
  PayloadState? _payloadState;

  /// CHANGE #678 — paging happens sideways, not downwards.
  ///
  /// A rail grows as you scroll RIGHT, up to the ceiling the backend set. The
  /// vertical page does not grow at all: a grid holds what it was given and
  /// ends in a Show-all button. #677 paged the page itself, and the result was
  /// a storefront you could never scroll to the bottom of.
  /// CMD #2037 — the feed comes back where it was left. Opening a category
  /// list (or a PDP) unmounts this widget, so the controller it was scrolling
  /// with is disposed; the offset is parked in [_homeFeedOffset] on the way
  /// out and handed to the next controller on the way in. That is what makes
  /// the Home tab a BACK button rather than a reset — the shell decides
  /// whether to go back or to the top, this only makes "back" mean something.
  late final ScrollController _scroll =
      ScrollController(initialScrollOffset: _homeFeedOffset);

  /// One in-flight request per section, keyed by section id — two rails may
  /// page at once without either seeing the other's half-applied result.
  final Set<String> _paging = <String>{};

  /// CMD #2051/#2066 — how much of the bottom the storefront's bottom chrome
  /// is covering. The Scaffold already stops this list at the top of the
  /// bottom nav, so the stack sitting ON that nav (the update-bar slot, and
  /// the cart pill above it) is the only thing left to scroll clear of.
  ///
  /// CMD #2091 — the room the chrome is ACTUALLY taking, not the ceiling.
  /// #2051 measured it and re-published it, which is what made the feed re-pad
  /// every time a sentence took a second line; #2066 replaced that with a
  /// constant and left the feed ending 116 px above the nav on every day with
  /// no update pending and an empty cart. This is neither: two booleans read
  /// from the same place the stack reads them, so the feed ends where the
  /// chrome does — and changes only when the chrome itself appears or goes.
  ///
  /// CMD #2147 — plus the floating dock's own room: the feed runs behind the
  /// dock, and its last row scrolls clear of it.
  double _updateBarClearance(BuildContext context) =>
      bottomStackLiveOf(context, pill: true).height +
      floatingDockClearanceOf(context);

  @override
  void didUpdateWidget(covariant HomeSectionsView old) {
    super.didUpdateWidget(old);
    // CMD #2021 — the Home tab, the logo and the system back button all land
    // on the home root, and landing there means the TOP of the feed. Jump
    // rather than animate when the feed is long: an eased 400 ms glide over
    // several thousand pixels reads as a freeze on a phone.
    if (old.scrollToTopTrigger != widget.scrollToTopTrigger) {
      _homeFeedOffset = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (_scroll.offset <= 0) return;
        if (_scroll.offset > _jumpAbove) {
          _scroll.jumpTo(0);
        } else {
          _scroll.animateTo(0,
              duration: _scrollHome, curve: Curves.easeOut);
        }
      });
    }
  }

  /// Above this offset a scroll-to-top jumps instead of animating.
  static const double _jumpAbove = 2400;
  static const Duration _scrollHome = Duration(milliseconds: 320);

  @override
  void dispose() {
    appUpdateBar.removeListener(_onChrome);
    _payload?.removeListener(_onPayload);
    _payload?.dispose();
    _homeFeedOffset = _scroll.hasClients ? _scroll.offset : _homeFeedOffset;
    _scroll.dispose();
    super.dispose();
  }

  /// An update arrived or was dismissed: the chrome changed height, so the
  /// room this feed holds back for it changed with it (#2091).
  void _onChrome() {
    if (mounted) setState(() {});
  }

  /// The controller moved: adopt its payload if it has one, and always adopt
  /// its status so the quiet line above the feed stays truthful.
  void _onPayload() {
    final c = _payload;
    if (c == null || !mounted) return;
    final st = c.state;
    final raw = st.data;
    HomeSections? parsed;
    if (raw != null) {
      try {
        parsed = HomeSections.fromMap(raw);
      } catch (_) {
        parsed = null;
      }
    }
    setState(() {
      _payloadState = st;
      if (parsed != null && parsed.ok) {
        HomeSectionsView._memo = parsed;
        _data = parsed;
      }
    });
    if (parsed != null && parsed.ok) _reportSeen();
  }

  @override
  void initState() {
    super.initState();
    // CMD #2091 — the feed's end padding is the chrome's LIVE height, so this
    // State has to hear the one input that is not a dependency of its build:
    // the update controller. The cart and the viewport arrive on their own.
    appUpdateBar.addListener(_onChrome);
    // Instant paint from the memo, then ALWAYS refetch in the background so a
    // backend change (counts, delivery time, section order) shows on the next
    // open rather than being pinned to a stale cache. Scroll offset survives
    // the rebuild via the PageStorageKey. Rule 8: cache renders, never decides.
    final memo = HomeSectionsView._memo;
    if (memo != null) {
      _data = memo;
    }
    if (widget.loader == null) {
      // Production path: disk cache first, then network, then backoff.
      final ctl = PayloadController(
        cacheKey: 'storefront_home_v2',
        fetch: () => MedicineRepository().fetchHomeSectionsRaw(),
      );
      _payload = ctl;
      ctl.addListener(_onPayload);
      unawaited(ctl.start());
      // The strip and the labels are not part of the feed payload.
      unawaited(_loadSideCars());
    } else {
      _load();
    }
  }

  /// The back-in-stock strip and the storefront labels — fetched alongside the
  /// feed, never per card, and never able to blank the feed if they fail.
  Future<void> _loadSideCars() async {
    unawaited(MedicineRepository().loadStorefrontLabels());
    try {
      final strip = await (widget.notificationsLoader ??
          () => MedicineRepository().myStockNotifications())();
      if (!mounted) return;
      setState(() => _backInStock = strip);
      _reportSeen();
    } catch (_) {
      // No strip is a missing strip, never a missing feed.
    }
  }

  Future<void> _load() async {
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

    HomeSections? sections;
    BackInStock strip = BackInStock.empty;
    try {
      final results = await Future.wait([loadSections(), loadNotifs()]);
      sections = results[0] as HomeSections;
      strip = results[1] as BackInStock;
    } catch (_) {
      sections = null; // network/parse failure — treat as no fresh payload
    }

    if (!mounted) return;

    // Rule 8: the cache is a render fallback, never overwritten by a worse
    // answer. A refetch only REPLACES the feed when it comes back ok; a failed
    // or ok:false refetch leaves the last good memo on screen (so a flaky
    // network never flips a populated home into a bare Retry). The bare Retry
    // shows only on a genuine cold start with nothing cached.
    final fresh = sections;
    if (fresh != null && fresh.ok) {
      HomeSectionsView._memo = fresh;
      setState(() {
        _data = fresh;
        _backInStock = strip;
      });
    } else if (HomeSectionsView._memo != null) {
      // Keep the cached feed; just carry any fresh strip verdict through.
      setState(() {
        _data = HomeSectionsView._memo;
        _backInStock = strip;
      });
    } else {
      // Cold start, nothing cached, fetch did not succeed → the retry state.
      setState(() {
        _data = fresh ?? HomeSections.failed;
        _backInStock = strip;
      });
    }

    _reportSeen();
    _reportRender();
  }

  /// CHANGE #274 — the card's own render-log line.
  ///
  /// The storefront is a canvas: no browser tool can read a Flutter widget, and
  /// "the string is in the bundle" only proves the code compiled. So the feed
  /// counts what it actually painted and posts it, which is the only evidence
  /// a deploy of this screen can produce (see the VERIFICATION RULE in
  /// CLAUDE.md).
  ///
  /// It counts, it never decides: `rails` is how many sections came back with
  /// the rail layout, `cards` is how many product cards those sections carry,
  /// and `ptr` is how many of them arrived with a trade price the viewer is
  /// entitled to — 0 for an anonymous visitor, which is itself the entitlement
  /// gate showing up in the log.
  void _reportRender() {
    final d = _data;
    if (d == null || !d.ok) return;
    var rails = 0;
    var cards = 0;
    var ptr = 0;
    for (final s in d.sections) {
      if (s.layout == HomeSectionLayout.rail) rails++;
      for (final c in s.cards) {
        cards++;
        if (c.pricing?.cardPrice?.hasPtr == true) ptr++;
      }
    }
    RenderLog.write('c274_home_cards',
        'rails=$rails cards=$cards ptr=$ptr sections=${d.sections.length}');
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

  /// "Show all products" / "Browse catalogue" — open the full grid. Falls back
  /// to a plain category jump if the shell did not wire the browse-all target.
  void _openBrowseAll() {
    if (widget.onBrowseAll != null) {
      widget.onBrowseAll!();
    } else {
      widget.onCategoryTap('All');
    }
  }

  /// CMD #2027 — "See all products" under Shop by company. The app holds no
  /// fallback: an unwired shell draws the pill and does nothing, which is the
  /// same rule every other unknown destination follows.
  void _openCompanies() => widget.onOpenCompanies?.call();

  @override
  Widget build(BuildContext context) {
    final d = _data;

    // CMD #1813 — three states, and none of them is a dead end.
    //
    // Nothing yet: the skeleton, with the quiet line saying we are still
    // trying. ok:false or a failed refresh: the LAST GOOD feed stays exactly
    // where it is and the line turns amber. There is no Retry button in any of
    // them — [PayloadController] is already retrying on the backend's schedule,
    // and pull-to-refresh below is still there for an impatient thumb.
    if (d == null || !d.ok) {
      // CMD #2156 — the pill floats over the skeleton; nothing moves.
      return PayloadStatusOverlay(
        state: _payloadState,
        child: const _FeedSkeleton(),
      );
    }

    // CHANGE #673 — the hero is the first row of the feed rather than a
    // separate widget above it, so it scrolls with the content and costs no
    // second scrollable. `show` is the backend's decision, not "is the title
    // non-empty".
    final hero = d.hero.show ? 1 : 0;

    // The strip sits ABOVE Best Sellers, and only when the backend sent
    // products for it.
    final strip = _backInStock.show ? 1 : 0;

    // CHANGE #745 — the customer strip: the wishlist chip and the rewards
    // badge, placed by customer_feature_placement rather than by this file.
    // It rides as a feed row for the same reason the hero does (one
    // scrollable), and it draws nothing at all — not even a gap — when the
    // backend placed nothing on 'home_chip'/'home_badge' or when the caller
    // has no pharmacy account.
    const lane = 1;

    final lead = hero + strip + lane;

    // The loaded feed carries the same quiet line: a slow or failing refresh
    // says so above the content instead of replacing it.
    // CMD #2156 — as ONE small pill floating under the search bar, over the
    // feed, so the feed never jumps when it comes or goes.
    // CMD #2167 — everything below draws on the 'home' surface, so
    // `card.layout_screens.home` can restyle the feed's cards on their own.
    return CardSurface(
      screen: 'home',
      child: PayloadStatusOverlay(
      state: _payloadState,
      child: RefreshIndicator(
      onRefresh: () => _payload == null ? _load() : _payload!.refresh(),
      child: ListView.builder(
        key: const PageStorageKey('home-sections'),
        controller: _scroll,
        // AlwaysScrollable so the pull gesture works even on a short feed;
        // Clamping so a hard flick past the end never opens a blank strip that
        // snaps back on release (the feed stops firmly top and bottom).
        physics: const AlwaysScrollableScrollPhysics(
          parent: ClampingScrollPhysics(),
        ),
        // CHANGE — the feed ends at the footer. The old bottom:96 spacer left a
        // blank band scrolling past the real end of the page.
        //
        // CMD #2051 — except for whatever the bottom stack is covering. The
        // Scaffold already ends this list at the top of the bottom nav, so the
        // only thing left to clear is the chrome sitting ON that nav; the
        // number is the stack's own measured height, 0 while it is down, so
        // the footer stops exactly at the real end of the page otherwise.
        padding: EdgeInsets.only(bottom: _updateBarClearance(context)),
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
              onCta: _openBrowseAll,
            );
          }
          if (strip == 1 && i == hero) {
            return _StripBlock(strip: _backInStock);
          }
          if (i == hero + strip) return const CustomerHomeStrip();
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
            onBrowseAll: _openBrowseAll,
            onOpenCompanies: _openCompanies,
            onNeedMore: () => unawaited(_pageSection(section.id)),
          );
        },
      ),
      ),
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
    // CHANGE #678 — the hero number is the viewer's count (zone for an
    // approved customer, catalogue for anyone else), formatted by the backend
    // and printed verbatim. The log carries every prop label so the live
    // render can be checked against the payload without a screenshot.
    RenderLog.write('c678_hero_props', hero.props.map((p) => p.label).join('|'));

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

  /// Opens the full product grid (a see-all that targets category 'All').
  final VoidCallback onBrowseAll;

  /// Opens the catalogue's companies list (a see-all of type 'companies').
  final VoidCallback onOpenCompanies;

  /// CHANGE #678 — the rail has been scrolled near its end and wants the next
  /// page. Whether one is fetched is decided upstairs, from the payload.
  final VoidCallback onNeedMore;

  const _SectionBlock({
    super.key,
    required this.section,
    required this.onCategoryTap,
    required this.onBrowseAll,
    required this.onOpenCompanies,
    required this.onNeedMore,
  });

  /// The backend named the destination type; the app maps it to navigation it
  /// already has. An unrecognised type does nothing rather than guessing.
  void _navigate(BuildContext context, SeeAll s) {
    switch (s.type) {
      case 'category':
        // 'All' is the whole catalogue — open the full product grid, not the
        // home feed we are already looking at (which made the button dead).
        if (s.key == 'All') {
          onBrowseAll();
        } else {
          onCategoryTap(s.key);
        }
      case 'search':
        onCategoryTap(s.key);
      // CMD #2027 — Shop by company's own pill. The backend names the
      // destination; the shell owns the catalogue tab it lands on.
      case 'companies':
        onOpenCompanies();
    }
  }

  @override
  Widget build(BuildContext context) {
    // CHANGE #673 — the band. A section with no band colour sits on the page
    // background, which is what makes the banded ones read as separate blocks
    // rather than a continuous wash. Which section gets which colour is a
    // Postgres row, so re-colouring the feed is an UPDATE.
    final band = Brand.hex(section.band, Colors.transparent);

    // CHANGE #678 — one Show-all control for both product layouts, a
    // full-width button under the section. It used to be a card tacked onto
    // the end of the rail, which nobody scrolled 24 cards to reach.
    final seeAll = section.seeAll;
    // No "Show all products" bar for a whole-catalogue see-all (key 'All' —
    // Best Sellers and the All-products rail): the hero's "Browse catalogue"
    // CTA already opens the full grid. Category- and company-wise see-alls keep
    // their bar.
    //
    // CMD #2037 read "same grey pill every rail" as "add one here too" and put
    // it back within the hour: TWO protected tests hold this exclusion down
    // (storefront_paging_test, home_sections_test) and #678 chose it on
    // purpose. What the spec is asking for is that the pill LOOKS the same on
    // every rail that has one — which is the centred group below.
    final showBar = seeAll != null &&
        section.seeAllLabel.isNotEmpty &&
        seeAll.key != 'All';

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
            // CMD #2118 — the same tiles, with a filter box pinned under the
            // heading. Typing narrows the grid SERVER-SIDE, so a buyer who
            // knows the maker never scrolls a twelve-tile sample looking for
            // it.
            HomeSectionLayout.brandGrid => CompanyFilterGrid(section: section),
            // Unreachable: unknown layouts are dropped at parse time. Kept so
            // this switch stays exhaustive if the enum grows.
            HomeSectionLayout.unknown => const SizedBox.shrink(),
          },
          if (showBar) ...[
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _SeeAllPill(
                label: section.seeAllLabel,
                // CMD #2027 — the backend's own list, already filtered to the
                // products that HAVE a photo. Taking the first three cards and
                // dropping the ones without an image is what used to leave one
                // lonely disc on a rail full of photographed products.
                thumbs: section.seeAllThumbs,
                bg: section.seeAllBg,
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
          // CMD #2167 — the ONE rail: catalogue-width cards, no reserved
          // height, every card in it as tall as the tallest.
          ProductCardRail(
            items: strip.items,
            onOpen: (p) =>
                Navigator.of(context).pushNamed('/product/${p.id}'),
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

  /// CMD #2167 — the rail's card width is the CATALOGUE's card width, which
  /// [ProductCardRail] reads from the payload's own `card.layout`. #274's
  /// viewport formula ([HomeSectionMetrics.railCardWidth]) made a home card
  /// 149 wide where the same card on a list was 158: one product, two sizes.
  /// What is left here is the paging threshold, which is about scrolling.
  static const double cardW = 156;

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

    // CMD #2167 — the rail draws the CATALOGUE's card at the catalogue's
    // width, so a product looks the same size on the feed and on a list, and
    // the next card peeks past the right edge. No height is reserved: the
    // row is as tall as its tallest card.
    return ProductCardRail(
      items: cards,
      controller: _c,
      onOpen: (p) => Navigator.of(context).pushNamed('/product/${p.id}'),
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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, c) {
          // A vertical grid stays compact — 6 cards on a phone, 10 on web —
          // while the horizontal rails carry up to 100. The backend sends up
          // to 10; a phone shows the first 6.
          final cap = c.maxWidth >= 600 ? 10 : 6;
          final count =
              section.cards.length < cap ? section.cards.length : cap;
          // CMD #2167 — the page is the scrollable, and the grid is rows of
          // cards that share their row's height.
          return ProductCardGrid(
            items: section.cards.take(count).toList(),
            onOpen: (p) =>
                Navigator.of(context).pushNamed('/product/${p.id}'),
          );
        },
      ),
    );
  }
}

/// CMD #2037 — where the home feed was left, in logical pixels.
///
/// Held outside the widget because the widget is what goes away: opening a
/// category list unmounts the feed and disposes its controller. The shell's
/// scroll-to-top zeroes it, so "tap Home again at the root" still means the
/// top.
double _homeFeedOffset = 0;

/// CMD #2027 — the See-all pill, under every section that has a destination.
///
/// One calm control on every rail. It used to be a solid bar painted in the
/// section's OWN accent, which put red, purple, blue and green full-width
/// buttons down a single scroll and made the feed read as four unrelated apps.
/// The pill is the search field's grey, the section colour lives in the title
/// and the rule line where it means something, and the wording is the
/// backend's — counts and all, so re-wording it is an UPDATE, not a deploy.
class _SeeAllPill extends StatelessWidget {
  final String label;

  /// Up to three product photos, chosen by the backend from products that
  /// actually have one. Empty renders no discs rather than blank circles.
  final List<String> thumbs;
  final VoidCallback onTap;

  /// CMD #2167 — `section.see_all_bg`: the row's own background colour, sent
  /// with the section. Empty falls back to the page ground.
  final String bg;

  const _SeeAllPill({
    required this.label,
    required this.onTap,
    this.thumbs = const [],
    this.bg = '',
  });

  static const double _thumb = 32;
  static const double _overlap = 22;

  @override
  Widget build(BuildContext context) => Material(
    key: const Key('c2027_see_all_pill'),
    // CMD #2167 — the row's background is `section.see_all_bg`, never a grey
    // typed here. Re-colouring it is an UPDATE to storefront_theme.
    color: Ds.hex(bg, Ds.c.bg),
    borderRadius: Ds.r.rCard,
    child: InkWell(
      borderRadius: Ds.r.rCard,
      onTap: onTap,
      child: Container(
        height: Ds.touch.listRowMinHeight,
        decoration: BoxDecoration(
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        // CMD #2037 — ONE CENTRED GROUP. The discs used to sit on the left
        // edge, the label was an Expanded centred in whatever was left and the
        // chevron was pinned to the right edge, so a pill read as three things
        // with two gaps between them and the "centred" label was not centred
        // against the group it belonged to. Now thumbs, words and chevron are
        // a single min-width Row centred in the pill: they travel together at
        // every width, and the whole group shrinks (the label ellipsises)
        // rather than the gaps growing.
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            Flexible(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (thumbs.isNotEmpty) ...[
                    SizedBox(
                      height: _thumb,
                      width: _thumb + _overlap * (thumbs.length - 1),
                      child: Stack(
                        children: [
                          for (var i = 0; i < thumbs.length; i++)
                            Positioned(
                              left: i * _overlap,
                              child: _ThumbDisc(
                                key: ValueKey('c2027_pill_thumb_$i'),
                                url: thumbs[i],
                              ),
                            ),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x8),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.body.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: Ds.space.x16 + Ds.space.x4,
                    color: Ds.c.textSecondary,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// One circular product photo on the See-all pill. The ring is the pill's own
/// surface, so overlapping discs stay separable against the grey.
class _ThumbDisc extends StatelessWidget {
  final String url;
  const _ThumbDisc({super.key, required this.url});

  @override
  Widget build(BuildContext context) => Container(
        width: _SeeAllPill._thumb,
        height: _SeeAllPill._thumb,
        decoration: BoxDecoration(
          color: Ds.c.surface,
          shape: BoxShape.circle,
          border: Border.all(color: Ds.c.surface, width: 2),
        ),
        clipBehavior: Clip.antiAlias,
        child: ProductImage(
          url: url,
          width: _SeeAllPill._thumb,
          height: _SeeAllPill._thumb,
          radius: BorderRadius.circular(_SeeAllPill._thumb),
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

// CMD #1813 — the _Retry widget that used to live here is gone on purpose.
//
// It was the bare Retry button a customer met when every RPC stalled together
// at ~13.9 s. The feed now keeps its last good payload and retries itself on
// the backend's backoff, so there is no state left for that button to occupy.

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


/// CMD #2118 — "Shop by company", with a filter box.
///
/// The twelve tiles the home payload carries are a SAMPLE of a few thousand
/// makers, so the section could only ever answer "is my company one of the
/// twelve?". The box asks `storefront_company_search` instead: matching,
/// ranking, the count sentence, the placeholder and the nothing-matched line
/// are all the backend's, and this widget swaps one list of tiles for another.
class CompanyFilterGrid extends StatefulWidget {
  final HomeSection section;

  /// Test seam — supply rows instead of calling the RPC.
  final Future<CompanyHits> Function(String q)? search;

  const CompanyFilterGrid({super.key, required this.section, this.search});

  @override
  State<CompanyFilterGrid> createState() => _CompanyFilterGridState();
}

class _CompanyFilterGridState extends State<CompanyFilterGrid> {
  final _ctrl = TextEditingController();
  Timer? _debounce;

  /// The block's own copy (hint, nothing-matched line), fetched once with an
  /// empty term. Never typed here.
  CompanyHits _copy = CompanyHits.none;
  CompanyHits _hits = CompanyHits.none;
  String _q = '';
  bool _loading = false;

  /// Long enough that a phone keyboard does not fire a request per letter,
  /// short enough that "tor" feels instant.
  static const Duration _wait = Duration(milliseconds: 220);

  Future<CompanyHits> Function(String) get _search =>
      widget.search ?? (q) => MedicineRepository().fetchCompanyHits(q);

  @override
  void initState() {
    super.initState();
    _loadCopy();
  }

  Future<void> _loadCopy() async {
    try {
      final c = await _search('');
      if (mounted) setState(() => _copy = c);
    } catch (_) {
      // No copy means no placeholder — the box still works, and the app has
      // no word of its own to put there.
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    final q = v.trim();
    if (q.isEmpty) {
      setState(() {
        _q = '';
        _hits = CompanyHits.none;
        _loading = false;
      });
      return;
    }
    setState(() {
      _q = q;
      _loading = true;
    });
    _debounce = Timer(_wait, () async {
      final hits = await _search(q);
      if (!mounted || _q != q) return;
      setState(() {
        _hits = hits;
        _loading = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtering = _q.isNotEmpty;
    final tiles = filtering
        ? [
            for (final r in _hits.rows)
              HomeTile(label: r.label, countLabel: r.countLabel, key: r.key),
          ]
        : widget.section.tiles;

    RenderLog.write('c2118_company_filter',
        'q=$_q;tiles=${tiles.length}');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          child: Semantics(
            identifier: 'company_filter_box',
            textField: true,
            child: TextField(
              controller: _ctrl,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              style: Ds.t.body,
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Ds.c.surface,
                hintText: _copy.hint,
                hintStyle: Ds.t.body.copyWith(color: Ds.c.textSecondary),
                prefixIcon: Icon(Icons.search, color: Ds.c.textSecondary),
                suffixIcon: !filtering
                    ? null
                    : IconButton(
                        icon: Icon(Icons.close, color: Ds.c.textSecondary),
                        onPressed: () {
                          _ctrl.clear();
                          _onChanged('');
                        },
                      ),
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
        ),
        SizedBox(height: Ds.space.x16),
        if (filtering && tiles.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            child: Text(
              _loading ? '' : _copy.emptyLabel,
              style: Ds.t.caption,
            ),
          )
        else
          _TileGrid(
            tiles: tiles,
            crossAxisCount: 3,
            centered: true,
            tinted: false,
            valueOf: (t) => t.key,
            onTap: (key) => Navigator.of(context)
                .pushNamed('/company/${Uri.encodeComponent(key)}'),
          ),
      ],
    );
  }
}
