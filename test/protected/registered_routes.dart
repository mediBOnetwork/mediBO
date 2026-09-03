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
/// The ten keys that were held back mid-#325 (reorder, pnl, discount_slabs,
/// loyalty, unmapped_companies, delivery_ops, notify_cost, settlement,
/// cron_health, profile) are IN this list now: home_shell.dart's lease freed
/// before the command ended, `_handleAdminNav` gained a case for each, and the
/// nine registry rows that had been parked at is_active=false were switched
/// back on. Nine of those ten screens had never had a tappable way in at all.
const kRegisteredAdminRoutes = <String>[
  // Orders & Fulfilment
  'fulfillment', 'order_alerts', 'order_closure', 'bags', 'reorder',
  // CHANGE #689 — "where is this order": the order timeline, addressable.
  'order_timeline',
  // Customers & Suppliers
  'customers', 'suppliers', 'add_customer', 'add_supplier', 'mr', 'companies',
  'unmapped_companies', 'deletion_requests',
  // Catalogue & Pricing
  'add_medicine', 'pricing_backfill', 'discount_slabs', 'loyalty',
  // Delivery
  'delivery_partners', 'delivery_ops',
  // Communication
  'whatsapp', 'wa_templates', 'wa_campaigns', 'wa_segments', 'wa_drips',
  'wa_ops', 'wa_diagnosis', 'notify_center', 'admin_push', 'notify_cost',
  // Money
  'bill_pipeline', 'gst', 'pnl', 'settlement', 'payment_upi',
  // Admin & System
  'manage_admins', 'dev_queue', 'scope_audit', 'feature_gaps', 'cron_health',
  'test_mode', // CHANGE #573 — the synthetic lane
  // CHANGE #397 — bulk editing and exports; both open AdminBulkScreen, the
  // second on its Exports tab.
  'bulk_actions', 'exports',
  // CMD #410 — the reviews & Q&A moderation desk. Nothing a pharmacy writes
  // about a product is public until it is approved there, so the queue must be
  // reachable from a phone, not only from a registry row.
  'reviews',
  // Identity — the only two rows the dropdown may hold
  'profile', 'logout',
  // CMD #429/#444 — the paper sale sheet.
  'paper_sale',
  // CMD #450 — the money screen (receivables, verification queue, unattached
  // money, stalled supplier bills).
  'money',
];
