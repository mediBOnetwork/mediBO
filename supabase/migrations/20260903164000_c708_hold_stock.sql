-- CHANGE #708 (5/6) — the stock a parked order is still holding.
--
-- A hold keeps the collected stock exactly where it is — that is the point.
-- But a bag full of somebody else's Amoxycillin sitting on the shelf for two
-- weeks is a real cost, so the partner can see WHAT is reserved and release it
-- back on purpose, with a reason. 'released' is already one of the three states
-- bag_allocations.state allows, so releasing is a state change and never a
-- DELETE: the row is the audit trail of what was reserved and why it went back.
--
-- Idempotent throughout.

create table if not exists public.order_hold_release (
  id          bigint primary key generated always as identity,
  order_id    uuid not null references public.orders(id) on delete cascade,
  hold_id     bigint references public.order_hold(id) on delete set null,
  lines       int not null default 0,
  qty_total   numeric not null default 0,
  reason      text,
  released_by uuid,
  released_by_label text,
  created_at  timestamptz not null default now()
);

comment on table public.order_hold_release is
  'CHANGE #708 — one row per deliberate release of the stock a held order was '
  'reserving. The bag_allocations rows are flipped to state=released, never '
  'deleted, so both halves of the story survive.';

create index if not exists order_hold_release_order_idx
  on public.order_hold_release (order_id, created_at desc);

alter table public.order_hold_release enable row level security;

insert into public.ui_copy (key, value) values
  ('order_hold.stock_heading',   to_jsonb('Stock reserved for this order'::text)),
  ('order_hold.stock_empty',     to_jsonb('No collected stock is reserved for this order.'::text)),
  ('order_hold.stock_line',      to_jsonb('{qty} × {name}'::text)),
  ('order_hold.stock_bag',       to_jsonb('Bag {bag}'::text)),
  ('order_hold.stock_total',     to_jsonb('{n} line(s) · {qty} units reserved'::text)),
  ('order_hold.release_note',    to_jsonb('Releasing puts the stock back on the shelf. The order stays on hold and will be re-collected when it resumes.'::text)),
  ('order_hold.err_release_reason', to_jsonb('Please say why you are releasing it.'::text)),
  ('order_hold.err_release_hold',   to_jsonb('Only a held order can have its stock released.'::text)),
  ('order_hold.err_release_staff',  to_jsonb('Only mediBO staff can release reserved stock.'::text)),
  ('order_hold.err_release_none',   to_jsonb('There is nothing reserved to release.'::text))
on conflict (key) do nothing;

-- ── what is reserved ──────────────────────────────────────────────────────
create or replace function public.order_hold_stock(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  v_act jsonb := public._c708_actor(p_order_id);
  v_state jsonb := public.order_hold_state(p_order_id);
  v_rows jsonb; v_lines int := 0; v_qty numeric := 0;
begin
  if not coalesce((v_act->>'has')::boolean,false) then
    return jsonb_build_object('ok', false, 'error','not_yours',
      'message', _c('order_hold.err_not_yours'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'alloc_id', ba.id,
           'product_id', ba.product_id,
           'name', coalesce(nullif(btrim(oi.product_name),''), m.product_name, ''),
           'qty', ba.qty,
           'bag_no', ba.bag_no,
           'bag_label', _cf('order_hold.stock_bag',
                          jsonb_build_object('bag', coalesce(ba.bag_no::text,'—'))),
           'supplier', coalesce(ba.assigned_supplier,''),
           'line', _cf('order_hold.stock_line', jsonb_build_object(
                     'qty', rtrim(rtrim(to_char(ba.qty,'FM999999990.99'),'0'),'.'),
                     'name', coalesce(nullif(btrim(oi.product_name),''), m.product_name, '')))
         ) order by ba.bag_no nulls last, ba.id), '[]'::jsonb),
         count(*)::int, coalesce(sum(ba.qty),0)
    into v_rows, v_lines, v_qty
    from bag_allocations ba
    left join order_items oi on oi.id = ba.order_item_id
    left join "MEDICINE" m on m.id = ba.product_id
   where ba.order_id = p_order_id and ba.state = 'reserved';

  return jsonb_build_object(
    'ok', true,
    'heading', _c('order_hold.stock_heading'),
    'empty_note', _c('order_hold.stock_empty'),
    'release_label', _c('order_hold.stock_release'),
    'release_reason_label', _c('order_hold.release_reason'),
    'release_note', _c('order_hold.release_note'),
    'has', (v_lines > 0),
    'lines', v_lines,
    'qty_total', v_qty,
    'total_label', _cf('order_hold.stock_total',
                     jsonb_build_object('n', v_lines::text,
                                        'qty', rtrim(rtrim(to_char(v_qty,'FM999999990.99'),'0'),'.'))),
    'can_release', (v_lines > 0
                    and (v_act->>'kind') = 'staff'
                    and coalesce((v_state->>'held')::boolean,false)),
    'held', coalesce((v_state->>'held')::boolean,false),
    'rows', v_rows);
end
$fn$;

-- ── release it back ───────────────────────────────────────────────────────
create or replace function public.order_hold_stock_release(
  p_order_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare
  v_act jsonb := public._c708_actor(p_order_id);
  v_state jsonb := public.order_hold_state(p_order_id);
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_lines int := 0; v_qty numeric := 0; v_rel bigint;
begin
  if not coalesce((v_act->>'has')::boolean,false) then
    return jsonb_build_object('ok', false, 'error','not_yours', 'tone','danger',
      'message', _c('order_hold.err_not_yours'));
  end if;
  if (v_act->>'kind') <> 'staff' then
    return jsonb_build_object('ok', false, 'error','staff_only', 'tone','danger',
      'message', _c('order_hold.err_release_staff'));
  end if;
  if not coalesce((v_state->>'held')::boolean,false) then
    return jsonb_build_object('ok', false, 'error','not_held', 'tone','danger',
      'message', _c('order_hold.err_release_hold'));
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'error','need_reason', 'tone','danger',
      'message', _c('order_hold.err_release_reason'));
  end if;

  select count(*)::int, coalesce(sum(qty),0) into v_lines, v_qty
    from bag_allocations where order_id = p_order_id and state = 'reserved';
  if v_lines = 0 then
    return jsonb_build_object('ok', false, 'error','nothing', 'tone','danger',
      'message', _c('order_hold.err_release_none'));
  end if;

  update bag_allocations set state = 'released'
   where order_id = p_order_id and state = 'reserved';

  insert into order_hold_release (order_id, hold_id, lines, qty_total, reason,
                                  released_by, released_by_label)
  values (p_order_id, nullif(v_state->>'hold_id','')::bigint, v_lines, v_qty,
          v_reason, auth.uid(), v_act->>'label')
  returning id into v_rel;

  return jsonb_build_object('ok', true, 'tone','success', 'release_id', v_rel,
    'lines', v_lines, 'qty_total', v_qty,
    'message', _cf('order_hold.stock_released', jsonb_build_object('n', v_lines::text)),
    'stock', public.order_hold_stock(p_order_id));
end
$fn$;

revoke all on function public.order_hold_stock(uuid) from public, anon, authenticated;
revoke all on function public.order_hold_stock_release(uuid,text) from public, anon, authenticated;
grant execute on function public.order_hold_stock(uuid) to authenticated;
grant execute on function public.order_hold_stock_release(uuid,text) to authenticated;
