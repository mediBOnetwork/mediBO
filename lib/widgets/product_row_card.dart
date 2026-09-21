import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product.dart';
import '../utils/render_log.dart';
import 'product_image.dart';
import 'qty_picker.dart';

/// CMD #2123 — THE ROW VARIANT OF THE ONE PRODUCT CARD.
///
/// The grid card (`CompactProductCard`, CMD #2122) is the product standing on
/// its own. This is the SAME card lying down, for the two lists where a
/// product is one line of something bigger: the cart and the Bulk Upload
/// review list. Both used to draw their own four-line row; neither does now.
///
///   photo  │ 1  name                  (one line, ellipsis)
///          │ 2  composition / qty     (one line, ellipsis — the caller's
///          │                           backend string)
///          │ 3  sale price badge      (number, or the locked word "PTR")
///          │ 4  control / state       (the cart's qty chip, Bulk Upload's
///          │                           availability badge)
///
/// The photo is exactly as tall as the four lines beside it. Everything the
/// row prints is a payload string handed in by the surface; this widget
/// words nothing, computes no money and never asks which price it holds.
///
/// What stays the surface's own is only what the surface IS: the cart's ✕
/// and bottom bar, Bulk Upload's handwriting crop, checkbox, retry and
/// confidence bar. Those sit around the card, never inside it.
class ProductRowCard extends StatelessWidget {
  final Product product;

  /// Line 1 — the product's name, as the payload printed it.
  final String name;

  /// Line 2 — one backend line (composition for the cart and for a Bulk
  /// Upload alternative; "17 strip" for the Bulk Upload match). Empty is
  /// absence: the slot holds its height and draws nothing.
  final String line2;

  /// Line 3 — the sale-price badge. Built from the payload with
  /// [RowPriceBadge.fromCardPrice] or [RowPriceBadge.fromMap].
  final Widget? price;

  /// Line 4 — the quantity chip ([RowQtyChip]) or a state badge
  /// ([RowStateBadge]).
  final Widget? line4;

  /// True when line 4 is a control, so it gets a full 44px touch height and
  /// the photo grows to match. A status line stays one text line tall.
  final bool line4IsControl;

  /// The Rx corner badge — `{has, label, tone:{bg,fg}}` as the payload sent
  /// it. Empty draws no badge.
  final Map<String, dynamic> rx;

  /// Opens the product page. Null keeps the photo inert.
  final VoidCallback? onOpen;

  /// Whether tapping the name opens the product too (the cart), or only the
  /// photo does (Bulk Upload, where the text belongs to the row it sits in).
  final bool nameOpens;
  final String openSemanticsId;
  final String openHint;

  /// The surface's own control at the far right (the cart's ✕ / checkbox).
  final Widget? trailing;

  /// Which list this card is drawn in, for the render-log proof only.
  final String surface;

  const ProductRowCard({
    super.key,
    required this.product,
    required this.name,
    required this.line2,
    required this.surface,
    this.price,
    this.line4,
    this.line4IsControl = false,
    this.rx = const {},
    this.onOpen,
    this.nameOpens = false,
    this.openSemanticsId = '',
    this.openHint = '',
    this.trailing,
    this.inlineControl = false,
  });

  /// CMD #2139 — the cart row: three lines, the control sits on the price
  /// line beside the badge, and the photo is exactly those three lines tall.
  final bool inlineControl;

  /// One text line of the block.
  static double get lineH => Ds.space.x24;

  /// The block's height — and therefore the photo's side.
  static double blockHeight({bool controlLine = false}) =>
      lineH * 3 + (controlLine ? Ds.touch.minTarget : lineH);

  @override
  Widget build(BuildContext context) {
    try {
      RenderLog.write('c2123_row_card_$surface', '1');
    } catch (_) {}
    final side = inlineControl
        ? lineH * 2 + Ds.touch.minTarget
        : blockHeight(controlLine: line4IsControl);
    Widget nameText = Text(
      name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Ds.t.body.copyWith(color: Ds.c.text, fontWeight: FontWeight.w700),
    );
    if (nameOpens && onOpen != null) {
      nameText = GestureDetector(
          behavior: HitTestBehavior.opaque, onTap: onOpen, child: nameText);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        identifier: openSemanticsId.isEmpty ? null : openSemanticsId,
        button: onOpen != null,
        label: openHint.isEmpty ? null : openHint,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(Ds.r.button),
          child: RowThumb(product: product, rx: rx, side: side),
        ),
      ),
      SizedBox(width: Ds.space.x12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _RowLine(height: lineH, child: nameText),
            _RowLine(
              height: lineH,
              child: line2.isEmpty
                  ? const SizedBox.shrink()
                  : Text(line2,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.caption),
            ),
            if (inlineControl)
              _RowLine(
                height: Ds.touch.minTarget,
                child: Row(children: [
                  Flexible(child: price ?? const SizedBox.shrink()),
                  SizedBox(width: Ds.space.x8),
                  ?line4,
                ]),
              )
            else ...[
              _RowLine(height: lineH, child: price ?? const SizedBox.shrink()),
              _RowLine(
                height: line4IsControl ? Ds.touch.minTarget : lineH,
                child: line4 ?? const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ),
      if (trailing != null) trailing!,
    ]);
  }
}

