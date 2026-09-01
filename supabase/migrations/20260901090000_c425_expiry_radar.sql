-- CHANGE #425 — EXPIRY RADAR, part 1: the substrate.
--
-- #413 built expiry buckets over `pharmacy_stock` and pinged on VALUE AT COST:
-- every batch with a rupee figure was a candidate, so a ₹40 maybe could out-rank
-- nothing and a shop with forty batches got the loudest one rather than the most
-- expensive MISTAKE. This command supersedes that half. The radar ranks on
-- EXPECTED LOSS — the money that is actually going to be thrown away:
--
--     expected_loss = unit_cost * max(0, est_left - velocity_per_day * days_left)
--
-- `est_left` and `velocity` come from #424's consumption inference when it is
-- present. #424 is still building as this lands, so the adapter below BINDS
-- LATE: `pharmacy_radar_rebind()` looks for an inference relation, and until it
-- finds one the radar falls back to the recorded quantity with velocity 0 —
-- the conservative answer (all of it is at risk), labelled 'recorded' rather
-- than dressed up as an inference. Nothing here breaks when #424 lands; the
-- rebind sweep picks it up on the dispatcher within the hour.
--
-- Everything the pharmacy reads is a backend string. Dart formats no rupee,
-- no plural and no "likely".

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. CONFIG — per pharmacy opt-in and frequency caps
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.pharmacy_radar_config (
  pharmacy_id      uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  opt_in           boolean not null default false,   -- WhatsApp alerts: explicit opt-in
  monthly_digest   boolean not null default true,
  urgent_enabled   boolean not null default true,
  ask_corrections  boolean not null default true,
  wa_intake        boolean not null default true,    -- forward a bill photo to our number
  max_msgs_per_week integer not null default 3,
  min_expected_loss numeric not null default 200,
  updated_at       timestamptz not null default now()
);
alter table public.pharmacy_radar_config enable row level security;

-- The ASK ledger: every one-tap correction we put in front of a pharmacy, on
-- WhatsApp or in the app, and the answer that came back.
create table if not exists public.pharmacy_radar_ask (
  id             uuid primary key default gen_random_uuid(),
  pharmacy_id    uuid not null references public.pharmacy_profiles(id) on delete cascade,
  stock_id       uuid,
  product_name   text,
  batch_no       text,
  expiry_on      date,
  channel        text not null default 'whatsapp',
  dedupe_key     text not null,
  question       text,
  options        jsonb not null default '[]'::jsonb,
  est_left       numeric,
  expected_loss  numeric,
  status         text not null default 'open',   -- open | answered | expired
  answered_qty   numeric,
  answer_source  text,
  answered_at    timestamptz,
  asked_on       date not null default public._c413_today(),
  created_at     timestamptz not null default now()
);
alter table public.pharmacy_radar_ask enable row level security;
create unique index if not exists pharmacy_radar_ask_dedupe_idx
  on public.pharmacy_radar_ask (pharmacy_id, dedupe_key);
create index if not exists pharmacy_radar_ask_open_idx
  on public.pharmacy_radar_ask (pharmacy_id, status, created_at desc);

-- Bill-by-WhatsApp intake ledger: one row per forwarded photo.
create table if not exists public.pharmacy_wa_intake (
  id              uuid primary key default gen_random_uuid(),
  pharmacy_id     uuid references public.pharmacy_profiles(id) on delete set null,
  message_id      uuid,
  phone           text,
  bucket          text,
  path            text,
  bill_id         uuid,
  status          text not null default 'received', -- received|queued|read|failed|ignored
  reason          text,
  confirmed_at    timestamptz,
  read_notified_at timestamptz,
  detail          jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now()
);
alter table public.pharmacy_wa_intake enable row level security;
create unique index if not exists pharmacy_wa_intake_msg_idx
  on public.pharmacy_wa_intake (message_id);
create index if not exists pharmacy_wa_intake_status_idx
  on public.pharmacy_wa_intake (status, created_at desc);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE SEND GUARD — during the build phase only Om's own numbers can be
--    reached. Not a comment, not a habit: every send in this command goes
--    through _c425_may_send() and a real pharmacy or supplier number is
--    refused by the database itself.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.app_settings(key, value) values
 ('expiry_radar', jsonb_build_object(
    'enabled', true,
    'build_phase', true,
    'test_numbers', jsonb_build_array('9111100011'),
    'min_expected_loss', 200,
    'max_msgs_per_week', 3,
    'digest_dom', 1,
    'ask_max_open', 3,
    'urgent_days', 21,
    'horizon_days', 120))
on conflict (key) do nothing;

create or replace function public._c425_cfg()
returns jsonb language sql stable set search_path to 'public' as $$
  select coalesce((select value from public.app_settings where key = 'expiry_radar'),
                  '{}'::jsonb);
$$;

