-- CHANGE #307 — QA round 2 fix (2 of 2): the partner row guard must trust the
-- PARENT ORDER's zone, not the child row's denormalised copy.
--
-- FINDING (high, c307_partner_guard_proof check "write grant + wrong zone"):
-- partner_row_guard() read zone_id off the row itself and only fell back to the
-- parent order when that column was NULL. order_items (and every other
-- order-child table) carries its own denormalised zone_id, which is stamped at
-- insert time and does NOT follow the order if the order is later moved to
-- another zone. A zone-1 partner holding a 'write' grant could therefore still
-- write rows belonging to an order that now sits in zone 2 — exactly the hole
-- the proof caught. Reading the child's stale copy is reading the attacker's
-- side of the join.
--
-- Fix: when the row has an order_id, the parent order's zone is AUTHORITATIVE
-- and must match the partner's zone. The row's own zone_id, when present, must
-- match too — so drift in either direction is refused rather than silently
-- picking the permissive side. A row with no resolvable zone stays refused
-- (deny by default), and every non-partner caller still short-circuits out on
-- line one, so this is a strict no-op for admin / super_admin / worker / cron.
--
-- Idempotent: create or replace only; the existing triggers keep pointing here.

create or replace function public.partner_row_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare
  v_feature text := TG_ARGV[0];
  v_row     record;
  v_row_zone  smallint;
  v_order_id  uuid;
  v_ord_zone  smallint;
  v_zone      smallint;
  v_mine      smallint;
  v_acc       text;
begin
  -- Non-partners are untouched. This must stay the first statement.
  if not public.is_partner() then
    if TG_OP = 'DELETE' then return OLD; else return NEW; end if;
  end if;

  if TG_OP = 'DELETE' then v_row := OLD; else v_row := NEW; end if;

  begin v_row_zone := (to_jsonb(v_row) ->> 'zone_id')::smallint;
  exception when others then v_row_zone := null; end;

  begin v_order_id := (to_jsonb(v_row) ->> 'order_id')::uuid;
  exception when others then v_order_id := null; end;

  if v_order_id is not null then
    select o.zone_id into v_ord_zone from orders o where o.id = v_order_id;
  end if;

  -- The parent order wins. Only a row with no order at all falls back to its
  -- own column.
  v_zone := coalesce(v_ord_zone, v_row_zone);
  v_mine := public.my_zone_id();

  if v_zone is null or v_mine is null or v_zone <> v_mine then
    raise exception 'not_authorized_zone';
  end if;

  -- Drift check: a child row whose own copy disagrees with its order is refused
  -- outright rather than resolved to whichever side lets the write through.
  if v_ord_zone is not null and v_row_zone is not null and v_row_zone <> v_ord_zone then
    raise exception 'not_authorized_zone';
  end if;

  v_acc := public.partner_access(v_feature);
  if v_acc <> 'write' then
    raise exception 'not_authorized_write';
  end if;

  if TG_OP = 'DELETE' then return OLD; else return NEW; end if;
end $$;

comment on function public.partner_row_guard() is
  'CHANGE #307 partner write guard. Fires BEFORE INSERT/UPDATE/DELETE on every '
  'partner-writable fulfilment table with the feature_key as TG_ARGV[0]. '
  'No-op for non-partners. For a partner: the PARENT ORDER''s zone is '
  'authoritative (a stale denormalised child zone_id can never widen access), '
  'and the feature grant must be write.';
