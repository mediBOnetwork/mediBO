// Shared dispute card widget — supplier portal [S1] and token page [S2].
// Payload-driven: buttons come from DisputeItem.actions; labels/codes verbatim.
// Admin context uses its own admin_fulfillment_screen card; this file is supplier-only.

import 'package:flutter/material.dart';
import '../design_tokens.dart';
import '../screens/admin/dispute/dispute_models.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';
import 'fulfill_item_sheet.dart' show ProofThumbnail;

// CHANGE #671 gap 51: the private eight-colour palette and the private hex
// parser are gone — every colour is a `Ds` token, and the backend's own
// active_colors / kind_colors / return-note hexes are read by Ds.hex.

String _pq(num n, String? packType) {
  if (packType == null || packType.trim().isEmpty) return '$n';
  return '$n ${n == 1 ? packType.trim() : "${packType.trim()}s"}';
}

// Shared dispute card; both pages instantiate it with the same fields.
// onRespond is null → card is read-only (no action buttons rendered).
class DisputeCard extends StatelessWidget {
  final DisputeItem item;
  // C363-F: when non-null, the row is item-wise — show this product's SUMMED qtys +
  // Active-if-any state (item is the representative line; agg carries the totals).
  final AggregatedDispute? agg;
  // Called with (disputeId, actionCode) when supplier taps a button.
  final Future<void> Function(String disputeId, String code)? onRespond;
  final bool isResponding;

  const DisputeCard({
    super.key,
    required this.item,
    this.agg,
    this.onRespond,
    this.isResponding = false,
  });