create or replace function public._c425_may_send(p_phone text)
returns boolean language plpgsql stable set search_path to 'public' as $$
declare
  v_cfg  jsonb := public._c425_cfg();
  v_ph   text  := nullif(right(regexp_replace(coalesce(p_phone,''),'\D','','g'), 10), '');
begin
  if not coalesce((v_cfg->>'enabled')::boolean, false) then return false; end if;
  if v_ph is null then return false; end if;
  -- never a supplier, in any phase
  if public._notify_is_supplier_phone(v_ph) then return false; end if;
  if coalesce((v_cfg->>'build_phase')::boolean, true) then
    return exists (
      select 1 from jsonb_array_elements_text(coalesce(v_cfg->'test_numbers','[]'::jsonb)) t
       where right(regexp_replace(t,'\D','','g'), 10) = v_ph);
  end if;
  return true;
end $$;

-- Frequency cap: how many radar messages has this shop had in the last 7 days.
create or replace function public._c425_week_count(p_shop uuid)
returns integer language sql stable set search_path to 'public' as $$
  select count(*)::integer from public.pharmacy_expiry_alert_log
   where pharmacy_id = p_shop
     and kind like 'radar_%'
     and created_at >= now() - interval '7 days';
$$;

create or replace function public._c425_config(p_shop uuid)
returns public.pharmacy_radar_config language plpgsql stable set search_path to 'public' as $$
declare v public.pharmacy_radar_config; v_cfg jsonb := public._c425_cfg();
begin
  select * into v from public.pharmacy_radar_config where pharmacy_id = p_shop;
  if found then return v; end if;
  v.pharmacy_id       := p_shop;
  v.opt_in            := false;
  v.monthly_digest    := true;
  v.urgent_enabled    := true;
  v.ask_corrections   := true;
  v.wa_intake         := true;
  v.max_msgs_per_week := coalesce((v_cfg->>'max_msgs_per_week')::int, 3);
  v.min_expected_loss := coalesce((v_cfg->>'min_expected_loss')::numeric, 200);
  return v;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. THE INFERENCE ADAPTER — late-bound to #424
--
-- `_c425_infer(shop)` answers (stock_id, est_left, velocity_per_day, basis) for
-- every lot. The body is REWRITTEN by pharmacy_radar_rebind() the moment an
-- inference relation appears, so this command never has to be re-deployed for
-- #424 to take effect, and never breaks if #424 changes shape.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.pharmacy_radar_binding (
  id          boolean primary key default true check (id),
  source      text not null default 'recorded',
  relation    text,
  bound_at    timestamptz not null default now(),
  detail      jsonb not null default '{}'::jsonb
);
insert into public.pharmacy_radar_binding(id) values (true) on conflict (id) do nothing;

create or replace function public._c425_infer(p_shop uuid)
returns table(stock_id uuid, est_left numeric, velocity_per_day numeric, basis text)
language sql stable set search_path to 'public' as $$
  select s.id, coalesce(s.qty,0)::numeric, 0::numeric, 'recorded'::text
    from public.pharmacy_stock s
   where s.pharmacy_id = p_shop;
$$;

-- Candidate shapes, in priority order. A relation qualifies when it carries a
-- lot/stock key plus a remaining-quantity column; velocity is optional.
create or replace function public.pharmacy_radar_rebind()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r         record;
  v_key     text; v_left text; v_vel text; v_rel text;
  v_bound   jsonb := null;
begin
  for r in
    select c.relname as rel
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind in ('r','v','m','p')
       and (c.relname like 'pharmacy_lot%state%'
         or c.relname like 'pharmacy_infer%'
         or c.relname like '%lot_inference%'
         or c.relname like 'pharmacy_consumption%'
         or c.relname like '%inferred_lot%')
     order by c.relname
  loop
    select max(case when column_name in ('stock_id','lot_id') then column_name end),
           max(case when column_name in ('inferred_left','est_left','remaining_qty','qty_left') then column_name end),
           max(case when column_name in ('velocity_per_day','velocity','daily_velocity','vel_per_day') then column_name end)
      into v_key, v_left, v_vel
      from information_schema.columns
     where table_schema = 'public' and table_name = r.rel;

    if v_key is not null and v_left is not null then
      v_rel := r.rel;
      exit;
    end if;
  end loop;

  if v_rel is null then
    execute $f$
      create or replace function public._c425_infer(p_shop uuid)
      returns table(stock_id uuid, est_left numeric, velocity_per_day numeric, basis text)
      language sql stable set search_path to 'public' as $b$
        select s.id, coalesce(s.qty,0)::numeric, 0::numeric, 'recorded'::text
          from public.pharmacy_stock s
         where s.pharmacy_id = p_shop;
      $b$;
    $f$;
    update public.pharmacy_radar_binding
       set source = 'recorded', relation = null, bound_at = now(),
           detail = jsonb_build_object('reason','no_inference_relation')
     where id;
    return jsonb_build_object('ok', true, 'source', 'recorded');
  end if;

  execute format($f$
    create or replace function public._c425_infer(p_shop uuid)
    returns table(stock_id uuid, est_left numeric, velocity_per_day numeric, basis text)
    language sql stable set search_path to 'public' as $b$
      select s.id,
             coalesce(i.%1$I, s.qty, 0)::numeric,
             coalesce(%2$s, 0)::numeric,
             case when i.%3$I is null then 'recorded' else 'inferred' end
        from public.pharmacy_stock s
        left join public.%4$I i on i.%3$I = s.id
       where s.pharmacy_id = p_shop;
    $b$;
  $f$, v_left,
       case when v_vel is null then '0' else format('i.%I', v_vel) end,
       v_key, v_rel);

  v_bound := jsonb_build_object('relation', v_rel, 'key', v_key,
                                'left', v_left, 'velocity', coalesce(v_vel,'-'));
  update public.pharmacy_radar_binding
     set source = 'inferred', relation = v_rel, bound_at = now(), detail = v_bound
   where id;
  return jsonb_build_object('ok', true, 'source', 'inferred', 'detail', v_bound);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE RADAR ROWS — expected loss, not value at cost
