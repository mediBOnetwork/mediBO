-- CHANGE #307 — QA round 1 fixes (hostile QA verdict: failed, 3 high findings).
--
-- FINDING 2 (high): get_my_role() returns 'admin' for partner staff so they
-- reuse the fulfilment screens. Only 18 functions had been swapped to
-- role_for_medibo_only(), leaving every OTHER admin-gated RPC — marketing,
-- customer acquisition, customer payment, partner settlement, pricing/margin,
-- catalogue, write-as-customer — reachable by a partner over the raw API. The
-- registry declared those areas owner='medibo', which removed the TILE but
-- never closed the RPC. This migration swaps them at the source.
--
-- role_for_medibo_only() = get_my_role() for everyone who is not a partner, so
-- the swap is a strict NO-OP for admin / super_admin / supplier / customer and
-- a refusal for partners. That is why it is safe to apply mechanically.
--
-- FINDING 3 (high): the zone clamp only defended RPCs that TAKE a zone
-- argument. Order RPCs addressed by a bare uuid were unclamped, and three
-- config writes took a raw caller-supplied zone. Fixed below.
--
-- FINDING 6 (low): partner_access(p_feature, p_partner) coalesced a
-- CALLER-supplied partner id ahead of my_partner_id(), letting one partner read
-- another partner's matrix. The two-argument form is now admin-only.
--
-- Idempotent: the swap re-selects only functions that still contain a bare
-- get_my_role(), so a second run finds nothing and does nothing.

-- ---------------------------------------------------------------------------
-- 1. mediBO-only RPCs: get_my_role() -> role_for_medibo_only()
-- ---------------------------------------------------------------------------
create table if not exists public.medibo_only_rpc (
  proname     text primary key,
  feature_key text not null,
  note        text,
  added_at    timestamptz not null default now()
);
comment on table public.medibo_only_rpc is
  'CHANGE #307 — the RPC surface a fulfilment partner must never reach. The '
  'build-time guard c307_medibo_only_audit() fails if any of these gates on a '
  'bare get_my_role(), so a NEW mediBO-only RPC cannot silently open to partners.';