  @override
  Widget build(BuildContext context) {
    // c350_card emitted once per card in build
    RenderLog.write('c350_card', 'kind=${item.kind}');

    final isActive = agg?.active ?? item.isActive;
    final hasImage  = (item.imageUrl ?? '').isNotEmpty;

    // Backend-owned (supplier_my_disputes / get_dispute_form): active_colors,
    // kind_label/kind_colors — verbatim, drive the badge and kind tag below.
    // active_colors.label is populated by construction (backend CASE has no
    // NULL branch), so there is no client-side Active/Inactive fallback text.
    final activeColors = agg?.activeColors ?? item.activeColors;
    final activeLabel = activeColors?['label'] ?? '';
    final activeBg = Ds.hex(activeColors?['bg'], Ds.c.bg);
    final activeFg = Ds.hex(activeColors?['fg'], Ds.c.textSecondary);
    final activeBorder = Ds.hex(activeColors?['border'], Colors.transparent);
    final kindTagText = item.kindLabel;
    final kindTagBg = Ds.hex(item.kindColors?['bg'], Ds.c.bg);
    final kindTagFg = Ds.hex(item.kindColors?['fg'], Ds.c.textSecondary);

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // Header: image + name + status pill
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _imageWidget(hasImage),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      item.productName.isNotEmpty ? item.productName : '—',
                      style: Ds.t.body.copyWith(
                        fontWeight: FontWeight.w700,
                        color: isActive ? Ds.c.text : Ds.c.textSecondary,
                      ),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                    ),
                    if ((item.wrongProductName ?? '').isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(
                        cf('dispute_card.they_say_we_sent', {'a': '${item.wrongProductName}'}),
                        style: Ds.t.caption.copyWith(color: Ds.c.danger),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (kindTagText.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: Ds.space.x4, vertical: Ds.space.x4),
                          decoration: BoxDecoration(
                              color: kindTagBg, borderRadius: Ds.r.rChip),
                          child: Text(kindTagText,
                              style: Ds.t.caption.copyWith(
                                  fontWeight: FontWeight.w700, color: kindTagFg)),
                        ),
                      ),
                    ],
                  ]),
                ),
                SizedBox(width: Ds.space.x4),
                // Backend-owned (supplier_my_disputes / get_dispute_form): active_colors,
                // verbatim — replaces the verbose "Awaiting supplier response" pill.
                Builder(builder: (_) {
                  RenderLog.write('c363_badge', 'where=supplier,active=$isActive');
                  return Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x8, vertical: Ds.space.x4),
                    decoration: BoxDecoration(
                      color: activeBg,
                      borderRadius: Ds.r.rChip,
                      border: Border.all(color: activeBorder),
                    ),
                    child: Text(activeLabel,
                        style: Ds.t.caption.copyWith(
                            fontWeight: FontWeight.w700, color: activeFg)),
                  );
                }),
              ]),
              // dispute_code: small + muted
              if ((item.disputeCode ?? '').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(
                  item.disputeCode!,
                  style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w500, letterSpacing: 0.3),
                ),
              ],
              // Pack / company caption
              if ((item.packType ?? '').isNotEmpty || (item.company ?? '').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(
                  [
                    if ((item.packType ?? '').isNotEmpty) item.packType!,
                    if ((item.company ?? '').isNotEmpty) item.company!,
                  ].join(' · '),
                  style: Ds.t.caption,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ],
            ]),
          ),
        ]),

        // Quantities table
        SizedBox(height: Ds.space.x12),
        _qtyTable(),

        // "In dispute: N units" when disputeQty is meaningful (summed when item-wise)
        if ((agg?.disputedQty ?? item.disputeQty ?? 0) > 0) ...[
          SizedBox(height: Ds.space.x4),
          Text(
            cf('dispute_card.in_dispute_units', {'a': '${(agg?.disputedQty ?? item.disputeQty ?? 0).toInt()}'}),
            style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w600, color: Ds.c.warning),
          ),
        ],

        // Proof photo thumbnail
        if ((item.proofUrl ?? '').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Row(children: [
            Text(c('dispute_card.proof'),
                style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600)),
            SizedBox(width: Ds.space.x8),
            ProofThumbnail(proofUrl: item.proofUrl!, size: 68),
          ]),
        ],

        // Return-note chip (supplier has no close button — info only)
        if (item.returnNoteChip != null) ...[
          SizedBox(height: Ds.space.x8),
          _returnNoteChip(item.returnNoteChip!),
        ],

        // Action buttons — payload-driven from actions[]
        if (item.actions.isNotEmpty && onRespond != null) ...[
          SizedBox(height: Ds.space.x12),
          _buttonRow(context),
        ],
      ]),
    );
  }

  Widget _imageWidget(bool hasImage) => ClipRRect(
    borderRadius: Ds.r.rButton,
    child: hasImage
        ? Image.network(
            item.imageUrl!,
            width: 60, height: 60, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _imageFallback(),
          )
        : _imageFallback(),
  );

  Widget _imageFallback() => Container(
    width: 60, height: 60,
    decoration: BoxDecoration(
      color: Ds.c.bg,
      borderRadius: Ds.r.rButton,
    ),
    child: Icon(Icons.medication_outlined, size: 28, color: Ds.c.divider),
  );

  Widget _qtyTable() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Ds.c.divider),
        borderRadius: Ds.r.rButton,
      ),
      child: Column(children: [
        // CHANGE #671: the three headings were Dart literals on a card two
        // public surfaces share. They are ui_copy now, like every other word.
        IntrinsicHeight(child: Row(children: [
          _qtyCell(c('dispute_card.qty_ordered'), header: true, amber: false),
          _vDiv(),
          _qtyCell(c('dispute_card.qty_received'), header: true, amber: false),
          _vDiv(),
          _qtyCell(c('dispute_card.qty_missing'), header: true, amber: true),
        ])),
        Divider(height: 1, color: Ds.c.divider),
        IntrinsicHeight(child: Row(children: [
          // C363-F: item-wise → show the product's SUMMED ordered/received/disputed totals.
          _qtyCell(_pq(agg?.orderedQty ?? item.ordered, item.packType), header: false, amber: false),
          _vDiv(),
          _qtyCell(_pq(agg?.receivedQty ?? item.received, item.packType), header: false, amber: false),
          _vDiv(),
          _qtyCell(_pq(agg?.disputedQty ?? item.short, item.packType), header: false, amber: true, bold: true),
        ])),
      ]),
    );
  }

  Widget _qtyCell(String text, {required bool header, required bool amber, bool bold = false}) =>
      Expanded(child: Container(
        padding: EdgeInsets.symmetric(
            vertical: Ds.space.x8, horizontal: Ds.space.x4),
        color: amber && !header ? Ds.c.warningSoft : null,
        child: Text(text, textAlign: TextAlign.center,
          style: Ds.t.caption.copyWith(
            fontWeight: (header || bold) ? FontWeight.w700 : FontWeight.w400,
            color: amber
                ? Ds.c.warning
                : (header ? Ds.c.textSecondary : Ds.c.text),
          ),
        ),
      ));

  Widget _vDiv() =>
      VerticalDivider(width: 1, color: Ds.c.divider, thickness: 1);

  // Backend-owned (supplier_my_disputes / get_dispute_form): return_note_chip, verbatim.
  Widget _returnNoteChip(DisputeReturnNoteChip chip) {
    RenderLog.write('c350_return_chip', 'open=${chip.isOpen}');
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: Ds.hex(chip.bg, Ds.c.bg),
          borderRadius: Ds.r.rChip,
        ),
        child: Text(
          chip.labelCard,
          style: Ds.t.caption.copyWith(
            fontWeight: FontWeight.w600,
            color: Ds.hex(chip.fg, Ds.c.textSecondary),
          ),
        ),
      ),
    );
  }

  // Payload-driven buttons: actions[] in payload order, labels verbatim.
  Widget _buttonRow(BuildContext context) {
    RenderLog.write('c350_actions', 'n=${item.actions.length}');
    final spinner = SizedBox(
      width: 14, height: 14,
      child: CircularProgressIndicator(color: Ds.c.surface, strokeWidth: 2),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: item.actions.asMap().entries.map((e) {
        final idx = e.key;
        final action = e.value;
        // CHANGE #531: backend-owned `primary` (was: idx == 0).
        final primary = action.primary;
        return Padding(
          padding: EdgeInsets.only(
              bottom: idx < item.actions.length - 1 ? Ds.space.x8 : 0),
          child: primary
              ? FilledButton(
                  onPressed: isResponding ? null : () => onRespond!(item.disputeId, action.code),
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    disabledBackgroundColor: Ds.c.brand.withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
                  ),
                  child: isResponding ? spinner
                      : Text(action.label,
                          style: Ds.t.body.copyWith(
                              fontWeight: FontWeight.w700, color: Ds.c.surface)),
                )
              : OutlinedButton(
                  onPressed: isResponding ? null : () => onRespond!(item.disputeId, action.code),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Ds.c.text,
                    side: BorderSide(color: Ds.c.divider),
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
                  ),
                  child: isResponding ? SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Ds.c.textSecondary))
                      : Text(action.label,
                          style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
                ),
        );
      }).toList(),
    );
  }
}
