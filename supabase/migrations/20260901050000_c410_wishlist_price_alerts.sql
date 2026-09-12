-- CMD #410 part 1 — WISHLIST PRICE ALERTS.
--
-- wishlist_items and its RPCs shipped in #160 and nothing has ever watched
-- them: a pharmacy saved a product and was never told when its rate moved or
-- when it came back. This adds the watcher.
--
-- Three deliberate choices, all of them about NOT firing a storm:
--
--  1. NO TRIGGER on medicine_pricing or on "MEDICINE". A price import updates
--     thousands of rows in one statement; a per-row trigger would turn one
--     import into one message per row per wisher. Instead a SNAPSHOT of the
--     wishlisted products only (a handful of rows, never the 563k catalogue)
--     is compared on the dispatcher's own schedule. One import => at most one
--     queue row per (customer, product, kind).
--  2. NO new pg_cron job. CHANGE #305 cut 57 jobs to one dispatcher and the
--     outage of 2026-08-18 was cron jobs colliding on minute 0. Both halves
--     register as cron_task rows and ride that dispatcher.
--  3. ONE DIGEST PER CUSTOMER PER IST DAY, never urgent. The queue absorbs
--     every change; the sender collapses whatever is pending into a single
--     notify() call. A day the customer already got a digest sends nothing
--     more, however many prices moved.
--
-- Money and percentages are computed by _pricing_compute() — the SAME function
-- the storefront price block uses — so an alert can never quote a number the
-- product page would disagree with. Every visible string is a
-- storefront_ui_label row: changing the wording is an UPDATE, not a deploy.

-- ── the snapshot: what we last saw for a product somebody wishes for ────────
create table if not exists public.wishlist_watch (
  product_id   bigint primary key,
  last_net     numeric,
  last_ptr     numeric,
  last_margin  numeric,
  last_buyable boolean,
  seen_at      timestamptz not null default now()
);

-- ── the queue: one pending row per (customer, product, kind) ────────────────
create table if not exists public.wishlist_alert_queue (
  id          bigserial primary key,
  account_id  uuid   not null,
  product_id  bigint not null,
  kind        text   not null,
  detail      jsonb  not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  digest_on   date
);

-- The dedupe that makes a price import safe: a second change to the same
-- product before the digest goes out UPDATES the pending row, it does not add
-- a second one.
create unique index if not exists ux_wishlist_alert_pending
  on public.wishlist_alert_queue (account_id, product_id, kind)
  where sent_at is null;
create index if not exists ix_wishlist_alert_pending_acct
  on public.wishlist_alert_queue (account_id) where sent_at is null;

-- ── the digest ledger: proof that a customer got at most one per IST day ────
create table if not exists public.wishlist_digest_log (
  account_id uuid not null,
  digest_on  date not null,
  sent_at    timestamptz not null default now(),
  items      integer not null default 0,
  result     jsonb,
  primary key (account_id, digest_on)
);

alter table public.wishlist_watch        enable row level security;
alter table public.wishlist_alert_queue  enable row level security;
alter table public.wishlist_digest_log   enable row level security;

-- No policies on purpose: every read goes through a SECURITY DEFINER RPC that
-- scopes to my_customer_id(). RLS on with no policy = anon and authenticated
-- see nothing directly, which is what CHANGE #305's grant sweep asked for.
revoke all on public.wishlist_watch       from anon, authenticated;
revoke all on public.wishlist_alert_queue from anon, authenticated;
revoke all on public.wishlist_digest_log  from anon, authenticated;

-- ── copy (backend-owned, one UPDATE to reword) ──────────────────────────────
insert into public.storefront_ui_label (key, value, note) values
  ('wl_alert_title',        'Price & stock alerts',                                  'Wishlist alerts block heading'),
  ('wl_alert_empty',        'No changes since you saved these.',                     'Wishlist alerts empty state'),
  ('wl_alert_price_drop',   'Rate dropped',                                          'Alert chip — net rate fell'),
  ('wl_alert_price_rise',   'Rate went up',                                          'Alert chip — net rate rose'),
  ('wl_alert_margin_up',    'Margin improved',                                       'Alert chip — margin rose'),
  ('wl_alert_back_in_stock','Back in stock',                                         'Alert chip — availability returned'),
  ('wl_alert_from_to',      'from {from} to {to}',                                   'Alert detail — old to new value'),
  ('wl_alert_digest_note',  'One update a day — we never send a price alert twice.', 'Wishlist alerts footnote')
