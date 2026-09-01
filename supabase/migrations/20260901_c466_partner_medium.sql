-- CMD #466 — the five APPROVED medium/partner feature_gaps rows, closed.
--
--   147  notif_cost_dashboard answered a partner  -> fenced on role_for_medibo_only()
--   150  no partner statement DOCUMENT            -> partner_document + the #403 renderer
--   151  no earnings surface for a partner        -> already live; proved, not rebuilt
--   153  no licence expiry / renewal reminder     -> expiry dates + daily sweep
--   154  no partner suspension / offboarding      -> partner_suspend / partner_resume
--
-- The c466_qa1_* migrations at the end are round-1 hostile-QA fixes: the
-- new-work router must never leave the zone, and mediBO own GST registration
-- for a commission invoice is platform_identity, never the partner-mirrored
-- billing_config.
--
-- This file is the git-committed copy of exactly what was applied, in order.
-- Every statement is idempotent: a resumed worker re-applies it as a no-op.

-- ===== c466_partner_medium_copy (20260901201900) =====
insert into public.ui_copy(key, value) values
  ('partner_lifecycle.heading',        to_jsonb('Partner status'::text)),
  ('partner_lifecycle.active_label',   to_jsonb('Active'::text)),
  ('partner_lifecycle.suspended_label',to_jsonb('Suspended'::text)),
  ('partner_lifecycle.inactive_label', to_jsonb('Not active'::text)),
  ('partner_lifecycle.suspend_label',  to_jsonb('Suspend partner'::text)),
  ('partner_lifecycle.resume_label',   to_jsonb('Resume partner'::text)),
  ('partner_lifecycle.reason_hint',    to_jsonb('Why is this partner being suspended?'::text)),
  ('partner_lifecycle.err_no_reason',  to_jsonb('A suspension needs a reason.'::text)),
  ('partner_lifecycle.err_not_authorized', to_jsonb('Only mediBO staff can change a partner''s status.'::text)),
  ('partner_lifecycle.err_no_partner', to_jsonb('That partner no longer exists.'::text)),
  ('partner_lifecycle.suspended_since',to_jsonb('Suspended {at} by {by}'::text)),
  ('partner_lifecycle.inflight_head',  to_jsonb('Orders already with this partner'::text)),
  ('partner_lifecycle.inflight_text',  to_jsonb('{n} order(s) are still open. They stay with this partner and are worked to close as normal — suspension stops NEW orders being routed here, it does not cancel work in hand.'::text)),
  ('partner_lifecycle.inflight_none',  to_jsonb('No open orders. Nothing is left to finish.'::text)),
  ('partner_lifecycle.balance_head',   to_jsonb('Open settlement balance'::text)),
  ('partner_lifecycle.balance_text',   to_jsonb('{amt} across {n} unsettled period(s). Suspension does not freeze it — every period already earned is computed and paid on the normal cadence.'::text)),
  ('partner_lifecycle.balance_none',   to_jsonb('Nothing outstanding. Every period is settled.'::text)),
  ('partner_lifecycle.routing_head',   to_jsonb('New work'::text)),
  ('partner_lifecycle.routing_text',   to_jsonb('New orders in this zone are routed to the next active partner from the moment the suspension is saved.'::text)),
  ('partner_lifecycle.suspended_toast',to_jsonb('Partner suspended. New orders will not be routed here.'::text)),
  ('partner_lifecycle.resumed_toast',  to_jsonb('Partner resumed. New orders route here again.'::text)),

  ('partner_licence.heading',          to_jsonb('Licences and expiry'::text)),
  ('partner_licence.sub',              to_jsonb('A partner cannot trade on a lapsed licence. Set the expiry and mediBO reminds them before it runs out.'::text)),
  ('partner_licence.gstin_label',      to_jsonb('GSTIN'::text)),
  ('partner_licence.dl_20b_label',     to_jsonb('Drug Licence 20B'::text)),
  ('partner_licence.dl_21b_label',     to_jsonb('Drug Licence 21B'::text)),
  ('partner_licence.agreement_label',  to_jsonb('Signed agreement'::text)),
  ('partner_licence.no_expiry',        to_jsonb('No expiry recorded'::text)),
  ('partner_licence.no_number',        to_jsonb('Not captured'::text)),
  ('partner_licence.valid_label',      to_jsonb('Valid to {d}'::text)),
  ('partner_licence.due_label',        to_jsonb('Expires in {n} day(s) — {d}'::text)),
  ('partner_licence.expired_label',    to_jsonb('Expired on {d}'::text)),
  ('partner_licence.set_label',        to_jsonb('Set expiry'::text)),
  ('partner_licence.ok_all',           to_jsonb('All licences current'::text)),
  ('partner_licence.alert_due',        to_jsonb('{n} licence(s) expiring within {w} days'::text)),
  ('partner_licence.alert_expired',    to_jsonb('{n} licence(s) have expired'::text)),
  ('partner_licence.err_kind',         to_jsonb('That is not a licence mediBO tracks.'::text)),
  ('partner_licence.saved_toast',      to_jsonb('Expiry saved.'::text)),
  ('partner_licence.reminder_title',   to_jsonb('Licence renewal due'::text)),
  ('partner_licence.reminder_body',    to_jsonb('{label} for {partner} expires on {d}. Renew it and send mediBO the new copy.'::text)),

  ('partner_doc.title',                to_jsonb('Statement'::text)),
  ('partner_doc.button',               to_jsonb('Download statement'::text)),
  ('partner_doc.building_message',     to_jsonb('Building your statement…'::text)),
  ('partner_doc.ready_message',        to_jsonb('Statement ready.'::text)),
  ('partner_doc.err_unknown_kind',     to_jsonb('mediBO does not issue that document.'::text)),
  ('partner_doc.err_not_found',        to_jsonb('That statement is not available.'::text)),
  ('partner_doc.err_failed',           to_jsonb('The statement could not be built. Try again.'::text)),
  ('partner_doc.err_not_partner',      to_jsonb('Only a partner login can download a partner statement.'::text)),
  ('partner_doc.doc_title',            to_jsonb('Partner settlement statement — {period}'::text)),
  ('partner_doc.doc_subtitle',         to_jsonb('Generated {at} · mediBO'::text)),
  ('partner_doc.doc_brand',            to_jsonb('mediBO · Jai Mahakal Medical And Surgical'::text)),
  ('partner_doc.lbl_partner',          to_jsonb('Partner'::text)),
  ('partner_doc.lbl_gstin',            to_jsonb('Partner GSTIN'::text)),
  ('partner_doc.lbl_recipient',        to_jsonb('mediBO GSTIN'::text)),
  ('partner_doc.lbl_period',           to_jsonb('Period'::text)),
  ('partner_doc.lbl_statement_no',     to_jsonb('Statement no.'::text)),
  ('partner_doc.lbl_date',             to_jsonb('Issued'::text)),
  ('partner_doc.lbl_pos',              to_jsonb('Place of supply'::text)),
  ('partner_doc.lbl_sac',              to_jsonb('SAC'::text)),
  ('partner_doc.lbl_zone',             to_jsonb('Zone'::text)),
  ('partner_doc.no_gstin',             to_jsonb('Not registered'::text)),
  ('partner_doc.orders_heading',       to_jsonb('Orders fulfilled in this period'::text)),
  ('partner_doc.orders_empty',         to_jsonb('No orders were settled in this period.'::text)),
  ('partner_doc.col_date',             to_jsonb('Date'::text)),
  ('partner_doc.col_order',            to_jsonb('Order'::text)),
  ('partner_doc.col_revenue',          to_jsonb('Gross value'::text)),
  ('partner_doc.col_margin',           to_jsonb('Margin'::text)),
  ('partner_doc.col_share',            to_jsonb('Your share'::text)),
  ('partner_doc.costs_heading',        to_jsonb('Deductions'::text)),
  ('partner_doc.costs_empty',          to_jsonb('No deductions in this period.'::text)),
  ('partner_doc.col_cost_label',       to_jsonb('Deduction'::text)),
  ('partner_doc.col_cost_amount',      to_jsonb('Amount'::text)),
  ('partner_doc.lbl_orders',           to_jsonb('Orders fulfilled'::text)),
  ('partner_doc.lbl_gross',            to_jsonb('Gross order value'::text)),
  ('partner_doc.lbl_margin',           to_jsonb('Gross margin'::text)),
  ('partner_doc.lbl_costs',            to_jsonb('Less: costs'::text)),
  ('partner_doc.lbl_distributable',    to_jsonb('Distributable profit'::text)),
  ('partner_doc.lbl_split',            to_jsonb('Your split'::text)),
  ('partner_doc.lbl_commission',       to_jsonb('Commission earned (taxable value)'::text)),
  ('partner_doc.lbl_brought_forward',  to_jsonb('Brought forward'::text)),
  ('partner_doc.lbl_net',              to_jsonb('Net payable'::text)),
  ('partner_doc.gst_note_registered',  to_jsonb('GST: the commission above is the TAXABLE VALUE of a service you supply to mediBO. You are registered ({gstin}), so raise a tax invoice on mediBO for this amount plus GST at {rate}% (SAC {sac}); mediBO pays the commission and the tax against that invoice. This statement is not a tax invoice.'::text)),
  ('partner_doc.gst_note_unregistered',to_jsonb('GST: the commission above is the TAXABLE VALUE of a service you supply to mediBO. No GSTIN is recorded for you, so no tax is added and no tax invoice is expected. Give mediBO your GSTIN if you are registered. This statement is not a tax invoice.'::text)),
  ('partner_doc.gst_head',             to_jsonb('GST on the commission'::text)),
  ('partner_doc.gst_taxable',          to_jsonb('Taxable value'::text)),
  ('partner_doc.gst_cgst',             to_jsonb('CGST'::text)),
  ('partner_doc.gst_sgst',             to_jsonb('SGST'::text)),
  ('partner_doc.gst_igst',             to_jsonb('IGST'::text)),
  ('partner_doc.gst_invoice_total',    to_jsonb('Invoice this on mediBO'::text)),
  ('partner_doc.footer',               to_jsonb('Computed from the settlement ledger. Every figure is the one snapshotted on the order at bill time — a later change to the deal never rewrites a past statement.'::text))
on conflict (key) do nothing;

-- ===== c466_row147_notif_cost_medibo_only (20260901201912) =====
-- ROW 147 — notif_cost_dashboard reports mediBO's OWN per-message notification
-- spend. It gated on get_my_role(), which a partner login can satisfy; the fence
-- has to be role_for_medibo_only(), which reports 'partner' for anyone holding a
-- partner login no matter what else their identity is.
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'notif_cost_dashboard';
  if v_def is null then
    raise exception 'c466: notif_cost_dashboard not found';
  end if;

  if position('role_for_medibo_only()' in v_def) > 0 then
    return;  -- already fenced; a resumed worker re-applies this as a no-op
  end if;

  v_def := replace(v_def,
    'if get_my_role() not in (''admin'',''super_admin'') then raise exception ''forbidden''; end if;',
    'if public.role_for_medibo_only() not in (''admin'',''super_admin'') then raise exception ''forbidden''; end if;');

  if position('role_for_medibo_only()' in v_def) = 0 then
    raise exception 'c466: could not find the notif_cost_dashboard gate to fence';
  end if;

  execute v_def;
