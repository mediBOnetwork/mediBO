// CHANGE #558 / #571 — the one session object.
//
// Everything the app needs to know about *who is signed in* comes from the
// backend's `my_session()` RPC and lands here. Nothing else in the app may
// infer role, account, display name, landing route, or whether an order may be
// placed: not the email on the Supabase user, not a cached flag, not a
// constructor argument, not SharedPreferences. If a widget needs the role, it
// reads this object.
//
// CHANGE #571 — every field below is READ from the payload. Nothing on this
// class re-derives an answer the backend already gave. `role == 'supplier'`
// style tests are gone: the backend ships `is_supplier`, `surface`,
// `can_place_order` and a fully worded `order_gate`.
//
// Deliberately platform-free (no dart:html, no Supabase import) so it can be
// constructed in a widget test from a plain map.

import 'package:flutter/foundation.dart';

/// Which set of surfaces the app is allowed to render right now.
///
/// CHANGE #571 — this is no longer *computed*. `my_session().surface` is the
/// answer; [surfaceFromName] only parses the backend's word into a Dart enum.
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

  /// The route/worker surface.
  worker,
}

/// The backend's decision about whether this account may place an order, and
/// the exact words to show when it may not.
///
/// [hasBlocker] encodes absence explicitly. An empty [title] must NEVER be read
/// as "there is no problem" — that inversion is how a false "Remove unavailable
/// items" banner once shipped.
@immutable
class OrderGate {
  const OrderGate({
    required this.hasBlocker,
    required this.reason,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.actionRoute,
    required this.shortLabel,
  });

  static const OrderGate open = OrderGate(
    hasBlocker: false,
    reason: 'none',
    title: '',
    message: '',
    actionLabel: '',
    actionRoute: '',
    shortLabel: '',
  );

  /// Nothing may be ordered until the backend has actually answered. Closed by
  /// default so an unresolved session can never read as permission.
  static const OrderGate unresolved = OrderGate(
    hasBlocker: true,
    reason: 'unresolved',
    title: '',
    message: '',
    actionLabel: '',
    actionRoute: '',
    shortLabel: '',
  );

  final bool hasBlocker;

  /// 'none' | 'signed_out' | 'not_registered' | 'pending_approval' |
  /// 'suspended' | 'supplier_account' | 'staff_account' |
  /// 'viewas_pending_approval' | 'unresolved'
  final String reason;
  final String title;
  final String message;
  final String actionLabel;
  final String actionRoute;

  /// The one-line form, for a checkout bar rather than a dialog.
  final String shortLabel;

  factory OrderGate.fromJson(Map<String, dynamic>? json) {
    if (json == null) return OrderGate.unresolved;
    String s(String k) => json[k] == null ? '' : json[k].toString();
    return OrderGate(
      hasBlocker: json['has_blocker'] == true,
      reason: s('reason'),
      title: s('title'),
      message: s('message'),
      actionLabel: s('action_label'),
      actionRoute: s('action_route'),
      shortLabel: s('short_label'),
    );
  }
}

/// The backend-rendered WhatsApp order button on the bulk-upload screen.
/// Same facts as [OrderGate], a different rendering — also authored server-side.
@immutable
class BulkWaGate {
  const BulkWaGate({
    required this.label,
    required this.note,
    required this.hasNote,
    required this.enabled,
    required this.action,
  });

  static const BulkWaGate unresolved = BulkWaGate(
    label: '', note: '', hasNote: false, enabled: false, action: 'none');

  final String label;
  final String note;

  /// Explicit absence — an empty [note] is not the same as "no note".
  final bool hasNote;
  final bool enabled;

  /// 'send' | 'login' | 'none'
  final String action;

