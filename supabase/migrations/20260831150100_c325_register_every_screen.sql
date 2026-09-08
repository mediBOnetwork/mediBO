-- CHANGE #325 — register EVERY existing screen. A screen absent from this
-- table does not render in nav at all, so "nothing may be missing" is a data
-- statement rather than a habit.
--
-- Nine of these screens (reorder, pnl, discount_slabs, loyalty,
-- unmapped_companies, delivery_ops, notify_cost, settlement, cron_health) had
-- no tappable way in at all before this change — they existed, worked, and
-- could only be reached by typing a URL, which by rule 11 means they did not
-- exist. They ship active because _handleAdminNav now has a case for each.
--
-- Mid-build they were parked at is_active=false, because home_shell.dart was
-- leased to another command and a registered tile whose route the router
-- cannot open renders perfectly and does nothing on tap (the #645/#646 bug).
-- Parking and un-parking were both a one-line UPDATE with no deploy, which is
-- the argument for a registry-driven nav in one sentence.

update feature_registry set category = 'orders'
  where feature_key in ('partner.inquiry','partner.supplier_orders','partner.collect',
                        'partner.count','partner.bag_mapping','partner.pack','partner.assign_delivery');
update feature_registry set category = 'money'
  where feature_key in ('partner.supplier_payment','partner.settlement','medibo.pricing',
                        'medibo.customer_payment','medibo.partner_settlement');
update feature_registry set category = 'comms'     where feature_key = 'medibo.marketing';
update feature_registry set category = 'parties'   where feature_key = 'medibo.customer_acquisition';
update feature_registry set category = 'catalogue' where feature_key = 'medibo.catalogue';

insert into feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface, badge_source,
   roles_allowed, deep_link)