end $mig$;

-- ===== c466_row153_partner_licence_expiry (20260901202233) =====
-- ROW 153 — a partner's licences were captured as free text with no expiry and
-- no renewal lane, unlike delivery partners. Give region_partners the four
-- expiry dates, one admin setter, one card both surfaces render, and a daily
-- sweep that reminds the partner before a licence lapses.

alter table public.region_partners
  add column if not exists gstin_expiry     date,
  add column if not exists dl_20b_expiry    date,
  add column if not exists dl_21b_expiry    date,
  add column if not exists agreement_expiry date;

create table if not exists public.partner_licence_reminder (
  partner_id bigint      not null references public.region_partners(id) on delete cascade,
  kind       text        not null,
  expiry     date        not null,
  sent_at    timestamptz not null default now(),
  primary key (partner_id, kind, expiry)
);

insert into public.app_settings(key, value)
values ('partner_licence_window_days', to_jsonb(30))
on conflict (key) do nothing;

-- The card. Ownership is the fence: mediBO staff read any partner, a partner
-- login reads ONLY its own row — p_partner_id is ignored for a partner.
create or replace function public.partner_licence_card(p_partner_id bigint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  v_role text := public.role_for_medibo_only();
  v_admin boolean := v_role in ('admin','super_admin');
  v_pid bigint;
  rp public.region_partners%rowtype;
  v_window int := coalesce((select (value #>> '{}')::int from app_settings
                              where key='partner_licence_window_days'), 30);
  v_rows jsonb := '[]'::jsonb;
  v_due int := 0; v_exp int := 0;
  r record;
begin
  v_pid := case when v_admin then coalesce(p_partner_id, public.my_partner_id())
                else public.my_partner_id() end;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error', 'no_partner',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;
  select * into rp from region_partners where id = v_pid;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_partner',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;

  for r in
    select * from (values
      ('gstin',     public._c('partner_licence.gstin_label'),     rp.gstin,  rp.gstin_expiry,     1),
      ('dl_20b',    public._c('partner_licence.dl_20b_label'),    rp.dl_20b, rp.dl_20b_expiry,    2),
      ('dl_21b',    public._c('partner_licence.dl_21b_label'),    rp.dl_21b, rp.dl_21b_expiry,    3),
      ('agreement', public._c('partner_licence.agreement_label'),
         nullif(rp.agreement_doc_path,''), rp.agreement_expiry,   4)
    ) as t(kind, label, number, expiry, sort)
    order by sort
  loop
    if r.expiry is null then
      v_rows := v_rows || jsonb_build_object(
        'kind', r.kind, 'label', r.label,
        'number', coalesce(nullif(r.number,''), public._c('partner_licence.no_number')),
        'has_number', coalesce(nullif(r.number,''),'') <> '',
        'expiry_iso', null,
        'expiry_label', public._c('partner_licence.no_expiry'),
        'tone', 'neutral', 'days_left', null, 'can_edit', v_admin);
    elsif r.expiry < current_date then
      v_exp := v_exp + 1;
      v_rows := v_rows || jsonb_build_object(
        'kind', r.kind, 'label', r.label,
        'number', coalesce(nullif(r.number,''), public._c('partner_licence.no_number')),
        'has_number', coalesce(nullif(r.number,''),'') <> '',
        'expiry_iso', r.expiry,
        'expiry_label', public._cf('partner_licence.expired_label',
            jsonb_build_object('d', to_char(r.expiry,'DD/MM/YYYY'))),
        'tone', 'danger', 'days_left', (r.expiry - current_date), 'can_edit', v_admin);
    elsif r.expiry <= current_date + v_window then
      v_due := v_due + 1;
      v_rows := v_rows || jsonb_build_object(
        'kind', r.kind, 'label', r.label,
        'number', coalesce(nullif(r.number,''), public._c('partner_licence.no_number')),
        'has_number', coalesce(nullif(r.number,''),'') <> '',
        'expiry_iso', r.expiry,
        'expiry_label', public._cf('partner_licence.due_label',
            jsonb_build_object('n', (r.expiry - current_date)::text,
                               'd', to_char(r.expiry,'DD/MM/YYYY'))),
        'tone', 'warning', 'days_left', (r.expiry - current_date), 'can_edit', v_admin);
    else
      v_rows := v_rows || jsonb_build_object(
        'kind', r.kind, 'label', r.label,
        'number', coalesce(nullif(r.number,''), public._c('partner_licence.no_number')),
        'has_number', coalesce(nullif(r.number,''),'') <> '',
        'expiry_iso', r.expiry,
        'expiry_label', public._cf('partner_licence.valid_label',
            jsonb_build_object('d', to_char(r.expiry,'DD/MM/YYYY'))),
        'tone', 'success', 'days_left', (r.expiry - current_date), 'can_edit', v_admin);
    end if;
  end loop;

  return jsonb_build_object('ok', true,
    'partner_id', v_pid,
    'partner_name', rp.partner_name,
    'zone_id', rp.zone_id,
    'heading', public._c('partner_licence.heading'),
    'sub', public._c('partner_licence.sub'),
    'set_label', public._c('partner_licence.set_label'),
    'can_edit', v_admin,
    'window_days', v_window,
    'rows', v_rows,
    'alert_label', case
        when v_exp > 0 then public._cf('partner_licence.alert_expired', jsonb_build_object('n', v_exp::text))
        when v_due > 0 then public._cf('partner_licence.alert_due',
               jsonb_build_object('n', v_due::text, 'w', v_window::text))
        else public._c('partner_licence.ok_all') end,
    'alert_tone', case when v_exp > 0 then 'danger'
                       when v_due > 0 then 'warning' else 'success' end,
    'expired_count', v_exp, 'due_count', v_due);
end $fn$;

create or replace function public.partner_licence_set(
  p_partner_id bigint, p_kind text, p_expiry date)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare v_kind text := lower(btrim(coalesce(p_kind,'')));
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'tone','danger', 'message', public._c('partner_lifecycle.err_not_authorized'));
  end if;
  if v_kind not in ('gstin','dl_20b','dl_21b','agreement') then
    return jsonb_build_object('ok', false, 'error','bad_kind',
      'tone','danger', 'message', public._c('partner_licence.err_kind'));
  end if;
  if not exists (select 1 from region_partners where id = p_partner_id) then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'tone','danger', 'message', public._c('partner_lifecycle.err_no_partner'));
  end if;

  update region_partners set
    gstin_expiry     = case when v_kind='gstin'     then p_expiry else gstin_expiry     end,
    dl_20b_expiry    = case when v_kind='dl_20b'    then p_expiry else dl_20b_expiry    end,
    dl_21b_expiry    = case when v_kind='dl_21b'    then p_expiry else dl_21b_expiry    end,
    agreement_expiry = case when v_kind='agreement' then p_expiry else agreement_expiry end,
    updated_at = now()
  where id = p_partner_id;

  -- A re-dated licence must be reminded about again.
  delete from partner_licence_reminder where partner_id = p_partner_id and kind = v_kind;

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (p_partner_id, auth.uid(), 'partner.onboarding', 'licence_expiry_set',
          jsonb_build_object('kind', v_kind, 'expiry', p_expiry));

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_licence.saved_toast'),
    'card', public.partner_licence_card(p_partner_id));
end $fn$;

