-- CMD #366 — the customer buying pack, with Om's four customisations.
-- feature_gaps rows 171, 172, 175, 176.
--
-- The rule that shapes all four: NEVER show a number we have not actually
-- earned. mediBO is B2B trade commerce — MRP is the regulatory ceiling and a
-- display field, never the selling price — so a "saving" computed off MRP, a
-- margin estimated without a real PTR, or a delivery date invented from a
-- config window would each be a fabricated number on a pharmacy's buying
-- screen. Every block below is explicitly ABSENT until its real input exists.
--
-- Measured before building (31 Aug 2026): medicine_pricing has 2 rows ready,
-- deliveries has ZERO rows with delivered_at, order_items has 2 unfulfillable
-- lines, and 73,619 of 75,597 buyable products carry salt_composition. So 171
-- and 176 light up immediately; 172 and 175 are correct-and-empty today and
-- fill in as supplier bills and real deliveries land. That is the design.
--
-- Idempotent throughout: a resumed worker re-applies this as a no-op.

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW 171 — SAME-SALT SUBSTITUTES
-- Om: "check first; if a substitute mechanism exists anywhere, extend it."
-- It does: product_detail().similar already matches on salt_composition,
-- filters to buyable and ranks by sales_count. What it lacks is strength/form
-- normalisation, a real price, and a saving. So this EXTENDS that rail into a
-- `substitutes` block and leaves `similar` exactly as it was.
-- ═══════════════════════════════════════════════════════════════════════════

-- The grouping key. Salt, strength and form squashed to a comparable form:
-- case-folded, punctuation-normalised, whitespace-collapsed. Paracetamol
-- 500mg Tablet and PARACETAMOL (500 MG) TABLET are the same buying decision;
-- Paracetamol 650mg is not.
create or replace function public._norm_seg(p text)
returns text language sql immutable as $$
  -- One segment of the key: case-folded, every run of punctuation or space
  -- collapsed to a single space, then trimmed. Done per segment so a bracket
  -- next to the separator ("Paracetamol (500mg)|10 tablets") cannot leave a
  -- stray space that makes two identical compositions compare unequal.
  select btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]+', ' ', 'g'));
$$;

create or replace function public.med_composition_key(
  p_salt text, p_pack_qty text, p_pack_type text)
returns text language sql immutable as $$
  select nullif(public._norm_seg(p_salt) || '|' ||
                public._norm_seg(p_pack_qty) || '|' ||
                public._norm_seg(p_pack_type), '||');
$$;

-- One substitute row, priced. Kept separate from product_detail so the admin
-- and customer substitution surfaces (row 176) read the SAME list — one
-- definition of "what can replace this", never three that drift apart.
create or replace function public.same_composition_options(
  p_product_id bigint, p_limit integer default 10)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  m        record;
  v_disc   numeric := public.my_cart_discount_pct();
  v_self   jsonb;
  v_self_net numeric;
  v_key    text;
  v_items  jsonb;
