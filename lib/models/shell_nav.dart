import 'package:flutter/widgets.dart';

/// CMD #2021 — where a bottom-tab tap and the system back button land.
///
/// Om: "tapping the Home tab must do exactly what tapping the mediBO logo
/// does". It did not. The bar hands the shell the PAGE its registry row names
/// (`customer_nav_slot.page_index`, CHANGE #630) and the shell showed that
/// page — which, for the storefront, is whatever the shopper left on it: a
/// category grid, a search result, the whole-catalogue grid. A tab that
/// re-opens the screen you were already on is a bookmark, not a destination.
///
/// The rule this file holds is one sentence — **a bottom tab is a ROOT, not a
/// bookmark** — plus the back ladder that follows from it. It is pure: no
/// widgets, no RPC, no strings. That is what lets `test/protected` cover the
/// whole rule on the Dart VM in milliseconds, with no Supabase client and no
/// canvas to read (Flutter web renders to canvas, so a widget-level proof of
/// this behaviour is not available to us at all).
///
/// Nothing here is a display decision: every word in the bar is still the
/// backend's (`customer_nav().slots[].label`), every page is still the row's
/// own `page_index`, and this file only answers "what does landing on that
/// page mean".

/// The IndexedStack positions `home_shell.dart` builds, named once.
///
/// They are addressed by NUMBER in several places already (pages 3–10 are the
/// admin sections, 11 is My Shop, 12 is the Catalogue — see the `pages` list),
/// so naming the two this rule turns on keeps the literals out of the new code
/// instead of adding a fourth copy of them.
class ShellPage {
  const ShellPage._();

  /// The storefront: the sectioned home feed, category grids and search.
  static const int storefront = 0;

  /// The Catalogue (CHANGE #747) — its own screen, with its own landing.
  static const int catalogue = 12;
}

/// What a tap on a bottom-nav slot means.
enum ShellTabTap {
  /// Return the storefront to its home feed and scroll that feed to the top —
  /// identically to the logo, and identically whether the tab was already
  /// selected or not.
  homeRoot,

  /// Return the Catalogue to its landing (the Browse-by tiles), leaving no
  /// class trail, product list, letter or search behind it.
  catalogueRoot,

  /// Every other slot: show that page, exactly as before.
  showPage,
}

/// CMD #2037 — what a tap on the HOME tab means, given where the shopper is.
///
/// #2021 made every Home tap the same instruction (root + top), which is right
/// for the logo and wrong for a tab: leaving the feed to look at Orders and
/// coming back cost the shopper their whole scroll, and so did opening a
/// category list. Home is a BACK button now, and only the last press is a
/// reset:
///
///   Orders → Home  ............ the storefront exactly as it was left
///   a category list → Home  ... back out to the feed, where it was left
///   the feed itself → Home  ... scroll to the top
///
/// The logo and the system back button are untouched: both still mean the home
/// ROOT, which is [ShellTabTap.homeRoot].
enum ShellHomeTap {
  /// Another tab: show the storefront again, with whatever it was showing —
  /// category, search, scroll offset and all.
  resumeStorefront,

  /// The storefront, but inside something opened from home (a category list, a
  /// search result, the whole-catalogue grid, the cart panel): step back out
  /// to the feed, which keeps the offset it was left at.
  backToFeed,

  /// The feed itself, at the root: scroll it to the top.
  scrollTop,
}

/// What the Android system back button does while the shell itself is on top.
enum ShellBack {
  /// The cart panel is open over the shell: close that first.
  closeCart,

  /// Anywhere that is not the home root — a category list, a search result,
  /// the whole-catalogue grid, the Catalogue, Orders, Bulk — goes home. It
  /// never restores the scroll position inside the list that was left.
  goHome,

  /// The home root: back leaves the app, as normal.
  exit,
}

/// The slice of shell state the two decisions above read.
@immutable
class ShellNavState {
  /// The IndexedStack page currently showing.
  final int page;

  /// The storefront category filter. [anyCategory] means "not filtered".
  final String category;

  /// The shopper's search text, if any.
  final String query;

  /// The whole-catalogue product grid ("Show all N products") is open.
  final bool browseAll;

  /// The cart panel is open over the shell.
  final bool cartOpen;

  const ShellNavState({
    required this.page,
    required this.category,
    required this.query,
    required this.browseAll,
    required this.cartOpen,
  });

  /// The sentinel the storefront has always used for "every category".
  static const String anyCategory = 'All';

  /// The storefront, showing the sectioned home feed and nothing else — the
  /// one place the logo has always landed, and now the one place Home lands.
  bool get isHomeRoot =>
      page == ShellPage.storefront &&
      category == anyCategory &&
      query.trim().isEmpty &&
      !browseAll &&
      !cartOpen;
}

/// The decisions themselves.
class ShellNav {
  const ShellNav._();

  /// A tap on the bar, resolved from the page the tapped row named.
  ///
  /// CMD #2037 — [ShellTabTap.homeRoot] is now the NAME of the home slot, not
  /// the whole instruction: what a Home tap does depends on where the shopper
  /// is, and that second question is [homeTap]. Every other slot is unchanged.
  static ShellTabTap tapOn(int page) => switch (page) {
        ShellPage.storefront => ShellTabTap.homeRoot,
        ShellPage.catalogue => ShellTabTap.catalogueRoot,
        _ => ShellTabTap.showPage,
      };

  /// CMD #2037 — the Home TAB's own ladder, one rung per tap.
  ///
  /// Pure, like [back], and for the same reason: Flutter web renders to
  /// canvas, so the only proof of this rule available to us is a VM test over
  /// the decision itself.
  static ShellHomeTap homeTap(ShellNavState state) {
    if (state.page != ShellPage.storefront) return ShellHomeTap.resumeStorefront;
    if (!state.isHomeRoot) return ShellHomeTap.backToFeed;
    return ShellHomeTap.scrollTop;
  }

  /// The back ladder. One step per press, never two.
  static ShellBack back(ShellNavState state) {
    if (state.cartOpen) return ShellBack.closeCart;
    return state.isHomeRoot ? ShellBack.exit : ShellBack.goHome;
  }

  /// True when the system may pop the shell's route — i.e. leave the app.
  static bool canPop(ShellNavState state) => back(state) == ShellBack.exit;
}

/// CMD #2021 — the one "go to the storefront home root" signal.
///
/// A product page and a company page are real routes (CHANGE #636 / #638)
/// pushed ABOVE the shell in the same Navigator, so the bar is not on screen
/// there and those screens cannot reach the shell's state directly. They pop
/// back to the shell and fire this; the shell listens and goes home. Same
/// arrangement as `ShopBadge` / `CustomerNav` — a notifier the shell listens
/// to, rather than a new argument threaded through every route.
class ShellHomeSignal {
  const ShellHomeSignal._();

  static final ValueNotifier<int> value = ValueNotifier<int>(0);

  /// Pop every pushed route back to the shell, then ask it to go home.
  ///
  /// Both halves are needed and in this order: popping alone leaves the shell
  /// on whatever list the product page was opened from, and signalling alone
  /// would reset a shell the shopper cannot see.
  static void goHome(BuildContext context) {
    final nav = Navigator.maybeOf(context);
    if (nav != null && nav.canPop()) {
      nav.popUntil((route) => route.isFirst);
    }
    value.value++;
  }
}