-- The renewal reminder. One row per (partner, licence, expiry date) so a
-- partner is told once per renewal, never once per day.
create or replace function public.partner_licence_expiry_sweep()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare
  v_window int := coalesce((select (value #>> '{}')::int from app_settings
                              where key='partner_licence_window_days'), 30);
  r record; v_sent int := 0; v_expired int := 0;
begin
  for r in
    select rp.id as partner_id, rp.partner_name, t.kind, t.label, t.expiry
      from region_partners rp
      cross join lateral (values
        ('gstin',     public._c('partner_licence.gstin_label'),     rp.gstin_expiry),
        ('dl_20b',    public._c('partner_licence.dl_20b_label'),    rp.dl_20b_expiry),
        ('dl_21b',    public._c('partner_licence.dl_21b_label'),    rp.dl_21b_expiry),
        ('agreement', public._c('partner_licence.agreement_label'), rp.agreement_expiry)
      ) as t(kind, label, expiry)
     where coalesce(rp.is_active, false)
       and t.expiry is not null
       and t.expiry <= current_date + v_window
       and not exists (select 1 from partner_licence_reminder m
                        where m.partner_id = rp.id and m.kind = t.kind and m.expiry = t.expiry)
  loop
    begin
      perform public.notify_partner('partner_licence_expiry', jsonb_build_object(
        'partner_id', r.partner_id::text,
        'label', r.label,
        'partner', r.partner_name,
        'd', to_char(r.expiry,'DD/MM/YYYY'),
        'title', public._c('partner_licence.reminder_title'),
        'body', public._cf('partner_licence.reminder_body', jsonb_build_object(
                  'label', r.label, 'partner', r.partner_name,
                  'd', to_char(r.expiry,'DD/MM/YYYY')))));
    exception when others then
      null;  -- a missing notification route must never stall the sweep
    end;

    insert into partner_licence_reminder(partner_id, kind, expiry)
    values (r.partner_id, r.kind, r.expiry) on conflict do nothing;

    insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
    values (r.partner_id, null, 'partner.onboarding', 'licence_expiry_reminder',
            jsonb_build_object('kind', r.kind, 'expiry', r.expiry,
              'summary', public._cf('partner_licence.reminder_body', jsonb_build_object(
                'label', r.label, 'partner', r.partner_name,
                'd', to_char(r.expiry,'DD/MM/YYYY')))));

    v_sent := v_sent + 1;
    if r.expiry < current_date then v_expired := v_expired + 1; end if;
  end loop;

  if v_expired > 0 then
    insert into rg_alerts(fingerprint, severity, kind, name, detail, first_seen, last_seen, seen_count)
    values ('partner_licence_expired', 'warn', 'partner', 'partner licence expired',
            jsonb_build_object('count', v_expired), now(), now(), 1)
    on conflict (fingerprint) do update
      set last_seen = now(), seen_count = rg_alerts.seen_count + 1,
          detail = excluded.detail;
  end if;

  return jsonb_build_object('ok', true, 'reminded', v_sent, 'expired', v_expired,
                            'window_days', v_window);
end $fn$;

insert into public.cron_task(name, ord, mode, work_sql, enabled, run_at_ist, dml, note)
values ('partner-licence-expiry-sweep', 536, 'poll',
        'select public.partner_licence_expiry_sweep();', true, '06:40:00', true,
        'CMD #466 row 153 — reminds a partner before a GSTIN / 20B / 21B / agreement lapses.')
on conflict (name) do nothing;

grant execute on function public.partner_licence_card(bigint)          to authenticated;
grant execute on function public.partner_licence_set(bigint,text,date) to authenticated;

-- ===== c466_row154_partner_suspend_resume (20260901202317) =====
-- ROW 154 — nothing suspended a PARTNER. is_active was only reachable through
-- save_region_partner's activation side effect, which deactivates the other
-- partners in the zone as a byproduct, and nothing said what happens to work in
-- hand or to the open settlement balance.
--
-- Suspension here means exactly one thing, and the copy says it: NEW work stops
-- routing to this partner immediately; orders already with them are worked to
-- close; the settlement balance keeps accruing and pays on the normal cadence.
-- It is deliberately NOT is_active=false, which would delete the partner's
-- logins out from under in-flight work (my_partner_id() joins on is_active).

alter table public.region_partners
  add column if not exists suspended_at    timestamptz,
  add column if not exists suspended_by    text,
  add column if not exists suspend_reason  text;

-- New work stops here: every router that picks a partner skips a suspended one.
create or replace function public.partner_for_district(p_district text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $fn$
  with want as (select public.norm_district(p_district) as d),
  hit as (
    select rp.* from region_partners rp, want w
    where rp.is_active and rp.suspended_at is null and rp.district = w.d limit 1
  ),
  fallback as (
    select rp.* from region_partners rp
    where rp.is_active and rp.suspended_at is null and rp.district = 'Raipur' limit 1
  ),
  -- Never return nothing: a suspended partner still owns the district until a
  -- replacement exists, and an order must always be stamped.
  last_resort as (
    select rp.* from region_partners rp, want w
    where rp.is_active and rp.district = w.d limit 1
  ),
  chosen as (
    select * from hit
    union all select * from fallback   where not exists (select 1 from hit)
    union all select * from last_resort
      where not exists (select 1 from hit) and not exists (select 1 from fallback)
  )
  select jsonb_build_object(
    'district', c.district,
    'partner_name', c.partner_name,
    'address', c.address,
    'gstin', c.gstin,
    'dl_20b', c.dl_20b,
    'dl_21b', c.dl_21b,
    'state', c.state,
    'dl_combined', concat_ws('  |  ',
        nullif('20B: '||coalesce(c.dl_20b,''),'20B: '),
        nullif('21B: '||coalesce(c.dl_21b,''),'21B: ')),
    'gst_doc_path', c.gst_doc_path,
    'dl20b_doc_path', c.dl20b_doc_path,
    'dl21b_doc_path', c.dl21b_doc_path,
    'suspended', c.suspended_at is not null,
    'matched', (select w.d from want w) is not distinct from c.district
  ) from chosen c limit 1;
$fn$;

create or replace function public.active_partner()
returns jsonb
language sql stable security definer set search_path to 'public'
as $fn$
  select jsonb_build_object(
    'id', rp.id, 'area', rp.district, 'partner_name', rp.partner_name,
    'address', rp.address, 'gstin', rp.gstin, 'dl_20b', rp.dl_20b, 'dl_21b', rp.dl_21b,
    'state', rp.state,
    'dl_combined', concat_ws('  |  ',
        nullif('20B: '||coalesce(rp.dl_20b,''),'20B: '),
        nullif('21B: '||coalesce(rp.dl_21b,''),'21B: ')),
    'gst_doc_path', rp.gst_doc_path,
    'dl20b_doc_path', rp.dl20b_doc_path,
    'dl21b_doc_path', rp.dl21b_doc_path)
  from region_partners rp where rp.is_active
  order by (rp.suspended_at is not null), rp.id
  limit 1;
$fn$;

-- The card: status, and the two consequences the register said were undefined.
create or replace function public.partner_lifecycle_card(p_partner_id bigint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  v_role text := public.role_for_medibo_only();
  v_admin boolean := v_role in ('admin','super_admin');
  v_pid bigint := case when v_admin then coalesce(p_partner_id, public.my_partner_id())
                       else public.my_partner_id() end;
  rp public.region_partners%rowtype;
  v_inflight int := 0; v_periods int := 0; v_balance numeric := 0;
  v_status text; v_tone text; v_label text;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;
  select * into rp from region_partners where id = v_pid;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;

  select count(*) into v_inflight
    from orders o
   where o.partner_id = v_pid
     and coalesce(o.status,'') not in ('delivered','cancelled','completed','closed','rejected');

  select count(*), coalesce(sum(coalesce(p.net_due, p.payable, 0)), 0)
    into v_periods, v_balance
    from partner_settlement_periods p
   where p.partner_id = v_pid and coalesce(p.status,'') <> 'settled';

  if rp.suspended_at is not null then
    v_status := 'suspended'; v_tone := 'danger';
    v_label  := public._c('partner_lifecycle.suspended_label');
  elsif coalesce(rp.is_active,false) then
    v_status := 'active'; v_tone := 'success';
    v_label  := public._c('partner_lifecycle.active_label');
  else
    v_status := 'inactive'; v_tone := 'warning';
    v_label  := public._c('partner_lifecycle.inactive_label');
  end if;

  return jsonb_build_object('ok', true,
    'partner_id', v_pid, 'partner_name', rp.partner_name, 'zone_id', rp.zone_id,
    'heading', public._c('partner_lifecycle.heading'),
    'status', v_status, 'status_tone', v_tone, 'status_label', v_label,
    'is_suspended', rp.suspended_at is not null,
    'can_act', v_admin,
    'suspend_label', public._c('partner_lifecycle.suspend_label'),
    'resume_label',  public._c('partner_lifecycle.resume_label'),
    'reason_hint',   public._c('partner_lifecycle.reason_hint'),
    'suspend_reason', coalesce(rp.suspend_reason,''),
    'suspended_since', case when rp.suspended_at is null then ''
      else public._cf('partner_lifecycle.suspended_since', jsonb_build_object(
        'at', public.ist_fmt(rp.suspended_at,'dmy_hm'),
        'by', coalesce(rp.suspended_by,''))) end,
    'blocks', jsonb_build_array(
      jsonb_build_object('key','routing',
        'heading', public._c('partner_lifecycle.routing_head'),
        'text',    public._c('partner_lifecycle.routing_text'), 'tone','info'),
      jsonb_build_object('key','inflight',
        'heading', public._c('partner_lifecycle.inflight_head'),
        'count',   v_inflight,
        'text',    case when v_inflight = 0 then public._c('partner_lifecycle.inflight_none')
                        else public._cf('partner_lifecycle.inflight_text',
                               jsonb_build_object('n', v_inflight::text)) end,
        'tone',    case when v_inflight = 0 then 'neutral' else 'warning' end),
      jsonb_build_object('key','balance',
        'heading', public._c('partner_lifecycle.balance_head'),
        'count',   v_periods,
        'amount',  public.inr_money(v_balance),
        'text',    case when v_periods = 0 then public._c('partner_lifecycle.balance_none')
                        else public._cf('partner_lifecycle.balance_text',
                               jsonb_build_object('amt', public.inr_money(v_balance),
                                                  'n', v_periods::text)) end,
        'tone',    case when v_periods = 0 then 'neutral' else 'info' end)));
end $fn$;

create or replace function public.partner_suspend(p_partner_id bigint, p_reason text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public._c('partner_lifecycle.err_not_authorized'));
  end if;
  if not exists (select 1 from region_partners where id = p_partner_id) then
    return jsonb_build_object('ok', false, 'error','no_partner','tone','danger',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'error','no_reason','tone','danger',
      'message', public._c('partner_lifecycle.err_no_reason'));
  end if;

  update region_partners
     set suspended_at = coalesce(suspended_at, now()),
         suspended_by = coalesce(public.my_login_email(),'admin'),
         suspend_reason = v_reason,
         updated_at = now()
   where id = p_partner_id;

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (p_partner_id, auth.uid(), 'partner.onboarding', 'partner_suspended',
          jsonb_build_object('reason', v_reason,
            'summary', public._c('partner_lifecycle.suspended_toast')));

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_lifecycle.suspended_toast'),
    'card', public.partner_lifecycle_card(p_partner_id));
end $fn$;

create or replace function public.partner_resume(p_partner_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public._c('partner_lifecycle.err_not_authorized'));
  end if;
  if not exists (select 1 from region_partners where id = p_partner_id) then
    return jsonb_build_object('ok', false, 'error','no_partner','tone','danger',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;

  update region_partners
     set suspended_at = null, suspended_by = null, suspend_reason = null,
         updated_at = now()
   where id = p_partner_id;

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (p_partner_id, auth.uid(), 'partner.onboarding', 'partner_resumed',
          jsonb_build_object('summary', public._c('partner_lifecycle.resumed_toast')));

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_lifecycle.resumed_toast'),
    'card', public.partner_lifecycle_card(p_partner_id));
end $fn$;

grant execute on function public.partner_lifecycle_card(bigint)     to authenticated;
grant execute on function public.partner_suspend(bigint,text)       to authenticated;
grant execute on function public.partner_resume(bigint)             to authenticated;

-- ===== c466_row154_stamp_and_card_fix (20260901202430) =====
-- The order-stamping trigger is the REAL new-work router: it picks the zone's
-- active partner on insert. A suspended partner must not be picked, or
-- "suspension" would only be a label on a screen.
create or replace function public.orders_stamp_partner()
returns trigger
language plpgsql security definer set search_path to 'public'
as $fn$
BEGIN
  IF NEW.fulfillment_partner_id IS NULL THEN
    SELECT rp.id INTO NEW.fulfillment_partner_id
    FROM region_partners rp
    WHERE rp.is_active AND rp.suspended_at IS NULL
      AND rp.zone_id = COALESCE(NEW.zone_id, 1)
    LIMIT 1;
    IF NEW.fulfillment_partner_id IS NULL THEN
      SELECT rp.id INTO NEW.fulfillment_partner_id FROM region_partners rp
       WHERE rp.is_active AND rp.suspended_at IS NULL ORDER BY rp.id LIMIT 1;
    END IF;
    -- Last resort: a suspended partner still owns the zone until a replacement
    -- exists. An order is never left unstamped.
    IF NEW.fulfillment_partner_id IS NULL THEN
      SELECT rp.id INTO NEW.fulfillment_partner_id FROM region_partners rp
       WHERE rp.is_active AND rp.zone_id = COALESCE(NEW.zone_id, 1) LIMIT 1;
    END IF;
    IF NEW.fulfillment_partner_id IS NULL THEN
      SELECT rp.id INTO NEW.fulfillment_partner_id FROM region_partners rp
       WHERE rp.is_active ORDER BY rp.id LIMIT 1;
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

-- orders carries fulfillment_partner_id, not partner_id.
create or replace function public.partner_lifecycle_card(p_partner_id bigint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  v_role text := public.role_for_medibo_only();
  v_admin boolean := v_role in ('admin','super_admin');
  v_pid bigint := case when v_admin then coalesce(p_partner_id, public.my_partner_id())
                       else public.my_partner_id() end;
  rp public.region_partners%rowtype;
  v_inflight int := 0; v_periods int := 0; v_balance numeric := 0;
  v_status text; v_tone text; v_label text;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;
  select * into rp from region_partners where id = v_pid;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;

  select count(*) into v_inflight
    from orders o
   where o.fulfillment_partner_id = v_pid
     and coalesce(o.status,'') not in ('delivered','cancelled','completed','closed','rejected');

  select count(*), coalesce(sum(coalesce(p.net_due, p.payable, 0)), 0)
    into v_periods, v_balance
    from partner_settlement_periods p
   where p.partner_id = v_pid and coalesce(p.status,'') <> 'settled';

  if rp.suspended_at is not null then
    v_status := 'suspended'; v_tone := 'danger';
    v_label  := public._c('partner_lifecycle.suspended_label');
  elsif coalesce(rp.is_active,false) then
    v_status := 'active'; v_tone := 'success';
    v_label  := public._c('partner_lifecycle.active_label');
  else
    v_status := 'inactive'; v_tone := 'warning';
    v_label  := public._c('partner_lifecycle.inactive_label');
  end if;

  return jsonb_build_object('ok', true,
    'partner_id', v_pid, 'partner_name', rp.partner_name, 'zone_id', rp.zone_id,
    'heading', public._c('partner_lifecycle.heading'),
    'status', v_status, 'status_tone', v_tone, 'status_label', v_label,
    'is_suspended', rp.suspended_at is not null,
    'can_act', v_admin,
    'suspend_label', public._c('partner_lifecycle.suspend_label'),
    'resume_label',  public._c('partner_lifecycle.resume_label'),
    'reason_hint',   public._c('partner_lifecycle.reason_hint'),
    'suspend_reason', coalesce(rp.suspend_reason,''),
    'suspended_since', case when rp.suspended_at is null then ''
      else public._cf('partner_lifecycle.suspended_since', jsonb_build_object(
        'at', public.ist_fmt(rp.suspended_at,'dmy_hm'),
        'by', coalesce(rp.suspended_by,''))) end,
    'blocks', jsonb_build_array(
      jsonb_build_object('key','routing',
        'heading', public._c('partner_lifecycle.routing_head'),
        'text',    public._c('partner_lifecycle.routing_text'), 'tone','info'),
      jsonb_build_object('key','inflight',
        'heading', public._c('partner_lifecycle.inflight_head'),
        'count',   v_inflight,
        'text',    case when v_inflight = 0 then public._c('partner_lifecycle.inflight_none')
                        else public._cf('partner_lifecycle.inflight_text',
                               jsonb_build_object('n', v_inflight::text)) end,
        'tone',    case when v_inflight = 0 then 'neutral' else 'warning' end),
      jsonb_build_object('key','balance',
        'heading', public._c('partner_lifecycle.balance_head'),
        'count',   v_periods,
        'amount',  public.inr_money(v_balance),
        'text',    case when v_periods = 0 then public._c('partner_lifecycle.balance_none')
                        else public._cf('partner_lifecycle.balance_text',
                               jsonb_build_object('amt', public.inr_money(v_balance),
                                                  'n', v_periods::text)) end,
        'tone',    case when v_periods = 0 then 'neutral' else 'info' end)));
end $fn$;

-- ===== c466_row154_routing_copy_truthful (20260901202618) =====
-- region_partners carries UNIQUE(district) and UNIQUE(zone_id) WHERE is_active,
-- so a zone has exactly ONE active partner. "New work reroutes to the next
-- active partner" is therefore only true once a replacement is activated, and
-- the card must say which of the two situations the admin is actually in
-- rather than promising a reroute that cannot happen.
insert into public.ui_copy(key, value) values
  ('partner_lifecycle.routing_replacement', to_jsonb('New orders in this zone go to {name} from now. Nothing new is routed to the suspended partner.'::text)),
  ('partner_lifecycle.routing_none',        to_jsonb('This zone has no other active partner, so new orders still land here until a replacement is activated. Activate one to move the work.'::text))
on conflict (key) do nothing;

create or replace function public.partner_lifecycle_card(p_partner_id bigint default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  v_role text := public.role_for_medibo_only();
  v_admin boolean := v_role in ('admin','super_admin');
  v_pid bigint := case when v_admin then coalesce(p_partner_id, public.my_partner_id())
                       else public.my_partner_id() end;
  rp public.region_partners%rowtype;
  v_inflight int := 0; v_periods int := 0; v_balance numeric := 0;
  v_status text; v_tone text; v_label text;
  v_next text; v_route_text text; v_route_tone text;
begin
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;
  select * into rp from region_partners where id = v_pid;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_partner',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;

  select count(*) into v_inflight
    from orders o
   where o.fulfillment_partner_id = v_pid
     and coalesce(o.status,'') not in ('delivered','cancelled','completed','closed','rejected');

  select count(*), coalesce(sum(coalesce(p.net_due, p.payable, 0)), 0)
    into v_periods, v_balance
    from partner_settlement_periods p
   where p.partner_id = v_pid and coalesce(p.status,'') <> 'settled';

  -- Who new work would actually go to.
  select o.partner_name into v_next
    from region_partners o
   where o.id <> v_pid and o.is_active and o.suspended_at is null
     and o.zone_id is not distinct from rp.zone_id
   order by o.id limit 1;

  if v_next is not null then
    v_route_text := public._cf('partner_lifecycle.routing_replacement',
                      jsonb_build_object('name', v_next));
    v_route_tone := 'info';
  else
    v_route_text := public._c('partner_lifecycle.routing_none');
    v_route_tone := 'warning';
  end if;

  if rp.suspended_at is not null then
    v_status := 'suspended'; v_tone := 'danger';
    v_label  := public._c('partner_lifecycle.suspended_label');
  elsif coalesce(rp.is_active,false) then
    v_status := 'active'; v_tone := 'success';
    v_label  := public._c('partner_lifecycle.active_label');
  else
    v_status := 'inactive'; v_tone := 'warning';
    v_label  := public._c('partner_lifecycle.inactive_label');
  end if;

  return jsonb_build_object('ok', true,
    'partner_id', v_pid, 'partner_name', rp.partner_name, 'zone_id', rp.zone_id,
    'heading', public._c('partner_lifecycle.heading'),
    'status', v_status, 'status_tone', v_tone, 'status_label', v_label,
    'is_suspended', rp.suspended_at is not null,
    'can_act', v_admin,
    'suspend_label', public._c('partner_lifecycle.suspend_label'),
    'resume_label',  public._c('partner_lifecycle.resume_label'),
    'reason_hint',   public._c('partner_lifecycle.reason_hint'),
    'suspend_reason', coalesce(rp.suspend_reason,''),
    'replacement', coalesce(v_next,''),
    'has_replacement', v_next is not null,
    'suspended_since', case when rp.suspended_at is null then ''
      else public._cf('partner_lifecycle.suspended_since', jsonb_build_object(
        'at', public.ist_fmt(rp.suspended_at,'dmy_hm'),
        'by', coalesce(rp.suspended_by,''))) end,
    'blocks', jsonb_build_array(
      jsonb_build_object('key','routing',
        'heading', public._c('partner_lifecycle.routing_head'),
        'text',    v_route_text, 'tone', v_route_tone),
      jsonb_build_object('key','inflight',
        'heading', public._c('partner_lifecycle.inflight_head'),
        'count',   v_inflight,
        'text',    case when v_inflight = 0 then public._c('partner_lifecycle.inflight_none')
                        else public._cf('partner_lifecycle.inflight_text',
                               jsonb_build_object('n', v_inflight::text)) end,
        'tone',    case when v_inflight = 0 then 'neutral' else 'warning' end),
      jsonb_build_object('key','balance',
        'heading', public._c('partner_lifecycle.balance_head'),
        'count',   v_periods,
        'amount',  public.inr_money(v_balance),
        'text',    case when v_periods = 0 then public._c('partner_lifecycle.balance_none')
                        else public._cf('partner_lifecycle.balance_text',
                               jsonb_build_object('amt', public.inr_money(v_balance),
                                                  'n', v_periods::text)) end,
        'tone',    case when v_periods = 0 then 'neutral' else 'info' end)));
end $fn$;

-- ===== c466_row150_partner_statement_document (20260901202801) =====
-- ROW 150 — there was no partner equivalent of admin_payout_statement: a
-- partner had no periodic DOCUMENT of orders fulfilled, gross value, commission
-- earned, deductions and net payable, and nothing anywhere said how GST applies
-- to the commission even though region_partners captures a gstin.
--
-- The generic document renderer from CHANGE #403 already draws any
-- title/header/sections/totals/notes payload, so this is SQL plus one branch in
-- bill-render. Nothing here computes in Dart and nothing computes in the
-- renderer: every rupee and every sentence is finished text from this function.

insert into public.app_settings(key, value) values
  ('partner_commission_gst', jsonb_build_object('rate', 18, 'sac', '9985'))
on conflict (key) do nothing;

create table if not exists public.partner_document (
  id            uuid primary key default gen_random_uuid(),
  partner_id    bigint      not null references public.region_partners(id) on delete cascade,
  kind          text        not null,
  ref_key       text        not null,
  title         text,
  file_name     text,
  bucket        text,
  path          text,
  status        text        not null default 'queued',
  attempts      int         not null default 0,
  source_stamp  text,
  requested_by  uuid,
  requested_at  timestamptz not null default now(),
  started_at    timestamptz,
  ready_at      timestamptz,
  bytes         bigint,
  last_error    text,
  created_at    timestamptz not null default now(),
  unique (partner_id, kind, ref_key)
);

alter table public.partner_document enable row level security;

-- The document model. GST is stated, not implied: the commission is the taxable
-- value of a service the partner supplies to mediBO, so a registered partner
-- raises a tax invoice for commission + GST and an unregistered one does not.
create or replace function public._c466_statement_payload(p_partner_id bigint, p_period_id bigint)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  pr public.partner_settlement_periods%rowtype;
  rp public.region_partners%rowtype;
  bc public.billing_config%rowtype;
  v_gst   jsonb := coalesce((select value from app_settings where key='partner_commission_gst'),
                            jsonb_build_object('rate',18,'sac','9985'));
  v_rate  numeric := coalesce((v_gst->>'rate')::numeric, 18);
  v_sac   text    := coalesce(v_gst->>'sac', '9985');
  v_reg   boolean;
  v_inter boolean;
  v_taxable numeric; v_tax numeric; v_cgst numeric := 0; v_sgst numeric := 0; v_igst numeric := 0;
  v_orders jsonb; v_costs jsonb; v_totals jsonb; v_period text; v_no text;
begin
  select * into pr from partner_settlement_periods where id = p_period_id and partner_id = p_partner_id;
  if not found then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  select * into rp from region_partners where id = p_partner_id;
  select * into bc from billing_config where id = 1;

  v_reg   := coalesce(nullif(btrim(coalesce(rp.gstin,'')),''),'') <> '';
  v_inter := v_reg and coalesce(nullif(btrim(coalesce(rp.state,'')),''),'')
             is distinct from coalesce(nullif(btrim(coalesce(bc.seller_state,'')),''),'');

  v_taxable := coalesce(pr.partner_share, 0);
  v_tax := case when v_reg then round(v_taxable * v_rate / 100.0, 2) else 0 end;
  if v_reg and v_inter then v_igst := v_tax;
  elsif v_reg then v_cgst := round(v_tax/2, 2); v_sgst := v_tax - v_cgst;
  end if;

  v_period := to_char(pr.period_start,'DD/MM/YYYY') || ' – ' || to_char(pr.period_end,'DD/MM/YYYY');
  v_no := 'PS-' || p_partner_id::text || '-' || p_period_id::text;

  select coalesce(jsonb_agg(jsonb_build_object(
           'date_label', to_char(s.order_date, 'DD/MM/YYYY'),
           'ref',        coalesce(s.order_code, ''),
           'revenue',    public.inr_money(s.revenue),
           'margin',     public.inr_money(s.gross_margin),
           'share',      public.inr_money(s.partner_share))
         order by s.order_date, s.id), '[]'::jsonb)
    into v_orders
    from partner_settlements s
   where s.period_id = p_period_id and s.partner_id = p_partner_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label',  coalesce(nullif(c.driver_label,''), c.cost_type),
           'amount', public.inr_money(coalesce(c.override_amount, c.computed_amount)))
         order by c.created_at), '[]'::jsonb)
    into v_costs
    from order_costs c
   where c.order_id in (select s.order_id from partner_settlements s
                         where s.period_id = p_period_id and s.partner_id = p_partner_id);

  v_totals := jsonb_build_array(
    jsonb_build_object('label', public._c('partner_doc.lbl_orders'),        'value', coalesce(pr.orders_count,0)::text),
    jsonb_build_object('label', public._c('partner_doc.lbl_gross'),         'value', public.inr_money(pr.revenue)),
    jsonb_build_object('label', public._c('partner_doc.lbl_margin'),        'value', public.inr_money(pr.gross_margin)),
    jsonb_build_object('label', public._c('partner_doc.lbl_costs'),         'value', public.inr_money(pr.cost_total)),
    jsonb_build_object('label', public._c('partner_doc.lbl_distributable'), 'value', public.inr_money(pr.distributable)),
    jsonb_build_object('label', public._c('partner_doc.lbl_split'),         'value', trim(to_char(coalesce(pr.split_pct,0),'FM990.00')) || '%'),
    jsonb_build_object('label', public._c('partner_doc.lbl_commission'),    'value', public.inr_money(pr.partner_share)),
    jsonb_build_object('label', public._c('partner_doc.lbl_brought_forward'),'value', public.inr_money(pr.brought_forward)),
    jsonb_build_object('label', public._c('partner_doc.lbl_net'),
                       'value', public.inr_money(coalesce(pr.net_due, pr.payable, 0)), 'bold', true));

  if v_reg then
    v_totals := v_totals
      || jsonb_build_object('label', public._c('partner_doc.gst_taxable'), 'value', public.inr_money(v_taxable))
      || jsonb_build_object('label', public._c('partner_doc.gst_cgst'),    'value', public.inr_money(v_cgst))
      || jsonb_build_object('label', public._c('partner_doc.gst_sgst'),    'value', public.inr_money(v_sgst))
      || jsonb_build_object('label', public._c('partner_doc.gst_igst'),    'value', public.inr_money(v_igst))
      || jsonb_build_object('label', public._c('partner_doc.gst_invoice_total'),
                            'value', public.inr_money(v_taxable + v_tax), 'bold', true);
  end if;

  return jsonb_build_object('ok', true,
    'stamp', md5(coalesce(pr.status,'') || coalesce(pr.partner_share,0)::text
                 || coalesce(pr.net_due,0)::text || coalesce(pr.orders_count,0)::text
                 || coalesce(rp.gstin,'') || v_rate::text),
    'file_name', v_no || '.pdf',
    'title', public._cf('partner_doc.doc_title', jsonb_build_object('period', v_period)),
    'doc', jsonb_build_object(
      'title', public._cf('partner_doc.doc_title', jsonb_build_object('period', v_period)),
      'subtitle', public._cf('partner_doc.doc_subtitle',
                    jsonb_build_object('at', public.ist_fmt(now(),'dmy_hm'))),
      'brand', public._c('partner_doc.doc_brand'),
      'header', jsonb_build_array(
        jsonb_build_object('label', public._c('partner_doc.lbl_partner'),      'value', coalesce(rp.partner_name,'')),
        jsonb_build_object('label', public._c('partner_doc.lbl_gstin'),        'value', coalesce(nullif(rp.gstin,''), public._c('partner_doc.no_gstin'))),
        jsonb_build_object('label', public._c('partner_doc.lbl_recipient'),    'value', coalesce(bc.seller_gstin,'')),
        jsonb_build_object('label', public._c('partner_doc.lbl_zone'),         'value', coalesce(rp.zone_id,0)::text),
        jsonb_build_object('label', public._c('partner_doc.lbl_period'),       'value', v_period),
        jsonb_build_object('label', public._c('partner_doc.lbl_statement_no'), 'value', v_no),
        jsonb_build_object('label', public._c('partner_doc.lbl_date'),         'value', to_char(now() at time zone 'Asia/Kolkata','DD/MM/YYYY')),
        jsonb_build_object('label', public._c('partner_doc.lbl_pos'),          'value', coalesce(rp.state,'')),
        jsonb_build_object('label', public._c('partner_doc.lbl_sac'),          'value', v_sac)),
      'sections', jsonb_build_array(
        jsonb_build_object(
          'heading', public._c('partner_doc.orders_heading'),
          'columns', jsonb_build_array(
            jsonb_build_object('key','date_label','label',public._c('partner_doc.col_date'),   'align','left', 'width',80),
            jsonb_build_object('key','ref',       'label',public._c('partner_doc.col_order'),  'align','left', 'width',150),
            jsonb_build_object('key','revenue',   'label',public._c('partner_doc.col_revenue'),'align','right','width',110),
            jsonb_build_object('key','margin',    'label',public._c('partner_doc.col_margin'), 'align','right','width',110),
            jsonb_build_object('key','share',     'label',public._c('partner_doc.col_share'),  'align','right','width',110)),
          'rows', v_orders,
          'empty_label', public._c('partner_doc.orders_empty')),
        jsonb_build_object(
          'heading', public._c('partner_doc.costs_heading'),
          'columns', jsonb_build_array(
            jsonb_build_object('key','label', 'label',public._c('partner_doc.col_cost_label'), 'align','left', 'width',330),
            jsonb_build_object('key','amount','label',public._c('partner_doc.col_cost_amount'),'align','right','width',110)),
          'rows', v_costs,
          'empty_label', public._c('partner_doc.costs_empty'))),
      'totals', v_totals,
      'notes', jsonb_build_array(
        case when v_reg then
          public._cf('partner_doc.gst_note_registered', jsonb_build_object(
            'gstin', coalesce(rp.gstin,''), 'rate', trim(to_char(v_rate,'FM990.##')), 'sac', v_sac))
        else public._c('partner_doc.gst_note_unregistered') end),
      'footer', public._c('partner_doc.footer')),
    'gst', jsonb_build_object('registered', v_reg, 'interstate', v_inter,
      'rate', v_rate, 'sac', v_sac,
      'taxable', public.inr_money(v_taxable), 'cgst', public.inr_money(v_cgst),
      'sgst', public.inr_money(v_sgst), 'igst', public.inr_money(v_igst),
      'invoice_total', public.inr_money(v_taxable + v_tax),
      'heading', public._c('partner_doc.gst_head'),
      'note', case when v_reg then
          public._cf('partner_doc.gst_note_registered', jsonb_build_object(
            'gstin', coalesce(rp.gstin,''), 'rate', trim(to_char(v_rate,'FM990.##')), 'sac', v_sac))
        else public._c('partner_doc.gst_note_unregistered') end));
end $fn$;

-- ===== c466_row150_partner_doc_rpcs (20260901202833) =====
-- request -> build -> poll -> open, the same contract the supplier documents use.
create or replace function public.partner_doc_request(p_kind text, p_ref text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'net'
as $fn$
declare
  v_pid bigint := public.my_partner_id();
  v_admin boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_period bigint; pay jsonb; d public.partner_document%rowtype; v_id uuid;
begin
  if v_pid is null and v_admin then
    -- mediBO staff pull a partner's statement by prefixing the period with its
    -- partner id, never by widening the partner fence for everyone else.
    select p.partner_id into v_pid from partner_settlement_periods p
     where p.id = nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
  end if;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','not_partner',
      'message', public._c('partner_doc.err_not_partner'));
  end if;
  if coalesce(p_kind,'') <> 'statement' then
    return jsonb_build_object('ok', false, 'error','unknown_kind',
      'message', public._c('partner_doc.err_unknown_kind'));
  end if;

  v_period := nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
  if v_period is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._c('partner_doc.err_not_found'));
  end if;

  pay := public._c466_statement_payload(v_pid, v_period);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
      'message', public._c('partner_doc.err_not_found'));
  end if;

  select * into d from public.partner_document
   where partner_id = v_pid and kind = p_kind and ref_key = v_period::text;

  if found and d.status = 'ready' and coalesce(d.path,'') <> ''
     and d.source_stamp is not distinct from (pay->>'stamp') then
    return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public._c('partner_doc.ready_message'),
      'gst', pay->'gst');
  end if;

  insert into public.partner_document(
      partner_id, kind, ref_key, title, file_name, status, attempts,
      source_stamp, requested_by, requested_at, started_at, last_error)
  values (v_pid, p_kind, v_period::text, pay->>'title', pay->>'file_name',
          'queued', 0, pay->>'stamp', auth.uid(), now(), null, null)
  on conflict (partner_id, kind, ref_key) do update
    set title = excluded.title, file_name = excluded.file_name,
        status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
        requested_by = excluded.requested_by, requested_at = now(),
        started_at = null, last_error = null
  returning id into v_id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('partner_doc_id', v_id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'status','building', 'doc_id', v_id,
    'poll_ms', 1500, 'message', public._c('partner_doc.building_message'),
    'gst', pay->'gst');
