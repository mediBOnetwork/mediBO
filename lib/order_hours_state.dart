import 'package:flutter/widgets.dart';

import 'models/order_hours_model.dart';

/// Exposes the [OrderHoursModel] to the widget tree and rebuilds dependents
/// whenever order hours change. Access it with `OrderHoursState.of(context)`.
class OrderHoursState extends InheritedNotifier<OrderHoursModel> {
  const OrderHoursState({
    super.key,
    required OrderHoursModel orderHours,
    required super.child,
  }) : super(notifier: orderHours);

  static OrderHoursModel of(BuildContext context) {
    final state = context.dependOnInheritedWidgetOfExactType<OrderHoursState>();
    assert(state != null, 'OrderHoursState not found in widget tree');
    return state!.notifier!;
  }

  static OrderHoursModel read(BuildContext context) {
    final state = context.getInheritedWidgetOfExactType<OrderHoursState>();
    assert(state != null, 'OrderHoursState not found in widget tree');
    return state!.notifier!;
  }
}
