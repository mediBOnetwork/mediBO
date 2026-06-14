import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'package:flutter/widgets.dart';

// Build-phase dev tool flag — set false before public launch.
const bool kEnableViewAs = true;

const String _kViewAsKey = 'medibo_view_as';

enum ViewAsRole { customer, supplier, company, deliveryPartner }

class ViewAsIdentity {
  final String id;     // table PK (pharmacy_profiles.id for customer)
  final String name;
  final String email;
  final String? userId; // auth.users.id — set for customer so orders can be scoped
  const ViewAsIdentity({required this.id, required this.name, required this.email, this.userId});
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
    _persist(role, identity);
    notifyListeners();
  }

  void exit() {
    _role = null;
    _identity = null;
    _clearPersisted();
    notifyListeners();
  }

  void _persist(ViewAsRole role, ViewAsIdentity identity) {
    try {
      html.window.localStorage[_kViewAsKey] = jsonEncode({
        'role': role.name,
        'id': identity.id,
        'name': identity.name,
        'email': identity.email,
        'userId': identity.userId,
      });
    } catch (_) {}
  }

  void _clearPersisted() {
    try {
      html.window.localStorage.remove(_kViewAsKey);
    } catch (_) {}
  }

  /// Reads persisted descriptor from localStorage without activating. Returns null if nothing stored.
  static Map<String, dynamic>? readPersistedDescriptor() {
    try {
      final raw = html.window.localStorage[_kViewAsKey];
      if (raw == null) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static void clearPersisted() {
    try {
      html.window.localStorage.remove(_kViewAsKey);
    } catch (_) {}
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