-- ─────────────────────────────────────────────────────────────────────────────
-- A NAMED row type, so every helper below can take one whole radar row as an
-- argument. (SQL and PL/pgSQL both refuse a bare `record` parameter.)
do $$
begin
  if to_regtype('public.c425_radar_row') is null then
    create type public.c425_radar_row as (
      stock_id uuid, product_id bigint, product_name text, pack_label text,
      batch_no text, expiry_on date, qty numeric, unit_cost numeric,
      est_left numeric, velocity_per_day numeric, basis text,
      days_to_expiry integer, bucket_key text,
      value_at_cost numeric, expected_qty_lost numeric, expected_loss numeric,
      supplier_name text, closes_on date, days_to_close integer, window_state text);
  end if;
end $$;

drop function if exists public._c425_rows(uuid);
create function public._c425_rows(p_shop uuid)
returns setof public.c425_radar_row
language sql stable set search_path to 'public' as $$
  with cfg as (select public._c425_cfg() c),
  base as (
    select s.id, s.medicine_id, s.product_name, s.pack_label, s.batch_no,
           coalesce(s.expiry_on, public._c413_expiry_date(s.expiry)) as expiry_on,
           coalesce(s.qty,0) as qty, coalesce(s.unit_cost,0) as unit_cost,
           nullif(btrim(coalesce(s.supplier_label,'')),'') as supplier_name,
           i.est_left, i.velocity_per_day, i.basis
      from public.pharmacy_stock s
      join public._c425_infer(p_shop) i on i.stock_id = s.id
     where s.pharmacy_id = p_shop
  ), dated as (
    select b.*, (b.expiry_on - public._c413_today())::integer as dte
      from base b where b.expiry_on is not null
  ), scored as (
    select d.*,
           greatest(coalesce(d.est_left, d.qty), 0) as left_qty,
           greatest(0, coalesce(d.est_left, d.qty)
                       - coalesce(d.velocity_per_day,0) * greatest(d.dte, 0)) as lost_qty
      from dated d
      cross join cfg
     where d.dte <= coalesce((cfg.c->>'horizon_days')::int, 120)
  )
  select s.id, s.medicine_id, s.product_name, s.pack_label, s.batch_no,
         s.expiry_on, s.qty, s.unit_cost,
         round(s.left_qty, 2), round(coalesce(s.velocity_per_day,0), 3), s.basis,
         s.dte,
         case when s.dte <  0  then 'expired'
              when s.dte <= 30 then 'd30'
              when s.dte <= 60 then 'd60'
              when s.dte <= 90 then 'd90'
              else 'later' end,
         round(s.left_qty * s.unit_cost, 2),
         round(s.lost_qty, 2),
         round(s.lost_qty * s.unit_cost, 2),
         s.supplier_name,
         (s.expiry_on - w.closes_days),
         ((s.expiry_on - w.closes_days) - public._c413_today())::integer,
         case
           when public._c413_today() >  (s.expiry_on - w.closes_days) then 'closed'
           when public._c413_today() <  (s.expiry_on - w.opens_days)  then 'not_open'
           else 'open'
         end
    from scored s
    cross join lateral public._c413_window(p_shop, s.supplier_name) w;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. COPY — every word the pharmacy reads, in the database
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
 ('phradar.title',          to_jsonb('Expiry radar'::text)),
 ('phradar.nav_label',      to_jsonb('Expiry radar'::text)),
 ('phradar.nav_sub',        to_jsonb('Ranked by the money you are about to lose'::text)),
 ('phradar.subtitle',       to_jsonb('Ranked by what it will actually cost you, not by what is closest.'::text)),
 ('phradar.headline',       to_jsonb('{{value}} likely to expire unsold'::text)),
 ('phradar.headline_none',  to_jsonb('Nothing worth worrying about yet'::text)),
 ('phradar.headline_note',  to_jsonb('{{items}} batches on the radar · at your purchase cost'::text)),
 ('phradar.headline_none_note', to_jsonb('We will tell you the moment a batch starts costing you money.'::text)),
 ('phradar.list_title',     to_jsonb('Worst first'::text)),
 ('phradar.value_label',    to_jsonb('Expected loss'::text)),
 ('phradar.basis_inferred', to_jsonb('Estimated from your purchases'::text)),
 ('phradar.basis_recorded', to_jsonb('From your recorded stock'::text)),
 ('phradar.qty_inferred',   to_jsonb('likely ~{{n}} left'::text)),
 ('phradar.qty_recorded',   to_jsonb('{{n}} recorded'::text)),
 ('phradar.expiry_label',   to_jsonb('Expires {{date}}'::text)),
 ('phradar.batch_label',    to_jsonb('Batch {{batch}}'::text)),
 ('phradar.no_batch',       to_jsonb('No batch number'::text)),
 ('phradar.no_supplier',    to_jsonb('Supplier not recorded'::text)),
 ('phradar.window_open',    to_jsonb('Return window closes in {{days}} days'::text)),
 ('phradar.window_closed',  to_jsonb('Return window has closed'::text)),
 ('phradar.window_not_open',to_jsonb('Return window opens later'::text)),
 ('phradar.empty',          to_jsonb('No batch is at risk right now'::text)),
 ('phradar.empty_hint',     to_jsonb('Forward your purchase bills on WhatsApp and this fills itself.'::text)),
 ('phradar.ask_title',      to_jsonb('How many are actually left?'::text)),
 ('phradar.ask_question',   to_jsonb('{{product}} — {{batch_word}} expires {{date}}. We think ~{{n}} left. How many actually?'::text)),
 ('phradar.ask_other',      to_jsonb('Other'::text)),
 ('phradar.ask_other_hint', to_jsonb('Type the number'::text)),
 ('phradar.ask_saved',      to_jsonb('Saved — {{n}} left on {{product}}. Thank you.'::text)),
 ('phradar.ask_saved_zero', to_jsonb('Saved — {{product}} is finished. Thank you.'::text)),
 ('phradar.ask_none',       to_jsonb('Nothing to confirm right now'::text)),
 ('phradar.ask_gone',       to_jsonb('That question is already answered.'::text)),
 ('phradar.ask_bad_qty',    to_jsonb('Please send a whole number, like 0 or 4.'::text)),
 ('phradar.ask_section',    to_jsonb('Quick check'::text)),
 ('phradar.ask_section_note', to_jsonb('One tap keeps the estimate honest.'::text)),
 ('phradar.optin_title',    to_jsonb('Get this on WhatsApp'::text)),
 ('phradar.optin_body',     to_jsonb('Urgent expiry alerts and a monthly stock summary on your registered WhatsApp number. No more than {{cap}} messages a week.'::text)),
 ('phradar.optin_on',       to_jsonb('WhatsApp alerts are on'::text)),
 ('phradar.optin_off',      to_jsonb('WhatsApp alerts are off'::text)),
 ('phradar.optin_button_on',  to_jsonb('Turn on WhatsApp alerts'::text)),
 ('phradar.optin_button_off', to_jsonb('Turn off'::text)),
 ('phradar.optin_no_number', to_jsonb('Add a WhatsApp number to your profile first.'::text)),
 ('phradar.intake_title',   to_jsonb('Bills by WhatsApp'::text)),
 ('phradar.intake_body',    to_jsonb('Forward any purchase bill photo to mediBO on WhatsApp. It lands in your bill vault and we message you what we read.'::text)),
 ('phradar.intake_count',   to_jsonb('{{n}} bills arrived this way'::text)),
 ('phradar.intake_none',    to_jsonb('No bill has arrived by WhatsApp yet'::text)),
 ('phradar.wa_received',    to_jsonb('Bill received — reading it now. We will message you what we read.'::text)),
 ('phradar.wa_read',        to_jsonb('Read your bill: {{supplier}}, invoice {{invoice}}, {{lines}} items, {{total}}. Open mediBO to confirm.'::text)),
 ('phradar.wa_read_partial',to_jsonb('Read your bill but some lines were unclear ({{lines}} items). Open mediBO to check.'::text)),
 ('phradar.wa_failed',      to_jsonb('We could not read that bill. Please send a clearer photo in daylight.'::text)),
 ('phradar.wa_urgent',      to_jsonb('{{product}} ({{batch_word}}) expires {{date}} — about {{value}} at risk. Return window closes in {{days}} days. How many are left?'::text)),
 ('phradar.wa_digest',      to_jsonb('{{shop}} — this month: {{bills}} bills captured, stock worth about {{stock}}, and {{value}} at risk of expiring. Check these {{items}} items in mediBO.'::text)),
 ('phradar.digest_title',   to_jsonb('This month'::text)),
 ('phradar.digest_bills',   to_jsonb('Bills captured'::text)),
 ('phradar.digest_stock',   to_jsonb('Stock value'::text)),
 ('phradar.digest_risk',    to_jsonb('At risk'::text)),
 ('phradar.refused',        to_jsonb('This screen is for a pharmacy account.'::text)),
 ('phradar.saved',          to_jsonb('Saved'::text))
