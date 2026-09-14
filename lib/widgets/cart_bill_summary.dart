// CMD #2014 — the cart's bill summary card.
//
// Every row in this card is a row of `cart_bill_row`: its label, its icon
// name, its position, whether it shows at all, whether its amount is a stored
// constant / a computed basket variable / an admin's formula, whether it is
// waived, and the copy of the popup it opens. An admin changes any of those in
// the admin app and the next cart_bill_view() reflects it — there is no deploy
// in that loop, and there is no number, word or ₹ sign computed here.
//
// This widget therefore does exactly three things: it lays the rows out, it
// maps a backend icon NAME to a glyph (an unknown name renders no icon rather
// than a guessed one, so a new row can ship to an old build), and it opens the
// dialog the backend wrote when a row says it is tappable.

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// One row of the bill, straight from the payload.
class BillRow {
  final String key;
  final String label;
  final String icon;

  /// The amount to print. Empty when the row is waived — a waived row prints
  /// [struckValue] with a line through it followed by [freeLabel] instead.
  final String value;
  final String struckValue;
  final String freeLabel;
  final bool waived;

  /// 'default' | 'brand' | 'total' — chosen by the backend, never inferred
  /// from the row's key here.
  final String tone;
  final bool bold;
  final bool dividerBefore;
  final bool tappable;
  final String popupTitle;
  final String popupBody;
  final String popupDismiss;

  const BillRow({
    required this.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.struckValue,
    required this.freeLabel,
    required this.waived,
    required this.tone,
    required this.bold,
    required this.dividerBefore,
    required this.tappable,
    required this.popupTitle,
    required this.popupBody,
    required this.popupDismiss,
  });

  factory BillRow.fromMap(Map<String, dynamic> m) {
    final popup = m['popup'] is Map
        ? Map<String, dynamic>.from(m['popup'] as Map)
        : const <String, dynamic>{};
    return BillRow(
      key: (m['key'] ?? '').toString(),
      label: (m['label'] ?? '').toString(),
      icon: (m['icon'] ?? '').toString(),
      value: (m['value'] ?? '').toString(),
      struckValue: (m['struck_value'] ?? '').toString(),
      freeLabel: (m['free_label'] ?? '').toString(),
      waived: m['waived'] == true,
      tone: (m['tone'] ?? '').toString(),
      bold: m['bold'] == true,
      dividerBefore: m['divider_before'] == true,
      tappable: m['tappable'] == true,
      popupTitle: (popup['title'] ?? '').toString(),
      popupBody: (popup['body'] ?? '').toString(),
      popupDismiss: (popup['dismiss'] ?? '').toString(),
    );
  }
}

/// The whole block: title + rows, or nothing at all when the backend says the
/// basket has no bill to show yet.
class CartBillSummary extends StatelessWidget {
  final String title;
  final List<BillRow> rows;

  const CartBillSummary({super.key, required this.title, required this.rows});

  /// Builds the block from the `bill` object of cart_bill_view(). Returns null
  /// when there is nothing to draw, so the caller can omit it entirely rather
  /// than render an empty card.
  static CartBillSummary? fromPayload(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    if (m['has'] != true) return null;
    final list = (m['rows'] as List?) ?? const [];
    final rows = list
        .whereType<Map>()
        .map((e) => BillRow.fromMap(Map<String, dynamic>.from(e)))
        .toList();
    if (rows.isEmpty) return null;
    return CartBillSummary(title: (m['title'] ?? '').toString(), rows: rows);
  }

  /// Backend icon NAME → glyph. An unrecognised name deliberately maps to
  /// null: the row still renders, just without a leading glyph.
  static const Map<String, IconData> _glyphs = <String, IconData>{
    'local_offer_outlined': Icons.local_offer_outlined,
    'sell_outlined': Icons.sell_outlined,
    'account_balance_wallet_outlined': Icons.account_balance_wallet_outlined,
    'inventory_2_outlined': Icons.inventory_2_outlined,
    'local_shipping_outlined': Icons.local_shipping_outlined,
    'receipt_long_outlined': Icons.receipt_long_outlined,
    'receipt_long': Icons.receipt_long,
    'percent_outlined': Icons.percent_outlined,
    'savings_outlined': Icons.savings_outlined,
    'discount_outlined': Icons.discount_outlined,
    'payments_outlined': Icons.payments_outlined,
    'info_outline': Icons.info_outline,
  };

