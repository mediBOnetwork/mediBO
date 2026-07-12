import 'package:flutter/material.dart';

import '../order_hours_state.dart';

/// CHANGE #446 — persistent "we're closed" strip for the customer storefront + cart.
/// Browsing/search/cart-editing stay usable; only order placement is blocked.
class OrderHoursBanner extends StatelessWidget {
  const OrderHoursBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final model = OrderHoursState.of(context);
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        if (!model.loaded || model.isOpen) return const SizedBox.shrink();
        final message = (model.closedMessage ?? '').trim();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: const Color(0xFFDC2626),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 16, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message.isEmpty
                      ? 'Order hours are closed.'
                      : 'Order hours are closed. $message',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
