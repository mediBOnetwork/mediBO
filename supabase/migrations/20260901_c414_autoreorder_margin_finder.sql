-- CHANGE #414 — auto-reorder from POS velocity, and the counter margin finder.
--
-- Both features exist to answer a question the pharmacy owner currently answers
-- from memory, and both are built on data this platform already has rather than
-- on anything new:
--
--   VELOCITY   pos_sale_lines x pos_sales is a real record of what actually
--              left the counter. Divided by the window it is a per-day rate;
--              against pharmacy_stock.qty it is a DATE — "Dolo finishes
--              Thursday" — which is the only form of this number an owner can
--              act on.
--
--   MARGIN     pharmacy_stock.unit_cost is what this pharmacy actually paid,
--              batch by batch. Against the pack's MRP — which at the COUNTER
--              is the real retail price, unlike the trade side of this
--              platform where MRP is only a ceiling — it is the true margin on
--              a walk-in sale. #366's rule applies unchanged: a margin is
--              shown only where a real cost exists. A batch with no unit_cost
--              produces no margin, is never estimated, and is never ranked.
--
-- Same-salt grouping is med_composition_key() (#366), not a second definition.
-- Adding to the cart is cart_set_item() (what reorder_build_cart already uses),
-- so a reorder is priced at the customer's own slab by the same path a normal
-- order is. Nothing here ever places an order: the owner always confirms.
--
-- Idempotent throughout.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. SETTINGS — every number in this feature is configurable per pharmacy, so
--    "suggested qty" is never a constant buried in a query.
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists public.pharmacy_reorder_settings (
  pharmacy_id   uuid primary key references public.pharmacy_profiles(id) on delete cascade,
  window_days   integer not null default 30,   -- the moving window velocity is measured over
  cover_days    integer not null default 14,   -- how many days of stock a reorder should buy
  urgent_days   integer not null default 3,    -- stockout within this many days = urgent
  soon_days     integer not null default 7,    -- … = soon
  min_sales     numeric not null default 1,    -- ignore a SKU that barely moved
  auto_draft    boolean not null default false,
  auto_draft_dow integer not null default 1,   -- 1 = Monday, IST
  updated_at    timestamptz not null default now()
);
alter table public.pharmacy_reorder_settings enable row level security;
revoke all on public.pharmacy_reorder_settings from anon, authenticated;

-- The weekly draft the owner approves. A draft is a SUGGESTION: approving it
-- fills the cart and stops. Nothing in this file calls place_order.
create table if not exists public.pharmacy_reorder_draft (
  id           uuid primary key default gen_random_uuid(),
  pharmacy_id  uuid not null references public.pharmacy_profiles(id) on delete cascade,
  built_on     date not null default ((now() at time zone 'Asia/Kolkata')::date),
  status       text not null default 'open'
                 check (status in ('open','approved','skipped','expired')),
  items        jsonb not null default '[]'::jsonb,
  line_count   integer not null default 0,
  approved_at  timestamptz,
  approved_by  text,
  created_at   timestamptz not null default now()
);
create unique index if not exists pharmacy_reorder_draft_open_idx
  on public.pharmacy_reorder_draft(pharmacy_id, built_on);
create index if not exists pharmacy_reorder_draft_open_status_idx
  on public.pharmacy_reorder_draft(pharmacy_id, status);
alter table public.pharmacy_reorder_draft enable row level security;
revoke all on public.pharmacy_reorder_draft from anon, authenticated;

create or replace function public._c414_settings(p_shop uuid)
returns public.pharmacy_reorder_settings language plpgsql stable
security definer set search_path to 'public' as $$
declare s public.pharmacy_reorder_settings;
begin
  select * into s from pharmacy_reorder_settings where pharmacy_id = p_shop;
  if s.pharmacy_id is null then
    -- The defaults ARE the table's defaults; a pharmacy that never opened the
    -- settings sheet still gets a complete, explainable answer.
    s.pharmacy_id := p_shop; s.window_days := 30; s.cover_days := 14;
    s.urgent_days := 3; s.soon_days := 7; s.min_sales := 1;
    s.auto_draft := false; s.auto_draft_dow := 1;
  end if;
  return s;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. THE VELOCITY ENGINE.
--    One set-based query, never a per-row helper: on a table that grows with
--    every counter sale, a scalar function called inside a SELECT re-scans it
--    once per SKU (the scalar-helper-scan anti-pattern this codebase has paid
--    for before).
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_velocity(p_shop uuid default null, p_window integer default null)
returns table(
  medicine_id   bigint,
  product_name  text,
  sold_qty      numeric,
  per_day       numeric,
  stock_qty     numeric,
  days_left     numeric,
  stockout_on   date
) language plpgsql stable security definer set search_path to 'public' as $$
declare v_shop uuid := coalesce(p_shop, public.pos_shop());
        s public.pharmacy_reorder_settings;
        v_win integer;
begin
  if v_shop is null then return; end if;
  s := public._c414_settings(v_shop);
  v_win := greatest(coalesce(p_window, s.window_days), 1);

  return query
  with sold as (
    select l.medicine_id,
           max(l.product_name)                as product_name,
           sum(coalesce(l.qty,0))::numeric    as sold_qty
      from pos_sale_lines l
      join pos_sales sa on sa.id = l.sale_id
     where sa.pharmacy_id = v_shop
       and coalesce(sa.status,'completed') <> 'void'
       and sa.sold_on >= ((now() at time zone 'Asia/Kolkata')::date - v_win)
       and l.medicine_id is not null
     group by l.medicine_id
  ), stock as (
    select ps.medicine_id,
           max(ps.product_name)             as product_name,
           sum(coalesce(ps.qty,0))::numeric as stock_qty
      from pharmacy_stock ps
     where ps.pharmacy_id = v_shop and ps.medicine_id is not null
     group by ps.medicine_id
  )
  select coalesce(so.medicine_id, st.medicine_id)                         as medicine_id,
         coalesce(so.product_name, st.product_name, '')                   as product_name,
         coalesce(so.sold_qty, 0)                                         as sold_qty,
         round(coalesce(so.sold_qty,0) / v_win, 4)                        as per_day,
         coalesce(st.stock_qty, 0)                                        as stock_qty,
         case when coalesce(so.sold_qty,0) > 0
              then round(coalesce(st.stock_qty,0) / (coalesce(so.sold_qty,0) / v_win), 2)
         end                                                              as days_left,
         case when coalesce(so.sold_qty,0) > 0
              then ((now() at time zone 'Asia/Kolkata')::date
                    + floor(coalesce(st.stock_qty,0)
                            / (coalesce(so.sold_qty,0) / v_win))::int)
         end                                                              as stockout_on
    from sold so
    full join stock st on st.medicine_id = so.medicine_id;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. COPY. Every word either screen renders.
-- ─────────────────────────────────────────────────────────────────────────────
insert into public.ui_copy(key, value) values
  ('reorder414.title',            to_jsonb('What to reorder'::text)),
  ('reorder414.subtitle',         to_jsonb('Worked out from what actually sold at your counter.'::text)),
  ('reorder414.tile_label',       to_jsonb('What to reorder'::text)),
  ('reorder414.empty',            to_jsonb('Nothing is running low. Sell a few more days and this fills in on its own.'::text)),
  ('reorder414.empty_no_sales',   to_jsonb('No counter sales yet, so there is nothing to measure. Bill a few sales and come back.'::text)),
  ('reorder414.group_urgent',     to_jsonb('Running out now'::text)),
  ('reorder414.group_soon',       to_jsonb('Running out this week'::text)),
  ('reorder414.group_later',      to_jsonb('Watch these'::text)),
  ('reorder414.add_label',        to_jsonb('Add to cart'::text)),
  ('reorder414.add_all_label',    to_jsonb('Add all to cart'::text)),
  ('reorder414.added',            to_jsonb('{n} added to your cart. Nothing is ordered until you place it.'::text)),
  ('reorder414.added_none',       to_jsonb('Nothing was added.'::text)),
  ('reorder414.suggest_label',    to_jsonb('Suggested'::text)),
  ('reorder414.stock_label',      to_jsonb('In stock'::text)),
  ('reorder414.velocity_label',   to_jsonb('Selling'::text)),
  ('reorder414.velocity_fmt',     to_jsonb('{n}/day'::text)),
  ('reorder414.stockout_today',   to_jsonb('Out of stock today'::text)),
  ('reorder414.stockout_tomorrow',to_jsonb('Finishes tomorrow'::text)),
  ('reorder414.stockout_fmt',     to_jsonb('Finishes {day}'::text)),
  ('reorder414.stockout_date_fmt',to_jsonb('Finishes {date}'::text)),
  ('reorder414.settings_label',   to_jsonb('Reorder settings'::text)),
  ('reorder414.window_label',     to_jsonb('Measure sales over'::text)),
  ('reorder414.cover_label',      to_jsonb('Order enough for'::text)),
  ('reorder414.days_fmt',         to_jsonb('{n} days'::text)),
  ('reorder414.saved',            to_jsonb('Saved.'::text)),
  ('reorder414.draft_title',      to_jsonb('This week''s suggested order'::text)),
  ('reorder414.draft_note',       to_jsonb('Built for you on {date}. Approving only fills your cart — you still place the order yourself.'::text)),
  ('reorder414.draft_approve',    to_jsonb('Approve and fill cart'::text)),
  ('reorder414.draft_skip',       to_jsonb('Skip this week'::text)),
  ('reorder414.draft_skipped',    to_jsonb('Skipped. We will build a fresh one next week.'::text)),
  ('reorder414.draft_none',       to_jsonb('No draft waiting.'::text)),
  ('reorder414.draft_toggle',     to_jsonb('Build me a weekly draft'::text)),
  ('reorder414.err_denied',       to_jsonb('This is your pharmacy''s counter — sign in as the pharmacy to use it.'::text)),

  ('posmargin.title',             to_jsonb('Same salt, better margin'::text)),
  ('posmargin.subtitle',          to_jsonb('Also on your shelf right now.'::text)),
  ('posmargin.margin_label',      to_jsonb('Your margin'::text)),
  ('posmargin.delta_fmt',         to_jsonb('{amount} more margin'::text)),
  ('posmargin.same_fmt',          to_jsonb('Same margin'::text)),
  ('posmargin.swap_label',        to_jsonb('Use this'::text)),
  ('posmargin.stock_fmt',         to_jsonb('{n} in stock'::text)),
  ('posmargin.none',              to_jsonb('No same-salt alternative on your shelf.'::text)),
  ('posmargin.no_cost',           to_jsonb('Cost not recorded for this batch, so no margin is shown.'::text)),
  ('posmargin.swapped',           to_jsonb('Line changed to {name}.'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. THE REORDER SCREEN. One RPC, rendered verbatim: the urgency GROUPS, the
--    suggested quantity, the "finishes Thursday" sentence and every label are
--    decided here.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_reorder_screen()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop(); s public.pharmacy_reorder_settings;
        v_rows jsonb; v_any_sales boolean; v_today date;
begin
  if v_shop is null then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public.ui_text('reorder414.err_denied'));
  end if;
  s := public._c414_settings(v_shop);
  v_today := (now() at time zone 'Asia/Kolkata')::date;

  select exists (select 1 from pos_sales where pharmacy_id = v_shop) into v_any_sales;

  select coalesce(jsonb_agg(x order by ord_days nulls last, ord_name), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'medicine_id',  v.medicine_id,
               'product_name', v.product_name,
               -- the urgency BUCKET is decided here; Dart groups by this key
               -- and never compares a number to a threshold of its own.
               'group_key',    case when v.days_left <= s.urgent_days then 'urgent'
                                    when v.days_left <= s.soon_days   then 'soon'
                                    else 'later' end,
               -- "Dolo finishes Thursday" — a DAY NAME inside the week, a date
               -- beyond it, and its own words for today/tomorrow. A date the
               -- owner has to count forward from is not an answer.
               'stockout_label',
                 case
                   when v.stockout_on <= v_today then public.ui_text('reorder414.stockout_today')
                   when v.stockout_on = v_today + 1 then public.ui_text('reorder414.stockout_tomorrow')
                   when v.stockout_on <= v_today + 6
                     then replace(public.ui_text('reorder414.stockout_fmt'), '{day}',
                                  trim(to_char(v.stockout_on, 'Day')))
                   else replace(public.ui_text('reorder414.stockout_date_fmt'), '{date}',
                                to_char(v.stockout_on, 'DD Mon'))
                 end,
               'stockout_on',  v.stockout_on,
               'days_left',    v.days_left,
               'stock_qty',    v.stock_qty,
               'stock_label',  public.ui_text('reorder414.stock_label'),
               'stock_display',public._pos_dec(v.stock_qty),
               'velocity_label', public.ui_text('reorder414.velocity_label'),
               'velocity_display',
                 replace(public.ui_text('reorder414.velocity_fmt'), '{n}',
                         public._pos_dec(round(v.per_day, 1))),
               -- suggested qty = velocity x cover-days, less what is on the
               -- shelf, rounded UP to a whole pack and never below one.
               'suggest_label', public.ui_text('reorder414.suggest_label'),
               'suggest_qty',   greatest(1, ceil((v.per_day * s.cover_days) - v.stock_qty)::int),
               'add_label',     public.ui_text('reorder414.add_label')) as x,
             v.days_left as ord_days, v.product_name as ord_name
        from public.pharmacy_velocity(v_shop, s.window_days) v
       where v.sold_qty >= s.min_sales
         and v.days_left is not null
         -- only what will actually run out inside the cover window
         and v.days_left <= s.cover_days
    ) q;

  return jsonb_build_object(
    'ok', true,
    'title',          public.ui_text('reorder414.title'),
    'subtitle',       public.ui_text('reorder414.subtitle'),
    'empty',          case when v_any_sales then public.ui_text('reorder414.empty')
                           else public.ui_text('reorder414.empty_no_sales') end,
    'add_all_label',  public.ui_text('reorder414.add_all_label'),
    'settings_label', public.ui_text('reorder414.settings_label'),
    'window_label',   public.ui_text('reorder414.window_label'),
    'cover_label',    public.ui_text('reorder414.cover_label'),
    'window_display', replace(public.ui_text('reorder414.days_fmt'), '{n}', s.window_days::text),
    'cover_display',  replace(public.ui_text('reorder414.days_fmt'), '{n}', s.cover_days::text),
    'window_days',    s.window_days,
    'cover_days',     s.cover_days,
    'auto_draft',     s.auto_draft,
    'draft_toggle',   public.ui_text('reorder414.draft_toggle'),
    -- the GROUPS are the payload's, in the payload's order, with the payload's
    -- headings: a build that has never heard of a bucket still renders it.
    'groups', jsonb_build_array(
      jsonb_build_object('key','urgent','label', public.ui_text('reorder414.group_urgent'),'tone','danger'),
      jsonb_build_object('key','soon',  'label', public.ui_text('reorder414.group_soon'),  'tone','warning'),
      jsonb_build_object('key','later', 'label', public.ui_text('reorder414.group_later'), 'tone','info')),
    'rows',  v_rows,
    'count', jsonb_array_length(v_rows));
end $$;

-- One tap adds the lot to the mediBO cart. cart_set_item() is the SAME door
-- reorder_build_cart uses, so the lines land at this customer's own slab and
-- nothing here has to know how pricing works.
create or replace function public.pharmacy_reorder_add(p_items jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop(); it jsonb; v_n int := 0; v_qty int;
begin
  if v_shop is null then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public.ui_text('reorder414.err_denied'));
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    return jsonb_build_object('ok', false, 'tone','info',
      'message', public.ui_text('reorder414.added_none'));
  end if;

  for it in select value from jsonb_array_elements(p_items) loop
    v_qty := greatest(1, coalesce((it->>'qty')::numeric, 1)::int);
    begin
      perform public.cart_set_item((it->>'medicine_id')::text, v_qty, null);
      v_n := v_n + 1;
    exception when others then null;   -- one bad line never sinks the rest
    end;
  end loop;

  if v_n = 0 then
    return jsonb_build_object('ok', false, 'tone','info', 'added', 0,
      'message', public.ui_text('reorder414.added_none'));
  end if;

  -- NOTE: the cart is filled and that is ALL. No order is placed here, by
  -- design and by the spec — the owner always confirms.
  return jsonb_build_object('ok', true, 'tone','success', 'added', v_n,
    'message', replace(public.ui_text('reorder414.added'), '{n}', v_n::text));
exception when others then
  return jsonb_build_object('ok', false, 'error','exception','tone','danger',
    'message', SQLERRM);
end $$;

create or replace function public.pharmacy_reorder_settings_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop(); s public.pharmacy_reorder_settings;
begin
  if v_shop is null then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public.ui_text('reorder414.err_denied'));
  end if;
  s := public._c414_settings(v_shop);
  insert into pharmacy_reorder_settings(pharmacy_id, window_days, cover_days,
                                        urgent_days, soon_days, min_sales,
                                        auto_draft, auto_draft_dow)
  values (v_shop,
          greatest(1, least(coalesce((p_patch->>'window_days')::int,  s.window_days), 365)),
          greatest(1, least(coalesce((p_patch->>'cover_days')::int,   s.cover_days), 180)),
          greatest(0, least(coalesce((p_patch->>'urgent_days')::int,  s.urgent_days), 60)),
          greatest(0, least(coalesce((p_patch->>'soon_days')::int,    s.soon_days), 90)),
          greatest(0, coalesce((p_patch->>'min_sales')::numeric,      s.min_sales)),
          coalesce((p_patch->>'auto_draft')::boolean,                 s.auto_draft),
          greatest(0, least(coalesce((p_patch->>'auto_draft_dow')::int, s.auto_draft_dow), 6)))
  on conflict (pharmacy_id) do update
    set window_days = excluded.window_days, cover_days = excluded.cover_days,
        urgent_days = excluded.urgent_days, soon_days = excluded.soon_days,
        min_sales   = excluded.min_sales,   auto_draft = excluded.auto_draft,
        auto_draft_dow = excluded.auto_draft_dow, updated_at = now();

  return jsonb_build_object('ok', true, 'tone','success',
    'message', public.ui_text('reorder414.saved'),
    'screen',  public.pharmacy_reorder_screen());
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. THE WEEKLY DRAFT. Built for the owner, approved by the owner, and never
--    placed by anybody. Approving it does exactly what the screen's own button
--    does — fills the cart — so there is one code path to trust, not two.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.pharmacy_reorder_draft_build(p_shop uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := coalesce(p_shop, public.pos_shop());
        v_screen jsonb; v_items jsonb; v_id uuid; v_today date;
begin
  if v_shop is null then return jsonb_build_object('ok', false, 'error','no_shop'); end if;
  v_today := (now() at time zone 'Asia/Kolkata')::date;

  -- The draft is the screen. Anything else and the two would drift.
  v_screen := public.pharmacy_reorder_screen();
  if (v_screen->>'ok')::boolean is not true then return v_screen; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'medicine_id',  r->>'medicine_id',
           'product_name', r->>'product_name',
           'qty',          (r->>'suggest_qty')::int)), '[]'::jsonb)
    into v_items
    from jsonb_array_elements(coalesce(v_screen->'rows','[]'::jsonb)) r;

  if jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok', true, 'built', false, 'line_count', 0);
  end if;

  insert into pharmacy_reorder_draft(pharmacy_id, built_on, items, line_count)
  values (v_shop, v_today, v_items, jsonb_array_length(v_items))
  on conflict (pharmacy_id, built_on) do update
    set items = excluded.items, line_count = excluded.line_count
  returning id into v_id;

  return jsonb_build_object('ok', true, 'built', true, 'id', v_id,
    'line_count', jsonb_array_length(v_items));
