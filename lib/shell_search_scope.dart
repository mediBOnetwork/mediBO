import 'package:flutter/foundation.dart';

/// CMD #2175 — the shell's per-tab search, published to the screen that
/// answers it.
///
/// Om: "Search per tab — the backend gives scope + placeholder." The shell
/// draws ONE search bar on every customer tab and the backend's `scope` string
/// says which surface answers what is typed. The bar and the surface are in
/// different libraries (the shell is one `part` family, the Orders and Profile
/// tabs are their own screens), so the seam between them is this: a notifier
/// per scope, written by the bar and listened to by the screen.
///
/// It is a notifier rather than a callback passed down the tree because a tab
/// is an `IndexedStack` child that is ALIVE while another tab is on screen —
/// there is no build of Orders happening at the moment Orders' own query is
/// typed. A listener repaints exactly the list that changed and nothing else.
///
/// The scope strings are the backend's (`shell_style().search.tabs.*.scope`);
/// nothing here invents one.
final Map<String, ValueNotifier<String>> _scopes =
    <String, ValueNotifier<String>>{};

ValueNotifier<String> shellScopeQuery(String scope) =>
    _scopes[scope] ??= ValueNotifier<String>('');
