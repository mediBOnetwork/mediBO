-- CHANGE #309 step 7a — DOORSTEP DAMAGE / SHORT CLAIMS -> CREDIT NOTE.
--
-- delivery_partial already recorded a returned quantity, and then that number
-- went nowhere: the customer was still billed for goods they had visibly handed
-- back to the rider. This step turns "3 came back damaged" into money.
--
-- Deliberately NOT a second dispute system. mediBO already has a rich supplier
-- dispute matrix (fw_raise_dispute / fw_resolve_dispute / supplier_disputes) and
-- duplicating it would give two answers to "who owes what". A claim here is a
-- CUSTOMER-side credit against the customer's own bill, and it carries a
-- dispute_id so an admin can link it to the supplier-side case that recovers
-- the cost. The two stay related, not merged.
--
-- Applied before customer_bill is updated, because the bill reads the credits.

create table if not exists public.delivery_claims (
  id            uuid primary key default gen_random_uuid(),
  delivery_id   uuid references public.deliveries(id) on delete set null,
  order_id      uuid not null references public.orders(id) on delete cascade,
  order_item_id uuid,
  product_id    bigint,

  kind          text not null check (kind in ('damaged','short','missing')),
  qty           numeric(12,2) not null default 0,
  amount        numeric(12,2),          -- credit value; null until priced
  note          text,
  photo_path    text not null,          -- evidence is mandatory, see below

  status        text not null default 'open'
                  check (status in ('open','approved','rejected','credited')),
  raised_by     uuid,
  raised_by_role text,
  raised_at     timestamptz not null default now(),
  reviewed_by   uuid,
  reviewed_at   timestamptz,
  reject_reason text,

  -- the EXISTING supplier dispute this claim was escalated to, if any.
  dispute_id    uuid,

  created_at    timestamptz not null default now()
);

create index if not exists idx_delivery_claims_order  on public.delivery_claims(order_id);
create index if not exists idx_delivery_claims_status on public.delivery_claims(status)
  where status in ('open','approved');

-- ── What the bill subtracts ─────────────────────────────────────────────────
-- Only APPROVED and already-CREDITED claims count. An open claim is an
-- allegation, and an allegation must never quietly reduce a tax invoice.
create or replace function public._order_credit_notes(p_order_id uuid)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',     c.id,
           'amount', coalesce(c.amount,0),
           'reason', case c.kind
                       when 'damaged' then public._c('delivery.claim_kind_damaged')
                       when 'short'   then public._c('delivery.claim_kind_short')
                       else                public._c('delivery.claim_kind_missing') end,
           'note',   coalesce(c.note,'')) order by c.raised_at), '[]'::jsonb)
    from public.delivery_claims c
   where c.order_id = p_order_id
     and c.status in ('approved','credited')
     and coalesce(c.amount,0) > 0;
$$;

