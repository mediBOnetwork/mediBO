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

/// Every active discount slab, one at a time, rolling on the backend's
/// interval. `has:false` draws nothing.
///
/// CMD #2162 — one slide is ONE row: the orange pill carries `lead` ("5% CD")
/// and the text carries `rest` only, so the discount is never said twice.
/// Every `interval_ms` the whole row rolls: the current row moves up and fades
/// out while the next rises from below and fades in, together, over
/// [kCdRollMs]. Everything is clipped inside the strip. Touch pauses the roll,
/// reduced motion cross-fades in place, and a single slab never moves.
class CartCdStrip extends StatefulWidget {
  final Map<String, dynamic> block;
  const CartCdStrip({super.key, required this.block});

  @override
  State<CartCdStrip> createState() => _CartCdStripState();
}

/// CMD #2162 — how long one roll between two slides lasts.
const int kCdRollMs = 400;

class _CartCdStripState extends State<CartCdStrip>
    with SingleTickerProviderStateMixin {
  Timer? _t;
  int _i = 0;
  int? _prev;
  bool _held = false;

  late final AnimationController _roll = AnimationController(
      vsync: this, duration: const Duration(milliseconds: kCdRollMs))
    ..addStatusListener((st) {
      if (st == AnimationStatus.completed && mounted) {
        setState(() => _prev = null);
      }
    });

  List<Map<String, dynamic>> get _slides => v2List(widget.block['slides']);

  bool get _showing => widget.block['has'] == true && _slides.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(CartCdStrip old) {
    super.didUpdateWidget(old);
    if (_i >= _slides.length) _i = 0;
    if (_prev != null && _prev! >= _slides.length) _prev = null;
    if (old.block['interval_ms'] != widget.block['interval_ms'] ||
        v2List(old.block['slides']).length != _slides.length) {
      _arm();
    }
  }

  void _arm() {
    _t?.cancel();
    final ms = (widget.block['interval_ms'] as num?)?.toInt() ?? 0;
    // One slab (or none) is static: no timer at all.
    if (ms <= 0 || _slides.length < 2) return;
    _t = Timer.periodic(Duration(milliseconds: ms), (_) => _next());
  }

  void _next() {
    if (!mounted || _held || !_showing) return;
    final n = _slides.length;
    if (n < 2) return;
    setState(() {
      _prev = _i;
      _i = (_i + 1) % n;
    });
    RenderLog.write('c2162_cd_roll', '$_i');
    _roll.forward(from: 0);
  }

  @override
  void dispose() {
    _t?.cancel();
    _roll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final slides = _slides;
    if (!_showing) {
      return const SizedBox.shrink();
    }
    final ink = Ds.c.warning;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final cur = _i % slides.length;
    return Semantics(
      identifier: 'cart_cd_strip',
      child: Listener(
        onPointerDown: (_) => _held = true,
        onPointerUp: (_) => _held = false,
        onPointerCancel: (_) => _held = false,
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
            Expanded(
              // Clipped: a rolling row never paints past the strip's edge.
              child: ClipRect(
                child: AnimatedBuilder(
                  animation: _roll,
                  builder: (context, _) {
                    final t = Curves.easeInOut.transform(_roll.value);
                    final moving = _prev != null && _roll.isAnimating;
                    return Stack(children: [
                      if (moving)
                        Positioned.fill(
                          child: CdRollRow(
                            slide: slides[_prev!],
                            ink: ink,
                            dy: reduce ? 0 : -t,
                            opacity: 1 - t,
                          ),
                        ),
                      CdRollRow(
                        key: ValueKey('cd_row_$cur'),
                        slide: slides[cur],
                        ink: ink,
                        dy: moving && !reduce ? 1 - t : 0,
                        opacity: moving ? t : 1,
                      ),
                    ]);
                  },
                ),
              ),
            ),
            SizedBox(width: Ds.space.x8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var k = 0; k < slides.length; k++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: kCdRollMs),
                    curve: Curves.easeInOut,
                    margin: EdgeInsets.only(left: k == 0 ? 0 : Ds.space.x4 / 2),
                    width: k == cur ? Ds.space.x16 : Ds.space.x4,
                    height: Ds.space.x4,
                    decoration: BoxDecoration(
                      color: k == cur ? ink : ink.withValues(alpha: 0.35),
                      borderRadius: Ds.r.rChip,
                    ),
                  ),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

/// CMD #2162 — one CD slide: the orange `lead` pill, then `rest`. [dy] is a
/// fraction of the row's own height (−1 = one row up, +1 = one row below),
/// so the pill and the text always travel together.
class CdRollRow extends StatelessWidget {
  final Map<String, dynamic> slide;
  final Color ink;
  final double dy;
  final double opacity;
  const CdRollRow(
      {super.key,
      required this.slide,
      required this.ink,
      this.dy = 0,
      this.opacity = 1});

  @override
  Widget build(BuildContext context) {
    return FractionalTranslation(
      translation: Offset(0, dy),
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Row(children: [
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x8, vertical: Ds.space.x4),
            decoration: BoxDecoration(color: ink, borderRadius: Ds.r.rChip),
            child: Text(v2s(slide, 'lead'),
                maxLines: 1,
                softWrap: false,
                style: Ds.t.caption.copyWith(
                    color: Ds.c.surface, fontWeight: FontWeight.w700)),
          ),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Text(v2s(slide, 'rest'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption.copyWith(color: Ds.c.text)),
          ),
        ]),
      ),
    );
  }
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
        // CMD #2152 — every enabled option takes the tap, including the one
        // already selected (the save is idempotent), so the tap always lands.
        onTap: enabled ? () => onSelect(k) : null,
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
          // CMD #2162 — two lines: the green advance badge, then the orange
          // remaining-due badge. Words are the backend's.
          ...CartModeBadges.lines(b),
        ]),
      );
}