values
  ('admin.fulfillment','Fulfilment','Orders & Fulfilment','truck','fulfillment',310,'medibo',false,'none',true,'orders','dashboard','disputes',array['admin','super_admin'],'/admin/go/fulfillment'),
  ('admin.order_alerts','New-order alerts','Orders & Fulfilment','alert','order_alerts',320,'medibo',false,'none',true,'orders','dashboard','order_alerts',array['admin','super_admin'],'/admin/go/order_alerts'),
  ('admin.order_closure','Order closure','Orders & Fulfilment','task','order_closure',330,'medibo',false,'none',true,'orders','dashboard','pending_orders',array['admin','super_admin'],'/admin/go/order_closure'),
  ('admin.bags','Bags','Orders & Fulfilment','qr','bags',340,'medibo',false,'none',true,'orders','dashboard',null,array['admin','super_admin'],'/admin/go/bags'),
  ('admin.reorder','Reorder & auto-reorders','Orders & Fulfilment','autorenew','reorder',350,'medibo',false,'none',true,'orders','dashboard',null,array['admin','super_admin'],'/admin/go/reorder'),
  ('admin.customers','Customers','Customers & Suppliers','people','customers',410,'medibo',false,'none',true,'parties','dashboard','pending_customers',array['admin','super_admin'],'/admin/go/customers'),
  ('admin.suppliers','Suppliers','Customers & Suppliers','inventory','suppliers',420,'medibo',false,'none',true,'parties','dashboard',null,array['admin','super_admin'],'/admin/go/suppliers'),
  ('admin.add_customer','Add Customer','Customers & Suppliers','person_add','add_customer',430,'medibo',false,'none',true,'parties','dashboard',null,array['admin','super_admin'],'/admin/go/add_customer'),
  ('admin.add_supplier','Add Supplier','Customers & Suppliers','add_business','add_supplier',440,'medibo',false,'none',true,'parties','dashboard',null,array['admin','super_admin'],'/admin/go/add_supplier'),
  ('admin.mr','MR Registrations','Customers & Suppliers','badge','mr',450,'medibo',false,'none',true,'parties','dashboard',null,array['admin','super_admin'],'/admin/go/mr'),
  ('admin.companies','Company Registrations','Customers & Suppliers','business','companies',460,'medibo',false,'none',true,'parties','dashboard',null,array['admin','super_admin'],'/admin/go/companies'),
  ('admin.unmapped_companies','Unmapped companies','Customers & Suppliers','link_off','unmapped_companies',470,'medibo',false,'none',true,'parties','dashboard',null,array['admin','super_admin'],'/admin/go/unmapped_companies'),
  ('admin.deletion_requests','Deletion Requests','Customers & Suppliers','person_remove','deletion_requests',480,'medibo',false,'none',true,'parties','dashboard','deletion_requests',array['admin','super_admin'],'/admin/go/deletion_requests'),
  ('admin.add_medicine','Add Medicine','Catalogue & Pricing','medication','add_medicine',510,'medibo',false,'none',true,'catalogue','dashboard',null,array['admin','super_admin'],'/admin/go/add_medicine'),
  ('admin.pricing_backfill','Product pricing','Catalogue & Pricing','rupee','pricing_backfill',520,'medibo',false,'none',true,'catalogue','dashboard',null,array['admin','super_admin'],'/admin/go/pricing_backfill'),
  ('admin.discount_slabs','Discount slabs','Catalogue & Pricing','percent','discount_slabs',530,'medibo',false,'none',true,'catalogue','dashboard',null,array['admin','super_admin'],'/admin/go/discount_slabs'),
  ('admin.loyalty','Loyalty','Catalogue & Pricing','stars','loyalty',540,'medibo',false,'none',true,'catalogue','dashboard',null,array['admin','super_admin'],'/admin/go/loyalty'),
  ('admin.delivery_partners','Delivery Partners','Delivery','moped','delivery_partners',610,'medibo',false,'none',true,'delivery','dashboard',null,array['admin','super_admin'],'/admin/go/delivery_partners'),
  ('admin.delivery_ops','Delivery operations','Delivery','route','delivery_ops',620,'medibo',false,'none',true,'delivery','dashboard',null,array['admin','super_admin'],'/admin/delivery-ops'),
  ('admin.whatsapp','WhatsApp','Communication','forum','whatsapp',710,'medibo',false,'none',true,'comms','dashboard',null,array['admin','super_admin'],'/admin/go/whatsapp'),
  ('admin.wa_templates','WhatsApp Templates','Communication','description','wa_templates',720,'medibo',false,'none',true,'comms','dashboard',null,array['admin','super_admin'],'/admin/go/wa_templates'),
  ('admin.wa_campaigns','WhatsApp Campaigns','Communication','campaign','wa_campaigns',730,'medibo',false,'none',true,'comms','dashboard',null,array['admin','super_admin'],'/admin/go/wa_campaigns'),
  ('admin.wa_segments','WhatsApp Segments','Communication','filter','wa_segments',740,'medibo',false,'none',true,'comms','dashboard',null,array['admin','super_admin'],'/admin/go/wa_segments'),
  ('admin.wa_drips','Sequences','Communication','timeline','wa_drips',750,'medibo',false,'none',true,'comms','dashboard',null,array['admin','super_admin'],'/admin/go/wa_drips'),
  ('admin.wa_ops','WhatsApp Ops','Communication','settings_suggest','wa_ops',760,'medibo',false,'none',true,'comms','dashboard',null,array['admin','super_admin'],'/admin/go/wa_ops'),
  ('admin.wa_diagnosis','WhatsApp delivery diagnosis','Communication','fact_check','wa_diagnosis',770,'medibo',false,'none',true,'comms','dashboard',null,array['admin','super_admin'],'/admin/go/wa_diagnosis'),
  ('admin.notify_center','Notification Centre','Communication','notifications','notify_center',780,'medibo',false,'none',true,'comms','dashboard',null,array['admin','super_admin'],'/admin/go/notify_center'),
  ('admin.admin_push','Push notifications','Communication','phonelink_ring','admin_push',790,'medibo',false,'none',true,'comms','dashboard',null,array['admin','super_admin'],'/admin/go/admin_push'),
  ('admin.notify_cost','Notification cost','Communication','payments','notify_cost',800,'medibo',false,'none',true,'comms','dashboard',null,array['admin','super_admin'],'/admin/go/notify_cost'),
  ('admin.bill_pipeline','Bill pipeline','Money','receipt','bill_pipeline',810,'medibo',false,'none',true,'money','dashboard','flagged_bills',array['admin','super_admin'],'/admin/go/bill_pipeline'),
  ('admin.gst','GST','Money','account_balance','gst',820,'medibo',false,'none',true,'money','dashboard',null,array['admin','super_admin'],'/admin/go/gst'),
  ('admin.pnl','Profit & loss','Money','trending_up','pnl',830,'medibo',false,'none',true,'money','dashboard',null,array['admin','super_admin'],'/admin/go/pnl'),
  ('admin.settlement','Partner settlement','Money','handshake','settlement',840,'medibo',false,'none',true,'money','dashboard',null,array['admin','super_admin'],'/admin/settlement'),
  ('admin.payment_upi','Payment and Partner','Money','qr','payment_upi',850,'medibo',false,'none',true,'money','dashboard',null,array['super_admin'],'/admin/go/payment_upi'),
  ('admin.manage_admins','Manage Admins','Admin & System','admin_panel','manage_admins',910,'medibo',false,'none',true,'system','dashboard',null,array['super_admin'],'/admin/go/manage_admins'),
  ('admin.dev_queue','Dev Queue','Admin & System','terminal','dev_queue',920,'medibo',false,'none',true,'system','dashboard',null,array['super_admin'],'/admin/go/dev_queue'),
  ('admin.scope_audit','Scope audit','Admin & System','rule','scope_audit',930,'medibo',false,'none',true,'system','dashboard',null,array['admin','super_admin'],'/admin/go/scope_audit'),
  ('admin.feature_gaps','Feature gaps','Admin & System','rule_folder','feature_gaps',940,'medibo',false,'none',true,'system','dashboard',null,array['admin','super_admin'],'/admin/feature-gaps'),
  ('admin.cron_health','Cron health','Admin & System','schedule','cron_health',950,'medibo',false,'none',true,'system','dashboard',null,array['super_admin'],'/admin/cron-health'),
  ('identity.view_profile','View Profile','Account','person','profile',10,'medibo',true,'read',true,'identity','profile',null,array['admin','super_admin','supplier','customer','delivery','worker','mr','company'],'/profile'),
  ('identity.logout','Logout','Account','logout','logout',20,'medibo',true,'read',true,'identity','profile',null,array['admin','super_admin','supplier','customer','delivery','worker','mr','company'],null)
