// CMD #2147 — the header's order-hours pill.
//
// Everything it says and how it looks is `order_hours_state().pill`:
// {state, label, tone{bg, fg, dot}, pulse, pulse_ms, refresh_s}. The backend
// picks which of the six states the zone is in and words it; this file holds
// no clock and no rule. It prints `label`, paints `tone`, pulses on `pulse`
// (a solid dot plus a ring that grows and fades — the YouTube live dot) and,
// when tapped, opens `order_hours_state().sheet` {title, hours, note}.
//
// Motion is transform/opacity only for the pulse, so nothing beside the pill
// moves while it breathes; a state change cross-fades the label (150 ms) and
// animates width and colours (300 ms). Reduce-motion: a still dot, instant
// switches.

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../order_hours_state.dart';
import '../utils/render_log.dart';
import 'customer_order_item_card.dart' show hexColor;

/// The live pill: reads the app-wide [OrderHoursState] and draws nothing until
/// the backend has sent one.
class OrderHoursHeaderPill extends StatelessWidget {
  const OrderHoursHeaderPill({super.key});

  @override
  Widget build(BuildContext context) {
    final st = context.dependOnInheritedWidgetOfExactType<OrderHoursState>();
    final m = st?.notifier;
    if (m == null) return const SizedBox.shrink();
    return OrderHoursPill(pill: m.pill, sheet: m.sheet);
  }
}

/// The pill itself, pure: a payload in, a pill out. Tested on the VM.
class OrderHoursPill extends StatelessWidget {
  const OrderHoursPill({super.key, required this.pill, required this.sheet});

  final Map<String, dynamic> pill;
  final Map<String, dynamic> sheet;

  static const String semanticsId = 'c2147_hours_pill';

  Map<String, dynamic> get _tone =>
      Map<String, dynamic>.from((pill['tone'] as Map?) ?? const {});

  @override
  Widget build(BuildContext context) {
    final label = (pill['label'] ?? '').toString();
    if (label.isEmpty) return const SizedBox.shrink();
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final bg = hexColor((_tone['bg'] ?? '').toString(), fallback: Ds.c.bg);
    final fg = hexColor(
      (_tone['fg'] ?? '').toString(),
      fallback: Ds.c.textSecondary,
    );
    final dot = hexColor((_tone['dot'] ?? '').toString(), fallback: fg);
    final pulse = pill['pulse'] == true && !still;
    final ms = (pill['pulse_ms'] as num?)?.toInt() ?? 1600;
    RenderLog.write('c2147_pill', (pill['state'] ?? '').toString());
    final colorMs = Duration(milliseconds: still ? 0 : 300);
    return Semantics(
      identifier: semanticsId,
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => showOrderHoursSheet(context, sheet),
        // The pill is [Ds.touch.headerPill] tall; the hit box is the whole
        // header row ([Ds.touch.headerTile]).
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: Ds.touch.headerTile),
          // Left-aligned (Om): the pill sits right after the logo; the free
          // room goes between it and the bell, never around it.
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: 1,
            child: AnimatedSize(
              duration: colorMs,
              curve: Curves.easeOut,
              alignment: Alignment.centerLeft,
              child: AnimatedContainer(
                duration: colorMs,
                curve: Curves.easeOut,
                height: Ds.touch.headerPill,
                alignment: Alignment.centerLeft,
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    LiveDot(color: dot, pulse: pulse, periodMs: ms),
                    SizedBox(width: Ds.space.x4 + Ds.space.x4 / 2),
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: Duration(milliseconds: still ? 0 : 150),
                        // Om: never ellipsize — the full label on one
                        // line; only a phone too narrow for it scales it down.
                        child: FittedBox(
                          key: ValueKey(label),
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            label,
                            maxLines: 1,
                            softWrap: false,
                            style: Ds.t.caption.copyWith(
                              color: fg,
                              fontSize: Ds.touch.headerPillText,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
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
    this.periodMs = 1600,
  });

  final Color color;
  final bool pulse;
  final int periodMs;

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
    final d = Ds.space.x8;
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