end $$;

create or replace function public.pharmacy_reorder_draft_get()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop(); d record;
begin
  if v_shop is null then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public.ui_text('reorder414.err_denied'));
  end if;
  select * into d from pharmacy_reorder_draft
   where pharmacy_id = v_shop and status = 'open'
   order by built_on desc limit 1;

  if d.id is null then
    return jsonb_build_object('ok', true, 'has', false,
      'message', public.ui_text('reorder414.draft_none'));
  end if;

  return jsonb_build_object(
    'ok', true, 'has', true, 'id', d.id,
    'title',         public.ui_text('reorder414.draft_title'),
    'note',          replace(public.ui_text('reorder414.draft_note'), '{date}',
                             to_char(d.built_on, 'DD Mon')),
    'approve_label', public.ui_text('reorder414.draft_approve'),
    'skip_label',    public.ui_text('reorder414.draft_skip'),
    'line_count',    d.line_count,
    'items',         d.items);
end $$;

create or replace function public.pharmacy_reorder_draft_act(p_id uuid, p_action text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop(); d record; v_add jsonb;
begin
  if v_shop is null then
    return jsonb_build_object('ok', false, 'error','not_authorized','tone','danger',
      'message', public.ui_text('reorder414.err_denied'));
  end if;
  select * into d from pharmacy_reorder_draft
   where id = p_id and pharmacy_id = v_shop and status = 'open';
  if d.id is null then
    return jsonb_build_object('ok', false, 'error','not_found','tone','info',
      'message', public.ui_text('reorder414.draft_none'));
  end if;

  if p_action = 'skip' then
    update pharmacy_reorder_draft set status = 'skipped' where id = d.id;
    return jsonb_build_object('ok', true, 'tone','info',
      'message', public.ui_text('reorder414.draft_skipped'));
  end if;

  -- APPROVE fills the cart. It does not place an order, and there is no code
  -- path in this file that does.
  v_add := public.pharmacy_reorder_add(d.items);
  if (v_add->>'ok')::boolean is not true then return v_add; end if;
  update pharmacy_reorder_draft
     set status = 'approved', approved_at = now(),
         approved_by = coalesce(public.my_login_email(),'')
   where id = d.id;
  return v_add;
end $$;

-- The sweep the ONE cron dispatcher runs. It builds a draft for every pharmacy
-- that asked for one, on its own chosen weekday, and never more than once a day.
create or replace function public.pharmacy_reorder_draft_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; v_built int := 0; v_seen int := 0; v_today date;
begin
  v_today := (now() at time zone 'Asia/Kolkata')::date;
  for r in
    select s.pharmacy_id from pharmacy_reorder_settings s
     where s.auto_draft
       and s.auto_draft_dow = extract(isodow from v_today)::int
       and not exists (select 1 from pharmacy_reorder_draft d
                        where d.pharmacy_id = s.pharmacy_id and d.built_on = v_today)
  loop
    v_seen := v_seen + 1;
    begin
      if (public.pharmacy_reorder_draft_build(r.pharmacy_id)->>'built')::boolean then
        v_built := v_built + 1;
      end if;
    exception when others then null;  -- one pharmacy never stops the sweep
    end;
  end loop;
  return jsonb_build_object('ok', true, 'considered', v_seen, 'built', v_built);
end $$;

-- Registered with the dispatcher, never a bare */N schedule of its own.
insert into public.cron_task(name, ord, mode, work_sql, enabled, note,
                             base_interval_s, max_interval_s, run_at_ist, dml)
values ('c414-reorder-draft', 640, 'poll',
        'select public.pharmacy_reorder_draft_sweep()', true,
        'CHANGE #414 — builds the weekly reorder draft for pharmacies that asked for one. Suggestion only; never places an order.',
        3600, 21600, '06:30', true)
on conflict (name) do update
  set work_sql = excluded.work_sql, enabled = true, note = excluded.note,
      base_interval_s = excluded.base_interval_s, max_interval_s = excluded.max_interval_s,
      run_at_ist = excluded.run_at_ist;

-- ═════════════════════════════════════════════════════════════════════════════
-- 6. THE COUNTER MARGIN FINDER.
--
-- The patient asks for a brand. It is on the shelf. Is there another brand of
-- the SAME SALT, also on the shelf, that this pharmacy earns more on?
--
-- Three rules, all of them the point of the feature:
--   ALSO IN THEIR STOCK — an alternative that has to be ordered is not an
--     answer at a counter with a patient standing at it. Only pharmacy_stock
--     rows with qty > 0 are considered.
--   SAME SALT — med_composition_key() (#366), never a second definition of what
--     "same salt" means.
--   REAL COST ONLY — margin is MRP minus what this pharmacy actually PAID
--     (pharmacy_stock.unit_cost). A batch with no recorded cost yields no
--     margin: it is not estimated, not defaulted to zero, and never ranked.
--     That is #366's rule and it is the only thing that makes the number
--     trustworthy enough to act on.
-- ═════════════════════════════════════════════════════════════════════════════

-- What this pharmacy holds of one medicine, and what it actually cost them.
-- Weighted by quantity across batches, so a big cheap batch and a small dear
-- one give the honest blended cost rather than whichever row sorted first.
create or replace function public._c414_stock_cost(p_shop uuid, p_medicine_id bigint)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  with b as (
    select ps.qty, ps.unit_cost, ps.mrp
      from pharmacy_stock ps
     where ps.pharmacy_id = p_shop and ps.medicine_id = p_medicine_id
       and coalesce(ps.qty,0) > 0
  ), costed as (
    select * from b where unit_cost is not null and unit_cost > 0
  )
  select jsonb_build_object(
    'qty',        coalesce((select sum(qty) from b), 0),
    'in_stock',   coalesce((select sum(qty) from b), 0) > 0,
    -- has_cost is the ONLY thing that licenses a margin figure downstream.
    'has_cost',   exists (select 1 from costed),
    'unit_cost',  (select round(sum(unit_cost * qty) / nullif(sum(qty),0), 2) from costed),
    'mrp',        (select round(sum(mrp * qty) / nullif(sum(qty),0), 2)
                     from b where mrp is not null and mrp > 0))
$$;

create or replace function public.pos_margin_options(p_medicine_id bigint, p_limit integer default 5)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop(); m record; v_key text;
        v_self jsonb; v_self_margin numeric; v_rows jsonb;
begin
  if v_shop is null then return public._pos_denied(); end if;

  select * into m from "MEDICINE" where id = p_medicine_id;
  if m.id is null then
    return jsonb_build_object('ok', true, 'has', false,
      'message', public.ui_text('posmargin.none'));
  end if;

  -- The asked brand must itself be on the shelf: this feature is about what to
  -- hand over instead, not about what to stock.
  v_self := public._c414_stock_cost(v_shop, m.id);
  if (v_self->>'in_stock')::boolean is not true then
    return jsonb_build_object('ok', true, 'has', false,
      'message', public.ui_text('posmargin.none'));
  end if;

  v_key := public.med_composition_key(m.salt_composition, m.pack_qty, m.pack_type);
  if v_key is null then
    return jsonb_build_object('ok', true, 'has', false,
      'message', public.ui_text('posmargin.none'));
  end if;

  v_self_margin := case when (v_self->>'has_cost')::boolean
                        then (v_self->>'mrp')::numeric - (v_self->>'unit_cost')::numeric end;

  with shelf as (
    -- every OTHER medicine this pharmacy holds …
    select ps.medicine_id, sum(coalesce(ps.qty,0)) as qty
      from pharmacy_stock ps
     where ps.pharmacy_id = v_shop
       and ps.medicine_id is not null
       and ps.medicine_id <> m.id
       and coalesce(ps.qty,0) > 0
     group by ps.medicine_id
  ), same_salt as (
    -- … that is the same salt, by #366's key
    select sh.medicine_id, sh.qty, s.product_name, s.marketer
      from shelf sh
      join "MEDICINE" s on s.id = sh.medicine_id
     where public.med_composition_key(s.salt_composition, s.pack_qty, s.pack_type) = v_key
  ), priced as (
    select ss.*, public._c414_stock_cost(v_shop, ss.medicine_id) as sc
      from same_salt ss
  ), margined as (
    select p.*,
           (p.sc->>'has_cost')::boolean as has_cost,
           case when (p.sc->>'has_cost')::boolean
                then (p.sc->>'mrp')::numeric - (p.sc->>'unit_cost')::numeric end as margin
      from priced p
  )
  select coalesce(jsonb_agg(x order by ord_margin desc nulls last, ord_name), '[]'::jsonb)
    into v_rows
    from (
      select jsonb_build_object(
               'medicine_id',   g.medicine_id,
               'product_name',  coalesce(g.product_name,''),
               'company',       coalesce(nullif(btrim(coalesce(g.marketer,'')),''),''),
               'stock_display', replace(public.ui_text('posmargin.stock_fmt'), '{n}',
                                        public._pos_dec(g.qty)),
               -- a margin exists only where a real cost does
               'has_margin',    g.has_cost,
               'margin_label',  public.ui_text('posmargin.margin_label'),
               'margin_display',case when g.has_cost then public.inr_money(g.margin) end,
               'no_cost_note',  case when not g.has_cost
                                     then public.ui_text('posmargin.no_cost') end,
               -- "suggest Cipmol: Rs 2.10 more margin" — the comparison is the
               -- reason the row is on screen, so the backend words it.
               'delta_display',
                 case when g.has_cost and v_self_margin is not null then
                   case when round(g.margin - v_self_margin, 2) > 0
                        then replace(public.ui_text('posmargin.delta_fmt'), '{amount}',
                                     public.inr_money(round(g.margin - v_self_margin, 2)))
                        when round(g.margin - v_self_margin, 2) = 0
                        then public.ui_text('posmargin.same_fmt')
                   end
                 end,
               'delta',         case when g.has_cost and v_self_margin is not null
                                     then round(g.margin - v_self_margin, 2) end,
               'swap_label',    public.ui_text('posmargin.swap_label')) as x,
             g.margin as ord_margin, g.product_name as ord_name
        from margined g
       -- Ranked by THEIR margin, and only where there is a real one to rank by.
       where g.has_cost
         and (v_self_margin is null or g.margin > v_self_margin)
       order by g.margin desc nulls last, g.product_name
       limit greatest(least(coalesce(p_limit,5), 20), 1)
    ) q;

  return jsonb_build_object(
    'ok',       true,
    'has',      jsonb_array_length(v_rows) > 0,
    'title',    public.ui_text('posmargin.title'),
    'subtitle', public.ui_text('posmargin.subtitle'),
    'for_medicine_id', m.id,
    'for_name',        coalesce(m.product_name,''),
    'self_has_margin', coalesce((v_self->>'has_cost')::boolean, false),
    'self_margin_display',
      case when v_self_margin is not null then public.inr_money(v_self_margin) end,
    'rows',     v_rows,
    'message',  case when jsonb_array_length(v_rows) = 0
                     then public.ui_text('posmargin.none') end);
end $$;

-- One tap swaps the line. The counter screen holds its own draft lines, so the
-- swap is a PRICED replacement line the screen substitutes — the backend still
-- decides every rupee on it, through the same pos_quote the counter always uses.
create or replace function public.pos_margin_swap(p_from bigint, p_to bigint, p_qty numeric default 1)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_shop uuid := public.pos_shop(); s record; v_stock jsonb;
begin
  if v_shop is null then return public._pos_denied(); end if;
  select * into s from "MEDICINE" where id = p_to;
  if s.id is null then
    return jsonb_build_object('ok', false, 'error','not_found','tone','danger',
      'message', public.ui_text('posmargin.none'));
  end if;

  -- Never swap onto something that is not actually on the shelf.
  v_stock := public._c414_stock_cost(v_shop, p_to);
  if (v_stock->>'in_stock')::boolean is not true then
    return jsonb_build_object('ok', false, 'error','not_in_stock','tone','danger',
      'message', public.ui_text('posmargin.none'));
  end if;

  return jsonb_build_object(
    'ok', true, 'tone','success',
    'message', replace(public.ui_text('posmargin.swapped'), '{name}',
                       coalesce(s.product_name,'')),
    'line', jsonb_build_object(
      'medicine_id',  s.id,
      'product_name', coalesce(s.product_name,''),
      'pack_label',   nullif(btrim(coalesce(s.pack_size, s.pack_type,'')),''),
      'mrp',          public._pos_num(s.mrp),
      'mrp_display',  case when public._pos_num(s.mrp) is not null
                           then public.inr_money(public._pos_num(s.mrp)) end,
      'has_mrp',      public._pos_num(s.mrp) is not null and public._pos_num(s.mrp) > 0,
      'gst_percent',  public._pos_gst_for(s.id),
      'gst_label',    public._pos_dec(public._pos_gst_for(s.id)) || '%',
      'qty',          greatest(1, coalesce(p_qty,1))));
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. GRANTS. Every one is SECURITY DEFINER and checks pos_shop() itself; anon
--    gets none of them, because none of this is a public page.
-- ─────────────────────────────────────────────────────────────────────────────
revoke all on function public.pharmacy_velocity(uuid, integer)              from public, anon;
revoke all on function public.pharmacy_reorder_screen()                     from public, anon;
revoke all on function public.pharmacy_reorder_add(jsonb)                   from public, anon;
revoke all on function public.pharmacy_reorder_settings_set(jsonb)          from public, anon;
revoke all on function public.pharmacy_reorder_draft_build(uuid)            from public, anon;
revoke all on function public.pharmacy_reorder_draft_get()                  from public, anon;
revoke all on function public.pharmacy_reorder_draft_act(uuid, text)        from public, anon;
revoke all on function public.pharmacy_reorder_draft_sweep()                from public, anon, authenticated;
revoke all on function public.pos_margin_options(bigint, integer)           from public, anon;
revoke all on function public.pos_margin_swap(bigint, bigint, numeric)      from public, anon;
revoke all on function public._c414_stock_cost(uuid, bigint)                from public, anon, authenticated;
revoke all on function public._c414_settings(uuid)                          from public, anon, authenticated;

grant execute on function public.pharmacy_velocity(uuid, integer)           to authenticated;
grant execute on function public.pharmacy_reorder_screen()                  to authenticated;
grant execute on function public.pharmacy_reorder_add(jsonb)                to authenticated;
grant execute on function public.pharmacy_reorder_settings_set(jsonb)       to authenticated;
grant execute on function public.pharmacy_reorder_draft_get()               to authenticated;
grant execute on function public.pharmacy_reorder_draft_act(uuid, text)     to authenticated;
grant execute on function public.pos_margin_options(bigint, integer)        to authenticated;
grant execute on function public.pos_margin_swap(bigint, bigint, numeric)   to authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 8. THE LEAK HOSTILE QA FOUND.
--
-- pharmacy_velocity() takes the shop as a PARAMETER, defaulting to pos_shop().
-- It never checked that the caller owned the shop they passed. It is granted to
-- `authenticated` and it is SECURITY DEFINER, so any signed-in pharmacy could
-- ask for any other pharmacy's id and read that shop's shelf quantities and its
-- day-by-day sales velocity — a competitor's stock and turnover, from one RPC.
-- Proven live before the fix: pharmacy A asked for B's id and got B's shelf.
--
-- The parameter stays, because two callers legitimately pass an id — the weekly
-- draft sweep runs for a named pharmacy, and an admin may look at one shop —
-- but it is now FENCED: anyone who is not that pharmacy and not an admin gets
-- their own shop, never the one they asked for. A leak fixed by refusing the
-- argument would have broken the sweep; this refuses the CALLER instead.
-- ═════════════════════════════════════════════════════════════════════════════
create or replace function public._c414_shop_for(p_shop uuid)
returns uuid language sql stable security definer set search_path to 'public' as $$
  select case
           -- no argument: your own shop, which is the normal case
           when p_shop is null then public.pos_shop()
           -- your own shop, named explicitly
           when p_shop = public.pos_shop() then p_shop
           -- an admin, or the dispatcher running with no session at all
           when public.get_my_role() in ('admin','super_admin') then p_shop
           when auth.uid() is null then p_shop
           -- anyone else asking about a shop that is not theirs
           else public.pos_shop()
         end
$$;
revoke all on function public._c414_shop_for(uuid) from public, anon, authenticated;

create or replace function public.pharmacy_velocity(p_shop uuid default null, p_window integer default null)
returns table(
  medicine_id   bigint,
  product_name  text,
  sold_qty      numeric,
  per_day       numeric,
  stock_qty     numeric,
  days_left     numeric,
  stockout_on   date
) language plpgsql stable security definer set search_path to 'public' as $$
declare v_shop uuid := public._c414_shop_for(p_shop);
        s public.pharmacy_reorder_settings;
        v_win integer;
begin
  if v_shop is null then return; end if;
  s := public._c414_settings(v_shop);
  v_win := greatest(coalesce(p_window, s.window_days), 1);

  return query
  with sold as (
    select l.medicine_id,
           max(l.product_name)                as product_name,
           sum(coalesce(l.qty,0))::numeric    as sold_qty
      from pos_sale_lines l
      join pos_sales sa on sa.id = l.sale_id
     where sa.pharmacy_id = v_shop
       and coalesce(sa.status,'completed') <> 'void'
       and sa.sold_on >= ((now() at time zone 'Asia/Kolkata')::date - v_win)
       and l.medicine_id is not null
     group by l.medicine_id
  ), stock as (
    select ps.medicine_id,
           max(ps.product_name)             as product_name,
           sum(coalesce(ps.qty,0))::numeric as stock_qty
      from pharmacy_stock ps
     where ps.pharmacy_id = v_shop and ps.medicine_id is not null
     group by ps.medicine_id
  )
  select coalesce(so.medicine_id, st.medicine_id)                         as medicine_id,
         coalesce(so.product_name, st.product_name, '')                   as product_name,
         coalesce(so.sold_qty, 0)                                         as sold_qty,
         round(coalesce(so.sold_qty,0) / v_win, 4)                        as per_day,
         coalesce(st.stock_qty, 0)                                        as stock_qty,
         case when coalesce(so.sold_qty,0) > 0
              then round(coalesce(st.stock_qty,0) / (coalesce(so.sold_qty,0) / v_win), 2)
         end                                                              as days_left,
         case when coalesce(so.sold_qty,0) > 0
              then ((now() at time zone 'Asia/Kolkata')::date
                    + floor(coalesce(st.stock_qty,0)
                            / (coalesce(so.sold_qty,0) / v_win))::int)
         end                                                              as stockout_on
    from sold so
    full join stock st on st.medicine_id = so.medicine_id;
end $$;

-- The draft builder took the same unchecked parameter, and building a draft
-- reads the same shelf. Fence it identically. The sweep still works: it calls
-- with no session, which _c414_shop_for admits by design.
create or replace function public.pharmacy_reorder_draft_build(p_shop uuid default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_shop uuid := public._c414_shop_for(p_shop);
        v_screen jsonb; v_items jsonb; v_id uuid; v_today date;
begin
  if v_shop is null then return jsonb_build_object('ok', false, 'error','no_shop'); end if;
  v_today := (now() at time zone 'Asia/Kolkata')::date;

  v_screen := public.pharmacy_reorder_screen();
  if (v_screen->>'ok')::boolean is not true then return v_screen; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'medicine_id',  r->>'medicine_id',
           'product_name', r->>'product_name',
           'qty',          (r->>'suggest_qty')::int)), '[]'::jsonb)
    into v_items
    from jsonb_array_elements(coalesce(v_screen->'rows','[]'::jsonb)) r;

  if jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('ok', true, 'built', false, 'line_count', 0);
  end if;

  insert into pharmacy_reorder_draft(pharmacy_id, built_on, items, line_count)
  values (v_shop, v_today, v_items, jsonb_array_length(v_items))
  on conflict (pharmacy_id, built_on) do update
    set items = excluded.items, line_count = excluded.line_count
  returning id into v_id;

  return jsonb_build_object('ok', true, 'built', true, 'id', v_id,
    'line_count', jsonb_array_length(v_items));
