// CMD #2139 — Cart v2 pieces.
//
// Every word, amount and state here is `cart_render().v2` (or
// `cart_place_block()` / `cart_v2_placed()`), printed verbatim. This file owns
// only layout: where the CD strip sits, how a row slides, how tall the receive
// box is. Nothing is computed or worded in Dart.

import 'dart:async';

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

Map<String, dynamic> v2Map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};

List<Map<String, dynamic>> v2List(Object? v) => v is List
    ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
    : const <Map<String, dynamic>>[];

String v2s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

/// The backend names an icon; this is the lookup, nothing more.
IconData v2Icon(String name) {
  switch (name) {
    case 'local_shipping':
      return Icons.local_shipping_outlined;
    case 'storefront':
      return Icons.storefront_outlined;
    case 'person':
      return Icons.person_outline;
    case 'assignment':
      return Icons.assignment_outlined;
    case 'hourglass':
      return Icons.hourglass_empty;
    case 'block':
      return Icons.do_not_disturb_on_outlined;
    case 'location':
      return Icons.location_on_outlined;
    case 'schedule':
      return Icons.schedule;
    case 'warning':
      return Icons.warning_amber_rounded;
    case 'check':
      return Icons.check_circle_outline;
    case 'rupee':
      return Icons.currency_rupee;
    case 'delete':
      return Icons.delete_outline;
    default:
      return Icons.info_outline;
  }
}

/// A backend tone name → the token pair.
({Color bg, Color fg}) v2Tone(String tone) {
  switch (tone) {
    case 'success':
      return (bg: Ds.c.successSoft, fg: Ds.c.brand);
    case 'warning':
      return (bg: Ds.c.warningSoft, fg: Ds.c.warning);
    case 'danger':
      return (bg: Ds.c.dangerSoft, fg: Ds.c.danger);
    default:
      return (bg: Ds.c.infoSoft, fg: Ds.c.info);
  }
}

// ── CD strip ────────────────────────────────────────────────────────────────

/// Every active discount slab, one at a time, sliding on the backend's
/// interval. `has:false` draws nothing.
class CartCdStrip extends StatefulWidget {
  final Map<String, dynamic> block;
  const CartCdStrip({super.key, required this.block});

  @override
  State<CartCdStrip> createState() => _CartCdStripState();
}

class _CartCdStripState extends State<CartCdStrip>
    with SingleTickerProviderStateMixin {
  Timer? _t;
  int _i = 0;

  /// CMD #2152 — the cash-discount burst: the badge rises from below, a ring
  /// bursts around it, then it floats up and fades out at the top. One
  /// controller, [kCdBurstMs] long, restarted each time the discount shown
  /// appears or changes. It runs on the display's own vsync (120 Hz panels
  /// get 120 frames a second).
  late final AnimationController _burst = AnimationController(
      vsync: this, duration: const Duration(milliseconds: kCdBurstMs));

  List<Map<String, dynamic>> get _slides => v2List(widget.block['slides']);

  bool get _showing => widget.block['has'] == true && _slides.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _arm();
    if (_showing) _fire();
  }

  @override
  void didUpdateWidget(CartCdStrip old) {
    super.didUpdateWidget(old);
    final was = old.block['has'] == true && v2List(old.block['slides']).isNotEmpty;
    if (_i >= _slides.length) _i = 0;
    // Appeared, or the backend sent a different discount list.
    if (_showing &&
        (!was || '${old.block['slides']}' != '${widget.block['slides']}')) {
      _fire();
    }
  }

  void _fire() {
    RenderLog.write('c2152_cd_burst', '${_i % (_slides.isEmpty ? 1 : _slides.length)}');
    _burst.forward(from: 0);
  }

  void _arm() {
    _t?.cancel();
    final ms = (widget.block['interval_ms'] as num?)?.toInt() ?? 0;
    if (ms <= 0) return;
    _t = Timer.periodic(Duration(milliseconds: ms), (_) {
      if (!mounted) return;
      final n = _slides.length;
      if (n > 1) {
        setState(() => _i = (_i + 1) % n);
        _fire();
      }
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slides = _slides;
    if (!_showing) {
      return const SizedBox.shrink();
    }
    final s = slides[_i % slides.length];
    final ink = Ds.c.warning;
    return Semantics(
      identifier: 'cart_cd_strip',
      child: Container(
        margin: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x4),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: Ds.c.warningSoft,
          borderRadius: Ds.r.rButton,
          border: Border.all(color: ink.withValues(alpha: 0.35)),
        ),
        child: Row(children: [
          CdBurstBadge(
            progress: _burst,
            label: v2s(s, 'lead'),
            ink: ink,
          ),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, anim) => SlideTransition(
                position: Tween<Offset>(
                        begin: const Offset(0, 0.6), end: Offset.zero)
                    .animate(anim),
                child: FadeTransition(opacity: anim, child: child),
              ),
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: v2s(s, 'lead'),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  const TextSpan(text: ' '),
                  TextSpan(text: v2s(s, 'rest')),
                ]),
                key: ValueKey(_i),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption.copyWith(color: Ds.c.text),
              ),
            ),
          ),
          SizedBox(width: Ds.space.x8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var k = 0; k < slides.length; k++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  margin: EdgeInsets.only(left: k == 0 ? 0 : Ds.space.x4 / 2),
                  width: k == _i % slides.length ? Ds.space.x16 : Ds.space.x4,
                  height: Ds.space.x4,
                  decoration: BoxDecoration(
                    color: k == _i % slides.length
                        ? ink
                        : ink.withValues(alpha: 0.35),
                    borderRadius: Ds.r.rChip,
                  ),
                ),
            ],
          ),
        ]),
      ),
    );
  }
}

