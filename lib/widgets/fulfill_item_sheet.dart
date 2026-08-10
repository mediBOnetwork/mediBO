// FULFILL360 pass 3 (CHANGE #531): this file previously held FulfillItemSheet /
// showFulfillItemSheet — the per-order-item counting popup. That whole widget
// tree became unreachable when the tap paths were rewired: showFulfillItemSheet
// was called only from _showItemSheet, which was called only from _buildItemTile,
// which had ZERO callers (_buildItemList no longer exists; _buildNarrowItemList
// is the live mobile list). ~1665 lines deleted. The live per-item popup is
// _ProductReceiveSheet in admin_fulfillment_screen.dart.
//
// The file path is kept ONLY because ProofThumbnail below is imported by three
// live surfaces: widgets/dispute_card.dart, screens/public/dispute_form_screen.dart,
// screens/supplier/supplier_disputes_screen.dart, and admin_fulfillment_screen.dart.

import 'package:flutter/material.dart';

import '../services/ui_copy.dart';
import '../utils/render_log.dart';

// ── Proof thumbnail widget — shared between dispute surfaces ──────────────────

/// Shows a tappable proof thumbnail. Opens a full-screen viewer on tap.
/// Emits c194_dispute_proof_rendered to render-log.
class ProofThumbnail extends StatelessWidget {
  final String proofUrl;
  final double size;
  const ProofThumbnail({super.key, required this.proofUrl, this.size = 72});

  @override
  Widget build(BuildContext context) {
    return Builder(builder: (ctx) {
      RenderLog.write('c194_dispute_proof_rendered',
          'url=${proofUrl.length > 60 ? proofUrl.substring(0, 60) : proofUrl}');
      return GestureDetector(
        onTap: () => showDialog<void>(
          context: ctx,
          builder: (_) => Dialog(
            backgroundColor: Colors.black,
            insetPadding: EdgeInsets.zero,
            child: Stack(children: [
              SizedBox.expand(
                child: InteractiveViewer(
                  child: Image.network(
                    proofUrl,
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image_outlined,
                          color: Colors.white, size: 48),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 8, right: 8,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ]),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.network(
                proofUrl,
                width: size, height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  width: size, height: size,
                  color: const Color(0xFFF3F4F6),
                  child: const Icon(Icons.broken_image_outlined,
                      color: Color(0xFF6B7280)),
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(c('fulfill_item.proof_tap_to_zoom'),
                style: const TextStyle(fontSize: 10, color: Color(0xFF6B7280))),
          ],
        ),
      );
    });
  }
}
