-- CHANGE #354 — feature_gaps row 87 (surface delivery / step "earnings", critical)
--
-- admin_payout_open() (CHANGE #309) builds every payout line from
-- `coalesce(d.earning,0)`. Nothing in the database ever wrote deliveries.earning:
-- no default, not generated, no trigger, and the only four functions that mention
-- the word merely READ it. The #309 migration header states "deliveries.earning
-- already computed what each drop earns" — it never did. Meanwhile the rider's own
-- screens showed round(delivered_count * per_drop_rate, 2), a completely different
-- formula. So the rider saw a real figure and the payout run would have paid ZERO.
--
-- Fix, in three parts:
--   1. a rate resolver — partner.per_drop_rate, else app_settings
--      delivery_per_drop_rate — the SAME resolution my_delivery_home already used;
--   2. a trigger that stamps deliveries.earning the moment a drop becomes
--      'delivered'. A trigger, not a line inside _delivery_complete, so every path
--      into 'delivered' (OTP, QR, signature, photo, partial, offline replay, an
--      admin correction) stamps it — there is no second door;
--   3. the rider screens now SUM the stamped column, so the screen and the payout
--      statement read one source instead of agreeing by coincidence.
-- Plus a backfill for any already-delivered row.
-- Proof: rg behaviour test `delivery_earning_stamped`.

-- 1 ─────────────────────────────────────────────────────────────────────────
create or replace function public._delivery_drop_rate(p_partner uuid)
 RETURNS numeric
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select r.per_drop_rate from public.delivery_partner_registrations r where r.id = p_partner),
    (select (value #>> '{}')::numeric from public.app_settings where key = 'delivery_per_drop_rate'),
    0);
$function$;

-- 2 ─────────────────────────────────────────────────────────────────────────
create or replace function public.trg_delivery_stamp_earning()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  -- Stamp once, on the transition into 'delivered'. Never restamp: a payout line
  -- already cut against this row must not silently change amount underneath it.
  if new.status = 'delivered'
     and (tg_op = 'INSERT' or old.status is distinct from 'delivered')
     and new.earning is null then
    new.earning := round(public._delivery_drop_rate(new.partner_id), 2);
  end if;
  return new;
end $function$;

drop trigger if exists trg_delivery_stamp_earning on public.deliveries;
create trigger trg_delivery_stamp_earning
  before insert or update on public.deliveries
  for each row execute function public.trg_delivery_stamp_earning();

-- backfill — idempotent, and a no-op once every delivered row carries a figure
update public.deliveries d
   set earning = round(public._delivery_drop_rate(d.partner_id), 2)
 where d.status = 'delivered' and d.earning is null;

-- 3 ─────────────────────────────────────────────────────────────────────────
create or replace function public.my_delivery_home(p_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  p delivery_partner_registrations%rowtype; v_date date; v_rate numeric;
  v_del int; v_fail int; v_pend int; v_km numeric; v_on boolean; v_since timestamptz;
  v_earn numeric;
begin
  select * into p from delivery_partner_registrations
   where user_id = auth.uid() and is_active and coalesce(is_deleted,false)=false limit 1;
  if p.id is null then
    return jsonb_build_object('allowed',false,'is_partner',false,
      'empty_title','Not a delivery account',
      'empty_note','This login is not an active delivery partner.');
  end if;
  v_date := coalesce(p_date,(now() at time zone 'Asia/Kolkata')::date);
  v_rate := public._delivery_drop_rate(p.id);

  select count(*) filter (where d.status='delivered'),
         count(*) filter (where d.status='failed'),
         count(*) filter (where d.status in ('assigned','out_for_delivery')),
         round(coalesce(sum(d.leg_km),0),1),
         -- CHANGE #354 (row 87): the STAMPED column, the same one every payout
         -- line is cut from. Never re-derive it as delivered_count * rate here —
         -- that is how the screen and the statement drifted apart.
         round(coalesce(sum(d.earning) filter (where d.status='delivered'),0),2)
    into v_del, v_fail, v_pend, v_km, v_earn
  from deliveries d join delivery_runs r on r.id = d.run_id
  where d.partner_id = p.id and r.run_date = v_date;

  select (s.ended_at is null), s.started_at into v_on, v_since
  from delivery_partner_shifts s
  where s.partner_id = p.id and s.shift_date = v_date
  order by s.started_at desc limit 1;

  return jsonb_build_object(
    'allowed', true, 'is_partner', true,
    'partner_id', p.id, 'partner_name', coalesce(p.full_name,''),
    'partner_type', p.partner_type, 'is_agency', (p.partner_type='agency'),
    'zone_id', p.zone_id,
    'zone_label', coalesce((select z.name from zones z where z.id=p.zone_id),''),
    'the_date', v_date,
    'on_shift', coalesce(v_on,false),
    'shift_since', v_since,
    'shift_button_label', case when coalesce(v_on,false) then 'End shift' else 'Start shift' end,
    'shift_action', case when coalesce(v_on,false) then 'end' else 'start' end,
    'tiles', jsonb_build_array(
       jsonb_build_object('key','delivered','label','Delivered','value',coalesce(v_del,0),
                          'colors', jsonb_build_object('bg','#E1F5EE','fg','#0F6E56')),
       jsonb_build_object('key','pending','label','Pending','value',coalesce(v_pend,0),
                          'colors', jsonb_build_object('bg','#FEF3C7','fg','#92400E')),
       jsonb_build_object('key','failed','label','Failed','value',coalesce(v_fail,0),
                          'colors', jsonb_build_object('bg','#FBE9E7','fg','#B42318')),
       jsonb_build_object('key','distance','label','Distance','value',coalesce(v_km,0),
                          'display', coalesce(v_km,0)::text || ' km',
                          'colors', jsonb_build_object('bg','#E6F1FB','fg','#0C447C'))),
    'earning_today', coalesce(v_earn,0),
    'earning_today_display', public.inr_money(coalesce(v_earn,0)),
    'per_drop_display', public.inr_money(v_rate) || ' per delivery');
end $function$;

create or replace function public.my_delivery_history(p_days integer DEFAULT 14)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare p delivery_partner_registrations%rowtype; v_rows jsonb;
begin
  select * into p from delivery_partner_registrations
   where user_id = auth.uid() and is_active and coalesce(is_deleted,false)=false limit 1;
  if p.id is null then return jsonb_build_object('allowed',false,'days','[]'::jsonb); end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'the_date', d.run_date,
      'date_label', to_char(d.run_date,'DD Mon'),
      'delivered', d.del, 'failed', d.fai, 'total', d.tot,
      -- CHANGE #354 (row 87): stamped earning, summed. Same source as the payout.
      'earning', d.earn,
      'earning_display', public.inr_money(d.earn)) order by d.run_date desc), '[]'::jsonb)
    into v_rows
  from (
    select r.run_date,
           count(*) filter (where x.status='delivered')::int del,
           count(*) filter (where x.status='failed')::int fai,
           count(*)::int tot,
           round(coalesce(sum(x.earning) filter (where x.status='delivered'),0),2) earn
    from deliveries x join delivery_runs r on r.id = x.run_id
    where x.partner_id = p.id
      and r.run_date >= (now() at time zone 'Asia/Kolkata')::date - greatest(coalesce(p_days,14),1)
    group by r.run_date) d;

  return jsonb_build_object('allowed',true,'days',v_rows,
    'title','Last ' || greatest(coalesce(p_days,14),1) || ' days');
end $function$;
