// CMD #1929 — the admin route TABLE.
//
// Extracted from home_shell.dart's _handleAdminNav, which had grown to 85
// cases in 572 lines — 58 of them the identical shape "push this const
// screen". That is data, not control flow, and keeping it in the shell is what
// pushed the file past the 2,000-line ceiling
// test/protected/god_file_guard_test.dart holds it to. The shell's own concern
// is boot and routing; WHICH widget a key opens is a lookup.
//
// The 27 cases that stayed behind are the ones with actual behaviour: a seed
// argument, a role gate, an injected RPC, a tab index. Those belong to the
// shell.
//
// Adding a destination is now ONE line here plus its feature_registry row —
// and no route in this table can render a row that does nothing on tap, the
// #645/#646 bug, because the same map the shell reads is the map this file is.
import 'package:flutter/material.dart';

import '../features/bags/bags_screen.dart';
import '../features/whatsapp/ui/wa_home_screen.dart';
import '../features/whatsapp/ui/wa_templates_screen.dart';
import 'admin/admin_audit_screen.dart';
import 'admin/admin_bill_pipeline_screen.dart';
import 'admin/admin_bulk_screen.dart';
import 'admin/admin_delivery_ops_screen.dart';
import 'admin/admin_demand_engine_screen.dart';
import 'admin/admin_gst_screen.dart';
import 'admin/admin_money_screen.dart';
import 'admin/admin_order_closure_screen.dart';
import 'admin/admin_pricing_screen.dart';
import 'admin/admin_push_screen.dart';
import 'admin/admin_reviews_screen.dart';
import 'admin/admin_roles_screen.dart';
import 'admin/admin_scope_audit_screen.dart';
import 'admin/admin_stock_on_hand_screen.dart';
import 'admin/admin_supplier_account_screen.dart';
import 'admin/catalogue_health_screen.dart';
import 'admin/loyalty_admin_screen.dart';
import 'admin/notify_center_screen.dart';
import 'admin/notify_cost_screen.dart';
import 'admin/order_alerts_screen.dart';
import 'admin/payment_alerts_screen.dart';
import 'admin/pnl_screen.dart';
import 'admin/pricing_backfill_screen.dart';
import 'admin/reorder_admin_screen.dart';
import 'admin/settlement_screen.dart';
import 'admin/unmapped_companies_screen.dart';
import 'admin/wa_campaigns_screen.dart';
import 'admin/wa_diagnosis_screen.dart';
import 'admin/wa_drips_screen.dart';
import 'admin/wa_ops_screen.dart';
import 'admin/wa_segments_screen.dart';
import 'customer/order_help_sheet.dart';
import 'order_lists_screen.dart';
import 'pharmacy/khata_screen.dart';
import 'pharmacy/near_listing_screen.dart';
import 'pharmacy/paper_sale_screen.dart';
import 'pharmacy/pharmacy_audit_screen.dart';
import 'pharmacy/pharmacy_expiry_screen.dart';
import 'pharmacy/pharmacy_gst_screen.dart';
import 'pharmacy/pharmacy_overpay_screen.dart';
import 'pharmacy/pharmacy_owner_screen.dart';
import 'pharmacy/pharmacy_parcel_count_screen.dart';
import 'pharmacy/pharmacy_radar_screen.dart';
import 'pharmacy/pharmacy_refill_screen.dart';
import 'pharmacy/pharmacy_reorder_screen.dart';
import 'pharmacy/pharmacy_stock_screen.dart';
import 'pharmacy/pharmacy_variance_screen.dart';
import 'pharmacy/pharmacy_vault_screen.dart';
import 'pharmacy/pos_screen.dart';
import 'pharmacy/px_screen.dart';
import 'pharmacy/rx_scan_screen.dart';
import 'profile_screen.dart';
import 'purchases_screen.dart';
import 'reorder_screen.dart';

