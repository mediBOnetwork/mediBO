// CMD #2147 — the header's order-hours pill.
// CMD #2187 — …which now always carries THREE lines and rolls them.
// CMD #2191 — …and whose WIDTH is the line it is showing, never a number.
//
// Everything it says and how it looks is `header_status_pill()` (reported as
// `order_hours_state().pill`):
//
//   {state, scope, lines[3]{kind,text}, hold_ms, roll_ms, pulse, pulse_ms,
//    style{bg, fg, dot, height, radius, text, pad_x, dot_size, min_w, max_w}}
//
// The backend picks the state, words all three lines (status · relative time ·
// action), resolves the scope (universal → the CTA, zone → the zone's stage,
// order → their own order) and merges the state's own geometry into `style`.
// This file holds no clock, no rule, no threshold and no English: it prints
// `lines[]` one at a time, paints `style` and pulses on `pulse`.
//
// THE ROLL. Each line holds for `hold_ms`, then the outgoing line slides UP
// and fades while the incoming line rises FROM BELOW — one movement, not a
// swap — over `roll_ms` on an ease-in-out, clipped inside the pill. The same
// motion the cash-discount strip and the search placeholder use.
//
// ONE MOTION (CMD #2187). The pill rolls only while the header row is fully on
// screen; the search placeholder is frozen for exactly as long. The verdict is
// `pillMayRoll` in `shell_motion.dart`, which is the BACKEND's
// `shell_style().motion.one_at_a_time` — not a rule invented here.
//
// ONLY THE BACKEND (CMD #2191, Om). The pill prints `lines[]` and nothing
// else. There is no English word for the pill in this file, no fallback
// string, no default label and no null-coalesce to a literal; `label` and
// `text` are the screen reader's one-string form of the same sentence and are
// never drawn. Every dimension and colour is a `style` value and every
// duration is a response value — no dp and no ms in Dart. A payload that is
// missing its words, its geometry or its colours draws NOTHING rather than
// something invented, which is what a single-line payload (an old cache, a
// backend that sent only `label`) now does. Reduce-motion is a cross-fade
// with a still dot.
//
// THE WIDTH (CMD #2191). The pill HUGS the line it is showing: the roll keeps
// only the incoming and the outgoing line in the Stack, so the pill's width is
// that line's width and it grows and shrinks with the words. `style.min_w` and
// `style.max_w` wrap the WHOLE pill — padding included — so `max_w` is the
// ceiling a reader actually sees, and a line only ellipsises once it has taken
// every pixel the ceiling (or the header row) allows. There is no fixed width
// anywhere in this file: height, radius, pad_x, text size, the dot and its gap
// are all `style` values, and the WORDS that fit a narrow phone are the
// backend's own narrow tier (`tier`), picked from the width the app reports.

import 'dart:async';

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../order_hours_state.dart';
import '../shell_motion.dart';
import '../utils/render_log.dart';

/// The live pill: reads the app-wide [OrderHoursState] and draws nothing until
/// the backend has sent one.
class OrderHoursHeaderPill extends StatelessWidget {
  const OrderHoursHeaderPill({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.dependOnInheritedWidgetOfExactType<OrderHoursState>();
    final m = st?.notifier;
    if (m == null) return const SizedBox.shrink();
    // CMD #2191 — the app reports the width it has; the BACKEND decides what
    // that width means (which wording tier fits it). Reported after the frame,
    // because it can start a fetch and a fetch notifies listeners.
    final double w = MediaQuery.sizeOf(context).width;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      m.reportViewportWidth(w);
    });
    return OrderHoursPill(pill: m.pill, sheet: m.sheet);
  }
}

/// The pill itself, pure: a payload in, a pill out. Tested on the VM.
class OrderHoursPill extends StatefulWidget {
  const OrderHoursPill({
    super.key,
    required this.pill,
    required this.sheet,
    this.rolls,
  });

  final Map<String, dynamic> pill;
  final Map<String, dynamic> sheet;

  /// Overrides the one-motion gate. `null` asks [pillMayRoll], which is the
  /// BACKEND's `shell_style().motion` policy; a test passes true/false to hold
  /// the gate still while it looks at the roll.
  final bool? rolls;

  static const String semanticsId = 'c2147_hours_pill';

  /// A line's style — one place, so every line of the roll is one size and the
  /// pill's width never depends on which line is showing. [size] is
  /// `style.text` and is required: a text size chosen here would be a dp in
  /// Dart.
  static TextStyle labelStyle(Color fg, {required double size}) =>
      Ds.t.caption.copyWith(
        color: fg,
        fontSize: size,
        fontWeight: FontWeight.w600,
        height: 1,
      );