  static IconData? glyphFor(String name) => _glyphs[name];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(
          Ds.space.x12, Ds.space.x8, Ds.space.x12, Ds.space.x8),
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title.isNotEmpty) ...[
            Text(title, style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
          ],
          for (final r in rows) _BillRowTile(row: r),
        ],
      ),
    );
  }
}

class _BillRowTile extends StatelessWidget {
  final BillRow row;
  const _BillRowTile({required this.row});

  void _openPopup(BuildContext context) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        backgroundColor: Ds.c.surface,
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
        titlePadding: EdgeInsets.fromLTRB(
            Ds.space.x24, Ds.space.x24, Ds.space.x24, Ds.space.x8),
        contentPadding: EdgeInsets.fromLTRB(
            Ds.space.x24, Ds.space(0), Ds.space.x24, Ds.space.x8),
        actionsPadding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space(0), Ds.space.x16, Ds.space.x12),
        title: Text(row.popupTitle, style: Ds.t.subtitle),
        content: Text(row.popupBody, style: Ds.t.bodySecondary),
        actions: [
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: TextButton.styleFrom(
                foregroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              child: Text(row.popupDismiss, style: Ds.t.body.copyWith(color: Ds.c.brand)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isTotal = row.tone == 'total';
    final labelColor = row.tone == 'brand' ? Ds.c.brand : Ds.c.text;
    final valueColor = row.tone == 'brand' ? Ds.c.brand : Ds.c.text;

    final labelStyle = (isTotal ? Ds.t.subtitle : Ds.t.body).copyWith(
      color: labelColor,
      fontWeight: row.bold ? FontWeight.w700 : null,
    );
    final valueStyle = (isTotal ? Ds.t.subtitle : Ds.t.body).copyWith(
      color: valueColor,
      fontWeight: row.bold ? FontWeight.w700 : FontWeight.w600,
    );

    final glyph = CartBillSummary.glyphFor(row.icon);

    final content = Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (glyph != null) ...[
            Icon(glyph,
                size: Ds.t.bodySize + Ds.space.x4,
                color: row.tone == 'brand' ? Ds.c.brand : Ds.c.textSecondary),
            SizedBox(width: Ds.space.x12),
          ],
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(row.label,
                      style: labelStyle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ),
                if (row.tappable) ...[
                  SizedBox(width: Ds.space.x4),
                  Icon(Icons.info_outline,
                      size: Ds.t.captionSize + Ds.space.x4,
                      color: Ds.c.textSecondary),
                ],
              ],
            ),
          ),
          SizedBox(width: Ds.space.x12),
          _Amount(row: row, style: valueStyle),
        ],
      ),
    );

    final body = row.tappable
        ? Semantics(
            button: true,
            label: row.label,
            child: InkWell(
              onTap: () => _openPopup(context),
              borderRadius: Ds.r.rButton,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                child: content,
              ),
            ),
          )
        : content;

    if (!row.dividerBefore) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
          child: Divider(height: Ds.space(0), color: Ds.c.divider),
        ),
        body,
      ],
    );
  }
}

/// The right-hand column. A waived fee is its own amount with a line through
/// it, followed by the backend's own word for free — never the string "FREE"
/// written here.
class _Amount extends StatelessWidget {
  final BillRow row;
  final TextStyle style;
  const _Amount({required this.row, required this.style});

  @override
  Widget build(BuildContext context) {
    if (!row.waived) {
      return Text(row.value, style: style, textAlign: TextAlign.right);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (row.struckValue.isNotEmpty)
          Text(
            row.struckValue,
            style: style.copyWith(
              color: Ds.c.textSecondary,
              decoration: TextDecoration.lineThrough,
              decorationColor: Ds.c.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
        if (row.struckValue.isNotEmpty && row.freeLabel.isNotEmpty)
          SizedBox(width: Ds.space.x8),
        if (row.freeLabel.isNotEmpty)
          Text(row.freeLabel,
              style: style.copyWith(
                  color: Ds.c.success, fontWeight: FontWeight.w700)),
      ],
    );
  }
}