/// CMD #2162 — the payment lines for a receive mode: a green badge for
/// `advance_note` ("Pay advance now") and an orange one for `note` (the
/// remaining due). Shared by the receive box and the Place order popup, so
/// both always say the same thing. An empty field draws nothing.
class CartModeBadges {
  CartModeBadges._();

  static List<Widget> lines(Map<String, dynamic> b) => [
        if (v2s(b, 'advance_note').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          _badge(v2s(b, 'advance_note'), Icons.check_circle_outline,
              Ds.c.successSoft, Ds.c.brand, 'cart_mode_advance'),
        ],
        if (v2s(b, 'note').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          _badge(v2s(b, 'note'), Icons.payments_outlined, Ds.c.warningSoft,
              Ds.c.warning, 'cart_mode_due'),
        ],
      ];

  static Widget _badge(
          String text, IconData icon, Color bg, Color ink, String id) =>
      Semantics(
        identifier: id,
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x8, vertical: Ds.space.x4),
          decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rButton),
          child: Row(children: [
            Icon(icon, size: Ds.space.x12, color: ink),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: Text(text,
                  style: Ds.t.caption
                      .copyWith(color: Ds.c.text, fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
      );

  /// The popup's block for the SELECTED mode: bold title with its icon, then
  /// the two badges.
  static Widget modeBlock(Map<String, dynamic> m) => Semantics(
        identifier: 'cart_popup_mode',
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.all(Ds.space.x12),
          decoration:
              BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rButton),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(v2Icon(v2s(m, 'icon')),
                      size: Ds.space.x16, color: Ds.c.brand),
                  SizedBox(width: Ds.space.x8),
                  Expanded(
                    child: Text(v2s(m, 'title'),
                        style:
                            Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
                  ),
                ]),
                ...lines(m),
              ]),
        ),
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
  final mode = v2Map(p['mode']);
  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    // CMD #2162 — the mode block made the sheet taller than the default 9/16
    // cap on short phones; size to content and scroll if a phone is shorter.
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SingleChildScrollView(
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
            // CMD #2162 — the selected receive mode as three lines replaces
            // the one-line chip whenever the backend sends it.
            if (mode['has'] == true) ...[
              SizedBox(height: Ds.space.x12),
              CartModeBadges.modeBlock(mode),
            ] else if (chip.isNotEmpty) ...[
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