on conflict (key) do nothing;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. THE ASK — question and options, composed in the backend
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c425_ask_options(p_left numeric)
returns jsonb language sql immutable set search_path to 'public' as $$
  select coalesce(jsonb_agg(distinct_opt order by distinct_opt), '[]'::jsonb)
    from (
      select distinct greatest(round(v)::int, 0) as distinct_opt
        from unnest(array[0::numeric,
                          floor(coalesce(p_left,0) / 2),
                          round(coalesce(p_left,0))]) v
    ) o;
$$;

create or replace function public._c425_ask_build(p_shop uuid, p_row public.c425_radar_row)
returns jsonb language plpgsql stable set search_path to 'public' as $$
declare v_batch text;
begin
  v_batch := case when coalesce(btrim(coalesce(p_row.batch_no,'')),'') = ''
                  then public.ui_text('phradar.no_batch')
                  else public.ui_fmt('phradar.batch_label',
                         jsonb_build_object('batch', p_row.batch_no)) end;
  return jsonb_build_object(
    'question', public.ui_fmt('phradar.ask_question', jsonb_build_object(
        'product',    coalesce(p_row.product_name, ''),
        'batch_word', v_batch,
        'date',       to_char(p_row.expiry_on, 'DD/MM/YY'),
        'n',          trim(to_char(coalesce(p_row.est_left,0), 'FM999999990.##')))),
    'options',  public._c425_ask_options(p_row.est_left),
    'batch_word', v_batch);