/// CMD #2152 — how long one cash-discount burst lasts.
const int kCdBurstMs = 900;

/// The CD strip's badge and its burst. At rest it is the % tile. When
/// [progress] runs (0→1 over [kCdBurstMs]) a pill carrying the backend's
/// [label] rises from below (0–0.28), a ring bursts around it (0.18–0.62),
/// then it floats up and fades out at the top (0.62–1). Nothing here is
/// laid out differently while it plays — the pill and ring are painted over
/// the tile, so the strip never changes height.
class CdBurstBadge extends StatelessWidget {
  final Animation<double> progress;
  final String label;
  final Color ink;
  const CdBurstBadge(
      {super.key, required this.progress, required this.label, required this.ink});

  /// Phase edges, as fractions of the burst.
  static const double riseEnd = 0.28;
  static const double ringStart = 0.18;
  static const double ringEnd = 0.62;
  static const double floatStart = 0.62;

  static double _seg(double t, double a, double b) =>
      ((t - a) / (b - a)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final tile = Ds.space.x24;
    return SizedBox(
      width: tile,
      height: tile,
      child: AnimatedBuilder(
        animation: progress,
        builder: (context, _) {
          final t = progress.value;
          final playing = progress.isAnimating || (t > 0 && t < 1);
          final rise = Curves.easeOutBack.transform(_seg(t, 0, riseEnd));
          final ring = Curves.easeOut.transform(_seg(t, ringStart, ringEnd));
          final fl = Curves.easeIn.transform(_seg(t, floatStart, 1));
          final travel = Ds.space.x24;
          final dy = (1 - rise) * travel - fl * travel;
          final pillOpacity = (_seg(t, 0, riseEnd * 0.6) * (1 - fl)).clamp(0.0, 1.0);
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Container(
                width: tile,
                height: tile,
                decoration:
                    BoxDecoration(color: ink, borderRadius: Ds.r.rButton),
                alignment: Alignment.center,
                child: Icon(Icons.percent,
                    size: Ds.space.x16, color: Ds.c.surface),
              ),
              if (playing && ring > 0 && ring < 1)
                IgnorePointer(
                  child: CustomPaint(
                    size: Size.square(tile),
                    painter: _CdRingPainter(
                        progress: ring, color: ink, base: tile / 2),
                  ),
                ),
              if (playing && label.isNotEmpty && pillOpacity > 0)
                Positioned(
                  left: 0,
                  top: dy - Ds.space.x4,
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: pillOpacity,
                      child: Transform.scale(
                        scale: 0.8 + 0.2 * rise,
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: Ds.space.x8,
                              vertical: Ds.space.x4),
                          decoration: BoxDecoration(
                            color: ink,
                            borderRadius: Ds.r.rChip,
                            boxShadow: Ds.elevation.e2,
                          ),
                          child: Text(label,
                              maxLines: 1,
                              softWrap: false,
                              style: Ds.t.caption.copyWith(
                                  color: Ds.c.surface,
                                  fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _CdRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double base;
  _CdRingPainter({required this.progress, required this.color, required this.base});

  @override
  void paint(Canvas canvas, Size size) {
    final r = base * (1 + 1.6 * progress);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (1 - progress) * base * 0.35 + 1
      ..color = color.withValues(alpha: (1 - progress) * 0.8);
    canvas.drawCircle(size.center(Offset.zero), r, paint);
  }

  @override
  bool shouldRepaint(_CdRingPainter old) =>
      old.progress != progress || old.color != color || old.base != base;
}

// ── Swipe-to-reveal Remove ──────────────────────────────────────────────────

/// Drag left to reveal the red Remove action; tap it to remove. Drag right
/// (or tap the row) closes it. Nothing is removed by the drag itself.
class CartSwipeRow extends StatefulWidget {
  final Widget child;
  final String removeLabel;
  final VoidCallback? onRemove;
  final String semanticsId;
  const CartSwipeRow({
    super.key,
    required this.child,
    required this.removeLabel,
    required this.onRemove,
    this.semanticsId = 'cart_row_remove',
  });

  @override
  State<CartSwipeRow> createState() => _CartSwipeRowState();
}

class _CartSwipeRowState extends State<CartSwipeRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 180));

  double get _actionW => Ds.touch.minTarget * 2;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _drag(DragUpdateDetails d) {
    _c.value = (_c.value - d.primaryDelta! / _actionW).clamp(0.0, 1.0);
  }

  void _end(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    if (v < -300 || (v <= 300 && _c.value > 0.5)) {
      _c.forward();
    } else {
      _c.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.onRemove == null) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _drag,
      onHorizontalDragEnd: _end,
      child: ClipRect(
        child: Stack(children: [
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: Semantics(
                identifier: widget.semanticsId,
                button: true,
                child: InkWell(
                  onTap: () {
                    _c.value = 0;
                    widget.onRemove!();
                  },
                  child: Container(
                    width: _actionW,
                    color: Ds.c.danger,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_outline,
                            size: Ds.space.x16, color: Ds.c.surface),
                        SizedBox(height: Ds.space.x4),
                        Text(widget.removeLabel,
                            style: Ds.t.caption.copyWith(
                                color: Ds.c.surface,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _c,
            builder: (_, child) => Transform.translate(
                offset: Offset(-_actionW * _c.value, 0), child: child),
            child: GestureDetector(
              onTap: _c.value > 0 ? () => _c.reverse() : null,
              child: ColoredBox(color: Ds.c.surface, child: widget.child),
            ),
          ),
        ]),
      ),
    );
  }
}

// ── Floating dark note (swipe tip) ──────────────────────────────────────────

class CartSwipeTip extends StatelessWidget {
  final Map<String, dynamic> block;
  final VoidCallback onOk;
  const CartSwipeTip({super.key, required this.block, required this.onOk});

  @override
  Widget build(BuildContext context) {
    if (block['show'] != true) return const SizedBox.shrink();
    return Container(
      margin: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x8),
      padding: EdgeInsets.only(left: Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.text,
        borderRadius: Ds.r.rButton,
        boxShadow: Ds.elevation.e2,
      ),
      child: Row(children: [
        Icon(Icons.swipe_left, size: Ds.space.x16, color: Ds.c.warning),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: v2s(block, 'bold'),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const TextSpan(text: ' '),
              TextSpan(text: v2s(block, 'rest')),
            ]),
            style: Ds.t.caption.copyWith(color: Ds.c.surface),
          ),
        ),
        // CMD #2152 — the tap target is its own opaque Material/InkWell, the
        // top-most thing under the finger: no Dismissible, drag recogniser or
        // overlay sits above it, and the hide happens in the tap's own frame
        // (CartModel.swipeTipSeen) before the server write.
        Semantics(
          identifier: 'cart_swipe_tip_ok',
          button: true,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onOk,
              borderRadius: Ds.r.rButton,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                    minWidth: Ds.touch.minTarget,
                    minHeight: Ds.touch.minTarget),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                  child: Center(
                    widthFactor: 1,
                    child: Text(v2s(block, 'ok'),
                        style: Ds.t.caption.copyWith(
                            color: Ds.c.brandSoft,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

// ── Bill summary ────────────────────────────────────────────────────────────

class CartBillV2 extends StatefulWidget {
  final Map<String, dynamic> block;
  const CartBillV2({super.key, required this.block});

  @override
  State<CartBillV2> createState() => _CartBillV2State();
}

class _CartBillV2State extends State<CartBillV2> {
  bool _open = false;

  Widget _amount(String struck, String value, bool free, {bool strong = false}) =>
      Row(mainAxisSize: MainAxisSize.min, children: [
        if (struck.isNotEmpty) ...[
          Text(struck,
              style: Ds.t.caption.copyWith(
                  decoration: TextDecoration.lineThrough,
                  color: Ds.c.textSecondary)),
          SizedBox(width: Ds.space.x8),
        ],
        Text(value,
            style: (strong ? Ds.t.body : Ds.t.caption).copyWith(
                color: free ? Ds.c.brand : Ds.c.text,
                fontWeight: FontWeight.w700)),
      ]);

  Widget _line(Widget left, Widget right) => Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
        child: Row(children: [
          Expanded(child: left),
          SizedBox(width: Ds.space.x8),
          right,
        ]),
      );

  Future<void> _info(Map<String, dynamic> info) => showModalBottomSheet<void>(
        context: context,
        backgroundColor: Ds.c.surface,
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
        builder: (ctx) => Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(v2s(info, 'title'), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x8),
              Text(v2s(info, 'body'), style: Ds.t.body),
              SizedBox(height: Ds.space.x16),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(v2s(info, 'dismiss')),
                ),
              ),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final b = widget.block;
    if (b['has'] != true) return const SizedBox.shrink();
    final fees = v2List(b['fees']);
    final savings = v2Map(b['savings']);
    final cap = Ds.t.caption.copyWith(color: Ds.c.textSecondary);
    return _V2Card(
      semanticsId: 'cart_bill_v2',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(v2s(b, 'title'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x8),
        _line(Text(v2s(b, 'mrp_label'), style: cap),
            _amount('', v2s(b, 'mrp_value'), false)),
        _line(Text(v2s(b, 'sale_label'), style: cap),
            Text(v2s(b, 'sale_value'), style: cap)),
        if (b['fees_has'] == true) ...[
          Semantics(
            identifier: 'cart_bill_fees_toggle',
            button: true,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                child: _line(
                  Row(children: [
                    Text(v2s(b, 'fees_label'), style: cap),
                    Icon(_open ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                        size: Ds.space.x16, color: Ds.c.textSecondary),
                  ]),
                  _amount(v2s(b, 'fees_struck'), v2s(b, 'fees_value'),
                      b['fees_free'] == true),
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: !_open
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: EdgeInsets.only(left: Ds.space.x12),
                    child: Column(children: [
                      for (final f in fees)
                        _line(
                          Row(children: [
                            Flexible(
                                child: Text(v2s(f, 'label'),
                                    style: cap,
                                    overflow: TextOverflow.ellipsis)),
                            if (v2Map(f['info'])['has'] == true)
                              InkWell(
                                onTap: () => _info(v2Map(f['info'])),
                                child: Padding(
                                  padding: EdgeInsets.all(Ds.space.x4),
                                  child: Icon(Icons.info_outline,
                                      size: Ds.space.x12,
                                      color: Ds.c.textSecondary),
                                ),
                              ),
                          ]),
                          _amount(v2s(f, 'struck'), v2s(f, 'value'),
                              f['free'] == true),
                        ),
                    ]),
                  ),
          ),
        ],
        if (savings['has'] == true) ...[
          SizedBox(height: Ds.space.x4),
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x8),
            decoration: BoxDecoration(
                color: Ds.c.successSoft, borderRadius: Ds.r.rButton),
            child: Row(children: [
              Icon(Icons.savings_outlined,
                  size: Ds.space.x16, color: Ds.c.brand),
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: Text(v2s(savings, 'text'),
                    style: Ds.t.caption.copyWith(
                        color: Ds.c.brand, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ],
        SizedBox(height: Ds.space.x8),
        Divider(height: Ds.space.hairline, color: Ds.c.divider),
        SizedBox(height: Ds.space.x8),
        Row(children: [
          Expanded(
              child: Text(v2s(b, 'advance_label'),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w700))),
          Text(v2s(b, 'advance_value'),
              style: Ds.t.subtitle.copyWith(color: Ds.c.brand)),
        ]),
      ]),
    );
  }
}

class _V2Card extends StatelessWidget {
  final Widget child;
  final String semanticsId;
  const _V2Card({required this.child, this.semanticsId = ''});

  @override
  Widget build(BuildContext context) => Semantics(
        identifier: semanticsId.isEmpty ? null : semanticsId,
        child: Container(
          margin: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x8),
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1,
          ),
          child: child,
        ),
      );
}

// ── Receive mode ────────────────────────────────────────────────────────────

class CartReceiveBox extends StatelessWidget {
  final Map<String, dynamic> block;
  final ValueChanged<String> onSelect;
  final bool busy;
  const CartReceiveBox(
      {super.key, required this.block, required this.onSelect, this.busy = false});

  @override
  Widget build(BuildContext context) {
    if (block['has'] != true) return const SizedBox.shrink();
    final sel = v2s(block, 'selected');
    final opts = v2List(block['options']);
    final boxes = v2Map(block['boxes']);
    final keys = opts.map((o) => v2s(o, 'key')).toList();
    final idx = keys.indexOf(sel).clamp(0, keys.isEmpty ? 0 : keys.length - 1);
    return _V2Card(
      semanticsId: 'cart_receive',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(v2s(block, 'title'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < opts.length; i++) ...[
              if (i > 0) SizedBox(width: Ds.space.x8),
              Expanded(child: _option(opts[i], v2s(opts[i], 'key') == sel)),
            ],
          ]),
        ),
        SizedBox(height: Ds.space.x12),
        // Both boxes are laid out; the taller sets the height, so switching
        // mode never moves anything below.
        IndexedStack(
          index: idx,
          sizing: StackFit.loose,
          children: [for (final k in keys) _box(v2Map(boxes[k]))],
        ),
      ]),
    );
  }

  Widget _option(Map<String, dynamic> o, bool on) {
    final enabled = o['enabled'] == true && !busy;
    final k = v2s(o, 'key');
    return Semantics(
      identifier: 'cart_receive_$k',
      button: true,
      selected: on,
      child: InkWell(
        borderRadius: Ds.r.rButton,
        onTap: enabled && !on ? () => onSelect(k) : null,
        child: Opacity(
          opacity: o['enabled'] == true ? 1 : 0.5,
          child: Container(
            constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: on ? Ds.c.brandSoft : Ds.c.surface,
              borderRadius: Ds.r.rButton,
              border: Border.all(color: on ? Ds.c.brand : Ds.c.divider),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(v2Icon(v2s(o, 'icon')),
                          size: Ds.space.x16, color: Ds.c.brand),
                      SizedBox(height: Ds.space.x4),
                      Text(v2s(o, 'label'),
                          style: Ds.t.body
                              .copyWith(fontWeight: FontWeight.w700)),
                      Text(v2s(o, 'sub'),
                          style: Ds.t.caption
                              .copyWith(color: Ds.c.textSecondary)),
                    ]),
              ),
              Icon(on ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: Ds.space.x16,
                  color: on ? Ds.c.brand : Ds.c.textSecondary),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _box(Map<String, dynamic> b) => Container(
        padding: EdgeInsets.all(Ds.space.x12),
        decoration:
            BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rButton),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.location_on_outlined,
                size: Ds.space.x16, color: Ds.c.danger),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: '${v2s(b, 'lead')} '),
                  TextSpan(
                      text: v2s(b, 'name'),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  if (v2s(b, 'address').isNotEmpty)
                    TextSpan(text: '\n${v2s(b, 'address')}'),
                ]),
                style: Ds.t.caption.copyWith(color: Ds.c.text),
              ),
            ),
          ]),
          SizedBox(height: Ds.space.x8),
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x8, vertical: Ds.space.x4),
            decoration: BoxDecoration(
                color: Ds.c.warningSoft, borderRadius: Ds.r.rButton),
            child: Row(children: [
              Icon(Icons.payments_outlined,
                  size: Ds.space.x12, color: Ds.c.warning),
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: Text(v2s(b, 'note'),
                    style: Ds.t.caption.copyWith(
                        color: Ds.c.text, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ]),
      );
}