on conflict (feature_key) do update set
  label = excluded.label, group_label = excluded.group_label,
  icon_key = excluded.icon_key, route_key = excluded.route_key,
  sort_order = excluded.sort_order, category = excluded.category,
  surface = excluded.surface, badge_source = excluded.badge_source,
  roles_allowed = excluded.roles_allowed, deep_link = excluded.deep_link,
  is_active = excluded.is_active;

-- The noun a count is counting, so "10 bills to review" is data rather than
-- string surgery in Dart.
update feature_registry set badge_noun = 'bills to review'   where feature_key = 'admin.bill_pipeline';
update feature_registry set badge_noun = 'pending orders'    where feature_key = 'admin.order_closure';
update feature_registry set badge_noun = 'orders to action'  where feature_key = 'admin.order_alerts';
update feature_registry set badge_noun = 'open disputes'     where feature_key = 'admin.fulfillment';
update feature_registry set badge_noun = 'pending sign-ups'  where feature_key = 'admin.customers';
update feature_registry set badge_noun = 'deletion requests' where feature_key = 'admin.deletion_requests';

-- Palette synonyms: typing "gst" finds the GST ledger because the registry
-- says so, not because Dart knows what GST is.
update feature_registry set search_terms = 'gst tax gstr input credit ledger' where feature_key = 'admin.gst';
update feature_registry set search_terms = 'bill billing invoice pipeline'    where feature_key = 'admin.bill_pipeline';
update feature_registry set search_terms = 'pnl profit loss margin'           where feature_key = 'admin.pnl';
update feature_registry set search_terms = 'whatsapp wa message'              where feature_key like 'admin.wa%';
update feature_registry set search_terms = 'push fcm firebase notification'   where feature_key = 'admin.admin_push';
update feature_registry set search_terms = 'price ptr rate margin'            where feature_key = 'admin.pricing_backfill';
update feature_registry set search_terms = 'rider courier delivery boy'       where feature_key in ('admin.delivery_partners','admin.delivery_ops');
update feature_registry set search_terms = 'pack bag collect count arrivals dispute' where feature_key = 'admin.fulfillment';
update feature_registry set search_terms = 'upi qr razorpay payment partner'  where feature_key = 'admin.payment_upi';