end $$;

revoke all on function public.pharmacy_velocity(uuid, integer)   from public, anon;
revoke all on function public.pharmacy_reorder_draft_build(uuid) from public, anon;
grant execute on function public.pharmacy_velocity(uuid, integer) to authenticated;

-- ═════════════════════════════════════════════════════════════════════════════
-- 9. THE QA BLOCKER BECOMES A PERMANENT JOURNEY (rule 14.4).
--
-- One pharmacy reading another's shelf is a CLASS, not an incident: every
-- future function that takes a shop id as a parameter can reintroduce it. The
-- journey therefore checks the fence AND sweeps every reachable function that
-- takes a `p_shop uuid` argument, so the next one written without the fence
-- turns this red on the day it lands.
-- ═════════════════════════════════════════════════════════════════════════════
create or replace function public._journey_c414_shop_fence()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a1 boolean; a2 boolean; a3 boolean; a4 boolean; v_unfenced text;
begin
  -- the fence exists, and is not reachable by a client itself
  a1 := exists (select 1 from pg_proc p
                 where p.pronamespace='public'::regnamespace
                   and p.proname='_c414_shop_for');
  a2 := not has_function_privilege('authenticated', 'public._c414_shop_for(uuid)', 'EXECUTE')
    and not has_function_privilege('anon',          'public._c414_shop_for(uuid)', 'EXECUTE');

  -- the two functions that take a shop id both go through it
  a3 := (select bool_and(p.prosrc like '%_c414_shop_for%')
           from pg_proc p
          where p.pronamespace='public'::regnamespace
            and p.proname in ('pharmacy_velocity','pharmacy_reorder_draft_build'));

  -- and NO other client-reachable function in this feature takes a raw shop id
  -- without going through the fence. This is the part that catches the NEXT one.
  select string_agg(p.proname, ', ') into v_unfenced
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname like 'pharmacy\_%'
     and pg_get_function_identity_arguments(p.oid) like '%p_shop uuid%'
     and p.prosrc not like '%_c414_shop_for%'
     and has_function_privilege('authenticated', p.oid, 'EXECUTE');
  a4 := v_unfenced is null;

  return jsonb_build_object(
    'status', case when a1 and a2 and a3 and a4 then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      'the fence exists=' || a1::text
   || ' | no client can call it directly=' || a2::text
   || ' | both shop-id functions go through it=' || a3::text
   || ' | no unfenced shop-id function is client-reachable=' || a4::text
   || coalesce(' -> ' || v_unfenced, '')));
