// CHANGE #558 — two focused widget tests for the one session source of truth.
//
// 1. A stubbed my_session() with is_admin true renders admin surfaces and no
//    customer surfaces; is_admin false does the reverse.
// 2. A cached session whose auth_user_id differs from the current auth user id
//    re-fetches instead of rendering the cached account.
//
// These drive the real SessionGate — the single place that makes the surface
// decision (RULE 6) and runs the mismatch guard (RULE 4) — through a real
// widget tree, with my_session() stubbed at the boundary.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/models/app_session.dart';
import 'package:pharma_b2b/models/session_gate.dart';

/// Exactly the payload shape my_session() returns.
Map<String, dynamic> mySessionPayload({
  required String authUserId,
  required bool isAdmin,
}) =>
    <String, dynamic>{
      'signed_in': true,
      'auth_user_id': authUserId,
      'login_email': isAdmin ? 'masteromprakashsahu@gmail.com' : '8357881873',
      'role': isAdmin ? 'super_admin' : 'customer',
      'is_admin': isAdmin,
      'owner_type': isAdmin ? 'admin' : 'customer',
      'owner_id': isAdmin ? 'admin-1' : 'cust-1',
      'display_name': isAdmin ? 'masteromprakashsahu@gmail.com' : 'Pallavi Pharmacy',
      'home_route': isAdmin ? '/dashboard' : '/store',
      'home_label': isAdmin ? 'Dashboard' : 'Store',
      'message': 'Signed in',
    };

/// Stands in for the app shell: switches on the ONE surface decision and
/// renders admin-only or customer-only markers, never both.
class _SurfaceProbe extends StatelessWidget {
  const _SurfaceProbe(this.gate);

  final SessionGate gate;

  static const adminSurfaces = ['Dashboard', 'Customers', 'Suppliers', 'Fulfill', 'WhatsApp'];
  static const customerSurfaces = ['Store', 'Catalogue', 'Orders', 'Bulk', 'Cart'];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: AnimatedBuilder(
        animation: gate,
        builder: (context, _) {
          // RULE 4 — the guard runs before anything renders.
          gate.ensureMatchesAuthUser();
          final surface = gate.surfaceFor();
          switch (surface) {
            case AccountSurface.unresolved:
              return const Scaffold(body: Text('LOADING'));
            case AccountSurface.admin:
              return Scaffold(
                body: Column(
                  children: [for (final s in adminSurfaces) Text(s)],
                ),
              );
            case AccountSurface.customer:
              return Scaffold(
                body: Column(
                  children: [for (final s in customerSurfaces) Text(s)],
                ),
              );
            case AccountSurface.supplier:
            case AccountSurface.pendingSupplier:
              return const Scaffold(body: Text('SUPPLIER'));
          }
        },
      ),
    );
  }
}

void main() {
  testWidgets('is_admin decides which surfaces render, and only those',
      (tester) async {
    // ── is_admin true ────────────────────────────────────────────────────────
    var currentUid = 'admin-auth-uid';
    final adminGate = SessionGate(
      currentAuthUserId: () => currentUid,
      refetch: () async {},
    );
    adminGate.adopt(AppSession.fromJson(
        mySessionPayload(authUserId: 'admin-auth-uid', isAdmin: true)));

    await tester.pumpWidget(_SurfaceProbe(adminGate));

    for (final s in _SurfaceProbe.adminSurfaces) {
      expect(find.text(s), findsOneWidget, reason: 'admin surface $s must render');
    }
    for (final s in _SurfaceProbe.customerSurfaces) {
      expect(find.text(s), findsNothing,
          reason: 'customer surface $s must NOT render for an admin session');
    }
    // The landing route comes from the backend, not a Dart role->route map.
    expect(adminGate.session!.homeRoute, '/dashboard');
    expect(adminGate.session!.displayName, 'masteromprakashsahu@gmail.com');

    // ── is_admin false ───────────────────────────────────────────────────────
    currentUid = 'cust-auth-uid';
    final custGate = SessionGate(
      currentAuthUserId: () => currentUid,
      refetch: () async {},
    );
    custGate.adopt(AppSession.fromJson(
        mySessionPayload(authUserId: 'cust-auth-uid', isAdmin: false)));

    await tester.pumpWidget(_SurfaceProbe(custGate));

    for (final s in _SurfaceProbe.customerSurfaces) {
      expect(find.text(s), findsOneWidget, reason: 'customer surface $s must render');
    }
    for (final s in _SurfaceProbe.adminSurfaces) {
      expect(find.text(s), findsNothing,
          reason: 'admin surface $s must NOT render for a customer session');
    }
    expect(custGate.session!.homeRoute, '/store');
    expect(custGate.session!.displayName, 'Pallavi Pharmacy');
  });

  testWidgets('a session for a different auth user re-fetches, never renders',
      (tester) async {
    // The admin signs in and the session is adopted normally...
    const adminUid = 'admin-auth-uid';
    const customerUid = 'cust-auth-uid';

    var currentUid = adminUid;
    var refetches = 0;
    late SessionGate gate;
    gate = SessionGate(
      currentAuthUserId: () => currentUid,
      refetch: () async {
        refetches++;
        // What the app does on a mismatch: ask my_session() again for whoever
        // the SDK now holds, and adopt that answer. Async, like the real RPC.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        gate.adopt(AppSession.fromJson(
            mySessionPayload(authUserId: currentUid, isAdmin: false)));
      },
    );
    gate.adopt(AppSession.fromJson(
        mySessionPayload(authUserId: adminUid, isAdmin: true)));
    expect(gate.matchesAuthUser, isTrue);

    // ...then the auth user changes underneath it — the exact state that used
    // to open the admin interface for the customer.
    currentUid = customerUid;
    expect(gate.matchesAuthUser, isFalse);

    await tester.pumpWidget(_SurfaceProbe(gate));

    // Not one admin surface may be painted from the stale session.
    for (final s in _SurfaceProbe.adminSurfaces) {
      expect(find.text(s), findsNothing,
          reason: 'stale admin surface $s must never render');
    }
    expect(find.text('LOADING'), findsOneWidget,
        reason: 'a mismatch renders the neutral state, never a guess');

    await tester.pumpAndSettle();

    expect(refetches, greaterThanOrEqualTo(1),
        reason: 'the mismatch must trigger a re-fetch');
    expect(gate.session!.authUserId, customerUid);
    expect(gate.session!.isAdmin, isFalse);
    for (final s in _SurfaceProbe.customerSurfaces) {
      expect(find.text(s), findsOneWidget,
          reason: 'after the re-fetch the real account renders');
    }
  });
}
