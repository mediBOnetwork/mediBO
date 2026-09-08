import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/payload_cache.dart';

/// CMD #1813 — the two widgets that make "no blank screen, ever" structural
/// rather than a promise each screen has to keep on its own.
///
/// [PayloadStatusLine] prints the one quiet backend sentence.
/// [NeverBlankBody] decides between the body and the skeleton, and there is no
/// third branch: an error has no branch of its own, because an error must not
/// take the body away.

/// A hairline strip: a small spinner and one backend sentence, nothing else.
///
/// Renders NOTHING when the state has nothing to say — the normal case for a
/// payload that arrived on time.
class PayloadStatusLine extends StatelessWidget {
  const PayloadStatusLine({super.key, required this.state});

  /// Null means "this screen is not on the never-blank controller at all"
  /// (a test seam, or a surface that supplies its own payload) — draw nothing
  /// rather than an eternal spinner over content that has already arrived.
  final PayloadState? state;

  @override
  Widget build(BuildContext context) {
    final state = this.state;
    if (state == null || !state.showStatusLine) return const SizedBox.shrink();
    final line = state.statusLine;
    // A failing refresh is amber, a normal refresh is just quiet grey. Nothing
    // here is red: the customer still has a working screen.
    final tone = state.failures > 0 ? Ds.c.warning : Ds.c.textSecondary;
    return Container(
      width: double.infinity,
      color: state.failures > 0 ? Ds.c.warningSoft : Ds.c.bg,
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x16,
        vertical: Ds.space.x8,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: Ds.space.x12,
            height: Ds.space.x12,
            child: CircularProgressIndicator(strokeWidth: 2, color: tone),
          ),
          SizedBox(width: Ds.space.x8),
          Flexible(
            child: Text(
              line,
              style: Ds.t.caption.copyWith(color: tone),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws [builder] over the last good payload, with [PayloadStatusLine] above
/// it, and falls back to [skeleton] only when this device has never held a
/// payload for this screen.
///
/// There is no error branch and no Retry button by construction. A failed
/// refresh changes the status line and nothing else; the controller is already
/// retrying on the backend's own schedule.
class NeverBlankBody extends StatelessWidget {
  const NeverBlankBody({
    super.key,
    required this.state,
    required this.builder,
    required this.skeleton,
  });

  final PayloadState state;
  final Widget Function(BuildContext, Map<String, dynamic>) builder;
  final Widget skeleton;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PayloadStatusLine(state: state),
        Flexible(
          child: state.hasBody ? builder(context, state.data!) : skeleton,
        ),
      ],
    );
  }
}

/// Convenience: rebuilds [child] whenever the controller moves.
class PayloadBuilder extends StatelessWidget {
  const PayloadBuilder({
    super.key,
    required this.controller,
    required this.builder,
    required this.skeleton,
  });

  final PayloadController controller;
  final Widget Function(BuildContext, Map<String, dynamic>) builder;
  final Widget skeleton;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (ctx, _) => NeverBlankBody(
        state: controller.state,
        builder: builder,
        skeleton: skeleton,
      ),
    );
  }
}
