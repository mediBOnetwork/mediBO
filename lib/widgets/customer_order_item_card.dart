import 'package:flutter/material.dart';

import 'product_image.dart';

/// CHANGE #641 — one item card for the customer's Orders → Items list.
///
/// This widget renders. It does not decide. Every string it prints arrives
/// already worded, already formatted and already cased from
/// `my_orders_screen().lines` / `.unfulfilled_lines`:
///
///   * `qty_label`  — "2 Tubes", unit word and plural chosen server-side
///   * `rate_label` — "₹69.38", currency symbol and rounding server-side
///   * `line_label` — "₹138.76"
///   * `status_label` — "Available" / "Confirmation Pending" /
///     "No Supplier Available", printed VERBATIM. Nothing here substitutes a
///     word, and nothing maps a status to a colour: the chip's hexes travel
///     with the line.
///
/// It was extracted from `orders_screen.dart` so the layout is reachable from a
/// widget test without booting the whole Orders screen.
class CustomerOrderItem {
  final String name;
  final String company;
  final String packLabel;
  final String qtyLabel;
  final String rateLabel;
  final String lineLabel;
  final String imageUrl;
  final String statusLabel;
  final String statusTone;
  final String statusBg;
  final String statusFg;

  const CustomerOrderItem({
    this.name = '',
    this.company = '',
    this.packLabel = '',
    this.qtyLabel = '',
    this.rateLabel = '',
    this.lineLabel = '',
    this.imageUrl = '',
    this.statusLabel = '',
    this.statusTone = '',
    this.statusBg = '',
    this.statusFg = '',
  });

  /// The ONE parser for an item row. `lines` and `unfulfilled_lines` carry an
  /// identical shape, so there is exactly one place that can read a line wrong.
  ///
  /// The payload promises `""` rather than `null` for the optional fields, but
  /// `?? ''` still guards every one of them: a row written before #641 simply
  /// lacks the key, and an absent key must read as an absence, not a crash.
  factory CustomerOrderItem.fromPayload(Map<String, dynamic> j) {
    final colors = j['status_colors'] is Map
        ? (j['status_colors'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return CustomerOrderItem(
      name: (j['name'] ?? '').toString(),
      company: (j['company'] ?? '').toString(),
      packLabel: (j['pack_label'] ?? '').toString(),
      qtyLabel: (j['qty_label'] ?? '').toString(),
      rateLabel: (j['rate_label'] ?? '').toString(),
      lineLabel: (j['line_label'] ?? '').toString(),
      imageUrl: (j['image_url'] ?? '').toString(),
      // Falls back to the older `status_text` key so a stale payload still
      // shows the real words rather than an empty chip — never to a word
      // invented here.
      statusLabel: (j['status_label'] ?? j['status_text'] ?? '').toString(),
      statusTone: (j['status_tone'] ?? '').toString(),
      statusBg: (colors['bg'] ?? '').toString(),
      statusFg: (colors['fg'] ?? '').toString(),
    );
  }
}

class CustomerOrderItemCard extends StatelessWidget {
  final CustomerOrderItem item;
  const CustomerOrderItemCard({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final l = item;
    // `width: double.infinity` is the fix for the desktop regression: without
    // it this Container shrinks to its widest child inside a
    // CrossAxisAlignment.start Column, which is why the card looked full-bleed
    // on a phone and collapsed to a stub on the web. Stating the width here
    // makes the card fill its parent whatever the parent's alignment is, so the
    // two widths cannot drift apart again.
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // The slot is 72x72 whether or not there is an image: ProductImage
        // reserves the box before the bytes land and renders its own neutral
        // fallback for "" (the backend's explicit "no image"), so a missing
        // image can never collapse the slot or reflow the list.
        ProductImage(
          url: l.imageUrl,
          width: 72,
          height: 72,
          fit: BoxFit.cover,
          radius: BorderRadius.circular(10),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                    color: Color(0xFF111827))),
            // Already upper-cased server-side. Dart does not .toUpperCase() —
            // casing is a display decision the payload already made.
            if (l.company.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(l.company,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
              ),
            // Omitted entirely when the medicine carries no pack — no blank
            // line, no reserved gap.
            if (l.packLabel.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(l.packLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
              ),
            const SizedBox(height: 8),
            Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 4,
                children: [
                  // qty_label already reads "2 Tubes" — the unit word and its
                  // plural were decided server-side.
                  if (l.qtyLabel.isNotEmpty)
                    Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                          color: const Color(0xFFF3F4F6),
                          borderRadius: BorderRadius.circular(6)),
                      child: Text(l.qtyLabel,
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF374151))),
                    ),
                  if (l.rateLabel.isNotEmpty)
                    Text(l.rateLabel,
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF6B7280))),
                  if (l.lineLabel.isNotEmpty)
                    Text(l.lineLabel,
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF111827))),
                ]),
            // The status chip sits on its own line below the money row. Its
            // words are status_label verbatim and its colours came with the
            // line, so "Available" is never substituted for anything else.
            if (l.statusLabel.isNotEmpty) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: LineStatusChip(
                    text: l.statusLabel, bg: l.statusBg, fg: l.statusFg),
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Words and both colours arrive together on the line. Recolouring a status is
/// an UPDATE to `app_settings.item_status_tones`, never a deploy.
class LineStatusChip extends StatelessWidget {
  final String text;
  final String bg;
  final String fg;
  const LineStatusChip(
      {super.key, required this.text, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: hexColor(bg, fallback: const Color(0xFFF3F4F6)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: hexColor(fg, fallback: const Color(0xFF374151)))),
    );
  }
}

/// "#RRGGBB" → Color. An unreadable value falls back rather than throwing: a
/// bad hex must not blank an order.
Color hexColor(String hex, {required Color fallback}) {
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return fallback;
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(v);
}
