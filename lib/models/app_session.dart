// CHANGE #558 — the one session object.
//
// Everything the app needs to know about *who is signed in* comes from the
// backend's `my_session()` RPC and lands here. Nothing else in the app may
// infer role, account, display name or landing route: not the email on the
// Supabase user, not a cached flag, not a constructor argument, not
// SharedPreferences. If a widget needs the role, it reads this object.
//
// Deliberately platform-free (no dart:html, no Supabase import) so it can be
// constructed in a widget test from a plain map.

import 'package:flutter/foundation.dart';

/// Which set of surfaces the app is allowed to render right now.
///
/// The mapping from a session to one of these values is made in exactly one
/// place — [AppSession.surface] — per CHANGE #558 RULE 6.
enum AccountSurface {
  /// Session not resolved yet, or resolved against a different auth user.
  /// Nothing that shows account data may render.
  unresolved,

  /// Dashboard, Customers, Suppliers, Fulfill, WhatsApp.
  admin,

  /// The supplier shell.
  supplier,

  /// A supplier account that exists but has not been approved yet.
  pendingSupplier,

  /// Store, Catalogue, Orders, Bulk, Cart. Also what a signed-out visitor
  /// browsing the public storefront gets.
  customer,
}

@immutable
class AppSession {
  const AppSession({
    required this.signedIn,
    required this.authUserId,
    required this.loginEmail,
    required this.role,
    required this.isAdmin,
    required this.ownerType,
    required this.ownerId,
    required this.displayName,
    required this.homeRoute,
    required this.homeLabel,
    this.message = '',
    this.supplierStatus,
  });

  /// The resolved "nobody is signed in" session. Note this is a *resolved*
  /// state, not an unknown one — it is safe to render the public storefront.
  static const AppSession signedOut = AppSession(
    signedIn: false,
    authUserId: '',
    loginEmail: '',
    role: 'none',
    isAdmin: false,
    ownerType: '',
    ownerId: '',
    displayName: '',
    homeRoute: '/login',
    homeLabel: 'Login',
  );

  final bool signedIn;

  /// auth.uid() as the *backend* saw it. The mismatch guard compares this
  /// against the SDK's current user id before anything renders.
  final String authUserId;
  final String loginEmail;
  final String role;
  final bool isAdmin;
  final String ownerType;
  final String ownerId;
  final String displayName;
  final String homeRoute;
  final String homeLabel;

  /// Backend-authored copy shown on the login screen. Never written in Dart.
  final String message;

  /// Not part of my_session(): 'ok' | 'pending_approval' | 'not_found'.
  /// Only ever consulted to tell an unapproved supplier apart from a plain
  /// customer — never to decide the role itself.
  final String? supplierStatus;

  bool get isSuperAdmin => role == 'super_admin';
  bool get isSupplier => role == 'supplier';

  /// The supplier's own id, when this session *is* a supplier.
  String? get supplierId => isSupplier && ownerId.isNotEmpty ? ownerId : null;

  static String _str(Map<String, dynamic> j, String k) {
    final v = j[k];
    return v == null ? '' : v.toString();
  }

  factory AppSession.fromJson(Map<String, dynamic> json) {
    if (json['signed_in'] != true) return AppSession.signedOut;
    final route = _str(json, 'home_route');
    return AppSession(
      signedIn: true,
      authUserId: _str(json, 'auth_user_id'),
      loginEmail: _str(json, 'login_email'),
      role: _str(json, 'role'),
      isAdmin: json['is_admin'] == true,
      ownerType: _str(json, 'owner_type'),
      ownerId: _str(json, 'owner_id'),
      displayName: _str(json, 'display_name'),
      // No role->route map in Dart: the backend's home_route is the only
      // source. The fallback exists solely so a malformed row can't strand
      // the user on a blank route.
      homeRoute: route.isEmpty ? '/store' : route,
      homeLabel: _str(json, 'home_label'),
      message: _str(json, 'message'),
    );
  }

  AppSession withSupplierStatus(String? status) => AppSession(
        signedIn: signedIn,
        authUserId: authUserId,
        loginEmail: loginEmail,
        role: role,
        isAdmin: isAdmin,
        ownerType: ownerType,
        ownerId: ownerId,
        displayName: displayName,
        homeRoute: homeRoute,
        homeLabel: homeLabel,
        message: message,
        supplierStatus: status,
      );

  /// RULE 6 — the single place that decides which surfaces may render.
  ///
  /// [actingAsCustomer] is the super-admin "View As customer" dev tool: it is
  /// the one documented way an admin session renders customer surfaces.
  /// [matchesAuthUser] is the RULE 4 mismatch guard result; false means the
  /// cached session belongs to a different auth user and nothing may render.
  AccountSurface surface({
    required bool matchesAuthUser,
    bool actingAsCustomer = false,
  }) {
    if (!matchesAuthUser) return AccountSurface.unresolved;
    if (actingAsCustomer) return AccountSurface.customer;
    if (isAdmin) return AccountSurface.admin;
    if (isSupplier) return AccountSurface.supplier;
    if (supplierStatus == 'pending_approval') {
      return AccountSurface.pendingSupplier;
    }
    return AccountSurface.customer;
  }

  @override
  String toString() => 'AppSession(signedIn: $signedIn, role: $role, '
      'isAdmin: $isAdmin, authUserId: $authUserId, owner: $ownerType/$ownerId, '
      'home: $homeRoute)';
}