  /// A `style` colour, or null when the backend did not send a usable one.
  /// Null is the whole point: there is no fallback colour in this file, so a
  /// pill with no colours draws nothing instead of a grey guess.
  static Color? colorOf(Object? hex) {
    var h = (hex ?? '').toString().trim();
    if (h.startsWith('#')) h = h.substring(1);
    if (h.length == 6) h = 'FF$h';
    if (h.length != 8) return null;
    final v = int.tryParse(h, radix: 16);
    return v == null ? null : Color(v);
  }

  /// The lines the backend sent, in ITS order, empties dropped — and NOTHING
  /// else. CMD #2191 (Om): there is no fallback to `label` or `text`. Those
  /// two carry the SAME sentence joined for a screen reader, and reading them
  /// here is the one route by which a stale single-line payload could print a
  /// word the backend had stopped saying. An empty `lines[]` is an empty pill.
  static List<String> linesOf(Map<String, dynamic> pill) {
    final raw = pill['lines'];
    if (raw is! List) return const <String>[];
    final out = <String>[];
    for (final e in raw) {
      final t = (e is Map ? (e['text'] ?? '') : (e ?? '')).toString();
      if (t.isNotEmpty) out.add(t);
    }
    return out;
  }

  @override
  State<OrderHoursPill> createState() => _OrderHoursPillState();
}

