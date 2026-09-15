-- CMD #1889 — "Customers needing licence", and the order block that follows it.
--
-- Three approved customers are trading with no drug licence on file. They get a
-- named list inside KYC review, and until a licence is verified their order is
-- refused by the BACKEND with the backend's own sentence. Flutter checks
-- nothing: the refusal arrives in my_session().order_gate exactly like every
-- other reason, and _place_order_v2_core already raises on it.

-- ── the copy ──────────────────────────────────────────────────────────────
insert into public.app_settings(key, value)
values ('order_gate_copy', '{}'::jsonb)
on conflict (key) do nothing;

update public.app_settings
   set value = value || jsonb_build_object('licence_required', jsonb_build_object(
         'title',        'Upload drug licence to order',
         'message',      'Ordering opens as soon as your drug licence is uploaded and verified.',
         'action_label', 'Upload licence',
         'action_route', '/documents',
         'short_label',  'Licence needed'))
 where key = 'order_gate_copy'
   and value->'licence_required' is null;

-- the switch, so the block is data and not a deploy
insert into public.app_settings(key, value)
values ('licence_order_gate', jsonb_build_object('enabled', true,
        'block_states', jsonb_build_array('missing','rejected','expired')))
on conflict (key) do nothing;

insert into public.ui_copy(key, value) values
  ('kyc_backfill.title',        '"Customers needing licence"'::jsonb),
  ('kyc_backfill.subtitle',     '"Approved customers with no verified drug licence. They cannot order until one is on file."'::jsonb),
  ('kyc_backfill.empty',        '"Every approved customer has a licence on file."'::jsonb),
  ('kyc_backfill.count_one',    '"1 customer"'::jsonb),
  ('kyc_backfill.count_many',   '"{n} customers"'::jsonb),
  ('kyc_backfill.ask_label',    '"Ask for licence"'::jsonb),
  ('kyc_backfill.asked_toast',  '"Asked for the licence over WhatsApp."'::jsonb),
  ('kyc_backfill.asked_label',  '"Asked {d}"'::jsonb),
  ('kyc_backfill.state_missing','"No licence uploaded"'::jsonb),
  ('kyc_backfill.state_pending','"Licence waiting for review"'::jsonb),
  ('kyc_backfill.state_rejected','"Licence rejected"'::jsonb),
  ('kyc_backfill.state_expired','"Licence expired"'::jsonb),
  ('kyc_backfill.err_no_customer','"That customer is not on this list."'::jsonb),
  ('kyc_expiry.title',          '"Licence expiry"'::jsonb),
  ('kyc_expiry.read_label',     '"Read from the licence"'::jsonb),
  ('kyc_expiry.none_label',     '"Nothing read — type the date"'::jsonb),
  ('kyc_expiry.field_label',    '"Expiry date"'::jsonb),
  ('kyc_expiry.number_label',   '"Licence number"'::jsonb),
  ('kyc_expiry.reason_label',   '"Why are you changing it?"'::jsonb),
  ('kyc_expiry.reason_hint',    '"A date that does not match the read needs a reason."'::jsonb),
  ('kyc_expiry.save_label',     '"Save expiry"'::jsonb),
  ('kyc_expiry.edit_label',     '"Set expiry"'::jsonb),
  ('kyc_expiry.saved_manual',   '"Expiry saved with your reason."'::jsonb),
  ('kyc_expiry.saved_confirm',  '"Expiry confirmed."'::jsonb),
  ('kyc_expiry.err_no_expiry',  '"Enter an expiry date."'::jsonb),
  ('kyc_expiry.err_bad_expiry', '"That date is too far in the past."'::jsonb),
  ('kyc_expiry.err_no_reason',  '"Give a reason for the date you typed."'::jsonb)
on conflict (key) do nothing;

