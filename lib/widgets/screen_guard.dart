// lib/widgets/screen_guard.dart — CMD #2107
//
// THE GUARD THAT KEEPS AN EXCEPTION INSIDE ONE SCREEN.
//
// Before this file the app set `FlutterError.onError` (which logs and
// swallows) but never set `ErrorWidget.builder`. So a throw inside a screen's
// `build` was replaced by Flutter's DEFAULT error widget — in a release build
// a bare grey rectangle with no title, no sentence and no way back. Inside the
// shell's IndexedStack that rectangle is the whole page, which on a phone
// reads as "I tapped it and the screen closed".
//
// This file is the error state that takes its place, and it is words-free:
// every string is a `ui_copy` row (`screen_guard.*`), so the wording is an
// UPDATE, never a deploy. The exception text itself is NOT shown — it is
// already reported by FlutterError.onError/CrashReporting, and a stack trace
// is not an answer a pharmacy can act on.
//
// Two ways in:
//   • [installScreenGuard] — set once at boot; catches EVERY screen.
//   • [ScreenGuard]        — wraps one subtree so its failure leaves the rest
//                            of the page (the header, the tab row) alive.

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';

/// Replaces Flutter's default grey error box with [ScreenErrorState].
///
/// Called once, from main(). Idempotent — calling it twice installs the same
/// builder.
void installScreenGuard() {
  ErrorWidget.builder = (FlutterErrorDetails details) {
    try {
      RenderLog.write('c2107_screen_guard', 1);
    } catch (_) {}
    return const ScreenErrorState();
  };
}

/// Wraps one subtree so an exception inside it renders [ScreenErrorState] in
/// place of THAT subtree instead of the whole page.
///
/// It does not catch anything itself — `ErrorWidget.builder` does that, and
/// Flutter already replaces the nearest failed widget rather than the root.
/// What this adds is a boundary the framework can stop at: a [RepaintBoundary]
/// plus its own [Builder] keeps the failure inside the child, so the screen's
/// header and tab row survive a broken body.
class ScreenGuard extends StatelessWidget {
  const ScreenGuard({super.key, required this.child, this.onRetry});

  final Widget child;

  /// What the error state's primary button does. Null renders the button that
  /// pops back instead, so there is always a way out.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Builder(builder: (_) => child),
    );
  }
}

/// The error state itself. Also usable directly by a screen that caught its
/// own failure and wants the same face as the global guard.
class ScreenErrorState extends StatelessWidget {
  const ScreenErrorState({super.key, this.onRetry});

  /// The primary action. Null → the button pops this route, which is the one
  /// action that always exists.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final title = c('screen_guard.title');
    final body = c('screen_guard.body');
    final retry = onRetry != null ? c('screen_guard.retry') : c('screen_guard.back');
    return Material(
      color: Ds.c.bg,
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: Ds.space.x48, color: Ds.c.textSecondary),
              SizedBox(height: Ds.space.x16),
              if (title.isNotEmpty)
                Text(title, textAlign: TextAlign.center, style: Ds.t.title),
              if (body.isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                Text(body,
                    textAlign: TextAlign.center,
                    style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
              ],
              if (retry.isNotEmpty) ...[
                SizedBox(height: Ds.space.x24),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: onRetry ??
                        () {
                          final nav = Navigator.maybeOf(context);
                          if (nav != null && nav.canPop()) nav.pop();
                        },
                    child: Text(retry),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