/// A backend colour as either wire shape: `'#RRGGBB'` (cart_render) or a
/// packed ARGB int (the product models, cart_availability).
Color rowTone(Object? raw, Color fallback) {
  if (raw is int) return Color(raw);
  if (raw is num) return Color(raw.toInt());
  return Ds.hex(raw, fallback);
}

/// One fixed-height line, so a line the payload left empty still holds its
/// place and the photo ends on the same baseline as line 4.
class _RowLine extends StatelessWidget {
  final double height;
  final Widget child;
  const _RowLine({required this.height, required this.child});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: Align(alignment: Alignment.centerLeft, child: child),
      );
}

/// The row card's photo: a bordered tile sized to the text block, with the
/// payload's Rx badge on its corner when it sent one.
class RowThumb extends StatelessWidget {
  final Product product;
  final Map<String, dynamic> rx;
  final double side;
  const RowThumb(
      {super.key, required this.product, required this.side, this.rx = const {}});

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      width: side,
      height: side,
      padding: EdgeInsets.all(Ds.space.x4),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.button),
        border: Border.all(color: Ds.c.divider),
      ),
      child: ProductImage(
        url: product.imageUrl,
        width: side - Ds.space.x12,
        height: side - Ds.space.x12,
        radius: BorderRadius.circular(Ds.r.chip),
      ),
    );
    final label = (rx['label'] ?? '').toString();
    if (rx['has'] != true || label.isEmpty) return tile;
    final tone = (rx['tone'] as Map?)?.cast<String, dynamic>();
    return Stack(clipBehavior: Clip.none, children: [
      tile,
      Positioned(
        top: -Ds.space.x4,
        left: -Ds.space.x4,
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x4 + Ds.space.hairline,
              vertical: Ds.space.hairline),
          decoration: BoxDecoration(
            color: rowTone(tone?['bg'], Ds.c.info),
            borderRadius: BorderRadius.circular(Ds.r.chip),
          ),
          child: Text(label,
              style: Ds.t.caption.copyWith(
                  color: rowTone(tone?['fg'], Ds.c.surface),
                  fontWeight: FontWeight.w700)),
        ),
      ),
    ]);
  }
}

/// Line 3 — ONE filled badge, the sale price and nothing else.
///
/// `value` is already the right answer for THIS viewer — the formatted amount
/// for an approved buyer, the locked word for everyone else — so nothing here
/// asks which it is holding and no PTR number can reach a viewer the backend
/// withheld it from. FittedBox rather than an ellipsis (CMD #2119): on a very
/// narrow phone the whole badge scales down together.
class RowPriceBadge extends StatelessWidget {
  final String label;
  final String value;
  final Object? bg;
  final Object? fg;
  const RowPriceBadge(
      {super.key, required this.label, required this.value, this.bg, this.fg});

  /// The grid card's own price block (`card.price` / `pricing.card_price`).
  static Widget fromCardPrice(CardPrice? p) => p == null
      ? const SizedBox.shrink()
      : RowPriceBadge(
          label: p.saleLabel, value: p.priceDisplay, bg: p.saleBg, fg: p.saleFg);

  /// cart_row_block()'s `sale_badge` — the same card_price, as a map.
  static Widget fromMap(Map<String, dynamic> badge) => badge['has'] != true
      ? const SizedBox.shrink()
      : RowPriceBadge(
          label: (badge['label'] ?? '').toString(),
          value: (badge['value'] ?? '').toString(),
          bg: badge['bg'],
          fg: badge['fg']);

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) return const SizedBox.shrink();
    final ink = rowTone(fg, Ds.c.surface);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.hairline),
        decoration: BoxDecoration(
          color: rowTone(bg, Ds.c.brand),
          borderRadius: BorderRadius.circular(Ds.r.chip),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (label.isNotEmpty) ...[
            Text(label,
                maxLines: 1,
                softWrap: false,
                style: Ds.t.caption.copyWith(color: ink)),
            SizedBox(width: Ds.space.x4),
          ],
          Text(value,
              maxLines: 1,
              softWrap: false,
              style: Ds.t.caption
                  .copyWith(color: ink, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

/// Line 4 as a status: one word and the two colours that came with it
/// (Bulk Upload's Available / Unavailable).
class RowStateBadge extends StatelessWidget {
  final String label;
  final Object? bg;
  final Object? fg;
  final bool available;
  const RowStateBadge(
      {super.key,
      required this.label,
      this.bg,
      this.fg,
      this.available = true});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4 / 2),
      decoration: BoxDecoration(
        color: rowTone(bg, available ? Ds.c.success : Ds.c.danger),
        borderRadius: BorderRadius.circular(Ds.r.chip),
      ),
      child: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Ds.t.caption.copyWith(
              color: rowTone(fg, Ds.c.surface), fontWeight: FontWeight.w600)),
    );
  }
}