on conflict (key) do nothing;

-- The notification route. push_enabled = true because the dispatcher spec says
-- push first; notify() falls through to the WhatsApp template on its own when
-- there is no device token.
insert into public.wa_event_routes
  (event_key, label, description, audience, enabled, push_enabled, push_title, push_body, wa_category)
values
  ('wishlist_digest', 'Wishlist daily update',
   'One daily digest of price and stock changes on a customer''s wishlist',
   'customer', true, true, 'Your wishlist changed', '{{summary}}', 'marketing')
on conflict (event_key) do nothing;

-- ═══════════════════════════════════════════════════════════════════════════
-- THE SCAN — set-based, over wishlisted products only.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.wishlist_alert_scan()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare
  v_new      int := 0;
  v_watched  int := 0;
begin
  -- Current truth for every product at least one customer wishes for. The
  -- numbers come from _pricing_compute(), the same routine _pricing_block()
  -- runs for the storefront, so an alert and the product page can never
  -- disagree. Nothing here depends on a viewer: the ledger values are the
  -- catalogue's own, and entitlement is applied when the digest is RENDERED.
  -- Dropped first so the function is safe to call twice inside ONE
  -- transaction — which the proof script does, and which a dispatcher retry
  -- could do too. `on commit drop` alone would raise "relation already
  -- exists" on the second call.
  drop table if exists _wl_now;
  create temporary table _wl_now on commit drop as
  with wp as (
    select distinct wi.product_id from public.wishlist_items wi
  )
  select m.id                                             as product_id,
         coalesce(m.product_name, '')                     as name,
         (lower(coalesce(m.buyable::text,'')) in ('true','t')) as buyable,
         case when coalesce(mp.pricing_ready, false)
              then (public._pricing_compute(
                      nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
                      mp.ptr, mp.gst_pct, coalesce(mp.discount_pct, 0),
                      mp.scheme_buy_qty, mp.scheme_free_qty, false)) end as calc,
         mp.ptr                                           as ptr
    from wp
    join public."MEDICINE" m on m.id = wp.product_id
    left join public.medicine_pricing mp on mp.product_id = m.id;

  select count(*) into v_watched from _wl_now;

  -- First sight of a product is NEVER an alert. There is no "before" to
  -- compare against, and inventing one would tell a pharmacy a rate changed
  -- on the day we started looking.
  insert into public.wishlist_watch (product_id, last_net, last_ptr, last_margin, last_buyable, seen_at)
  select n.product_id,
         (n.calc->>'net_payable')::numeric,
         n.ptr,
         (n.calc->>'margin_pct')::numeric,
         n.buyable,
         now()
    from _wl_now n
  on conflict (product_id) do nothing;

  -- The changes worth telling a buyer about. Each one needs a REAL number on
  -- BOTH sides: no rate before or no rate now => no alert, never a "0%".
  with changed as (
    select n.product_id, n.name, n.buyable,
           (n.calc->>'net_payable')::numeric as net,
           (n.calc->>'margin_pct')::numeric  as margin,
           w.last_net, w.last_margin, w.last_buyable
      from _wl_now n
      join public.wishlist_watch w on w.product_id = n.product_id
  ), events as (
    select c.product_id, c.name, 'price_drop'::text as kind,
           jsonb_build_object('from', c.last_net, 'to', c.net,
                              'from_display', public.inr_money(c.last_net),
                              'to_display',   public.inr_money(c.net)) as detail
      from changed c
     where c.net is not null and c.last_net is not null and c.net < c.last_net
    union all
    select c.product_id, c.name, 'price_rise',
           jsonb_build_object('from', c.last_net, 'to', c.net,
                              'from_display', public.inr_money(c.last_net),
                              'to_display',   public.inr_money(c.net))
      from changed c
     where c.net is not null and c.last_net is not null and c.net > c.last_net
    union all
    select c.product_id, c.name, 'margin_up',
           jsonb_build_object('from', c.last_margin, 'to', c.margin,
                              'from_display', public._num_label(c.last_margin) || '%',
                              'to_display',   public._num_label(c.margin) || '%')
      from changed c
     where c.margin is not null and c.last_margin is not null and c.margin > c.last_margin
    union all
    select c.product_id, c.name, 'back_in_stock', '{}'::jsonb
      from changed c
     where c.buyable and coalesce(c.last_buyable, false) = false
  )
  insert into public.wishlist_alert_queue (account_id, product_id, kind, detail)
  select wi.account_id, e.product_id, e.kind, e.detail
    from events e
    join public.wishlist_items wi on wi.product_id = e.product_id
  on conflict (account_id, product_id, kind) where sent_at is null
  do update set detail = excluded.detail, created_at = now();
  get diagnostics v_new = row_count;

  -- The snapshot moves to now(), so the same change is never queued twice.
  update public.wishlist_watch w
     set last_net     = (n.calc->>'net_payable')::numeric,
         last_ptr     = n.ptr,
         last_margin  = (n.calc->>'margin_pct')::numeric,
         last_buyable = n.buyable,
         seen_at      = now()
    from _wl_now n
   where n.product_id = w.product_id
     and (w.last_net     is distinct from (n.calc->>'net_payable')::numeric
       or w.last_ptr     is distinct from n.ptr
       or w.last_margin  is distinct from (n.calc->>'margin_pct')::numeric
       or w.last_buyable is distinct from n.buyable);

  -- A product nobody wishes for any more stops being watched.
  delete from public.wishlist_watch w
   where not exists (select 1 from public.wishlist_items wi where wi.product_id = w.product_id);

  return jsonb_build_object('ok', true, 'watched', v_watched, 'queued', v_new);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- THE DIGEST — one notify() per customer per IST day. Never urgent.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.wishlist_alert_digest(p_limit integer default 25)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_catalog'
