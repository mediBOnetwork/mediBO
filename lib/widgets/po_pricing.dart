import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// CHANGE #353 (feature_gaps #29 / #59) — how a supplier purchase order says
/// what it is priced on.
///
/// The PO used to be totalled at MRP * qty, because a supplier could only ever
/// answer "Available / Out of Stock / We don't stock this" — there was no rate
/// field anywhere in the answer path. MRP is the printed legal ceiling, never
/// the selling price, so every figure on the document was wrong.
///
/// Both widgets here PRINT and nothing else: the basis label, its tone, the
/// payable figure, the per-line rate, the line total and the MRP note all
/// arrive from `po_pricing_block()` / `po_retotal()`. Nothing is computed,
/// formatted or worded in Dart — a ₹ string is never built here.
class PoPricingBanner extends StatelessWidget {
  /// The `pricing` block from supplier_my_orders() / sup_order_bill_panel().
  final Map<String, dynamic>? pricing;
  const PoPricingBanner({super.key, required this.pricing});

  @override
  Widget build(BuildContext context) {
    final p = pricing;
    // An older backend sends no block at all: the banner is ABSENT, never a
    // half-worded default.
    if (p == null || p['has'] != true) return const SizedBox.shrink();
    final label = (p['label'] as String?) ?? '';
    if (label.isEmpty) return const SizedBox.shrink();

    final tone = (p['tone'] as String?) ?? 'info';
    final bg = tone == 'success'
        ? Ds.c.successSoft
        : tone == 'warning'
            ? Ds.c.warningSoft
            : Ds.c.infoSoft;
    RenderLog.write('c353_po_pricing_basis', '${p['basis']}');

    final payableLabel = (p['payable_label'] as String?) ?? '';
    final payable = (p['payable_display'] as String?) ?? '';
    final mrpNote = (p['mrp_note'] as String?) ?? '';

    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rCard),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Ds.t.bodyStrong),
        if (payable.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Row(children: [
            Expanded(child: Text(payableLabel, style: Ds.t.caption)),
            Text(payable, style: Ds.t.bodyStrong),
          ]),
        ],
        if (mrpNote.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(mrpNote, style: Ds.t.caption),
        ],
      ]),
    );
  }
}

/// One PO line's rate, where that rate came from, and the line total.
class PoRateLine extends StatelessWidget {
  /// One element of the PO's `items[]`.
  final Map<String, dynamic> item;
  const PoRateLine({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final rate = (item['rate_display'] as String?) ?? '';
    final basis = (item['price_basis_label'] as String?) ?? '';
    final total = (item['line_total_display'] as String?) ?? '';
    if (rate.isEmpty && basis.isEmpty && total.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(Ds.space.x16, 0, Ds.space.x16, Ds.space.x12),
      child: Row(children: [
        Expanded(child: Text(basis, style: Ds.t.caption)),
        SizedBox(width: Ds.space.x8),
        Text(rate, style: Ds.t.body),
        SizedBox(width: Ds.space.x12),
        Text(total, style: Ds.t.bodyStrong),
      ]),
    );
  }
}