-- ── Raising a claim at the door ─────────────────────────────────────────────
-- Photo proof is REQUIRED and enforced here rather than in the app, because the
-- app is exactly the layer that gets bypassed by the offline replay path.
create or replace function public.delivery_raise_claim(
  p_delivery_id uuid,
  p_kind        text,
  p_qty         numeric,
  p_photo       text,
  p_note        text default null,
  p_order_item_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  d public.deliveries%rowtype;
  v_role text := coalesce(public.get_my_role(),'none');
  v_is_rider boolean; v_is_cust boolean;
  v_amount numeric; v_id uuid; v_ptr numeric;
begin
  select * into d from public.deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  if coalesce(p_kind,'') not in ('damaged','short','missing') then
    return jsonb_build_object('ok',false,'error','bad_kind');
  end if;

  if nullif(btrim(coalesce(p_photo,'')),'') is null then
    return jsonb_build_object('ok',false,'error','photo_required',
      'message', public._c('delivery.claim_photo_required'));
  end if;

  select exists(select 1 from public.delivery_partner_registrations
                 where id = d.partner_id and user_id = auth.uid()) into v_is_rider;
  select exists(select 1 from public.orders o
                  join public.pharmacy_profiles pp on pp.id = o.customer_id
                 where o.id = d.order_id and pp.user_id = auth.uid()) into v_is_cust;

  if not (v_is_rider or v_is_cust or v_role in ('admin','super_admin')) then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  -- Price the credit off the TRADE rate actually billed for that line, not off
  -- MRP. Left null when the line is not billed yet; an admin prices it then.
  if p_order_item_id is not null then
    select b.ptr into v_ptr
      from public.bill_line_allocations a
      join public.bill_lines b on b.id = a.bill_line_id
     where a.order_item_id = p_order_item_id and b.verified
     order by b.id desc limit 1;
    v_amount := round(coalesce(v_ptr,0) * coalesce(p_qty,0), 2);
    if v_amount = 0 then v_amount := null; end if;
  end if;

  insert into public.delivery_claims(
    delivery_id, order_id, order_item_id, kind, qty, amount, note, photo_path,
    raised_by, raised_by_role)
  values (d.id, d.order_id, p_order_item_id, p_kind, coalesce(p_qty,0), v_amount,
          nullif(btrim(coalesce(p_note,'')),''), btrim(p_photo),
          auth.uid(), case when v_is_rider then 'delivery'
                          when v_is_cust then 'customer' else v_role end)
  returning id into v_id;

  insert into public.delivery_events(delivery_id, order_id, partner_id, event, note, actor)
  values (d.id, d.order_id, d.partner_id, 'claim',
          p_kind || ' x' || trim_scale(coalesce(p_qty,0))::text,
          coalesce(auth.jwt()->>'email','rider'));

  return jsonb_build_object('ok',true,'claim_id',v_id,
    'status','open',
    'message', public._c('delivery.claim_raised'));
end $function$;

-- ── Admin decides ───────────────────────────────────────────────────────────
create or replace function public.admin_claim_decide(
  p_claim_id uuid, p_action text, p_amount numeric default null, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare c public.delivery_claims%rowtype;
begin
  if public.get_my_role() not in ('admin','super_admin') then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;
  select * into c from public.delivery_claims where id = p_claim_id;
  if c.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;
  if c.status <> 'open' then
    return jsonb_build_object('ok',false,'error','already_decided','status',c.status);
  end if;

  if p_action = 'approve' then
    update public.delivery_claims
       set status='approved', amount = coalesce(p_amount, amount),
           reviewed_by=auth.uid(), reviewed_at=now()
     where id = p_claim_id;
  elsif p_action = 'reject' then
    update public.delivery_claims
       set status='rejected', reject_reason=nullif(btrim(coalesce(p_reason,'')),''),
           reviewed_by=auth.uid(), reviewed_at=now()
     where id = p_claim_id;
  else
    return jsonb_build_object('ok',false,'error','bad_action');
  end if;

  return jsonb_build_object('ok',true,'claim_id',p_claim_id,'status',
    (select status from public.delivery_claims where id = p_claim_id));
end $function$;

alter table public.delivery_claims enable row level security;

do $$
begin
  if not exists (select 1 from pg_policies
                  where tablename='delivery_claims' and policyname='delivery_claims_read_own') then
    create policy delivery_claims_read_own on public.delivery_claims
      for select to authenticated
      using (
        public.get_my_role() in ('admin','super_admin')
        or exists (select 1 from public.orders o
                     join public.pharmacy_profiles pp on pp.id = o.customer_id
                    where o.id = delivery_claims.order_id and pp.user_id = auth.uid())
        or exists (select 1 from public.deliveries d
                     join public.delivery_partner_registrations p on p.id = d.partner_id
                    where d.id = delivery_claims.delivery_id and p.user_id = auth.uid()));
  end if;
end $$;

grant select on public.delivery_claims to authenticated;
grant execute on function public.delivery_raise_claim(uuid,text,numeric,text,text,uuid) to authenticated;
grant execute on function public.admin_claim_decide(uuid,text,numeric,text) to authenticated;
