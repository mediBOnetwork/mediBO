import 'package:flutter/material.dart';

import '../app_state.dart';
import 'product_image.dart';

/// CHANGE #636 — the persistent floating cart pill.
///
/// Everything it shows comes from `cart_render().render.pill`: whether to
/// appear at all (`show`), the item count wording (`items_label`), the CTA
/// (`cta`) and the thumbnail (`image`). The app does not count the cart to
/// decide visibility — that would be a second answer to a question the cart
/// payload already answers, and the two disagree for exactly as long as a
/// write is in flight.
///
/// This is the only widget in the storefront chrome that reads the cart, so a
/// cart write repaints the pill and nothing else.
class CartPill extends StatelessWidget {
  final VoidCallback onTap;
  const CartPill({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);
    final show = cart.pillShow;

    return IgnorePointer(
      ignoring: !show,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        offset: show ? Offset.zero : const Offset(0, 1.6),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: show ? 1 : 0,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Material(
                color: const Color(0xFF1B7A43),
                borderRadius: BorderRadius.circular(28),
                elevation: 6,
                shadowColor: Colors.black.withValues(alpha: 0.28),
                child: InkWell(
                  borderRadius: BorderRadius.circular(28),
                  onTap: onTap,
                  child: SizedBox(
                    height: 52,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(3),
                              child: ProductImage(
                                url: cart.pillImage,
                                width: 34,
                                height: 34,
                                radius: BorderRadius.circular(17),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            cart.pillItemsLabel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            width: 1,
                            height: 16,
                            color: Colors.white24,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            cart.pillCta,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              color: Colors.white, size: 18),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
