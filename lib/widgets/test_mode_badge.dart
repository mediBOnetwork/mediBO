import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/test_session.dart';

/// CMD #1964 — the TEST badge that stands in the APP HEADER.
///
/// #573's strip sits above every route and says, at full width, that nothing
/// here is real. This is the other half of that signal: once a session is on,
/// the reads underneath it are a different world — a customer sees only the
/// synthetic orders, a real session sees only the real ones — and the header
/// is the one piece of chrome on screen in every route of every role, next to
/// the logo, where "which world am I in" belongs.
///
/// THE APP RENDERS. IT NEVER DECIDES. Everything here is
/// `test_session_banner()`'s answer, verbatim: `on` is the only gate — there is
/// no local rule about when a session counts — `badge` is the word and
/// `badge_hint` is the long-press line. No copy is written in Dart, so a `TEST`
/// that should read `DEMO` is an UPDATE to `ui_copy`, not a deploy.
///
/// MOBILE-FIRST. The mobile header centres its logo against the header itself
/// and holds the avatar and the cart outside that centre, so a badge that
/// measured freely could push the logo off centre or collide with it. The pill
/// renders inside whatever width its parent gives it and CLIPS — never wraps,
/// never overflows — so 320px degrades to a narrower pill rather than to a
/// yellow-and-black stripe.
class TestModeBadge extends StatelessWidget {
  const TestModeBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: TestSessionState.instance.banner,
      builder: (context, payload, _) {
        if (payload['on'] != true) return const SizedBox.shrink();
        final label = _s(payload, 'badge');
        if (label.isEmpty) return const SizedBox.shrink();
        return _pill(label, _s(payload, 'badge_hint'));
      },
    );
  }

  Widget _pill(String label, String hint) {
    final chip = Container(
      // Every call site is "after something, in a header" — the avatar on the
      // phone, the logo lock-up on the two desktop headers — so the gap is the
      // badge's own and it disappears with the badge instead of leaving a hole.
      margin: EdgeInsets.only(left: Ds.space.x8),
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x8,
        vertical: Ds.space.x4,
      ),
      decoration: BoxDecoration(
        color: Ds.c.dangerSoft,
        borderRadius: Ds.r.rChip,
        border: Border.all(color: Ds.c.danger, width: Ds.space.hairline),
      ),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: Ds.t.caption.copyWith(
          color: Ds.c.danger,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
    // The hint is the backend's sentence; an absent one means no tooltip at
    // all rather than an empty bubble.
    if (hint.isEmpty) return Semantics(label: label, child: chip);
    return Tooltip(
      message: hint,
      child: Semantics(label: '$label. $hint', child: chip),
    );
  }

  static String _s(Map<String, dynamic> p, String k) {
    final v = p[k];
    return v is String ? v : (v == null ? '' : '$v');
  }
}
