import 'dart:async';

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/payload_cache.dart';
import '../services/ui_copy.dart';

/// CMD #1813 — the two widgets that make "no blank screen, ever" structural
/// rather than a promise each screen has to keep on its own.
///
/// [PayloadStatusLine] prints the one quiet backend sentence.
/// [NeverBlankBody] decides between the body and the skeleton, and there is no
/// third branch: an error has no branch of its own, because an error must not
/// take the body away.

/// CMD #2156 (Om) — the ONE connection message on a customer screen: a small
/// pill under the search bar (design "slow internet"), never a full-width
/// strip and never red. Amber while a refresh is failing, quiet grey while a
/// first load or a slow refresh is still going, and green `net.back_online`
/// for [backOnlineFor] the moment a failing refresh lands. Every word is the
/// backend's ([PayloadState.statusLine] / ui_copy).
///
/// It is drawn OVER the content by [PayloadStatusOverlay], so appearing and
/// disappearing never moves the page (no layout jump). Renders NOTHING when the
/// state has nothing to say — the normal case for a payload that arrived on
/// time.
class PayloadStatusLine extends StatefulWidget {
  const PayloadStatusLine({super.key, required this.state});

  /// Null means "this screen is not on the never-blank controller at all"
  /// (a test seam, or a surface that supplies its own payload) — draw nothing
  /// rather than an eternal spinner over content that has already arrived.
  final PayloadState? state;

  static const Duration backOnlineFor = Duration(seconds: 2);

  @override
  State<PayloadStatusLine> createState() => _PayloadStatusLineState();
}

class _PayloadStatusLineState extends State<PayloadStatusLine> {
  bool _backOnline = false;
  Timer? _timer;

  @override
  void didUpdateWidget(PayloadStatusLine old) {
    super.didUpdateWidget(old);
    final was = old.state?.failures ?? 0;
    final now = widget.state?.failures ?? 0;
    // A failing refresh just landed: say so, briefly, then fall silent.
    if (was > 0 && now == 0 && widget.state?.hasBody == true) {
      _timer?.cancel();
      _backOnline = true;
      _timer = Timer(PayloadStatusLine.backOnlineFor, () {
        if (mounted) setState(() => _backOnline = false);
      });
    } else if (now > 0) {
      _backOnline = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final back = _backOnline && UiCopy.t('net.back_online').isNotEmpty;
    if (!back && (state == null || !state.showStatusLine)) {
      return const SizedBox.shrink();
    }
    final failing = !back && state!.failures > 0;
    final line = back ? UiCopy.t('net.back_online') : state!.statusLine;
    final Color fg = back
        ? Ds.c.success
        : failing
            ? Ds.c.warning
            : Ds.c.textSecondary;
    final Color bg = back
        ? Ds.c.successSoft
        : failing
            ? Ds.c.warningSoft
            : Ds.c.bg;
    return Semantics(
      identifier: 'c2156_net_pill',
      liveRegion: true,
      // The pill's ground is the Container's own colour (a token), clipped
      // round; the hairline and the soft shadow ride the box around it.
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: Ds.r.rChip,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: ClipRRect(
        borderRadius: Ds.r.rChip,
        child: Container(
        color: bg,
        padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12,
          vertical: Ds.space.x4 + Ds.space.x4 / 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            back
                ? Icon(Icons.check_circle, size: Ds.space.x12, color: fg)
                : SizedBox(
                    width: Ds.space.x12,
                    height: Ds.space.x12,
                    child: CircularProgressIndicator(strokeWidth: 2, color: fg),
                  ),
            SizedBox(width: Ds.space.x8),
            Flexible(
              child: Text(
                line,
                maxLines: 1,
                style: Ds.t.caption.copyWith(color: fg, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      ),
      ),
    );
  }
}

/// CMD #2156 — lays [PayloadStatusLine] OVER [child], centred just under the
/// top edge (the search bar sits right above it), so the content keeps its
/// place whether the pill is showing or not.
class PayloadStatusOverlay extends StatelessWidget {
  const PayloadStatusOverlay({super.key, required this.state, required this.child});

  final PayloadState? state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          top: Ds.space.x8,
          left: Ds.space.x16,
          right: Ds.space.x16,
          child: IgnorePointer(
            child: Center(child: PayloadStatusLine(state: state)),
          ),
        ),
      ],
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
    return PayloadStatusOverlay(
      state: state,
      child: state.hasBody ? builder(context, state.data!) : skeleton,
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
