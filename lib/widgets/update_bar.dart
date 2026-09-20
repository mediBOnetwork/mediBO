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
//     (CMD #2065 added a Later and a 24 h hide; CMD #2112 removed both again.
//     An update a shop can postpone for a day reaches it a day late, and this
//     slot is now shared with the registration bar, where a dismissed pill
//     would have read as "nothing owed".)
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
  ///
  /// CMD #2112 — there is no `onDismiss` any more. The pill stays up until the
  /// update lands, so the only control on it is Update Now.
  void show({
    required VoidCallback onUpdate,
    Map<String, dynamic>? payload,
  }) {
    _onUpdate = onUpdate;
    if (payload != null) _payload = payload;
    if (_visible) {
      notifyListeners();
      return;
    }
    _visible = true;
    notifyListeners();
  }

  /// Take the bar down — the update landed, or the driver decided there is no
  /// update after all. Never a user control (CMD #2112).
  void hide() {
    if (!_visible) return;
    _visible = false;
    _updating = false;
    _downloaded = false;
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

  // ── CMD #2051 — the copy, resolved ONCE ────────────────────────────────
  //
  // The payload is the source and ui_copy is the fallback for an unreachable
  // backend. That rule used to live inside the host, which meant the bottom
  // stack would have had to repeat it — two places deciding one sentence is
  // how a fallback starts showing on one surface only. It lives here, next to
  // the payload it resolves, and both renderers ask.

  /// Two payload names for one string: the RPC's (CMD #2065) and the one the
  /// pre-#2065 `app_update_bar()` alias still sends.
  String _s2(String key, String alt, String copyKey) {
    final v = _payload[key];
    if (v is String && v.isNotEmpty) return v;
    final w = _payload[alt];
    if (w is String && w.isNotEmpty) return w;
    return c(copyKey);
  }

  String _s(String key, String copyKey) {
    final v = _payload[key];
    if (v is String && v.isNotEmpty) return v;
    return c(copyKey);
  }

  /// The one line of copy in the middle of the bar.
  String get label => _s2('title', 'label', 'update_bar.title');

  /// The word on the green button.
  String get actionLabel => _s2('cta', 'button_label', 'update_bar.action');

  /// The backend's forced flag, rendered as "no way out but updating".
  bool get forced => _payload['forced'] == true;

  /// What the button says once the update is running.
  String get updatingLabel => _s('updating_label', 'update_bar.updating');

  /// Android flexible flow: what it says while Play restarts the app.
  String get downloadedLabel => _s('downloaded_label', 'update_bar.updating');

  // CMD #2066 — `bottom_gap` is no longer read, and the bar has no offset of
  // any kind. An offset was how the bar was kept clear of a bottom nav it was
  // painted OVER; it now sits IN a reserved slot on top of that nav, so "how
  // high does it float" has no answer to give. The payload key may keep
  // arriving — it is ignored, which is the only way "every position is static"
  // can be true of a number the backend can change.

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

// CMD #2066 — THE BAR HAS ONE HOME AND ONE HEIGHT.
//
// #2037 published a MEASURED height here (`appUpdateBarHeight`) because the
// bar was an overlay installed from `MaterialApp.builder` that nothing inside
// the app could see, and #2051 added a mount count (`bottomStackMounted`) so
// that overlay could stand down while the storefront's own column drew the
// bar. Both are gone: the bar renders in exactly one place — the update-bar
// slot of [StorefrontBottomStack] — and that slot is a fixed
// `Ds.touch.listRowMinHeight`, so there is no height for anyone to publish and
// no second renderer for anyone to count.


/// The ONE controller the app-level host renders. Both the web watcher and the
/// Android driver raise this same instance, which is what makes "same bar, same
/// look" true rather than a coincidence of two widgets.
final UpdateBarController appUpdateBar = UpdateBarController();

// The app-level host that used to wrap the whole app is deleted with #2066:
// wrapping everything is exactly how the bar reached login, the cart, the
// checkout and every pushed route — surfaces with no bottom nav for it to sit
// on. Where it renders is now the SHELL's answer (`bottomNavVisible`), asked
// by the one widget that draws it.

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
    this.fixedHeight,
    this.leading,
    this.actionIdentifier,
  });

  final String title;
  final String actionLabel;
  final String updatingLabel;

  /// Android flexible flow: shown while Play applies the download and restarts.
  final String? downloadedLabel;

  final bool updating;
  final bool downloaded;

  /// CMD #2066 — the exact height of the slot this bar was given, when it is
  /// in one. The stack reserves [BottomStackMetrics.slot] whether or not an
  /// update is pending, so the bar fills that box rather than sizing itself:
  /// a sentence that takes a second line at 360 px must not make the chrome
  /// taller and push the cart pill up. Null = size to content (no slot).
  final double? fixedHeight;

  final VoidCallback onUpdate;

  /// CMD #2112 — the glyph in the white circle on the left. The update bar
  /// draws a gear and the registration bar draws its own; everything else
  /// about the two pills — shape, size, colour, position, behaviour — is this
  /// one widget, which is what "the same banner" means.
  final IconData? leading;

  /// CMD #2114 — the semantics identifier on the button, so a browser journey
  /// can tap THIS bar's action rather than "the green button near the bottom".
  /// Null on the update bar, which no journey drives.
  final String? actionIdentifier;

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
    // CMD #2051/#2066 — FLUSH, full width, and no inset of its own. The bar is
    // the top surface of the bottom chrome; the stack it sits in owns the
    // bottom edge and whatever safe area is below it. An inset here as well
    // would show as a white seam between the bar and the nav.

    // One data row tall — the same 56 the pill above it is, so the two read as
    // one stack rather than two unrelated bits of chrome. CMD #2066: when the
    // bottom stack hands the bar a slot, that height is EXACT, not a minimum.
    final fixed = widget.fixedHeight;
    final minHeight = Ds.touch.listRowMinHeight;
    // A fixed slot has to fit a 44 px gear, a 44 px button and up to two lines
    // of the backend's sentence inside 56 px, so the breathing room is one
    // step of the scale rather than two. Sizing to content keeps the roomier
    // padding it always had.
    final vPad = fixed == null ? Ds.space.x8 : Ds.space.x4;

    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
          .animate(CurvedAnimation(parent: _ctrl, curve: Ds.motion.curve)),
      // CMD #2051 — edge to edge. The bar is not a floating card any more: it
      // is the top surface of the bottom chrome, so it spans the screen and
      // only its TOP corners are rounded.
      child: DecoratedBox(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius:
                BorderRadius.vertical(top: Radius.circular(Ds.r.card)),
            // CMD #2037 — a SOFT TOP shadow. Sitting on the nav, the card has
            // only one edge anything can see; e2 falls downwards, behind the
            // nav, which is why the card used to read as a flat white block.
            boxShadow: Ds.elevation.eUp,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: ConstrainedBox(
              constraints: fixed == null
                  ? BoxConstraints(minHeight: minHeight)
                  : BoxConstraints.tightFor(height: fixed),
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x16, vertical: vPad),
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
        child: Icon(widget.leading ?? Icons.settings_outlined,
            color: Ds.c.text, size: Ds.t.subtitleSize),
      );

  Widget _action() {
    final id = widget.actionIdentifier;
    final button = _button();
    if (id == null || id.isEmpty) return button;
    // A named node, so a journey taps the bar's own button by name. The child
    // keeps its own semantics (the backend's label is what a screen reader
    // reads); this only gives the node an address.
    return Semantics(identifier: id, container: true, child: button);
  }

  /// CMD #2116 — ONE RECTANGLE, WHATEVER THE WORD IS.
  ///
  /// The button used to be sized by its own label, so the login bar's `Login`
  /// drew a visibly narrower, differently-placed box than the registration
  /// bar's `Continue`: the same widget in the same slot, and the two bars
  /// still did not line up when a user saw them one after the other. A
  /// label-sized button also means the backend cannot reword a button without
  /// moving the chrome, which is the opposite of what a backend-owned string
  /// is for.
  ///
  /// The box is now [DsTouch.barActionWidth] x [DsTouch.minTarget] exactly —
  /// a token, so it is retunable with one `ui_design_set` and no deploy — and
  /// the word is centred inside it. A word too long for the box scales down
  /// (never ellipses, never widens): `Update Now`, `Continue`, `Login` and
  /// the updating label all print in the identical rectangle.
  Widget _button() => SizedBox(
        width: Ds.touch.barActionWidth,
        height: Ds.touch.minTarget,
        child: FilledButton(
          onPressed:
              (widget.updating || widget.downloaded) ? null : widget.onUpdate,
          style: FilledButton.styleFrom(
            backgroundColor: Ds.c.brand,
            foregroundColor: Ds.c.surface,
            disabledBackgroundColor: Ds.c.brandDark,
            disabledForegroundColor: Ds.c.surface,
            // The SizedBox is the size. Zero here so the button can neither
            // grow past the box for a long word nor sit smaller than it for a
            // short one.
            minimumSize: Size.zero,
            maximumSize: Size.infinite,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            // NOT x16: at 360 px the eight extra pixels come straight out of
            // the sentence's share of the row, and #2028's mobile-first rule
            // is that the CHROME gives way before the line does.
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
            // CMD #2037 — a rounded RECTANGLE, not a stadium: the same corner
            // every primary button in the app wears.
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            visualDensity: VisualDensity.standard,
          ),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              _label,
              style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface),
              maxLines: 1,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}