end $fn$;

create or replace function public.partner_doc_status(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  v_pid bigint := public.my_partner_id();
  v_admin boolean := public.role_for_medibo_only() in ('admin','super_admin');
  d public.partner_document%rowtype;
begin
  select * into d from public.partner_document where id = p_id;
  if not found or (not v_admin and d.partner_id is distinct from v_pid) then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._c('partner_doc.err_not_found'));
  end if;
  if d.status = 'ready' and coalesce(d.path,'') <> '' then
    return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public._c('partner_doc.ready_message'));
  end if;
  if d.status = 'failed' then
    return jsonb_build_object('ok', false, 'status','failed', 'doc_id', d.id,
      'error','render_failed', 'message', public._c('partner_doc.err_failed'));
  end if;
  return jsonb_build_object('ok', true, 'status','building', 'doc_id', d.id,
    'poll_ms', 1500, 'message', public._c('partner_doc.building_message'));
end $fn$;

create or replace function public.partner_doc_render_input(p_doc_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare d public.partner_document%rowtype; pay jsonb;
begin
  select * into d from public.partner_document where id = p_doc_id;
  if not found then return jsonb_build_object('ok', false, 'error','doc_not_found'); end if;

  update public.partner_document
     set status = 'running', attempts = attempts + 1, started_at = now()
   where id = p_doc_id;

  pay := public._c466_statement_payload(d.partner_id, d.ref_key::bigint);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
  end if;

  return jsonb_build_object('ok', true,
    'doc_id', d.id,
    'bucket', 'partner-receipts',
    'path', 'p' || d.partner_id::text || '/statement/' ||
            regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
    'file_name', coalesce(nullif(d.file_name,''), 'statement.pdf'),
    'document', pay->'doc');
end $fn$;

create or replace function public.partner_doc_report(
  p_doc_id uuid, p_ok boolean, p_bucket text default null, p_path text default null,
  p_name text default null, p_bytes bigint default null, p_error text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
begin
  if p_ok then
    update public.partner_document
       set status='ready', bucket=p_bucket, path=p_path,
           file_name = coalesce(nullif(p_name,''), file_name),
           bytes = p_bytes, ready_at = now(), last_error = null
     where id = p_doc_id;
  else
    update public.partner_document
       set status='failed', last_error = left(coalesce(p_error,'unknown'), 2000)
     where id = p_doc_id;
  end if;
  return jsonb_build_object('ok', true, 'doc_id', p_doc_id);
end $fn$;

grant execute on function public.partner_doc_request(text,text) to authenticated;
grant execute on function public.partner_doc_status(uuid)       to authenticated;

insert into storage.buckets (id, name, public)
values ('partner-receipts','partner-receipts', false)
on conflict (id) do nothing;

-- ===== c466_row150_render_delegation (20260901202945) =====
-- bill-render states its own extension point: renderDoc() names nothing, so a
-- new document kind is "a change in SQL and no deploy here". A partner
-- statement is that fourth kind. The two RPCs bill-render already calls learn
-- one fallback each: an id that is not a SUPPLIER document is looked for among
-- the PARTNER documents and handed to the partner pair. No edge-function
-- redeploy, and the partner_doc_* contract stays the one the app talks to.
create or replace function public.supplier_doc_render_input(p_doc_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare d public.supplier_document%rowtype; pay jsonb;
begin
  select * into d from public.supplier_document where id = p_doc_id;
  if not found then
    -- CMD #466 row 150 — a partner statement, drawn by the same renderer.
    if exists (select 1 from public.partner_document pd where pd.id = p_doc_id) then
      return public.partner_doc_render_input(p_doc_id);
    end if;
    return jsonb_build_object('ok', false, 'error', 'doc_not_found');
  end if;

  update public.supplier_document
     set status = 'running', attempts = attempts + 1, started_at = now()
   where id = p_doc_id;

  if d.kind = 'agency_invoice' then
    pay := public._agency_invoice_doc_payload(d.ref_key::uuid);
    if coalesce(pay->>'ok','false') <> 'true' then
      return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
    end if;
    return jsonb_build_object('ok', true,
      'doc_id', d.id,
      'bucket', 'partner-receipts',
      'path', 'da' || d.supplier_id::text || '/invoice/' ||
              regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
      'file_name', coalesce(nullif(d.file_name,''), 'invoice.pdf'),
      'document', pay->'doc');
  end if;

  pay := public._c403_doc_payload(d.supplier_id, d.kind, d.ref_key);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','no_payload'));
  end if;

  return jsonb_build_object('ok', true,
    'doc_id', d.id,
    'bucket', 'supplier-docs',
    'path', d.supplier_id::text || '/' || d.kind || '/' ||
            regexp_replace(d.ref_key, '[^0-9A-Za-z_-]', '', 'g') || '.pdf',
    'file_name', coalesce(nullif(d.file_name,''), 'document.pdf'),
    'document', pay->'doc');
end $fn$;

-- ===== c466_row150_report_delegation (20260901203018) =====
-- partner_doc_report takes bigint bytes; the renderer reports an integer.
create or replace function public.partner_doc_report(
  p_doc_id uuid, p_ok boolean, p_bucket text default null, p_path text default null,
  p_name text default null, p_bytes integer default null, p_error text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
begin
  if p_ok then
    update public.partner_document
       set status='ready', bucket=p_bucket, path=p_path,
           file_name = coalesce(nullif(p_name,''), file_name),
           bytes = p_bytes, ready_at = now(), last_error = null
     where id = p_doc_id;
  else
    update public.partner_document
       set status = case when attempts >= 3 then 'failed' else 'queued' end,
           last_error = left(coalesce(p_error,''), 500)
     where id = p_doc_id;
  end if;
  return jsonb_build_object('ok', true, 'doc_id', p_doc_id);
end $fn$;

drop function if exists public.partner_doc_report(uuid, boolean, text, text, text, bigint, text);

create or replace function public.supplier_doc_report(
  p_doc_id uuid, p_ok boolean, p_bucket text default null, p_path text default null,
  p_name text default null, p_bytes integer default null, p_error text default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
begin
  -- CMD #466 row 150 — the same delegation as supplier_doc_render_input: an id
  -- the supplier ledger does not own belongs to a partner statement.
  if not exists (select 1 from public.supplier_document where id = p_doc_id)
     and exists (select 1 from public.partner_document where id = p_doc_id) then
    return public.partner_doc_report(p_doc_id, p_ok, p_bucket, p_path, p_name, p_bytes, p_error);
  end if;

  if p_ok then
    update public.supplier_document
       set status = 'ready', bucket = p_bucket, path = p_path,
           file_name = coalesce(nullif(p_name,''), file_name),
           bytes = p_bytes, ready_at = now(), last_error = null
     where id = p_doc_id;
  else
    update public.supplier_document
       set status = case when attempts >= 3 then 'failed' else 'queued' end,
           last_error = left(coalesce(p_error,''), 500)
     where id = p_doc_id;
  end if;
  return jsonb_build_object('ok', true, 'doc_id', p_doc_id);
end $fn$;

-- and the request posts the id bill-render already understands
create or replace function public.partner_doc_request(p_kind text, p_ref text)
returns jsonb
language plpgsql security definer set search_path to 'public', 'net'
as $fn$
declare
  v_pid bigint := public.my_partner_id();
  v_admin boolean := public.role_for_medibo_only() in ('admin','super_admin');
  v_period bigint; pay jsonb; d public.partner_document%rowtype; v_id uuid;
begin
  if v_pid is null and v_admin then
    select p.partner_id into v_pid from partner_settlement_periods p
     where p.id = nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
  end if;
  if v_pid is null then
    return jsonb_build_object('ok', false, 'error','not_partner',
      'message', public._c('partner_doc.err_not_partner'));
  end if;
  if coalesce(p_kind,'') <> 'statement' then
    return jsonb_build_object('ok', false, 'error','unknown_kind',
      'message', public._c('partner_doc.err_unknown_kind'));
  end if;

  v_period := nullif(regexp_replace(coalesce(p_ref,''), '\D', '', 'g'),'')::bigint;
  if v_period is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._c('partner_doc.err_not_found'));
  end if;

  pay := public._c466_statement_payload(v_pid, v_period);
  if coalesce(pay->>'ok','false') <> 'true' then
    return jsonb_build_object('ok', false, 'error', coalesce(pay->>'error','not_found'),
      'message', public._c('partner_doc.err_not_found'));
  end if;

  select * into d from public.partner_document
   where partner_id = v_pid and kind = p_kind and ref_key = v_period::text;

  if found and d.status = 'ready' and coalesce(d.path,'') <> ''
     and d.source_stamp is not distinct from (pay->>'stamp') then
    return jsonb_build_object('ok', true, 'status','ready', 'doc_id', d.id,
      'bucket', d.bucket, 'path', d.path, 'file_name', d.file_name,
      'expires_s', 300, 'message', public._c('partner_doc.ready_message'),
      'gst', pay->'gst');
  end if;

  insert into public.partner_document(
      partner_id, kind, ref_key, title, file_name, status, attempts,
      source_stamp, requested_by, requested_at, started_at, last_error)
  values (v_pid, p_kind, v_period::text, pay->>'title', pay->>'file_name',
          'queued', 0, pay->>'stamp', auth.uid(), now(), null, null)
  on conflict (partner_id, kind, ref_key) do update
    set title = excluded.title, file_name = excluded.file_name,
        status = 'queued', attempts = 0, source_stamp = excluded.source_stamp,
        requested_by = excluded.requested_by, requested_at = now(),
        started_at = null, last_error = null
  returning id into v_id;

  perform net.http_post(
    url     := 'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-render',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-notify-secret','medibo_order_notify_2027',
                                  'Authorization','Bearer ' || public._service_key()),
    body    := jsonb_build_object('supplier_doc_id', v_id),
    timeout_milliseconds := 20000);

  return jsonb_build_object('ok', true, 'status','building', 'doc_id', v_id,
    'poll_ms', 1500, 'message', public._c('partner_doc.building_message'),
    'gst', pay->'gst');
end $fn$;

grant execute on function public.partner_doc_request(text,text) to authenticated;

-- ===== c466_row150_statement_carries_document (20260901203043) =====
-- The statement screen now carries the download affordance and the GST block,
-- so the document is reachable from the surface the partner already opens.
create or replace function public.partner_statement(p_period_id bigint default null, p_limit integer default 20)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare
  v_partner bigint := public.my_partner_id();
  v_pid bigint := p_period_id;
  v_pay jsonb;
begin
  if v_partner is null then
    return jsonb_build_object('ok', false, 'title', public._stl_c('ui.title'),
                              'message', public._stl_c('ui.partner_denied'));
  end if;
  if v_pid is null then
    select id into v_pid from public.partner_settlement_periods
     where partner_id = v_partner and status <> 'open'
     order by period_end desc, id desc limit 1;
  end if;

  if v_pid is not null then
    v_pay := public._c466_statement_payload(v_partner, v_pid);
  end if;

  return jsonb_build_object(
    'ok', true,
    'title',    public._stl_c('ui.title'),
    'subtitle', public._stl_c('ui.subtitle'),
    'footnote', public._stl_c('ui.footnote'),
    'error_text', public._stl_c('ui.error'),
    'retry_text', public._stl_c('ui.retry'),
    'empty_text', public._stl_c('ui.empty'),
    'partner', coalesce((select partner_name from public.region_partners where id = v_partner), ''),
    'periods', jsonb_build_object(
      'heading', public._stl_c('sec.periods'),
      'empty_text', public._stl_c('period.empty'),
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'period_id', p.id,
                 'label', format(public._stl_c('period.window'),
                                 public.ist_fmt(p.period_start::timestamptz,'dmy'),
                                 public.ist_fmt(p.period_end::timestamptz,'dmy')),
                 'sub', public._stl_c('period.' || p.status) || ' · ' ||
                        public._stl_c('cad.' || p.cadence),
                 'value', public.inr_money(p.payable),
                 'value_tone', public._stl_tone('period.' || p.status))
               order by p.period_end desc, p.id desc)
          from (select * from public.partner_settlement_periods
                 where partner_id = v_partner and status <> 'open'
                 order by period_end desc, id desc
                 limit greatest(coalesce(p_limit,20),1)) p), '[]'::jsonb)),
    -- CMD #466 row 150 — the periodic DOCUMENT, and the GST treatment of the
    -- commission stated in words rather than left to the partner to guess.
    'document', case when v_pid is null then null else jsonb_build_object(
        'has', coalesce(v_pay->>'ok','false') = 'true',
        'kind', 'statement',
        'ref', v_pid::text,
        'title', public._c('partner_doc.title'),
        'button_label', public._c('partner_doc.button'),
        'building_message', public._c('partner_doc.building_message'),
        'ready_message', public._c('partner_doc.ready_message'),
        'error_message', public._c('partner_doc.err_failed')) end,
    'gst', case when v_pid is null then null else v_pay->'gst' end,
    'statement', case when v_pid is null then null
                      else public.settlement_statement(v_pid) end);