end $$;

-- Raise (or reuse) today's ask for one lot. Returns the ask row id.
create or replace function public._c425_ask_open(p_shop uuid, p_stock_id uuid, p_channel text)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare r public.c425_radar_row; v_ask jsonb; v_key text; v_id uuid;
begin
  select * into r from public._c425_rows(p_shop) x where x.stock_id = p_stock_id;
  if not found then return null; end if;

  v_key := p_stock_id::text || ':' || to_char(public._c413_today(), 'IYYY-"W"IW');
  select id into v_id from public.pharmacy_radar_ask
   where pharmacy_id = p_shop and dedupe_key = v_key;
  if v_id is not null then return v_id; end if;

  v_ask := public._c425_ask_build(p_shop, r);
  insert into public.pharmacy_radar_ask (
    pharmacy_id, stock_id, product_name, batch_no, expiry_on, channel,
    dedupe_key, question, options, est_left, expected_loss)
  values (p_shop, p_stock_id, r.product_name, r.batch_no, r.expiry_on,
          coalesce(p_channel,'whatsapp'), v_key,
          v_ask->>'question', v_ask->'options', r.est_left, r.expected_loss)
  on conflict (pharmacy_id, dedupe_key) do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.pharmacy_radar_ask
     where pharmacy_id = p_shop and dedupe_key = v_key;
  end if;
  return v_id;
end $$;