as $function$
declare
  r        record;
  v_today  date := (now() at time zone 'Asia/Kolkata')::date;
  v_sent   int  := 0;
  v_skip   int  := 0;
  v_lines  text;
  v_n      int;
  v_ph     text;
  v_res    jsonb;
begin
  for r in
    select q.account_id, count(*) as n
      from public.wishlist_alert_queue q
     where q.sent_at is null
       and not exists (select 1 from public.wishlist_digest_log d
                        where d.account_id = q.account_id and d.digest_on = v_today)
     group by q.account_id
     order by min(q.created_at)
     limit greatest(coalesce(p_limit, 25), 1)
  loop
    select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''), '\D', '', 'g'), 10)
      into v_ph
      from public.pharmacy_profiles pp
     where pp.id = r.account_id;

    -- Every line is a storefront_ui_label plus the product's own name; the
    -- sender writes no sentence of its own.
    select string_agg(l.line, E'\n' order by l.ord), count(*)
      into v_lines, v_n
      from (
        select coalesce(m.product_name, '') || ' — ' ||
               coalesce((select value from public.storefront_ui_label
                          where key = 'wl_alert_' || q.kind), q.kind) ||
               case when q.detail ? 'to_display'
                    then ' ' || replace(replace(
                           coalesce((select value from public.storefront_ui_label where key = 'wl_alert_from_to'), ''),
                           '{from}', coalesce(q.detail->>'from_display','')),
                           '{to}',   coalesce(q.detail->>'to_display',''))
                    else '' end as line,
               q.created_at as ord
          from public.wishlist_alert_queue q
          join public."MEDICINE" m on m.id = q.product_id
         where q.account_id = r.account_id and q.sent_at is null
      ) l;

    if coalesce(v_n, 0) = 0 then
      v_skip := v_skip + 1;
      continue;
    end if;

    -- notify() decides push-vs-template on its own (CHANGE #298 puts push
    -- first). It is called ONCE per customer per day — the batching this
    -- whole file exists for.
    v_res := public.notify('wishlist_digest', v_ph,
               jsonb_build_object('summary', v_lines,
                                  'count', v_n::text,
                                  'customer_id', r.account_id::text));

    update public.wishlist_alert_queue
       set sent_at = now(), digest_on = v_today
     where account_id = r.account_id and sent_at is null;

    insert into public.wishlist_digest_log (account_id, digest_on, items, result)
    values (r.account_id, v_today, v_n, v_res)
    on conflict (account_id, digest_on) do update
      set items = excluded.items, result = excluded.result, sent_at = now();

    v_sent := v_sent + 1;
  end loop;

  return jsonb_build_object('ok', true, 'digests_sent', v_sent, 'skipped', v_skip, 'day', v_today);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- THE CUSTOMER-FACING READ — the alert block the wishlist screen renders.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.wishlist_alerts()
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_acct  uuid := public.my_customer_id();
  v_ent   boolean := public.viewer_sees_trade_price();
  v_items jsonb;
