// CHANGE #286 → CMD #2028 — the floating update pill.
//
// WHAT THIS IS
// One white pill that floats clear of the bottom nav AND of the floating cart
// pill, on every screen, until the app is updated:
//
//   ┌─────────────────────────────────────────────────┐
//   │  (⚙)   App update available      [ Update Now ] │
//   └─────────────────────────────────────────────────┘
//
//   • gear glyph in a white, shadowed circle on the left
//   • one dark line of copy in the middle
//   • one solid brand-green pill button on the right
//   • no Later, no dismiss, no version text — it stays until the update lands
//
// It is an OVERLAY, installed once from `MaterialApp.builder`: it reflows
// nothing, it covers only its own rectangle, and every pixel outside that
// rectangle keeps taking taps. Both platforms raise the SAME bar — the web
// watcher (version.json) and the Android driver (Play in-app updates) differ
// only in what `Update Now` does.
//
// ZERO STYLE LITERALS AND ZERO DART COPY. Every colour, size, radius, gap,
// shadow and duration is read from the `Ds` token layer (backend `ui_design`),
// and the sentence, the button word, the two progress words and the float
// height all arrive in the `app_update_bar()` payload. Restyling, rewording or
// re-positioning this bar is an UPDATE, never a deploy.

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';

/// Render-log key proving the bar actually painted in the live build.
const String kUpdateBarRenderKey = 'c286_update_bar';

/// CMD #2028 — proof key for the floating variant, so the live render-log can
/// tell the #286 strip from this pill.
const String kUpdatePillRenderKey = 'c2028_update_pill';

/// The one piece of state the bar needs, held outside the widget tree so the
/// web watcher and the Android driver (both plain services) can raise the pill
/// from anywhere without a BuildContext.
class UpdateBarController extends ChangeNotifier {
  bool _visible = false;
  bool _updating = false;
  bool _downloaded = false;
  VoidCallback? _onUpdate;
  Map<String, dynamic> _payload = const {};

  bool get visible => _visible;

  /// True from the moment the user taps until the app actually swaps builds.
  /// The pill shows the updating label and stops accepting taps — one update,
  /// never three.
  bool get updating => _updating;

  /// Android flexible flow only: the bytes are on the device and Play is
  /// restarting the app. A separate word from "updating" because the wait is a
  /// different one, and both words come from the backend.
  bool get downloaded => _downloaded;

  VoidCallback? get onUpdate => _onUpdate;

  /// The last `app_update_bar()` payload. Every string the pill prints and the
  /// height it floats at are read out of here.
  Map<String, dynamic> get payload => _payload;

  /// Raise the pill with the payload that decided it.
  void show({required VoidCallback onUpdate, Map<String, dynamic>? payload}) {
    _onUpdate = onUpdate;
    if (payload != null) _payload = payload;
    if (_visible) {
      notifyListeners();
      return;
    }
    _visible = true;
    notifyListeners();
  }

  /// Latch into the updating state. Idempotent, so a second tap changes
  /// nothing.
  void markUpdating() {
    if (_updating) return;
    _updating = true;
    notifyListeners();
  }

  /// Android: Play finished downloading and is about to restart the app.
  void markDownloaded() {
    if (_downloaded) return;
    _downloaded = true;
    _updating = true;
    notifyListeners();
  }

  /// Play reported the download failed or the customer backed out. The pill
  /// goes back to offering the button — it never disappears, because the
  /// update is still pending.
  void markIdle() {
    if (!_updating && !_downloaded) return;
    _updating = false;
    _downloaded = false;
    notifyListeners();
  }

  /// Test seam — the controller is a long-lived singleton in production.
  @visibleForTesting
  void reset() {
    _visible = false;
    _updating = false;
    _downloaded = false;
    _onUpdate = null;
    _payload = const {};
    notifyListeners();
  }
}

/// CMD #2037 — how much of the bottom of the screen the update card is
/// currently covering, in logical pixels, or 0 when it is not showing.
///
/// The card is an OVERLAY installed from `MaterialApp.builder`, so nothing
/// inside the app can see it by looking at its own layout. Anything that has to
/// stay clear of it — the floating cart pill, a page's bottom padding — listens
/// to this instead of being told the number twice. It is MEASURED, not
/// computed: the sentence is allowed a second line at 360 px, so the card's
/// height is not a constant anyone may assume.
final ValueNotifier<double> appUpdateBarHeight = ValueNotifier<double>(0);

/// The ONE controller the app-level host renders. Both the web watcher and the
/// Android driver raise this same instance, which is what makes "same bar, same
/// look" true rather than a coincidence of two widgets.
final UpdateBarController appUpdateBar = UpdateBarController();

/// Wraps the whole app (from `MaterialApp.builder`) and parks the pill at the
/// bottom of the screen on top of everything else — above the bottom nav, above
/// the floating cart pill, above any sheet backdrop.
class UpdateBarHost extends StatelessWidget {
  const UpdateBarHost({super.key, required this.controller, required this.child});

