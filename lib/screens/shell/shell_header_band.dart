part of '../home_shell.dart';

// CMD #2052 · LAYER 1 — the collapsing header band, sharded out of
// shell_mobile_chrome.dart.
//
// The band is one self-contained concern — a driver, a notifier, a settle and a
// render object — and it is the piece of the shell most likely to be edited on
// its own, so it gets its own leasable path rather than sharing the mobile
// chrome's. A `part`, not a library, for shell_mobile_chrome's reason: the
// widgets around it are library-private and making them public to move one
// concern would be a rewrite, not an extraction.

// ─── CMD #2030 — the header band follows the finger, 1:1 ─────────────────────
// ─── CMD #2038 — …but only when the finger actually asked for it ─────────────
// ─── CMD #2052 — so stop asking the LIST, and ask the finger ─────────────────
//
// CMD #2019 gave the band back to the products on scroll, but on a verdict:
// 12 px of travel flipped a bool and a 180 ms curve played the rest. #2030
// deleted the verdict and made the band a DISTANCE that IS the scroll delta.
// #2038 then filtered the deltas no finger produced — overscroll, bounce, the
// snap-back, a tremor mid-drag.
//
// All of it read the SCROLL OFFSET, and the offset is the problem. It does not
// only move when a finger moves it: a page of products arriving shortens
// nothing but re-measures everything, a grid re-lays-out, a keyboard opens, a
// `jumpTo` fires, a collapsing band hands its own height to the viewport. Each
// of those reports pixels running BACKWARDS, every backward pixel read as "the
// finger came up", and the header flashed back mid-scroll with no reversal of
// Om's own. Filtering harder could never fix it: a re-measure is
// indistinguishable from a drag once you are looking at an offset.
//
// So the input is not the offset any more. It is the POINTER, and only while it
// is down:
//
//   1. ONLY A FINGER MOVES THE BAND. The driver reads `dragDetails.delta`, the
//      pointer's own travel, and ignores every ScrollUpdate that carries no
//      drag. Inserted content, a re-measure, a keyboard, a programmatic jump
//      and the band's own effect on the viewport all arrive without a finger,
//      so all of them move the header by exactly zero.
//   2. MOMENTUM FOLLOWS THE DRAG THAT STARTED IT. A ballistic phase drives
//      nothing at all. When the finger leaves the glass the band finishes in
//      the direction the DRAG was going, so a downward fling can only ever end
//      with the header away — it can never reveal it on the way.
//   3. A REVERSAL EARNS ITS TURN, on the finger: `Ds.touch.headerHysteresis`
//      (40 px) of deliberate travel the other way. Under that the band does not
//      move — but the travel is KEPT, so the moment the turn is earned every
//      pixel the finger asked for is paid at once, rather than the first 40 px
//      of every reversal being eaten.
//   4. OVERSCROLL AND BOUNCE ARE NOT SCROLL. An OverscrollNotification is
//      discarded outright, and so is any drag reported while the list is
//      outside its own [min, max] — the whole of a bounce and the whole of the
//      spring back.
//   5. IT IS NEVER LEFT HALF OPEN. The gesture decides which end;
//      `Ds.touch.headerSettleMs` decides how fast it gets there. The settle is
//      an ANIMATION VALUE written into the same notifier the render object
//      already listens to, so a settle rebuilds exactly as much as a drag
//      does: nothing.
//
// It is still not a real SliverAppBar, for #2019's reason: the chrome BELOW the
// band is what must stay pinned, and that chrome changes height with focus (the
// search bar, the breadcrumb, the A–Z rail, the category chip row, and the idle
// rail that opens under them). A pinned sliver must be told its extent in
// advance; a widget that sits outside the scroll view need not be, and outside
// the scroll view is the strongest form of pinned there is. The band shrinks
// its own height, so every one of those rows stays exactly under wherever the
// band currently ends. Nothing reflows: the width never changes.
//
// ONE band, ONE driver, ONE notifier — for Home and for the Catalogue both
// (#2052(8)). They are two pages of the same shell, so the Catalogue's lists
// bubble their notifications into the same listener and collapse the same
// header; there is no second controller to keep in step with this one.

