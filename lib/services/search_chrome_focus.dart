import 'package:flutter/foundation.dart';

/// CMD #2117 §3 — "while the keyboard is open, hide the bottom banner and the
/// View cart pill".
///
/// The search box is the one control that opens the keyboard on the storefront,
/// so ITS focus is the signal — not `MediaQuery.viewInsets`, which on Flutter
/// web is answered by the browser's visual viewport and reads 0 on exactly the
/// phones this is for.
///
/// It is one global [ValueNotifier] rather than an InheritedWidget because the
/// two ends stand in different subtrees: the box lives in the shell's header
/// and the chrome lives at the bottom of the shell's Stack (and, on a pushed
/// route, in a different Navigator entirely). A notifier is also what
/// `CustomerNav` and `appUpdateBar` already are, so the bottom stack listens to
/// it the same way it listens to everything else.
///
/// WHETHER focus hides the chrome is the BACKEND's answer
/// (`search_bar_block().hide_bottom_chrome_on_focus`): the surface only reports
/// what it observed, and reports `false` the moment the backend says not to.
class SearchChromeFocus {
  const SearchChromeFocus._();

  /// True while the search box has focus AND the backend asked for the chrome
  /// to stand down.
  static final ValueNotifier<bool> suppressed = ValueNotifier<bool>(false);

  /// Called by the search surface on every focus change and on every payload.
  static void report({required bool focused, required bool backendWantsHide}) {
    final next = focused && backendWantsHide;
    if (suppressed.value != next) suppressed.value = next;
  }

  /// A surface leaving the tree must not leave the chrome hidden behind it.
  static void release() {
    if (suppressed.value) suppressed.value = false;
  }
}
