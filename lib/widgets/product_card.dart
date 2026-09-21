import 'package:flutter/material.dart';

import '../models/product.dart';
import '../services/ui_copy.dart';
import 'animations.dart';

// CMD #2146 — the old full-size `ProductCard` (and its _QuantityStepper) is
// gone: every product surface draws the ONE shared card,
// `CompactProductCard` (Product card v5). Only the backend-driven
// [AvailabilityButton] still lives here.

/// CHANGE #553 — the one place the storefront paints an add-to-cart button.
///
/// Everything visible comes from the backend's [Availability] verdict: the
/// label, both colours and whether the button works. There is no threshold,
/// no supplier-count comparison and no hardcoded availability string here —
/// change the wording or the colours in Postgres and this widget follows.
///
/// When [availability] is null the row came from an outage fallback that
/// carries no verdict; the button then keeps the app's normal green
/// add-to-cart styling rather than inventing an availability decision.
class AvailabilityButton extends StatelessWidget {
  final Availability? availability;
  final VoidCallback onAdd;
  const AvailabilityButton({
    super.key,
    required this.availability,
    required this.onAdd,
  });

  static const _radius = 8.0;
  static const _textStyle =
      TextStyle(fontWeight: FontWeight.w500, fontSize: 14);

  @override
  Widget build(BuildContext context) {
    final av = availability;

    // No verdict (outage fallback): the pre-#553 green add-to-cart, unchanged.
    if (av == null) {
      return PressEffect(
        key: const ValueKey('add'),
        child: SizedBox.expand(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(_radius)),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: _textStyle,
              elevation: 0,
              splashFactory: NoSplash.splashFactory,
              shadowColor: Colors.transparent,
            ).copyWith(
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 16),
            label: Text(c('product_card.add_to_cart')),
          ),
        ),
      );
    }

    final bg = av.bg == null ? null : Color(av.bg!);
    final fg = av.fg == null ? null : Color(av.fg!);
    final style = FilledButton.styleFrom(
      backgroundColor: bg,
      foregroundColor: fg,
      disabledBackgroundColor: bg,
      disabledForegroundColor: fg,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(_radius)),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: _textStyle,
      elevation: 0,
      splashFactory: NoSplash.splashFactory,
      shadowColor: Colors.transparent,
    );

    if (av.canAdd) {
      return PressEffect(
        key: const ValueKey('add'),
        child: SizedBox.expand(
          child: FilledButton.icon(
            style: style.copyWith(
              overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            ),
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 16),
            label: Text(av.ctaLabel),
          ),
        ),
      );
    }

    // CMD #2023 — the button alone carries the state. Unavailable is grey and
    // NON-TAPPABLE: there is no second opinion to surface any more, because
    // there is no second answer — public.zone_available() decided this, and the
    // "Available · <zone>" / "Not in your zone" text line it used to argue with
    // no longer exists in any payload. IgnorePointer is the whole widget now.
    return IgnorePointer(
      key: const ValueKey('cta-disabled'),
      child: SizedBox.expand(
        child: FilledButton(
          style: style,
          onPressed: null,
          child: Text(av.ctaLabel),
        ),
      ),
    );
  }
}
