-- CHANGE #850 — Supplier My Account.
--
-- The supplier-facing mirror of #753's admin supplier page, on the SAME shape:
-- a registry table names the tabs, each tab names its own RPC, each RPC answers
-- with blocks[] in the grammar #840's MyAccountScreen already renders
-- (kv | tiles | chips | list | table | timeline | toggles | select | actions |
--  calendar | nav | note). Nothing on this page is decided in Dart: every
-- label, rupee, percentage, chip tone, empty state and toast is built here.
--
-- Identity is the LOGIN's own supplier — never a parameter — so a supplier can
-- only ever read their own data, and a staff sub-login is clamped further by
-- supplier_can() through each tab's feature_key.

begin;

-- ── 1. the registry ─────────────────────────────────────────────────────────
create table if not exists public.supplier_account_tab (
  tab_key     text primary key,
  copy_key    text not null,
  icon_key    text not null default '',
  rpc         text not null default '',
  feature_key text,
  sort_order  int  not null default 0,
  is_active   boolean not null default true
);

alter table public.supplier_account_tab enable row level security;

drop policy if exists supplier_account_tab_read on public.supplier_account_tab;
create policy supplier_account_tab_read on public.supplier_account_tab
  for select using (true);

insert into public.supplier_account_tab (tab_key, copy_key, icon_key, sort_order, feature_key) values
  ('profile',      'sup_acct.tab_profile',      'store',        10, null),
  ('companies',    'sup_acct.tab_companies',    'domain',       20, null),
  ('availability', 'sup_acct.tab_availability', 'inventory',    30, null),
  ('orders',       'sup_acct.tab_orders',       'receipt',      40, 'supplier.orders'),
  ('payments',     'sup_acct.tab_payments',     'payments',     50, null),
  ('returns',      'sup_acct.tab_returns',      'assignment',   60, null),
  ('performance',  'sup_acct.tab_performance',  'insights',     70, null),
  ('history',      'sup_acct.tab_history',      'history',      80, null),
  ('statement',    'sup_acct.tab_statement',    'description',  90, null),
  ('coverage',     'sup_acct.tab_coverage',     'map',         100, null),
  ('staff',        'sup_acct.tab_staff',        'people',      110, 'supplier.staff'),
  ('preferences',  'sup_acct.tab_preferences',  'settings',    120, null)
on conflict (tab_key) do update
  set copy_key = excluded.copy_key,
      icon_key = excluded.icon_key,
      sort_order = excluded.sort_order,
      feature_key = excluded.feature_key,
      is_active = true;

-- ── 2. identity + small helpers ─────────────────────────────────────────────
create or replace function public._sup850_me()
returns public.supplier_profiles
language plpgsql security definer set search_path to 'public' as $fn$
declare sp public.supplier_profiles%rowtype; v uuid;
begin
  v := public.my_supplier_id();
  if v is not null then
    select * into sp from public.supplier_profiles where id = v;
    if sp.id is not null then return sp; end if;
  end if;
  sp := public.current_supplier_profile();
  return sp;
end $fn$;

create or replace function public._sup850_t(p_key text)
returns text language sql stable security definer set search_path to 'public' as $fn$
  select public.ui_text('sup_acct.'||p_key)
$fn$;

create or replace function public._sup850_deny()
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object('ok', false, 'blocks', '[]'::jsonb,
                            'error', 'not_a_supplier',
                            'message', public._sup850_t('denied'))
$fn$;

create or replace function public._sup850_kv(p_label text, p_value text)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select jsonb_build_object(
    'label', p_label,
    'value', case when coalesce(btrim(coalesce(p_value,'')),'') = ''
                  then public._sup850_t('not_set') else btrim(p_value) end,
    'muted', (coalesce(btrim(coalesce(p_value,'')),'') = ''))
$fn$;

-- Month chips every month-filtered tab draws, twelve back from this one.
create or replace function public._sup850_months(p_active date)
returns jsonb language sql stable security definer set search_path to 'public' as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', to_char(mm,'YYYY-MM'),
           'label', to_char(mm,'Mon YY'),
           'value', to_char(mm,'YYYY-MM'),
           'active', (mm = p_active)) order by mm desc), '[]'::jsonb)
    from (select (date_trunc('month',(now() at time zone 'Asia/Kolkata')::date)::date
                  - (i||' months')::interval)::date as mm
            from generate_series(0,11) i) g
$fn$;

commit;

-- ── 3. the page ─────────────────────────────────────────────────────────────
begin;

