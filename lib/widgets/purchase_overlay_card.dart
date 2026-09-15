import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product.dart' show PurchaseOverlay;

/// CMD #791 — "Last ordered 12 Aug · 3× last month · usual qty 9", with the
/// one tap that puts the usual quantity back in the basket.
///
/// The ONE widget every surface that shows a buyer's own history uses, so the
/// wording, the chips and the button label cannot drift between the product
/// page and anything added later. It renders and taps; it decides nothing:
///
///  * the three chips arrive pre-split and pre-worded in payload order,
///  * the button's caption is `add_label` ("Add usual qty (9)") — the app never
///    interpolates the number into a sentence of its own,
///  * whether there is a button at all is `can_add`, not `usualQty > 0`
///    re-derived here,
///  * and the tint is the payload's `{bg, fg}` resolved through `Ds.hex` with a
///    token fallback, so a missing tone degrades to the theme instead of to a
///    colour typed in Dart.
///
/// An anonymous visitor never reaches this widget: `purchase_overlay()` returns
/// `has:false` without a customer account, so [PurchaseOverlay.has] is already
/// the answer and no surface has to ask "am I logged in?".
class PurchaseOverlayCard extends StatelessWidget {
  final PurchaseOverlay overlay;

  /// Fires the one-tap re-order. The parent owns the cart write, so this widget
  /// stays free of the cart model and can be rendered in a test with no state.
  final VoidCallback onAddUsual;

  const PurchaseOverlayCard({
    super.key,
    required this.overlay,
    required this.onAddUsual,
  });

  @override
  Widget build(BuildContext context) {
    if (!overlay.has) return const SizedBox.shrink();

    final bg = Ds.hex(overlay.tone['bg'], Ds.c.bg);
    final fg = Ds.hex(overlay.tone['fg'], Ds.c.text);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (overlay.title.isNotEmpty) ...[
            Text(overlay.title, style: Ds.t.caption.copyWith(color: fg)),
            SizedBox(height: Ds.space.x8),
          ],
          // The chips in payload order. They are the SAME words `label` joins,
          // so a narrow surface can print the one-line form instead and the two
          // can never say different things.
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final chip in overlay.chips)
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                    color: Ds.c.surface,
                    borderRadius: Ds.r.rChip,
                  ),
                  child: Text(
                    chip,
                    style: Ds.t.caption.copyWith(color: fg),
                  ),
                ),
            ],
          ),
          if (overlay.canAdd && overlay.addLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: onAddUsual,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  side: BorderSide(color: Ds.c.brand),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(overlay.addLabel, style: Ds.t.bodyStrong.copyWith(color: Ds.c.brand)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
