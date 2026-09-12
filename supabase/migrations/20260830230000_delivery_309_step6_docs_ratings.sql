-- CHANGE #309 step 6 — RIDER DOCUMENT EXPIRY, and DELIVERY RATING.
--
-- Two features, one migration, because both feed the same admin dashboard row.
--
-- (6) DOCUMENT EXPIRY. The registration table held an id_doc_path and nothing
-- about when the document stops being valid. An expired driving licence is not
-- an admin inconvenience, it is an uninsured rider carrying scheduled drugs on
-- a public road — so expiry blocks ASSIGNMENT, at the assignment RPCs, and the
-- reminder goes out before it bites rather than after.
--
-- (7) RATING. admin_delivery_dashboard already scored riders on success_rate,
-- which only knows whether a parcel arrived — not whether the person was late,
-- rude, or left it with a stranger. The customer's own rating is the missing
-- half, and it sits beside success_rate rather than replacing it.

-- ── (6) expiry dates ────────────────────────────────────────────────────────
alter table public.delivery_partner_registrations
  add column if not exists dl_number          text,
  add column if not exists dl_expiry          date,
  add column if not exists insurance_number   text,
  add column if not exists insurance_expiry   date,
  add column if not exists rc_number          text,
  add column if not exists rc_expiry          date,
  add column if not exists docs_reminded_at   timestamptz;

create index if not exists idx_dpr_doc_expiry
  on public.delivery_partner_registrations(dl_expiry, insurance_expiry, rc_expiry)
  where is_active;