/// How many logical pixels of the header band are currently gone: 0 = the whole
/// band is showing, `Ds.touch.headerBand` = it is entirely off the top. Every
/// value in between is real — this is a position, not a state.
final ValueNotifier<double> shellHeaderCollapse = ValueNotifier<double>(0);

/// Is any of the band still showing? Derived, never stored: a second source of
/// truth is how a scroll-linked header starts snapping again.
bool get shellHeaderBandShowing =>
    shellHeaderCollapse.value < Ds.touch.headerBand;

/// The deepest collapse this session has reached, for the render log: a live
/// page that reports it has moved the band by N pixels is proof the driver ran,
/// which a screenshot of a header at rest can never be.
double _bandDeepest = 0;

void _bandSet(double v) {
  if (shellHeaderCollapse.value == v) return;
  shellHeaderCollapse.value = v;
  if (v > _bandDeepest) {
    _bandDeepest = v;
    RenderLog.write('c2030_band_px', v.round());
  }
}

// ── The driver's memory. Three numbers and a flag, no widget state. ──────────

/// The direction the band is currently travelling in: 1 = hiding (the finger is
/// going up the glass), -1 = showing, 0 = it has not moved yet.
double _bandDir = 0;

/// Finger travel AGAINST [_bandDir] that has been asked for but not yet
/// believed, signed. It is spent in full the moment it crosses the hysteresis,
/// so a reversal is DELAYED by 40 px — never shortened by 40 px.
double _bandPending = 0;

/// Is a finger currently on the glass? Set by the first drag delta of a
/// gesture, cleared when the gesture is finished off. It is what tells a
/// ballistic delta apart from a re-measure: both arrive without a finger, but
/// only one of them follows one.
bool _bandDragging = false;

/// Deltas the filters threw away, for the render log: a live page that reports
/// it refused N deltas is the only proof a flicker guard can give, because the
/// flicker it prevents is by definition not in a screenshot.
int _bandHeld = 0;

/// Gestures finished off by the settle, for the render log.
int _bandSettled = 0;

/// The mounted band's settle animation, or null when no band is on screen (a
/// unit test, a disabled tab). Without one the band still finishes — it simply
/// arrives instantly instead of travelling.
_ShellHeaderSettle? _bandSettle;

void _bandHold() {
  _bandHeld++;
  RenderLog.write('c2038_hold', _bandHeld);
}

/// Put the band back. A new tab, or a tab the band does not belong to, starts
/// with full chrome — and with no memory of the last tab's direction.
void shellHeaderBandShow() {
  _bandDir = 0;
  _bandPending = 0;
  _bandDragging = false;
  _bandSettle?.stop();
  _bandSet(0);
}