insert into public.medibo_only_rpc(proname, feature_key, note) values
  -- marketing (WhatsApp campaigns, templates, tokens, drips, audiences)
  ('wa_admin_order_groups','medibo.marketing',null),
  ('wa_audience_delete','medibo.marketing',null),
  ('wa_audience_save','medibo.marketing',null),
  ('wa_audiences_screen','medibo.marketing',null),
  ('wa_campaign_action','medibo.marketing',null),
  ('wa_campaign_detail','medibo.marketing',null),
  ('wa_campaign_dry_run','medibo.marketing',null),
  ('wa_campaign_holdout','medibo.marketing',null),
  ('wa_campaign_save','medibo.marketing',null),
  ('wa_campaign_schedule','medibo.marketing',null),
  ('wa_contact_ledger','medibo.marketing',null),
  ('wa_conversations','medibo.marketing',null),
  ('wa_convert_start','medibo.marketing',null),
  ('wa_drip_action','medibo.marketing',null),
  ('wa_drip_save','medibo.marketing',null),
  ('wa_drip_step_save','medibo.marketing',null),
  ('wa_event_diagnosis','medibo.marketing',null),
  ('wa_event_route_save','medibo.marketing',null),
  ('wa_event_routes_screen','medibo.marketing',null),
  ('wa_mark_image_done','medibo.marketing',null),
  ('wa_mark_read','medibo.marketing',null),
  ('wa_media_job_status','medibo.marketing',null),
  ('wa_media_upload_detached','medibo.marketing',null),
  ('wa_policy_apply','medibo.marketing',null),
  ('wa_policy_review_latest','medibo.marketing',null),
  ('wa_policy_review_start','medibo.marketing',null),
  ('wa_preview_draft','medibo.marketing',null),
  ('wa_send_health','medibo.marketing',null),
  ('wa_send_retry','medibo.marketing',null),
  ('wa_set_customer_language','medibo.marketing',null),
  ('wa_set_order_source','medibo.marketing',null),
  ('wa_template_clone','medibo.marketing',null),
  ('wa_template_delete','medibo.marketing',null),
  ('wa_template_delete_local','medibo.marketing',null),
  ('wa_template_header_status','medibo.marketing',null),
  ('wa_template_pipeline','medibo.marketing',null),
  ('wa_template_preview','medibo.marketing',null),
  ('wa_template_preview_pair','medibo.marketing',null),
  ('wa_template_save','medibo.marketing',null),
  ('wa_template_set_header_media','medibo.marketing',null),
  ('wa_template_similar','medibo.marketing',null),
  ('wa_template_submit_blockers','medibo.marketing',null),
  ('wa_template_translate_clone','medibo.marketing',null),
  ('wa_templates_screen','medibo.marketing',null),
  ('wa_thread','medibo.marketing',null),
  ('wa_token_ai_search','medibo.marketing',null),
  ('wa_token_apply_proposal','medibo.marketing',null),
  ('wa_token_coverage','medibo.marketing',null),
  ('wa_token_delete','medibo.marketing',null),
  ('wa_token_save','medibo.marketing',null),
  ('wa_token_search_result','medibo.marketing',null),
  ('wa_token_source_save','medibo.marketing',null),
  ('wa_token_toggle','medibo.marketing',null),
  ('wa_tokens_screen','medibo.marketing',null),
  ('wa_translation_status','medibo.marketing',null),
  ('wa_waba_status','medibo.marketing',null),
  -- customer acquisition (lead hub, scraping, routes, field workers)
  ('lead_assign_zone','medibo.customer_acquisition','also took a raw caller zone'),
  ('lead_checkin_sheet','medibo.customer_acquisition',null),
  ('lead_cluster','medibo.customer_acquisition',null),
  ('lead_convert_to_customer','medibo.customer_acquisition',null),
  ('lead_customer_prefill','medibo.customer_acquisition',null),
  ('lead_get_hub','medibo.customer_acquisition',null),
  ('lead_leads_summary','medibo.customer_acquisition',null),
  ('lead_plan_route','medibo.customer_acquisition','also took a raw caller zone'),
  ('lead_routes_screen','medibo.customer_acquisition',null),
  ('lead_scrape_month_usage','medibo.customer_acquisition',null),
  ('lead_scrape_resume','medibo.customer_acquisition',null),
  ('lead_scrape_runs_list','medibo.customer_acquisition',null),
  ('lead_scrape_start','medibo.customer_acquisition',null),
  ('lead_set_hub','medibo.customer_acquisition',null),
  ('lead_set_hub_by_address','medibo.customer_acquisition',null),
  ('lead_summary','medibo.customer_acquisition',null),
  ('lead_visits_report','medibo.customer_acquisition',null),
  ('lead_worker_upsert','medibo.customer_acquisition',null),
  ('lead_workers_list','medibo.customer_acquisition',null),
  ('lead_zones_list','medibo.customer_acquisition',null),
  -- customer payment collection (the method, the UTR, the claims, the credit)
  ('customer_order_payment_panel','medibo.customer_payment','leaked payments[].method_label'),
  ('admin_order_payment','medibo.customer_payment',null),
  ('payment_claim_link','medibo.customer_payment',null),
  ('customer_credit_list','medibo.customer_payment',null),
  ('customer_credit_set','medibo.customer_payment',null),
  ('admin_claim_decide','medibo.customer_payment',null),
  -- partner settlement (what mediBO pays the partner — never partner-writable)
  ('admin_payout_open','medibo.partner_settlement',null),
  ('admin_payout_pay','medibo.partner_settlement',null),
  ('admin_payout_statement','medibo.partner_settlement',null),
  -- pricing and margin
  ('storefront_margin_page','medibo.pricing',null),
  -- catalogue / customer records / ordering on a customer's behalf
  ('admin_company_names','medibo.catalogue',null),
  ('admin_customer_action','medibo.customer_acquisition',null),
  ('admin_customer_alert_row','medibo.customer_acquisition',null),
  ('admin_customer_profile_by_user','medibo.customer_acquisition',null),
  ('admin_customer_screen_data','medibo.customer_acquisition',null),
  ('admin_customer_update','medibo.customer_acquisition',null),
  ('admin_writeas_cart_clear','medibo.customer_acquisition',null),
  ('admin_writeas_cart_remove','medibo.customer_acquisition',null),
  ('admin_writeas_cart_upsert','medibo.customer_acquisition',null),
  ('admin_writeas_place_order','medibo.customer_acquisition',null),
  ('admin_writeas_place_order_v2','medibo.customer_acquisition',null),
  ('admin_writeas_supplier_answer','medibo.customer_acquisition',null),
  -- platform/zone configuration writes that took a raw caller-supplied zone
  ('admin_serviceability_set','medibo.catalogue','took a raw caller zone'),
  ('admin_set_delivery_partner','medibo.catalogue','took a raw caller zone'),
  ('zone_contact_save','medibo.catalogue','took a raw caller zone')
