part of '../home_shell.dart';

// CMD #2021 · shard — where the bottom tabs and the system back button land.
//
// CHANGE #327 sharded this shell into `part` files so one concern owns one
// leasable path, and the god-file guard holds home_shell.dart under 2,000
// lines with exactly one concern left in it: boot/routing. "Which root does
// this tap mean" is not boot/routing, and it arrived with 1,991 of those
// 2,000 lines already spent — so it lands here, in its own file, the way the
// bars and the cart panel did.
//
// It is an EXTENSION rather than a mixin because every line below reads the
// shell's own private state (`_index`, `_category`, `_search`, …) and a part
// shares the library's privacy scope: an extension sees those directly, where
// a mixin would need every one of them re-declared as an abstract getter and
// setter. `setState` is the one member an extension may not touch (it is
// @protected, and an extension is not a subclass), so the shell exposes the
// single-line `_navSetState` for it.
//
// The DECISIONS are not here either — they are pure, in models/shell_nav.dart,
// where test/protected/shell_nav_test.dart covers them without a Navigator, a
// Supabase client or a canvas. What is here is only the applying.

extension _ShellNavRoots on _HomeShellState {
  /// CMD #2021 — THE home root, and the only definition of it.
  ///
  /// The logo, the Home tab, the system back button and a product page's own
  /// home action all land here, so there is one answer to "what is home" and
  /// not four that have to agree.
  ///
  /// `_search` is cleared here for the first time. Since CMD #1906 the shopper's
  /// search lives in `_search` (query, filters, page) and `_query` is only its
  /// text; clearing `_query` alone left `_search.hasQuery` true, so the
  /// storefront kept rendering the search result while the URL said `/`. That
  /// is the logo bug this command found on the way to the tab one.
  void _goHome() {
    _navSetState(() {
      _index = 0;
      _category = 'All';
      _query = '';
      _search = SearchQueryState.blank;
      _searchPayload = null;
      _browseAll = false;
      _cartOpen = false;
      _scrollToTopTrigger++;
      shellHeaderBandShow(); // CMD #2019 — home starts full-chrome.
    });
    _searchCtrl.clear();
    pushUrl('/');
  }

  /// CMD #2021 — the Catalogue's own root: the Browse-by tiles.
  ///
  /// The Catalogue keeps its position in one immutable `CatalogueRoute`, and
  /// the seam that already exists for telling it where to go is `shellScope` —
  /// a NEW instance is what its didUpdateWidget reacts to, which is why this
  /// builds a fresh landing route every tap rather than reusing a const one.
  void _goCatalogue() {
    _navSetState(() {
      _index = ShellPage.catalogue;
      _cartOpen = false;
      _catScope = CatalogueRoute(search: SearchQueryState.blank);
      _search = SearchQueryState.blank;
      _searchPayload = null;
      _query = '';
      _category = 'All';
      _browseAll = false;
      shellHeaderBandShow();
    });
    _searchCtrl.clear();
    pushUrl(_urlForState());
  }

  /// CMD #2021 — a bottom tab is a ROOT, not a bookmark.
  ///
  /// The bar hands back the PAGE its registry row named (CHANGE #630); what
  /// landing on that page MEANS is `ShellNav.tapOn`, which is pure and covered
  /// by test/protected/shell_nav_test.dart. Tapping the already-selected Home
  /// tab needs no branch of its own: `_goHome()` bumps the scroll trigger every
  /// time, so re-tapping it scrolls the feed to the top.
  void _onNavTap(int page) {
    switch (ShellNav.tapOn(page)) {
      case ShellTabTap.homeRoot:
        _goHome();
      case ShellTabTap.catalogueRoot:
        _goCatalogue();
      case ShellTabTap.showPage:
        _showPage(page);
    }
  }

  /// CMD #2021 — a pushed page (PDP, company) asked for the storefront home.
  void _onHomeSignal() {
    if (mounted) _goHome();
  }

  /// CMD #2021 — the shell's state, as the back ladder reads it.
  ShellNavState get _navState => ShellNavState(
        page: _index,
        category: _category,
        query: _query,
        browseAll: _browseAll,
        cartOpen: _cartOpen,
      );

  /// CMD #2021 — the Android system back button, one rung per press.
  ///
  /// Back out of a category list, a search result, the whole-catalogue grid,
  /// the Catalogue, Orders or Bulk lands on the home root — never back inside
  /// the list at the offset it was left, which is what an IndexedStack shell
  /// otherwise does because none of those are routes. From the home root the
  /// press is not intercepted at all and the app closes, as normal.
  ///
  /// Web is untouched: browser back is history, handled by `listenPopState` →
  /// `_applyPath`, and never reaches a PopScope on the shell's own route.
  void _onSystemBack() {
    switch (ShellNav.back(_navState)) {
      case ShellBack.closeCart:
        _navSetState(() => _cartOpen = false);
      case ShellBack.goHome:
        _goHome();
      case ShellBack.exit:
        break; // canPop was true — the framework already popped.
    }
  }

  /// Show a tab and push the matching URL — the plain case, unchanged since
  /// CHANGE #614. Every caller that is not a bottom-bar tap (the footer links,
  /// the desktop header, a placed order returning to Orders) arrives here
  /// through `_setIndex`, which is now the dispatcher above.
  void _showPage(int i) {
    _navSetState(() {
      _index = i;
      _cartOpen = false;
      // CHANGE #614 — the Orders tab lives in an IndexedStack, which keeps its
      // State alive precisely so tab switches do NOT rebuild it. That also
      // means it never re-fetched: whatever it loaded once, at shell build,
      // was what it kept showing. Bumping the signal here makes opening the
      // tab an actual fetch, so the list is never older than the tap.
      if (i == 1) _ordersRefreshSignal++;
      shellHeaderBandShow(); // CMD #2019 — a new tab starts full-chrome.
    });
    pushUrl(_urlForState());
  }

  /// CMD #2027 — "See all products" under Shop by company.
  ///
  /// The rail shows the top makers; the pill behind it opens the catalogue's
  /// full companies list — the same door the Catalogue tab's Company tile
  /// opens, so there is one companies list and not two. The URL is the
  /// route's own, so a reload or a back press lands on the same list.
  void _openCompaniesList() {
    const route = CatalogueRoute(tab: 'companies');
    _navSetState(() {
      _catScope = route;
      _index = 12;
      _cartOpen = false;
    });
    pushUrl(route.url);
  }
}