-- ── the list ──────────────────────────────────────────────────────────────
-- Zone- and date-scoped: admin_active_zone() (null = all zones for a super
-- admin, the partner's own zone for a partner) and admin_active_date() as the
-- "as at" day the list is judged on.
create or replace function public.kyc_licence_backfill(
  p_limit integer default 50, p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_zone int  := public.admin_active_zone();
  v_date date := public.admin_active_date();
  v_lim int   := least(greatest(coalesce(p_limit,50),1), 200);
  v_off int   := greatest(coalesce(p_offset,0),0);
  v_rows jsonb; v_total int;
begin
  if not public.kyc_can_review('read') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._c('kyc_review.err_not_authorized'));
  end if;

  with base as (
    select p.id, p.pharmacy_name, p.city, p.phone, p.whatsapp_no, p.zone_id,
           p.created_at, p.dl_expiry,
           public.kyc_state('pharmacy', p.id) as st
      from public.pharmacy_profiles p
     where coalesce(p.approved,false) = true
       and lower(coalesce(p.status,'')) <> 'suspended'
       and coalesce(p.is_synthetic,false) = false
       and (v_zone is null or p.zone_id = v_zone)
       and (p.created_at at time zone 'Asia/Kolkata')::date <= v_date
  ), needing as (
    select b.*, (b.st->>'state') as state
      from base b
     where (b.st->>'state') is distinct from 'verified'
  ), counted as (
    select count(*)::int as n from needing
  )
  select (select n from counted),
         coalesce(jsonb_agg(row_to_json(x)::jsonb order by x.ord), '[]'::jsonb)
    into v_total, v_rows
  from (
    select n.id::text as customer_id,
           coalesce(nullif(btrim(n.pharmacy_name),''), '—') as name,
           coalesce(nullif(btrim(n.city),''), '') as city,
           n.state,
           public._c('kyc_backfill.state_'||n.state) as state_label,
           case n.state when 'pending' then 'warning' when 'expired' then 'danger'
                        when 'rejected' then 'danger' else 'neutral' end as state_tone,
           public._c('kyc_backfill.ask_label') as ask_label,
           case when r.sent_at is null then ''
                else public.ui_fmt('kyc_backfill.asked_label',
                       jsonb_build_object('d', to_char(r.sent_at at time zone 'Asia/Kolkata','DD/MM/YYYY')))
           end as asked_label,
           coalesce(n.zone_id, 0) as zone_id,
           row_number() over (order by n.created_at) as ord
      from needing n
      left join lateral (
        select max(l.created_at) as sent_at from public.kyc_backfill_ask l
         where l.customer_id = n.id) r on true
     order by n.created_at
     limit v_lim offset v_off
  ) x;

  return jsonb_build_object('ok', true,
    'title',    public._c('kyc_backfill.title'),
    'subtitle', public._c('kyc_backfill.subtitle'),
    'empty',    public._c('kyc_backfill.empty'),
    'count_label', case when v_total = 1 then public._c('kyc_backfill.count_one')
                        else public.ui_fmt('kyc_backfill.count_many',
                               jsonb_build_object('n', v_total::text)) end,
    'total',    v_total,
    'has_more', (v_off + v_lim) < v_total,
    'zone_id',  v_zone,
    'as_at',    v_date,
    'can_write', public.kyc_can_review('write'),
    'rows',     coalesce(v_rows, '[]'::jsonb));
end $fn$;

create table if not exists public.kyc_backfill_ask (
  id          bigserial primary key,
  customer_id uuid not null references public.pharmacy_profiles(id) on delete cascade,
  asked_by    uuid,
  zone_id     smallint,
  created_at  timestamptz not null default now()
);
create index if not exists kyc_backfill_ask_cust_idx on public.kyc_backfill_ask(customer_id, created_at desc);
alter table public.kyc_backfill_ask enable row level security;

create or replace function public.kyc_licence_ask(p_customer_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare p public.pharmacy_profiles%rowtype; v_zone int := public.admin_active_zone();
begin
  if not public.kyc_can_review('write') then
    return jsonb_build_object('ok', false, 'error','not_authorized', 'tone','danger',
      'message', public._c('kyc_review.err_not_authorized'));
  end if;
  select * into p from public.pharmacy_profiles where id = p_customer_id;
  if not found or (v_zone is not null and coalesce(p.zone_id,-1) <> v_zone) then
    return jsonb_build_object('ok', false, 'error','no_customer', 'tone','danger',
      'message', public._c('kyc_backfill.err_no_customer'));
  end if;
  begin
    perform public.wa_send_event('kyc_backfill_request', p.id,
      jsonb_build_object('name', coalesce(p.pharmacy_name,''),
                         'label', public._c('kyc.kind.drug_licence'),
                         'link', 'https://medibo.in/'),
      coalesce(nullif(p.whatsapp_no,''), p.phone), null);
  exception when others then null;
  end;
  insert into public.kyc_backfill_ask(customer_id, asked_by, zone_id)
  values (p.id, auth.uid(), p.zone_id);
  return jsonb_build_object('ok', true, 'tone','success',
    'message', public._c('kyc_backfill.asked_toast'));
end $fn$;

revoke all on function public.kyc_licence_backfill(integer, integer) from public;
grant execute on function public.kyc_licence_backfill(integer, integer) to authenticated;
revoke all on function public.kyc_licence_ask(uuid) from public;
grant execute on function public.kyc_licence_ask(uuid) to authenticated;

-- ── the block: one more reason in the ONE gate everything already reads ────
create or replace function public.licence_order_block(p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_cfg jsonb := coalesce((select value from app_settings where key='licence_order_gate'),
                          '{"enabled":true,"block_states":["missing","rejected","expired"]}'::jsonb);
  v_states text[] := coalesce((select array_agg(x #>> '{}')
                                 from jsonb_array_elements(coalesce(v_cfg->'block_states','[]'::jsonb)) x),
                              array['missing','rejected','expired']);
  v_st jsonb; v_state text;
begin
  if p_customer_id is null or not coalesce((v_cfg->>'enabled')::boolean, true) then
    return jsonb_build_object('blocked', false, 'state', '');
  end if;
  if coalesce((select is_synthetic from pharmacy_profiles where id = p_customer_id), false) then
    return jsonb_build_object('blocked', false, 'state', 'synthetic');
  end if;
  v_st := public.kyc_state('pharmacy', p_customer_id);
  v_state := coalesce(v_st->>'state','');
  return jsonb_build_object('blocked', v_state = any (v_states), 'state', v_state);
end $fn$;
create or replace function public.licence_order_block(p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_cfg jsonb := coalesce((select value from app_settings where key='licence_order_gate'),
                          '{"enabled":true,"block_states":["missing","rejected","expired"]}'::jsonb);
  v_states text[] := coalesce((select array_agg(x #>> '{}')
                                 from jsonb_array_elements(coalesce(v_cfg->'block_states','[]'::jsonb)) x),
                              array['missing','rejected','expired']);
  v_st jsonb; v_state text; v_grace boolean;
begin
  if p_customer_id is null or not coalesce((v_cfg->>'enabled')::boolean, true) then
    return jsonb_build_object('blocked', false, 'state', '');
  end if;
  if coalesce((select is_synthetic from pharmacy_profiles where id = p_customer_id), false) then
    return jsonb_build_object('blocked', false, 'state', 'synthetic');
  end if;
  v_st    := public.kyc_state('pharmacy', p_customer_id);
  v_state := coalesce(v_st->>'state','');
  -- The KYC grace window is the ONE place that decides how long an account that
  -- predates enforcement may keep trading. This gate honours it rather than
  -- inventing a second answer: an account inside grace is warned, never refused.
  v_grace := coalesce((v_st->>'in_grace')::boolean, false);
  return jsonb_build_object(
    'blocked',  (v_state = any (v_states)) and not v_grace,
    'state',    v_state,
    'in_grace', v_grace);
end $fn$;
