import 'package:flutter/widgets.dart';

// Build-phase dev tool flag — set false before public launch.
const bool kEnableViewAs = true;

enum ViewAsRole { customer, supplier, company, deliveryPartner }

class ViewAsIdentity {
  final String id;      // table PK (pharmacy_profiles.id for customer)
  final String name;
  final String email;
  final String? userId; // auth.users.id — set for customer so orders can be scoped
  final bool isApproved; // pharmacy_profiles.approved — gates write-as order placement
  const ViewAsIdentity({
    required this.id,
    required this.name,
    required this.email,
    this.userId,
    this.isApproved = true,
  });
}

class ViewAsNotifier extends ChangeNotifier {
  ViewAsRole? _role;
  ViewAsIdentity? _identity;

  ViewAsRole? get role => _role;
  ViewAsIdentity? get identity => _identity;
  bool get isActive => _role != null;

  void activate(ViewAsRole role, ViewAsIdentity identity) {
    _role = role;
    _identity = identity;
    notifyListeners();
  }

  void exit() {
    _role = null;
    _identity = null;
    notifyListeners();
  }
}

class ViewAsState extends InheritedNotifier<ViewAsNotifier> {
  const ViewAsState({
    super.key,
    required ViewAsNotifier notifier,
    required super.child,
  }) : super(notifier: notifier);

  static ViewAsNotifier of(BuildContext context) {
    final s = context.dependOnInheritedWidgetOfExactType<ViewAsState>();
    assert(s != null, 'ViewAsState not found in widget tree');
    return s!.notifier!;
  }

  static ViewAsNotifier read(BuildContext context) {
    final s = context.getInheritedWidgetOfExactType<ViewAsState>();
    assert(s != null, 'ViewAsState not found in widget tree');
    return s!.notifier!;
  }
}