class _OrderHoursPillState extends State<OrderHoursPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    // No duration here: `roll_ms` is the backend's and arrives with the
    // payload, so the controller is given it at the moment it is used.
    duration: Duration.zero,
    value: 1,
  );
  Timer? _timer;
  int _i = 0;
  int _prev = 0;

  /// A finger on the pill holds the line it is reading (Om: pause on touch).
  bool _held = false;

  List<String> get _lines => OrderHoursPill.linesOf(widget.pill);

  /// The roll's two durations, the BACKEND's own. Absent (or not positive)
  /// means the backend is not asking for a roll — and there is no Dart number
  /// to fall back to, so the pill simply stands still.
  Duration? get _rollDur => _msOf('roll_ms');
  Duration? get _holdDur => _msOf('hold_ms');
  Duration? _msOf(String key) {
    final n = (widget.pill[key] as num?)?.toInt();
    return (n == null || n <= 0) ? null : Duration(milliseconds: n);
  }

  /// The one-motion verdict for this frame.
  bool get _mayRoll => widget.rolls ?? pillMayRoll;

  @override
  void initState() {
    super.initState();
    _publish();
    shellMotion.addListener(_onMotion);
    _restart();
  }

  @override
  void didUpdateWidget(covariant OrderHoursPill old) {
    super.didUpdateWidget(old);
    final n = _lines.length;
    if (_i >= n) _i = 0;
    if (_prev >= n) _prev = 0;
    _publish();
    if (OrderHoursPill.linesOf(old.pill).length != n ||
        old.pill['hold_ms'] != widget.pill['hold_ms'] ||
        old.rolls != widget.rolls) {
      _restart();
    }
  }

  @override
  void dispose() {
    shellMotion.removeListener(_onMotion);
    _timer?.cancel();
    _c.dispose();
    // The pill is leaving the screen, so it owns no motion any more and the
    // search placeholder is free to rotate again.
    shellPillCanRoll.value = false;
    super.dispose();
  }

  /// Tells the gate whether there is anything here to collide with.
  void _publish() => shellPillCanRoll.value = _lines.length > 1;

  /// The gate moved (the header row started or finished travelling). Nothing
  /// is rebuilt — only the clock starts or stops, which is the whole rule.
  void _onMotion() => _restart();

  void _restart() {
    _timer?.cancel();
    final hold = _holdDur;
    if (_lines.length < 2 || !_mayRoll || hold == null) return;
    _timer = Timer.periodic(hold, (_) {
      if (!mounted || _held || !_mayRoll) return;
      final n = _lines.length;
      if (n < 2) return;
      setState(() {
        _prev = _i;
        _i = (_i + 1) % n;
      });
      _c.duration = _rollDur ?? Duration.zero;
      _c.forward(from: 0);
    });
  }

  void _hold(bool held) {
    if (_held == held) return;
    _held = held;
  }

  /// `style` is CMD #2187's merged block (colours + geometry). `tone` is what
  /// #2147 sent and is still read, so an app on an old payload paints.
  Map<String, dynamic> get _style {
    final s = widget.pill['style'];
    if (s is Map && s.isNotEmpty) return Map<String, dynamic>.from(s);
    final t = widget.pill['tone'];
    return t is Map
        ? Map<String, dynamic>.from(t)
        : const <String, dynamic>{};
  }

  double? _dim(String key) => (_style[key] as num?)?.toDouble();

  /// One line of the roll, at the size every other line is drawn at.
  Widget _line(String text, TextStyle style) => Text(
        text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        textScaler: TextScaler.noScaling,
        style: style,
      );

  /// The roll. CMD #2187 kept every line in the Stack at all times, which made
  /// the pill as wide as its WIDEST line — a pill sized for "We are packing
  /// today's orders" while it showed "Order now", and an ellipsis on the line
  /// that was actually too long. CMD #2191: only the line coming IN and, while
  /// it is still moving, the line going OUT are in the Stack, so the pill is
  /// the width of what is on screen and changes with it. The outgoing line
  /// carries on UP and out of the middle while the incoming one rises FROM
  /// BELOW — one movement, not a swap — clipped inside the pill.
  Widget _roll(List<String> lines, TextStyle style, bool still) {
    if (lines.length < 2 || _holdDur == null) return _line(lines.first, style);
    return ClipRect(
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final double t =
              still ? 1 : Curves.easeInOut.transform(_c.value.clamp(0.0, 1.0));
          final bool rolling = !still && t < 1 && _prev != _i;
          return Stack(
            alignment: Alignment.centerLeft,
            children: <Widget>[
              if (rolling) _slot(_prev, t, lines[_prev], style, still),
              _slot(_i, t, lines[_i], style, still),
            ],
          );
        },
      ),
    );
  }

  Widget _slot(int k, double t, String text, TextStyle style, bool still) {
    final Widget child = _line(text, style);
    if (k == _i) {
      return FractionalTranslation(
        translation: Offset(0, still ? 0 : 1 - t),
        child: Opacity(opacity: t, child: child),
      );
    }
    return FractionalTranslation(
      translation: Offset(0, still ? 0 : -t),
      child: Opacity(opacity: 1 - t, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    if (lines.isEmpty) return const SizedBox.shrink();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final st = _style;
    // CMD #2191 (Om) — the three colours are `style`'s, with nothing to fall
    // back to. A pill the backend has not coloured is not drawn.
    final Color? bg = OrderHoursPill.colorOf(st['bg']);
    final Color? fg = OrderHoursPill.colorOf(st['fg']);
    final Color? dot = OrderHoursPill.colorOf(st['dot']);
    // The dot pulses on the backend's own period. No period, no pulse.
    final int? pulseMs = (widget.pill['pulse_ms'] as num?)?.toInt();
    final pulse = widget.pill['pulse'] == true &&
        !still &&
        pulseMs != null &&
        pulseMs > 0;
    final rolling = _mayRoll && lines.length > 1 && _holdDur != null;
    RenderLog.write('c2147_pill', (widget.pill['state'] ?? '').toString());
    RenderLog.write('c2187_pill_lines', lines.length);
    RenderLog.write('c2187_pill_roll', rolling ? 1 : 0);
    RenderLog.write('c2187_pill_scope', (widget.pill['scope'] ?? '').toString());
    // CMD #2191 — which wording tier the backend picked for the width this app
    // reported. 'narrow' on a 320/360 dp phone, 'full' from 369 dp up.
    RenderLog.write('c2191_pill_tier', (widget.pill['tier'] ?? '').toString());
    // The colour cross-fade rides the backend's own roll duration; there is no
    // Dart millisecond to pick here either.
    final colorMs = still ? Duration.zero : (_rollDur ?? Duration.zero);

    // CMD #2191 (Om) — EVERY dimension is a `style` value: height, radius,
    // text, pad_x, dot_size, dot_gap and the two width bounds. None of them
    // has a Dart default, because a dp written here is a dp the backend cannot
    // change. `min_w` and `max_w` wrap the WHOLE pill below, padding included,
    // so `max_w` is the width a reader can measure on the screen.
    final double? pillH = _dim('height');
    final double? textSize = _dim('text');
    final double? padX = _dim('pad_x');
    final double? dotSize = _dim('dot_size');
    final double? dotGap = _dim('dot_gap');
    final double? radius = _dim('radius');
    final double? minW = _dim('min_w');
    final double? maxW = _dim('max_w');
    // An incomplete payload draws NOTHING. That is the rule, not a defect:
    // half a pill in invented sizes is worse than no pill, and it is how the
    // backend stops being the only author.
    if (bg == null ||
        fg == null ||
        dot == null ||
        pillH == null ||
        textSize == null ||
        padX == null ||
        dotSize == null ||
        dotGap == null ||
        radius == null ||
        minW == null ||
        maxW == null) {
      RenderLog.write('c2191_pill_incomplete', 1);
      return const SizedBox.shrink();
    }
    final BorderRadius corner = BorderRadius.circular(radius);
    final textStyle = OrderHoursPill.labelStyle(fg, size: textSize);

    return Semantics(
      identifier: OrderHoursPill.semanticsId,
      button: true,
      // The whole pill in one string, joined by the BACKEND's own separator —
      // a screen reader is never handed a third of a sentence. CMD #2191: this
      // is the ONLY use of `label` in the app, it is never drawn, and it falls
      // back to nothing rather than to a line of the roll.
      label: (widget.pill['label'] ?? '').toString(),
      child: Listener(
        onPointerDown: (_) => _hold(true),
        onPointerUp: (_) => _hold(false),
        onPointerCancel: (_) => _hold(false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showOrderHoursSheet(context, widget.sheet),
          // The pill is `style.height` tall; the hit box is the whole header
          // row ([Ds.touch.headerTile]).
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: Ds.touch.headerTile),
            // Left-aligned (Om): the pill sits right after the logo; the free
            // room goes between it and the bell, never around it.
            child: Align(
              alignment: Alignment.centerLeft,
              widthFactor: 1,
              // The width follows the words: AnimatedSize carries the pill
              // from one line's width to the next over the roll's own
              // duration, so growing and shrinking is part of the same
              // movement rather than a jump at the end of it.
              child: AnimatedSize(
                duration: still ? Duration.zero : (_rollDur ?? Duration.zero),
                curve: Curves.easeInOut,
                alignment: Alignment.centerLeft,
                // CMD #2191 — the ceiling and the floor are OUTSIDE the
                // padding, so `max_w` is the pill's own width and a line
                // ellipsises only after the pill has taken all of it (or all
                // the header row had left, whichever is less).
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: minW, maxWidth: maxW),
                  child: AnimatedContainer(
                    duration: colorMs,
                    curve: Curves.easeOut,
                    height: pillH,
                    // NO `alignment:` here — a Container that is given one
                    // EXPANDS to fill whatever width it is offered, which is
                    // how the pill came to be a wide box with a clipped
                    // sentence in it. Without it the box is exactly its Row,
                    // and the Row is `MainAxisSize.min`: the pill is its
                    // words, plus pad_x, inside min_w..max_w.
                    padding: EdgeInsets.symmetric(horizontal: padX),
                    decoration: BoxDecoration(color: bg, borderRadius: corner),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LiveDot(
                            color: dot,
                            pulse: pulse,
                            periodMs: pulseMs ?? 0,
                            size: dotSize),
                        SizedBox(width: dotGap),
                        // CMD #2164 — the lines at their own size, always: no
                        // FittedBox, no OS text scaling. CMD #2187 — and one
                        // at a time, rolling. CMD #2191 — and the pill is as
                        // wide as the one that is showing.
                        Flexible(child: _roll(lines, textStyle, still)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A solid dot and, while [pulse], a ring of the same colour that grows from
/// the dot and fades out, once every [periodMs]. The ring is a scale + opacity
/// on a layer the size of the dot's box, so its growth never moves layout.
class LiveDot extends StatefulWidget {
  const LiveDot({
    super.key,
    required this.color,
    required this.pulse,
    required this.periodMs,
    required this.size,
  });

  final Color color;
  final bool pulse;

  /// `pulse_ms` from the payload. Required, because a pulse period invented
  /// here would be a millisecond the backend cannot change; [pulse] is only
  /// ever true when the backend sent a positive one.
  final int periodMs;

  /// `style.dot_size`, in logical pixels — the backend's, always.
  final double size;

  @override
  State<LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: widget.periodMs),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulse) _c.repeat();
  }

  @override
  void didUpdateWidget(LiveDot old) {
    super.didUpdateWidget(old);
    if (old.periodMs != widget.periodMs) {
      _c.duration = Duration(milliseconds: widget.periodMs);
    }
    if (widget.pulse && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.pulse && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double d = widget.size;
    final dotBox = Container(
      width: d,
      height: d,
      decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
    );
    return SizedBox(
      width: d,
      height: d,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          if (widget.pulse)
            RepaintBoundary(
              child: AnimatedBuilder(
                animation: _c,
                builder: (_, child) => Opacity(
                  opacity: (1 - _c.value) * 0.55,
                  child: Transform.scale(
                    scale: 1 + _c.value * 1.6,
                    child: child,
                  ),
                ),
                child: dotBox,
              ),
            ),
          dotBox,
        ],
      ),
    );
  }
}

/// The sheet the pill opens: `order_hours_state().sheet`, verbatim.
Future<void> showOrderHoursSheet(
  BuildContext context,
  Map<String, dynamic> sheet,
) {
  final title = (sheet['title'] ?? '').toString();
  final hours = (sheet['hours'] ?? '').toString();
  final note = (sheet['note'] ?? '').toString();
  if (title.isEmpty && hours.isEmpty) return Future.value();
  RenderLog.write('c2147_hours_sheet', 1);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Ds.space.x24,
          Ds.space.x24,
          Ds.space.x24,
          Ds.space.x32,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title.isNotEmpty) Text(title, style: Ds.t.title),
            if (hours.isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              Text(hours, style: Ds.t.bodyStrong),
            ],
            if (note.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(note, style: Ds.t.caption),
            ],
          ],
        ),
      ),
    ),
  );
}