create or replace function public.supplier_account_page()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_tabs jsonb; v_kyc jsonb; v_closed jsonb; v_chips jsonb;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  v_kyc := public._sup753_kyc(coalesce(nullif(sp.drug_license,''), sp.dl_1),
                              coalesce(nullif(sp.gstin,''), sp.gst),
                              sp.dl_expiry, sp.gstin_expiry);

  select coalesce(jsonb_agg(jsonb_build_object(
           'key',  t.tab_key,
           'label', public.ui_text(t.copy_key),
           'icon',  coalesce(t.icon_key,''),
           'rpc',   coalesce(nullif(t.rpc,''), 'supplier_account_tab_'||t.tab_key))
         order by t.sort_order, t.tab_key), '[]'::jsonb)
    into v_tabs
    from public.supplier_account_tab t
   where t.is_active
     and (t.feature_key is null or public.supplier_can(t.feature_key,'read'));

  v_chips := jsonb_build_array(v_kyc->'chip');

  -- The shop's own open/closed state rides in the header, so a supplier who
  -- forgot the shop is shut sees it on every tab.
  select jsonb_build_object('show', true,
           'label', case when c.id is null then public._sup850_t('shop_open')
                         else public._sup850_t('shop_closed') end,
           'bg',     case when c.id is null then '#D1FAE5' else '#FEE2E2' end,
           'fg',     case when c.id is null then '#065F46' else '#991B1B' end,
           'border', case when c.id is null then '#A7F3D0' else '#FECACA' end)
    into v_closed
    from (select 1) one
    left join public.supplier_closure c
      on lower(btrim(coalesce(c.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
     and c.reopened_at is null
     and c.starts_at <= now()
     and (c.ends_at is null or c.ends_at > now());

  if v_closed is not null then v_chips := v_chips || jsonb_build_array(v_closed); end if;

  return jsonb_build_object(
    'ok', true,
    'title', coalesce(nullif(btrim(coalesce(sp.supplier_name,'')),''),
                      nullif(btrim(coalesce(sp.contact_name,'')),''),
                      public._sup850_t('title')),
    'subtitle', array_to_string(array_remove(array[
        nullif(btrim(coalesce(sp.supplier_code,'')),''),
        (select z.name from public.zones z where z.id = sp.zone_id),
        nullif(btrim(coalesce(sp.city,'')),'')], null), '  ·  '),
    'chips', v_chips,
    'tabs', v_tabs,
    'default_tab', coalesce(v_tabs->0->>'key',''),
    'back_label',  public._sup850_t('back'),
    'empty_label', public._sup850_t('empty'),
    'more_label',  public._sup850_t('more'));
end $fn$;

commit;

-- ── 4. tab: Profile & KYC ───────────────────────────────────────────────────
begin;

-- One editable field, named and validated here. The screen only carries the
-- string the supplier typed; the whitelist below is the only thing that
-- decides what a supplier may change about their own shop.
create or replace function public.supplier_account_profile_set(p_field text, p_value text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare sp public.supplier_profiles%rowtype; v text := btrim(coalesce(p_value,''));
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  if coalesce(p_field,'') not in
     ('contact_person','phone','whatsapp_no','email','address','city','state','pincode') then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('p_bad_field'));
  end if;

  if p_field in ('phone','whatsapp_no')
     and v <> '' and length(regexp_replace(v,'[^0-9]','','g')) <> 10 then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('p_bad_phone'));
  end if;
  if p_field = 'email' and v <> '' and v !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('p_bad_email'));
  end if;

  execute format('update public.supplier_profiles set %I = $1 where id = $2', p_field)
    using nullif(v,''), sp.id;

  insert into public.supplier_audit_log(supplier_id, action, actor_identity, detail, created_at)
  values (sp.id, 'profile_edited', coalesce(auth.email(), auth.uid()::text),
          jsonb_build_object('field', p_field), now());

  return jsonb_build_object('ok', true, 'message', public._sup850_t('p_saved'));
exception when others then
  return jsonb_build_object('ok', false, 'message', public._sup850_t('p_save_failed'));
end $fn$;

-- Close or reopen the shop for ONE day off the calendar. The supplier's own
-- close/reopen RPCs still own the live "closed now" state; this is the
-- planned-holiday door beside them.
create or replace function public.supplier_account_holiday_set(p_day text, p_on boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare sp public.supplier_profiles%rowtype; v_d date; v_from timestamptz; v_to timestamptz;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;
  v_d := to_date(nullif(btrim(coalesce(p_day,'')),''), 'YYYY-MM-DD');
  if v_d is null then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('h_pick_day'));
  end if;
  v_from := (v_d::text || ' 00:00:00 Asia/Kolkata')::timestamptz;
  v_to   := ((v_d + 1)::text || ' 00:00:00 Asia/Kolkata')::timestamptz;

  if coalesce(p_on,false) then
    insert into public.supplier_closure(supplier_name, starts_at, ends_at, reason, closed_by, created_at)
    values (sp.supplier_name, v_from, v_to, public._sup850_t('h_reason'),
            coalesce(auth.email(), auth.uid()::text), now());
    return jsonb_build_object('ok', true, 'message',
      public.ui_textf('sup_acct.h_closed_on', jsonb_build_object('day', to_char(v_d,'FMDD Mon'))));
  end if;

  update public.supplier_closure
     set reopened_at = now()
   where lower(btrim(coalesce(supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
     and reopened_at is null
     and starts_at < v_to and coalesce(ends_at, starts_at + interval '1 day') > v_from;

  return jsonb_build_object('ok', true, 'message',
    public.ui_textf('sup_acct.h_opened_on', jsonb_build_object('day', to_char(v_d,'FMDD Mon'))));
end $fn$;

create or replace function public.supplier_account_tab_profile(
  p_month text default null, p_day text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_kyc jsonb; v_this date; v_m date; v_sel date;
  v_cells jsonb; v_closed_now boolean; v_docs jsonb; v_actions jsonb;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  v_kyc  := public._sup753_kyc(coalesce(nullif(sp.drug_license,''), sp.dl_1),
                               coalesce(nullif(sp.gstin,''), sp.gst),
                               sp.dl_expiry, sp.gstin_expiry);
  v_this := date_trunc('month',(now() at time zone 'Asia/Kolkata')::date)::date;
  v_m    := coalesce(to_date(nullif(btrim(coalesce(p_month,'')),''),'YYYY-MM'), v_this);
  v_sel  := to_date(nullif(btrim(coalesce(p_day,'')),''),'YYYY-MM-DD');

  select exists (select 1 from public.supplier_closure c
                  where lower(btrim(coalesce(c.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
                    and c.reopened_at is null and c.starts_at <= now()
                    and (c.ends_at is null or c.ends_at > now()))
    into v_closed_now;

  -- The month grid, computed here: leading blanks, day numbers, and which days
  -- the shop is already shut.
  with days as (
    select generate_series(v_m, (v_m + interval '1 month' - interval '1 day')::date, '1 day')::date d
  ),
  blanks as (
    select generate_series(1, extract(isodow from v_m)::int - 1) b
  ),
  cells as (
    select 0 ord, null::date d, ''::text lbl, ''::text val, false shut from blanks
    union all
    select 1, d, to_char(d,'FMDD'), to_char(d,'YYYY-MM-DD'),
           exists (select 1 from public.supplier_closure c
                    where lower(btrim(coalesce(c.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
                      and c.reopened_at is null
                      and c.starts_at < ((d + 1)::text || ' 00:00:00 Asia/Kolkata')::timestamptz
                      and coalesce(c.ends_at, c.starts_at + interval '1 day')
                          > (d::text || ' 00:00:00 Asia/Kolkata')::timestamptz)
      from days
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', lbl, 'value', val, 'has', shut,
           'tone', case when shut then 'danger'
                        when d is not null and d = v_sel then 'brand'
                        else 'neutral' end)
         order by ord, d nulls first), '[]'::jsonb)
    into v_cells from cells;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(d.title,''), d.file_name, d.kind),
           'subtitle', coalesce(public.ist_fmt(d.ready_at,'day_mon_year'), ''),
           'chip', public.status_chip('doc_status', d.status))
         order by d.requested_at desc), '[]'::jsonb)
    into v_docs
    from public.supplier_document d
   where d.supplier_id = sp.id;

  v_actions := jsonb_build_array(
    jsonb_build_object('label', public._sup850_t('p_e_person'), 'tone','brand',
      'kind','rpc','rpc','supplier_account_profile_set',
      'args', jsonb_build_object('p_field','contact_person'),
      'prompt', jsonb_build_object('arg','p_value','title',public._sup850_t('p_e_person'),
        'hint', coalesce(nullif(sp.contact_person,''), sp.contact_name, ''),
        'ok', public._sup850_t('save'), 'cancel', public._sup850_t('cancel'))),
    jsonb_build_object('label', public._sup850_t('p_e_phone'), 'tone','brand',
      'kind','rpc','rpc','supplier_account_profile_set',
      'args', jsonb_build_object('p_field','phone'),
      'prompt', jsonb_build_object('arg','p_value','title',public._sup850_t('p_e_phone'),
        'hint', coalesce(nullif(sp.phone,''), sp.contact_no, ''),
        'ok', public._sup850_t('save'), 'cancel', public._sup850_t('cancel'))),
    jsonb_build_object('label', public._sup850_t('p_e_wa'), 'tone','brand',
      'kind','rpc','rpc','supplier_account_profile_set',
      'args', jsonb_build_object('p_field','whatsapp_no'),
      'prompt', jsonb_build_object('arg','p_value','title',public._sup850_t('p_e_wa'),
        'hint', coalesce(sp.whatsapp_no,''),
        'ok', public._sup850_t('save'), 'cancel', public._sup850_t('cancel'))),
    jsonb_build_object('label', public._sup850_t('p_e_email'), 'tone','brand',
      'kind','rpc','rpc','supplier_account_profile_set',
      'args', jsonb_build_object('p_field','email'),
      'prompt', jsonb_build_object('arg','p_value','title',public._sup850_t('p_e_email'),
        'hint', coalesce(sp.email,''),
        'ok', public._sup850_t('save'), 'cancel', public._sup850_t('cancel'))),
    jsonb_build_object('label', public._sup850_t('p_e_address'), 'tone','brand',
      'kind','rpc','rpc','supplier_account_profile_set',
      'args', jsonb_build_object('p_field','address'),
      'prompt', jsonb_build_object('arg','p_value','title',public._sup850_t('p_e_address'),
        'hint', coalesce(nullif(sp.address,''), sp.street_address, ''),
        'ok', public._sup850_t('save'), 'cancel', public._sup850_t('cancel'))),
    jsonb_build_object('label', public._sup850_t('p_e_city'), 'tone','brand',
      'kind','rpc','rpc','supplier_account_profile_set',
      'args', jsonb_build_object('p_field','city'),
      'prompt', jsonb_build_object('arg','p_value','title',public._sup850_t('p_e_city'),
        'hint', coalesce(sp.city,''),
        'ok', public._sup850_t('save'), 'cancel', public._sup850_t('cancel'))));

  return jsonb_build_object('ok', true, 'month', to_char(v_m,'YYYY-MM'),
    'blocks', jsonb_build_array(
    jsonb_build_object('kind','kv','title',public._sup850_t('p_business'),'rows',jsonb_build_array(
      public._sup850_kv(public._sup850_t('f_name'), sp.supplier_name),
      public._sup850_kv(public._sup850_t('f_code'), sp.supplier_code),
      public._sup850_kv(public._sup850_t('f_zone'),
        (select z.name from public.zones z where z.id = sp.zone_id)),
      public._sup850_kv(public._sup850_t('f_type'),
        coalesce(nullif(sp.stockist_type,''), sp.store_type)),
      public._sup850_kv(public._sup850_t('f_status'), sp.status),
      public._sup850_kv(public._sup850_t('f_since'),
        public.ist_fmt(coalesce(sp.approved_at, sp.created_at),'day_mon_year')))),
    jsonb_build_object('kind','kv','title',public._sup850_t('p_contact'),'rows',jsonb_build_array(
      public._sup850_kv(public._sup850_t('f_person'),
        coalesce(nullif(sp.contact_person,''), sp.contact_name)),
      public._sup850_kv(public._sup850_t('f_phone'),
        coalesce(nullif(sp.phone,''), sp.contact_no)),
      public._sup850_kv(public._sup850_t('f_whatsapp'), sp.whatsapp_no),
      public._sup850_kv(public._sup850_t('f_email'), sp.email),
      public._sup850_kv(public._sup850_t('f_address'),
        coalesce(nullif(sp.address,''), sp.street_address)),
      public._sup850_kv(public._sup850_t('f_city'),
        array_to_string(array_remove(array[nullif(btrim(coalesce(sp.city,'')),''),
                                           nullif(btrim(coalesce(sp.state,'')),'')], null), ', ')))),
    jsonb_build_object('kind','actions','title',public._sup850_t('p_edit_title'),
      'note', public._sup850_t('p_edit_note'), 'items', v_actions),
    jsonb_build_object('kind','kv','title',public._sup850_t('p_kyc'),
      'chip', v_kyc->'chip', 'rows', jsonb_build_array(
      public._sup850_kv(public._sup850_t('f_dl'),
        coalesce(nullif(sp.drug_license,''), sp.dl_1)),
      public._sup850_kv(public._sup850_t('f_dl_exp'),
        case when sp.dl_expiry is null then '' else to_char(sp.dl_expiry,'FMDD Mon YYYY') end),
      public._sup850_kv(public._sup850_t('f_gst'),
        coalesce(nullif(sp.gstin,''), sp.gst)),
      public._sup850_kv(public._sup850_t('f_gst_exp'),
        case when sp.gstin_expiry is null then '' else to_char(sp.gstin_expiry,'FMDD Mon YYYY') end))),
    jsonb_build_object('kind','embed','widget','kyc_panel'),
    jsonb_build_object('kind','list','title',public._sup850_t('p_docs'),
      'empty', public._sup850_t('p_docs_empty'), 'items', v_docs),
    jsonb_build_object('kind','chips','key','month','arg','p_month',
      'title', public._sup850_t('h_month'), 'chips', public._sup850_months(v_m)),
    jsonb_build_object('kind','calendar','title',public._sup850_t('p_cal'),
      'month_label', to_char(v_m,'FMMonth YYYY'),
      'weekdays', jsonb_build_array(
        public._sup850_t('wd_mon'), public._sup850_t('wd_tue'), public._sup850_t('wd_wed'),
        public._sup850_t('wd_thu'), public._sup850_t('wd_fri'), public._sup850_t('wd_sat'),
        public._sup850_t('wd_sun')),
      'day_arg','p_day', 'cells', v_cells, 'empty', public._sup850_t('p_cal_empty')),
    jsonb_build_object('kind','actions','title',public._sup850_t('p_shop'),
      'note', case when v_sel is null then public._sup850_t('p_shop_note')
                   else public.ui_textf('sup_acct.p_shop_picked',
                          jsonb_build_object('day', to_char(v_sel,'FMDD Mon YYYY'))) end,
      'value', case when v_closed_now then public._sup850_t('shop_closed')
                    else public._sup850_t('shop_open') end,
      'items', jsonb_build_array(
        jsonb_build_object('label', public._sup850_t('p_close_day'), 'tone','danger',
          'enabled', (v_sel is not null), 'kind','rpc',
          'rpc','supplier_account_holiday_set',
          'args', jsonb_build_object('p_day', coalesce(to_char(v_sel,'YYYY-MM-DD'),''), 'p_on', true)),
        jsonb_build_object('label', public._sup850_t('p_open_day'), 'tone','success',
          'enabled', (v_sel is not null), 'kind','rpc',
          'rpc','supplier_account_holiday_set',
          'args', jsonb_build_object('p_day', coalesce(to_char(v_sel,'YYYY-MM-DD'),''), 'p_on', false)),
        jsonb_build_object('label', public._sup850_t('p_reopen_now'), 'tone','brand',
          'enabled', v_closed_now, 'kind','rpc',
          'rpc','supplier_reopen_shop', 'args', '{}'::jsonb)))));
end $fn$;

commit;

-- ── 5. tab: Companies I stock ───────────────────────────────────────────────
begin;

create or replace function public.supplier_account_company_request(p_company text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare sp public.supplier_profiles%rowtype; v text := btrim(coalesce(p_company,''));
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;
  if v = '' then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('c_req_empty'));
  end if;
  if exists (select 1 from public.supplier_pending_companies q
              where q.supplier_id = sp.id
                and lower(btrim(q.company_name)) = lower(v)
                and coalesce(q.status,'pending') = 'pending') then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('c_req_dupe'));
  end if;

  insert into public.supplier_pending_companies(supplier_id, company_name, status, created_at)
  values (sp.id, v, 'pending', now());

  return jsonb_build_object('ok', true,
    'message', public.ui_textf('sup_acct.c_req_sent', jsonb_build_object('name', v)));
end $fn$;

create or replace function public.supplier_account_tab_companies(p_filter text default 'all')
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_f text := lower(coalesce(nullif(btrim(coalesce(p_filter,'')),''),'all'));
  v_rows jsonb; v_pending jsonb;
  v_all int; v_matched int; v_unmatched int;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  select count(*),
         count(*) filter (where coalesce(array_length(public._sup753_mapped(sc.id),1),0) > 0),
         count(*) filter (where coalesce(array_length(public._sup753_mapped(sc.id),1),0) = 0)
    into v_all, v_matched, v_unmatched
    from public.supplier_company sc where sc.supplier_id = sp.id;

  select coalesce(jsonb_agg(x.row order by x.name), '[]'::jsonb) into v_rows
    from (
      select lower(btrim(coalesce(sc.supplier_company,''))) name,
             jsonb_build_object(
               'title', coalesce(nullif(btrim(coalesce(sc.supplier_company,'')),''), '—'),
               'subtitle', case
                 when coalesce(array_length(public._sup753_mapped(sc.id),1),0) = 0 then ''
                 else array_to_string(public._sup753_mapped(sc.id), ', ') end,
               'meta', case when sc.matched_at is null then ''
                            else public._sup850_t('c_matched_on')||': '||
                                 public.ist_fmt(sc.matched_at,'day_mon_year') end,
               'chip', case when coalesce(array_length(public._sup753_mapped(sc.id),1),0) > 0
                 then jsonb_build_object('show',true,'label',public._sup850_t('c_matched'),
                        'bg','#D1FAE5','fg','#065F46','border','#A7F3D0')
                 else jsonb_build_object('show',true,'label',public._sup850_t('c_unmatched'),
                        'bg','#FEF3C7','fg','#92400E','border','#FDE68A') end) row
        from public.supplier_company sc
       where sc.supplier_id = sp.id
         and (v_f = 'all'
              or (v_f = 'matched'   and coalesce(array_length(public._sup753_mapped(sc.id),1),0) > 0)
              or (v_f = 'unmatched' and coalesce(array_length(public._sup753_mapped(sc.id),1),0) = 0))
    ) x;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', q.company_name,
           'subtitle', coalesce(nullif(q.reject_reason,''),''),
           'meta', public.ist_fmt(q.created_at,'day_mon_year'),
           'chip', public.status_chip('pending_company_status', coalesce(q.status,'pending')))
         order by q.created_at desc), '[]'::jsonb)
    into v_pending
    from public.supplier_pending_companies q
   where q.supplier_id = sp.id;

  return jsonb_build_object('ok', true, 'filter', v_f, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','tiles', jsonb_build_array(
      jsonb_build_object('label',public._sup850_t('c_total'),    'value',v_all::text,      'tone','neutral'),
      jsonb_build_object('label',public._sup850_t('c_matched'),  'value',v_matched::text,  'tone','success'),
      jsonb_build_object('label',public._sup850_t('c_unmatched'),'value',v_unmatched::text,
        'tone', case when v_unmatched > 0 then 'warning' else 'neutral' end))),
    jsonb_build_object('kind','chips','key','filter','arg','p_filter','chips', jsonb_build_array(
      jsonb_build_object('key','all',      'value','all',      'label',public._sup850_t('c_f_all'),      'count',v_all,      'active',v_f='all'),
      jsonb_build_object('key','matched',  'value','matched',  'label',public._sup850_t('c_f_matched'),  'count',v_matched,  'active',v_f='matched'),
      jsonb_build_object('key','unmatched','value','unmatched','label',public._sup850_t('c_f_unmatched'),'count',v_unmatched,'active',v_f='unmatched'))),
    jsonb_build_object('kind','actions','title',public._sup850_t('c_req_title'),
      'note', public._sup850_t('c_req_note'), 'items', jsonb_build_array(
      jsonb_build_object('label', public._sup850_t('c_req_btn'), 'tone','brand','kind','rpc',
        'rpc','supplier_account_company_request', 'args','{}'::jsonb,
        'prompt', jsonb_build_object('arg','p_company',
          'title', public._sup850_t('c_req_title'),
          'hint',  public._sup850_t('c_req_hint'),
          'ok',    public._sup850_t('c_req_btn'),
          'cancel',public._sup850_t('cancel'))))),
    jsonb_build_object('kind','list','title',public._sup850_t('c_list_title'),
      'empty', public._sup850_t('c_list_empty'), 'items', v_rows),
    jsonb_build_object('kind','list','title',public._sup850_t('c_pending_title'),
      'empty', public._sup850_t('c_pending_empty'), 'items', v_pending)));