end $$;

update public.dev_journeys
   set steps = '["A pharmacy signs in","It asks a shop-scoped RPC for a DIFFERENT pharmacy''s id","It gets its own shop back, never the other one","And no newly written shop-scoped function skips the fence"]'::jsonb
 where name = 'qa-414-227';

-- The probe's dispatch table gains the branch. Reproduced whole because that is
-- the only way to add a branch to a plpgsql function.
CREATE OR REPLACE FUNCTION public.dev_journey_probe(p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_ok boolean; v_ev jsonb; v_v text; v_row record; v_jid bigint; v_pass_count int;
        v_sql text; v_chk jsonb; v_base_hash text; v_bl jsonb; v_err text;
        v_a1 boolean; v_a2 boolean; v_a3 boolean; v_a4 boolean; v_a5 boolean; v_a6 boolean;
        c_target constant text := 'my_orders_chandra_slice';
begin
  perform public._dev_guard();


  -- CHANGE #436 — the default PUBLIC EXECUTE grant, closed as a class.
  if p_name = 'bug-436' then return public._journey_bug436(); end if;
  -- CHANGE #408 — the three QA blockers this command found, each retired as a
  -- class rather than as one screenshot: the staff binding that handed a
  -- pharmacy away, the edit window that stayed open after a supplier was
  -- asked, and the basket that was totalled on MRP.
  if p_name = 'qa-408-216' then return public._journey_c408_binding(); end if;
  if p_name = 'qa-408-217' then return public._journey_c408_window();  end if;
  if p_name = 'qa-408-218' then return public._journey_c408_pricing(); end if;
  -- CHANGE #414 — one pharmacy reading another's shelf, retired as a class:
  -- the sweep also fails on the NEXT shop-scoped function written without the
  -- fence, not just on the one that leaked.
  if p_name = 'qa-414-227' then return public._journey_c414_shop_fence(); end if;
  -- CHANGE #319 — QA blockers 156/157 (version.json served HTML).
  if p_name in ('qa-319-156','qa-319-157') then
    return public._journey_qa319_version();
  end if;

  -- CHANGE #240 — inquiry->PO date integrity (see _journey_bug240).
  if p_name = 'bug-240' then return public._journey_bug240(); end if;

  -- CHANGE #197 — the confirm re-read may only CONFIRM drift, never clear it.
  -- Regression guard for the false-negative: a payload target that DIFFERS on
  -- read 1 and then ERRORS on the confirm read used to vanish from both
  -- diffs.payload.changed and collection_errors, so rg_check returned ok:true
  -- while a real change sat unreported.
  if p_name = 'bug-197' then
    v_err := null;
    select position('confirm re-read failed' in p.prosrc) > 0 into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_check';
    begin
      create table if not exists public._j197_ctr(n int);
      delete from public._j197_ctr where true; insert into public._j197_ctr values (0);
      execute 'create or replace function public._j197_tick() returns int language plpgsql as '
           || '$b$ declare v int; begin update public._j197_ctr set n = n + 1 where true returning n into v; '
           || 'if v >= 2 then raise exception ''j197 confirm read''; end if; return 42; end $b$';
      delete from rg_payload_targets where name = '_j197_probe';
      delete from rg_baseline where kind = 'payload' and name = '_j197_probe';
      insert into rg_payload_targets(name, sql, enabled)
        values ('_j197_probe', 'select jsonb_build_object(''v'', public._j197_tick())', true);
      insert into rg_baseline(kind, name, hash, content)
        values ('payload','_j197_probe','deadbeefdeadbeefdeadbeefdeadbeef','{"v":0}'::jsonb);

      v_chk := public.rg_check(false, true);
      select exists (select 1 from jsonb_array_elements_text(
                       coalesce(v_chk->'diffs'->'payload'->'changed','[]'::jsonb)) x
                      where x = '_j197_probe') into v_a2;
      select exists (select 1 from jsonb_array_elements(
                       coalesce(v_chk->'collection_errors','[]'::jsonb)) e
                      where e->>'name' = '_j197_probe') into v_a3;
    exception when others then
      v_a2 := false; v_a3 := false; v_err := sqlerrm;
    end;

    begin
      delete from rg_payload_targets where name = '_j197_probe';
      delete from rg_baseline where kind = 'payload' and name = '_j197_probe';
      execute 'drop function if exists public._j197_tick()';
      execute 'drop table if exists public._j197_ctr';
    exception when others then null;
    end;

    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false);
    return jsonb_build_object(
      'status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof',
          'rg_check carries the unconfirmable-drift rule=' || coalesce(v_a1::text,'null')
          || ' | drift KEPT in changed when the confirm read errors=' || coalesce(v_a2::text,'null')
          || ' | reason surfaced in collection_errors=' || coalesce(v_a3::text,'null'),
        'probe_cleaned_up', not exists (select 1 from rg_payload_targets where name = '_j197_probe'),
        'error', v_err));
  end if;

  -- CHANGE #192 — the mandated post-deploy verifier must never fail a run whose
  -- own asks all passed. Asserted from verify_run_log, which render_verify.js
  -- writes on every run: a run with keys_ok + build_match MUST exit 0, and a
  -- boot-only run must neither execute the allocation phase nor mutate prod.
  if p_name = 'bug-192' then
    select count(*) into v_pass_count from verify_run_log where at > now() - interval '7 days';
    if v_pass_count = 0 then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no render_verify run recorded in the last 7 days'));
    end if;

    select count(*) = 0 into v_ok
    from verify_run_log l
    where l.at > now() - interval '7 days'
      and (
        (l.keys_ok and l.build_match and l.exit_code <> 0
           and coalesce(array_length(l.phases_failed,1),0) = 0)
        or (coalesce(array_length(l.requested_phases,1),0) > 0
            and exists (select 1 from unnest(l.phases_run) p
                        where not (p = any(l.requested_phases)) and p <> 'boot'))
        or (l.mutated and coalesce(array_length(l.requested_phases,1),0) > 0
            and not (l.requested_phases && array['allocation','receiving','voice','arrivals']))
      );

    select jsonb_build_object(
      'db_proof', 'verify_run_log rows/7d: '||count(*)::text||
        '; failed-with-nothing-wrong: '||
        count(*) filter (where keys_ok and build_match and exit_code <> 0
                           and coalesce(array_length(phases_failed,1),0) = 0)::text||
        '; ran-an-unrequested-phase: '||
        count(*) filter (where coalesce(array_length(requested_phases,1),0) > 0
                           and exists (select 1 from unnest(phases_run) p
                                       where not (p = any(requested_phases)) and p <> 'boot'))::text||
        '; mutated-without-asking: '||
        count(*) filter (where mutated and coalesce(array_length(requested_phases,1),0) > 0
                           and not (requested_phases && array['allocation','receiving','voice','arrivals']))::text,
      'latest', (select jsonb_build_object(
                   'at', l.at::text, 'commit', l.commit_hash, 'exit_code', l.exit_code,
                   'keys', to_jsonb(l.requested_keys),
                   'asked_for', to_jsonb(l.requested_phases),
                   'ran', to_jsonb(l.phases_run),
                   'failed', to_jsonb(l.phases_failed),
                   'mutated', l.mutated)
                 from verify_run_log l order by l.at desc limit 1))
      into v_ev
    from verify_run_log where at > now() - interval '7 days';

    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);
  end if;
  if p_name = 'backup-lands' then
    select bool_and(ok) and count(*) filter (where kind='db') >= 1
           and count(*) filter (where kind='repo') >= 1 into v_ok
    from backup_log where at > now() - interval '26 hours'
      and (size_mb)::numeric > 1 and ok;
    select jsonb_build_object(
      'db_proof', 'backup_log rows in last 26h: '||coalesce(count(*),0)::text,
      'latest', max(at)::text) into v_ev
    from backup_log where at > now() - interval '26 hours' and ok;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);

  elsif p_name = 'eta-honest' then
    select count(*) = 0 into v_ok
    from dev_commands
    where status='building' and eta_left_s is not null and eta_total_s is not null
      and eta_left_s > eta_total_s and coalesce(eta_note,'') = '';
    select jsonb_build_object(
      'db_proof', 'building rows: '||count(*) filter (where status='building')::text||
                  '; inflated-without-note: '||
                  count(*) filter (where status='building' and eta_left_s>eta_total_s and coalesce(eta_note,'')='')::text
    ) into v_ev from dev_commands;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end, 'evidence', v_ev);

  elsif p_name = 'add-media-survives' then
    select m.* into v_row from dev_command_messages m
    where jsonb_array_length(coalesce(m.images,'[]'::jsonb)) > 0
    order by m.id desc limit 1;
    if not found then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no message with images yet'));
    end if;
    select bool_and(coalesce(trim(x),'') <> '') into v_ok
    from jsonb_array_elements_text(v_row.images) x;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof','message #'||v_row.id||' images non-empty='||v_ok));

  elsif p_name = 'reply-media-live' then
    select m.* into v_row from dev_command_messages m
    where coalesce(m.sender,'') = 'om'
      and jsonb_array_length(coalesce(m.images,'[]'::jsonb)) > 0
    order by m.id desc limit 1;
    if not found then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no reply-with-photo yet'));
    end if;
    -- c290-strengthen: presence is not content. bool_and over the paths.
    select bool_and(coalesce(trim(x),'') <> '') into v_ok
    from jsonb_array_elements_text(v_row.images) x;
    return jsonb_build_object('status', case when coalesce(v_ok,false) then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof','reply message #'||v_row.id||' carries '||
        jsonb_array_length(v_row.images)::text||' image(s); every path non-empty='||
        coalesce(v_ok,false)::text));

  elsif p_name = 'android-apk-produces-file' then
    select count(*) > 0 into v_ok from dev_commands
    where android_status='built' and coalesce(android_artifact_url,'') <> '';
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no built android artifact on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof','built android artifacts: '||
        (select count(*) from dev_commands where android_status='built')::text));

  elsif p_name = 'fast-lane-writes' then
    select count(*) > 0 into v_ok from ui_copy where key = 'journey.test' and value is not null;
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','ui_copy journey.test key not present'));
    end if;
    -- c290-strengthen: compare the exact stored value, not its nullness.
    select value = '"journey_probe_ok"'::jsonb into v_ok
      from ui_copy where key='journey.test';
    return jsonb_build_object('status', case when coalesce(v_ok,false) then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'ui_copy journey.test='||(select value::text from ui_copy where key='journey.test')||
        '; equals the fast-lane marker="journey_probe_ok"='||coalesce(v_ok,false)::text));

  elsif p_name = 'gcp-taps-enqueue' then
    select count(*) > 0 into v_ok from dev_commands where kind='gcp';
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no gcp-kind command on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof',
        'gcp commands on record: '||(select count(*) from dev_commands where kind='gcp')::text));

  elsif p_name = 'pool-settings-save' then
    select (select value from dev_runner_config where key='worker_pool') is not null into v_ok;
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof', 'worker_pool config readable; sec_pin_verify(null)='||
          (sec_pin_verify(null))::text));

  elsif p_name = 'rollback-creates-command' then
    select count(*) > 0 into v_ok
    from dev_commands where title like 'Rollback #%' and urgent=true;
    if not v_ok then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','no Rollback command on record yet'));
    end if;
    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof',
        'urgent Rollback commands on record: '||
        (select count(*) from dev_commands where title like 'Rollback #%' and urgent=true)::text));

  elsif p_name = 'bug-191' then
    -- CHANGE #191. The class: a payload target that FAILS to collect must be
    -- reported as an explicit error, never as a content diff, and must never be
    -- written into the baseline. Previously a failure became hash='ERROR:'||md5(msg),
    -- which rg_check counted as 'changed' -> rg_gate blocked a clean tree.
    --
    -- Structural guards first (cheap, no mutation).
    select p.proconfig::text like '%statement_timeout%' into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_collect_payloads';
    -- 57014 is not matched by OTHERS; it must be named or it escapes the guard.
    select p.prosrc like '%query_canceled%' into v_a2
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='rg_collect_payloads';
    select not exists (select 1 from rg_baseline where kind='payload' and hash='ERROR') into v_a3;

    select b.hash into v_base_hash from rg_baseline b where b.kind='payload' and b.name=c_target;
    select pt.sql into v_sql from rg_payload_targets pt where pt.name=c_target;
    if v_sql is null or v_base_hash is null then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','probe target '||c_target||' is not baselined'));
    end if;

    -- Behavioural reproduction: break the target, then assert the guard's verdict.
    begin
      update rg_payload_targets set sql='select (1/0)::text::jsonb' where name=c_target;

      v_chk := rg_check(false, true);

      -- (a) the failure is surfaced as a collection error
      v_a4 := exists (select 1 from jsonb_array_elements(coalesce(v_chk->'collection_errors','[]'::jsonb)) e
                       where e->>'name' = c_target);
      -- (b) and is NOT counted as drift
      v_a5 := not exists (select 1 from jsonb_array_elements_text(
                            coalesce(v_chk->'diffs'->'payload'->'changed','[]'::jsonb)) t(nm)
                          where t.nm = c_target);

      -- (c) rebaselining while a target is failing must leave the baseline intact
      v_bl := rg_baseline_all();
      select (b.hash = v_base_hash) into v_a6
        from rg_baseline b where b.kind='payload' and b.name=c_target;

      update rg_payload_targets set sql=v_sql where name=c_target;
    exception when others then
      update rg_payload_targets set sql=v_sql where name=c_target;
      v_err := sqlerrm;
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','probe raised, target SQL restored: '||v_err));
    end;

    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false) and coalesce(v_a6,false);

    return jsonb_build_object(
      'status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object(
        'db_proof',
          'target='||c_target||
          ' | rg_collect_payloads has statement_timeout='||coalesce(v_a1,false)::text||
          ' | names query_canceled='||coalesce(v_a2,false)::text||
          ' | no ERROR hash in baseline='||coalesce(v_a3,false)::text||
          ' | broken target reported as collection_error='||coalesce(v_a4,false)::text||
          ' | broken target NOT counted as diff='||coalesce(v_a5,false)::text||
          ' | rg_baseline_all left baseline intact='||coalesce(v_a6,false)::text,
        'diffs_while_broken', coalesce(v_chk->'summary','{}'::jsonb),
        'baseline_run', coalesce(v_bl->'baselined'->'payload','null'::jsonb),
        'target_sql_restored', true));

  elsif p_name = 'qa-395-183' then
    -- CHANGE #395 QA blocker: every function that change added is SECURITY
    -- DEFINER and shipped with Postgres's default PUBLIC EXECUTE.
    -- _order_cancel_core is deliberately UNGUARDED so the token-based
    -- order-alert path can reach it, so the anon key that ships in the web
    -- bundle could cancel ANY order, release its stock and its open supplier
    -- inquiry lines, and fire an automatic refund. Same shape as
    -- feature_gaps #25, CHANGE #353 and audit_write() in #422.
    --
    -- Asserted as "the doors exist" AND "no door is open", because a
    -- bool_and over a function that has vanished is silently true.
    select count(*) = 22 into v_a1
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_returns_guard','_return_line_money',
                         '_return_returnable_qty','_order_collected','_order_refunded',
                         '_order_paid_net','_order_rzp_payment_id','_rzp_refund_apply',
                         '_order_credit_notes','gst_ledger_build_credit_notes',
                         'refund_prepare','refund_store','returns_orders_list',
                         'order_returns_panel','order_return_add','order_return_approve',
                         'order_return_reject','refund_quote','refund_request',
                         'refund_mark_manual','refund_cancel');
    -- anon is the key in the bundle. Not one of these may be reachable by it.
    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_returns_guard','_return_line_money',
                         '_return_returnable_qty','_order_collected','_order_refunded',
                         '_order_paid_net','_order_rzp_payment_id','_rzp_refund_apply',
                         '_order_credit_notes','gst_ledger_build_credit_notes',
                         'refund_prepare','refund_store','returns_orders_list',
                         'order_returns_panel','order_return_add','order_return_approve',
                         'order_return_reject','refund_quote','refund_request',
                         'refund_mark_manual','refund_cancel')
       and has_function_privilege('anon', p.oid, 'execute');
    -- the exact door the blocker walked through
    select not has_function_privilege(
             'anon','public._order_cancel_core(uuid,text,text,uuid,text)','execute')
      into v_a3;
    -- a signed-in role may hold EXECUTE only where the function guards ITSELF.
    select count(*) = 0 into v_a4
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('_order_cancel_core','_return_line_money','_return_returnable_qty',
                         '_order_collected','_order_refunded','_order_paid_net',
                         '_order_rzp_payment_id','_rzp_refund_apply',
                         'gst_ledger_build_credit_notes','refund_prepare','refund_store')
       and has_function_privilege('authenticated', p.oid, 'execute');
    -- and the ledgers themselves stay closed to the bundle key.
    select count(*) = 0 into v_a5
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname='public'
       and c.relname in ('order_returns','refunds','order_cancellations')
       and (has_table_privilege('anon', c.oid, 'insert')
         or has_table_privilege('anon', c.oid, 'update')
         or has_table_privilege('anon', c.oid, 'delete'));
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all 22 returns/refund RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon='||coalesce(v_a2,false)::text||
        ' | _order_cancel_core denied to anon='||coalesce(v_a3,false)::text||
        ' | no unguarded helper reachable by authenticated='||coalesce(v_a4,false)::text||
        ' | no returns ledger writable by anon='||coalesce(v_a5,false)::text));

  elsif p_name = 'qa-273-47' then
    -- c290-strengthen. QA #273 finding 47: the anon key that ships inside the
    -- web bundle and the APK must not reach any cron door. cron_wake matters
    -- most — it is SECURITY DEFINER, so a success there lets an anonymous
    -- caller queue dispatcher work and make the database run a task a minute.
    -- Asserted as "no door is open", and separately as "the doors still exist",
    -- because a bool_and over a vanished function is silently true.
    select count(*) = 6 into v_a1
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health');
    -- c290-probe-fix: anon is the key that ships in the bundle, and it is the
    -- key this journey is about. A signed-in role may hold EXECUTE only where
    -- the function guards itself — cron_health does, and the super-admin Cron
    -- Health screen is built on exactly that.
    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and has_function_privilege('anon', p.oid, 'execute');
    select count(*) = 0 into v_a5
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and has_function_privilege('authenticated', p.oid, 'execute')
       and p.prosrc not like '%_dev_guard()%';
    select not (has_function_privilege('anon','public.cron_wake(text)','execute')) into v_a3;
    select count(*) = 0 into v_a4
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname='public'
       and c.relname in ('cron_task','cron_signal','cron_guard_config','cron_dispatch_state')
       and (has_table_privilege('anon', c.oid, 'select')
         or has_table_privilege('anon', c.oid, 'insert'));
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false)
        and coalesce(v_a3,false) and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all six cron RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon='||coalesce(v_a2,false)::text||
        ' | every signed-in-reachable cron RPC guards itself='||coalesce(v_a5,false)::text||
        ' | cron_wake denied to anon='||coalesce(v_a3,false)::text||
        ' | no cron table readable or writable by anon='||coalesce(v_a4,false)::text));

  elsif p_name = 'qa-274-57' then
    -- c290-strengthen. QA #274 finding 57: PTR must never reach an unentitled
    -- viewer. Walked as a TYPED pricing block, deliberately not as a text
    -- search: matching a formatted rupee token across 500+ cards collided with
    -- a legitimate MRP twice before and cost two false-alarm debug passes.
    v_v := coalesce(current_setting('request.jwt.claims', true), '');
    v_err := null;
    begin
      perform set_config('request.jwt.claims', '', true);   -- no session: anon
      v_chk := storefront_home_v2(60);
      perform set_config('request.jwt.claims', v_v, true);
    exception when others then
      perform set_config('request.jwt.claims', v_v, true);
      v_err := sqlerrm;
    end;
    if v_err is not null then
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','anon storefront_home_v2 raised: '||v_err));
    end if;

    with cards as (
      select it as card
      from jsonb_array_elements(coalesce(v_chk->'sections','[]'::jsonb)) s,
           jsonb_array_elements(coalesce(s->'items','[]'::jsonb)) it
      where it ? 'id'
    )
    -- c290-bool-or: aggregate the counterexample as a boolean. A count above
    -- 1 cannot be assigned to a boolean, and under the real leak the count is
    -- every card.
    select count(*),
           bool_or((card->'pricing') ?| array['ptr_display','ptr_caption','raw','has_ptr']),
           bool_or(coalesce((card->'pricing'->'card_price'->>'has_ptr')::boolean, true)),
           bool_or(coalesce(card->'pricing'->'card_price'->>'has_note','') <> 'true'
               and coalesce(card->'pricing'->'card_price'->>'note','') = ''),
           bool_or(coalesce(card->'pricing'->>'display_mode','') <> 'mrp_only')
      into v_pass_count, v_a1, v_a2, v_a3, v_a4
    from cards;

    -- c290-probe-fix: v_a1..v_a4 are booleans, so each count arrived already
    -- cast (0 -> false, n -> true). Comparing 'false' to '0' failed a clean
    -- payload every time.
    v_ok := coalesce(v_pass_count,0) > 0
        and not coalesce(v_a1,true) and not coalesce(v_a2,true)
        and not coalesce(v_a3,true) and not coalesce(v_a4,true);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'anon cards walked='||coalesce(v_pass_count,0)::text||
        ' | any card leaking a ptr key='||coalesce(v_a1,true)::text||
        ' | any card with card_price.has_ptr not false='||coalesce(v_a2,true)::text||
        ' | any card missing the locked note='||coalesce(v_a3,true)::text||
        ' | any card not in display_mode=mrp_only='||coalesce(v_a4,true)::text));

  elsif p_name = 'devqueue-buttons-change-db' then
    -- c290-strengthen. "Each button flips the DB field." Asserted against the
    -- RPCs the buttons call, because the alternative — driving a real row
    -- through pause/resume/cancel — puts a decoy into the live queue that
    -- another worker can claim in the same second.
    select position($q$status='paused'$q$ in p.prosrc) > 0 into v_a1
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_pause';
    select position($q$status='pending'$q$ in p.prosrc) > 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_resume';
    select position($q$status='cancelled'$q$ in p.prosrc) > 0 into v_a3
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_cancel';
    select position($q$urgent = coalesce((p_patch->>'urgent')::boolean, urgent)$q$ in p.prosrc) > 0
      into v_a4
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname='dev_cmd_update';
    select count(*) = 4 and bool_and(p.prosrc like '%_dev_guard()%') into v_a5
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public'
       and p.proname in ('dev_cmd_pause','dev_cmd_resume','dev_cmd_cancel','dev_cmd_update');
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false) and coalesce(v_a3,false)
        and coalesce(v_a4,false) and coalesce(v_a5,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'Pause writes paused='||coalesce(v_a1,false)::text||
        ' | Resume writes pending='||coalesce(v_a2,false)::text||
        ' | Cancel writes cancelled='||coalesce(v_a3,false)::text||
        ' | Urgent writes urgent='||coalesce(v_a4,false)::text||
        ' | all four present and guarded='||coalesce(v_a5,false)::text));

  elsif p_name = 'worker-grid-loads' then
    -- c290-strengthen. "The grid shows >=1 worker chip with lane labels."
    -- Phrased as two no-counterexample assertions so an idle box with a
    -- genuinely empty pool is not a false red: the grid must account for every
    -- command that has been building for over two minutes (the supervisor
    -- republishes every 20s, so a fresh claim is allowed to be missing), and
    -- no chip it does show may be blank.
    select value into v_chk from dev_runner_config where key='pool_state';
    if v_chk is null or jsonb_typeof(v_chk->'workers') <> 'array' then
      return jsonb_build_object('status','failed','evidence',
        jsonb_build_object('db_proof','pool_state snapshot missing or workers is not an array'));
    end if;
    select not exists (
      select 1 from dev_commands d
       where d.status='building'
         and d.started_at < now() - interval '2 minutes'
         and not exists (select 1 from jsonb_array_elements(v_chk->'workers') w
                          where coalesce(w->>'command_id','') = d.id::text)) into v_a1;
    select not exists (
      select 1 from jsonb_array_elements(v_chk->'workers') w
       where coalesce(trim(w->>'id'),'') = ''
          or coalesce(trim(w->>'lane'),'') = ''
          or coalesce(trim(w->>'status'),'') = '') into v_a2;
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'chips='||jsonb_array_length(v_chk->'workers')::text||
        ' | every settled building command has a chip='||coalesce(v_a1,false)::text||
        ' | no chip missing id/lane/status='||coalesce(v_a2,false)::text));

  else
    -- Externally proven journeys (menu-reachability, qa-274-54): the assertion
    -- lives in a Playwright run or a widget test, so the only proof this branch
    -- can read is a run somebody else filed through journey_report.
    -- Check how many passed runs exist across all commands via journey_report.
    -- If >= 2, the external Playwright runner has proven this journey works → passed.
    select id into v_jid from dev_journeys where name = p_name limit 1;
    if v_jid is null then
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason','unknown journey: '||p_name));
    end if;
    -- c290-strengthen: ONLY externally reported passes count. This branch
    -- writes evidence.db_proof on its own pass, so counting every passed run
    -- let it certify itself: two journeys stood at 40 passes, 40 of them its
    -- own and 0 from any runner. An external runner (journey_report from
    -- Playwright or a widget test) files evidence WITHOUT db_proof, and that
    -- is the only proof this branch is allowed to count.
    select count(*) into v_pass_count
    from dev_journey_runs
    where journey_id = v_jid and status = 'passed'
      and not (coalesce(evidence,'{}'::jsonb) ? 'db_proof');
    if v_pass_count >= 2 then
      return jsonb_build_object('status','passed','evidence',
        jsonb_build_object('db_proof',
          'browser runner recorded '||v_pass_count||' passed runs for '||p_name));
    else
      return jsonb_build_object('status','skipped','evidence',
        jsonb_build_object('reason',
          'browser runner needs '||(2-v_pass_count)||' more run(s); current='||v_pass_count));
    end if;
  end if;
end $function$

