import 'package:flutter/widgets.dart';

import 'models/cart_model.dart';

/// Exposes the [CartModel] to the widget tree and rebuilds dependents
/// whenever the cart changes. Access it with `AppState.of(context)`.
class AppState extends InheritedNotifier<CartModel> {
  const AppState({
    super.key,
    required CartModel cart,
    required super.child,
  }) : super(notifier: cart);

  static CartModel of(BuildContext context) {
    final state = context.dependOnInheritedWidgetOfExactType<AppState>();
    assert(state != null, 'AppState not found in widget tree');
    return state!.notifier!;
  }
}