end $fn$;

commit;

-- ── 6. tab: Orders ──────────────────────────────────────────────────────────
begin;

create or replace function public.supplier_account_tab_orders(
  p_status text default 'all', p_limit integer default 25)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_f text := lower(coalesce(nullif(btrim(coalesce(p_status,'')),''),'all'));
  v_lim int := least(greatest(coalesce(p_limit,25),1),200);
  v_copy jsonb; v_items jsonb; v_total int; v_amt numeric;
  v_c_all int; v_c_open int; v_c_packed int; v_c_settled int; v_c_cancelled int;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  v_copy := jsonb_build_object('one', public._sup850_t('o_items_one'),
                               'many', public._sup850_t('o_items_many'));

  select count(*),
         count(*) filter (where so.settled_at is null and not coalesce(so.packed,false)
                            and lower(coalesce(so.status,'')) <> 'cancelled'),
         count(*) filter (where coalesce(so.packed,false)),
         count(*) filter (where so.settled_at is not null),
         count(*) filter (where lower(coalesce(so.status,'')) = 'cancelled')
    into v_c_all, v_c_open, v_c_packed, v_c_settled, v_c_cancelled
    from public.supplier_orders so where so.supplier_id = sp.id;

  with f as (
    select so.* from public.supplier_orders so
     where so.supplier_id = sp.id
       and (v_f = 'all'
            or (v_f = 'open'      and so.settled_at is null and not coalesce(so.packed,false)
                                  and lower(coalesce(so.status,'')) <> 'cancelled')
            or (v_f = 'packed'    and coalesce(so.packed,false))
            or (v_f = 'settled'   and so.settled_at is not null)
            or (v_f = 'cancelled' and lower(coalesce(so.status,'')) = 'cancelled'))
  ),
  page as (select * from f order by created_at desc limit v_lim)
  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(p.order_code,''), '#'||coalesce(p.order_no,0)::text),
           'subtitle', public.count_label(v_copy,'one','many',coalesce(jsonb_array_length(p.items),0)),
           'meta', public.ist_fmt(coalesce(p.created_at, p.order_date::timestamptz),'day_mon_year'),
           'trailing', public.inr_money(coalesce(p.total_amount,0)),
           'chip', public.status_chip('supplier_status', p.status),
           'actions', jsonb_build_array(
             jsonb_build_object('label', public._sup850_t('o_pdf'), 'tone','brand',
               'kind','doc', 'rpc','supplier_account_doc',
               'args', jsonb_build_object('p_kind','purchase_order','p_ref', p.id::text),
               'poll_rpc','supplier_account_doc_status', 'poll_arg','p_id')))
         order by p.created_at desc), '[]'::jsonb)
    into v_items from page p;

  select count(*), coalesce(sum(coalesce(so.total_amount,0)),0)
    into v_total, v_amt
    from public.supplier_orders so
   where so.supplier_id = sp.id
     and (v_f = 'all'
          or (v_f = 'open'      and so.settled_at is null and not coalesce(so.packed,false)
                                and lower(coalesce(so.status,'')) <> 'cancelled')
          or (v_f = 'packed'    and coalesce(so.packed,false))
          or (v_f = 'settled'   and so.settled_at is not null)
          or (v_f = 'cancelled' and lower(coalesce(so.status,'')) = 'cancelled'));

  return jsonb_build_object('ok', true, 'filter', v_f, 'limit', v_lim,
    'has_more', (v_lim < v_total), 'more_label', public._sup850_t('more'),
    'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','tiles', jsonb_build_array(
      jsonb_build_object('label',public._sup850_t('o_orders'),'value',v_total::text,'tone','neutral'),
      jsonb_build_object('label',public._sup850_t('o_value'), 'value',public.inr_money(v_amt),'tone','info'))),
    jsonb_build_object('kind','chips','key','status','arg','p_status','chips', jsonb_build_array(
      jsonb_build_object('key','all',      'value','all',      'label',public._sup850_t('o_all'),      'count',v_c_all,      'active',v_f='all'),
      jsonb_build_object('key','open',     'value','open',     'label',public._sup850_t('o_open'),     'count',v_c_open,     'active',v_f='open'),
      jsonb_build_object('key','packed',   'value','packed',   'label',public._sup850_t('o_packed'),   'count',v_c_packed,   'active',v_f='packed'),
      jsonb_build_object('key','settled',  'value','settled',  'label',public._sup850_t('o_settled'),  'count',v_c_settled,  'active',v_f='settled'),
      jsonb_build_object('key','cancelled','value','cancelled','label',public._sup850_t('o_cancelled'),'count',v_c_cancelled,'active',v_f='cancelled'))),
    jsonb_build_object('kind','list','title',public._sup850_t('o_title'),
      'empty', public._sup850_t('o_empty'), 'items', v_items)));
end $fn$;

commit;

-- ── 7. documents: one door, one poll ────────────────────────────────────────
begin;

-- supplier_doc_request answers with doc_id; MyAccountScreen polls whatever the
-- payload called `statement_id`. Rather than teach the screen a second name,
-- the backend answers with both.
create or replace function public.supplier_account_doc(p_kind text, p_ref text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r jsonb;
begin
  r := public.supplier_doc_request(p_kind, p_ref);
  if coalesce(r->>'doc_id','') <> '' then
    r := r || jsonb_build_object('statement_id', r->>'doc_id');
  end if;
  return r;
end $fn$;

create or replace function public.supplier_account_doc_status(p_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r jsonb;
begin
  r := public.supplier_doc_status(p_id);
  if coalesce(r->>'doc_id','') <> '' then
    r := r || jsonb_build_object('statement_id', r->>'doc_id');
  end if;
  return r;
end $fn$;

commit;

-- ── 8. tab: Payments & Bills ────────────────────────────────────────────────
begin;

create or replace function public.supplier_account_tab_payments(p_limit integer default 25)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_lim int := least(greatest(coalesce(p_limit,25),1),200);
  v_billed numeric; v_paid numeric; v_pending numeric; v_debit numeric;
  v_bills jsonb; v_pays jsonb; v_n int;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  select coalesce(sum(coalesce(so.total_amount,0)),0) into v_billed
    from public.supplier_orders so
   where so.supplier_id = sp.id and lower(coalesce(so.status,'')) <> 'cancelled';

  select coalesce(sum(coalesce(pm.amount,0)),0) into v_paid
    from public.supplier_payments pm
    join public.supplier_orders so on so.id = pm.supplier_order_id
   where so.supplier_id = sp.id;

  select coalesce(sum(greatest(coalesce(so.total_amount,0) - coalesce(p.amt,0),0)),0)
    into v_pending
    from public.supplier_orders so
    left join (select supplier_order_id, sum(coalesce(amount,0)) amt
                 from public.supplier_payments group by 1) p on p.supplier_order_id = so.id
   where so.supplier_id = sp.id and so.settled_at is null
     and lower(coalesce(so.status,'')) <> 'cancelled';

  select coalesce(sum(coalesce(d.adj_amount,0)),0) into v_debit
    from public.supplier_disputes d
   where lower(btrim(coalesce(d.assigned_supplier,''))) = lower(btrim(coalesce(sp.supplier_name,'')));

  select coalesce(jsonb_agg(b.row order by b.at desc), '[]'::jsonb), count(*)
    into v_bills, v_n
    from (select coalesce(pb.received_at, pb.created_at) at,
                 jsonb_build_object(
                   'title', coalesce(nullif(pb.file_name,''), public._sup850_t('y_unbilled')),
                   'subtitle', coalesce(public.ist_fmt(coalesce(pb.received_at, pb.created_at),'day_mon_year'),''),
                   'chip', public.status_chip('bill_status', coalesce(pb.status,''))) row
            from public.pending_bills pb
           where lower(btrim(coalesce(pb.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
           order by coalesce(pb.received_at, pb.created_at) desc
           limit v_lim) b;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', public.inr_money(coalesce(pm.amount,0)),
           'subtitle', array_to_string(array_remove(array[
               nullif(btrim(coalesce(pm.mode,'')),''),
               nullif(btrim(coalesce(pm.utr,'')),'')], null), '  ·  '),
           'meta', coalesce(public.ist_fmt(pm.created_at,'day_mon_year'),''),
           'trailing', coalesce(so.order_code,''))
         order by pm.created_at desc), '[]'::jsonb)
    into v_pays
    from public.supplier_payments pm
    join public.supplier_orders so on so.id = pm.supplier_order_id
   where so.supplier_id = sp.id;

  return jsonb_build_object('ok', true, 'limit', v_lim, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','tiles', jsonb_build_array(
      jsonb_build_object('label',public._sup850_t('y_billed'), 'value',public.inr_money(v_billed),'tone','neutral'),
      jsonb_build_object('label',public._sup850_t('y_paid'),   'value',public.inr_money(v_paid),  'tone','success'),
      jsonb_build_object('label',public._sup850_t('y_pending'),'value',public.inr_money(v_pending),
                         'tone', case when v_pending > 0 then 'warning' else 'neutral' end),
      jsonb_build_object('label',public._sup850_t('y_debits'), 'value',public.inr_money(v_debit),
                         'tone', case when v_debit > 0 then 'danger' else 'neutral' end))),
    jsonb_build_object('kind','nav','title',public._sup850_t('y_payout_title'),
      'items', jsonb_build_array(
        jsonb_build_object('route','payout','label',public._sup850_t('y_payout'),
                           'caption',public._sup850_t('y_payout_cap')))),
    jsonb_build_object('kind','list','title',public._sup850_t('y_bills'),
      'empty', public._sup850_t('y_bills_empty'), 'items', v_bills),
    jsonb_build_object('kind','list','title',public._sup850_t('y_pay_title'),
      'empty', public._sup850_t('y_pay_empty'), 'items', v_pays)));
end $fn$;

commit;

-- ── 9. tab: Returns & Debits (#710) ─────────────────────────────────────────
begin;

-- A supplier who disagrees with a debit note says so here. It is recorded
-- against the return in the audit trail admin already reads; nothing about the
-- return's money moves until admin acts on it.
create or replace function public.supplier_account_return_dispute(p_id uuid, p_note text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare sp public.supplier_profiles%rowtype; r public.supplier_return%rowtype;
        v text := btrim(coalesce(p_note,''));
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;
  select * into r from public.supplier_return where id = p_id and supplier_id = sp.id;
  if r.id is null then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('r_not_found'));
  end if;
  if v = '' then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('r_note_empty'));
  end if;

  insert into public.supplier_audit_log(supplier_id, action, actor_identity, detail, created_at)
  values (sp.id, 'return_disputed', coalesce(auth.email(), auth.uid()::text),
          jsonb_build_object('return_id', r.id, 'debit_no', coalesce(r.debit_no,''), 'note', v),
          now());

  return jsonb_build_object('ok', true, 'message', public._sup850_t('r_note_sent'));
end $fn$;

