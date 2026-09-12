// CHANGE #286 — the slim, Plazza-style update bar.
//
// WHAT THIS REPLACES
// The web update prompt used to be a MaterialBanner, which Flutter pins to the
// TOP of the scaffold and which PUSHES the whole app down while it is showing.
// With a circular badge, a heading, a sub-line and a full-width filled button
// it ate roughly half a phone screen (see the #286 reference shot) before the
// user had even seen the header.
//
// WHAT THIS IS
// One compact bar pinned just above the bottom nav, exactly like Plazza's:
//
//   ( ⭮ )  App update available                     [ Update Now ]
//
//   • round chip on the left, brand-tinted, one update glyph
//   • ONE line of copy — no sub-line, no paragraph
//   • one compact fully-rounded pill on the right
//
// It is an OVERLAY, never part of the page: it reflows nothing, it covers only
// its own rectangle, and every pixel outside that rectangle keeps taking taps.
//
// ZERO STYLE LITERALS. Every colour, size, radius, gap, shadow and duration is
// read from the `Ds` token layer (backend `ui_design`), and both strings come
// from `ui_copy`. Restyling or rewording this bar is an UPDATE, never a deploy.

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';

/// Render-log key proving the bar actually painted in the live build.
const String kUpdateBarRenderKey = 'c286_update_bar';

/// The one piece of state the bar needs, held outside the widget tree so
/// [VersionWatcher] (a plain service) can raise the bar from anywhere without
/// a BuildContext — the same reason the old code needed a messenger key.
class UpdateBarController extends ChangeNotifier {
  bool _visible = false;
  bool _updating = false;
  VoidCallback? _onUpdate;

  bool get visible => _visible;

  /// True from the moment the user taps (or the auto-reload fires) until the
  /// page actually swaps. The pill shows the updating label and stops
  /// accepting taps — one reload, never three.
  bool get updating => _updating;

  VoidCallback? get onUpdate => _onUpdate;

  /// Raise the bar. [onUpdate] is the same action the old banner's button ran.
  void show({required VoidCallback onUpdate}) {
    _onUpdate = onUpdate;
    if (_visible) return;
    _visible = true;
    notifyListeners();
  }

  /// Latch into the updating state. Idempotent, so the user tapping while the
  /// 6 s auto-reload is already running changes nothing.
  void markUpdating() {
    if (_updating) return;
    _updating = true;
    notifyListeners();
  }

  /// Test seam — the controller is a long-lived singleton in production.
  @visibleForTesting
  void reset() {
    _visible = false;
    _updating = false;
    _onUpdate = null;
    notifyListeners();
  }
}

/// Wraps the whole app (from `MaterialApp.builder`) and parks the bar at the
/// bottom of the screen on top of everything else — above the bottom nav, above
/// a floating cart pill, above any sheet backdrop.
class UpdateBarHost extends StatelessWidget {
  const UpdateBarHost({super.key, required this.controller, required this.child});

  final UpdateBarController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.visible) return child;
        // The Stack's only extra child is the bar itself, so nothing outside
        // the bar's own rectangle can swallow a tap.
        return Stack(
          children: [
            child,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: UpdateBar(
                title: c('update_bar.title'),
                actionLabel: c('update_bar.action'),
                updatingLabel: c('update_bar.updating'),
                updating: controller.updating,
                onUpdate: controller.onUpdate ?? () {},
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The bar itself — pure presentation, so a widget test can mount it with
/// fixture copy and no network, no timers and no service singleton.
class UpdateBar extends StatefulWidget {
  const UpdateBar({
    super.key,
    required this.title,
    required this.actionLabel,
    required this.updatingLabel,
    required this.updating,
    required this.onUpdate,
  });

  final String title;
  final String actionLabel;
  final String updatingLabel;
  final bool updating;
  final VoidCallback onUpdate;

  @override
  State<UpdateBar> createState() => _UpdateBarState();
}

class _UpdateBarState extends State<UpdateBar> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: Ds.motion.sheet)..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    try {
      RenderLog.write(kUpdateBarRenderKey,
          'variant:bottom_slim;updating:${widget.updating}');
    } catch (_) {}

    // Safe-area aware: the system inset keeps the bar off the gesture bar, and
    // the backend's bottomBarGap lifts it clear of the bottom nav.
    final bottomInset =
        MediaQuery.of(context).viewPadding.bottom + Ds.touch.bottomBarGap;

    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
          .animate(CurvedAnimation(parent: _ctrl, curve: Ds.motion.curve)),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Material(
          color: Ds.c.surface,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Ds.c.surface,
              border: Border(top: BorderSide(color: Ds.c.divider)),
              boxShadow: Ds.elevation.e1,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16, vertical: Ds.space.x12),
              // MOBILE FIRST (Om, #282): 99% of pharmacies open mediBO on a
              // phone. At 360 px the old x12/x12 gaps plus the x16 pill padding
              // left the line ~77 px of slot for a ~145 px sentence, so the bar
              // read "App u…" — the exact opposite of clean. The chrome now
              // gives way before the sentence does: x8 gaps here, x12 inside
              // the pill, and the copy itself is short phone copy from ui_copy.
              child: Row(
                children: [
                  _chip(),
                  SizedBox(width: Ds.space.x8),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Ds.t.bodyStrong,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                  _action(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chip() => Container(
        width: Ds.touch.minTarget,
        height: Ds.touch.minTarget,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: Ds.c.brandSoft, shape: BoxShape.circle),
        child: Icon(Icons.system_update_alt_rounded,
            color: Ds.c.brand, size: Ds.t.subtitleSize),
      );

  Widget _action() => FilledButton(
        onPressed: widget.updating ? null : widget.onUpdate,
        style: FilledButton.styleFrom(
          backgroundColor: Ds.c.brand,
          foregroundColor: Ds.c.surface,
          disabledBackgroundColor: Ds.c.brandDark,
          disabledForegroundColor: Ds.c.surface,
          minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
          shape: const StadiumBorder(),
          visualDensity: VisualDensity.standard,
        ),
        child: Text(
          widget.updating ? widget.updatingLabel : widget.actionLabel,
          style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface),
          maxLines: 1,
        ),
      );
}
