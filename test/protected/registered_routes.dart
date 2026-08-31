// CHANGE #325 — the offline half of the feature registry.
//
// `feature_registry` is the single source of nav truth, and it lives in
// Postgres. The protected suite runs on the Dart VM with no network, so it
// cannot read that table — but "a screen the nav does not name cannot be
// opened at all" is exactly the property several protected tests exist to
// hold down. This file is the frozen mirror they check against.
//
// Keeping it in step is deliberate friction: registering a screen means adding
// its `route_key` here and a `case` in `_handleAdminNav`. That is cheaper than
// the bug it prevents (#645/#646) — a menu row that renders perfectly and does
// nothing on tap, on a canvas app no tool can click.
library;

/// Every `route_key` in feature_registry that the shell router can open.
///
/// NOT yet here, and deliberately: reorder, pnl, discount_slabs, loyalty,
/// unmapped_companies, delivery_ops, notify_cost, settlement, cron_health,
/// profile. All ten are registered in the table and all ten need a `case` in
/// `_handleAdminNav`; home_shell.dart was leased to another command for the
/// whole of #325, so the router half could not land. Adding the cases and then
/// these ten keys is the follow-up's acceptance test, written in advance.
const kRegisteredAdminRoutes = <String>[
  // Orders & Fulfilment
  'fulfillment', 'order_alerts', 'order_closure', 'bags',
  // Customers & Suppliers
  'customers', 'suppliers', 'add_customer', 'add_supplier', 'mr', 'companies',
  'deletion_requests',
  // Catalogue & Pricing
  'add_medicine', 'pricing_backfill',
  // Delivery
  'delivery_partners',
  // Communication
  'whatsapp', 'wa_templates', 'wa_campaigns', 'wa_segments', 'wa_drips',
  'wa_ops', 'wa_diagnosis', 'notify_center', 'admin_push',
  // Money
  'bill_pipeline', 'gst', 'payment_upi',
  // Admin & System
  'manage_admins', 'dev_queue', 'scope_audit', 'feature_gaps',
  // Identity
  'logout',
];