/// Feeds [shellHeaderCollapse] from the FINGER, 1:1 — and from nothing else.
/// Always returns false: this listens, it never swallows a notification.
bool shellHeaderScroll(ScrollNotification n, bool enabled) {
  if (!enabled) {
    shellHeaderBandShow();
    return false;
  }
  // Horizontal rails (the home feed's carousels, the chip row, the A–Z strip,
  // the idle rail) scroll constantly and must never move the band.
  if (n.metrics.axis != Axis.vertical) return false;
  if (!n.metrics.hasContentDimensions) return false;

  final double h = Ds.touch.headerBand;

  // A finger landing cancels a settle that is still playing and throws away a
  // reversal that was still being built: the next gesture starts its own
  // argument. The direction SURVIVES, because the 40 px a turn costs is about
  // the finger changing its mind, not about where a gesture happens to end.
  if (n is ScrollStartNotification) {
    _bandSettle?.stop();
    _bandPending = 0;
    _bandDragging = n.dragDetails != null;
    return false;
  }
  // #2052(5) — the list has come to rest. Whatever is left half open is
  // finished off now.
  if (n is ScrollEndNotification) {
    _bandFinishGesture();
    return false;
  }
  // #2052(2) — `idle` IS the finger leaving the glass, and it is reported
  // BEFORE the ballistic phase starts. The band settles from here, so the
  // momentum that follows has nothing left to do and nothing to reveal.
  if (n is UserScrollNotification) {
    if (n.direction == ScrollDirection.idle) _bandFinishGesture();
    return false;
  }
  // #2052(4) — an OverscrollNotification IS the bounce. It never drives.
  if (n is OverscrollNotification) {
    _bandHold();
    return false;
  }
  if (n is! ScrollUpdateNotification) return false;

  // #2052(1) — no finger, no movement. A fling coasting, the physics settling,
  // a page of products inserted, a grid re-measuring, the keyboard opening, a
  // programmatic jump: every one of them arrives here without `dragDetails`,
  // and not one of them is allowed a pixel of the header. The first of them
  // after a drag is also the moment the finger left, so the gesture is
  // finished off rather than abandoned half open.
  if (n.dragDetails == null) {
    if (_bandDragging) {
      _bandFinishGesture();
    } else {
      _bandHold();
    }
    return false;
  }

  // A page with less to scroll than the band is tall can never lose its header:
  // hiding it would be the only scrolling the page had.
  if (n.metrics.maxScrollExtent - n.metrics.minScrollExtent <= h) {
    shellHeaderBandShow();
    return false;
  }

  // #2052(4) — the list is past one of its own ends: this drag is stretching a
  // bounce, not scrolling. Ignored entirely, in both directions.
  if (n.metrics.outOfRange) {
    _bandHold();
    return false;
  }

  _bandDragging = true;
  _bandSettle?.stop();

  // The pointer's own travel. A finger moving UP the glass (a negative dy)
  // takes the list DOWN and the header with it, so the band's sign is the
  // pointer's, flipped. `scrollDelta` is deliberately not read: it is the
  // number that lies when the list re-measures.
  final double d = -n.dragDetails!.delta.dy;
  if (d == 0) return false;

  // Sitting at the very top of the list wearing half a header is a state no
  // drag can leave, because there is no more list to drag back. The floor is
  // read only while a finger is down, so an offset that arrives at 0 on its own
  // — a reset, a jumpTo, a re-measure — can still never flash the header back.
  if (n.metrics.pixels <= n.metrics.minScrollExtent && d <= 0) {
    _bandDir = -1;
    _bandPending = 0;
    _bandSet(0);
    return false;
  }

  // #2052(3) — the reservoir. Every drag delta goes in; the band moves only
  // when what is in it points the way the band is ALREADY going, or when a new
  // direction has travelled `Ds.touch.headerHysteresis` and earned itself. So a
  // wobble that nets nothing moves nothing in EITHER direction, and a direction
  // that is finally believed is paid in full rather than docked the threshold.
  //
  // The threshold guards the FIRST direction as well as a reversal, because the
  // gesture now finishes what it starts (#2052(5)): without it, three stray
  // pixels at the top of a fresh page would take the whole header away. "Smaller
  // jitter changes nothing" has to mean nothing, from cold as much as mid-drag.
  double spend = d;
  _bandPending += d;
  if (_bandDir != 0 && _bandPending * _bandDir > 0) {
    spend = _bandPending; // with the grain: net travel, 1:1
  } else if (_bandPending.abs() >= Ds.touch.headerHysteresis) {
    spend = _bandPending; // the turn is earned, and paid in full
  } else {
    _bandHold();
    return false;
  }
  _bandPending = 0;
  _bandDir = spend > 0 ? 1.0 : -1.0;

  // 1:1, both directions, inside the band's own height.
  double v = shellHeaderCollapse.value + spend;
  if (v < 0) v = 0;
  if (v > h) v = h;
  _bandSet(v);
  return false;
}

