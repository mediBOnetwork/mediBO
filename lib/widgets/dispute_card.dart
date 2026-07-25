// Shared dispute card widget — supplier portal [S1] and token page [S2].
// Payload-driven: buttons come from DisputeItem.actions; labels/codes verbatim.
// Admin context uses its own admin_fulfillment_screen card; this file is supplier-only.

import 'package:flutter/material.dart';
import '../screens/admin/dispute/dispute_models.dart';
import '../utils/render_log.dart';
import 'fulfill_item_sheet.dart' show ProofThumbnail;

const _kGreen     = Color(0xFF1B7A43);
const _kText      = Color(0xFF111827);
const _kSub       = Color(0xFF6B7280);
const _kBorder    = Color(0xFFE5E7EB);
const _kAmberText = Color(0xFFB8860B);
const _kAmberBg   = Color(0xFFFFF8E1);
const _kNeutral   = Color(0xFFF1F3F4);
const _kRed       = Color(0xFFDC2626);

Color _hexColor(String? hex, Color fallback) {
  if (hex == null || hex.isEmpty) return fallback;
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? fallback : Color(v);
}

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
    final isWrong   = item.kind == 'wrong_item' || item.kind == 'few_wrong';

    // Backend-owned (supplier_my_disputes / get_dispute_form): active_colors,
    // kind_label/kind_colors — verbatim, drive the badge and kind tag below.
    final activeColors = agg?.activeColors ?? item.activeColors;
    final activeLabel = activeColors?['label'] ?? (isActive ? 'Active' : 'Inactive');
    final activeBg = _hexColor(activeColors?['bg'], const Color(0xFFF3F4F6));
    final activeFg = _hexColor(activeColors?['fg'], _kSub);
    final kindTagText = item.kindLabel;
    final kindTagBg = _hexColor(item.kindColors?['bg'], const Color(0xFFF1F5F9));
    final kindTagFg = _hexColor(item.kindColors?['fg'], const Color(0xFF475569));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kBorder),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // Header: image + name + status pill
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _imageWidget(hasImage),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(
                      item.productName.isNotEmpty ? item.productName : '—',
                      style: TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700,
                        color: isActive ? _kText : _kSub, height: 1.3,
                      ),
                      maxLines: 2, overflow: TextOverflow.ellipsis,
                    ),
                    if (isWrong && (item.wrongProductName ?? '').isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        'They say we sent: ${item.wrongProductName}',
                        style: const TextStyle(fontSize: 12, color: _kRed),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (kindTagText.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                              color: kindTagBg, borderRadius: BorderRadius.circular(5)),
                          child: Text(kindTagText,
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
                                  color: kindTagFg)),
                        ),
                      ),
                    ],
                  ]),
                ),
                const SizedBox(width: 6),
                // Backend-owned (supplier_my_disputes / get_dispute_form): active_colors,
                // verbatim — replaces the verbose "Awaiting supplier response" pill.
                Builder(builder: (_) {
                  RenderLog.write('c363_badge', 'where=supplier,active=$isActive');
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: activeBg,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(activeLabel,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: activeFg)),
                  );
                }),
              ]),
              // dispute_code: small + muted
              if ((item.disputeCode ?? '').isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  item.disputeCode!,
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w500,
                      color: Color(0xFF9CA3AF), letterSpacing: 0.3),
                ),
              ],
              // Pack / company caption
              if ((item.packType ?? '').isNotEmpty || (item.company ?? '').isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  [
                    if ((item.packType ?? '').isNotEmpty) item.packType!,
                    if ((item.company ?? '').isNotEmpty) item.company!,
                  ].join(' · '),
                  style: const TextStyle(fontSize: 12, color: _kSub),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ],
            ]),
          ),
        ]),

        // Quantities table
        const SizedBox(height: 12),
        _qtyTable(),

        // "In dispute: N units" when disputeQty is meaningful (summed when item-wise)
        if ((agg?.disputedQty ?? item.disputeQty ?? 0) > 0) ...[
          const SizedBox(height: 6),
          Text(
            'In dispute: ${(agg?.disputedQty ?? item.disputeQty ?? 0).toInt()} units',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kAmberText),
          ),
        ],

        // Proof photo thumbnail
        if ((item.proofUrl ?? '').isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(children: [
            const Text('Proof:',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kSub)),
            const SizedBox(width: 8),
            ProofThumbnail(proofUrl: item.proofUrl!, size: 68),
          ]),
        ],

        // Return-note chip (supplier has no close button — info only)
        if (item.returnNoteChip != null) ...[
          const SizedBox(height: 10),
          _returnNoteChip(item.returnNoteChip!),
        ],

        // Action buttons — payload-driven from actions[]
        if (item.actions.isNotEmpty && onRespond != null) ...[
          const SizedBox(height: 12),
          _buttonRow(context),
        ],
      ]),
    );
  }

  Widget _imageWidget(bool hasImage) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
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
      color: const Color(0xFFF1F3F4),
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Icon(Icons.medication_outlined, size: 28, color: Color(0xFFBDBDBD)),
  );

  Widget _qtyTable() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        IntrinsicHeight(child: Row(children: [
          _qtyCell('Ordered', header: true, amber: false),
          _vDiv(),
          _qtyCell('Received', header: true, amber: false),
          _vDiv(),
          _qtyCell('Missing', header: true, amber: true),
        ])),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
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
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        color: amber && !header ? _kAmberBg : null,
        child: Text(text, textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: header ? 11 : 13,
            fontWeight: (header || bold) ? FontWeight.w700 : FontWeight.w400,
            color: amber ? _kAmberText : (header ? _kSub : _kText),
          ),
        ),
      ));

  Widget _vDiv() => const VerticalDivider(width: 1, color: Color(0xFFE5E7EB), thickness: 1);

  // Backend-owned (supplier_my_disputes / get_dispute_form): return_note_chip, verbatim.
  Widget _returnNoteChip(DisputeReturnNoteChip chip) {
    RenderLog.write('c350_return_chip', 'open=${chip.isOpen}');
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: _hexColor(chip.bg, _kNeutral),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          chip.labelCard,
          style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600,
            color: _hexColor(chip.fg, _kSub),
          ),
        ),
      ),
    );
  }

  // Payload-driven buttons: actions[] in payload order, labels verbatim.
  Widget _buttonRow(BuildContext context) {
    RenderLog.write('c350_actions', 'n=${item.actions.length}');
    final spinner = const SizedBox(
      width: 14, height: 14,
      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: item.actions.asMap().entries.map((e) {
        final idx = e.key;
        final action = e.value;
        final primary = idx == 0;
        return Padding(
          padding: EdgeInsets.only(bottom: idx < item.actions.length - 1 ? 8 : 0),
          child: primary
              ? FilledButton(
                  onPressed: isResponding ? null : () => onRespond!(item.disputeId, action.code),
                  style: FilledButton.styleFrom(
                    backgroundColor: _kGreen,
                    disabledBackgroundColor: _kGreen.withValues(alpha: 0.4),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  child: isResponding ? spinner
                      : Text(action.label,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700,
                              color: Colors.white)),
                )
              : OutlinedButton(
                  onPressed: isResponding ? null : () => onRespond!(item.disputeId, action.code),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kText,
                    side: const BorderSide(color: _kBorder),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  child: isResponding ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: _kSub))
                      : Text(action.label,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
        );
      }).toList(),
    );
  }
}