create or replace function public.supplier_account_tab_returns(p_limit integer default 25)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_lim int := least(greatest(coalesce(p_limit,25),1),200);
  v_rows jsonb; v_debits jsonb; v_open numeric; v_count int;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  select count(*), coalesce(sum(coalesce(r.grand_total,0)),0)
    into v_count, v_open
    from public.supplier_return r
   where r.supplier_id = sp.id and r.status <> 'drafted';

  select coalesce(jsonb_agg(x.row order by x.at desc), '[]'::jsonb) into v_rows
    from (select r.created_at at, jsonb_build_object(
            'title', coalesce(nullif(r.debit_no,''), public._sup850_t('r_untitled')),
            'subtitle', public.ui_textf('sup_acct.r_lines',
                          jsonb_build_object('n', coalesce(r.item_count,0)::text)),
            'meta', coalesce(public.ist_fmt(r.created_at,'day_mon_year'),''),
            'trailing', public.inr_money(coalesce(r.grand_total,0)),
            'trailing_tone', 'danger',
            'chip', public.status_chip('supplier_return_status', coalesce(r.status,'')),
            'actions',
              (case when r.acknowledged_at is null then jsonb_build_array(
                 jsonb_build_object('label', public._sup850_t('r_ack'), 'tone','success',
                   'kind','rpc','rpc','supplier_return_ack',
                   'args', jsonb_build_object('p_id', r.id, 'p_note','')))
               else '[]'::jsonb end)
              || jsonb_build_array(
                 jsonb_build_object('label', public._sup850_t('r_dispute'), 'tone','warning',
                   'kind','rpc','rpc','supplier_account_return_dispute',
                   'args', jsonb_build_object('p_id', r.id),
                   'prompt', jsonb_build_object('arg','p_note',
                     'title', public._sup850_t('r_dispute'),
                     'hint',  public._sup850_t('r_dispute_hint'),
                     'ok',    public._sup850_t('send'),
                     'cancel',public._sup850_t('cancel'))),
                 jsonb_build_object('label', public._sup850_t('r_note_pdf'), 'tone','brand',
                   'kind','doc','rpc','supplier_account_doc',
                   'args', jsonb_build_object('p_kind','debit_note','p_ref', r.id::text),
                   'poll_rpc','supplier_account_doc_status','poll_arg','p_id'))) row
            from public.supplier_return r
           where r.supplier_id = sp.id and r.status <> 'drafted'
           order by r.created_at desc limit v_lim) x;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(d.product_name,''), d.dispute_code, '—'),
           'subtitle', coalesce(nullif(d.kind,''),''),
           'meta', coalesce(public.ist_fmt(d.created_at,'day_mon_year'),''),
           'trailing', public.inr_money(coalesce(d.adj_amount,0)),
           'trailing_tone', 'danger',
           'chip', public.status_chip('dispute_status', coalesce(d.status,'')))
         order by d.created_at desc), '[]'::jsonb)
    into v_debits
    from public.supplier_disputes d
   where lower(btrim(coalesce(d.assigned_supplier,''))) = lower(btrim(coalesce(sp.supplier_name,'')));

  return jsonb_build_object('ok', true, 'limit', v_lim, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','tiles', jsonb_build_array(
      jsonb_build_object('label',public._sup850_t('r_count'),'value',v_count::text,'tone','neutral'),
      jsonb_build_object('label',public._sup850_t('r_value'),'value',public.inr_money(v_open),
                         'tone', case when v_open > 0 then 'danger' else 'neutral' end))),
    jsonb_build_object('kind','list','title',public._sup850_t('r_title'),
      'empty', public._sup850_t('r_empty'), 'items', v_rows),
    jsonb_build_object('kind','list','title',public._sup850_t('r_debits'),
      'empty', public._sup850_t('r_debits_empty'), 'items', v_debits)));
end $fn$;

commit;

-- ── 10. tab: Performance (with the SPN breakdown) ───────────────────────────
begin;

create or replace function public.supplier_account_tab_performance()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_this date := date_trunc('month',(now() at time zone 'Asia/Kolkata')::date)::date;
  v_now jsonb; v_trend jsonb; v_factors jsonb; v_tips jsonb;
  v_rank int; v_ret_ok boolean;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  v_now := public._sup753_metrics(sp.id, v_this);
  insert into public.supplier_perf_monthly (supplier_id, month, metrics, computed_at)
  values (sp.id, v_this, v_now, now())
  on conflict (supplier_id, month) do update
    set metrics = excluded.metrics, computed_at = now();

  v_ret_ok := coalesce((v_now->>'returns_available')::boolean, false);

  select r into v_rank from (
    select x.id, rank() over (order by coalesce(x."SPN",0) desc, lower(x.supplier_name)) r
      from public.supplier_profiles x
     where coalesce(x.is_deleted,false) = false
       and x.zone_id is not distinct from sp.zone_id) q(id, r)
   where q.id = sp.id;

  select coalesce(jsonb_agg(jsonb_build_array(
           jsonb_build_object('text', to_char(m.month,'Mon YY'), 'align','left'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'response_rate')::numeric), 'align','right'),
           jsonb_build_object('text', case when m.metrics->>'median_response_s' is null
                                           then public._sup850_t('pf_na')
                                           else public.fmt_duration_short((m.metrics->>'median_response_s')::int) end,
                              'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'fill_rate')::numeric), 'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'short_rate')::numeric), 'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'dispute_rate')::numeric), 'align','right'),
           jsonb_build_object('text', public._sup753_pct((m.metrics->>'on_time_rate')::numeric), 'align','right'))
         order by m.month desc), '[]'::jsonb)
    into v_trend
    from public.supplier_perf_monthly m
   where m.supplier_id = sp.id
     and m.month > (v_this - interval '12 months')::date;

  -- The four factors the SPN is made of, read-only: the supplier sees what he
  -- is graded on and what each grade is worth. Only admin may change them.
  v_factors := jsonb_build_array(
    jsonb_build_array(
      jsonb_build_object('text', public._sup850_t('spn_f_margin'), 'align','left'),
      jsonb_build_object('text', coalesce(nullif(btrim(coalesce(sp.margin,'')),''),
                                          public._sup850_t('not_set')), 'align','left'),
      jsonb_build_object('text', coalesce(sp.margin_points,0)::text, 'align','right')),
    jsonb_build_array(
      jsonb_build_object('text', public._sup850_t('spn_f_cd'), 'align','left'),
      jsonb_build_object('text', coalesce(nullif(btrim(coalesce(sp.cd_condition,'')),''),
                                          public._sup850_t('not_set')), 'align','left'),
      jsonb_build_object('text', coalesce(sp.cd_points,0)::text, 'align','right')),
    jsonb_build_array(
      jsonb_build_object('text', public._sup850_t('spn_f_behaviour'), 'align','left'),
      jsonb_build_object('text', coalesce(nullif(btrim(coalesce(sp.behaviour,'')),''),
                                          public._sup850_t('not_set')), 'align','left'),
      jsonb_build_object('text', coalesce(sp.behaviour_points,0)::text, 'align','right')),
    jsonb_build_array(
      jsonb_build_object('text', public._sup850_t('spn_f_payment'), 'align','left'),
      jsonb_build_object('text', coalesce(nullif(btrim(coalesce(sp.payment_term,'')),''),
                                          public._sup850_t('not_set')), 'align','left'),
      jsonb_build_object('text', coalesce(sp.payment_points,0)::text, 'align','right')));

  -- "What moves it" — every option the grader can pick, and its points. These
  -- are spn_options rows verbatim; nothing is invented here.
  select coalesce(jsonb_agg(jsonb_build_object(
           'title', o.label,
           'subtitle', case o.field
                         when 'margin'       then public._sup850_t('spn_f_margin')
                         when 'cd_condition' then public._sup850_t('spn_f_cd')
                         when 'behaviour'    then public._sup850_t('spn_f_behaviour')
                         when 'payment_term' then public._sup850_t('spn_f_payment')
                         else o.field end,
           'trailing', public.ui_textf('sup_acct.spn_pts',
                         jsonb_build_object('n', o.points::text)),
           'trailing_tone', case when o.points > 0 then 'success' else 'muted' end)
         order by o.field, o.points desc), '[]'::jsonb)
    into v_tips
    from public.spn_options o;

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','tiles','title',public._sup850_t('pf_window'),'tiles', jsonb_build_array(
      jsonb_build_object('label',public._sup850_t('pf_spn'),
        'value', to_char(coalesce(sp."SPN",0),'FM999,999,999'), 'tone','brand'),
      jsonb_build_object('label',public._sup850_t('pf_rank'),
        'value', public.ui_textf('sup_acct.pf_rank_value',
                   jsonb_build_object('n', coalesce(v_rank,0)::text)), 'tone','info'),
      jsonb_build_object('label',public._sup850_t('pf_resp'),
        'value',public._sup753_pct((v_now->>'response_rate')::numeric),'tone','info'),
      jsonb_build_object('label',public._sup850_t('pf_median'),
        'value', case when v_now->>'median_response_s' is null then public._sup850_t('pf_na')
                      else public.fmt_duration_short((v_now->>'median_response_s')::int) end,'tone','neutral'),
      jsonb_build_object('label',public._sup850_t('pf_fill'),
        'value',public._sup753_pct((v_now->>'fill_rate')::numeric),'tone','success'),
      jsonb_build_object('label',public._sup850_t('pf_short'),
        'value',public._sup753_pct((v_now->>'short_rate')::numeric),'tone','warning'),
      jsonb_build_object('label',public._sup850_t('pf_disp'),
        'value',public._sup753_pct((v_now->>'dispute_rate')::numeric),'tone','warning'),
      jsonb_build_object('label',public._sup850_t('pf_ontime'),
        'value',public._sup753_pct((v_now->>'on_time_rate')::numeric),'tone','info'),
      jsonb_build_object('label',public._sup850_t('pf_returns'),
        'value', case when v_ret_ok then public._sup753_pct((v_now->>'returns_rate')::numeric)
                      else public._sup850_t('pf_no_returns') end,
        'tone', case when v_ret_ok then 'neutral' else 'muted' end))),
    jsonb_build_object('kind','table','title',public._sup850_t('spn_title'),
      'columns', jsonb_build_array(
        jsonb_build_object('label',public._sup850_t('spn_c_factor'),'align','left'),
        jsonb_build_object('label',public._sup850_t('spn_c_value'), 'align','left'),
        jsonb_build_object('label',public._sup850_t('spn_c_points'),'align','right')),
      'rows', v_factors),
    jsonb_build_object('kind','list','title',public._sup850_t('spn_moves'),
      'empty', public._sup850_t('spn_moves_empty'), 'items', v_tips),
    jsonb_build_object('kind','table','title',public._sup850_t('pf_trend'),
      'columns', jsonb_build_array(
        jsonb_build_object('label',public._sup850_t('pf_month'), 'align','left'),
        jsonb_build_object('label',public._sup850_t('pf_resp'),  'align','right'),
        jsonb_build_object('label',public._sup850_t('pf_median'),'align','right'),
        jsonb_build_object('label',public._sup850_t('pf_fill'),  'align','right'),
        jsonb_build_object('label',public._sup850_t('pf_short'), 'align','right'),
        jsonb_build_object('label',public._sup850_t('pf_disp'),  'align','right'),
        jsonb_build_object('label',public._sup850_t('pf_ontime'),'align','right')),
      'rows', v_trend)));
end $fn$;

commit;

-- ── 11. tab: History ────────────────────────────────────────────────────────
begin;

