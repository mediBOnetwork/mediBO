-- CMD #2039 — cart fixes: the summary row on OPEN, and a one-tap Clear cart
-- that can be undone.
--
-- 1. `cart_summary_block()` on production still carried the pre-#2013 body: it
--    returned `line`/`rows` but no `bottom`. `cart_update_item()` DID carry
--    `bottom`, which is why "Total items / Advance to pay" only appeared after
--    a quantity tap and never on open. The file that added `bottom`
--    (20260915140000_cmd2013…) had already been replayed once, so editing it
--    again could never reach live — the whole block is therefore restated
--    here, in a new file, idempotently.
--
-- 2. Clear cart no longer asks. The rows are photographed into
--    `cart_clear_snapshot` before they are deleted and `cart_clear()` hands
--    back the snapshot id plus the words the snackbar prints; `cart_clear_undo()`
--    puts every line and quantity back inside the window the BACKEND decides.
--    Nothing about that interaction — the sentence, the action word, the five
--    seconds — is written in Dart.

-- ── 0. the words ────────────────────────────────────────────────────────────
insert into public.ui_copy (key, value) values
  ('cart.cleared_snack',        to_jsonb('Cart cleared'::text)),
  ('cart.cleared_undo',         to_jsonb('Undo'::text)),
  ('cart.cleared_restored',     to_jsonb('Cart restored'::text)),
  ('cart.cleared_undo_expired', to_jsonb('That cart can no longer be restored'::text)),
  ('cart.loading_note',         to_jsonb('Loading your cart…'::text))
on conflict (key) do nothing;

-- ── 1. the summary block, with the bottom row #2013 added ───────────────────
create or replace function public.cart_summary_block(
  p_pricing jsonb, p_delivery jsonb, p_items_label text,
  p_grand_display text, p_mrp_total numeric, p_item_count integer)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $fn$
declare
  v_net      numeric := coalesce((p_pricing->>'net_payable')::numeric, 0);
  v_unpriced int     := coalesce((p_pricing->>'unpriced_count')::int, 0);
  v_priced   int     := coalesce((p_pricing->>'priced_count')::int, 0);
  v_has      boolean := (v_net > 0);
  v_rows     jsonb   := '[]'::jsonb;
  v_line     text;
  v_cust     uuid; v_zone smallint; v_adv jsonb; v_adv_amt numeric := 0;
begin
  if not v_has then
    v_line := public._cf('cart.summary_pending', jsonb_build_object('items', p_items_label));
  elsif v_unpriced > 0 then
    v_line := public._cf('cart.summary_partial',
                jsonb_build_object('items', p_items_label, 'pending', v_unpriced::text));
  else
    v_line := public._cf('cart.summary_priced', jsonb_build_object('items', p_items_label));
  end if;

  -- The advance this basket would freeze, from the same ladder the top strip
  -- reads. Never allowed to break a cart: any failure leaves it at 0.
  begin
    v_cust := coalesce(public.customer_id_for_user(public.viewer_cart_user()),
                       public.my_customer_id());
    if v_cust is not null then
      select pp.zone_id into v_zone from public.pharmacy_profiles pp where pp.id = v_cust;
    end if;
    v_adv := public.advance_pct_for(v_cust, v_zone);
    v_adv_amt := round(coalesce(p_mrp_total,0) * coalesce((v_adv->>'pct')::numeric, 0) / 100.0, 2);
  exception when others then
    v_adv := null; v_adv_amt := 0;
  end;

  v_rows := v_rows || jsonb_build_array(jsonb_build_object(
    'key','items','label', public._c('cart.summary_items_label'),
    'amount', coalesce(p_item_count,0)::text, 'strong', false));
  if v_has then
    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'key','grand','label', public._c('cart.grand_total_label'),
      'amount', p_grand_display, 'strong', true));
  end if;

  return jsonb_build_object(
    'line',           v_line,
    'delivery_note',  coalesce(p_delivery->>'note',''),
    'has_amount',     v_has,
    'show_line',      v_has,
    'amount_display', case when v_has then coalesce(p_pricing->>'net_payable_display','') else '' end,
    'priced_count',   v_priced,
    'unpriced_count', v_unpriced,
    'rate_note',      '',
    'rows',           v_rows,
    -- CMD #2013 — the ONE row the cart prints above Place order. CMD #2039 —
    -- and it now reaches live, so the row is there the moment the cart opens.
    'bottom', jsonb_build_object(
      'has',              true,
      'items_label',      public._c('cart.bottom_items_label'),
      'items_value',      coalesce(p_item_count,0)::text,
      'advance_label',    public._c('cart.bottom_advance_label'),
      'has_advance',      (v_adv_amt > 0),
      'advance_display',  case when v_adv_amt > 0 then public.inr_money(v_adv_amt) else '' end));
end $fn$;

-- ── 2. the undo snapshot ────────────────────────────────────────────────────
create table if not exists public.cart_clear_snapshot (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid,
  customer_id uuid,
  items       jsonb not null default '[]'::jsonb,
  item_count  integer not null default 0,
  created_at  timestamptz not null default now(),
  restored_at timestamptz
);
create index if not exists cart_clear_snapshot_user_idx
  on public.cart_clear_snapshot (user_id, created_at desc);
alter table public.cart_clear_snapshot enable row level security;

-- No policy: every read and write goes through the SECURITY DEFINER functions
-- below, which resolve the owner themselves. A snapshot is never selectable
-- from PostgREST, so one customer's cleared basket cannot be read by another.
revoke all on public.cart_clear_snapshot from anon, authenticated;