end $fn$;

-- ===== c466_row150_gst_lines (20260901203312) =====
-- The GST card on the statement screen prints a list of label/value rows. The
-- LIST is the backend's, so adding a cess line one day is an UPDATE here.
create or replace function public._c466_gst_lines(
  p_taxable numeric, p_cgst numeric, p_sgst numeric, p_igst numeric)
returns jsonb
language sql stable security definer set search_path to 'public'
as $fn$
  select jsonb_build_array(
    jsonb_build_object('label', public._c('partner_doc.gst_taxable'),       'value', public.inr_money(p_taxable)),
    jsonb_build_object('label', public._c('partner_doc.gst_cgst'),          'value', public.inr_money(p_cgst)),
    jsonb_build_object('label', public._c('partner_doc.gst_sgst'),          'value', public.inr_money(p_sgst)),
    jsonb_build_object('label', public._c('partner_doc.gst_igst'),          'value', public.inr_money(p_igst)),
    jsonb_build_object('label', public._c('partner_doc.gst_invoice_total'),
                       'value', public.inr_money(p_taxable + p_cgst + p_sgst + p_igst), 'bold', true));
$fn$;

do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='_c466_statement_payload';
  if position('''lines'', public._c466_gst_lines' in v_def) > 0 then return; end if;
  v_def := replace(v_def,
    '''invoice_total'', public.inr_money(v_taxable + v_tax),',
    '''invoice_total'', public.inr_money(v_taxable + v_tax),
      ''lines'', public._c466_gst_lines(v_taxable, v_cgst, v_sgst, v_igst),');
  if position('''lines'', public._c466_gst_lines' in v_def) = 0 then
    raise exception 'c466: could not splice gst lines into _c466_statement_payload';
  end if;
  execute v_def;
end $mig$;

-- ===== c466_console_carries_lifecycle_and_licences (20260901203343) =====
-- The admin partner console gains the two things rows 153 and 154 were about,
-- as blocks of the SAME payload it already renders: the partner's status (with
-- the suspend / resume action and what suspension does to work in hand and to
-- the open balance) and the licence expiry list.
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='admin_partner_console';
  if v_def is null then raise exception 'c466: admin_partner_console not found'; end if;
  if position('''lifecycle'', public.partner_lifecycle_card' in v_def) > 0 then return; end if;

  v_def := replace(v_def,
    '    ''fence'', public.partner_fence_card(),',
    '    ''fence'', public.partner_fence_card(),
    -- CMD #466 rows 153 + 154 — status/suspension and licence expiry.
    ''lifecycle'', public.partner_lifecycle_card(rp.id),
    ''licences'', public.partner_licence_card(rp.id),');

  if position('''lifecycle'', public.partner_lifecycle_card' in v_def) = 0 then
    raise exception 'c466: could not splice lifecycle/licences into admin_partner_console';
  end if;
  execute v_def;
end $mig$;

-- ===== c466_export_helper (20260901204435) =====
-- A guarded reader so the runner can write this command's applied SQL back into
-- the repo without hand-copying it. Service role only.
create or replace function public.c466_migration_sql()
returns text
language plpgsql security definer set search_path to 'public'
as $fn$
declare v text;
begin
  perform public._dev_guard();
  select string_agg('-- ===== ' || m.name || ' (' || m.version || ') =====' || chr(10) || s,
                    chr(10) || chr(10) order by m.version, i)
    into v
    from supabase_migrations.schema_migrations m,
         lateral unnest(m.statements) with ordinality as t(s, i)
   where m.name like 'c466\_%';
  return coalesce(v, '');
end $fn$;

-- ===== c466_qa1_stamp_never_leaves_the_zone (20260901210838) =====
-- QA round 1, BLOCKER 1. The suspension guard added to orders_stamp_partner()
-- sat in front of a pre-existing CROSS-ZONE fallback, which until now could only
-- fire when a zone had no active partner at all. Suspending the zone's sole
-- partner made it reachable in the ordinary case, and a zone-1 order then
-- stamped to the zone-2 partner — while partner_lifecycle_card correctly said
-- there was no replacement in this zone. A zone's work must never silently
-- cross into another zone: the whole partner model is zone-locked, and every
-- downstream fence (partner_zone_ok, partner_scope_order) is too.
--
-- Order of preference now, and the SAME ZONE always beats "some other zone":
--   1. this zone, active, not suspended        <- the normal case
--   2. this zone, active, even if suspended    <- work stays home; the card
--                                                 tells the admin to activate
--                                                 a replacement IN THIS ZONE
--   3. any active, not suspended               <- only when the zone has no
--   4. any active                                 partner at all
create or replace function public.orders_stamp_partner()
returns trigger
language plpgsql security definer set search_path to 'public'
as $fn$
declare v_zone smallint := COALESCE(NEW.zone_id, 1);
BEGIN
  IF NEW.fulfillment_partner_id IS NULL THEN
    SELECT rp.id INTO NEW.fulfillment_partner_id
      FROM region_partners rp
     WHERE rp.is_active AND rp.suspended_at IS NULL AND rp.zone_id = v_zone
     ORDER BY rp.id LIMIT 1;

    IF NEW.fulfillment_partner_id IS NULL THEN
      SELECT rp.id INTO NEW.fulfillment_partner_id
        FROM region_partners rp
       WHERE rp.is_active AND rp.zone_id = v_zone
       ORDER BY rp.id LIMIT 1;
    END IF;

    IF NEW.fulfillment_partner_id IS NULL THEN
      SELECT rp.id INTO NEW.fulfillment_partner_id
        FROM region_partners rp
       WHERE rp.is_active AND rp.suspended_at IS NULL
       ORDER BY rp.id LIMIT 1;
    END IF;

    IF NEW.fulfillment_partner_id IS NULL THEN
      SELECT rp.id INTO NEW.fulfillment_partner_id
        FROM region_partners rp
       WHERE rp.is_active ORDER BY rp.id LIMIT 1;
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

-- partner_for_district() had the same shape: its 'Raipur' fallback is a
-- DIFFERENT district, so a suspended partner in district X could hand its work
-- to Raipur. Prefer the district itself, suspended or not, over another one.
create or replace function public.partner_for_district(p_district text)
returns jsonb
language sql stable security definer set search_path to 'public'
as $fn$
  with want as (select public.norm_district(p_district) as d),
  hit as (
    select rp.* from region_partners rp, want w
    where rp.is_active and rp.suspended_at is null and rp.district = w.d limit 1
  ),
  -- the district's own partner, even suspended: its work stays in its district
  same_district as (
    select rp.* from region_partners rp, want w
    where rp.is_active and rp.district = w.d limit 1
  ),
  fallback as (
    select rp.* from region_partners rp
    where rp.is_active and rp.suspended_at is null and rp.district = 'Raipur' limit 1
  ),
  last_resort as (
    select rp.* from region_partners rp where rp.is_active order by rp.id limit 1
  ),
  chosen as (
    select * from hit
    union all select * from same_district where not exists (select 1 from hit)
    union all select * from fallback
      where not exists (select 1 from hit) and not exists (select 1 from same_district)
    union all select * from last_resort
      where not exists (select 1 from hit) and not exists (select 1 from same_district)
        and not exists (select 1 from fallback)
  )
  select jsonb_build_object(
    'district', c.district,
    'partner_name', c.partner_name,
    'address', c.address,
    'gstin', c.gstin,
    'dl_20b', c.dl_20b,
    'dl_21b', c.dl_21b,
    'state', c.state,
    'dl_combined', concat_ws('  |  ',
        nullif('20B: '||coalesce(c.dl_20b,''),'20B: '),
        nullif('21B: '||coalesce(c.dl_21b,''),'21B: ')),
    'gst_doc_path', c.gst_doc_path,
    'dl20b_doc_path', c.dl20b_doc_path,
    'dl21b_doc_path', c.dl21b_doc_path,
    'suspended', c.suspended_at is not null,
    'matched', (select w.d from want w) is not distinct from c.district
  ) from chosen c limit 1;
$fn$;

-- QA round 1, MAJOR: btrim() strips spaces only, so a tab or a newline passed
-- as a "reason". Collapse ALL whitespace before deciding it is empty.
create or replace function public.partner_suspend(p_partner_id bigint, p_reason text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $fn$
declare
  v_reason text := nullif(btrim(regexp_replace(coalesce(p_reason,''), '\s+', ' ', 'g')), '');
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public._c('partner_lifecycle.err_not_authorized'));
  end if;
  if not exists (select 1 from region_partners where id = p_partner_id) then
    return jsonb_build_object('ok', false, 'error','no_partner','tone','danger',
      'message', public._c('partner_lifecycle.err_no_partner'));
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'error','no_reason','tone','danger',
      'message', public._c('partner_lifecycle.err_no_reason'));
  end if;

  update region_partners
     set suspended_at = coalesce(suspended_at, now()),
         suspended_by = coalesce(public.my_login_email(),'admin'),
         suspend_reason = v_reason,
         updated_at = now()
   where id = p_partner_id;

  insert into partner_audit_log(partner_id, user_id, feature_key, action, detail)
  values (p_partner_id, auth.uid(), 'partner.onboarding', 'partner_suspended',
          jsonb_build_object('reason', v_reason,
            'summary', public._c('partner_lifecycle.suspended_toast')));

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('partner_lifecycle.suspended_toast'),
    'card', public.partner_lifecycle_card(p_partner_id));
