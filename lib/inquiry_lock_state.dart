import 'package:flutter/widgets.dart';

import 'models/inquiry_lock_model.dart';

/// Exposes the [InquiryLockModel] to the widget tree and rebuilds dependents
/// whenever the lock changes. Access with `InquiryLockState.of(context)`.
class InquiryLockState extends InheritedNotifier<InquiryLockModel> {
  const InquiryLockState({
    super.key,
    required InquiryLockModel inquiryLock,
    required super.child,
  }) : super(notifier: inquiryLock);

  static InquiryLockModel of(BuildContext context) {
    final state = context.dependOnInheritedWidgetOfExactType<InquiryLockState>();
    assert(state != null, 'InquiryLockState not found in widget tree');
    return state!.notifier!;
  }

  static InquiryLockModel read(BuildContext context) {
    final state = context.getInheritedWidgetOfExactType<InquiryLockState>();
    assert(state != null, 'InquiryLockState not found in widget tree');
    return state!.notifier!;
  }
}