/// #2052(5) — the finger has left. The band is finished off at the end the DRAG
/// was heading for, never at the end an offset happens to be nearest: that is
/// what makes a downward fling unable to reveal it. With no gesture behind it
/// (a stray end notification) the nearer end wins, so the band is never left
/// standing half open by anything at all.
void _bandFinishGesture() {
  if (!_bandDragging) return;
  _bandDragging = false;
  _bandPending = 0;
  final double h = Ds.touch.headerBand;
  final double from = shellHeaderCollapse.value;
  final double to = _bandDir > 0
      ? h
      : _bandDir < 0
          ? 0
          : (from * 2 >= h ? h : 0);
  if (from == to) return;
  _bandSettled++;
  RenderLog.write('c2052_settle', _bandSettled);
  final _ShellHeaderSettle? s = _bandSettle;
  if (s == null) {
    _bandSet(to);
    return;
  }
  s.run(from, to);
}

/// The settle: an [AnimationController] whose value is written straight into
/// [shellHeaderCollapse]. Nothing rebuilds — the render object is already
/// listening to that notifier, so an animated frame costs exactly what a
/// dragged frame costs.
class _ShellHeaderSettle {
  _ShellHeaderSettle(TickerProvider vsync)
      : _c = AnimationController(vsync: vsync, duration: _settleDuration) {
    _c.addListener(_tick);
  }

  static Duration get _settleDuration =>
      Duration(milliseconds: Ds.touch.headerSettleMs.round());

  final AnimationController _c;
  double _from = 0;
  double _to = 0;

  void _tick() {
    final double t = Curves.easeOutCubic.transform(_c.value);
    _bandSet(_from + (_to - _from) * t);
  }

  void run(double from, double to) {
    _from = from;
    _to = to;
    _c.duration = _settleDuration;
    _c.forward(from: 0);
  }

  void stop() {
    if (_c.isAnimating) _c.stop();
  }

  void dispose() {
    _c.removeListener(_tick);
    _c.dispose();
  }
}

/// CMD #2052(8) — the shell tabs the band belongs to: the storefront Home (0)
/// and the Catalogue (12). Both are pages of the SAME shell, drawn under the
/// SAME header, so both are driven by the one controller above rather than by a
/// second one that would have to be kept in step with it. Every other tab —
/// Orders, Bulk upload, My Shop, and every staff page — keeps its header at all
/// times, which is what `shellHeaderScroll(n, false)` restores.
bool shellHeaderBandTab(int index) => index == 0 || index == 12;

/// The header band, wrapped so it can ride the scroll. [enabled] is the shell's
/// own verdict — only the customer phone chrome collapses.
Widget shellCollapsibleBand(bool enabled, Widget child) =>
    enabled ? _CollapsingBand(child: child) : child;

/// CMD #2052 — the band owns the settle's ticker, and nothing else.
///
/// It is a StatefulWidget purely so there is a [TickerProvider] with the band's
/// own lifetime to hang the settle on. It never calls `setState`, so the child
/// is built exactly once: the movement — dragged or settling — is a number on a
/// notifier the render object below reads for itself.
class _CollapsingBand extends StatefulWidget {
  const _CollapsingBand({required this.child});

  final Widget child;

  @override
  State<_CollapsingBand> createState() => _CollapsingBandState();
}