on conflict (proname) do nothing;

-- Rewrite each listed function so its role gate resolves through
-- role_for_medibo_only(). Overload-safe (iterates oids), and a second run finds
-- nothing left to rewrite.
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
    -- guard: only run if the text actually changed, and never touch the
    -- definition of role_for_medibo_only/get_my_role themselves.
    if v_new <> v_def and r.proname not in ('get_my_role','role_for_medibo_only') then
      execute v_new;
      v_n := v_n + 1;
    end if;
  end loop;
  raise notice 'c307 qa fix: rewrote % medibo-only functions', v_n;
end $do$;

-- ---------------------------------------------------------------------------
-- 2. Order zone clamp — the canonical "may I see this order" helper.
--    A partner is in-zone or not authorised, checked BEFORE the admin bypass
--    (a partner's get_my_role() is 'admin', which is exactly the hole).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._assert_can_see_order(p_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_owner uuid; v_cust uuid; v_claims text; v_zone smallint;
begin
  v_claims := nullif(current_setting('request.jwt.claims', true), '');
  if v_claims is null then return; end if;                              -- cron / trigger / psql
  if (v_claims::jsonb ->> 'role') = 'service_role' then return; end if;  -- trusted backend

  select user_id, customer_id, zone_id into v_owner, v_cust, v_zone from orders where id = p_order_id;
  if not found then raise exception 'order_not_found'; end if;

  -- CHANGE #307 QA fix: a fulfilment partner is confined to its own zone even
  -- though get_my_role() answers 'admin' for it. Checked FIRST, so the admin
  -- bypass below can never hand a partner another zone's order.
  if public.is_partner() then
    if v_zone is not null and v_zone = public.my_zone_id() then return; end if;
    raise exception 'not_authorized_zone';
  end if;

  if get_my_role() in ('admin','super_admin') then return; end if;
  if auth.uid() is null then raise exception 'not_authorized'; end if;
  if v_cust is not null and v_cust = public.my_customer_id() then return; end if;
  if v_owner = any (public.my_owner_user_ids()) then return; end if;
  raise exception 'not_authorized';
end $function$;

-- ---------------------------------------------------------------------------
-- 3. partner_access: the two-argument form is admin-only.
--    A partner reading its OWN matrix omits p_partner and is unaffected.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.partner_access(p_feature text, p_partner bigint DEFAULT NULL::bigint)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select pp.access
       from partner_permissions pp
       join feature_registry fr on fr.feature_key = pp.feature_key
      where pp.partner_id = case
              when p_partner is null then public.my_partner_id()
              -- only mediBO staff may ask about ANOTHER partner; a partner
              -- passing someone else's id is answered about itself.
              when public.role_for_medibo_only() in ('admin','super_admin') then p_partner
              else public.my_partner_id()
            end
        and pp.feature_key = p_feature
        and fr.is_active and fr.partner_eligible and fr.owner = 'partner'),
    'none')
$function$;

-- ---------------------------------------------------------------------------
-- 4. The regression guard. This is what makes "anything new defaults to none"
--    true FOREVER instead of once: if a mediBO-only RPC is ever (re)created
--    gating on a bare get_my_role(), this returns rows and the build-time test
--    goes red. rg_check()/the protected suite call it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.c307_medibo_only_audit()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with leaky as (
    select p.proname, m.feature_key
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      join public.medibo_only_rpc m on m.proname = p.proname
     where n.nspname = 'public' and p.prokind = 'f'
       and pg_get_functiondef(p.oid) like '%get_my_role()%'
       and pg_get_functiondef(p.oid) not like '%role_for_medibo_only()%'
  )
  select jsonb_build_object(
    'ok', not exists (select 1 from leaky),
    'registered', (select count(*) from public.medibo_only_rpc),
    'leaky_count', (select count(*) from leaky),
    'leaky', coalesce((select jsonb_agg(jsonb_build_object('rpc',proname,'feature',feature_key)) from leaky), '[]'::jsonb)
  )
$function$;

grant execute on function public.c307_medibo_only_audit() to authenticated, service_role;