/// route key -> the screen it opens. Every entry is a const, zero-argument
/// screen; anything needing an argument stays in the shell's switch.
final Map<String, WidgetBuilder> kAdminSimpleRoutes = <String, WidgetBuilder>{
  'admin_push': (_) => const AdminPushScreen(),
  'admin_roles': (_) => const AdminRolesScreen(),
  'audit_log': (_) => const AdminAuditScreen(),
  'bags': (_) => const BagsScreen(),
  'bill_pipeline': (_) => const AdminBillPipelineScreen(),
  'bulk_actions': (_) => const AdminBulkScreen(),
  'catalogue_health': (_) => const CatalogueHealthScreen(),
  'cust_help_requests': (_) => const MySupportRequestsScreen(),
  'cust_reorder_due': (_) => const ReorderScreen(),
  'cust_saved_lists': (_) => const OrderListsScreen(),
  'delivery_ops': (_) => const AdminDeliveryOpsScreen(),
  'demand_engine': (_) => const AdminDemandEngineScreen(),
  'gst': (_) => const AdminGstScreen(),
  'khata': (_) => const KhataScreen(),
  'loyalty': (_) => const LoyaltyAdminScreen(),
  'money': (_) => const AdminMoneyScreen(),
  'near_listing': (_) => const NearListingScreen(),
  'notify_center': (_) => const NotifyCenterScreen(),
  'notify_cost': (_) => const NotifyCostScreen(),
  'order_alerts': (_) => const OrderAlertsScreen(),
  'order_closure': (_) => const AdminOrderClosureScreen(),
  'paper_sale': (_) => const PaperSaleScreen(),
  'payment_alerts': (_) => const PaymentAlertsScreen(),
  'pharmacy_audit': (_) => const PharmacyAuditScreen(),
  'pharmacy_expiry': (_) => const PharmacyExpiryScreen(),
  'pharmacy_gst': (_) => const PharmacyGstScreen(),
  'pharmacy_owner': (_) => const PharmacyOwnerScreen(),
  'pharmacy_parcel': (_) => const ParcelCountHomeScreen(),
  'pharmacy_radar': (_) => const PharmacyRadarScreen(),
  'pharmacy_reorder': (_) => const PharmacyReorderScreen(),
  'pharmacy_stock': (_) => const PharmacyStockScreen(),
  'pharmacy_variance': (_) => const PharmacyVarianceScreen(),
  'pharmacy_vault': (_) => const PharmacyVaultScreen(),
  'pnl': (_) => const PnlScreen(),
  'pos': (_) => const PosScreen(),
  'pos_upi': (_) => const PosUpiSetupScreen(),
  'price_check': (_) => const PharmacyOverpayScreen(),
  'pricing': (_) => const AdminPricingScreen(),
  'pricing_backfill': (_) => const PricingBackfillScreen(),
  'profile': (_) => const ProfileScreen(),
  'purchases': (_) => const PurchasesScreen(),
  'px_exchange': (_) => const PxScreen(),
  'refill': (_) => const PharmacyRefillScreen(),
  'reorder': (_) => const ReorderAdminScreen(),
  'reviews': (_) => const AdminReviewsScreen(),
  'rx_scan': (_) => const RxScanScreen(),
  'scope_audit': (_) => const AdminScopeAuditScreen(),
  'settlement': (_) => const SettlementScreen(),
  'stock_on_hand': (_) => const AdminStockOnHandScreen(),
  'supplier_accounts': (_) => const AdminSupplierAccountScreen(),
  'unmapped_companies': (_) => const UnmappedCompaniesScreen(),
  'wa_campaigns': (_) => const WaCampaignsScreen(),
  'wa_diagnosis': (_) => const WaDiagnosisScreen(),
  'wa_drips': (_) => const WaDripsScreen(),
  'wa_ops': (_) => const WaOpsScreen(),
  'wa_segments': (_) => const WaSegmentsScreen(),
  'wa_templates': (_) => const WaTemplatesScreen(),
  'whatsapp': (_) => const WaHomeScreen(),
};
