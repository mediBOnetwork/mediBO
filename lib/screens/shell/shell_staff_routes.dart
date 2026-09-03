// lib/screens/shell/shell_staff_routes.dart — CHANGE #1016
//
// The doors the shared staff shell had been promising and did not have.
//
// #653 merged the partner into the admin interface and #657 deleted the
// routed Partner page, but the resolver that page used (partnerDestination in
// partner_home_screen.dart) was the ONLY thing that opened seven partner
// screens: My documents, My staff, Workers, Expenses, Supplier payments,
// Returns to supplier and the partner's own settlement statement. Every one
// of them stayed a registry tile — surface_route even declared some of them
// as home_shell doors — and every one fell through the shell's switch into
// "route unavailable". This file is that door.
//
// WHY A SEPARATE FILE. home_shell.dart is capped at 2,000 lines by its own
// guard and shell_extra_routes.dart is the shard other commands are writing
// into today; a second shard costs the shell one four-line lookup and gives
// the partner doors a leasable path of their own. The reachability gate
// (test/protected/admin_nav_reachability_test.dart) reads this file's arms
// exactly as it reads shell_extra_routes.dart's.
//
// Authorisation is NOT here. Each screen's RPCs zone-clamp a partner and
// refuse anyone else in their own words; the door being open to a role decides
// nothing about what that role reads or writes.

import 'package:flutter/material.dart';

import '../../services/access.dart';
import '../partner/partner_documents_screen.dart';
import '../partner/partner_expense_screen.dart';
import '../partner/partner_home_screen.dart' show PartnerFeaturePage;
import '../partner/partner_returns_screen.dart';
import '../partner/partner_staff_screen.dart';
import '../partner/partner_statement_screen.dart';
import '../partner/partner_supplier_payment_screen.dart';
import '../partner/partner_workers_screen.dart';

/// The page title is the label the ACCESS MATRIX gave the route
/// (`access_boot().routes[<route>].label`) — the registry's own word, so
/// renaming "My staff" is an UPDATE and never a deploy.
String _title(String routeKey) => Access.instance.routeLabel(routeKey);

/// These screens are TAB BODIES — a bounded box, no Scaffold of their own —
/// so each is pushed inside [PartnerFeaturePage], the same frame the retired
/// partner resolver used.
Widget _page(String routeKey, Widget child) =>
    PartnerFeaturePage(title: _title(routeKey), child: child);

/// The screen a route_key opens, or null when this table does not own it.
/// Null means "keep looking": the shell's own switch and its backend-worded
/// default branch stay in charge of an unknown route.
Widget? shellStaffRouteScreen(String routeKey) => switch (routeKey) {
      // CHANGE #692 — the partner's own agreement + KYC documents.
      'partner_documents' => const PartnerDocumentsPage(),
      // CHANGE #399 — the partner's own staff, its expenses, its workers.
      'partner_staff' => _page(routeKey, const PartnerStaffScreen()),
      'partner_expenses' => _page(routeKey, const PartnerExpenseScreen()),
      'partner_workers' => _page(routeKey, const PartnerWorkersScreen()),
      // CHANGE #399 — the partner's door onto the supplier payment writer,
      // zone-clamped (partner_sup_record_payment).
      'supplier_payment' => _page(routeKey, const PartnerSupplierPaymentScreen()),
      // CHANGE #710 — stock going back to a supplier and its debit note.
      'supplier_returns' => _page(routeKey, const PartnerReturnsScreen()),
      // CHANGE #323 — the partner's own settlement statement. Its OWN route
      // now: the shared 'settlement' key opens the office console.
      'partner_settlement' => _page(routeKey, const PartnerStatementScreen()),
      _ => null,
    };
