// CHANGE #850 — Supplier My Account.
//
// The supplier's own page, and deliberately not a second renderer: #840 already
// built one that prints `blocks[]` — kv, tiles, chips, list, table, timeline,
// toggles, select, actions, calendar, nav, note — with no display string of its
// own. `supplier_account_page()` answers in that exact grammar, so this file is
// only the two things the renderer cannot know by itself: which page RPC to ask,
// and which screen a supplier-side `nav` route_key means.
//
// Everything a supplier sees on it — the tab list, the labels, every rupee,
// every chip tone, every toast, the SPN breakdown, the month names — arrives in
// the payload. There is not one word of copy in this file.
import 'package:flutter/material.dart';

import '../customer/my_account_screen.dart';
import 'supplier_payments_screen.dart';
import 'supplier_payout_screen.dart';
import 'supplier_records_screen.dart';
import 'supplier_schemes_screen.dart';
import 'supplier_staff_screen.dart';

/// A `nav` block's route_key -> the screen that already owns that surface.
/// A key this build has never heard of resolves to null and the renderer skips
/// the row in silence, so the backend can name a screen before it ships.
Widget? supplierAccountMenuScreen(String routeKey) => switch (routeKey) {
      'staff' => const SupplierStaffScreen(),
      'payout' => const SupplierPayoutScreen(),
      'payments' => const SupplierPaymentsScreen(),
      'records' => const SupplierRecordsScreen(),
      'schemes' => const SupplierSchemesScreen(),
      _ => null,
    };

/// The supplier's My Account page. [initialTab] is a tab_key from the backend
/// registry; anything the registry does not offer is ignored and the payload's
/// own default_tab wins.
class SupplierAccountPage extends StatelessWidget {
  final String initialTab;

  const SupplierAccountPage({super.key, this.initialTab = ''});

  @override
  Widget build(BuildContext context) => MyAccountScreen(
        initialTab: initialTab,
        pageRpc: 'supplier_account_page',
        logPrefix: 'c850_sup_account',
        navResolver: supplierAccountMenuScreen,
      );
}

/// Opens the page as a full route.
Future<void> openSupplierAccountPage(BuildContext context,
        {String initialTab = ''}) =>
    Navigator.of(context).push<void>(MaterialPageRoute<void>(
      builder: (_) => SupplierAccountPage(initialTab: initialTab),
    ));