begin
  if v_acct is null then
    return jsonb_build_object('ok', false, 'error', 'not_customer', 'has', false, 'items', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(x.row order by x.ord desc), '[]'::jsonb) into v_items
    from (
      select jsonb_build_object(
               'product_id', q.product_id::text,
               'name',       coalesce(m.product_name, ''),
               'kind',       q.kind,
               'label',      coalesce((select value from public.storefront_ui_label
                                        where key = 'wl_alert_' || q.kind), ''),
               -- A rate movement is a TRADE number. An unentitled viewer gets
               -- the fact that it changed and no figure at all — the same rule
               -- the price block applies, not a second one invented here.
               'has_detail', (v_ent and q.detail ? 'to_display'),
               'detail',     case when v_ent and q.detail ? 'to_display'
                                  then replace(replace(
                                         coalesce((select value from public.storefront_ui_label where key='wl_alert_from_to'),''),
                                         '{from}', coalesce(q.detail->>'from_display','')),
                                         '{to}',   coalesce(q.detail->>'to_display',''))
                                  else '' end,
               'tone',       case q.kind
                               when 'price_drop'    then 'success'
                               when 'margin_up'     then 'success'
                               when 'back_in_stock' then 'info'
                               else 'warning' end) as row,
             q.created_at as ord
        from public.wishlist_alert_queue q
        join public."MEDICINE" m on m.id = q.product_id
       where q.account_id = v_acct
         and q.created_at >= now() - interval '30 days'
       order by q.created_at desc
       limit 25) x;

  return jsonb_build_object(
    'ok',    true,
    'has',   jsonb_array_length(v_items) > 0,
    'title', coalesce((select value from public.storefront_ui_label where key='wl_alert_title'), ''),
    'empty', coalesce((select value from public.storefront_ui_label where key='wl_alert_empty'), ''),
    'note',  coalesce((select value from public.storefront_ui_label where key='wl_alert_digest_note'), ''),
    'items', v_items);
end $function$;

grant execute on function public.wishlist_alerts() to authenticated;
revoke execute on function public.wishlist_alert_scan()            from anon, authenticated;
revoke execute on function public.wishlist_alert_digest(integer)   from anon, authenticated;
revoke execute on function public.wishlist_alerts()                from anon;

-- ── register with the ONE dispatcher (CHANGE #305). No new pg_cron job. ─────
insert into public.cron_task
  (name, ord, mode, gate_sql, work_sql, enabled, base_interval_s, max_interval_s, dml, note)
values
  ('wishlist_alert_scan', 395, 'poll',
   'select exists (select 1 from public.wishlist_items)',
   'select public.wishlist_alert_scan()',
   true, 900, 3600, true,
   'CMD #410 — compares a snapshot of wishlisted products only; queues at most one row per customer/product/kind.'),
  ('wishlist_alert_digest', 396, 'poll',
   $gate$select exists (
      select 1 from public.wishlist_alert_queue q
       where q.sent_at is null
         and not exists (select 1 from public.wishlist_digest_log d
                          where d.account_id = q.account_id
                            and d.digest_on = (now() at time zone 'Asia/Kolkata')::date))$gate$,
   'select public.wishlist_alert_digest(25)',
   true, 1800, 3600, true,
   'CMD #410 — one digest per customer per IST day. The gate is the per-day ledger, so a price import cannot storm.')
on conflict (name) do update
  set gate_sql = excluded.gate_sql,
      work_sql = excluded.work_sql,
      note     = excluded.note,
      enabled  = excluded.enabled;
