// CMD #2021 — the bottom tabs are ROOTS, and the back button is a ladder.
//
// Om: "tapping the Home tab must do exactly what tapping the mediBO logo
// does". The bar hands the shell the PAGE its registry row names (CHANGE
// #630) and the shell used to show that page — which, for the storefront,
// was whatever was left on it: a category grid, a search result, the
// whole-catalogue grid. A tab that re-opens the screen you are already on is
// a bookmark.
//
// Flutter web renders to canvas, so there is no browser-level proof of a tap
// available to this repo at all (VERIFICATION RULE). The rule is therefore
// pure — `lib/models/shell_nav.dart` — and this file is the whole of it:
// which reset a page means, when back leaves the app, and the fact that
// "already on Home" is deliberately NOT a special case.
//
// Runs on the Dart VM in milliseconds: no network, no Supabase, no widgets.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/shell_nav.dart';

ShellNavState _state({
  int page = ShellPage.storefront,
  String category = ShellNavState.anyCategory,
  String query = '',
  bool browseAll = false,
  bool cartOpen = false,
}) =>
    ShellNavState(
      page: page,
      category: category,
      query: query,
      browseAll: browseAll,
      cartOpen: cartOpen,
    );

void main() {
  group('a bottom tab is a root, not a bookmark', () {
    test('the storefront slot always means the home root', () {
      expect(ShellNav.tapOn(ShellPage.storefront), ShellTabTap.homeRoot);
    });

    test('the catalogue slot always means the catalogue landing', () {
      expect(ShellNav.tapOn(ShellPage.catalogue), ShellTabTap.catalogueRoot);
    });

    test('every other slot still just shows its page', () {
      // Orders, Bulk, My Shop and the staff sections keep their old
      // behaviour: nothing here resets a page it does not own.
      for (final page in const [1, 2, 3, 11, 13, 14]) {
        expect(ShellNav.tapOn(page), ShellTabTap.showPage,
            reason: 'page $page must not be reset by a tab tap');
      }
    });

    test('the answer does not depend on where the shopper already is', () {
      // Spec item 2 — tapping the ALREADY-ACTIVE Home tab scrolls the feed to
      // the top — needs no branch of its own precisely because of this: the
      // tap always means "go to the home root", and going there always bumps
      // the scroll signal. A `if (page == current) return;` guard in the
      // shell is the bug this test exists to keep out.
      expect(ShellNav.tapOn(ShellPage.storefront), ShellTabTap.homeRoot);
      expect(ShellNav.tapOn(ShellPage.catalogue), ShellTabTap.catalogueRoot);
    });
  });

  group('what counts as the home root', () {
    test('the sectioned feed, unfiltered and unsearched', () {
      expect(_state().isHomeRoot, isTrue);
    });

    test('a category list is not the home root', () {
      expect(_state(category: 'CARDIAC').isHomeRoot, isFalse);
    });

    test('a search result is not the home root', () {
      expect(_state(query: 'dolo').isHomeRoot, isFalse);
      // Whitespace is not a search.
      expect(_state(query: '   ').isHomeRoot, isTrue);
    });

    test('the Show-all grid is not the home root', () {
      expect(_state(browseAll: true).isHomeRoot, isFalse);
    });

    test('an open cart is not the home root', () {
      expect(_state(cartOpen: true).isHomeRoot, isFalse);
    });

    test('another tab is not the home root', () {
      expect(_state(page: ShellPage.catalogue).isHomeRoot, isFalse);
      expect(_state(page: 1).isHomeRoot, isFalse);
    });
  });

  group('the system back ladder — one rung per press', () {
    test('an open cart closes first, wherever it was opened from', () {
      expect(ShellNav.back(_state(cartOpen: true)), ShellBack.closeCart);
      expect(ShellNav.back(_state(category: 'CARDIAC', cartOpen: true)),
          ShellBack.closeCart);
    });

    test('a category list goes home, never back into the list', () {
      expect(ShellNav.back(_state(category: 'CARDIAC')), ShellBack.goHome);
    });

    test('search results and the Show-all grid go home', () {
      expect(ShellNav.back(_state(query: 'dolo')), ShellBack.goHome);
      expect(ShellNav.back(_state(browseAll: true)), ShellBack.goHome);
    });

    test('the Catalogue, Orders and Bulk go home', () {
      expect(ShellNav.back(_state(page: ShellPage.catalogue)),
          ShellBack.goHome);
      expect(ShellNav.back(_state(page: 1)), ShellBack.goHome);
      expect(ShellNav.back(_state(page: 2)), ShellBack.goHome);
    });

    test('back from the home root exits, as normal', () {
      expect(ShellNav.back(_state()), ShellBack.exit);
    });

    test('canPop is true only where back is meant to leave the app', () {
      // This is what the shell hands PopScope, so an inversion here is an app
      // that either cannot be closed or closes from the middle of a list.
      expect(ShellNav.canPop(_state()), isTrue);
      expect(ShellNav.canPop(_state(category: 'CARDIAC')), isFalse);
      expect(ShellNav.canPop(_state(query: 'dolo')), isFalse);
      expect(ShellNav.canPop(_state(browseAll: true)), isFalse);
      expect(ShellNav.canPop(_state(cartOpen: true)), isFalse);
      expect(ShellNav.canPop(_state(page: ShellPage.catalogue)), isFalse);
    });
  });

  group('the signal a pushed page fires', () {
    test('firing it moves the notifier the shell listens to', () {
      // A product page and a company page are routes pushed ABOVE the shell,
      // so they cannot reach its state; they pop and fire this instead. The
      // shell's listener calls the same _goHome() the logo and the tab call.
      final before = ShellHomeSignal.value.value;
      ShellHomeSignal.value.value = before + 1;
      expect(ShellHomeSignal.value.value, before + 1);
    });
  });
}
