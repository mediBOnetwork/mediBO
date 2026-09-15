/// The shell's path ↔ tab table, and the URL helpers that go with it.
///
/// CHANGE #340 left `home_shell.dart` carrying exactly ONE concern —
/// boot/routing — and the god-file guard holds it under 2,000 lines. Every
/// deep-linked tab used to cost the shell a chained `if` in each of its two
/// readers (`_initFromUrl`, `_applyPath`) plus one in the writer, so the
/// third tab added to it (#1892, `/admin/dashboard`) was the one that pushed
/// the file over. The table lives here instead: a new deep-linked tab is now
/// one map entry, and the shell reads it in all three places.
///
/// Pure Dart, no widgets, no strings a user ever sees — every label the app
/// prints still comes from the backend.
class ShellRoutes {
  const ShellRoutes._();

  /// Paths that select a tab in the shell's IndexedStack and change nothing
  /// else. Order-deep-links, `/c/<slug>` and the catalogue carry arguments,
  /// so they stay in the shell where the argument is applied.
  static const tabs = <String, int>{
    '/orders': 1,
    '/bulk-upload': 2,
    '/admin/dashboard': 3, // #1892 — the dashboard home screen
  };

  /// The tab a path selects, or null when the path is not one of ours.
  static int? indexFor(String path) => tabs[path];

  /// The canonical path for a tab, or null when the tab has no URL of its own.
  static String? pathFor(int index) {
    for (final e in tabs.entries) {
      if (e.value == index) return e.key;
    }
    return null;
  }

  static String catToSlug(String cat) => cat.toLowerCase().replaceAll(' ', '-');

  static String slugToCat(String slug) =>
      slug.toUpperCase().replaceAll('-', ' ');

  /// The URL that represents the shell's current state.
  static String urlForState(int index, String category) {
    final tab = pathFor(index);
    if (tab != null) return tab;
    if (index == 12) return '/catalogue';
    if (category != 'All') return '/c/${catToSlug(category)}';
    return '/';
  }
}