end $fn$;

-- ===== c466_qa1_platform_gstin_not_the_partner_mirror (20260901210900) =====
-- QA round 1, BLOCKER 2. billing_config is NOT mediBO's own identity: the
-- trigger sync_active_partner_to_billing() copies the ACTIVE PARTNER's name,
-- GSTIN, address and state into it, because a customer bill is raised by the
-- zone's partner. Reading seller_gstin / seller_state as "mediBO" therefore
-- printed the partner's own GSTIN as the recipient of its own commission
-- invoice, and made the interstate test compare a state with itself — so the
-- IGST branch could never fire. It was invisible in testing only because the
-- one settlement period has partner_share = 0.
--
-- mediBO the platform already has its own row: platform_identity. Give it the
-- two fields the commission invoice actually needs. No trigger writes here.
alter table public.platform_identity
  add column if not exists gstin text,
  add column if not exists state text;

-- Seed from what billing_config holds TODAY, which is the operator's own
-- registration (the About page names Jai Mahakal Medical And Surgical, in
-- Chhattisgarh, as the legal operator, and that is the currently active zone-1
-- partner). Seeded once; from here it is edited, never synced.
update public.platform_identity p
   set gstin = coalesce(nullif(p.gstin,''), (select b.seller_gstin from public.billing_config b where b.id = 1)),
       state = coalesce(nullif(p.state,''), (select coalesce(b.seller_state,'Chhattisgarh') from public.billing_config b where b.id = 1))
 where p.id = 1;