class _CollapsingBandState extends State<_CollapsingBand>
    with SingleTickerProviderStateMixin {
  late final _ShellHeaderSettle _settle;

  @override
  void initState() {
    super.initState();
    _settle = _ShellHeaderSettle(this);
    _bandSettle = _settle;
  }

  @override
  void dispose() {
    if (identical(_bandSettle, _settle)) _bandSettle = null;
    _settle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _BandBox(child: widget.child);
}

/// CMD #2038 — a render object, not a builder.
///
/// #2030 already handed the header subtree through a `ValueListenableBuilder`
/// untouched, so the header's own widgets never rebuilt. The WRAPPER still did:
/// every frame of every flick allocated a new `Align` and updated its element,
/// 60 times a second, to change one number. There is no widget to rebuild here
/// at all. The notifier is read by the render object itself; moving it marks
/// layout and paint and nothing else, and the child is laid out with the very
/// same constraints every frame, so it never relayouts either — it is simply
/// painted [_gone] pixels higher, under a clip.
class _BandBox extends SingleChildRenderObjectWidget {
  const _BandBox({required Widget child}) : super(child: child);

  @override
  _RenderCollapsingBand createRenderObject(BuildContext context) {
    RenderLog.write('c2030_band', 1);
    RenderLog.write('c2038_band', 1);
    RenderLog.write('c2052_band', 1);
    return _RenderCollapsingBand(shellHeaderCollapse);
  }
}

class _RenderCollapsingBand extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _RenderCollapsingBand(this._collapse);

  final ValueListenable<double> _collapse;

  /// How many pixels of the band are gone, clamped to the band's own measured
  /// height. Read from the notifier, never stored anywhere else.
  double _gone = 0;

  ClipRectLayer? _clip;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _gone = _read();
    _collapse.addListener(_onCollapse);
  }

  @override
  void detach() {
    _collapse.removeListener(_onCollapse);
    super.detach();
  }

  @override
  void dispose() {
    _clip?.dispose();
    _clip = null;
    super.dispose();
  }

  double _read() {
    final double v = _collapse.value;
    return v.isFinite && v > 0 ? v : 0;
  }

  void _onCollapse() {
    final double v = _read();
    if (v == _gone) return;
    _gone = v;
    // Our own height changes, so this is layout — but the CHILD's constraints
    // do not change, so the header itself is never laid out again either.
    markNeedsLayout();
  }

  /// The band's natural height, and how much of it is currently hidden.
  double get _hidden {
    final RenderBox? c = child;
    if (c == null) return 0;
    final double nat = c.size.height;
    return _gone > nat ? nat : _gone;
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
    // Width comes from the parent, height is the header's own: the same
    // constraints on every frame, which is what keeps the child out of layout.
    c.layout(constraints.widthConstraints(), parentUsesSize: true);
    final double nat = c.size.height;
    final double gone = _gone > nat ? nat : _gone;
    size = constraints.constrain(Size(c.size.width, nat - gone));
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final RenderBox? c = child;
    if (c == null) return constraints.smallest;
    final Size s = c.getDryLayout(constraints.widthConstraints());
    final double gone = _gone > s.height ? s.height : _gone;
    return constraints.constrain(Size(s.width, s.height - gone));
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      ((child?.getMinIntrinsicHeight(width) ?? 0) - _gone).clamp(0.0, 1e9);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      ((child?.getMaxIntrinsicHeight(width) ?? 0) - _gone).clamp(0.0, 1e9);

  @override
  void paint(PaintingContext context, Offset offset) {
    final RenderBox? c = child;
    if (c == null) return;
    final double gone = _hidden;
    // The band RISES: the slice still on screen is its BOTTOM, exactly as if
    // the row were scrolling off the top of the list. A pure translation, and
    // a clip so the part that has risen past the top paints nowhere.
    if (gone <= 0) {
      _clip?.dispose();
      _clip = null;
      context.paintChild(c, offset);
      return;
    }
    _clip = context.pushClipRect(
      needsCompositing,
      offset,
      Offset.zero & size,
      (PaintingContext inner, Offset o) =>
          inner.paintChild(c, o + Offset(0, -gone)),
      oldLayer: _clip,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final RenderBox? c = child;
    if (c == null) return false;
    final Offset shift = Offset(0, -_hidden);
    return result.addWithPaintOffset(
      offset: shift,
      position: position,
      hitTest: (BoxHitTestResult r, Offset p) => c.hitTest(r, position: p),
    );
  }

  @override
  void applyPaintTransform(RenderObject child, Matrix4 transform) {
    transform.translateByDouble(0.0, -_hidden, 0.0, 1.0);
  }
}