-- ── The single answer to "are this rider's papers in order" ─────────────────
-- Returns render-ready state AND the machine flag the assignment gate reads, so
-- the chip the admin sees and the rule that blocks assignment can never drift
-- apart — they are the same computation.
create or replace function public.delivery_doc_state(p_partner_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  p public.delivery_partner_registrations%rowtype;
  v_days int := coalesce((public._dcfg(null)->>'doc_expiry_remind_days')::int, 30);
  v_blocks boolean := coalesce((public._dcfg(null)->>'doc_expiry_blocks')::boolean, true);
  v_today date := (now() at time zone 'Asia/Kolkata')::date;
  v_docs jsonb; v_expired text[]; v_soon text[];
begin
  select * into p from public.delivery_partner_registrations where id = p_partner_id;
  if p.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  select jsonb_agg(x order by x->>'label'),
         array_remove(array_agg(case when (x->>'state')='expired'  then x->>'label' end), null),
         array_remove(array_agg(case when (x->>'state')='expiring' then x->>'label' end), null)
    into v_docs, v_expired, v_soon
  from (
    select jsonb_build_object(
      'key', d.key,
      'label', d.label,
      'number', coalesce(d.num,''),
      'expiry', d.exp,
      'expiry_label', case when d.exp is null then ''
                           else to_char(d.exp,'DD Mon YYYY') end,
      -- 'missing' is deliberately NOT 'expired': we have not been told the
      -- date, which is a data-entry gap, not proof the rider is unlawful.
      'state', case when d.exp is null              then 'missing'
                    when d.exp <  v_today           then 'expired'
                    when d.exp <= v_today + v_days  then 'expiring'
                    else 'valid' end,
      'chip',  case when d.exp is null              then ''
                    when d.exp <  v_today           then public._c('delivery.doc_expired_chip')
                    when d.exp <= v_today + v_days  then public._c('delivery.doc_expiring_chip')
                    else public._c('delivery.doc_ok_chip') end,
      'chip_colors', case when d.exp is null             then jsonb_build_object('bg','#EFF6FF','fg','#1E40AF')
                          when d.exp <  v_today          then jsonb_build_object('bg','#FEE2E2','fg','#991B1B')
                          when d.exp <= v_today + v_days then jsonb_build_object('bg','#FEF3C7','fg','#92400E')
                          else jsonb_build_object('bg','#D1FAE5','fg','#065F46') end
    ) x
    from (values
      ('dl',        public._c('delivery.doc_dl_label'),        p.dl_number,        p.dl_expiry),
      ('insurance', public._c('delivery.doc_insurance_label'), p.insurance_number, p.insurance_expiry),
      ('rc',        public._c('delivery.doc_rc_label'),        p.rc_number,        p.rc_expiry)
    ) d(key, label, num, exp)
  ) s;

  return jsonb_build_object(
    'ok', true,
    'partner_id', p_partner_id,
    'partner_name', coalesce(p.full_name,''),
    'docs', coalesce(v_docs,'[]'::jsonb),
    'expired_count', coalesce(array_length(v_expired,1),0),
    'expiring_count', coalesce(array_length(v_soon,1),0),
    'has_expired', (coalesce(array_length(v_expired,1),0) > 0),
    -- the gate. blocks only when config says it should.
    'blocks_assignment', (v_blocks and coalesce(array_length(v_expired,1),0) > 0),
    'block_title', public._c('delivery.doc_blocked_title'),
    'block_message', case when coalesce(array_length(v_expired,1),0) > 0
      then public._cf('delivery.doc_blocked_msg', jsonb_build_object(
             'name', coalesce(p.full_name,''),
             'docs', array_to_string(v_expired, ', ')))
      else '' end,
    'remind_message', case when coalesce(array_length(v_soon,1),0) > 0
      then public._cf('delivery.doc_remind_msg', jsonb_build_object(
             'docs', array_to_string(v_soon, ', '),
             -- The soonest date among the docs that are EXPIRING, not the
             -- soonest date overall: an already-expired licence has the
             -- earliest date of all and would otherwise be quoted next to the
             -- name of a document that has not expired at all.
             'date', to_char((select min(e) from (values
                        (p.dl_expiry), (p.insurance_expiry), (p.rc_expiry)
                      ) t(e) where e is not null and e >= v_today), 'DD Mon YYYY')))
      else '' end);
end $function$;

create or replace function public.admin_set_partner_docs(
  p_partner_id uuid,
  p_dl_number text default null, p_dl_expiry date default null,
  p_insurance_number text default null, p_insurance_expiry date default null,
  p_rc_number text default null, p_rc_expiry date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  update public.delivery_partner_registrations
     set dl_number        = coalesce(nullif(btrim(coalesce(p_dl_number,'')),''), dl_number),
         dl_expiry        = coalesce(p_dl_expiry, dl_expiry),
         insurance_number = coalesce(nullif(btrim(coalesce(p_insurance_number,'')),''), insurance_number),
         insurance_expiry = coalesce(p_insurance_expiry, insurance_expiry),
         rc_number        = coalesce(nullif(btrim(coalesce(p_rc_number,'')),''), rc_number),
         rc_expiry        = coalesce(p_rc_expiry, rc_expiry)
   where id = p_partner_id;
  return public.delivery_doc_state(p_partner_id);
end $function$;

-- ── The reminder, on the ONE dispatcher ─────────────────────────────────────
-- Registered as a cron_task row rather than a bare pg_cron */N schedule: the
-- August 18 outage was 35 jobs all starting on minute 0 and starving the
-- 60-connection cap. 09:10 IST = 03:40 UTC, off the hour, once a day.
create or replace function public.delivery_docs_remind_tick()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r record; v_n int := 0; v_state jsonb;
begin
  for r in
    select id from public.delivery_partner_registrations
     where is_active and coalesce(is_deleted,false) = false
       and (docs_reminded_at is null or docs_reminded_at < now() - interval '7 days')
       and (dl_expiry is not null or insurance_expiry is not null or rc_expiry is not null)
     limit 200
  loop
    v_state := public.delivery_doc_state(r.id);
    if coalesce((v_state->>'expiring_count')::int,0) > 0
       or coalesce((v_state->>'expired_count')::int,0) > 0 then
      insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
      values (null, null, r.id, 'doc_reminder',
              coalesce(nullif(v_state->>'remind_message',''), v_state->>'block_message'), 'system');
      update public.delivery_partner_registrations set docs_reminded_at = now() where id = r.id;
      v_n := v_n + 1;
    end if;
  end loop;
  return jsonb_build_object('ok',true,'reminded',v_n);
end $function$;

-- 09:10 IST, once a day, on the ONE dispatcher (CHANGE #273). Deliberately not
-- an on-the-hour slot: the 18 August outage was 35 pg_cron jobs all firing on
-- minute 0 and taking every one of the 60 connection slots.
insert into public.cron_task(name, ord, mode, work_sql, enabled, run_at_ist, note)
select 'delivery_docs_remind', 945, 'poll',
       'select public.delivery_docs_remind_tick()', true, '09:10:00'::time,
       'CHANGE #309 — warns riders before a licence/insurance/RC expires and blocks assignment.'
where not exists (select 1 from public.cron_task where name = 'delivery_docs_remind');

-- ── (7) delivery rating ─────────────────────────────────────────────────────
create table if not exists public.delivery_ratings (
  id          uuid primary key default gen_random_uuid(),
  delivery_id uuid not null references public.deliveries(id) on delete cascade,
  order_id    uuid,
  partner_id  uuid,
  customer_id uuid,
  stars       smallint not null check (stars between 1 and 5),
  comment     text,
  created_at  timestamptz not null default now(),
  -- one rating per delivery: a customer rates the drop, not the day.
  unique (delivery_id)
);

create index if not exists idx_delivery_ratings_partner
  on public.delivery_ratings(partner_id, created_at desc);

create or replace function public.delivery_rate(
  p_delivery_id uuid, p_stars smallint, p_comment text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare d public.deliveries%rowtype; v_cust uuid;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  select pp.id into v_cust
    from public.orders o join public.pharmacy_profiles pp on pp.id = o.customer_id
   where o.id = d.order_id and pp.user_id = auth.uid();

  if v_cust is null and public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  if d.status <> 'delivered' then
    return jsonb_build_object('ok',false,'error','not_delivered',
      'message', public._c('delivery.rate_not_delivered'));
  end if;

  if p_stars is null or p_stars < 1 or p_stars > 5 then
    return jsonb_build_object('ok',false,'error','bad_stars');
  end if;

  insert into public.delivery_ratings(delivery_id, order_id, partner_id, customer_id, stars, comment)
  values (p_delivery_id, d.order_id, d.partner_id, v_cust, p_stars,
          nullif(btrim(coalesce(p_comment,'')),''))
  on conflict (delivery_id) do nothing;

  if not found then
    return jsonb_build_object('ok',false,'error','already_rated',
      'message', public._c('delivery.rate_already'));
  end if;

  return jsonb_build_object('ok',true,'stars',p_stars,
    'message', public._c('delivery.rate_thanks'));
end $function$;

-- ── What the customer's rating card renders ─────────────────────────────────
create or replace function public.delivery_rating_prompt(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare d public.deliveries%rowtype; v_rated boolean;
begin
  select * into d from public.deliveries
   where order_id = p_order_id and status = 'delivered'
   order by delivered_at desc limit 1;

  if d.id is null then return jsonb_build_object('show', false); end if;

  select exists(select 1 from public.delivery_ratings where delivery_id = d.id) into v_rated;

  return jsonb_build_object(
    'show', not v_rated,
    'delivery_id', d.id,
    'title',        public._c('delivery.rate_title'),
    'hint',         public._c('delivery.rate_hint'),
    'comment_hint', public._c('delivery.rate_comment_hint'),
    'submit_label', public._c('delivery.rate_submit'),
    'already_label',public._c('delivery.rate_already'),
    'rated', v_rated);
end $function$;

alter table public.delivery_ratings enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies
                  where tablename='delivery_ratings' and policyname='delivery_ratings_read') then
    create policy delivery_ratings_read on public.delivery_ratings
      for select to authenticated
      using (public.get_my_role() in ('admin','super_admin')
             or exists (select 1 from public.pharmacy_profiles pp
                         where pp.id = delivery_ratings.customer_id and pp.user_id = auth.uid())
             or exists (select 1 from public.delivery_partner_registrations p
                         where p.id = delivery_ratings.partner_id and p.user_id = auth.uid()));
  end if;
end $$;

grant select on public.delivery_ratings to authenticated;
grant execute on function public.delivery_doc_state(uuid) to authenticated;
grant execute on function public.delivery_rate(uuid,smallint,text) to authenticated;
grant execute on function public.delivery_rating_prompt(uuid) to authenticated;
grant execute on function public.admin_set_partner_docs(uuid,text,date,text,date,text,date) to authenticated;