-- The truth loop: an answer moves the shelf AND is left as ground truth for
-- #424's velocity to recalibrate against.
create or replace function public._c425_apply_answer(
  p_ask_id uuid, p_qty numeric, p_source text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a public.pharmacy_radar_ask; s public.pharmacy_stock; v_delta numeric;
begin
  select * into a from public.pharmacy_radar_ask where id = p_ask_id;
  if not found then
    return jsonb_build_object('ok', false, 'error','no_ask',
                              'message', public.ui_text('phradar.ask_gone'));
  end if;
  if a.status = 'answered' then
    return jsonb_build_object('ok', false, 'error','already',
                              'message', public.ui_text('phradar.ask_gone'));
  end if;
  if p_qty is null or p_qty < 0 then
    return jsonb_build_object('ok', false, 'error','bad_qty',
                              'message', public.ui_text('phradar.ask_bad_qty'));
  end if;

  select * into s from public.pharmacy_stock where id = a.stock_id;
  if found then
    v_delta := p_qty - coalesce(s.qty, 0);
    update public.pharmacy_stock set qty = p_qty, updated_at = now() where id = s.id;
    insert into public.pharmacy_stock_move (
      pharmacy_id, stock_id, item_key, kind, qty_delta, qty_after, unit_cost,
      reason_code, note, actor_label, ref_kind, ref_id)
    values (a.pharmacy_id, s.id, s.item_key, 'adjust', v_delta, p_qty, s.unit_cost,
            'count_correction', 'expiry radar answer', coalesce(p_source,'whatsapp'),
            'radar_ask', a.id::text);
  end if;

  update public.pharmacy_radar_ask
     set status = 'answered', answered_qty = p_qty, answered_at = now(),
         answer_source = coalesce(p_source, 'whatsapp')
   where id = a.id;

  return jsonb_build_object('ok', true, 'ask_id', a.id, 'qty', p_qty,
    'product', a.product_name,
    'message', case when p_qty = 0
      then public.ui_fmt('phradar.ask_saved_zero',
             jsonb_build_object('product', coalesce(a.product_name,'')))
      else public.ui_fmt('phradar.ask_saved', jsonb_build_object(
             'product', coalesce(a.product_name,''),
             'n', trim(to_char(p_qty, 'FM999999990.##')))) end);
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. THE SCREEN — one RPC, rendered verbatim
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public._c425_shop()
returns uuid language sql stable as $$ select public.my_customer_id(); $$;

create or replace function public._c425_denied()
returns jsonb language sql stable set search_path to 'public' as $$
  select jsonb_build_object('ok', false, 'error','not_a_pharmacy',
                            'message', public.ui_text('phradar.refused'));
$$;

create or replace function public._c425_item_json(r public.c425_radar_row, p_ask jsonb)
returns jsonb language sql stable set search_path to 'public' as $$
  select jsonb_build_object(
    'stock_id',    r.stock_id,
    'product_name', coalesce(r.product_name, ''),
    'value_display', public.inr_money(r.expected_loss),
    'value_caption', public.ui_text('phradar.value_label'),
    'cost_display',  public.inr_money(r.value_at_cost),
    'qty_label', case when r.basis = 'inferred'
      then public.ui_fmt('phradar.qty_inferred',
             jsonb_build_object('n', trim(to_char(r.est_left, 'FM999999990.##'))))
      else public.ui_fmt('phradar.qty_recorded',
             jsonb_build_object('n', trim(to_char(r.est_left, 'FM999999990.##')))) end,
    'basis_label', case when r.basis = 'inferred'
                        then public.ui_text('phradar.basis_inferred')
                        else public.ui_text('phradar.basis_recorded') end,
    'expiry_label', public.ui_fmt('phradar.expiry_label',
                      jsonb_build_object('date', to_char(r.expiry_on, 'DD/MM/YY'))),
    'batch_label', case when coalesce(btrim(coalesce(r.batch_no,'')),'') = ''
                        then public.ui_text('phradar.no_batch')
                        else public.ui_fmt('phradar.batch_label',
                               jsonb_build_object('batch', r.batch_no)) end,
    'supplier_label', coalesce(nullif(btrim(coalesce(r.supplier_name,'')),''),
                               public.ui_text('phradar.no_supplier')),
    'bucket_key', r.bucket_key,
    'window_label', case r.window_state
        when 'open' then public.ui_fmt('phradar.window_open',
               jsonb_build_object('days', greatest(r.days_to_close,0)::text))
        when 'closed' then public.ui_text('phradar.window_closed')
        else public.ui_text('phradar.window_not_open') end,
    'window_tone', case r.window_state when 'open' then 'warning'
                                       when 'closed' then 'danger'
                                       else 'neutral' end,
    'ask', p_ask);
$$;

create or replace function public._c425_ask_json(a public.pharmacy_radar_ask)
returns jsonb language sql stable set search_path to 'public' as $$
  select jsonb_build_object(
    'ask_id',   a.id,
    'stock_id', a.stock_id,
    'question', a.question,
    'options',  (select coalesce(jsonb_agg(jsonb_build_object(
                          'value', o, 'label', o::text) order by o), '[]'::jsonb)
                   from jsonb_array_elements_text(a.options) t(o)),
    'other_label', public.ui_text('phradar.ask_other'),
    'other_hint',  public.ui_text('phradar.ask_other_hint'),
    'status',   a.status,
    'answered_qty', a.answered_qty);
$$;

create or replace function public.pharmacy_radar_entry()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c425_shop(); v_risk numeric;
begin
  if v_shop is null then return jsonb_build_object('ok', true, 'show', false); end if;
  select coalesce(sum(r.expected_loss),0) into v_risk
    from public._c425_rows(v_shop) r
   where r.bucket_key in ('expired','d30','d60','d90');
  return jsonb_build_object('ok', true, 'show', true,
    'label',     public.ui_text('phradar.nav_label'),
    'sub_label', public.ui_text('phradar.nav_sub'),
    'badge',     case when v_risk > 0 then public.inr_money(v_risk) else null end,
    'route_key', 'pharmacy_radar');
end $$;

create or replace function public.pharmacy_radar_home()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_shop  uuid := public._c425_shop();
  v_cfg   public.pharmacy_radar_config;
  v_gcfg  jsonb := public._c425_cfg();
  v_items jsonb := '[]'::jsonb;
  v_asks  jsonb := '[]'::jsonb;
  v_risk  numeric := 0; v_n integer := 0;
  v_stock numeric := 0; v_bills integer := 0; v_wa integer := 0;
  v_phone text; r public.c425_radar_row;
  a public.pharmacy_radar_ask; v_ask jsonb;
begin
  if v_shop is null then return public._c425_denied(); end if;
  v_cfg := public._c425_config(v_shop);

  for r in
    select * from public._c425_rows(v_shop)
     where bucket_key in ('expired','d30','d60','d90')
     order by expected_loss desc, days_to_expiry
     limit 25
  loop
    select * into a from public.pharmacy_radar_ask
     where pharmacy_id = v_shop and stock_id = r.stock_id and status = 'open'
     order by created_at desc limit 1;
    v_ask := case when a.id is null then null else public._c425_ask_json(a) end;
    v_items := v_items || jsonb_build_array(public._c425_item_json(r, v_ask));
  end loop;

  select count(*), coalesce(sum(expected_loss),0) into v_n, v_risk
    from public._c425_rows(v_shop)
   where bucket_key in ('expired','d30','d60','d90') and expected_loss > 0;

  select coalesce(sum(coalesce(qty,0) * coalesce(unit_cost,0)),0) into v_stock
    from public.pharmacy_stock where pharmacy_id = v_shop and coalesce(qty,0) > 0;

  select count(*) into v_bills from public.pharmacy_purchase_bill
   where pharmacy_id = v_shop
     and created_at >= date_trunc('month', now() at time zone 'Asia/Kolkata');

  select count(*) into v_wa from public.pharmacy_wa_intake
   where pharmacy_id = v_shop and status <> 'ignored';

  for a in
    select * from public.pharmacy_radar_ask
     where pharmacy_id = v_shop and status = 'open'
     order by expected_loss desc nulls last, created_at desc
     limit coalesce((v_gcfg->>'ask_max_open')::int, 3)
  loop
    v_asks := v_asks || jsonb_build_array(public._c425_ask_json(a));
  end loop;

  select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),
                              '\D','','g'), 10)
    into v_phone from public.pharmacy_profiles pp where pp.id = v_shop;

  return jsonb_build_object(
    'ok', true,
    'title',    public.ui_text('phradar.title'),
    'subtitle', public.ui_text('phradar.subtitle'),
    'headline', case when v_risk > 0
        then public.ui_fmt('phradar.headline',
               jsonb_build_object('value', public.inr_money(v_risk)))
        else public.ui_text('phradar.headline_none') end,
    'headline_note', case when v_risk > 0
        then public.ui_fmt('phradar.headline_note',
               jsonb_build_object('items', v_n::text))
        else public.ui_text('phradar.headline_none_note') end,
    'list_title', public.ui_text('phradar.list_title'),
    'items', v_items,
    'empty', public.ui_text('phradar.empty'),
    'empty_hint', public.ui_text('phradar.empty_hint'),
    'asks_title', public.ui_text('phradar.ask_section'),
    'asks_note',  public.ui_text('phradar.ask_section_note'),
    'asks', v_asks,
    'asks_empty', public.ui_text('phradar.ask_none'),
    'digest', jsonb_build_object(
      'title', public.ui_text('phradar.digest_title'),
      'rows', jsonb_build_array(
        jsonb_build_object('label', public.ui_text('phradar.digest_bills'),
                           'value', v_bills::text),
        jsonb_build_object('label', public.ui_text('phradar.digest_stock'),
                           'value', public.inr_money(v_stock)),
        jsonb_build_object('label', public.ui_text('phradar.digest_risk'),
                           'value', public.inr_money(v_risk)))),
    'optin', jsonb_build_object(
      'title', public.ui_text('phradar.optin_title'),
      'body',  public.ui_fmt('phradar.optin_body',
                 jsonb_build_object('cap', v_cfg.max_msgs_per_week::text)),
      'on', v_cfg.opt_in,
      'state_label', case when v_cfg.opt_in then public.ui_text('phradar.optin_on')
                                            else public.ui_text('phradar.optin_off') end,
      'button', case when v_cfg.opt_in then public.ui_text('phradar.optin_button_off')
                                       else public.ui_text('phradar.optin_button_on') end,
      'can_enable', coalesce(length(v_phone),0) = 10,
      'blocked_message', case when coalesce(length(v_phone),0) = 10 then null
                              else public.ui_text('phradar.optin_no_number') end),
    'intake', jsonb_build_object(
      'title', public.ui_text('phradar.intake_title'),
      'body',  public.ui_text('phradar.intake_body'),
      'count_label', case when v_wa > 0
        then public.ui_fmt('phradar.intake_count', jsonb_build_object('n', v_wa::text))
        else public.ui_text('phradar.intake_none') end,
      'on', v_cfg.wa_intake));
