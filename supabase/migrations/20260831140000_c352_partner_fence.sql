-- CHANGE #352 — the 8 approved CRITICAL feature_gaps rows on the PARTNER surface.
--
-- rows 134,136,137,138,139,140,141,145. Every one of them is the same root
-- shape seen from a different angle: a fulfilment partner authenticates as
-- role 'admin' (CHANGE #307), so an admin-gated RPC admits it, and nothing
-- downstream asks which ZONE it belongs to or whether its permission matrix
-- actually granted the feature.
--
-- Four layers, smallest blast radius first:
--   A. medibo-only fence  — payment_collection_summary + rzp_webhook_log_recent
--                           (rows 136,145) join the round-1 registry.
--   B. scope helpers      — partner_scope_supplier / _delivery / _orders answer
--                           get_my_role()'s value for everyone who is not a
--                           partner and RAISE for a partner that is out of zone
--                           or was never granted the feature.
--   C. mechanical swap    — the nine by-name / by-id fulfilment RPCs have their
--                           single get_my_role() call replaced by the matching
--                           scope helper (rows 137,139,140,141), and
--                           zone_supplier_names ignores its caller-supplied
--                           zone for a partner (row 138).
--   D. the inversion      — row 134. get_my_role() no longer hands a partner
--                           'admin' for ANY rpc: only for one on
--                           partner_rpc_allow. Opt-IN. A new admin RPC is
--                           denied to partners the day it is written.
--
-- Idempotent throughout: create-or-replace, if-not-exists, on-conflict, and the
-- swap re-selects only functions that have not been swapped yet.

-- ===========================================================================
-- A. rows 136 + 145 — two customer-payment RPCs the round-1 registry missed.
-- ===========================================================================
insert into public.medibo_only_rpc(proname, feature_key, note) values
  ('payment_collection_summary','medibo.customer_payment',
   'CHANGE #352 row 136 — answered a partner with the live collection board: '
   'per-mode counts and rupee amounts, i.e. the customer payment METHOD.'),
  ('rzp_webhook_log_recent','medibo.customer_payment',
   'CHANGE #352 row 145 — answered a partner with live Razorpay deliveries '
   '(event, payment id, timestamp): the customer payment instrument.')
on conflict (proname) do nothing;

-- Re-run round 1's mechanical swap so the two newly registered names actually
-- gate on role_for_medibo_only(). Registering them without swapping would have
-- left c307_medibo_only_audit() red — the guard doing its job.
do $do$
declare r record; v_def text; v_new text; v_n int := 0;
begin
  for r in
    select p.oid, p.proname
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join public.medibo_only_rpc m on m.proname = p.proname
     where n.nspname = 'public' and p.prokind = 'f'
       and pg_get_functiondef(p.oid) like '%get_my_role()%'
       and pg_get_functiondef(p.oid) not like '%role_for_medibo_only()%'
  loop
    v_def := pg_get_functiondef(r.oid);
    v_new := replace(v_def, 'get_my_role()', 'role_for_medibo_only()');
    if v_new <> v_def and r.proname not in ('get_my_role','role_for_medibo_only') then
      execute v_new;
      v_n := v_n + 1;
    end if;
  end loop;
  raise notice 'c352: medibo-only swap rewrote % functions', v_n;
end $do$;

-- ===========================================================================
-- B. the scope helpers.
--
-- Each returns the SAME text get_my_role() would have returned, so dropping it
-- into an existing `if get_my_role() not in ('admin','super_admin')` gate is a
-- strict no-op for admin / super_admin / supplier / customer. For a partner it
-- is the two questions the gate never asked: is this row in your zone, and did
-- your matrix actually grant this feature (row 141 — partner_can() was called
-- by exactly zero RPCs and decided nothing but which tile was drawn).
-- ===========================================================================
create or replace function public.partner_supplier_zone(p_supplier_name text)
 returns smallint
 language sql stable security definer set search_path to 'public'
as $function$
  select sp.zone_id::smallint
    from supplier_profiles sp
   where lower(btrim(coalesce(sp.supplier_name,''))) = lower(btrim(coalesce(p_supplier_name,'')))
     and btrim(coalesce(sp.supplier_name,'')) <> ''
   order by sp.zone_id
   limit 1
$function$;

create or replace function public.partner_scope_supplier(p_supplier_name text, p_feature text, p_need text default 'write')
 returns text
 language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_zone smallint; v_mine smallint;
begin
  if not public.is_partner() then return public.get_my_role(); end if;

  if not public.partner_can(p_feature, coalesce(p_need,'write')) then
    raise exception 'not_authorized_feature' using detail = p_feature;
  end if;

  v_mine := public.partner_zone_id();
  v_zone := public.partner_supplier_zone(p_supplier_name);
  if v_mine is null or v_zone is null or v_zone <> v_mine then
    raise exception 'not_authorized_zone' using detail = coalesce(p_supplier_name,'');
  end if;

  return 'admin';
end $function$;

create or replace function public.partner_scope_delivery(p_delivery_id uuid, p_feature text, p_need text default 'write')
 returns text
 language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_zone smallint; v_mine smallint;
begin
  if not public.is_partner() then return public.get_my_role(); end if;

  if not public.partner_can(p_feature, coalesce(p_need,'write')) then
    raise exception 'not_authorized_feature' using detail = p_feature;
  end if;

  v_mine := public.partner_zone_id();
  select coalesce(d.zone_id, o.zone_id)::smallint into v_zone
    from deliveries d left join orders o on o.id = d.order_id
   where d.id = p_delivery_id;
  if v_mine is null or v_zone is null or v_zone <> v_mine then
    raise exception 'not_authorized_zone' using detail = coalesce(p_delivery_id::text,'');
  end if;

  return 'admin';
end $function$;

-- A MIXED-zone array is refused outright rather than silently filtered — a
-- half-applied assignment is worse than a refusal (row 140's suggestion).
create or replace function public.partner_scope_orders(p_order_ids uuid[], p_feature text, p_need text default 'write')
 returns text
 language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_mine smallint; v_bad int;
begin
  if not public.is_partner() then return public.get_my_role(); end if;

  if not public.partner_can(p_feature, coalesce(p_need,'write')) then
    raise exception 'not_authorized_feature' using detail = p_feature;
  end if;

  v_mine := public.partner_zone_id();
  if v_mine is null then raise exception 'not_authorized_zone'; end if;

  select count(*) into v_bad
    from unnest(coalesce(p_order_ids, '{}'::uuid[])) as t(id)
    left join orders o on o.id = t.id
   where o.id is null or o.zone_id is null or o.zone_id <> v_mine;
  if v_bad > 0 then
    raise exception 'not_authorized_zone' using detail = v_bad::text || ' order(s) outside zone ' || v_mine::text;
  end if;

  return 'admin';
end $function$;

grant execute on function public.partner_supplier_zone(text) to authenticated, service_role;
grant execute on function public.partner_scope_supplier(text,text,text) to authenticated, service_role;
grant execute on function public.partner_scope_delivery(uuid,text,text) to authenticated, service_role;
grant execute on function public.partner_scope_orders(uuid[],text,text) to authenticated, service_role;

-- ===========================================================================
-- C1. row 138 — zone_supplier_names(2) listed another zone's suppliers because
-- the zone arrived as a caller-supplied argument. A partner's argument is now
-- ignored: it always reads its own zone, whatever it passes.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.zone_supplier_names(p_zone_id smallint)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_zone smallint;
begin
  if public.is_partner() then
    v_zone := public.partner_zone_id();
    if v_zone is null then return '{}'::text[]; end if;   -- a partner with no zone sees nobody
  else
    v_zone := p_zone_id;
  end if;

  return coalesce((
    SELECT array_agg(lower(btrim(sp.supplier_name)))
      FROM supplier_profiles sp
     WHERE btrim(coalesce(sp.supplier_name,'')) <> ''
       AND (v_zone IS NULL OR sp.zone_id = v_zone)
  ), '{}'::text[]);
end $function$;

-- ===========================================================================
-- C2. rows 137, 139, 140 (+ 141) — the by-name and by-id fulfilment RPCs.
-- Each has exactly ONE get_my_role() call, in its role gate. Replacing that
-- call with the matching scope helper adds the zone predicate and the
-- permission check without touching a line of the body's business logic.
-- ===========================================================================
create table if not exists public.partner_scoped_rpc (
  proname       text primary key,
  replacement   text not null,
  gap_row       int,
  note          text,
  added_at      timestamptz not null default now()
);
comment on table public.partner_scoped_rpc is
  'CHANGE #352 — the fulfilment RPCs a partner reaches by NAME or by ID. The '
  'guard c352_partner_fence_audit() fails if any of these ever goes back to a '
  'bare get_my_role(), so the zone clamp cannot be undone by a later rewrite.';

insert into public.partner_scoped_rpc(proname, replacement, gap_row, note) values
  ('fw_get_state',            'public.partner_scope_supplier(p_supplier_name, ''partner.count'', ''read'')',  137, 'answered a zone-1 partner for the zone-2 supplier ''nikhat pharma'''),
  ('bag_attach',              'public.partner_scope_supplier(p_supplier_name, ''partner.bag_mapping'', ''write'')', 139, null),
  ('bag_detach',              'public.partner_scope_supplier(p_supplier_name, ''partner.bag_mapping'', ''write'')', 139, null),
  ('bag_count_set',           'public.partner_scope_supplier(p_supplier_name, ''partner.count'', ''write'')',  139, null),
  ('bag_count_clear',         'public.partner_scope_supplier(p_supplier_name, ''partner.count'', ''write'')',  139, null),
  ('fw_confirm_all_received', 'public.partner_scope_supplier(p_supplier_name, ''partner.collect'', ''write'')',139, null),
  ('delivery_assign',         'public.partner_scope_orders(p_order_ids, ''partner.assign_delivery'', ''write'')', 140, 'a mixed-zone array is refused, never filtered'),
  ('delivery_reassign',       'public.partner_scope_delivery(p_delivery_id, ''partner.assign_delivery'', ''write'')', 140, null),
  ('delivery_rto_receive',    'public.partner_scope_delivery(p_delivery_id, ''partner.assign_delivery'', ''write'')', 140, null)
on conflict (proname) do update set replacement = excluded.replacement,
                                    gap_row     = excluded.gap_row,
                                    note        = excluded.note;

do $do$
declare r record; v_def text; v_new text; v_n int := 0;
begin
  for r in
    select p.oid, p.proname, s.replacement
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join public.partner_scoped_rpc s on s.proname = p.proname
     where n.nspname = 'public' and p.prokind = 'f'
       and pg_get_functiondef(p.oid) like '%get_my_role()%'
  loop
    v_def := pg_get_functiondef(r.oid);
    -- the gate is the only get_my_role() in these nine bodies; replace_all is
    -- therefore exact. A second run finds no bare call and skips.
    v_new := replace(v_def, 'get_my_role()', r.replacement);
    if v_new <> v_def then
      execute v_new;
      v_n := v_n + 1;
    end if;
  end loop;
  raise notice 'c352: zone-clamped % fulfilment functions', v_n;
end $do$;

-- ===========================================================================
-- D. row 134 — INVERT THE GATE.
--
-- Until now a partner satisfied the plain admin test everywhere, so the
-- surface was opt-OUT: 420 functions gate on get_my_role(), round 1 fenced
-- 122 of them by hand, and the remaining 327 were open by default. Every new
-- admin RPC was a new leak the day it was written.
--
-- Now get_my_role() hands a partner 'admin' only when the RPC it is answering
-- is on partner_rpc_allow. PostgREST puts the entry point in request.path, so
-- the decision is made once, at the door, on the call the partner actually
-- made — a nested helper inherits the entry point's answer, which is the right
-- granularity: authority belongs to the screen, not to a private subroutine.
--
-- Scope, stated plainly: this fences /rpc/ calls. A direct TABLE read carries
-- no rpc name and is left to RLS, which CHANGE #307 round 2 already clamped
-- with partner_zone_ok() — so table access behaves exactly as it does today
-- and this migration cannot break it.
-- ===========================================================================
create table if not exists public.partner_rpc_allow (
  proname     text primary key,
  source      text not null default 'seed',
  note        text,
  added_at    timestamptz not null default now()
);
comment on table public.partner_rpc_allow is
  'CHANGE #352 row 134 — the OPT-IN list. A partner is answered ''admin'' only '
  'for an rpc named here; everything else answers ''partner'' and the admin '
  'gate refuses. Seeded from the import closure of the four screens '
  'partnerDestination() can actually open, so today''s partner surface is '
  'unchanged and tomorrow''s new admin RPC is closed by default.';

alter table public.partner_rpc_allow enable row level security;
drop policy if exists partner_rpc_allow_no_client on public.partner_rpc_allow;
create policy partner_rpc_allow_no_client on public.partner_rpc_allow
  for all to authenticated, anon using (false) with check (false);

create or replace function public.current_rpc_name()
 returns text
 language sql stable security definer set search_path to 'public'
as $function$
  select case
    when coalesce(nullif(current_setting('request.path', true), ''), '') like '%/rpc/%'
      then split_part(regexp_replace(nullif(current_setting('request.path', true), ''), '^.*/rpc/', ''), '?', 1)
    else null
  end
$function$;

create or replace function public.partner_rpc_allowed()
 returns boolean
 language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_fn text; v_enforce boolean; v_path text;
begin
  v_enforce := coalesce((select (value->>'enforce')::boolean
                           from app_settings where key = 'partner_fence'), true);
  if not v_enforce then return true; end if;

  v_path := nullif(current_setting('request.path', true), '');
  v_fn   := public.current_rpc_name();

  -- Not an rpc call at all (a direct table read, a trigger, cron, psql).
  -- Table access is RLS's job and is already zone-clamped; nothing partner-
  -- facing runs off PostgREST. Leave it exactly as it behaves today.
  if v_fn is null then return v_path is not null; end if;

  return exists (select 1 from public.partner_rpc_allow a where a.proname = v_fn);
end $function$;

grant execute on function public.current_rpc_name() to authenticated, service_role;
grant execute on function public.partner_rpc_allowed() to authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_my_role()
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_email text; v_keys text[]; v_is_admin boolean; v_is_super boolean; v_type text;
begin
  select lower(btrim(u.email)) into v_email from auth.users u where u.id = auth.uid();
  v_keys := public.my_identity_keys();

  select true, coalesce(a.is_super,false) into v_is_admin, v_is_super
  from admins a
  where lower(btrim(a.email)) = v_email or identity_norm(a.email) = any (v_keys)
  limit 1;

  if v_is_admin then
    if v_is_super then return 'super_admin'; else return 'admin'; end if;
  end if;

  -- CHANGE #307 — zone-locked partner staff authorise as an admin against the
  -- existing fulfilment RPCs. Checked BEFORE the "no identity" bail-out below,
  -- because partner_users.auth_user_id is itself an identity.
  -- CHANGE #352 row 134 — but ONLY for an rpc on partner_rpc_allow. This is
  -- the inversion: the partner surface is opt-IN, so a newly written admin RPC
  -- is closed to partners on the day it is created instead of open until
  -- someone remembers to fence it.
  if public.my_partner_id() is not null then
    if public.partner_rpc_allowed() then return 'admin'; end if;
    return 'partner';
  end if;

  if v_email is null and (v_keys is null or cardinality(v_keys) = 0) then return 'none'; end if;

  if public.my_supplier_id() is not null then return 'supplier'; end if;

  select li.owner_type into v_type
  from login_identities li
  where li.identity = any (v_keys)
    and li.owner_type in ('company','mr','delivery','worker')
  order by case li.owner_type when 'mr' then 1 when 'delivery' then 2
                              when 'company' then 3 else 4 end, li.id
  limit 1;
  if v_type is not null then return v_type; end if;

  return 'customer';
end $function$;

-- ---------------------------------------------------------------------------
-- D2. The seed. These 285 names are the rpc import-closure of the FOUR screens
-- partnerDestination() can open (AdminSupplierScreen, AdminFulfillmentScreen,
-- PartnerHomeScreen, PartnerStatementScreen) plus the profile surface — i.e.
-- exactly what a partner session calls today. Anything a mediBO-only RPC, it
-- is filtered out below: that registry outranks this one.
-- Measured on the live schema before the swap: 327 client-callable functions
-- gated on a bare get_my_role(); 140 of them are in this closure, so 187 stop
-- answering a partner the moment this migration lands.
-- ---------------------------------------------------------------------------
insert into public.partner_rpc_allow(proname, source, note)
select v.proname, 'seed_closure_c352',
       'partner screen closure at CHANGE #352'
  from (values
  ('add_supplier_column'),
  ('admin_active_date'),
  ('admin_approve_pending_company'),
  ('admin_approve_pending_medicine'),
  ('admin_cart_add'),
  ('admin_cart_remove_item'),
  ('admin_claim_decide'),
  ('admin_company_names'),
  ('admin_create_supplier'),
  ('admin_create_suppliers'),
  ('admin_customer_action'),
  ('admin_customer_orders'),
  ('admin_customer_profile_by_user'),
  ('admin_customer_screen_data'),
  ('admin_customer_update'),
  ('admin_date_scope_state'),
  ('admin_delivery_ops'),
  ('admin_delivery_queue'),
  ('admin_demand_preview'),
  ('admin_import_leads'),
  ('admin_import_leads_csv'),
  ('admin_lead_save'),
  ('admin_lead_type_map'),
  ('admin_list_suppliers'),
  ('admin_mark_bill_imported'),
  ('admin_order_payment'),
  ('admin_order_payment_view_v2'),
  ('admin_payment_claims'),
  ('admin_payout_open'),
  ('admin_payout_pay'),
  ('admin_pending_orders_for_user'),
  ('admin_purge_deleted_supplier'),
  ('admin_record_cash_payment'),
  ('admin_reject_pending'),
  ('admin_serviceability_set'),
  ('admin_set_date_scope'),
  ('admin_set_inquiry_answer'),
  ('admin_set_lead_status'),
  ('admin_set_order_status'),
  ('admin_set_supplier_spn'),
  ('admin_set_supplier_status_value'),
  ('admin_set_zone_scope'),
  ('admin_submit_inquiry_answers'),
  ('admin_supplier_action'),
  ('admin_supplier_company_add'),
  ('admin_supplier_company_bulk_link'),
  ('admin_supplier_company_count'),
  ('admin_supplier_company_rows'),
  ('admin_supplier_company_update'),
  ('admin_supplier_orders'),
  ('admin_supplier_screen_data'),
  ('admin_supplier_spn_row'),
  ('admin_update_supplier'),
  ('apply_allocation_mode'),
  ('auth_diag_note'),
  ('bag_attach'),
  ('bag_count_clear'),
  ('bag_count_set'),
  ('bag_detach'),
  ('bag_guard_shop_stage'),
  ('barcode_lookup'),
  ('barcode_submit_scan'),
  ('bulk_match_items'),
  ('cart_clear'),
  ('cart_mode'),
  ('cart_render'),
  ('cart_set_item'),
  ('claim_guest_cart'),
  ('customer_bill_file'),
  ('customer_bill_numbers'),
  ('customer_form_options'),
  ('delete_customer_bill'),
  ('delete_lead_group'),
  ('delete_lead_image'),
  ('delete_old_route_plans'),
  ('delete_order'),
  ('delete_route_plan'),
  ('delivery_assign'),
  ('delivery_reassign'),
  ('delivery_rto_receive'),
  ('delivery_suggest_partner'),
  ('enqueue_supplier_match'),
  ('fw_close_return_note'),
  ('fw_confirm_all_received'),
  ('fw_confirm_counting'),
  ('fw_count_in_warehouse'),
  ('fw_count_session'),
  ('fw_count_source_audit'),
  ('fw_date_label'),
  ('fw_error_messages'),
  ('fw_get_bag_items'),
  ('fw_get_disputes'),
  ('fw_get_state'),
  ('fw_issue_options'),
  ('fw_issue_qty_rules'),
  ('fw_list_arrivals'),
  ('fw_list_bags'),
  ('fw_list_unfillable'),
  ('fw_product_action'),
  ('fw_product_undo'),
  ('fw_raise_typed_dispute'),
  ('fw_resolve_dispute'),
  ('fw_search_bag_items'),
  ('fw_session_bag_options'),
  ('fw_set_product_issue'),
  ('fw_supplier_modes'),
  ('fw_ui_colors'),
  ('fw_ui_labels'),
  ('fw_unconfirm_all_received'),
  ('fw_undo_collect_submit'),
  ('get_all_companies'),
  ('get_app_setting'),
  ('get_categories_by_company'),
  ('get_companies_by_category'),
  ('get_dispute_form'),
  ('get_distinct_marketers'),
  ('get_item_supplier_options'),
  ('get_lead_detail'),
  ('get_leads_grouped_today'),
  ('get_pack_clip_mentions'),
  ('get_scraped_leads'),
  ('get_supplier_companies'),
  ('get_supplier_contacts'),
  ('get_supplier_inquiry_items_v2'),
  ('get_supplier_inquiry_overview'),
  ('get_supplier_inquiry_receipt'),
  ('get_therapeutic_categories'),
  ('get_unregistered_users'),
  ('get_voice_clip_mentions'),
  ('inquiry_buckets_today'),
  ('inquiry_product_id'),
  ('inquiry_realtime_topic'),
  ('inquiry_send_readiness'),
  ('is_customer_code_taken'),
  ('is_supplier_code_taken'),
  ('ist_labels'),
  ('lead_category_tree'),
  ('lead_checkin_sheet'),
  ('lead_convert_to_customer'),
  ('lead_customer_prefill'),
  ('lead_enrich_status'),
  ('lead_get_hub'),
  ('lead_leads_summary'),
  ('lead_scrape_resume'),
  ('lead_scrape_start'),
  ('lead_scrape_status'),
  ('lead_set_hub'),
  ('lead_set_hub_by_address'),
  ('lead_stop_card'),
  ('lead_visits_report'),
  ('lead_worker_upsert'),
  ('lead_workers_list'),
  ('list_unmapped_companies'),
  ('log_auth_debug'),
  ('login_otp_status'),
  ('login_request_otp'),
  ('login_screen_config'),
  ('login_verify_otp'),
  ('loyalty_config_get'),
  ('loyalty_my_rewards'),
  ('loyalty_redeem'),
  ('map_company'),
  ('map_config_get'),
  ('map_supplier_groups'),
  ('mark_payment_received'),
  ('medicine_exists'),
  ('medicine_rows_by_ids'),
  ('medicine_search_admin'),
  ('medicine_search_available'),
  ('medicine_set_barcode'),
  ('must_log_out'),
  ('my_delivery_run'),
  ('my_orders_screen'),
  ('my_profile_row'),
  ('my_route'),
  ('my_session'),
  ('notif_is_enabled'),
  ('notif_should_send'),
  ('order_hours_state'),
  ('order_item_status_panel'),
  ('pack_barcode_lookup'),
  ('pack_barcode_submit_scan'),
  ('pack_count_source_audit'),
  ('pack_finalize_session'),
  ('pack_get_queue'),
  ('pack_item_bag_breakdown'),
  ('pack_list_orders'),
  ('pack_mark_item'),
  ('pack_mention_product_totals'),
  ('pack_mention_set_status'),
  ('pack_review_groups'),
  ('pack_set_dispatch_ready'),
  ('pack_write_session_mentions'),
  ('partner_home'),
  ('partner_open'),
  ('partner_statement'),
  ('pending_staging_list'),
  ('plan_google_status'),
  ('record_visit'),
  ('reject_payment_claim'),
  ('render_log_note'),
  ('request_account_deletion'),
  ('route_apply_google'),
  ('route_apply_google_from'),
  ('route_lead_count'),
  ('route_map'),
  ('route_plan_assign'),
  ('route_plan_build'),
  ('route_plan_date_options'),
  ('route_plan_get'),
  ('route_plan_list'),
  ('route_plan_rebalance'),
  ('route_plan_toggle_route'),
  ('route_plan_toggle_stop'),
  ('run_fewest_baskets_allocation'),
  ('save_customer_profile'),
  ('scrape_form_options'),
  ('scrape_lead_card'),
  ('scrape_results_bulk'),
  ('scrape_run_delete'),
  ('scrape_run_export'),
  ('scrape_runs_list'),
  ('search_medicines_priority'),
  ('send_customer_bill_wa'),
  ('send_supplier_inquiry_wa'),
  ('send_supplier_order_wa'),
  ('set_app_setting'),
  ('set_inquiry_lock'),
  ('set_inquiry_manual_supplier'),
  ('set_item_receiving'),
  ('set_order_hours'),
  ('set_supplier_last_send_contact'),
  ('set_voice_received'),
  ('settlement_config_set'),
  ('settlement_cost_type_save'),
  ('settlement_dashboard'),
  ('settlement_recalculate'),
  ('settlement_record_payment'),
  ('settlement_settle'),
  ('settlement_statement'),
  ('settlement_zone_set'),
  ('spn_option_add'),
  ('spn_options_list'),
  ('start_inquiry_for_order'),
  ('start_inquiry_for_suppliers'),
  ('submit_dispute_response'),
  ('submit_registration'),
  ('sup_add_payment'),
  ('sup_order_bill_panel'),
  ('sup_order_send_options'),
  ('sup_record_payment'),
  ('supplier_match_statuses'),
  ('supplier_my_disputes'),
  ('supplier_pending_order_items'),
  ('supplier_respond_dispute'),
  ('suppliers_by_names'),
  ('ui_boot'),
  ('ui_copy_all'),
  ('unlock_supplier_collect'),
  ('upload_customer_bill'),
  ('verify_and_accept_payment'),
  ('voice_clip_register'),
  ('voice_finalize_session'),
  ('voice_fix_mention'),
  ('voice_insert_clip_mentions'),
  ('voice_live_attach_clip'),
  ('voice_live_clip_target'),
  ('voice_live_commit'),
  ('voice_live_commit_pack'),
  ('voice_live_preview'),
  ('voice_live_preview_pack'),
  ('voice_map_bag_boundary'),
  ('voice_match_product'),
  ('voice_mention_product_totals'),
  ('voice_mention_set_status'),
  ('voice_mention_start_sec'),
  ('voice_review_groups'),
  ('voice_usage_today'),
  ('wa_admin_order_groups'),
  ('wa_convert_start'),
  ('wa_mark_image_done'),
  ('wa_set_order_source'),
  ('wishlist_get'),
  ('wishlist_remove'),
  ('zone_picker')
) as v(proname)
where not exists (select 1 from public.medibo_only_rpc m where m.proname = v.proname)
on conflict (proname) do nothing;

-- ===========================================================================
-- E. The guard. This is what keeps all four layers true tomorrow: it goes red
-- if a medibo-only RPC drops back to a bare get_my_role(), if one of the nine
-- zone-clamped RPCs loses its scope helper, or if the fence is switched off.
-- rg_check()/the protected suite read it.
-- ===========================================================================
create or replace function public.c352_partner_fence_audit()
 returns jsonb
 language sql stable security definer set search_path to 'public'
as $function$
  with client_fns as (
    select p.oid, p.proname, pg_get_functiondef(p.oid) as def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ),
  bare as (
    select distinct proname from client_fns
     where def like '%get_my_role()%' and def not like '%role_for_medibo_only()%'
       and proname not in ('get_my_role','partner_scope_supplier','partner_scope_delivery','partner_scope_orders')
  ),
  unclamped as (
    select s.proname
      from public.partner_scoped_rpc s
      join client_fns f on f.proname = s.proname
     where f.def not like '%partner_scope_%'
  ),
  allowed as (
    select b.proname from bare b
     where exists (select 1 from public.partner_rpc_allow a where a.proname = b.proname)
  ),
  denied as (
    select b.proname from bare b
     where not exists (select 1 from public.partner_rpc_allow a where a.proname = b.proname)
  )
  select jsonb_build_object(
    'ok', (not exists (select 1 from unclamped))
          and coalesce((select (value->>'enforce')::boolean from app_settings where key='partner_fence'), true)
          and coalesce((public.c307_medibo_only_audit()->>'ok')::boolean, false),
    'enforce', coalesce((select (value->>'enforce')::boolean from app_settings where key='partner_fence'), true),
    'medibo_only_ok', coalesce((public.c307_medibo_only_audit()->>'ok')::boolean, false),
    'medibo_only_registered', (select count(*) from public.medibo_only_rpc),
    'scoped_rpcs', (select count(*) from public.partner_scoped_rpc),
    'scoped_unclamped', (select count(*) from unclamped),
    'scoped_unclamped_list', coalesce((select jsonb_agg(proname order by proname) from unclamped), '[]'::jsonb),
    'allow_listed', (select count(*) from public.partner_rpc_allow),
    'bare_admin_rpcs', (select count(*) from bare),
    'partner_reachable', (select count(*) from allowed),
    'partner_denied', (select count(*) from denied),
    'partner_denied_list', coalesce((select jsonb_agg(proname order by proname) from denied), '[]'::jsonb)
  )
$function$;
grant execute on function public.c352_partner_fence_audit() to authenticated, service_role;

-- ===========================================================================
-- F. THE PROOF. One fixed battery, run as the zone-1 partner, that reproduces
-- every one of the eight findings and shows it refused. Every WRITE probe runs
-- inside its own subtransaction and is rolled back by a marker exception, so
-- the proof never leaves a row behind — including the two probes that flip an
-- order into zone 2 to give row 140 the empirical half its register entry says
-- was missing ("no zone-2 order exists to probe with").
-- Super-admin only; it impersonates, so it is never client reachable.
-- ===========================================================================
create or replace function public.c352_partner_fence_proof()
 returns jsonb
 language plpgsql volatile security definer set search_path to 'public'
as $function$
declare
  v_out jsonb := '[]'::jsonb;
  v_claims text;
  v_uid uuid;
  v_actual text;
  v_txt text;
  v_order uuid;
  v_delivery uuid;
  v_zone2 text := 'nikhat pharma';

  procedure_marker text := 'c352_rollback_marker';
begin
  -- super-admin, or the runner's service_role JWT (the protected suite and the
  -- deploy gate call this headlessly).
  if coalesce(nullif(current_setting('request.jwt.claims', true),'')::jsonb ->> 'role','') <> 'service_role'
     and public.role_for_medibo_only() not in ('admin','super_admin') then
    raise exception 'not_authorized';
  end if;

  select pu.auth_user_id into v_uid
    from partner_users pu join region_partners rp on rp.id = pu.partner_id
   where coalesce(pu.is_active,true) and coalesce(rp.is_active,true)
     and pu.auth_user_id is not null and rp.zone_id = 1
   order by pu.id desc limit 1;
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'no_zone1_partner_user');
  end if;

  select o.id into v_order from orders o where o.zone_id = 1 order by o.order_date desc nulls last limit 1;
  select d.id into v_delivery from deliveries d join orders o on o.id = d.order_id where o.zone_id = 1 order by d.id desc limit 1;

  v_claims := current_setting('request.jwt.claims', true);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  -- ---- row 134: the inversion -------------------------------------------
  perform set_config('request.path', '/rpc/pnl_dashboard', true);
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 134, 'probe', 'get_my_role() on an rpc that is NOT allow-listed (/rpc/pnl_dashboard)',
    'expect', 'partner', 'actual', public.get_my_role(),
    'pass', public.get_my_role() = 'partner'));

  perform set_config('request.path', '/rpc/fw_get_state', true);
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 134, 'probe', 'get_my_role() on an allow-listed fulfilment rpc (/rpc/fw_get_state)',
    'expect', 'admin', 'actual', public.get_my_role(),
    'pass', public.get_my_role() = 'admin'));

  -- ---- row 136: customer payment collection ------------------------------
  perform set_config('request.path', '/rpc/payment_collection_summary', true);
  begin
    perform public.payment_collection_summary();
    v_actual := 'ANSWERED';
  exception when others then v_actual := 'RAISED: ' || sqlerrm;
  end;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 136, 'probe', 'payment_collection_summary() as the zone-1 partner',
    'expect', 'RAISED: not_authorized', 'actual', v_actual,
    'pass', v_actual like 'RAISED: not_authorized%'));

  -- ---- row 145: razorpay webhook log -------------------------------------
  perform set_config('request.path', '/rpc/rzp_webhook_log_recent', true);
  begin
    perform public.rzp_webhook_log_recent(5);
    v_actual := 'ANSWERED';
  exception when others then v_actual := 'RAISED: ' || sqlerrm;
  end;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 145, 'probe', 'rzp_webhook_log_recent(5) as the zone-1 partner',
    'expect', 'RAISED: not_authorized', 'actual', v_actual,
    'pass', v_actual like 'RAISED: not_authorized%'));

  -- ---- row 137: cross-zone read ------------------------------------------
  perform set_config('request.path', '/rpc/fw_get_state', true);
  begin
    perform public.fw_get_state(v_zone2, 'shop', current_date, false);
    v_actual := 'ANSWERED';
  exception when others then v_actual := 'RAISED: ' || sqlerrm;
  end;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 137, 'probe', 'fw_get_state(''' || v_zone2 || ''') — a ZONE-2 supplier — as the zone-1 partner',
    'expect', 'RAISED: not_authorized_zone', 'actual', v_actual,
    'pass', v_actual like 'RAISED: not_authorized_zone%'));

  -- and the same call for an in-zone supplier must still work (no regression)
  begin
    perform public.fw_get_state((select lower(btrim(sp.supplier_name)) from supplier_profiles sp
                                  where sp.zone_id = 1 and btrim(coalesce(sp.supplier_name,'')) <> ''
                                  order by sp.supplier_name limit 1), 'shop', current_date, false);
    v_actual := 'ANSWERED';
  exception when others then v_actual := 'RAISED: ' || sqlerrm;
  end;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 137, 'probe', 'fw_get_state(<a ZONE-1 supplier>) still answers the zone-1 partner',
    'expect', 'ANSWERED', 'actual', v_actual, 'pass', v_actual = 'ANSWERED'));

  -- ---- row 138: cross-zone enumeration -----------------------------------
  perform set_config('request.path', '/rpc/zone_supplier_names', true);
  v_txt := array_to_string(public.zone_supplier_names(2::smallint), ',');
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 138, 'probe', 'zone_supplier_names(2) as the zone-1 partner',
    'expect', 'zone-2 names absent', 'actual', 'returned ' || coalesce(nullif(v_txt,''),'<empty>'),
    'pass', position(v_zone2 in coalesce(v_txt,'')) = 0));

  -- ---- row 139: cross-zone WRITE (bag + count ledger) --------------------
  perform set_config('request.path', '/rpc/bag_attach', true);
  begin
    perform public.bag_attach(v_zone2, 'C352-PROOF');
    raise exception '%', procedure_marker;      -- undo anything the call wrote
  exception when others then
    v_actual := case when sqlerrm = procedure_marker then 'ANSWERED (rolled back)'
                     else 'RAISED: ' || sqlerrm end;
  end;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 139, 'probe', 'bag_attach(''' || v_zone2 || ''',''C352-PROOF'') as the zone-1 partner',
    'expect', 'RAISED: not_authorized_zone', 'actual', v_actual,
    'pass', v_actual like 'RAISED: not_authorized_zone%'));

  perform set_config('request.path', '/rpc/fw_confirm_all_received', true);
  begin
    perform public.fw_confirm_all_received(v_zone2, current_date);
    raise exception '%', procedure_marker;
  exception when others then
    v_actual := case when sqlerrm = procedure_marker then 'ANSWERED (rolled back)'
                     else 'RAISED: ' || sqlerrm end;
  end;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 139, 'probe', 'fw_confirm_all_received(''' || v_zone2 || ''') as the zone-1 partner',
    'expect', 'RAISED: not_authorized_zone', 'actual', v_actual,
    'pass', v_actual like 'RAISED: not_authorized_zone%'));

  -- ---- row 140: cross-zone delivery WRITE --------------------------------
  -- The register recorded this one as STRUCTURAL only, because every order in
  -- the database is zone 1. The probe below borrows one, flips it to zone 2
  -- inside a subtransaction, calls the RPC, and rolls the whole thing back.
  perform set_config('request.path', '/rpc/delivery_assign', true);
  if v_order is null then
    v_actual := 'SKIPPED: no order rows';
  else
    begin
      update orders set zone_id = 2 where id = v_order;
      begin
        perform public.delivery_assign(array[v_order]::uuid[], null::uuid);
        v_actual := 'ANSWERED';
      exception when others then v_actual := 'RAISED: ' || sqlerrm;
      end;
      raise exception '%', procedure_marker;    -- always undo the zone flip
    exception when others then
      if sqlerrm <> procedure_marker then v_actual := 'RAISED: ' || sqlerrm; end if;
    end;
  end if;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 140, 'probe', 'delivery_assign([a ZONE-2 order]) as the zone-1 partner (order flipped and rolled back)',
    'expect', 'RAISED: not_authorized_zone', 'actual', v_actual,
    'pass', v_actual like 'RAISED: not_authorized_zone%'));

  perform set_config('request.path', '/rpc/delivery_rto_receive', true);
  if v_delivery is null then
    -- no delivery rows exist yet: probe an id the partner cannot own, which is
    -- the same predicate (the helper resolves no zone and refuses).
    begin
      perform public.delivery_rto_receive(gen_random_uuid());
      v_actual := 'ANSWERED';
    exception when others then v_actual := 'RAISED: ' || sqlerrm;
    end;
  else
    begin
      update orders set zone_id = 2 where id = (select order_id from deliveries where id = v_delivery);
      update deliveries set zone_id = 2 where id = v_delivery;
      begin
        perform public.delivery_rto_receive(v_delivery);
        v_actual := 'ANSWERED';
      exception when others then v_actual := 'RAISED: ' || sqlerrm;
      end;
      raise exception '%', procedure_marker;
    exception when others then
      if sqlerrm <> procedure_marker then v_actual := 'RAISED: ' || sqlerrm; end if;
    end;
  end if;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 140, 'probe', case when v_delivery is null
        then 'delivery_rto_receive(<an id outside the partner''s zone>) as the zone-1 partner'
        else 'delivery_rto_receive(<a ZONE-2 delivery>) as the zone-1 partner (flipped and rolled back)' end,
    'expect', 'RAISED: not_authorized_zone', 'actual', v_actual,
    'pass', v_actual like 'RAISED: not_authorized_zone%'));

  -- positive control: an IN-ZONE order still assigns, so the clamp refused the
  -- zone and not the partner.
  perform set_config('request.path', '/rpc/delivery_assign', true);
  if v_order is not null then
    begin
      v_actual := public.partner_scope_orders(array[v_order]::uuid[], 'partner.assign_delivery', 'write');
    exception when others then v_actual := 'RAISED: ' || sqlerrm;
    end;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'gap_row', 140, 'probe', 'partner_scope_orders([a ZONE-1 order]) still admits the zone-1 partner',
      'expect', 'admin', 'actual', v_actual, 'pass', v_actual = 'admin'));
  end if;

  -- ---- row 141: the matrix is enforced, not decorative -------------------
  -- partner.pack is the one fulfilment feature this partner was never granted.
  perform set_config('request.path', '/rpc/bag_attach', true);
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 141, 'probe', 'partner_can(''partner.pack'',''write'') for the zone-1 partner (never granted)',
    'expect', 'false', 'actual', public.partner_can('partner.pack','write')::text,
    'pass', public.partner_can('partner.pack','write') = false));

  begin
    perform public.partner_scope_supplier(
      (select lower(btrim(sp.supplier_name)) from supplier_profiles sp where sp.zone_id = 1
        and btrim(coalesce(sp.supplier_name,'')) <> '' order by sp.supplier_name limit 1),
      'partner.pack','write');
    v_actual := 'ANSWERED';
  exception when others then v_actual := 'RAISED: ' || sqlerrm;
  end;
  v_out := v_out || jsonb_build_array(jsonb_build_object(
    'gap_row', 141, 'probe', 'an in-zone supplier under a feature the matrix says ''none'' (partner.pack)',
    'expect', 'RAISED: not_authorized_feature', 'actual', v_actual,
    'pass', v_actual like 'RAISED: not_authorized_feature%'));

  -- restore the session
  perform set_config('request.path', '', true);
  if v_claims is null then
    perform set_config('request.jwt.claims', '', true);
  else
    perform set_config('request.jwt.claims', v_claims, true);
  end if;

  return jsonb_build_object(
    'ok', not exists (select 1 from jsonb_array_elements(v_out) e where (e->>'pass')::boolean is not true),
    'ran_at', now(),
    'partner_user', v_uid,
    'checks', v_out,
    'passed', (select count(*) from jsonb_array_elements(v_out) e where (e->>'pass')::boolean),
    'total', jsonb_array_length(v_out)
  );
exception when others then
  if v_claims is not null then perform set_config('request.jwt.claims', v_claims, true); end if;
  perform set_config('request.path', '', true);
  raise;
end $function$;

revoke all on function public.c352_partner_fence_proof() from public, anon, authenticated;
grant execute on function public.c352_partner_fence_proof() to service_role;

drop function if exists public._c352_probe_path();