  factory BulkWaGate.fromJson(Map<String, dynamic>? json) {
    if (json == null) return BulkWaGate.unresolved;
    String s(String k) => json[k] == null ? '' : json[k].toString();
    return BulkWaGate(
      label: s('label'),
      note: s('note'),
      hasNote: json['has_note'] == true,
      enabled: json['enabled'] == true,
      action: s('action').isEmpty ? 'none' : s('action'),
    );
  }
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
    this.isSuperAdmin = false,
    this.isSupplier = false,
    this.isCustomer = false,
    this.isRegisteredCustomerFlag = false,
    this.isWorker = false,
    this.surfaceName = '',
    this.headerTitle = '',
    this.statusLabel = '',
    this.supplierId = '',
    this.supplierName = '',
    this.customerId = '',
    this.customerName = '',
    this.hasCustomerAccount = false,
    this.isSuspended = false,
    this.isPendingSupplier = false,
    this.supplierStatus = 'not_found',
    this.needsProfile = false,
    this.canPlaceOrder = false,
    this.actingAs = '',
    this.orderGate = OrderGate.unresolved,
    this.bulkWaGate = BulkWaGate.unresolved,
    this.pendingSupplierScreen = const {},
    this.actingAsName = '',
    this.profile = const {},
    this.identities = const [],
  });

  /// The resolved "nobody is signed in" session. Note this is a *resolved*
  /// state, not an unknown one — it is safe to render the public storefront.
  ///
  /// The strings here are a boot-time placeholder only: the moment my_session()
  /// answers, every one of them is replaced by the backend's own words.
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
    homeLabel: '',
    surfaceName: 'public',
    orderGate: OrderGate.unresolved,
    bulkWaGate: BulkWaGate.unresolved,
  );

  final bool signedIn;

  /// auth.uid() as the *backend* saw it. The mismatch guard compares this
  /// against the SDK's current user id before anything renders.
  final String authUserId;
  final String loginEmail;
  final String role;

  // ── Backend booleans. Never recomputed from [role]. ──────────────────────
  final bool isAdmin;
  final bool isSuperAdmin;
  final bool isSupplier;
  final bool isCustomer;

  /// The backend's `is_registered_customer` — meaning APPROVED, which is not
  /// the same as [hasCustomerAccount]. Kept distinct on purpose: conflating
  /// "has an account" with "is approved" is what let an unapproved account
  /// reach the checkout.
  final bool isRegisteredCustomerFlag;
  final bool isWorker;

  final String ownerType;
  final String ownerId;
  final String displayName;
  final String homeRoute;
  final String homeLabel;

  /// Backend word for the surface: 'public' | 'admin' | 'supplier' |
  /// 'pending_supplier' | 'worker' | 'customer'.
  final String surfaceName;

  final String headerTitle;
  final String statusLabel;
  final String supplierId;
  final String supplierName;
  final String customerId;
  final String customerName;

  /// A pharmacy_profiles row exists for this ACCOUNT (not this login).
  final bool hasCustomerAccount;
  final bool isSuspended;
  final bool isPendingSupplier;

  /// 'ok' | 'pending_approval' | 'not_found'
  final String supplierStatus;
  final bool needsProfile;

  /// THE boolean the cart gates on. Never `isRegistered && approved && ...`.
  final bool canPlaceOrder;

  /// Non-empty when a super-admin is acting as a customer (View As).
  final String actingAs;

  final OrderGate orderGate;
  final BulkWaGate bulkWaGate;

  /// The waiting screen shown to an unapproved supplier — title, message and
  /// button label all composed by the backend ('Welcome, <name>' included).
  final Map<String, dynamic> pendingSupplierScreen;

  /// Name of the account being impersonated, '' when not acting as anyone.
  final String actingAsName;

  String pendingText(String key) =>
      (pendingSupplierScreen[key] ?? '').toString();

  /// One of the 14 render-ready profile fields from my_session().profile,
  /// already formatted by the backend. Missing keys read as '' — never null,
  /// so no widget has to invent a fallback.
  String profileText(String key) => (profile[key] ?? '').toString();

  /// The 14 render-ready profile fields, already formatted by the backend.
  final Map<String, dynamic> profile;
  final List<Map<String, dynamic>> identities;

  /// Backend-authored copy shown on the login screen. Never written in Dart.
  final String message;

  static String _str(Map<String, dynamic> j, String k) {
    final v = j[k];
    return v == null ? '' : v.toString();
  }

  factory AppSession.fromJson(Map<String, dynamic> json) {
    String s(String k) => _str(json, k);
    bool b(String k) => json[k] == true;

    final gate = OrderGate.fromJson(
        (json['order_gate'] as Map?)?.cast<String, dynamic>());
    final waGate = BulkWaGate.fromJson(
        (json['bulk_wa_gate'] as Map?)?.cast<String, dynamic>());

    if (json['signed_in'] != true) {
      // Even signed out, the backend's own gate copy is what the app shows.
      return AppSession(
        signedIn: false,
        authUserId: '',
        loginEmail: '',
        role: s('role'),
        isAdmin: false,
        ownerType: '',
        ownerId: '',
        displayName: '',
        homeRoute: s('home_route'),
        homeLabel: s('home_label'),
        message: s('message'),
        surfaceName: s('surface'),
        statusLabel: s('status_label'),
        supplierStatus: s('supplier_status'),
        orderGate: gate,
        bulkWaGate: waGate,
      );
    }

    return AppSession(
      signedIn: true,
      authUserId: s('auth_user_id'),
      loginEmail: s('login_email'),
      role: s('role'),
      isAdmin: b('is_admin'),
      isSuperAdmin: b('is_super_admin'),
      isSupplier: b('is_supplier'),
      isCustomer: b('is_customer'),
      isRegisteredCustomerFlag: b('is_registered_customer'),
      isWorker: b('is_worker'),
      ownerType: s('owner_type'),
      ownerId: s('owner_id'),
      displayName: s('display_name'),
      homeRoute: s('home_route'),
      homeLabel: s('home_label'),
      surfaceName: s('surface'),
      headerTitle: s('header_title'),
      statusLabel: s('status_label'),
      supplierId: s('supplier_id'),
      supplierName: s('supplier_name'),
      customerId: s('customer_id'),
      customerName: s('customer_name'),
      hasCustomerAccount: b('has_customer_account'),
      isSuspended: b('is_suspended'),
      isPendingSupplier: b('is_pending_supplier'),
      supplierStatus: s('supplier_status'),
      needsProfile: b('needs_profile'),
      canPlaceOrder: b('can_place_order'),
      actingAs: s('acting_as'),
      actingAsName: s('acting_as_name'),
      orderGate: gate,
      bulkWaGate: waGate,
      pendingSupplierScreen:
          (json['pending_supplier_screen'] as Map?)?.cast<String, dynamic>() ??
              const {},
      message: s('message'),
      profile: (json['profile'] as Map?)?.cast<String, dynamic>() ?? const {},
      identities: ((json['identities'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList(growable: false),
    );
  }

  /// RULE 6 — which surfaces may render.
  ///
  /// CHANGE #571 — this no longer decides anything. `my_session().surface` has
  /// already decided, including the View As case (the backend sees
  /// `my_acting_as()` and returns 'customer' itself). The only judgement left
  /// here is the RULE 4 mismatch guard: a session belonging to a different auth
  /// user renders nothing at all.
  AccountSurface surface({required bool matchesAuthUser}) {
    if (!matchesAuthUser) return AccountSurface.unresolved;
    return surfaceFromName(surfaceName);
  }

  /// Parses the backend's surface word. Unknown words resolve to [unresolved]
  /// rather than guessing a surface — a wrong guess here is how an admin
  /// session once opened customer screens.
  static AccountSurface surfaceFromName(String name) {
    switch (name) {
      case 'admin':
        return AccountSurface.admin;
      case 'supplier':
        return AccountSurface.supplier;
      case 'pending_supplier':
        return AccountSurface.pendingSupplier;
      case 'worker':
        return AccountSurface.worker;
      case 'customer':
      case 'public':
        return AccountSurface.customer;
      default:
        return AccountSurface.unresolved;
    }
  }

  @override
  String toString() => 'AppSession(signedIn: $signedIn, role: $role, '
      'isAdmin: $isAdmin, authUserId: $authUserId, owner: $ownerType/$ownerId, '
      'surface: $surfaceName, canOrder: $canPlaceOrder, home: $homeRoute)';
}