end $$;

create or replace function public.pharmacy_radar_items(
  p_bucket text default null, p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c425_shop(); v_items jsonb := '[]'::jsonb;
        r public.c425_radar_row; v_total integer;
begin
  if v_shop is null then return public._c425_denied(); end if;
  for r in
    select * from public._c425_rows(v_shop)
     where (p_bucket is null or bucket_key = p_bucket)
       and bucket_key in ('expired','d30','d60','d90')
     order by expected_loss desc, days_to_expiry
     limit greatest(coalesce(p_limit,50),1) offset greatest(coalesce(p_offset,0),0)
  loop
    v_items := v_items || jsonb_build_array(public._c425_item_json(r, null));
  end loop;
  select count(*) into v_total from public._c425_rows(v_shop)
   where (p_bucket is null or bucket_key = p_bucket)
     and bucket_key in ('expired','d30','d60','d90');
  return jsonb_build_object('ok', true, 'items', v_items, 'total', v_total,
    'has_more', greatest(coalesce(p_offset,0),0) + jsonb_array_length(v_items) < v_total,
    'empty', public.ui_text('phradar.empty'),
    'empty_hint', public.ui_text('phradar.empty_hint'));
end $$;

create or replace function public.pharmacy_radar_answer(p_ask_id uuid, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c425_shop();
begin
  if v_shop is null then return public._c425_denied(); end if;
  if not exists (select 1 from public.pharmacy_radar_ask
                  where id = p_ask_id and pharmacy_id = v_shop) then
    return jsonb_build_object('ok', false, 'error','no_ask',
                              'message', public.ui_text('phradar.ask_gone'));
  end if;
  return public._c425_apply_answer(p_ask_id, p_qty, 'app');
end $$;

-- In-app one-tap without waiting for a WhatsApp ask: raise the ask, answer it.
create or replace function public.pharmacy_radar_ask_open(p_stock_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c425_shop(); v_id uuid; a public.pharmacy_radar_ask;
begin
  if v_shop is null then return public._c425_denied(); end if;
  v_id := public._c425_ask_open(v_shop, p_stock_id, 'app');
  if v_id is null then
    return jsonb_build_object('ok', false, 'error','no_lot',
                              'message', public.ui_text('phradar.ask_gone'));
  end if;
  select * into a from public.pharmacy_radar_ask where id = v_id;
  return jsonb_build_object('ok', true, 'ask', public._c425_ask_json(a));
end $$;

create or replace function public.pharmacy_radar_config_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c425_shop(); v public.pharmacy_radar_config;
begin
  if v_shop is null then return public._c425_denied(); end if;
  v := public._c425_config(v_shop);
  insert into public.pharmacy_radar_config as c (
    pharmacy_id, opt_in, monthly_digest, urgent_enabled, ask_corrections,
    wa_intake, max_msgs_per_week, min_expected_loss, updated_at)
  values (v_shop,
    coalesce((p_patch->>'opt_in')::boolean, v.opt_in),
    coalesce((p_patch->>'monthly_digest')::boolean, v.monthly_digest),
    coalesce((p_patch->>'urgent_enabled')::boolean, v.urgent_enabled),
    coalesce((p_patch->>'ask_corrections')::boolean, v.ask_corrections),
    coalesce((p_patch->>'wa_intake')::boolean, v.wa_intake),
    greatest(coalesce((p_patch->>'max_msgs_per_week')::int, v.max_msgs_per_week), 1),
    greatest(coalesce((p_patch->>'min_expected_loss')::numeric, v.min_expected_loss), 0),
    now())
  on conflict (pharmacy_id) do update set
    opt_in = excluded.opt_in, monthly_digest = excluded.monthly_digest,
    urgent_enabled = excluded.urgent_enabled, ask_corrections = excluded.ask_corrections,
    wa_intake = excluded.wa_intake, max_msgs_per_week = excluded.max_msgs_per_week,
    min_expected_loss = excluded.min_expected_loss, updated_at = now();
  return public.pharmacy_radar_home();
end $$;

grant execute on function public.pharmacy_radar_entry() to authenticated;
grant execute on function public.pharmacy_radar_home() to authenticated;
grant execute on function public.pharmacy_radar_items(text, integer, integer) to authenticated;
grant execute on function public.pharmacy_radar_answer(uuid, numeric) to authenticated;
grant execute on function public.pharmacy_radar_ask_open(uuid) to authenticated;
grant execute on function public.pharmacy_radar_config_set(jsonb) to authenticated;
grant execute on function public.pharmacy_radar_rebind() to service_role;