// ── Bottom bar ──────────────────────────────────────────────────────────────

class CartV2Bar extends StatelessWidget {
  final Map<String, dynamic> block;
  final VoidCallback? onPlace;
  final bool busy;
  const CartV2Bar(
      {super.key, required this.block, required this.onPlace, this.busy = false});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x12),
        child: Semantics(
          identifier: 'cart_place_order',
          button: true,
          child: Material(
            color: Ds.c.brand,
            borderRadius: Ds.r.rButton,
            child: InkWell(
              borderRadius: Ds.r.rButton,
              onTap: busy ? null : onPlace,
              child: Container(
                constraints: BoxConstraints(minHeight: Ds.space.x48),
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x16, vertical: Ds.space.x8),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(v2s(block, 'advance_label'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Ds.t.caption.copyWith(
                                color: Ds.c.surface.withValues(alpha: 0.85))),
                        Text(v2s(block, 'advance_value'),
                            maxLines: 1,
                            style: Ds.t.subtitle
                                .copyWith(color: Ds.c.surface)),
                      ],
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                  if (busy)
                    SizedBox(
                      width: Ds.space.x24,
                      height: Ds.space.x24,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Ds.c.surface),
                    )
                  else ...[
                    Text(v2s(block, 'place'),
                        style: Ds.t.body.copyWith(
                            color: Ds.c.surface, fontWeight: FontWeight.w700)),
                    Icon(Icons.chevron_right,
                        size: Ds.space.x24, color: Ds.c.surface),
                  ],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── The one mini popup ──────────────────────────────────────────────────────

/// Shows a `{icon, tone, title, body, chip, primary, secondary}` popup and
/// returns 'primary', 'secondary' or null (dismissed).
Future<String?> showCartV2Popup(BuildContext context, Map<String, dynamic> p,
    {bool dangerPrimary = false}) {
  final tone = v2Tone(v2s(p, 'tone'));
  final primary = v2Map(p['primary']);
  final secondary = v2Map(p['secondary']);
  final chip = v2s(p, 'chip');
  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Padding(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Container(
        padding: EdgeInsets.all(Ds.space.x24),
        decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e2),
        child: Semantics(
          identifier: 'cart_popup_${v2s(p, 'key')}',
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: Ds.space.x48,
              height: Ds.space.x48,
              decoration:
                  BoxDecoration(color: tone.bg, shape: BoxShape.circle),
              child: Icon(v2Icon(v2s(p, 'icon')),
                  color: tone.fg, size: Ds.space.x24),
            ),
            SizedBox(height: Ds.space.x12),
            Text(v2s(p, 'title'),
                textAlign: TextAlign.center, style: Ds.t.subtitle),
            if (v2s(p, 'body').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(v2s(p, 'body'),
                  textAlign: TextAlign.center,
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            ],
            if (chip.isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x8),
                decoration: BoxDecoration(
                    color: Ds.c.bg, borderRadius: Ds.r.rButton),
                child: Text(chip,
                    textAlign: TextAlign.center,
                    style: Ds.t.caption.copyWith(color: Ds.c.text)),
              ),
            ],
            SizedBox(height: Ds.space.x16),
            Row(children: [
              if (secondary['has'] == true) ...[
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: Semantics(
                      identifier: 'cart_popup_secondary',
                      button: true,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, 'secondary'),
                        child: Text(v2s(secondary, 'label'),
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
              ],
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: Semantics(
                    identifier: 'cart_popup_primary',
                    button: true,
                    child: FilledButton(
                      style: dangerPrimary
                          ? FilledButton.styleFrom(
                              backgroundColor: Ds.c.danger)
                          : null,
                      onPressed: () => Navigator.pop(ctx, 'primary'),
                      child: Text(v2s(primary, 'label'),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ),
    ),
  );
}