-- and let an admin correct it without a deploy
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(pr.oid) into v_def from pg_proc pr
    join pg_namespace n on n.oid = pr.pronamespace
   where n.nspname='public' and pr.proname='admin_save_platform_identity';
  if v_def is null then raise exception 'c466: admin_save_platform_identity not found'; end if;
  if position('gstin               = coalesce' in v_def) > 0 then return; end if;
  v_def := replace(v_def,
    '    udyam_no            = coalesce(p->>''udyam_no'', udyam_no),',
    '    udyam_no            = coalesce(p->>''udyam_no'', udyam_no),
    -- CMD #466 — mediBO''s OWN GST registration, the recipient on a partner
    -- commission invoice. Never the partner-mirrored billing_config.
    gstin               = coalesce(p->>''gstin'', gstin),
    state               = coalesce(p->>''state'', state),');
  if position('gstin               = coalesce' in v_def) = 0 then
    raise exception 'c466: could not splice gstin/state into admin_save_platform_identity';
  end if;
  execute v_def;
end $mig$;

insert into public.ui_copy(key, value) values
  ('partner_doc.gst_note_self', to_jsonb('GST: this zone is fulfilled by mediBO''s own operating entity — the partner and mediBO are the same registration ({gstin}), so there is no supply between two parties and no tax invoice arises on this commission. The figure above is an internal profit share.'::text))
on conflict (key) do nothing;

-- ===== c466_qa1_statement_gst_from_platform_identity (20260901210945) =====
-- The statement now reads mediBO's own registration from platform_identity, so
-- the recipient GSTIN is mediBO's and the interstate test compares the PARTNER's
-- state with MEDIBO's rather than with a copy of itself. A partner that IS the
-- operating entity (same GSTIN) is a third case: no supply, no tax invoice.
create or replace function public._c466_statement_payload(p_partner_id bigint, p_period_id bigint)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare
  pr public.partner_settlement_periods%rowtype;
  rp public.region_partners%rowtype;
  v_gst   jsonb := coalesce((select value from app_settings where key='partner_commission_gst'),
                            jsonb_build_object('rate',18,'sac','9985'));
  v_rate  numeric := coalesce((v_gst->>'rate')::numeric, 18);
  v_sac   text    := coalesce(v_gst->>'sac', '9985');
  v_me_gstin text; v_me_state text;
  v_p_gstin  text; v_p_state  text;
  v_reg boolean; v_self boolean; v_inter boolean;
  v_taxable numeric; v_tax numeric; v_cgst numeric := 0; v_sgst numeric := 0; v_igst numeric := 0;
  v_note text;
  v_orders jsonb; v_costs jsonb; v_totals jsonb; v_period text; v_no text;
begin
  select * into pr from partner_settlement_periods where id = p_period_id and partner_id = p_partner_id;
  if not found then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  select * into rp from region_partners where id = p_partner_id;

  -- mediBO's OWN registration. platform_identity is never written by
  -- sync_active_partner_to_billing(); billing_config is, so it is only a
  -- last-resort fallback for a database seeded before this column existed.
  select nullif(btrim(coalesce(pi.gstin,'')),''), nullif(btrim(coalesce(pi.state,'')),'')
    into v_me_gstin, v_me_state from public.platform_identity pi where pi.id = 1;
  if v_me_gstin is null or v_me_state is null then
    select coalesce(v_me_gstin, nullif(btrim(coalesce(b.seller_gstin,'')),'')),
           coalesce(v_me_state, nullif(btrim(coalesce(b.seller_state,'')),''))
      into v_me_gstin, v_me_state from public.billing_config b where b.id = 1;
  end if;

  v_p_gstin := nullif(btrim(coalesce(rp.gstin,'')),'');
  v_p_state := nullif(btrim(coalesce(rp.state,'')),'');

  v_reg   := v_p_gstin is not null;
  v_self  := v_reg and v_me_gstin is not null
             and upper(v_p_gstin) = upper(v_me_gstin);
  v_inter := v_reg and not v_self
             and v_p_state is not null and v_me_state is not null
             and upper(v_p_state) is distinct from upper(v_me_state);

  v_taxable := coalesce(pr.partner_share, 0);
  v_tax := case when v_reg and not v_self then round(v_taxable * v_rate / 100.0, 2) else 0 end;
  if v_inter then v_igst := v_tax;
  elsif v_reg and not v_self then v_cgst := round(v_tax/2, 2); v_sgst := v_tax - v_cgst;
  end if;

  v_note := case
    when v_self then public._cf('partner_doc.gst_note_self',
            jsonb_build_object('gstin', coalesce(v_p_gstin,'')))
    when v_reg then public._cf('partner_doc.gst_note_registered', jsonb_build_object(
            'gstin', coalesce(v_p_gstin,''), 'rate', trim(to_char(v_rate,'FM990.##')), 'sac', v_sac))
    else public._c('partner_doc.gst_note_unregistered') end;

  v_period := to_char(pr.period_start,'DD/MM/YYYY') || ' – ' || to_char(pr.period_end,'DD/MM/YYYY');
  v_no := 'PS-' || p_partner_id::text || '-' || p_period_id::text;

  select coalesce(jsonb_agg(jsonb_build_object(
           'date_label', to_char(s.order_date, 'DD/MM/YYYY'),
           'ref',        coalesce(s.order_code, ''),
           'revenue',    public.inr_money(s.revenue),
           'margin',     public.inr_money(s.gross_margin),
           'share',      public.inr_money(s.partner_share))
         order by s.order_date, s.id), '[]'::jsonb)
    into v_orders
    from partner_settlements s
   where s.period_id = p_period_id and s.partner_id = p_partner_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label',  coalesce(nullif(c.driver_label,''), c.cost_type),
           'amount', public.inr_money(coalesce(c.override_amount, c.computed_amount)))
         order by c.created_at), '[]'::jsonb)
    into v_costs
    from order_costs c
   where c.order_id in (select s.order_id from partner_settlements s
                         where s.period_id = p_period_id and s.partner_id = p_partner_id);

  v_totals := jsonb_build_array(
    jsonb_build_object('label', public._c('partner_doc.lbl_orders'),        'value', coalesce(pr.orders_count,0)::text),
    jsonb_build_object('label', public._c('partner_doc.lbl_gross'),         'value', public.inr_money(pr.revenue)),
    jsonb_build_object('label', public._c('partner_doc.lbl_margin'),        'value', public.inr_money(pr.gross_margin)),
    jsonb_build_object('label', public._c('partner_doc.lbl_costs'),         'value', public.inr_money(pr.cost_total)),
    jsonb_build_object('label', public._c('partner_doc.lbl_distributable'), 'value', public.inr_money(pr.distributable)),
    jsonb_build_object('label', public._c('partner_doc.lbl_split'),         'value', trim(to_char(coalesce(pr.split_pct,0),'FM990.00')) || '%'),
    jsonb_build_object('label', public._c('partner_doc.lbl_commission'),    'value', public.inr_money(pr.partner_share)),
    jsonb_build_object('label', public._c('partner_doc.lbl_brought_forward'),'value', public.inr_money(pr.brought_forward)),
    jsonb_build_object('label', public._c('partner_doc.lbl_net'),
                       'value', public.inr_money(coalesce(pr.net_due, pr.payable, 0)), 'bold', true));

  if v_reg and not v_self then
    v_totals := v_totals
      || jsonb_build_object('label', public._c('partner_doc.gst_taxable'), 'value', public.inr_money(v_taxable))
      || jsonb_build_object('label', public._c('partner_doc.gst_cgst'),    'value', public.inr_money(v_cgst))
      || jsonb_build_object('label', public._c('partner_doc.gst_sgst'),    'value', public.inr_money(v_sgst))
      || jsonb_build_object('label', public._c('partner_doc.gst_igst'),    'value', public.inr_money(v_igst))
      || jsonb_build_object('label', public._c('partner_doc.gst_invoice_total'),
                            'value', public.inr_money(v_taxable + v_tax), 'bold', true);
  end if;

  return jsonb_build_object('ok', true,
    'stamp', md5(coalesce(pr.status,'') || coalesce(pr.partner_share,0)::text
                 || coalesce(pr.net_due,0)::text || coalesce(pr.orders_count,0)::text
                 || coalesce(v_p_gstin,'') || coalesce(v_me_gstin,'')
                 || coalesce(v_p_state,'') || coalesce(v_me_state,'') || v_rate::text),
    'file_name', v_no || '.pdf',
    'title', public._cf('partner_doc.doc_title', jsonb_build_object('period', v_period)),
    'doc', jsonb_build_object(
      'title', public._cf('partner_doc.doc_title', jsonb_build_object('period', v_period)),
      'subtitle', public._cf('partner_doc.doc_subtitle',
                    jsonb_build_object('at', public.ist_fmt(now(),'dmy_hm'))),
      'brand', public._c('partner_doc.doc_brand'),
      'header', jsonb_build_array(
        jsonb_build_object('label', public._c('partner_doc.lbl_partner'),      'value', coalesce(rp.partner_name,'')),
        jsonb_build_object('label', public._c('partner_doc.lbl_gstin'),        'value', coalesce(v_p_gstin, public._c('partner_doc.no_gstin'))),
        jsonb_build_object('label', public._c('partner_doc.lbl_recipient'),    'value', coalesce(v_me_gstin, public._c('partner_doc.no_gstin'))),
        jsonb_build_object('label', public._c('partner_doc.lbl_zone'),         'value', coalesce(rp.zone_id,0)::text),
        jsonb_build_object('label', public._c('partner_doc.lbl_period'),       'value', v_period),
        jsonb_build_object('label', public._c('partner_doc.lbl_statement_no'), 'value', v_no),
        jsonb_build_object('label', public._c('partner_doc.lbl_date'),         'value', to_char(now() at time zone 'Asia/Kolkata','DD/MM/YYYY')),
        jsonb_build_object('label', public._c('partner_doc.lbl_pos'),          'value', coalesce(v_p_state,'')),
        jsonb_build_object('label', public._c('partner_doc.lbl_sac'),          'value', v_sac)),
      'sections', jsonb_build_array(
        jsonb_build_object(
          'heading', public._c('partner_doc.orders_heading'),
          'columns', jsonb_build_array(
            jsonb_build_object('key','date_label','label',public._c('partner_doc.col_date'),   'align','left', 'width',80),
            jsonb_build_object('key','ref',       'label',public._c('partner_doc.col_order'),  'align','left', 'width',150),
            jsonb_build_object('key','revenue',   'label',public._c('partner_doc.col_revenue'),'align','right','width',110),
            jsonb_build_object('key','margin',    'label',public._c('partner_doc.col_margin'), 'align','right','width',110),
            jsonb_build_object('key','share',     'label',public._c('partner_doc.col_share'),  'align','right','width',110)),
          'rows', v_orders,
          'empty_label', public._c('partner_doc.orders_empty')),
        jsonb_build_object(
          'heading', public._c('partner_doc.costs_heading'),
          'columns', jsonb_build_array(
            jsonb_build_object('key','label', 'label',public._c('partner_doc.col_cost_label'), 'align','left', 'width',330),
            jsonb_build_object('key','amount','label',public._c('partner_doc.col_cost_amount'),'align','right','width',110)),
          'rows', v_costs,
          'empty_label', public._c('partner_doc.costs_empty'))),
      'totals', v_totals,
      'notes', jsonb_build_array(v_note),
      'footer', public._c('partner_doc.footer')),
    'gst', jsonb_build_object(
      'registered', (v_reg and not v_self), 'interstate', v_inter, 'self_billing', v_self,
      'rate', v_rate, 'sac', v_sac,
      'taxable', public.inr_money(v_taxable), 'cgst', public.inr_money(v_cgst),
      'sgst', public.inr_money(v_sgst), 'igst', public.inr_money(v_igst),
      'invoice_total', public.inr_money(v_taxable + v_tax),
      'lines', case when (v_reg and not v_self)
                    then public._c466_gst_lines(v_taxable, v_cgst, v_sgst, v_igst)
                    else '[]'::jsonb end,
      'heading', public._c('partner_doc.gst_head'),
      'note', v_note));
end $fn$;