begin
  select * into m from "MEDICINE" where id = p_product_id;
  if m.id is null then
    return jsonb_build_object('has', false, 'items', '[]'::jsonb);
  end if;

  v_key := public.med_composition_key(m.salt_composition, m.pack_qty, m.pack_type);

  v_self := public.storefront_pricing(
    nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
    v_disc, m.id);
  -- The saving is net-rate against net-rate. MRP is the legal ceiling, not a
  -- price we sell at, so an MRP-based "saves X%" would be a fabricated claim.
  v_self_net := case when coalesce((v_self->>'pricing_ready')::boolean, false)
                     then (v_self->'raw'->>'net_payable')::numeric end;

  with cand as (
    select s.*,
           public.storefront_pricing(
             nullif(regexp_replace(coalesce(s.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
             v_disc, s.id) as pricing,
           case when public.med_composition_key(s.salt_composition, s.pack_qty, s.pack_type) = v_key
                then 'exact' else 'same_salt' end as match_kind
      from "MEDICINE" s
     where s.id <> m.id
       and s.buyable is true
       and nullif(btrim(s.salt_composition),'') is not null
       and s.salt_composition = m.salt_composition
  ), ranked as (
    select c.*,
           case when coalesce((c.pricing->>'has_margin')::boolean, false)
                then (c.pricing->>'margin_pct')::numeric end as margin_pct,
           case when coalesce((c.pricing->>'pricing_ready')::boolean, false)
                then (c.pricing->'raw'->>'net_payable')::numeric end as net
      from cand c
  )
  select coalesce(jsonb_agg(t.x order by t.ord), '[]'::jsonb) into v_items
    from (
      select jsonb_build_object(
               'id',          r.id,
               'name',        coalesce(r.product_name, ''),
               'company',     coalesce(r.marketer, ''),
               'pack_label',  coalesce(nullif(btrim(r.pack_type),''), nullif(btrim(r.pack_size),''), ''),
               'image',       coalesce(r.image_url_1, ''),
               'match',       r.match_kind,
               'match_label', case when r.match_kind = 'exact'
                                   then coalesce((select value from storefront_ui_label where key='sub_match_exact'), '')
                                   else coalesce((select value from storefront_ui_label where key='sub_match_salt'), '') end,
               'availability', public.storefront_cta(
                                 public.storefront_effective_count(r.id, r.supplier_count)),
               'pricing',     r.pricing,
               -- Present ONLY when both sides have a real rate. No rate on
               -- either side => no saving line at all, never a zero and never
               -- an MRP-derived percentage.
               'saving',      case
                 when v_self_net is not null and r.net is not null and r.net < v_self_net
                   then jsonb_build_object(
                          'has', true,
                          'amount', round(v_self_net - r.net, 2),
                          'label', coalesce((select value from storefront_ui_label where key='sub_saving_prefix'), 'Saves')
                                   || ' ' || public.inr_money(round(v_self_net - r.net, 2))
                                   || ' (' || public._num_label(round((v_self_net - r.net) / v_self_net * 100, 1)) || '%)')
                 else jsonb_build_object('has', false, 'label', '') end,
               'margin',      case
                 when r.margin_pct is not null
                   then jsonb_build_object('has', true, 'pct', r.margin_pct,
                                           'chip', r.pricing->'margin_chip')
                 else jsonb_build_object('has', false) end) as x,
             -- exact composition first, then the one that actually earns more,
             -- then the better-selling company (Om's preference for row 176).
             (case when r.match_kind = 'exact' then 0 else 1 end,
              case when r.margin_pct is null then 1 else 0 end,
              coalesce(-r.margin_pct, 0),
              coalesce(-r.sales_count, 0),
              r.id) as ord
        from ranked r
       order by ord
       limit greatest(coalesce(p_limit, 10), 1)) t;

  return jsonb_build_object(
    'has',     jsonb_array_length(v_items) > 0,
    'key',     v_key,
    'heading', coalesce((select value from storefront_ui_label where key='sub_heading'), ''),
    'note',    coalesce((select value from storefront_ui_label where key='sub_note'), ''),
    'empty',   coalesce((select value from storefront_ui_label where key='sub_empty'), ''),
    'items',   v_items);
end $$;

insert into public.storefront_ui_label(key, value, note) values
  ('sub_heading',       'Same composition',                                                   'CMD #366 row 171 — PDP substitutes block heading'),
  ('sub_note',          'Same salt and strength from other companies. Price and margin shown only where we hold a real trade rate.', 'CMD #366 row 171'),
  ('sub_empty',         'No other company on our catalogue carries this exact composition yet.', 'CMD #366 row 171'),
  ('sub_match_exact',   'Same strength & form',                                               'CMD #366 row 171'),
  ('sub_match_salt',    'Same salt',                                                          'CMD #366 row 171'),
  ('sub_saving_prefix', 'Saves',                                                              'CMD #366 row 171 — net rate vs net rate, never MRP'),
  ('margin_filter_title','Margin',                                                            'CMD #366 row 172'),
  ('margin_filter_all', 'Any margin',                                                         'CMD #366 row 172'),
  ('margin_filter_note','Only items with a real trade rate from an imported supplier bill can be filtered by margin.', 'CMD #366 row 172'),
  ('promise_prefix',    'Usually delivered in',                                               'CMD #366 row 175 — rolling average of real deliveries'),
  ('promise_note',      'Based on our own past deliveries to this area.',                     'CMD #366 row 175')
on conflict (key) do update set value = excluded.value, note = excluded.note;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW 172 — MARGIN SORT/FILTER, NO FALSE NUMBERS
-- _pricing_block already refuses to emit has_margin/margin_chip without
-- pricing_ready AND viewer_sees_trade_price(), so a fabricated margin is
-- already impossible at the source. What was missing: a FILTER, and the
-- storefront page honouring it. Both exclude every item without a real rate
-- by construction — they read medicine_pricing, not the catalogue.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.storefront_margin_filter (
  min_pct numeric primary key,
  label   text not null,
  sort    int  not null default 0,
  active  boolean not null default true
);
insert into public.storefront_margin_filter (min_pct, label, sort) values
  (10, 'Above 10%', 1), (15, 'Above 15%', 2), (20, 'Above 20%', 3), (30, 'Above 30%', 4)
on conflict (min_pct) do update set label = excluded.label, sort = excluded.sort;

create or replace function public.storefront_margin_filters(p_active numeric default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_rows jsonb; v_ready int;
begin
  if not (public.viewer_is_approved_customer()
          or public.get_my_role() = any (array['admin','super_admin'])) then
    return jsonb_build_object('has', false, 'options', '[]'::jsonb);
  end if;

  -- The same gate storefront_sort_options uses: with no real rate anywhere the
  -- filter must not appear at all, rather than appear and match nothing.
  select count(*) into v_ready
    from public.medicine_pricing mp
    join "MEDICINE" m on m.id = mp.product_id
   where mp.pricing_ready and lower(coalesce(m.buyable::text,'')) in ('true','t');
  if v_ready = 0 then
    return jsonb_build_object('has', false, 'options', '[]'::jsonb,
      'note', coalesce((select value from storefront_ui_label where key='margin_filter_note'), ''));
  end if;

  select jsonb_agg(jsonb_build_object(
           'min_pct', f.min_pct, 'label', f.label,
           'active', p_active is not null and f.min_pct = p_active)
         order by f.sort)
    into v_rows from public.storefront_margin_filter f where f.active;

  return jsonb_build_object(
    'has', true,
    'title', coalesce((select value from storefront_ui_label where key='margin_filter_title'), ''),
    'note',  coalesce((select value from storefront_ui_label where key='margin_filter_note'), ''),
    'priced_count', v_ready,
    'options', jsonb_build_array(
        jsonb_build_object('min_pct', null,
          'label', coalesce((select value from storefront_ui_label where key='margin_filter_all'), ''),
          'active', p_active is null))
      || coalesce(v_rows, '[]'::jsonb));
end $$;

create or replace function public.storefront_margin_page(
  p_offset integer default 0, p_limit integer default null, p_min_margin numeric default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_initial int := coalesce((select (value #>> '{}')::int from app_settings
                               where key = 'storefront_initial_limit'), 250);
  v_more    int := coalesce((select (value #>> '{}')::int from app_settings
                               where key = 'storefront_more_limit'), 100);
  v_lim     int := greatest(coalesce(nullif(p_limit, 0), v_initial), 1);
  v_off     int := greatest(coalesce(p_offset, 0), 0);
  v_disc    numeric := public.my_cart_discount_pct();
  v_is_admin boolean := public.role_for_medibo_only() = any (array['admin','super_admin']);
  v_total   bigint;
  v_items   jsonb;
  v_n       int;
begin
  if not (public.viewer_is_approved_customer() or v_is_admin) then
    return public.storefront_page('All', v_off, v_lim);
  end if;

  with ready as (
    select mp.product_id,
           ((public._pricing_compute(
               nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
               mp.ptr, mp.gst_pct, v_disc, mp.scheme_buy_qty, mp.scheme_free_qty)
            ) ->> 'margin_pct')::numeric as margin_pct
      from public.medicine_pricing mp
      join "MEDICINE" m on m.id = mp.product_id
     where mp.pricing_ready
       and lower(coalesce(m.buyable::text, '')) in ('true', 't'))
  -- The filter keeps only rows whose REAL margin clears the threshold. An item
  -- with no rate was never in `ready` to begin with, so no null-tolerant
  -- comparison can sweep it in and give it a margin it has not got.
  select count(*) into v_total from ready r
   where p_min_margin is null
      or (r.margin_pct is not null and r.margin_pct >= p_min_margin);

  with ready as (
    select mp.product_id,
           ((public._pricing_compute(
               nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
               mp.ptr, mp.gst_pct, v_disc, mp.scheme_buy_qty, mp.scheme_free_qty)
            ) ->> 'margin_pct')::numeric as margin_pct
      from public.medicine_pricing mp
      join "MEDICINE" m on m.id = mp.product_id
     where mp.pricing_ready
       and lower(coalesce(m.buyable::text, '')) in ('true', 't')),
  page as (
    select r.product_id, r.margin_pct
      from ready r
     where p_min_margin is null
        or (r.margin_pct is not null and r.margin_pct >= p_min_margin)
     order by r.margin_pct desc nulls last, r.product_id
     offset v_off limit v_lim)
  select coalesce(jsonb_agg(
           to_jsonb(m)
           || jsonb_build_object(
                'pack_qty_label',  public.sf_pack_qty_label(m.pack_qty),
                'pack_type_label', public.sf_pack_type_label(m.pack_type))
           || jsonb_build_object('supplier_label',
                case when v_is_admin then coalesce(m.supplier_label, '') else '' end)
           || jsonb_build_object('availability',
                public.storefront_cta(public.storefront_effective_count(m.id,
                  coalesce(nullif(regexp_replace(coalesce(m.supplier_count::text, ''), '[^0-9]', '', 'g'), '')::int, 0))))
           || jsonb_build_object('gst_percent_resolved',
                coalesce(m.gst_percent, public.gst_rate_for(m.therapeutic_class)))
           || jsonb_build_object('pricing', public.storefront_pricing(
                nullif(regexp_replace(coalesce(m.mrp::text, ''), '[^0-9.]', '', 'g'), '')::numeric,
                v_disc, m.id))
           order by p.margin_pct desc nulls last, p.product_id), '[]'::jsonb)
    into v_items
    from page p join "MEDICINE" m on m.id = p.product_id;

  v_n := jsonb_array_length(v_items);

  return jsonb_build_object(
    'status',        'ok',
    'category',      'All',
    'sort',          'margin',
    'sort_options',  public.storefront_sort_options('margin'),
    'margin_filter', public.storefront_margin_filters(p_min_margin),
    'min_margin',    p_min_margin,
    'page_offset',   v_off,
    'page_limit',    v_lim,
    'gated',         public.viewer_is_approved_customer(),
    'showing_label', coalesce((select value from storefront_ui_label
                                 where key = 'sort_margin_showing'), ''),
    'empty_label',   coalesce((select value from storefront_ui_label
                                 where key = 'sort_margin_empty'), ''),
    'total',         v_total,
    'count_label',   to_char(v_total, 'FM9,99,99,999'),
    'initial_limit', v_initial,
    'more_limit',    v_more,
    'next_offset',   v_off + v_n,
    'has_more',      (v_off + v_n) < v_total,
    'more_label',    coalesce((select value from storefront_ui_label
                                 where key = 'load_more_products'), ''),
    'end_label',     coalesce((select value from storefront_ui_label
                                 where key = 'feed_end_label'), ''),
    'items',         v_items);
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW 175 — DELIVERY PROMISE = THE AVERAGE OF OUR OWN ACTUALS
-- Om: rolling average of real past delivery times per zone; early orders seed
-- it; NO history => show nothing rather than an invented time.
-- The existing trg_delivery_stamp_promise is the post-assignment operational
-- SLA (config window, measured against on_time_grace_min) and is deliberately
-- untouched — this is the pre-order promise the buyer sees, which row 175 says
-- exists nowhere today.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.delivery_promise_config (
  id            boolean primary key default true check (id),
  min_samples   int not null default 5,
  window_days   int not null default 60,
  max_samples   int not null default 200,
  round_to_min  int not null default 15,
  updated_at    timestamptz not null default now()
);
insert into public.delivery_promise_config (id) values (true) on conflict (id) do nothing;

create or replace function public._duration_label(p_min int)
returns text language sql immutable as $$
  select case
    when p_min is null then ''
    when p_min < 60 then p_min::text || ' min'
    when p_min % 60 = 0 and p_min < 1440 then (p_min/60)::text || ' hr'
    when p_min < 1440 then (p_min/60)::text || ' hr ' || (p_min%60)::text || ' min'
    when p_min % 1440 = 0 then (p_min/1440)::text || ' day' || case when p_min/1440 = 1 then '' else 's' end
    else (p_min/1440)::text || ' day' || case when p_min/1440 = 1 then '' else 's' end
         || ' ' || ((p_min%1440)/60)::text || ' hr' end;
$$;

create or replace function public.delivery_promise(p_pincode text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  cfg   public.delivery_promise_config%rowtype;
  v_zone smallint;
  v_n   int := 0;
  v_avg numeric;
  v_mins int;
begin
  select * into cfg from public.delivery_promise_config where id;

  if nullif(btrim(coalesce(p_pincode,'')),'') is not null then
    select zone_id into v_zone from public.delivery_serviceability
     where pincode = btrim(p_pincode) and is_active limit 1;
  end if;

  -- Real deliveries only: assigned and actually delivered, inside the window,
  -- most recent first. Zone-scoped when we know the zone, otherwise the
  -- platform-wide average — still our OWN actuals, never a configured guess.
  select count(*), avg(mins) into v_n, v_avg from (
    select extract(epoch from (d.delivered_at - d.assigned_at)) / 60.0 as mins
      from public.deliveries d
     where d.delivered_at is not null
       and d.assigned_at  is not null
       and d.delivered_at > now() - make_interval(days => cfg.window_days)
       and d.delivered_at > d.assigned_at
       and (v_zone is null or d.zone_id = v_zone)
     order by d.delivered_at desc
     limit cfg.max_samples) s;

  -- Below the sample floor we say NOTHING. An invented date on a pharmacy's
  -- buying screen is worse than no date: it is a promise we never measured.
  if v_n < cfg.min_samples or v_avg is null then
    return jsonb_build_object('has', false, 'samples', v_n,
      'min_samples', cfg.min_samples, 'zone_id', v_zone, 'label', '', 'note', '');
  end if;

  v_mins := greatest(cfg.round_to_min,
              (round(v_avg / cfg.round_to_min) * cfg.round_to_min)::int);

  return jsonb_build_object(
    'has',      true,
    'samples',  v_n,
    'zone_id',  v_zone,
    'avg_min',  round(v_avg)::int,
    'label',    coalesce((select value from storefront_ui_label where key='promise_prefix'), '')
                || ' ' || public._duration_label(v_mins),
    'note',     coalesce((select value from storefront_ui_label where key='promise_note'), ''));
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW 176 — SUBSTITUTE CHOICE, CUSTOMER-APPROVED ONLY
-- Om: never auto-substitute. Admin opens a dropdown of same-formula options on
-- an out-of-stock line and may apply one ONLY after the customer approves. The
-- customer picks on their own Orders tab; a customer with no app gets the same
-- dropdown on a WhatsApp token page, the way supplier inquiry links already
-- work. The approval is a stored fact with a timestamp and an actor — not a
-- flag an admin can set on the customer's behalf.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.order_substitute_offer (
  id                bigserial primary key,
  order_item_id     uuid not null references public.order_items(id) on delete cascade,
  order_id          uuid,
  product_id        bigint,
  token             text not null unique default encode(gen_random_bytes(16), 'hex'),
  status            text not null default 'offered'
                    check (status in ('offered','approved','declined','held','applied','expired')),
  options           jsonb not null default '[]'::jsonb,
  chosen_product_id bigint,
  decided_by        text,
  decided_role      text,
  decided_at        timestamptz,
  applied_at        timestamptz,
  applied_by        uuid,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  expires_at        timestamptz not null default now() + interval '7 days'
);
alter table public.order_substitute_offer enable row level security;
create index if not exists order_substitute_offer_item_idx on public.order_substitute_offer (order_item_id);
create index if not exists order_substitute_offer_order_idx on public.order_substitute_offer (order_id);
create unique index if not exists order_substitute_offer_open_idx
  on public.order_substitute_offer (order_item_id)
  where status in ('offered','approved','held');

create table if not exists public.order_substitute_event (
  id        bigserial primary key,
  offer_id  bigint not null references public.order_substitute_offer(id) on delete cascade,
  at        timestamptz not null default now(),
  actor     text,
  role      text,
  action    text not null,
  detail    jsonb
);
alter table public.order_substitute_event enable row level security;

insert into public.storefront_ui_label(key, value, note) values
  ('sub_offer_heading',   'Out of stock — choose a substitute',              'CMD #366 row 176'),
  ('sub_offer_note',      'We could not source this item. Pick a replacement, or tell us to drop it — we will not swap anything without your say-so.', 'CMD #366 row 176'),
  ('sub_offer_accept',    'Send this instead',                                'CMD #366 row 176'),
  ('sub_offer_decline',   'Drop this item',                                   'CMD #366 row 176'),
  ('sub_offer_hold',      'Hold the order',                                   'CMD #366 row 176'),
  ('sub_offer_done',      'Thanks — we have recorded your choice.',           'CMD #366 row 176'),
  ('sub_offer_expired',   'This link has expired. Please open your order in the mediBO app.', 'CMD #366 row 176'),
  ('sub_offer_awaiting',  'Waiting for the customer to choose',               'CMD #366 row 176 — admin-side status'),
  ('sub_offer_approved',  'Customer approved — safe to apply',                'CMD #366 row 176 — admin-side status'),
  ('sub_offer_blocked',   'The customer has not approved a substitute for this line yet.', 'CMD #366 row 176 — the refusal an admin sees')
on conflict (key) do update set value = excluded.value, note = excluded.note;

-- The offer's own render-ready payload. One builder, three surfaces: the admin
-- order tab, the customer Orders tab and the public token page all print this.
create or replace function public._sub_offer_payload(p_offer public.order_substitute_offer)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_item record; v_expired boolean;
begin
  select oi.id, oi.product_name, oi.quantity, oi.unfulfillable_reason
    into v_item from public.order_items oi where oi.id = p_offer.order_item_id;
  v_expired := p_offer.expires_at < now();

  return jsonb_build_object(
    'ok',            true,
    'offer_id',      p_offer.id,
    'order_item_id', p_offer.order_item_id,
    'order_id',      p_offer.order_id,
    'status',        case when v_expired and p_offer.status = 'offered' then 'expired' else p_offer.status end,
    'expired',       v_expired,
    'heading',       coalesce((select value from storefront_ui_label where key='sub_offer_heading'), ''),
    'note',          coalesce((select value from storefront_ui_label where key='sub_offer_note'), ''),
    'expired_label', coalesce((select value from storefront_ui_label where key='sub_offer_expired'), ''),
    'done_label',    coalesce((select value from storefront_ui_label where key='sub_offer_done'), ''),
    'status_label',  case p_offer.status
        when 'offered'  then coalesce((select value from storefront_ui_label where key='sub_offer_awaiting'), '')
        when 'approved' then coalesce((select value from storefront_ui_label where key='sub_offer_approved'), '')
        when 'declined' then 'Customer dropped this item'
        when 'held'     then 'Customer asked us to hold the order'
        when 'applied'  then 'Substitute applied'
        else '' end,
    'status_tone',   case p_offer.status
        when 'approved' then 'success' when 'applied' then 'success'
        when 'declined' then 'neutral' when 'held' then 'warning' else 'info' end,
    'line', jsonb_build_object(
      'product_id',   p_offer.product_id,
      'product_name', coalesce(v_item.product_name, ''),
      'qty',          coalesce(v_item.quantity, 0),
      'reason',       coalesce(v_item.unfulfillable_reason, '')),
    'chosen_product_id', p_offer.chosen_product_id,
    'buttons', jsonb_build_array(
      jsonb_build_object('key','approve','label', coalesce((select value from storefront_ui_label where key='sub_offer_accept'), ''),  'tone','success','needs_choice', true),
      jsonb_build_object('key','decline','label', coalesce((select value from storefront_ui_label where key='sub_offer_decline'), ''), 'tone','neutral', 'needs_choice', false),
      jsonb_build_object('key','hold',   'label', coalesce((select value from storefront_ui_label where key='sub_offer_hold'), ''),    'tone','warning', 'needs_choice', false)),
    'options', p_offer.options);
end $$;

-- Admin opens the offer on an out-of-stock line. This does NOT substitute
-- anything; it asks. The options are frozen into the row so the customer sees
-- exactly the list that was offered, even if the catalogue moves underneath.
create or replace function public.sub_offer_open(p_order_item_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_item record; v_opts jsonb; v_offer public.order_substitute_offer;
begin
  if coalesce(public.get_my_role(), '') <> all (array['admin','super_admin']) then
    raise exception 'sub_offer_open: admin only';
  end if;

  select oi.* into v_item from public.order_items oi where oi.id = p_order_item_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  select * into v_offer from public.order_substitute_offer
   where order_item_id = p_order_item_id and status in ('offered','approved','held');
  if found then
    return public._sub_offer_payload(v_offer) || jsonb_build_object('reopened', true);
  end if;

  v_opts := (public.same_composition_options(v_item.product_id, 8))->'items';

  insert into public.order_substitute_offer
         (order_item_id, order_id, product_id, options, created_by)
  values (p_order_item_id, v_item.order_id, v_item.product_id,
          coalesce(v_opts, '[]'::jsonb), auth.uid())
  returning * into v_offer;

  insert into public.order_substitute_event (offer_id, actor, role, action, detail)
  values (v_offer.id, coalesce(auth.jwt()->>'email','admin'), public.get_my_role(), 'offered',
          jsonb_build_object('options', jsonb_array_length(coalesce(v_opts,'[]'::jsonb))));

  return public._sub_offer_payload(v_offer);
end $$;

-- The customer's answer — in the app (authenticated, scoped to their own
-- order) or on the token page. Both land here, so approval means one thing.
create or replace function public.sub_offer_decide(
  p_offer_id bigint default null, p_token text default null,
  p_action text default null, p_product_id bigint default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_offer public.order_substitute_offer; v_acct uuid; v_role text; v_actor text;
begin
  if p_action not in ('approve','decline','hold') then
    return jsonb_build_object('ok', false, 'error', 'bad_action');
  end if;

  if p_token is not null then
    select * into v_offer from public.order_substitute_offer where token = p_token;
    v_role := 'customer_link'; v_actor := 'token';
  elsif p_offer_id is not null then
    select * into v_offer from public.order_substitute_offer where id = p_offer_id;
    v_role := coalesce(public.get_my_role(), 'customer');
    v_actor := coalesce(auth.jwt()->>'email', 'customer');
  else
    return jsonb_build_object('ok', false, 'error', 'no_target');
  end if;

  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_offer.expires_at < now() then
    return jsonb_build_object('ok', false, 'error', 'expired',
      'message', coalesce((select value from storefront_ui_label where key='sub_offer_expired'), ''));
  end if;
  if v_offer.status not in ('offered','held') then
    return public._sub_offer_payload(v_offer) || jsonb_build_object('already_decided', true);
  end if;

  -- In-app: the decision must come from the account that owns the order. An
  -- admin cannot answer on the customer's behalf here — that is the whole
  -- point of the row.
  if p_token is null then
    v_acct := public.my_customer_id();
    if v_acct is null
       or not exists (select 1 from public.orders o
                       where o.id = v_offer.order_id and o.customer_id = v_acct) then
      return jsonb_build_object('ok', false, 'error', 'not_your_order');
    end if;
  end if;

  if p_action = 'approve' then
    if p_product_id is null
       or not exists (select 1 from jsonb_array_elements(v_offer.options) o
                       where (o->>'id')::bigint = p_product_id) then
      return jsonb_build_object('ok', false, 'error', 'not_an_offered_option');
    end if;
  end if;

  update public.order_substitute_offer
     set status = case p_action when 'approve' then 'approved'
                                when 'decline' then 'declined' else 'held' end,
         chosen_product_id = case when p_action = 'approve' then p_product_id else null end,
         decided_by = v_actor, decided_role = v_role, decided_at = now()
   where id = v_offer.id
  returning * into v_offer;

  insert into public.order_substitute_event (offer_id, actor, role, action, detail)
  values (v_offer.id, v_actor, v_role, p_action,
          jsonb_build_object('product_id', p_product_id));

  return public._sub_offer_payload(v_offer);
end $$;

-- Applying the swap. The ONLY door that touches the order line, and it refuses
-- unless the customer approved this exact product. There is no auto path.
create or replace function public.sub_offer_apply(p_offer_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_offer public.order_substitute_offer; v_new record;
begin
  if coalesce(public.get_my_role(), '') <> all (array['admin','super_admin']) then
    raise exception 'sub_offer_apply: admin only';
  end if;
  select * into v_offer from public.order_substitute_offer where id = p_offer_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  if v_offer.status <> 'approved' or v_offer.chosen_product_id is null then
    return jsonb_build_object('ok', false, 'error', 'not_approved',
      'message', coalesce((select value from storefront_ui_label where key='sub_offer_blocked'), ''));
  end if;

  select id, product_name, mrp, gst_percent into v_new
    from "MEDICINE" where id = v_offer.chosen_product_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'product_gone'); end if;

  update public.order_items
     set product_id   = v_new.id,
         product_name = v_new.product_name,
         unfulfillable = false,
         unfulfillable_reason = null
   where id = v_offer.order_item_id;

  update public.order_substitute_offer
     set status = 'applied', applied_at = now(), applied_by = auth.uid()
   where id = v_offer.id
  returning * into v_offer;

  insert into public.order_substitute_event (offer_id, actor, role, action, detail)
  values (v_offer.id, coalesce(auth.jwt()->>'email','admin'), public.get_my_role(), 'applied',
          jsonb_build_object('product_id', v_new.id));

  return public._sub_offer_payload(v_offer);
end $$;

-- The public token page — same shape as the supplier stock-update link.
create or replace function public.sub_offer_page(p_token text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_offer public.order_substitute_offer;
begin
  select * into v_offer from public.order_substitute_offer where token = p_token;
  if not found then
    return jsonb_build_object('ok', false, 'error', 'not_found',
      'message', coalesce((select value from storefront_ui_label where key='sub_offer_expired'), ''));
  end if;
  return public._sub_offer_payload(v_offer);
end $$;

-- Every open offer for one order — what the customer's Orders tab and the
-- admin's customer order tab both read.
create or replace function public.sub_offers_for_order(p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_rows jsonb;
begin
  select coalesce(jsonb_agg(public._sub_offer_payload(o) order by o.id), '[]'::jsonb)
    into v_rows from public.order_substitute_offer o where o.order_id = p_order_id;
  return jsonb_build_object('ok', true, 'order_id', p_order_id,
                            'has', jsonb_array_length(v_rows) > 0, 'offers', v_rows);
end $$;

grant execute on function public._norm_seg(text)                               to anon, authenticated, service_role;
grant execute on function public.med_composition_key(text, text, text)        to anon, authenticated, service_role;
grant execute on function public.same_composition_options(bigint, integer)     to authenticated, service_role;
grant execute on function public.storefront_margin_filters(numeric)            to anon, authenticated, service_role;
grant execute on function public.storefront_margin_page(integer, integer, numeric) to anon, authenticated, service_role;
grant execute on function public._duration_label(int)                          to anon, authenticated, service_role;
grant execute on function public.delivery_promise(text)                        to anon, authenticated, service_role;
grant execute on function public.sub_offer_open(uuid)                          to authenticated, service_role;
grant execute on function public.sub_offer_decide(bigint, text, text, bigint)  to anon, authenticated, service_role;
grant execute on function public.sub_offer_apply(bigint)                       to authenticated, service_role;
grant execute on function public.sub_offer_page(text)                          to anon, authenticated, service_role;
grant execute on function public.sub_offers_for_order(uuid)                    to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- product_detail() — the two new blocks, bolted onto the existing payload.
-- `similar` is left byte-for-byte as it was: test/protected/product_detail_test
-- pins that rail's shape, and row 171 is an EXTENSION of the mechanism, not a
-- replacement for it. `substitutes` is the priced, saving-aware version; the
-- PDP renders it and falls back to nothing when the backend says has:false.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.product_detail_v2(p_product_id bigint, p_pincode text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v jsonb;
begin
  v := public.product_detail(p_product_id);
  if coalesce((v->>'ok')::boolean, false) = false then
    return v;
  end if;
  return v || jsonb_build_object(
    'substitutes',      public.same_composition_options(p_product_id, 10),
    'delivery_promise', public.delivery_promise(p_pincode));
end $$;

grant execute on function public.product_detail_v2(bigint, text) to anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- ROW 172, the surface. The storefront already draws a chip row from
-- sort_options ({key,label,active}) and already routes by the key the BACKEND
-- put on the chip. So the margin thresholds ship as more chips on that same
-- row — no new control, no new payload shape, and the filter cannot appear
-- while no product has a real trade rate because the whole list is gated on
-- medicine_pricing.pricing_ready.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.storefront_sort_options(p_active text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_default text := coalesce((select value from storefront_ui_label
                                where key = 'sort_default_label'), 'Popular');
  v_margin  text := coalesce((select value from storefront_ui_label
                                where key = 'sort_margin_label'), 'Highest margin');
  v_active  text := case when coalesce(p_active,'') like 'margin%' then p_active else 'default' end;
  v_ready   int;
  v_chips   jsonb;
begin
  if not (public.viewer_is_approved_customer()
          or public.get_my_role() = any (array['admin','super_admin'])) then
    return '[]'::jsonb;
  end if;

  select count(*) into v_ready
    from public.medicine_pricing mp
    join "MEDICINE" m on m.id = mp.product_id
   where mp.pricing_ready
     and lower(coalesce(m.buyable::text, '')) in ('true', 't');
  if v_ready = 0 then
    return '[]'::jsonb;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'key', 'margin:' || f.min_pct::text,
           'label', f.label,
           'active', v_active = 'margin:' || f.min_pct::text)
         order by f.sort), '[]'::jsonb)
    into v_chips from public.storefront_margin_filter f where f.active;

  return jsonb_build_array(
    jsonb_build_object('key', 'default', 'label', v_default,
                       'active', v_active = 'default'),
    jsonb_build_object('key', 'margin',  'label', v_margin,
                       'active', v_active = 'margin'))
    || v_chips;
end;
$$;

-- Admin convenience: open an offer on EVERY still-unfulfillable line of one
-- order. The admin surface holds the order id, not the line uuids, and asking
-- the backend which lines are short is the backend's job anyway. Still asks —
-- it creates offers, it never substitutes.
create or replace function public.sub_offer_open_for_order(p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare r record; v_opened int := 0;
begin
  if coalesce(public.get_my_role(), '') <> all (array['admin','super_admin']) then
    raise exception 'sub_offer_open_for_order: admin only';
  end if;
  for r in select oi.id from public.order_items oi
            where oi.order_id = p_order_id and oi.unfulfillable
              and not exists (select 1 from public.order_substitute_offer o
                               where o.order_item_id = oi.id
                                 and o.status in ('offered','approved','held'))
  loop
    perform public.sub_offer_open(r.id);
    v_opened := v_opened + 1;
  end loop;
  return public.sub_offers_for_order(p_order_id) || jsonb_build_object('opened', v_opened);
end $$;

grant execute on function public.sub_offer_open_for_order(uuid) to authenticated, service_role;