create or replace function public.supplier_account_tab_history(
  p_month text default null, p_limit integer default 200)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_this date := date_trunc('month',(now() at time zone 'Asia/Kolkata')::date)::date;
  v_m date; v_from timestamptz; v_to timestamptz;
  v_lim int := least(greatest(coalesce(p_limit,200),1),500);
  v_items jsonb;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  v_m := coalesce(to_date(nullif(btrim(coalesce(p_month,'')),''),'YYYY-MM'), v_this);
  v_from := (v_m::text || ' 00:00:00 Asia/Kolkata')::timestamptz;
  v_to   := ((v_m + interval '1 month')::date::text || ' 00:00:00 Asia/Kolkata')::timestamptz;

  with ev as (
    select l.asked_at as at, public._sup850_t('h_inq_asked') as title,
           coalesce(i.product_name,'') as subtitle, 'info' as tone
      from public.supplier_response_log l
      left join public.inquiry i on i.id = l.inquiry_id
     where lower(btrim(coalesce(l.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
       and l.kind = 'inquiry_asked' and l.asked_at >= v_from and l.asked_at < v_to
    union all
    select l.responded_at, public._sup850_t('h_inq_ans'), coalesce(l.outcome,''), 'success'
      from public.supplier_response_log l
     where lower(btrim(coalesce(l.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
       and l.responded_at is not null and l.responded_at >= v_from and l.responded_at < v_to
    union all
    select so.created_at, public._sup850_t('h_order'),
           coalesce(so.order_code,'')||'  ·  '||public.inr_money(coalesce(so.total_amount,0)), 'neutral'
      from public.supplier_orders so
     where so.supplier_id = sp.id and so.created_at >= v_from and so.created_at < v_to
    union all
    select d.created_at,
           case when coalesce(d.adj_amount,0) > 0 then public._sup850_t('h_debit')
                else public._sup850_t('h_dispute') end,
           coalesce(d.product_name,''), 'danger'
      from public.supplier_disputes d
     where lower(btrim(coalesce(d.assigned_supplier,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
       and d.created_at >= v_from and d.created_at < v_to
    union all
    select b.received_at, public._sup850_t('h_bill'), coalesce(b.file_name,''), 'neutral'
      from public.pending_bills b
     where lower(btrim(coalesce(b.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
       and b.received_at >= v_from and b.received_at < v_to
    union all
    select pm.created_at, public._sup850_t('h_payment'),
           public.inr_money(coalesce(pm.amount,0))||'  ·  '||coalesce(pm.mode,''), 'success'
      from public.supplier_payments pm
      join public.supplier_orders so on so.id = pm.supplier_order_id
     where so.supplier_id = sp.id and pm.created_at >= v_from and pm.created_at < v_to
    union all
    select r.created_at, public._sup850_t('h_return'),
           coalesce(nullif(r.debit_no,''),'')||'  ·  '||public.inr_money(coalesce(r.grand_total,0)), 'warning'
      from public.supplier_return r
     where r.supplier_id = sp.id and r.status <> 'drafted'
       and r.created_at >= v_from and r.created_at < v_to
    union all
    select a.created_at,
           case a.action when 'spn_changed'     then public._sup850_t('h_spn')
                         when 'profile_edited'  then public._sup850_t('h_profile')
                         when 'return_disputed' then public._sup850_t('h_objection')
                         else public._sup850_t('h_avail') end,
           coalesce(a.actor_identity,''), 'info'
      from public.supplier_audit_log a
     where a.supplier_id = sp.id and a.created_at >= v_from and a.created_at < v_to
    union all
    select c.starts_at, public._sup850_t('h_closure'), coalesce(c.reason,''), 'warning'
      from public.supplier_closure c
     where lower(btrim(coalesce(c.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
       and c.starts_at >= v_from and c.starts_at < v_to
    union all
    select c.reopened_at, public._sup850_t('h_reopen'), '', 'success'
      from public.supplier_closure c
     where lower(btrim(coalesce(c.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
       and c.reopened_at is not null and c.reopened_at >= v_from and c.reopened_at < v_to
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'when', public.ist_fmt(e.at,'day_mon_time12'),
           'title', e.title, 'subtitle', e.subtitle, 'tone', e.tone)
         order by e.at desc), '[]'::jsonb)
    into v_items
    from (select * from ev where at is not null order by at desc limit v_lim) e;

  return jsonb_build_object('ok', true, 'month', to_char(v_m,'YYYY-MM'),
    'blocks', jsonb_build_array(
    jsonb_build_object('kind','chips','key','month','arg','p_month',
      'title', public._sup850_t('h_month'), 'chips', public._sup850_months(v_m)),
    jsonb_build_object('kind','timeline','title',public._sup850_t('h_title'),
      'empty', public._sup850_t('h_empty'), 'items', v_items)));
end $fn$;

commit;

-- ── 12. tab: Availability & stock update ────────────────────────────────────
begin;

-- The supplier's own door onto the same table admin writes through
-- (supplier_item_memory); the zone catalogue heals from it incrementally the
-- way #678 built it, so nothing is recomputed here.
create or replace function public.supplier_account_availability_set(
  p_product_id bigint, p_state text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare sp public.supplier_profiles%rowtype; v_state text := btrim(coalesce(p_state,''));
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  if v_state = '' then
    delete from public.supplier_item_memory
     where lower(btrim(supplier_name)) = lower(btrim(coalesce(sp.supplier_name,'')))
       and product_id = p_product_id;
  else
    insert into public.supplier_item_memory (supplier_name, product_id, last_answer,
                                             last_answered_at, times_answered)
    values (sp.supplier_name, p_product_id, v_state, now(), 1)
    on conflict (supplier_name, product_id) do update
      set last_answer = excluded.last_answer, last_answered_at = now();
  end if;

  insert into public.supplier_audit_log (supplier_id, actor_identity, feature_key, action, detail)
  values (sp.id, coalesce(nullif(public.my_login_email(),''), auth.uid()::text, 'unknown'),
          'supplier.account.availability', 'set_state',
          jsonb_build_object('product_id', p_product_id, 'state', v_state));

  return jsonb_build_object('ok', true, 'message', public._sup850_t('a_saved'));
end $fn$;

create or replace function public.supplier_account_bulk_availability(
  p_company text, p_state text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_co text := btrim(coalesce(p_company,''));
  v_state text := btrim(coalesce(p_state,''));
  v_n int := 0;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;
  if v_co = '' or v_state = '' then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('a_bulk_bad'));
  end if;

  with tgt as (
    select m.product_id
      from public.supplier_item_memory m
      join public."MEDICINE" md on md.id = m.product_id
     where lower(btrim(coalesce(m.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
       and lower(btrim(coalesce(md.marketer_canonical, md.marketer, ''))) = lower(v_co)
  ),
  upd as (
    update public.supplier_item_memory m
       set last_answer = v_state, last_answered_at = now()
      from tgt where m.product_id = tgt.product_id
       and lower(btrim(coalesce(m.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
    returning 1)
  select count(*) into v_n from upd;

  insert into public.supplier_audit_log (supplier_id, actor_identity, feature_key, action, detail)
  values (sp.id, coalesce(nullif(public.my_login_email(),''), auth.uid()::text, 'unknown'),
          'supplier.account.availability', 'bulk_set_state',
          jsonb_build_object('company', v_co, 'state', v_state, 'rows', v_n));

  return jsonb_build_object('ok', true,
    'message', public.ui_textf('sup_acct.a_bulk_done',
                 jsonb_build_object('n', v_n::text, 'company', v_co)));
end $fn$;

create or replace function public.supplier_account_exclusion_undo(
  p_company text, p_category text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare sp public.supplier_profiles%rowtype;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  delete from public.supplier_group_exclusion
   where lower(btrim(coalesce(supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
     and lower(btrim(coalesce(company,''))) = lower(btrim(coalesce(p_company,'')))
     and lower(btrim(coalesce(category,''))) = lower(btrim(coalesce(p_category,'')));

  insert into public.supplier_audit_log (supplier_id, actor_identity, feature_key, action, detail)
  values (sp.id, coalesce(nullif(public.my_login_email(),''), auth.uid()::text, 'unknown'),
          'supplier.account.availability', 'exclusion_undo',
          jsonb_build_object('company', p_company, 'category', p_category));

  return jsonb_build_object('ok', true, 'message', public._sup850_t('a_excl_undone'));
end $fn$;

create or replace function public.supplier_account_tab_availability(p_zone_id integer default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_zone smallint; v_zones jsonb; v_items jsonb; v_copy jsonb;
  v_bulk jsonb; v_forms jsonb; v_excl jsonb;
  v_avail text := 'Available'; v_oos text := 'Out of Stock';
  v_dont text := 'We don''t stock this product';
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  v_zone := coalesce(p_zone_id::smallint, sp.zone_id);
  v_copy := jsonb_build_object('one', public._sup850_t('a_times_one'),
                               'many', public._sup850_t('a_times_many'));

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', z.id::text, 'value', z.id,
           'label', case z.id when 1 then '①' when 2 then '②' when 3 then '③'
                              when 4 then '④' when 5 then '⑤'
                              else '('||z.id::text||')' end || ' ' || z.name,
           'count', (select count(*) from public.supplier_item_memory m
                      join public.catalogue_zone_avail cz
                        on cz.product_id = m.product_id and cz.zone_id = z.id
                     where lower(btrim(coalesce(m.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))),
           'active', (z.id = v_zone))
         order by z.id), '[]'::jsonb)
    into v_zones from public.zones z;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(btrim(coalesce(md.product_name,'')),''), '#'||m.product_id::text),
           'subtitle', public.count_label(v_copy,'one','many',coalesce(m.times_answered,0)),
           'meta', case when m.last_answered_at is null then ''
                        else public._sup850_t('a_last')||': '||
                             public.ist_fmt(m.last_answered_at,'day_mon_year') end,
           'chip', jsonb_build_object('show', true,
             'label', coalesce(nullif(m.last_answer,''), public._sup850_t('a_none')),
             'bg',     case lower(coalesce(m.last_answer,'')) when 'available' then '#D1FAE5'
                            when 'out of stock' then '#FEE2E2' else '#EFF6FF' end,
             'fg',     case lower(coalesce(m.last_answer,'')) when 'available' then '#065F46'
                            when 'out of stock' then '#991B1B' else '#1E40AF' end,
             'border', case lower(coalesce(m.last_answer,'')) when 'available' then '#A7F3D0'
                            when 'out of stock' then '#FECACA' else '#BFDBFE' end),
           'actions', jsonb_build_array(
             jsonb_build_object('label',public._sup850_t('a_set_available'),'tone','success',
               'selected',(m.last_answer = v_avail),'kind','rpc',
               'rpc','supplier_account_availability_set',
               'args', jsonb_build_object('p_product_id', m.product_id, 'p_state', v_avail)),
             jsonb_build_object('label',public._sup850_t('a_set_oos'),'tone','danger',
               'selected',(m.last_answer = v_oos),'kind','rpc',
               'rpc','supplier_account_availability_set',
               'args', jsonb_build_object('p_product_id', m.product_id, 'p_state', v_oos)),
             jsonb_build_object('label',public._sup850_t('a_set_dont'),'tone','info',
               'selected',(m.last_answer = v_dont),'kind','rpc',
               'rpc','supplier_account_availability_set',
               'args', jsonb_build_object('p_product_id', m.product_id, 'p_state', v_dont))))
         order by m.last_answered_at desc nulls last), '[]'::jsonb)
    into v_items
    from public.supplier_item_memory m
    left join public."MEDICINE" md on md.id = m.product_id
   where lower(btrim(coalesce(m.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
     and (v_zone is null
          or exists (select 1 from public.catalogue_zone_avail cz
                      where cz.product_id = m.product_id and cz.zone_id = v_zone));

  -- Bulk by company: one row per company this supplier has ever answered on,
  -- with both buttons already carrying that company's name.
  select coalesce(jsonb_agg(jsonb_build_object(
           'title', g.co,
           'subtitle', public.ui_textf('sup_acct.a_bulk_n',
                         jsonb_build_object('n', g.n::text)),
           'actions', jsonb_build_array(
             jsonb_build_object('label',public._sup850_t('a_bulk_oos'),'tone','danger','kind','rpc',
               'rpc','supplier_account_bulk_availability',
               'args', jsonb_build_object('p_company', g.co, 'p_state', v_oos)),
             jsonb_build_object('label',public._sup850_t('a_bulk_back'),'tone','success','kind','rpc',
               'rpc','supplier_account_bulk_availability',
               'args', jsonb_build_object('p_company', g.co, 'p_state', v_avail))))
         order by g.co), '[]'::jsonb)
    into v_bulk
    from (select btrim(coalesce(md.marketer_canonical, md.marketer,'')) co, count(*) n
            from public.supplier_item_memory m
            join public."MEDICINE" md on md.id = m.product_id
           where lower(btrim(coalesce(m.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
             and btrim(coalesce(md.marketer_canonical, md.marketer,'')) <> ''
           group by 1) g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', public.ui_textf('sup_acct.a_form_title',
                      jsonb_build_object('n', coalesce(jsonb_array_length(f.items),0)::text)),
           'subtitle', coalesce(public.ist_fmt(f.last_sent_at,'day_mon_time12'),''),
           'meta', case when f.expires_at is null then ''
                        else public._sup850_t('a_form_expires')||': '||
                             public.ist_fmt(f.expires_at,'day_mon_time12') end,
           'chip', public.status_chip('stock_update_status', coalesce(f.status,'')))
         order by f.created_at desc), '[]'::jsonb)
    into v_forms
    from public.stock_update_forms f
   where lower(btrim(coalesce(f.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
     and coalesce(f.status,'') <> 'expired'
     and (f.expires_at is null or f.expires_at > now());

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(btrim(coalesce(e.company,'')),''), '—'),
           'subtitle', coalesce(nullif(btrim(coalesce(e.category,'')),''),''),
           'meta', coalesce(public.ist_fmt(e.excluded_at,'day_mon_year'),''),
           'actions', jsonb_build_array(
             jsonb_build_object('label',public._sup850_t('a_excl_undo'),'tone','brand','kind','rpc',
               'rpc','supplier_account_exclusion_undo',
               'args', jsonb_build_object('p_company', coalesce(e.company,''),
                                          'p_category', coalesce(e.category,'')))))
         order by e.excluded_at desc), '[]'::jsonb)
    into v_excl
    from public.supplier_group_exclusion e
   where lower(btrim(coalesce(e.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')));

  return jsonb_build_object('ok', true, 'zone_id', v_zone, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','chips','key','zone','arg','p_zone_id',
      'title',public._sup850_t('a_zone'),'chips',v_zones),
    jsonb_build_object('kind','list','title',public._sup850_t('a_forms'),
      'empty', public._sup850_t('a_forms_empty'), 'items', v_forms),
    jsonb_build_object('kind','list','title',public._sup850_t('a_bulk_title'),
      'empty', public._sup850_t('a_bulk_empty'), 'items', v_bulk),
    jsonb_build_object('kind','list','title',public._sup850_t('a_title'),
      'empty', public._sup850_t('a_empty'), 'items', v_items),
    jsonb_build_object('kind','list','title',public._sup850_t('a_excl_title'),
      'empty', public._sup850_t('a_excl_empty'), 'items', v_excl)));
end $fn$;

commit;

-- ── 13. tab: Statement ──────────────────────────────────────────────────────
begin;

-- A route with no WhatsApp template still delivers: supplier_debit_note is the
-- precedent — push and email carry it until a template is approved.
insert into public.wa_event_routes (event_key, label, description, audience,
                                    enabled, push_enabled, email_enabled,
                                    push_title, push_body, email_subject, email_body)
values ('supplier_statement_ready',
        'Supplier monthly statement',
        'The monthly statement a supplier asked for from My Account.',
        'supplier', true, true, true,
        'Your statement is ready',
        'Your mediBO statement for {{month}} is ready in the app.',
        'Your mediBO statement for {{month}}',
        'Your mediBO statement for {{month}} is ready. Open My Account → Statement in the app to download it.')
on conflict (event_key) do nothing;

create or replace function public.supplier_account_statement_wa(p_month text)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_m date; v_phone text; v_doc jsonb;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;
  v_m := to_date(nullif(btrim(coalesce(p_month,'')),''),'YYYY-MM');
  if v_m is null then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('st_pick_month'));
  end if;

  v_phone := right(regexp_replace(coalesce(nullif(sp.whatsapp_no,''),
                                           nullif(sp.phone,''), sp.contact_no, ''),
                                  '[^0-9]','','g'), 10);
  if length(v_phone) <> 10 then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('st_no_phone'));
  end if;

  v_doc := public.supplier_doc_request('monthly_statement', to_char(v_m,'YYYY-MM'));
  if coalesce(v_doc->>'ok','false') <> 'true' then return v_doc; end if;

  begin
    perform public.notify('supplier_statement_ready', v_phone,
      jsonb_build_object('month', to_char(v_m,'FMMonth YYYY'),
                         'supplier_name', coalesce(sp.supplier_name,'')));
  exception when others then
    return jsonb_build_object('ok', false, 'message', public._sup850_t('st_send_failed'));
  end;

  return jsonb_build_object('ok', true,
    'message', public.ui_textf('sup_acct.st_sent',
                 jsonb_build_object('phone', v_phone)));
end $fn$;

create or replace function public.supplier_account_tab_statement(p_month text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_this date := date_trunc('month',(now() at time zone 'Asia/Kolkata')::date)::date;
  v_m date; v_from timestamptz; v_to timestamptz;
  v_ordered numeric; v_paid numeric; v_debit numeric; v_orders int;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;
  v_m := coalesce(to_date(nullif(btrim(coalesce(p_month,'')),''),'YYYY-MM'), v_this);
  v_from := (v_m::text || ' 00:00:00 Asia/Kolkata')::timestamptz;
  v_to   := ((v_m + interval '1 month')::date::text || ' 00:00:00 Asia/Kolkata')::timestamptz;

  select count(*), coalesce(sum(coalesce(so.total_amount,0)),0)
    into v_orders, v_ordered
    from public.supplier_orders so
   where so.supplier_id = sp.id
     and so.created_at >= v_from and so.created_at < v_to
     and lower(coalesce(so.status,'')) <> 'cancelled';

  select coalesce(sum(coalesce(pm.amount,0)),0) into v_paid
    from public.supplier_payments pm
    join public.supplier_orders so on so.id = pm.supplier_order_id
   where so.supplier_id = sp.id and pm.created_at >= v_from and pm.created_at < v_to;

  select coalesce(sum(coalesce(d.adj_amount,0)),0) into v_debit
    from public.supplier_disputes d
   where lower(btrim(coalesce(d.assigned_supplier,''))) = lower(btrim(coalesce(sp.supplier_name,'')))
     and d.created_at >= v_from and d.created_at < v_to;

  return jsonb_build_object('ok', true, 'month', to_char(v_m,'YYYY-MM'),
    'blocks', jsonb_build_array(
    jsonb_build_object('kind','chips','key','month','arg','p_month',
      'title', public._sup850_t('h_month'), 'chips', public._sup850_months(v_m)),
    jsonb_build_object('kind','tiles','title',public._sup850_t('st_title'),'tiles', jsonb_build_array(
      jsonb_build_object('label',public._sup850_t('st_orders'), 'value',v_orders::text,'tone','neutral'),
      jsonb_build_object('label',public._sup850_t('st_ordered'),'value',public.inr_money(v_ordered),'tone','info'),
      jsonb_build_object('label',public._sup850_t('st_paid'),   'value',public.inr_money(v_paid),'tone','success'),
      jsonb_build_object('label',public._sup850_t('st_debits'), 'value',public.inr_money(v_debit),
                         'tone', case when v_debit > 0 then 'danger' else 'neutral' end))),
    jsonb_build_object('kind','actions','title',public._sup850_t('st_get'),
      'note', public._sup850_t('st_note'), 'items', jsonb_build_array(
      jsonb_build_object('label', public._sup850_t('st_pdf'), 'tone','brand','kind','doc',
        'rpc','supplier_account_doc',
        'args', jsonb_build_object('p_kind','monthly_statement','p_ref', to_char(v_m,'YYYY-MM')),
        'poll_rpc','supplier_account_doc_status','poll_arg','p_id'),
      jsonb_build_object('label', public._sup850_t('st_wa'), 'tone','success','kind','rpc',
        'rpc','supplier_account_statement_wa',
        'args', jsonb_build_object('p_month', to_char(v_m,'YYYY-MM')))))));
end $fn$;

commit;

-- ── 14. tabs: Coverage, Staff, Preferences ──────────────────────────────────
begin;

create or replace function public.supplier_account_tab_coverage()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_declared jsonb; v_suggest jsonb; v_excl jsonb;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', coalesce(nullif(btrim(coalesce(c.company,'')),''),
                             public._sup850_t('cv_any_company')),
           'caption', coalesce(nullif(btrim(coalesce(c.category,'')),''),''),
           'on', true,
           'args', jsonb_build_object('p_company', coalesce(c.company,''),
                                      'p_category', c.category))
         order by lower(btrim(coalesce(c.company,'')))), '[]'::jsonb)
    into v_declared
    from public.supplier_coverage c
   where lower(btrim(coalesce(c.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')));

  select coalesce(jsonb_agg(jsonb_build_object(
           'label', s->>'company',
           'caption', coalesce(s->>'sub_label',''),
           'on', false,
           'args', jsonb_build_object('p_company', s->>'company', 'p_category', null))
         ), '[]'::jsonb)
    into v_suggest
    from jsonb_array_elements(
           public.supplier_coverage_suggestions(coalesce(sp.supplier_name,''))) s;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(btrim(coalesce(e.company,'')),''), '—'),
           'subtitle', coalesce(nullif(btrim(coalesce(e.category,'')),''),''),
           'meta', coalesce(public.ist_fmt(e.excluded_at,'day_mon_year'),''))
         order by e.excluded_at desc), '[]'::jsonb)
    into v_excl
    from public.supplier_group_exclusion e
   where lower(btrim(coalesce(e.supplier_name,''))) = lower(btrim(coalesce(sp.supplier_name,'')));

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','note','text', public._sup850_t('cv_intro')),
    jsonb_build_object('kind','toggles','title',public._sup850_t('cv_declared'),
      'note', public._sup850_t('cv_declared_note'),
      'rpc','supplier_coverage_set','value_arg','p_on','items', v_declared),
    jsonb_build_object('kind','toggles','title',public._sup850_t('cv_suggest'),
      'note', public._sup850_t('cv_suggest_note'),
      'rpc','supplier_coverage_set','value_arg','p_on','items', v_suggest),
    jsonb_build_object('kind','list','title',public._sup850_t('cv_excluded'),
      'empty', public._sup850_t('cv_excluded_empty'), 'items', v_excl)));
end $fn$;

create or replace function public.supplier_account_tab_staff()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare sp public.supplier_profiles%rowtype; v_rows jsonb;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'title', coalesce(nullif(btrim(coalesce(su.name,'')),''), su.identity),
           'subtitle', coalesce(su.identity,''),
           'meta', coalesce(rp.label, su.role_key, ''))
         order by lower(coalesce(su.name, su.identity))), '[]'::jsonb)
    into v_rows
    from public.supplier_users su
    left join public.supplier_role_preset rp on rp.role_key = su.role_key
   where su.supplier_id = sp.id;

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','nav','title',public._sup850_t('sf_manage_title'),
      'items', jsonb_build_array(
        jsonb_build_object('route','staff','label',public._sup850_t('sf_manage'),
                           'caption',public._sup850_t('sf_manage_cap')))),
    jsonb_build_object('kind','list','title',public._sup850_t('sf_title'),
      'empty', public._sup850_t('sf_empty'), 'items', v_rows)));
end $fn$;

create or replace function public.supplier_account_tab_preferences()
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  sp public.supplier_profiles%rowtype;
  v_items jsonb; v_langs jsonb; v_quiet text; v_win text;
begin
  sp := public._sup850_me();
  if sp.id is null then return public._sup850_deny(); end if;

  -- One switch per supplier-facing notification, ON unless this login turned
  -- it off. The catalogue is notification_settings' own default rows.
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', g.label,
           'caption', '',
           'on', not exists (select 1 from public.notification_settings s
                              where s.user_id = auth.uid()
                                and s.action_key = g.action_key
                                and s.channel = 'all' and s.enabled is false),
           'args', jsonb_build_object('p_action_key', g.action_key, 'p_channel','all'))
         order by g.sort, g.action_key), '[]'::jsonb)
    into v_items
    from (select distinct on (n.action_key) n.action_key,
                 coalesce(n.label, n.action_key) label, coalesce(n.sort,0) sort
            from public.notification_settings n
           where n.audience = 'supplier'
           order by n.action_key, n.user_id nulls first) g;

  select quiet_from::text || ' - ' || quiet_to::text into v_win
    from public.user_notify_quiet where user_id = auth.uid();
  v_quiet := coalesce(v_win, public._sup850_t('pr_quiet_off'));

  v_langs := coalesce((public.ui_language_block())->'options', '[]'::jsonb);

  return jsonb_build_object('ok', true, 'blocks', jsonb_build_array(
    jsonb_build_object('kind','toggles','title',public._sup850_t('pr_notify'),
      'note', public._sup850_t('pr_notify_note'),
      'rpc','my_notify_set','value_arg','p_enabled','items', v_items),
    jsonb_build_object('kind','actions','title',public._sup850_t('pr_quiet'),
      'note', public._sup850_t('pr_quiet_note'), 'value', v_quiet,
      'items', jsonb_build_array(
        jsonb_build_object('label', public._sup850_t('pr_quiet_set'), 'tone','brand','kind','rpc',
          'rpc','my_quiet_set','args','{}'::jsonb,
          'prompt', jsonb_build_object('arg','p_window',
            'title', public._sup850_t('pr_quiet'),
            'hint',  public._sup850_t('pr_quiet_hint'),
            'ok',    public._sup850_t('save'),
            'cancel',public._sup850_t('cancel'))),
        jsonb_build_object('label', public._sup850_t('pr_quiet_clear'), 'tone','muted','kind','rpc',
          'rpc','my_quiet_set','args', jsonb_build_object('p_window','')))),
    jsonb_build_object('kind','select','title',public._sup850_t('pr_language'),
      'rpc','ui_language_set','arg','p_lang','options', v_langs)));
end $fn$;

commit;

-- ── 15. the words ───────────────────────────────────────────────────────────
begin;

insert into public.ui_copy (key, value) values
  ('sup_acct.title',            to_jsonb('My account'::text)),
  ('sup_acct.back',             to_jsonb('Back'::text)),
  ('sup_acct.empty',            to_jsonb('Nothing to show on this tab yet.'::text)),
  ('sup_acct.more',             to_jsonb('Load more'::text)),
  ('sup_acct.denied',           to_jsonb('This login is not linked to a supplier account.'::text)),
  ('sup_acct.not_set',          to_jsonb('Not set'::text)),
  ('sup_acct.save',             to_jsonb('Save'::text)),
  ('sup_acct.cancel',           to_jsonb('Cancel'::text)),
  ('sup_acct.send',             to_jsonb('Send'::text)),
  ('sup_acct.shop_open',        to_jsonb('Shop open'::text)),
  ('sup_acct.shop_closed',      to_jsonb('Shop closed'::text)),
  ('sup_acct.tab_profile',      to_jsonb('Profile & KYC'::text)),
  ('sup_acct.tab_companies',    to_jsonb('Companies'::text)),
  ('sup_acct.tab_availability', to_jsonb('Availability'::text)),
  ('sup_acct.tab_orders',       to_jsonb('Orders'::text)),
  ('sup_acct.tab_payments',     to_jsonb('Payments & bills'::text)),
  ('sup_acct.tab_returns',      to_jsonb('Returns & debits'::text)),
  ('sup_acct.tab_performance',  to_jsonb('Performance'::text)),
  ('sup_acct.tab_history',      to_jsonb('History'::text)),
  ('sup_acct.tab_statement',    to_jsonb('Statement'::text)),
  ('sup_acct.tab_coverage',     to_jsonb('Coverage'::text)),
  ('sup_acct.tab_staff',        to_jsonb('Staff'::text)),
  ('sup_acct.tab_preferences',  to_jsonb('Preferences'::text)),
  ('sup_acct.wd_mon', to_jsonb('Mon'::text)),
  ('sup_acct.wd_tue', to_jsonb('Tue'::text)),
  ('sup_acct.wd_wed', to_jsonb('Wed'::text)),
  ('sup_acct.wd_thu', to_jsonb('Thu'::text)),
  ('sup_acct.wd_fri', to_jsonb('Fri'::text)),
  ('sup_acct.wd_sat', to_jsonb('Sat'::text)),
  ('sup_acct.wd_sun', to_jsonb('Sun'::text)),
  -- Profile
  ('sup_acct.p_business',    to_jsonb('Shop'::text)),
  ('sup_acct.p_contact',     to_jsonb('Contact'::text)),
  ('sup_acct.p_kyc',         to_jsonb('Licence & GST'::text)),
  ('sup_acct.p_docs',        to_jsonb('My documents'::text)),
  ('sup_acct.p_docs_empty',  to_jsonb('No document has been generated for you yet.'::text)),
  ('sup_acct.p_edit_title',  to_jsonb('Edit my details'::text)),
  ('sup_acct.p_edit_note',   to_jsonb('Shop name, code and zone are set by mediBO. Everything below is yours to change.'::text)),
  ('sup_acct.p_e_person',    to_jsonb('Contact person'::text)),
  ('sup_acct.p_e_phone',     to_jsonb('Phone'::text)),
  ('sup_acct.p_e_wa',        to_jsonb('WhatsApp number'::text)),
  ('sup_acct.p_e_email',     to_jsonb('Email'::text)),
  ('sup_acct.p_e_address',   to_jsonb('Address'::text)),
  ('sup_acct.p_e_city',      to_jsonb('City'::text)),
  ('sup_acct.p_saved',       to_jsonb('Saved.'::text)),
  ('sup_acct.p_save_failed', to_jsonb('Could not save that. Please try again.'::text)),
  ('sup_acct.p_bad_field',   to_jsonb('That field cannot be changed here.'::text)),
  ('sup_acct.p_bad_phone',   to_jsonb('Enter a 10-digit number.'::text)),
  ('sup_acct.p_bad_email',   to_jsonb('Enter a valid email address.'::text)),
  ('sup_acct.p_cal',         to_jsonb('Shop calendar'::text)),
  ('sup_acct.p_cal_empty',   to_jsonb('No days to show for this month.'::text)),
  ('sup_acct.p_shop',        to_jsonb('Shop hours'::text)),
  ('sup_acct.p_shop_note',   to_jsonb('Tap a day on the calendar, then close or open the shop for it.'::text)),
  ('sup_acct.p_shop_picked', to_jsonb('Selected: {day}'::text)),
  ('sup_acct.p_close_day',   to_jsonb('Close for this day'::text)),
  ('sup_acct.p_open_day',    to_jsonb('Open for this day'::text)),
  ('sup_acct.p_reopen_now',  to_jsonb('Reopen now'::text)),
  ('sup_acct.h_reason',      to_jsonb('Holiday'::text)),
  ('sup_acct.h_closed_on',   to_jsonb('Shop closed for {day}.'::text)),
  ('sup_acct.h_opened_on',   to_jsonb('Shop open again on {day}.'::text)),
  ('sup_acct.h_pick_day',    to_jsonb('Pick a day on the calendar first.'::text)),
  ('sup_acct.f_name',     to_jsonb('Shop name'::text)),
  ('sup_acct.f_code',     to_jsonb('Supplier code'::text)),
  ('sup_acct.f_zone',     to_jsonb('Zone'::text)),
  ('sup_acct.f_type',     to_jsonb('Type'::text)),
  ('sup_acct.f_status',   to_jsonb('Status'::text)),
  ('sup_acct.f_since',    to_jsonb('With mediBO since'::text)),
  ('sup_acct.f_person',   to_jsonb('Contact person'::text)),
  ('sup_acct.f_phone',    to_jsonb('Phone'::text)),
  ('sup_acct.f_whatsapp', to_jsonb('WhatsApp'::text)),
  ('sup_acct.f_email',    to_jsonb('Email'::text)),
  ('sup_acct.f_address',  to_jsonb('Address'::text)),
  ('sup_acct.f_city',     to_jsonb('City'::text)),
  ('sup_acct.f_dl',       to_jsonb('Drug licence'::text)),
  ('sup_acct.f_dl_exp',   to_jsonb('Licence expires'::text)),
  ('sup_acct.f_gst',      to_jsonb('GSTIN'::text)),
  ('sup_acct.f_gst_exp',  to_jsonb('GST expires'::text)),
  -- Companies
  ('sup_acct.c_total',         to_jsonb('Companies'::text)),
  ('sup_acct.c_matched',       to_jsonb('Matched'::text)),
  ('sup_acct.c_unmatched',     to_jsonb('Unmatched'::text)),
  ('sup_acct.c_f_all',         to_jsonb('All'::text)),
  ('sup_acct.c_f_matched',     to_jsonb('Matched'::text)),
  ('sup_acct.c_f_unmatched',   to_jsonb('Unmatched'::text)),
  ('sup_acct.c_matched_on',    to_jsonb('Matched'::text)),
  ('sup_acct.c_list_title',    to_jsonb('Companies I stock'::text)),
  ('sup_acct.c_list_empty',    to_jsonb('No company is mapped to your shop yet.'::text)),
  ('sup_acct.c_pending_title', to_jsonb('Requests'::text)),
  ('sup_acct.c_pending_empty', to_jsonb('You have not asked for a new company yet.'::text)),
  ('sup_acct.c_req_title',     to_jsonb('Add a company'::text)),
  ('sup_acct.c_req_note',      to_jsonb('Ask mediBO to map a company you stock. Admin reviews every request.'::text)),
  ('sup_acct.c_req_btn',       to_jsonb('Request a company'::text)),
  ('sup_acct.c_req_hint',      to_jsonb('Company name as printed'::text)),
  ('sup_acct.c_req_empty',     to_jsonb('Type the company name first.'::text)),
  ('sup_acct.c_req_dupe',      to_jsonb('You have already asked for that company.'::text)),
  ('sup_acct.c_req_sent',      to_jsonb('Sent to mediBO: {name}'::text)),
  -- Availability
  ('sup_acct.a_zone',          to_jsonb('Zone'::text)),
  ('sup_acct.a_title',         to_jsonb('My products'::text)),
  ('sup_acct.a_empty',         to_jsonb('No product has been asked of you in this zone yet.'::text)),
  ('sup_acct.a_last',          to_jsonb('Last answered'::text)),
  ('sup_acct.a_none',          to_jsonb('No answer yet'::text)),
  ('sup_acct.a_times_one',     to_jsonb('Answered once'::text)),
  ('sup_acct.a_times_many',    to_jsonb('Answered {n} times'::text)),
  ('sup_acct.a_set_available', to_jsonb('Available'::text)),
  ('sup_acct.a_set_oos',       to_jsonb('Out of stock'::text)),
  ('sup_acct.a_set_dont',      to_jsonb('I do not stock this'::text)),
  ('sup_acct.a_saved',         to_jsonb('Updated.'::text)),
  ('sup_acct.a_bulk_title',    to_jsonb('Update a whole company'::text)),
  ('sup_acct.a_bulk_empty',    to_jsonb('No company to update in bulk yet.'::text)),
  ('sup_acct.a_bulk_n',        to_jsonb('{n} products'::text)),
  ('sup_acct.a_bulk_oos',      to_jsonb('All out of stock'::text)),
  ('sup_acct.a_bulk_back',     to_jsonb('All back in stock'::text)),
  ('sup_acct.a_bulk_bad',      to_jsonb('Pick a company and a state.'::text)),
  ('sup_acct.a_bulk_done',     to_jsonb('{n} products of {company} updated.'::text)),
  ('sup_acct.a_forms',         to_jsonb('Stock update forms waiting'::text)),
  ('sup_acct.a_forms_empty',   to_jsonb('No stock update is pending from you.'::text)),
  ('sup_acct.a_form_title',    to_jsonb('{n} products to confirm'::text)),
  ('sup_acct.a_form_expires',  to_jsonb('Expires'::text)),
  ('sup_acct.a_excl_title',    to_jsonb('Companies I stopped stocking'::text)),
  ('sup_acct.a_excl_empty',    to_jsonb('You have not blocked any company.'::text)),
  ('sup_acct.a_excl_undo',     to_jsonb('Undo'::text)),
  ('sup_acct.a_excl_undone',   to_jsonb('You will be asked for this company again.'::text)),
  -- Orders
  ('sup_acct.o_title',      to_jsonb('Purchase orders'::text)),
  ('sup_acct.o_empty',      to_jsonb('No purchase order yet.'::text)),
  ('sup_acct.o_all',        to_jsonb('All'::text)),
  ('sup_acct.o_open',       to_jsonb('Open'::text)),
  ('sup_acct.o_packed',     to_jsonb('Packed'::text)),
  ('sup_acct.o_settled',    to_jsonb('Settled'::text)),
  ('sup_acct.o_cancelled',  to_jsonb('Cancelled'::text)),
  ('sup_acct.o_orders',     to_jsonb('Orders'::text)),
  ('sup_acct.o_value',      to_jsonb('Total value'::text)),
  ('sup_acct.o_items_one',  to_jsonb('1 item'::text)),
  ('sup_acct.o_items_many', to_jsonb('{n} items'::text)),
  ('sup_acct.o_pdf',        to_jsonb('PDF'::text)),
  -- Payments
  ('sup_acct.y_billed',       to_jsonb('Billed'::text)),
  ('sup_acct.y_paid',         to_jsonb('Paid'::text)),
  ('sup_acct.y_pending',      to_jsonb('Pending'::text)),
  ('sup_acct.y_debits',       to_jsonb('Debits'::text)),
  ('sup_acct.y_bills',        to_jsonb('Bills'::text)),
  ('sup_acct.y_bills_empty',  to_jsonb('No bill received from you yet.'::text)),
  ('sup_acct.y_unbilled',     to_jsonb('Bill without a file'::text)),
  ('sup_acct.y_pay_title',    to_jsonb('Payments to you'::text)),
  ('sup_acct.y_pay_empty',    to_jsonb('No payment recorded yet.'::text)),
  ('sup_acct.y_payout_title', to_jsonb('Where we pay you'::text)),
  ('sup_acct.y_payout',       to_jsonb('Bank & UPI details'::text)),
  ('sup_acct.y_payout_cap',   to_jsonb('Add or change the account mediBO pays into'::text)),
  -- Returns
  ('sup_acct.r_title',         to_jsonb('Returns to you'::text)),
  ('sup_acct.r_empty',         to_jsonb('No return has been raised against you.'::text)),
  ('sup_acct.r_count',         to_jsonb('Returns'::text)),
  ('sup_acct.r_value',         to_jsonb('Return value'::text)),
  ('sup_acct.r_lines',         to_jsonb('{n} lines'::text)),
  ('sup_acct.r_untitled',      to_jsonb('Debit note'::text)),
  ('sup_acct.r_ack',           to_jsonb('Acknowledge'::text)),
  ('sup_acct.r_dispute',       to_jsonb('Raise an objection'::text)),
  ('sup_acct.r_dispute_hint',  to_jsonb('What is wrong with this return?'::text)),
  ('sup_acct.r_note_pdf',      to_jsonb('Debit note PDF'::text)),
  ('sup_acct.r_note_sent',     to_jsonb('Your objection has been recorded for mediBO to review.'::text)),
  ('sup_acct.r_note_empty',    to_jsonb('Write what is wrong first.'::text)),
  ('sup_acct.r_not_found',     to_jsonb('That return is not yours.'::text)),
  ('sup_acct.r_debits',        to_jsonb('Debits & disputes'::text)),
  ('sup_acct.r_debits_empty',  to_jsonb('No debit raised against you.'::text)),
  -- Performance
  ('sup_acct.pf_window',      to_jsonb('This month'::text)),
  ('sup_acct.pf_spn',         to_jsonb('SPN'::text)),
  ('sup_acct.pf_rank',        to_jsonb('Rank in your zone'::text)),
  ('sup_acct.pf_rank_value',  to_jsonb('#{n}'::text)),
  ('sup_acct.pf_resp',        to_jsonb('Response rate'::text)),
  ('sup_acct.pf_median',      to_jsonb('Median reply'::text)),
  ('sup_acct.pf_fill',        to_jsonb('Fill rate'::text)),
  ('sup_acct.pf_short',       to_jsonb('Short supply'::text)),
  ('sup_acct.pf_disp',        to_jsonb('Disputes'::text)),
  ('sup_acct.pf_ontime',      to_jsonb('On-time collect'::text)),
  ('sup_acct.pf_returns',     to_jsonb('Returns'::text)),
  ('sup_acct.pf_no_returns',  to_jsonb('Not tracked yet'::text)),
  ('sup_acct.pf_na',          to_jsonb('—'::text)),
  ('sup_acct.pf_trend',       to_jsonb('Last 12 months'::text)),
  ('sup_acct.pf_month',       to_jsonb('Month'::text)),
  ('sup_acct.spn_title',      to_jsonb('How your SPN is made up'::text)),
  ('sup_acct.spn_c_factor',   to_jsonb('Factor'::text)),
  ('sup_acct.spn_c_value',    to_jsonb('Yours'::text)),
  ('sup_acct.spn_c_points',   to_jsonb('Points'::text)),
  ('sup_acct.spn_f_margin',   to_jsonb('Margin'::text)),
  ('sup_acct.spn_f_cd',       to_jsonb('Cash discount'::text)),
  ('sup_acct.spn_f_behaviour',to_jsonb('Behaviour'::text)),
  ('sup_acct.spn_f_payment',  to_jsonb('Payment terms'::text)),
  ('sup_acct.spn_moves',      to_jsonb('What moves your SPN'::text)),
  ('sup_acct.spn_moves_empty',to_jsonb('No SPN options are configured yet.'::text)),
  ('sup_acct.spn_pts',        to_jsonb('{n} pts'::text)),
  -- History
  ('sup_acct.h_month',     to_jsonb('Month'::text)),
  ('sup_acct.h_title',     to_jsonb('Everything that happened'::text)),
  ('sup_acct.h_empty',     to_jsonb('Nothing happened in this month.'::text)),
  ('sup_acct.h_inq_asked', to_jsonb('Asked for a price'::text)),
  ('sup_acct.h_inq_ans',   to_jsonb('You answered'::text)),
  ('sup_acct.h_order',     to_jsonb('Purchase order'::text)),
  ('sup_acct.h_debit',     to_jsonb('Debit raised'::text)),
  ('sup_acct.h_dispute',   to_jsonb('Dispute'::text)),
  ('sup_acct.h_bill',      to_jsonb('Bill received'::text)),
  ('sup_acct.h_payment',   to_jsonb('Payment made to you'::text)),
  ('sup_acct.h_return',    to_jsonb('Return raised'::text)),
  ('sup_acct.h_spn',       to_jsonb('SPN changed'::text)),
  ('sup_acct.h_profile',   to_jsonb('Details edited'::text)),
  ('sup_acct.h_objection', to_jsonb('You objected to a return'::text)),
  ('sup_acct.h_avail',     to_jsonb('Availability changed'::text)),
  ('sup_acct.h_closure',   to_jsonb('Shop closed'::text)),
  ('sup_acct.h_reopen',    to_jsonb('Shop reopened'::text)),
  -- Statement
  ('sup_acct.st_title',        to_jsonb('This month'::text)),
  ('sup_acct.st_orders',       to_jsonb('Orders'::text)),
  ('sup_acct.st_ordered',      to_jsonb('Ordered'::text)),
  ('sup_acct.st_paid',         to_jsonb('Paid to you'::text)),
  ('sup_acct.st_debits',       to_jsonb('Debits'::text)),
  ('sup_acct.st_get',          to_jsonb('Get the statement'::text)),
  ('sup_acct.st_note',         to_jsonb('The PDF opens here; WhatsApp sends it to your registered number.'::text)),
  ('sup_acct.st_pdf',          to_jsonb('Download PDF'::text)),
  ('sup_acct.st_wa',           to_jsonb('Send on WhatsApp'::text)),
  ('sup_acct.st_pick_month',   to_jsonb('Pick a month first.'::text)),
  ('sup_acct.st_no_phone',     to_jsonb('No 10-digit number on your account to send to.'::text)),
  ('sup_acct.st_send_failed',  to_jsonb('Could not send it right now. The PDF is still available above.'::text)),
  ('sup_acct.st_sent',         to_jsonb('Sent to {phone}.'::text)),
  -- Coverage
  ('sup_acct.cv_intro',          to_jsonb('Turn a company on and mediBO will ask you about its products. Turn it off and it will not.'::text)),
  ('sup_acct.cv_declared',       to_jsonb('Companies I cover'::text)),
  ('sup_acct.cv_declared_note',  to_jsonb('Switch a company off to stop being asked about it.'::text)),
  ('sup_acct.cv_suggest',        to_jsonb('Companies you answer on'::text)),
  ('sup_acct.cv_suggest_note',   to_jsonb('You have said Available for these but have not declared them yet.'::text)),
  ('sup_acct.cv_any_company',    to_jsonb('Any company'::text)),
  ('sup_acct.cv_excluded',       to_jsonb('Blocked by you'::text)),
  ('sup_acct.cv_excluded_empty', to_jsonb('You have not blocked any company.'::text)),
  -- Staff
  ('sup_acct.sf_title',        to_jsonb('People with a login'::text)),
  ('sup_acct.sf_empty',        to_jsonb('Only you can sign in to this shop.'::text)),
  ('sup_acct.sf_manage_title', to_jsonb('Staff logins'::text)),
  ('sup_acct.sf_manage',       to_jsonb('Manage staff'::text)),
  ('sup_acct.sf_manage_cap',   to_jsonb('Add a login, change what it may open, or remove it'::text)),
  -- Preferences
  ('sup_acct.pr_notify',      to_jsonb('What we tell you about'::text)),
  ('sup_acct.pr_notify_note', to_jsonb('Switch one off and mediBO stops sending it on every channel.'::text)),
  ('sup_acct.pr_quiet',       to_jsonb('Quiet hours'::text)),
  ('sup_acct.pr_quiet_note',  to_jsonb('Nothing is sent to you inside this window.'::text)),
  ('sup_acct.pr_quiet_hint',  to_jsonb('22:00 - 07:00'::text)),
  ('sup_acct.pr_quiet_off',   to_jsonb('No quiet hours set'::text)),
  ('sup_acct.pr_quiet_set',   to_jsonb('Set quiet hours'::text)),
  ('sup_acct.pr_quiet_clear', to_jsonb('Clear'::text)),
  ('sup_acct.pr_language',    to_jsonb('Language'::text))
on conflict (key) do nothing;

commit;

-- ── 16. grants ──────────────────────────────────────────────────────────────
begin;

revoke execute on function public.supplier_account_page() from public, anon;
revoke execute on function public.supplier_account_tab_profile(text, text) from public, anon;
revoke execute on function public.supplier_account_tab_companies(text) from public, anon;
revoke execute on function public.supplier_account_tab_availability(integer) from public, anon;
revoke execute on function public.supplier_account_tab_orders(text, integer) from public, anon;
revoke execute on function public.supplier_account_tab_payments(integer) from public, anon;
revoke execute on function public.supplier_account_tab_returns(integer) from public, anon;
revoke execute on function public.supplier_account_tab_performance() from public, anon;
revoke execute on function public.supplier_account_tab_history(text, integer) from public, anon;
revoke execute on function public.supplier_account_tab_statement(text) from public, anon;
revoke execute on function public.supplier_account_tab_coverage() from public, anon;
revoke execute on function public.supplier_account_tab_staff() from public, anon;
revoke execute on function public.supplier_account_tab_preferences() from public, anon;
revoke execute on function public.supplier_account_profile_set(text, text) from public, anon;
revoke execute on function public.supplier_account_holiday_set(text, boolean) from public, anon;
revoke execute on function public.supplier_account_company_request(text) from public, anon;
revoke execute on function public.supplier_account_availability_set(bigint, text) from public, anon;
revoke execute on function public.supplier_account_bulk_availability(text, text) from public, anon;
revoke execute on function public.supplier_account_exclusion_undo(text, text) from public, anon;
revoke execute on function public.supplier_account_return_dispute(uuid, text) from public, anon;
revoke execute on function public.supplier_account_statement_wa(text) from public, anon;
revoke execute on function public.supplier_account_doc(text, text) from public, anon;
revoke execute on function public.supplier_account_doc_status(uuid) from public, anon;

grant execute on function public.supplier_account_page() to authenticated;
grant execute on function public.supplier_account_tab_profile(text, text) to authenticated;
grant execute on function public.supplier_account_tab_companies(text) to authenticated;
grant execute on function public.supplier_account_tab_availability(integer) to authenticated;
grant execute on function public.supplier_account_tab_orders(text, integer) to authenticated;
grant execute on function public.supplier_account_tab_payments(integer) to authenticated;
grant execute on function public.supplier_account_tab_returns(integer) to authenticated;
grant execute on function public.supplier_account_tab_performance() to authenticated;
grant execute on function public.supplier_account_tab_history(text, integer) to authenticated;
grant execute on function public.supplier_account_tab_statement(text) to authenticated;
grant execute on function public.supplier_account_tab_coverage() to authenticated;
grant execute on function public.supplier_account_tab_staff() to authenticated;
grant execute on function public.supplier_account_tab_preferences() to authenticated;
grant execute on function public.supplier_account_profile_set(text, text) to authenticated;
grant execute on function public.supplier_account_holiday_set(text, boolean) to authenticated;
grant execute on function public.supplier_account_company_request(text) to authenticated;
grant execute on function public.supplier_account_availability_set(bigint, text) to authenticated;
grant execute on function public.supplier_account_bulk_availability(text, text) to authenticated;
grant execute on function public.supplier_account_exclusion_undo(text, text) to authenticated;
grant execute on function public.supplier_account_return_dispute(uuid, text) to authenticated;
grant execute on function public.supplier_account_statement_wa(text) to authenticated;
grant execute on function public.supplier_account_doc(text, text) to authenticated;
grant execute on function public.supplier_account_doc_status(uuid) to authenticated;

grant select on public.supplier_account_tab to authenticated, anon;

commit;
