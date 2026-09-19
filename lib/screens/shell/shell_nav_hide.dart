part of '../home_shell.dart';

// CMD #2080 — the bottom nav hides on the way down and comes back on the way
// up, exactly as the header band does.
//
// WHY THERE IS NO SECOND DRIVER
// The obvious build is a second `NotificationListener` with its own direction
// verdict. That is the build #2019 → #2030 → #2038 → #2052 spent four commands
// undoing for the header: a scroll-linked piece of chrome that reads the
// OFFSET flashes back every time the list re-measures, and two of them reading
// it separately also drift apart from each other. So the nav is not driven at
// all. It reads [shellNavHide] — the header driver's own travel, published as
// a fraction of the band's height — which means:
//
//   · SAME FINGER. Only `dragDetails` moves it. A fling coasting, a page of
//     products arriving, a grid re-measuring, a `jumpTo`: zero pixels, for the
//     same reason the header takes zero.
//   · SAME TIMING. The settle is `Ds.touch.headerSettleMs` on the same
//     `AnimationController`, writing the same number. There is no second curve
//     to keep equal to the first one.
//   · SAME HYSTERESIS. A reversal earns its turn over
//     `Ds.touch.headerHysteresis` of deliberate travel, once, for both.
//   · SAME FLOOR. At the top of a page the accumulator is pinned to 0, so the
//     bar is always fully out at rest.
//   · SAME SHORT-LIST RULE. A page with less to scroll than the band is tall
//     can lose neither piece of chrome.
//
// HOW IT HIDES — THE SLOT SHRINKS, IT DOES NOT SLIDE OVER ANYTHING
// The bar is a `Scaffold.bottomNavigationBar`, so the body ends exactly where
// the bar begins, and [StorefrontBottomStack] is mounted at `bottom: 0` of
// that body — flush on the bar by layout rather than by a number two widgets
// keep equal (#2066). That is the whole reason this shortens the SLOT instead
// of translating the bar: shorten it and the body grows by the same pixels in
// the same frame, so the cart pill and the update-bar slot ride down on the
// bar's own top edge. No gap opens under the pill, nothing is painted over,
// and — unlike a `Transform` out of the body — every one of them is still
// where the finger can reach it, because the visible rectangle and the
// hit-test rectangle are the same rectangle.
//
// The bar itself is laid out at its FULL height and painted from the top of
// the shrunken slot, so what is on screen is its top slice: the bar travels
// down off the bottom of the glass rather than being cropped in place.
//
// KEYBOARD OPEN NEVER HIDES IT. That read lives in [_NavHideBox] and nowhere
// else, so a keyboard opening rebuilds the bar and not the shell around it.

/// The `ui_copy` key that turns the behaviour on. Backend-owned and default
/// on: wording is not the only thing that should be an UPDATE rather than a
/// deploy.
const String kNavHideOnScrollKey = 'shell.nav_hide_on_scroll';

/// Is the shell allowed to hide its bottom nav on scroll?
bool get shellNavHideEnabled => UiCopy.flag(kNavHideOnScrollKey);

/// Wraps the customer bottom bar so it can ride the same scroll the header
/// does. [enabled] is the shell's verdict — customer chrome only, so the staff
/// and supplier shells pass false and get the bar they already had.
Widget shellHidingNav(Widget nav, {required bool enabled}) =>
    enabled ? _NavHideBox(child: nav) : nav;

/// Reads the one thing that must override the finger, and nothing else.
///
/// A `MediaQuery` dependency registered up in `_buildMobile` would rebuild the
/// whole shell — the `IndexedStack` included — every time a search field took
/// focus. Registered here it rebuilds one bar.
class _NavHideBox extends StatelessWidget {
  const _NavHideBox({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The keyboard is up: the bar stays out, whatever the last drag asked for.
    // A page whose field is focused is a page being typed into, not scrolled.
    final bool frozen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return _NavSlot(frozen: frozen, child: child);
  }
}

/// CMD #2080 — a render object, for #2038's reason.
///
/// The travel is a number on a notifier this object reads for itself, so a
/// dragged frame and a settling frame both cost one layout of a bar that is
/// laid out with the very same constraints every time — never a rebuild of the
/// bar, and never a rebuild of the shell that owns it.
class _NavSlot extends SingleChildRenderObjectWidget {
  const _NavSlot({required this.frozen, required Widget child})
      : super(child: child);

  final bool frozen;

  @override
  _RenderNavSlot createRenderObject(BuildContext context) {
    RenderLog.write('c2080_nav', 1);
    return _RenderNavSlot(shellNavHide, frozen);
  }

  @override
  void updateRenderObject(BuildContext context, _RenderNavSlot renderObject) {
    renderObject.frozen = frozen;
  }
}

class _RenderNavSlot extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _RenderNavSlot(this._hidden, this._frozen);

  final ValueListenable<double> _hidden;

  /// How much of the bar is gone, 0..1, as the driver last published it.
  double _t = 0;

  bool _frozen;

  set frozen(bool v) {
    if (_frozen == v) return;
    _frozen = v;
    markNeedsLayout();
  }

  /// What this frame actually draws. The keyboard wins over the finger.
  double get _gone => _frozen ? 0 : _t;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _t = _read();
    _hidden.addListener(_onHide);
  }

  @override
  void detach() {
    _hidden.removeListener(_onHide);
    super.detach();
  }

  double _read() {
    final double v = _hidden.value;
    if (!v.isFinite || v <= 0) return 0;
    return v > 1 ? 1 : v;
  }

  void _onHide() {
    final double v = _read();
    if (v == _t) return;
    _t = v;
    // Our own height changes — which is the point: the Scaffold hands those
    // pixels straight to the body, and the bottom stack rides down on them.
    // The CHILD's constraints never change, so the bar is never rebuilt and
    // never re-measured.
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! BoxParentData) child.parentData = BoxParentData();
  }

  @override
  void performLayout() {
    final RenderBox? c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    // Full height, always: the bar is measured as though it were entirely on
    // screen, and only the SLOT it is allowed to occupy shrinks.
    c.layout(constraints.widthConstraints(), parentUsesSize: true);
    final double nat = c.size.height;
    size = constraints.constrain(Size(c.size.width, nat * (1 - _gone)));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final RenderBox? c = child;
    if (c == null) return constraints.smallest;
    final Size s = c.getDryLayout(constraints.widthConstraints());
    return constraints.constrain(Size(s.width, s.height * (1 - _gone)));
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      (child?.getMinIntrinsicHeight(width) ?? 0) * (1 - _gone);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (child?.getMaxIntrinsicHeight(width) ?? 0) * (1 - _gone);

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? c = child;
    if (c == null) return;
    // Painted from OUR top, at its full height: the slice on screen is the
    // bar's top, and the rest of it has travelled past the bottom of the
    // glass. Nothing is below a bottom nav to be painted over, so there is
    // nothing here to clip.
    context.paintChild(c, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox? c = child;
    if (c == null) return false;
    // Identity: the bar is painted at our origin, so the part of it inside our
    // (shrinking) box is exactly the part that is on screen. A tap below that
    // box never reaches here at all, which is what makes a hidden bar
    // untappable without a single coordinate being written down twice.
    return c.hitTest(result, position: position);
  }
}