/// The chip's ONE decision, pure so it can be held down (CMD #2120).
///
/// After a pick the chip prints the label the PICKER handed back (still a
/// backend string) until the payload's own label changes — the server
/// answering, whatever it answered.
String? rowQtyPendingAfterPayload(
        {required String? pending,
        required String oldLabel,
        required String newLabel}) =>
    oldLabel == newLabel ? pending : null;

String rowQtyChipText({required String? pending, required String payload}) =>
    (pending != null && pending.isNotEmpty) ? pending : payload;

/// Line 4 as a control: quantity + pack as an outlined chip with a chevron.
///
/// `chip` is `{has, label, qty, pack_type, hint}` — the label is
/// bulk_qty_line()'s template ("5 strip"), never composed here. Tapping opens
/// the ONE quantity popup (`showQtyPickerChoice`) centred on `qty`. `locked`
/// is the backend's flag, carried: the chip is dead and tinted danger.
class RowQtyChip extends StatefulWidget {
  final Map<String, dynamic> chip;
  final bool locked;
  final ValueChanged<int> onPicked;
  final String semanticsId;
  const RowQtyChip({
    super.key,
    required this.chip,
    required this.onPicked,
    this.locked = false,
    this.semanticsId = 'cart_qty_chip',
    this.pickerRpc = '',
    this.compact = false,
  });

  /// CMD #2139 — non-empty opens the backend's sheet (e.g. `cart_qty_picker`,
  /// which ends with "Remove from cart") instead of the plain dialog.
  final String pickerRpc;

  /// Badge-height chip, centred in a full touch target.
  final bool compact;

  @override
  State<RowQtyChip> createState() => _RowQtyChipState();
}

class _RowQtyChipState extends State<RowQtyChip> {
  String? _pending;

  @override
  void didUpdateWidget(RowQtyChip old) {
    super.didUpdateWidget(old);
    _pending = rowQtyPendingAfterPayload(
        pending: _pending,
        oldLabel: _label(old.chip),
        newLabel: _label(widget.chip));
  }

  static String _label(Map<String, dynamic> m) => (m['label'] ?? '').toString();

  Future<void> _open() async {
    final packType = (widget.chip['pack_type'] ?? '').toString();
    final current = (widget.chip['qty'] as num?)?.toInt() ?? 0;
    final picked = widget.pickerRpc.isNotEmpty
        ? await showCardQtyPicker(context,
            packType: packType, current: current, rpc: widget.pickerRpc)
        : await showQtyPickerChoice(context,
            packType: packType, current: current);
    if (picked == null || !mounted) return;
    setState(() => _pending = picked.label);
    widget.onPicked(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chip['has'] != true) return const SizedBox.shrink();
    final text = rowQtyChipText(pending: _pending, payload: _label(widget.chip));
    if (text.isEmpty) return const SizedBox.shrink();
    final tint = widget.locked ? Ds.c.danger : Ds.c.brand;
    return Semantics(
      identifier: widget.semanticsId,
      button: true,
      label: (widget.chip['hint'] ?? '').toString(),
      child: InkWell(
        onTap: widget.locked ? null : _open,
        borderRadius: BorderRadius.circular(Ds.r.chip),
        child: SizedBox(
          height: Ds.touch.minTarget,
          child: Center(
            widthFactor: 1,
            child: _chipBody(text, tint))),
      ),
    );
  }

  Widget _chipBody(String text, Color tint) => Container(
          height: widget.compact ? Ds.space.x24 : Ds.touch.minTarget,
          padding: EdgeInsets.symmetric(
              horizontal: widget.compact ? Ds.space.x8 : Ds.space.x12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Ds.r.chip),
            border: Border.all(color: tint),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (widget.compact ? Ds.t.caption : Ds.t.body)
                      .copyWith(color: tint, fontWeight: FontWeight.w600)),
            ),
            SizedBox(width: Ds.space.x4),
            Icon(Icons.keyboard_arrow_down, size: Ds.space.x16, color: tint),
          ]),
        );
}