-- How long a cleared cart can still be put back. The snackbar shows 5 s; the
-- server keeps the row a little longer so a tap on the last frame still lands.
create or replace function public.cart_undo_window_s()
returns integer language sql immutable set search_path to 'public' as $fn$
  select 5
$fn$;

create or replace function public.cart_undo_grace_s()
returns integer language sql immutable set search_path to 'public' as $fn$
  select 60
$fn$;

-- ── 3. cart_clear — no question asked, and it can be taken back ─────────────
create or replace function public.cart_clear(p_guest_uid uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_uid uuid; v_cust uuid; v_snap uuid; v_items jsonb; v_n int := 0;
begin
  if auth.uid() is not null then
    v_uid  := public.viewer_cart_user();
    v_cust := coalesce(public.customer_id_for_user(v_uid), public.my_customer_id());
  else
    v_uid := p_guest_uid; v_cust := null;
  end if;
  if v_uid is null then return jsonb_build_object('ok',false,'message','Please log in'); end if;

  -- Photograph every line BEFORE the delete. Undo restores exactly this.
  select coalesce(jsonb_agg(to_jsonb(ci) - 'id'), '[]'::jsonb), count(*)
    into v_items, v_n
    from public.cart_items ci
   where (case when v_cust is not null then ci.customer_id = v_cust else ci.user_id = v_uid end);

  if v_n > 0 then
    insert into public.cart_clear_snapshot (user_id, customer_id, items, item_count)
    values (v_uid, v_cust, v_items, v_n)
    returning id into v_snap;
  end if;

  delete from public.cart_items
   where (case when v_cust is not null then customer_id = v_cust else user_id = v_uid end);

  -- Housekeeping: a snapshot outside the grace window can never be used again.
  delete from public.cart_clear_snapshot
   where created_at < now() - make_interval(secs => public.cart_undo_grace_s() * 10);

  return jsonb_build_object(
    'ok', true,
    'message', public._c('cart.cleared_snack'),
    'cart', public.cart_render(p_guest_uid),
    'undo', jsonb_build_object(
      'has',          (v_snap is not null),
      'snapshot_id',  v_snap,
      'message',      public._c('cart.cleared_snack'),
      'action_label', public._c('cart.cleared_undo'),
      'seconds',      public.cart_undo_window_s(),
      'item_count',   v_n));
end $fn$;

-- ── 4. cart_clear_undo — every line and quantity back ───────────────────────
create or replace function public.cart_clear_undo(
  p_snapshot_id uuid, p_guest_uid uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare
  v_uid uuid; v_cust uuid; v_snap public.cart_clear_snapshot; v_n int := 0;
begin
  if auth.uid() is not null then
    v_uid  := public.viewer_cart_user();
    v_cust := coalesce(public.customer_id_for_user(v_uid), public.my_customer_id());
  else
    v_uid := p_guest_uid; v_cust := null;
  end if;
  if v_uid is null then
    return jsonb_build_object('ok',false,'message', public._c('cart.cleared_undo_expired'));
  end if;

  select * into v_snap
    from public.cart_clear_snapshot s
   where s.id = p_snapshot_id
     and s.restored_at is null
     and s.created_at > now() - make_interval(secs => public.cart_undo_grace_s())
     and (case when v_cust is not null then s.customer_id = v_cust else s.user_id = v_uid end)
   for update;

  if v_snap.id is null then
    return jsonb_build_object(
      'ok', false,
      'message', public._c('cart.cleared_undo_expired'),
      'cart', public.cart_render(p_guest_uid));
  end if;

  insert into public.cart_items (
    user_id, product_id, product_name, price, mrp, quantity, image_url,
    manufacturer, pack_size, category, gst_percent, updated_at, added_by,
    removed_by_admin, removed_at, customer_id, price_source)
  select
    (r->>'user_id')::uuid,
    r->>'product_id',
    coalesce(r->>'product_name',''),
    nullif(r->>'price','')::numeric,
    nullif(r->>'mrp','')::numeric,
    coalesce(nullif(r->>'quantity','')::int, 0),
    r->>'image_url',
    r->>'manufacturer',
    r->>'pack_size',
    r->>'category',
    nullif(r->>'gst_percent','')::int,
    now(),
    coalesce(nullif(r->>'added_by',''), 'customer'),
    coalesce((r->>'removed_by_admin')::boolean, false),
    nullif(r->>'removed_at','')::timestamptz,
    nullif(r->>'customer_id','')::uuid,
    r->>'price_source'
  from jsonb_array_elements(coalesce(v_snap.items, '[]'::jsonb)) r
  where not exists (
    select 1 from public.cart_items ci
     where ci.product_id = r->>'product_id'
       and (case when v_cust is not null then ci.customer_id = v_cust
                 else ci.user_id = v_uid end));
  get diagnostics v_n = row_count;

  update public.cart_clear_snapshot set restored_at = now() where id = v_snap.id;

  return jsonb_build_object(
    'ok', true,
    'message', public._c('cart.cleared_restored'),
    'restored', v_n,
    'cart', public.cart_render(p_guest_uid));
end $fn$;

-- ── 5. grants — the same reach cart_clear already had (a guest cart is
--    cleared and undone while logged out, so anon needs both doors). Neither
--    function trusts its caller: each resolves the owner itself.
grant execute on function public.cart_summary_block(jsonb, jsonb, text, text, numeric, integer)
  to anon, authenticated, service_role;
grant execute on function public.cart_clear(uuid) to anon, authenticated, service_role;
grant execute on function public.cart_clear_undo(uuid, uuid) to anon, authenticated, service_role;
grant execute on function public.cart_undo_window_s() to anon, authenticated, service_role;
grant execute on function public.cart_undo_grace_s() to anon, authenticated, service_role;