  final UpdateBarController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.visible) {
          // CMD #2037 — nothing is covered while the card is down, and the
          // pill that lifts for it has to hear that too.
          if (appUpdateBarHeight.value != 0) {
            WidgetsBinding.instance.addPostFrameCallback(
                (_) => appUpdateBarHeight.value = 0);
          }
          return child;
        }
        final p = controller.payload;
        String s(String key, String copyKey) {
          final v = p[key];
          if (v is String && v.isNotEmpty) return v;
          return c(copyKey);
        }

        // The Stack's only extra child is the pill itself, so nothing outside
        // the pill's own rectangle can swallow a tap.
        return Stack(
          children: [
            child,
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: UpdateBar(
                title: s('label', 'update_bar.title'),
                actionLabel: s('button_label', 'update_bar.action'),
                updatingLabel: s('updating_label', 'update_bar.updating'),
                downloadedLabel: s('downloaded_label', 'update_bar.updating'),
                updating: controller.updating,
                downloaded: controller.downloaded,
                bottomGap: (p['bottom_gap'] as num?)?.toDouble(),
                onUpdate: controller.onUpdate ?? () {},
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The pill itself — pure presentation, so a widget test can mount it with
/// fixture copy and no network, no timers and no service singleton.
class UpdateBar extends StatefulWidget {
  const UpdateBar({
    super.key,
    required this.title,
    required this.actionLabel,
    required this.updatingLabel,
    required this.updating,
    required this.onUpdate,
    this.downloadedLabel,
    this.downloaded = false,
    this.bottomGap,
  });

  final String title;
  final String actionLabel;
  final String updatingLabel;

  /// Android flexible flow: shown while Play applies the download and restarts.
  final String? downloadedLabel;

  final bool updating;
  final bool downloaded;

  /// How far off the bottom of the screen the pill floats, from the backend, so
  /// clearing a taller bottom nav is an UPDATE. Null falls back to the design
  /// token (bottom nav height) plus one step of the spacing scale.
  final double? bottomGap;

  final VoidCallback onUpdate;

  @override
  State<UpdateBar> createState() => _UpdateBarState();
}

class _UpdateBarState extends State<UpdateBar> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: Ds.motion.sheet)..forward();

  /// CMD #2037 — the card's own box, so its height is MEASURED rather than
  /// assumed. At 360 px the sentence takes a second line and the card grows;
  /// anything clearing it has to clear what it actually is.
  final GlobalKey _cardKey = GlobalKey();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// Publish how much of the bottom of the screen the card covers, measured
  /// from the top of the bottom nav upwards: the card itself plus the step of
  /// air above it.
  void _publishHeight() {
    if (!mounted) return;
    final box = _cardKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final v = box.size.height + Ds.space.x8;
    if ((appUpdateBarHeight.value - v).abs() > 0.5) {
      appUpdateBarHeight.value = v;
    }
  }

  String get _label {
    if (widget.downloaded) {
      final d = widget.downloadedLabel;
      if (d != null && d.isNotEmpty) return d;
    }
    return widget.updating ? widget.updatingLabel : widget.actionLabel;
  }

  @override
  Widget build(BuildContext context) {
    try {
      RenderLog.write(kUpdateBarRenderKey,
          'variant:floating_pill;updating:${widget.updating}');
      RenderLog.write(kUpdatePillRenderKey, 1);
    } catch (_) {}
    WidgetsBinding.instance.addPostFrameCallback((_) => _publishHeight());

    // Safe-area aware: the system inset keeps the pill off the gesture bar, and
    // the backend's gap lifts it clear of the bottom nav AND the cart pill.
    // CMD #2037 — the card sits DIRECTLY ON the bottom nav: 0 gap. The float
    // height is the nav's own height and nothing more, so the two read as one
    // stack of chrome instead of a pill hovering in the middle of the page.
    // The number is still the backend's (`app_update_bar.bottom_gap`); the
    // token is only what an app with no payload yet falls back to.
    final gap = widget.bottomGap ?? Ds.touch.bottomBarGap;
    final bottomInset = MediaQuery.of(context).viewPadding.bottom + gap;

    // ~72 px tall, expressed in tokens: one data row plus one spacing step.
    final minHeight = Ds.touch.listRowMinHeight + Ds.space.x16;

    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
          .animate(CurvedAnimation(parent: _ctrl, curve: Ds.motion.curve)),
      child: Padding(
        // Full width minus one spacing step each side, so the card floats
        // rather than sitting on the edges.
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x8, Ds.space.x16, bottomInset),
        child: DecoratedBox(
          key: _cardKey,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rSheet,
            // CMD #2037 — a SOFT TOP shadow. Sitting on the nav, the card has
            // only one edge anything can see; e2 falls downwards, behind the
            // nav, which is why the card used to read as a flat white block.
            boxShadow: Ds.elevation.eUp,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: minHeight),
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8, vertical: Ds.space.x8),
                // MOBILE FIRST: at 360 px the sentence, the circle and the
                // button cannot all have their ideal width, so the CHROME
                // gives way and the sentence is allowed a second line — it is
                // never clipped to "App u…".
                child: Row(
                  children: [
                    _gear(),
                    SizedBox(width: Ds.space.x8),
                    Expanded(
                      child: Text(
                        widget.title,
                        style: Ds.t.bodyStrong.copyWith(color: Ds.c.text),
                        maxLines: 2,
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
      ),
    );
  }

  /// The gear, in its own white shadowed circle.
  Widget _gear() => Container(
        width: Ds.touch.minTarget,
        height: Ds.touch.minTarget,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Ds.c.surface,
          shape: BoxShape.circle,
          boxShadow: Ds.elevation.e1,
        ),
        // CMD #2037 — the OUTLINE gear. The filled glyph read as a heavy dot
        // next to one line of text.
        child: Icon(Icons.settings_outlined,
            color: Ds.c.text, size: Ds.t.subtitleSize),
      );

  Widget _action() => FilledButton(
        onPressed: (widget.updating || widget.downloaded) ? null : widget.onUpdate,
        style: FilledButton.styleFrom(
          backgroundColor: Ds.c.brand,
          foregroundColor: Ds.c.surface,
          disabledBackgroundColor: Ds.c.brandDark,
          disabledForegroundColor: Ds.c.surface,
          minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          // CMD #2037 — a rounded RECTANGLE, not a stadium: the same corner
          // every primary button in the app wears.
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          visualDensity: VisualDensity.standard,
        ),
        child: Text(
          _label,
          style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface),
          maxLines: 1,
        ),
      );
}
