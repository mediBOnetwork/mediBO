-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #698 — SUBSTITUTE OFFER FOR UNFULFILLED LINES: ASK THE CUSTOMER FIRST
--
-- Om's flow, end to end, and the order it happens in matters more than any
-- single piece of it:
--
--   inquiry finishes → a line is split out as unfulfilled → the backend finds
--   up to three substitutes → THE CUSTOMER IS ASKED (app card + WhatsApp link,
--   multi-select, ranked, 10-minute backend-owned timer) → only the ticked
--   products are inquired → the first supplier "Available" joins the SAME
--   order as a substitute line → collect / count / bag / pack / bill pick it
--   up on their own.
--
-- Two things this deliberately does NOT do:
--   * No prices. mediBO sells to pharmacies at the supplier's rate; the offer
--     carries availability only — product, company, strength, pack. A price on
--     this card would be a number we have not got yet.
--   * No substitution before the customer says yes. The ask is the trigger for
--     the inquiry, never the other way round.
--
-- WHY PROBES INSTEAD OF ORDER LINES
-- The waterfall is driven by demand it can see: inquiry_engine_ranked_suppliers
-- only opens a supplier's window when inquiry_demand_qty() > 0, and that reads
-- order_items. The obvious implementation — write the ticked substitutes into
-- order_items and delete the losers — would put unaccepted products inside a
-- live order, where bag allocation, the pack queue and the bill would all see
-- them for the minutes the waterfall runs. So a ticked substitute lives in
-- order_substitute_probe until a supplier says Available, and
-- inquiry_demand_qty gained one UNION arm that counts probe demand. Nothing
-- reaches order_items until there is a real supplier behind it.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. WHAT MAY NEVER BE SUBSTITUTED ────────────────────────────────────────
-- A flag on the product itself (Om's words) plus an admin-editable rule list,
-- because "narrow therapeutic index" and "Schedule X" are properties of a SALT
-- or a class, not of one pack, and a per-row flag alone would need 563k edits.

alter table public."MEDICINE"
  add column if not exists no_substitute boolean;

comment on column public."MEDICINE".no_substitute is
  'CHANGE #698 — true: this product is never offered as, or replaced by, a substitute.';

create table if not exists public.substitute_block_rule (
  id         bigserial primary key,
  kind       text not null check (kind in ('salt','therapeutic_class','company')),
  value      text not null,
  reason     text not null default '',
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid
);
create unique index if not exists substitute_block_rule_key
  on public.substitute_block_rule (kind, lower(btrim(value)));

-- Seeded from the two categories Om named. Admin-editable from here on: these
-- are rows, not code, so adding a molecule is an INSERT and never a deploy.
insert into public.substitute_block_rule (kind, value, reason) values
  ('salt','warfarin',        'Narrow therapeutic index — brand switching is clinically unsafe'),
  ('salt','acenocoumarol',   'Narrow therapeutic index'),
  ('salt','phenytoin',       'Narrow therapeutic index'),
  ('salt','carbamazepine',   'Narrow therapeutic index'),
  ('salt','valproate',       'Narrow therapeutic index'),
  ('salt','digoxin',         'Narrow therapeutic index'),
  ('salt','lithium',         'Narrow therapeutic index'),
  ('salt','levothyroxine',   'Narrow therapeutic index'),
  ('salt','theophylline',    'Narrow therapeutic index'),
  ('salt','ciclosporin',     'Narrow therapeutic index'),
  ('salt','cyclosporine',    'Narrow therapeutic index'),
  ('salt','tacrolimus',      'Narrow therapeutic index'),
  ('salt','sirolimus',       'Narrow therapeutic index'),
  ('salt','clozapine',       'Narrow therapeutic index'),
  ('salt','ketamine',        'Schedule X'),
  ('salt','buprenorphine',   'Schedule X'),
  ('salt','pentazocine',     'Schedule X'),
  ('salt','methylphenidate', 'Schedule X'),
  ('salt','amphetamine',     'Schedule X'),
  ('salt','methaqualone',    'Schedule X'),
  ('salt','secobarbital',    'Schedule X'),
  ('salt','pentobarbital',   'Schedule X'),
  ('salt','amobarbital',     'Schedule X'),
  ('salt','barbital',        'Schedule X'),
  ('therapeutic_class','anti neoplastics', 'Oncology — never auto-substituted'),
  ('therapeutic_class','vaccines',         'Cold-chain biologicals are not interchangeable')
on conflict (kind, lower(btrim(value))) do nothing;

-- ── 2. THE ASK, AND THE PROBES IT STARTS ────────────────────────────────────

create table if not exists public.order_substitute_ask (
  id                   bigserial primary key,
  order_id             uuid not null references public.orders(id) on delete cascade,
  order_item_id        uuid not null references public.order_items(id) on delete cascade,
  product_id           bigint,
  zone_id              smallint,
  customer_id          uuid,
  token                text not null unique default encode(gen_random_bytes(16),'hex'),
  status               text not null default 'asked'
    check (status in ('asked','submitted','inquiring','applied',
                      'skipped','timeout','no_supplier','cancelled')),
  options              jsonb not null default '[]'::jsonb,
  picked               jsonb not null default '[]'::jsonb,
  remember             boolean not null default false,
  deadline_at          timestamptz not null,
  asked_at             timestamptz not null default now(),
  decided_at           timestamptz,
  closed_at            timestamptz,
  close_reason         text,
  applied_product_id   bigint,
  applied_order_item_id uuid,
  wa_sent_at           timestamptz,
  closed_notified_at   timestamptz,
  is_synthetic         boolean not null default false,
  test_session_id      bigint
);
-- "One ask per unfulfilled line, never repeated" is an INDEX, not a code path.
create unique index if not exists order_substitute_ask_item_uq
  on public.order_substitute_ask (order_item_id);
create index if not exists order_substitute_ask_order_idx
  on public.order_substitute_ask (order_id);
create index if not exists order_substitute_ask_open_idx
  on public.order_substitute_ask (status, deadline_at)
  where status in ('asked','submitted','inquiring');

create table if not exists public.order_substitute_probe (
  id          bigserial primary key,
  ask_id      bigint not null references public.order_substitute_ask(id) on delete cascade,
  product_id  bigint not null,
  rank        int not null default 1,
  qty         numeric not null default 0,
  inquiry_id  bigint,
  status      text not null default 'probing'
    check (status in ('probing','available','unavailable','cancelled')),
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);
create unique index if not exists order_substitute_probe_uq
  on public.order_substitute_probe (ask_id, product_id);
create index if not exists order_substitute_probe_live_idx
  on public.order_substitute_probe (inquiry_id) where status = 'probing';

-- "Always accept Y for salt S" — opt-in on the card, auto-ticks next time.
create table if not exists public.customer_substitute_pref (
  id          bigserial primary key,
  customer_id uuid not null,
  salt_key    text not null,
  product_id  bigint not null,
  created_at  timestamptz not null default now()
);
create unique index if not exists customer_substitute_pref_uq
  on public.customer_substitute_pref (customer_id, salt_key, product_id);

-- The substitute line points back at the line it replaces. The original line
-- STAYS unfulfillable — it is the record of what was asked for.
alter table public.order_items
  add column if not exists substitute_for uuid;
comment on column public.order_items.substitute_for is
  'CHANGE #698 — this line was supplied INSTEAD of order_items.id it points at.';
create index if not exists order_items_substitute_for_idx
  on public.order_items (substitute_for) where substitute_for is not null;

insert into public.app_settings (key, value) values
  ('substitute_ask_enabled', 'true'::jsonb),
  ('substitute_ask_minutes', '10'::jsonb),
  ('substitute_ask_max_options', '3'::jsonb)
on conflict (key) do nothing;

-- ── 3. EVERY WORD THE CUSTOMER READS ────────────────────────────────────────
-- Not one of these sentences exists in Dart. Changing the wording of this
-- whole feature is an UPDATE on ui_copy, never a deploy.

insert into public.ui_copy (key, value) values
  ('substitute.title',            '"{product} is not available"'::jsonb),
  ('substitute.subtitle',         '"Tick the ones you accept. We will try them in the order you put them."'::jsonb),
  ('substitute.order_prefix',     '"Order {code}"'::jsonb),
  ('substitute.submit',           '"Try these"'::jsonb),
  ('substitute.submit_empty',     '"Tick at least one"'::jsonb),
  ('substitute.skip',             '"Skip — ship without it"'::jsonb),
  ('substitute.remember',         '"Always accept this for {salt}"'::jsonb),
  ('substitute.countdown',        '"{mmss} left to answer"'::jsonb),
  ('substitute.expired_title',    '"This offer has closed"'::jsonb),
  ('substitute.expired_note',     '"We shipped your order without this item."'::jsonb),
  ('substitute.unknown_title',    '"We could not find this offer"'::jsonb),
  ('substitute.unknown_note',     '"The link may be old. Open the order in the mediBO app."'::jsonb),
  ('substitute.done_title',       '"Thanks — we are asking our distributors now"'::jsonb),
  ('substitute.done_note',        '"We will tell you the moment one of them confirms."'::jsonb),
  ('substitute.skipped_title',    '"Noted — we will ship without it"'::jsonb),
  ('substitute.skipped_note',     '"You will only be billed for what we supply."'::jsonb),
  ('substitute.inquiring_title',  '"Asking our distributors"'::jsonb),
  ('substitute.inquiring_note',   '"{n} substitutes are with our distributors now."'::jsonb),
  ('substitute.applied_title',    '"{product} ({company}) will be supplied instead"'::jsonb),
  ('substitute.applied_note',     '"It joins this order — nothing else for you to do."'::jsonb),
  ('substitute.none_title',       '"No substitute was available"'::jsonb),
  ('substitute.none_note',        '"We are shipping the rest of your order."'::jsonb),
  ('substitute.timeout_title',    '"The 10 minutes ran out"'::jsonb),
  ('substitute.timeout_note',     '"We shipped without this item so the rest was not held up."'::jsonb),
  ('substitute.card_cta',         '"Choose a substitute"'::jsonb),
  ('substitute.card_pending',     '"1 item needs your answer"'::jsonb),
  ('substitute.opt_pack',         '"{pack}"'::jsonb),
  ('substitute.rank_label',       '"Choice {n}"'::jsonb),
  ('substitute.no_options',       '"We could not find an equal substitute for this item."'::jsonb),
  ('order_timeline.ev_sub_asked',        '"Asked {name} about a substitute"'::jsonb),
  ('order_timeline.ev_sub_asked_detail', '"{n} options offered · 10 minutes to answer"'::jsonb),
  ('order_timeline.ev_sub_picked',       '"Customer accepted {n} substitutes"'::jsonb),
  ('order_timeline.ev_sub_picked_detail','"{names}"'::jsonb),
  ('order_timeline.ev_sub_applied',      '"{product} supplied instead"'::jsonb),
  ('order_timeline.ev_sub_applied_detail','"Substitute for {original}"'::jsonb),
  ('order_timeline.ev_sub_closed',       '"Substitute offer closed"'::jsonb),
  ('order_timeline.ev_sub_closed_detail','"{reason}"'::jsonb)
on conflict (key) do nothing;

-- ── 4. IS THIS PRODUCT SUBSTITUTABLE AT ALL? ────────────────────────────────

create or replace function public.med_substitutable(p_product_id bigint)
returns boolean
language plpgsql stable security definer set search_path to 'public'
as $$
declare m public."MEDICINE"%rowtype;
begin
  select * into m from public."MEDICINE" where id = p_product_id;
  if m.id is null then return false; end if;
  if coalesce(m.no_substitute, false) then return false; end if;

  -- A rule matches on CONTAINMENT for a salt (a combination pack carrying
  -- warfarin is still warfarin) and on equality for a class or a company.
  return not exists (
    select 1 from public.substitute_block_rule r
     where r.active
       and ( (r.kind = 'salt'
              and position(lower(btrim(r.value)) in lower(coalesce(m.salt_composition,''))) > 0)
          or (r.kind = 'therapeutic_class'
              and public._norm_seg(r.value) = public._norm_seg(coalesce(m.therapeutic_class,'')))
          or (r.kind = 'company'
              and public._norm_seg(r.value) = public._norm_seg(coalesce(m.marketer,''))) ));
end $$;

-- ── 5. THE CANDIDATES ───────────────────────────────────────────────────────
-- Same salt + strength (salt_composition carries the strength in this
-- catalogue) + dosage form (pack_type), a DIFFERENT product from a DIFFERENT
-- company, stocked in the order's own zone. Ranked by what this customer has
-- bought of that salt before, then by how many suppliers carry it.
--
-- No price is read, computed or returned anywhere in this function.

create or replace function public.substitute_candidates(
  p_product_id bigint,
  p_zone_id    smallint default null,
  p_customer_id uuid default null,
  p_limit      integer default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  m       public."MEDICINE"%rowtype;
  v_zone  smallint := p_zone_id;
  v_lim   int := coalesce(p_limit,
                   (select (value #>> '{}')::int from app_settings
                     where key = 'substitute_ask_max_options'), 3);
  v_items jsonb;
begin
  select * into m from public."MEDICINE" where id = p_product_id;
  if m.id is null or not public.med_substitutable(p_product_id) then
    return jsonb_build_object('has', false, 'salt_key', '', 'items', '[]'::jsonb);
  end if;
  v_zone := coalesce(v_zone, public.zone_default_id());

  with pool as (
    -- Bounded on purpose: the salt index hands back the same-salt shelf, and
    -- everything expensive below (zone standby, purchase history) only ever
    -- runs over that shelf, never over the 563k-row catalogue.
    select s.id, s.product_name, s.marketer, s.salt_composition,
           s.pack_type, s.pack_qty, s.pack_size, s.image_url_1,
           coalesce(s.supplier_count, 0) as supplier_count
      from public."MEDICINE" s
     where s.buyable is true
       and s.salt_composition = m.salt_composition
       and s.id <> m.id
       and public._norm_seg(s.pack_type) = public._norm_seg(m.pack_type)
       and public._norm_seg(s.marketer) <> public._norm_seg(coalesce(m.marketer,''))
       and public.med_status_sellable(s.status)
     order by coalesce(s.sales_count, 0) desc, s.id
     limit 40
  ), zoned as (
    select p.*, public.medicine_zone_standby(p.id, v_zone) as zone_count
      from pool p
  ), history as (
    select oi.product_id, count(*)::int as bought
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where p_customer_id is not null
       and o.customer_id = p_customer_id
       and oi.product_id in (select id from zoned)
     group by oi.product_id
  ), ranked as (
    select z.*, coalesce(h.bought, 0) as bought,
           row_number() over (order by coalesce(h.bought,0) desc,
                                       z.supplier_count desc,
                                       z.id) as rnk
      from zoned z
      left join history h on h.product_id = z.id
     where z.zone_count > 0
       and public.med_substitutable(z.id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id',  r.id,
           'name',        coalesce(r.product_name, ''),
           'company',     coalesce(r.marketer, ''),
           'strength',    coalesce(r.salt_composition, ''),
           'pack_label',  coalesce(nullif(btrim(r.pack_qty), ''),
                                   nullif(btrim(r.pack_type), ''),
                                   nullif(btrim(r.pack_size), ''), ''),
           'image',       coalesce(r.image_url_1, ''),
           'bought_before', (r.bought > 0),
           'rank',        r.rnk) order by r.rnk), '[]'::jsonb)
    into v_items
    from ranked r
   where r.rnk <= greatest(v_lim, 1);

  return jsonb_build_object(
    'has',      jsonb_array_length(v_items) > 0,
    'salt_key', coalesce(public.med_composition_key(m.salt_composition, '', m.pack_type), ''),
    'items',    v_items);
end $$;

-- ── 6. THE PAYLOAD BOTH SURFACES RENDER ─────────────────────────────────────
-- The in-app card and the public /substitute-ask/<token> page are the SAME
-- payload. One contract, so the two surfaces can never drift.

create or replace function public._substitute_mmss(p_left interval)
returns text language sql immutable as $$
  select lpad(greatest(floor(extract(epoch from p_left) / 60)::int, 0)::text, 2, '0') || ':' ||
         lpad(greatest(floor(extract(epoch from p_left))::int % 60, 0)::text, 2, '0');
$$;

create or replace function public._substitute_ask_payload(p_ask_id bigint)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare
  a       public.order_substitute_ask%rowtype;
  o       public.orders%rowtype;
  v_name  text;
  v_left  interval;
  v_open  boolean;
  v_opts  jsonb;
  v_pick  jsonb;
  v_probe jsonb;
  v_salt  text;
  v_applied jsonb := jsonb_build_object('has', false);
  v_state text; v_title text; v_note text;
begin
  select * into a from public.order_substitute_ask where id = p_ask_id;
  if a.id is null then
    return jsonb_build_object('ok', false, 'error', 'substitute_ask_not_found',
      'title', public._c('substitute.unknown_title'),
      'message', public._c('substitute.unknown_note'));
  end if;
  select * into o from public.orders where id = a.order_id;

  select coalesce(oi.product_name, '') into v_name
    from public.order_items oi where oi.id = a.order_item_id;
  select coalesce(m.salt_composition, '') into v_salt
    from public."MEDICINE" m where m.id = a.product_id;

  v_left := a.deadline_at - now();
  v_open := a.status = 'asked' and v_left > interval '0';

  v_pick := a.picked;
  select coalesce(jsonb_agg(
           opt || jsonb_build_object(
             'rank_label', replace(public._c('substitute.rank_label'), '{n}', idx::text),
             -- Pre-ticked ONLY because the backend already knows the answer:
             -- either the customer has answered this ask, or they told us once
             -- to always accept this product for this salt.
             'selected', (v_pick @> to_jsonb(array[(opt->>'product_id')::bigint]))
           ) order by idx), '[]'::jsonb)
    into v_opts
    from jsonb_array_elements(a.options) with ordinality t(opt, idx);

  select coalesce(jsonb_agg(jsonb_build_object(
           'product_id', p.product_id, 'rank', p.rank, 'status', p.status,
           'inquiry_id', p.inquiry_id) order by p.rank), '[]'::jsonb)
    into v_probe from public.order_substitute_probe p where p.ask_id = a.id;

  if a.applied_product_id is not null then
    select jsonb_build_object(
             'has', true,
             'product_id', m.id,
             'name', coalesce(m.product_name, ''),
             'company', coalesce(m.marketer, ''),
             'title', replace(replace(public._c('substitute.applied_title'),
                        '{product}', coalesce(m.product_name, '')),
                        '{company}', coalesce(m.marketer, '')),
             'note', public._c('substitute.applied_note'))
      into v_applied from public."MEDICINE" m where m.id = a.applied_product_id;
  end if;

  v_state := case
    when a.status = 'applied'                     then 'applied'
    when a.status = 'skipped'                     then 'skipped'
    when a.status = 'timeout'                     then 'timeout'
    when a.status = 'no_supplier'                 then 'none'
    when a.status = 'cancelled'                   then 'closed'
    when a.status in ('submitted','inquiring')    then 'inquiring'
    when not v_open                               then 'timeout'
    else 'open' end;

  v_title := case v_state
    when 'open'      then replace(public._c('substitute.title'), '{product}', v_name)
    when 'inquiring' then public._c('substitute.inquiring_title')
    when 'applied'   then coalesce(nullif(v_applied->>'title',''), public._c('substitute.applied_title'))
    when 'skipped'   then public._c('substitute.skipped_title')
    when 'timeout'   then public._c('substitute.timeout_title')
    when 'none'      then public._c('substitute.none_title')
    else public._c('substitute.expired_title') end;

  v_note := case v_state
    when 'open'      then public._c('substitute.subtitle')
    when 'inquiring' then replace(public._c('substitute.inquiring_note'), '{n}',
                                  jsonb_array_length(a.picked)::text)
    when 'applied'   then public._c('substitute.applied_note')
    when 'skipped'   then public._c('substitute.skipped_note')
    when 'timeout'   then public._c('substitute.timeout_note')
    when 'none'      then public._c('substitute.none_note')
    else public._c('substitute.expired_note') end;

  return jsonb_build_object(
    'ok',            true,
    'ask_id',        a.id,
    'token',         a.token,
    'order_id',      a.order_id::text,
    'order_label',   replace(public._c('substitute.order_prefix'), '{code}',
                             coalesce(o.order_code, '')),
    'status',        a.status,
    'state',         v_state,
    'is_open',       v_open,
    'product_name',  v_name,
    'salt',          v_salt,
    'title',         v_title,
    'note',          v_note,
    'options',       v_opts,
    'option_count',  jsonb_array_length(v_opts),
    'probes',        v_probe,
    'applied',       v_applied,
    'deadline_at',   a.deadline_at,
    -- The countdown is a SENTENCE the backend wrote against its own clock.
    -- Flutter prints it; it never renders a timer of its own, because a phone
    -- clock that disagrees with the deadline would show a lie.
    'countdown_label', case when v_open
      then replace(public._c('substitute.countdown'), '{mmss}', public._substitute_mmss(v_left))
      else '' end,
    'seconds_left',  greatest(floor(extract(epoch from v_left))::int, 0),
    'submit_label',  public._c('substitute.submit'),
    'submit_empty_label', public._c('substitute.submit_empty'),
    'skip_label',    public._c('substitute.skip'),
    'remember_label', replace(public._c('substitute.remember'), '{salt}', v_salt),
    'remember',      a.remember,
    'empty_label',   public._c('substitute.no_options'));
end $$;

-- ── 7. OPENING THE ASK ──────────────────────────────────────────────────────
-- Called the moment a line is finalized unfulfilled. Idempotent by the unique
-- index on order_item_id: a resumed sweep re-asking the same line is a no-op,
-- which is exactly Om's "one ask per unfulfilled line, never repeated".

create or replace function public.substitute_ask_open(p_order_item_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  oi      public.order_items%rowtype;
  o       public.orders%rowtype;
  v_ask   public.order_substitute_ask%rowtype;
  v_cand  jsonb;
  v_min   int := coalesce((select (value #>> '{}')::int from app_settings
                            where key = 'substitute_ask_minutes'), 10);
  v_on    boolean := coalesce((select (value #>> '{}')::boolean from app_settings
                                where key = 'substitute_ask_enabled'), true);
  v_pref  jsonb := '[]'::jsonb;
  v_salt  text;
begin
  if not v_on then return jsonb_build_object('ok', false, 'error', 'disabled'); end if;

  select * into oi from public.order_items where id = p_order_item_id;
  if oi.id is null then return jsonb_build_object('ok', false, 'error', 'line_not_found'); end if;

  select * into v_ask from public.order_substitute_ask where order_item_id = p_order_item_id;
  if v_ask.id is not null then
    return jsonb_build_object('ok', true, 'already', true, 'ask_id', v_ask.id,
                              'ask', public._substitute_ask_payload(v_ask.id));
  end if;

  select * into o from public.orders where id = oi.order_id;

  v_cand := public.substitute_candidates(oi.product_id, oi.zone_id, o.customer_id, null);
  if not coalesce((v_cand->>'has')::boolean, false) then
    -- "No candidates → skip silently." No row, no card, no WhatsApp.
    return jsonb_build_object('ok', true, 'skipped', true, 'reason', 'no_candidates');
  end if;

  -- "Always accept Y for salt S" — the memory arrives as a pre-tick, and the
  -- customer can still untick it. It is a default, never a decision.
  select coalesce(jsonb_agg(to_jsonb(cp.product_id)), '[]'::jsonb) into v_pref
    from public.customer_substitute_pref cp
   where cp.customer_id = o.customer_id
     and cp.salt_key = (v_cand->>'salt_key')
     and cp.product_id in (
       select (x->>'product_id')::bigint from jsonb_array_elements(v_cand->'items') x);

  insert into public.order_substitute_ask
    (order_id, order_item_id, product_id, zone_id, customer_id,
     options, picked, deadline_at, is_synthetic, test_session_id)
  values (oi.order_id, oi.id, oi.product_id, oi.zone_id, o.customer_id,
          v_cand->'items', v_pref, now() + make_interval(mins => greatest(v_min, 1)),
          coalesce(oi.is_synthetic, false), oi.test_session_id)
  on conflict (order_item_id) do nothing
  returning * into v_ask;

  if v_ask.id is null then
    select * into v_ask from public.order_substitute_ask where order_item_id = p_order_item_id;
    return jsonb_build_object('ok', true, 'already', true, 'ask_id', v_ask.id,
                              'ask', public._substitute_ask_payload(v_ask.id));
  end if;

  perform public.substitute_ask_send_wa(v_ask.id);
  return jsonb_build_object('ok', true, 'ask_id', v_ask.id,
                            'ask', public._substitute_ask_payload(v_ask.id));
end $$;

create or replace function public.substitute_ask_send_wa(p_ask_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a public.order_substitute_ask%rowtype;
  o public.orders%rowtype;
  v_phone text; v_name text; v_link text;
begin
  select * into a from public.order_substitute_ask where id = p_ask_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  if a.wa_sent_at is not null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  select * into o from public.orders where id = a.order_id;
  if coalesce(a.is_synthetic, false) then
    -- A synthetic order never reaches a real pharmacy's WhatsApp.
    update public.order_substitute_ask set wa_sent_at = now() where id = a.id;
    return jsonb_build_object('ok', true, 'synthetic', true);
  end if;

  select coalesce(oi.product_name,'') into v_name
    from public.order_items oi where oi.id = a.order_item_id;
  v_phone := right(regexp_replace(coalesce(public._order_customer_phone(a.order_id),''),'\D','','g'), 10);
  v_link  := public._c417_base_url() || '/substitute-ask/' || a.token;

  begin
    perform public.notify('order_substitute_ask', v_phone, jsonb_build_object(
      'order_id',       a.order_id::text,
      'customer_id',    coalesce(a.customer_id::text, ''),
      'order_code',     coalesce(o.order_code, ''),
      'pharmacy_name',  coalesce(o.pharmacy_name, ''),
      'product_name',   v_name,
      'option_count',   jsonb_array_length(a.options)::text,
      'substitute_link', v_link));
    update public.order_substitute_ask set wa_sent_at = now() where id = a.id;
  exception when others then
    -- A WhatsApp hiccup must never stop the in-app card from existing.
    return jsonb_build_object('ok', false, 'error', sqlerrm, 'link', v_link);
  end;
  return jsonb_build_object('ok', true, 'link', v_link);
end $$;

insert into public.wa_event_routes
  (event_key, label, description, audience, template_name, auto_template_name,
   language, variable_map, enabled, auto_manage)
values
  ('order_substitute_ask',
   'Substitute offer — ask the customer',
   'CHANGE #698 — a line could not be sourced. Offers up to three equal substitutes and a 10-minute link.',
   'customer', 'order_substitute_ask', 'order_substitute_ask', 'en',
   '["{{pharmacy_name}}", "{{product_name}}", "{{order_code}}", "{{substitute_link}}"]'::jsonb,
   true, true),
  ('order_substitute_applied',
   'Substitute confirmed',
   'CHANGE #698 — a distributor confirmed one of the substitutes the customer accepted.',
   'customer', 'order_substitute_applied', 'order_substitute_applied', 'en',
   '["{{pharmacy_name}}", "{{substitute_name}}", "{{substitute_company}}", "{{product_name}}", "{{order_code}}"]'::jsonb,
   true, true),
  ('order_substitute_none',
   'No substitute available',
   'CHANGE #698 — the offer closed with nothing to supply; the order ships without the line.',
   'customer', 'order_substitute_none', 'order_substitute_none', 'en',
   '["{{pharmacy_name}}", "{{product_name}}", "{{order_code}}"]'::jsonb,
   true, true)
on conflict (event_key) do nothing;

-- ── 8. THE CUSTOMER ANSWERS ─────────────────────────────────────────────────
-- Anonymous by token, exactly like /stock-update/<token>: the token IS the
-- authorisation. The in-app card posts the same token, so both surfaces run
-- one code path and can never behave differently.

create or replace function public.substitute_ask_page(p_token text)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_id bigint;
begin
  select id into v_id from public.order_substitute_ask
   where token = nullif(btrim(coalesce(p_token,'')), '');
  if v_id is null then
    return jsonb_build_object('ok', false, 'error', 'substitute_ask_not_found',
      'title',   public._c('substitute.unknown_title'),
      'message', public._c('substitute.unknown_note'));
  end if;
  return public._substitute_ask_payload(v_id);
end $$;

create or replace function public.substitute_ask_submit(
  p_token text,
  p_product_ids bigint[] default '{}'::bigint[],
  p_remember boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a       public.order_substitute_ask%rowtype;
  v_valid bigint[];
  v_pick  jsonb;
  v_salt  text;
  v_n     int;
begin
  select * into a from public.order_substitute_ask
   where token = nullif(btrim(coalesce(p_token,'')), '');
  if a.id is null then
    return jsonb_build_object('ok', false, 'error', 'substitute_ask_not_found',
      'title', public._c('substitute.unknown_title'),
      'message', public._c('substitute.unknown_note'));
  end if;
  if a.status <> 'asked' then
    return jsonb_build_object('ok', false, 'error', 'already_answered',
                              'ask', public._substitute_ask_payload(a.id));
  end if;
  if a.deadline_at <= now() then
    -- The timer is the BACKEND's. A late submit is refused here, not policed
    -- by a countdown running on the customer's phone.
    perform public.substitute_ask_close(a.id, 'timeout');
    return jsonb_build_object('ok', false, 'error', 'expired',
      'title', public._c('substitute.timeout_title'),
      'message', public._c('substitute.timeout_note'),
      'ask', public._substitute_ask_payload(a.id));
  end if;

  -- Only ids we actually offered, in the CUSTOMER's order — the array's own
  -- order is the ranking, which is what "drag to rank" produces.
  select array_agg(x order by x_ord) into v_valid
    from (
      select v as x, ord as x_ord
        from unnest(coalesce(p_product_ids, '{}'::bigint[])) with ordinality u(v, ord)
       where exists (select 1 from jsonb_array_elements(a.options) o
                      where (o->>'product_id')::bigint = v)
    ) t;
  v_valid := coalesce(v_valid, '{}'::bigint[]);
  v_n := coalesce(array_length(v_valid, 1), 0);

  if v_n = 0 then
    return public.substitute_ask_skip(p_token);
  end if;

  select coalesce(jsonb_agg(to_jsonb(v) order by ord), '[]'::jsonb) into v_pick
    from unnest(v_valid) with ordinality u(v, ord);

  update public.order_substitute_ask
     set picked = v_pick, remember = coalesce(p_remember, false),
         status = 'submitted', decided_at = now()
   where id = a.id;

  if coalesce(p_remember, false) then
    select coalesce(public.med_composition_key(m.salt_composition, '', m.pack_type), '')
      into v_salt from public."MEDICINE" m where m.id = a.product_id;
    if v_salt <> '' and a.customer_id is not null then
      insert into public.customer_substitute_pref (customer_id, salt_key, product_id)
      select a.customer_id, v_salt, v from unnest(v_valid) v
      on conflict (customer_id, salt_key, product_id) do nothing;
    end if;
  end if;

  perform public.substitute_start_probes(a.id);
  return jsonb_build_object('ok', true, 'picked', v_n,
                            'title',   public._c('substitute.done_title'),
                            'message', public._c('substitute.done_note'),
                            'ask',     public._substitute_ask_payload(a.id));
end $$;

create or replace function public.substitute_ask_skip(p_token text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare a public.order_substitute_ask%rowtype;
begin
  select * into a from public.order_substitute_ask
   where token = nullif(btrim(coalesce(p_token,'')), '');
  if a.id is null then
    return jsonb_build_object('ok', false, 'error', 'substitute_ask_not_found',
      'title', public._c('substitute.unknown_title'),
      'message', public._c('substitute.unknown_note'));
  end if;
  if a.status = 'asked' then
    update public.order_substitute_ask
       set status = 'skipped', decided_at = now(), closed_at = now(),
           close_reason = 'skipped'
     where id = a.id;
  end if;
  return jsonb_build_object('ok', true,
    'title',   public._c('substitute.skipped_title'),
    'message', public._c('substitute.skipped_note'),
    'ask',     public._substitute_ask_payload(a.id));
end $$;

-- ── 9. THE PROBES — THE EXISTING WATERFALL, ON THE TICKED PRODUCTS ONLY ─────
-- One inquiry row per ticked substitute, for the order's own zone. Everything
-- after that is the machinery that already exists: inquiry_ps_lookup fills the
-- ranked supplier list, compute_current_supplier_fx opens the waterfall,
-- inquiry_engine_sync sends the WhatsApp, and inquiry_to_supplier_orders
-- builds the supplier order the moment somebody answers Available.

create or replace function public.substitute_start_probes(p_ask_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a      public.order_substitute_ask%rowtype;
  oi     public.order_items%rowtype;
  v_date date := (now() at time zone 'Asia/Kolkata')::date;
  v_batch int;
  v_pid  bigint; v_rank int := 0; v_inq bigint; v_qty numeric;
  v_made int := 0;
begin
  select * into a from public.order_substitute_ask where id = p_ask_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  select * into oi from public.order_items where id = a.order_item_id;

  select coalesce(max(i.inquiry_batch), 0) + 1 into v_batch
    from public.inquiry i where i.batch_date = v_date;

  for v_pid in select (x #>> '{}')::bigint from jsonb_array_elements(a.picked) x loop
    v_rank := v_rank + 1;
    v_qty  := public.substitute_equivalent_qty(a.product_id, v_pid, coalesce(oi.quantity, 0));

    -- Reuse the day's inquiry row for this product+zone when one exists: the
    -- waterfall is per product, not per order, and a second row would ask the
    -- same distributor the same question twice.
    select i.id into v_inq
      from public.inquiry i
     where i.product_id = v_pid and i.batch_date = v_date
       and i.zone_id is not distinct from oi.zone_id
     order by i.id limit 1;

    if v_inq is null then
      insert into public.inquiry (product_id, product_name, quantity, mrp, gst_percent,
                                  batch_date, inquiry_batch, inquiry_phase, zone_id,
                                  available, out_of_stock, we_dont_stock_this_product,
                                  is_synthetic, test_session_id)
      -- MEDICINE.mrp is TEXT in this catalogue ("₹123.50", "123.5/-"); the
      -- inquiry column is numeric. Sanitised, never cast blind.
      select v_pid, coalesce(m.product_name,''), v_qty,
             nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
             m.gst_percent,
             v_date, v_batch, 'draft', oi.zone_id, false, false, false,
             coalesce(a.is_synthetic,false), a.test_session_id
        from public."MEDICINE" m where m.id = v_pid
      returning id into v_inq;
    else
      update public.inquiry set quantity = greatest(coalesce(quantity,0), v_qty)
       where id = v_inq;
    end if;

    insert into public.order_substitute_probe (ask_id, product_id, rank, qty, inquiry_id)
    values (a.id, v_pid, v_rank, v_qty, v_inq)
    on conflict (ask_id, product_id) do update
      set rank = excluded.rank, qty = excluded.qty, inquiry_id = excluded.inquiry_id;
    v_made := v_made + 1;
  end loop;

  update public.order_substitute_ask set status = 'inquiring' where id = a.id;
  return jsonb_build_object('ok', true, 'probes', v_made);
end $$;

-- "qty = original qty in equivalent packs". Both sides carry a pack size in
-- pack_qty ("10 tablets", "15 tablets"); when both parse, the quantity is
-- rounded UP so the pharmacy is never short. When either side is unreadable
-- the quantity is carried across unchanged rather than guessed.
create or replace function public.substitute_equivalent_qty(
  p_from bigint, p_to bigint, p_qty numeric)
returns numeric
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_a numeric; v_b numeric;
begin
  select nullif(regexp_replace(coalesce(pack_qty,''), '\D', '', 'g'), '')::numeric
    into v_a from public."MEDICINE" where id = p_from;
  select nullif(regexp_replace(coalesce(pack_qty,''), '\D', '', 'g'), '')::numeric
    into v_b from public."MEDICINE" where id = p_to;
  if v_a is null or v_b is null or v_a <= 0 or v_b <= 0 or v_a = v_b then
    return coalesce(p_qty, 0);
  end if;
  return ceil(coalesce(p_qty, 0) * v_a / v_b);
end $$;

-- ── 10. THE FIRST "AVAILABLE" JOINS THE ORDER ───────────────────────────────

create or replace function public.substitute_cancel_probe(p_probe_id bigint)
returns void
language plpgsql security definer set search_path to 'public'
as $$
declare p public.order_substitute_probe%rowtype;
begin
  select * into p from public.order_substitute_probe where id = p_probe_id;
  if p.id is null or p.status not in ('probing','available') then return; end if;

  update public.order_substitute_probe
     set status = 'cancelled', resolved_at = now() where id = p.id;

  -- A probe inquiry that nothing else is waiting on must GO, not just be
  -- ignored: inquiry_to_supplier_orders builds a supplier PO out of every
  -- Available row, so a losing probe left behind would put a product nobody
  -- ordered onto a distributor's purchase order. Deleting the row re-runs that
  -- trigger and the PO recomputes without it.
  if p.inquiry_id is not null
     and not exists (select 1 from public.order_items oi where oi.inquiry_id = p.inquiry_id)
     and not exists (select 1 from public.order_substitute_probe q
                      where q.inquiry_id = p.inquiry_id and q.id <> p.id
                        and q.status in ('probing','available'))
  then
    delete from public.inquiry where id = p.inquiry_id;
  end if;
end $$;

create or replace function public.substitute_apply(p_ask_id bigint, p_product_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a      public.order_substitute_ask%rowtype;
  oi     public.order_items%rowtype;
  m      public."MEDICINE"%rowtype;
  p      public.order_substitute_probe%rowtype;
  v_new  uuid;
  v_qty  numeric;
  r      record;
begin
  select * into a from public.order_substitute_ask where id = p_ask_id for update;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  if a.status = 'applied' then
    return jsonb_build_object('ok', true, 'already', true,
                              'order_item_id', a.applied_order_item_id::text);
  end if;
  if a.status not in ('submitted','inquiring') then
    return jsonb_build_object('ok', false, 'error','not_inquiring','status', a.status);
  end if;

  select * into p from public.order_substitute_probe
   where ask_id = a.id and product_id = p_product_id;
  select * into oi from public.order_items where id = a.order_item_id;
  select * into m  from public."MEDICINE" where id = p_product_id;
  if m.id is null then return jsonb_build_object('ok', false, 'error','product_not_found'); end if;

  v_qty := coalesce(p.qty, public.substitute_equivalent_qty(a.product_id, p_product_id,
                                                            coalesce(oi.quantity, 0)));

  -- The substitute joins the SAME order. Every downstream stage — collect,
  -- count, bag allocation, the pack queue, the bill — reads order_items, so
  -- there is nothing else to wire: the line is simply there, flagged with the
  -- line it stands in for. Price is left NULL on purpose; _oi_resolve_price
  -- and the bill decide the money off the supplier's own rate, never off MRP.
  insert into public.order_items
    (order_id, product_id, product_name, quantity, mrp, gst_percent,
     pharmacy_name, inquiry_id, substitute_for, is_synthetic, test_session_id)
  values (a.order_id, m.id, coalesce(m.product_name, ''), v_qty,
          nullif(regexp_replace(coalesce(m.mrp::text,''), '[^0-9.]', '', 'g'), '')::numeric,
          m.gst_percent,
          oi.pharmacy_name, p.inquiry_id, oi.id,
          coalesce(oi.is_synthetic, false), oi.test_session_id)
  returning id into v_new;

  update public.order_substitute_probe
     set status = 'available', resolved_at = now()
   where id = p.id;

  for r in select id from public.order_substitute_probe
            where ask_id = a.id and id <> coalesce(p.id, -1)
              and status in ('probing','available')
  loop
    perform public.substitute_cancel_probe(r.id);
  end loop;

  update public.order_substitute_ask
     set status = 'applied', applied_product_id = m.id, applied_order_item_id = v_new,
         closed_at = now(), close_reason = 'applied'
   where id = a.id;

  -- The original line STAYS unfulfillable. It is the record of what the
  -- pharmacy actually asked for, and the bill prints the pair.
  return jsonb_build_object('ok', true, 'order_item_id', v_new::text,
                            'product_id', m.id, 'quantity', v_qty);
end $$;

create or replace function public.substitute_ask_close(p_ask_id bigint, p_reason text)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare a public.order_substitute_ask%rowtype; r record; v_status text;
begin
  select * into a from public.order_substitute_ask where id = p_ask_id;
  if a.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  if a.status in ('applied','skipped','timeout','no_supplier','cancelled') then
    return jsonb_build_object('ok', true, 'already', true, 'status', a.status);
  end if;

  v_status := case p_reason when 'timeout' then 'timeout'
                            when 'no_supplier' then 'no_supplier'
                            when 'skipped' then 'skipped'
                            else 'cancelled' end;

  for r in select id from public.order_substitute_probe
            where ask_id = a.id and status in ('probing','available') loop
    perform public.substitute_cancel_probe(r.id);
  end loop;

  update public.order_substitute_ask
     set status = v_status, closed_at = now(), close_reason = p_reason
   where id = a.id;
  return jsonb_build_object('ok', true, 'status', v_status);
end $$;

-- ── 11. THE TICK — the only thing with a clock ──────────────────────────────

create or replace function public.substitute_ask_tick(p_limit integer default 50)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  r record; w record;
  v_opened int := 0; v_applied int := 0; v_timeout int := 0;
  v_none int := 0; v_notified int := 0; v_on boolean;
  v_res jsonb;
begin
  v_on := coalesce((select (value #>> '{}')::boolean from app_settings
                     where key = 'substitute_ask_enabled'), true);
  if not v_on then return jsonb_build_object('ok', true, 'enabled', false); end if;

  -- (a) Any freshly unfulfilled line that has no ask yet. order_finalize_
  -- unfulfilled opens the ask inline; this is the backstop for a line that was
  -- marked by any other path, and it is a no-op once the ask exists.
  for r in
    select oi.id from public.order_items oi
      join public.orders o on o.id = oi.order_id
     where oi.unfulfillable
       and oi.unfulfillable_at > now() - interval '2 days'
       and coalesce(o.status,'') <> 'cancelled'
       and not exists (select 1 from public.order_substitute_ask a
                        where a.order_item_id = oi.id)
     order by oi.unfulfillable_at desc
     limit greatest(coalesce(p_limit, 50), 1)
  loop
    begin
      v_res := public.substitute_ask_open(r.id);
      if coalesce((v_res->>'ok')::boolean,false)
         and not coalesce((v_res->>'skipped')::boolean,false)
         and not coalesce((v_res->>'already')::boolean,false) then
        v_opened := v_opened + 1;
      end if;
    exception when others then null;
    end;
  end loop;

  -- (b) The 10 minutes are the BACKEND's. Nothing on a phone closes an ask.
  for r in
    select id from public.order_substitute_ask
     where status = 'asked' and deadline_at <= now()
     limit greatest(coalesce(p_limit, 50), 1)
  loop
    perform public.substitute_ask_close(r.id, 'timeout');
    v_timeout := v_timeout + 1;
  end loop;

  -- (c) First Available wins, and "first" is the customer's own ranking.
  for r in
    select a.id from public.order_substitute_ask a
     where a.status in ('submitted','inquiring')
     limit greatest(coalesce(p_limit, 50), 1)
  loop
    select p.product_id into w
      from public.order_substitute_probe p
      join public.inquiry i on i.id = p.inquiry_id
     where p.ask_id = r.id and p.status = 'probing'
       and i.current_status = 'Available'
       and coalesce(btrim(i.current_supplier), '') <> ''
     order by p.rank
     limit 1;

    if w.product_id is not null then
      v_res := public.substitute_apply(r.id, w.product_id);
      if coalesce((v_res->>'ok')::boolean, false) then v_applied := v_applied + 1; end if;
    else
      -- Every probe answered, and every answer was no.
      update public.order_substitute_probe p
         set status = 'unavailable', resolved_at = now()
        from public.inquiry i
       where i.id = p.inquiry_id and p.ask_id = r.id and p.status = 'probing'
         and i.current_status is not null
         and i.current_status not in ('Available','Confirmation Pending');

      if not exists (select 1 from public.order_substitute_probe p
                      where p.ask_id = r.id and p.status = 'probing') then
        perform public.substitute_ask_close(r.id, 'no_supplier');
        v_none := v_none + 1;
      end if;
    end if;
  end loop;

  -- (d) Tell the customer, exactly once, whatever the outcome was.
  for r in
    select id from public.order_substitute_ask
     where closed_at is not null and closed_notified_at is null
       and status in ('applied','timeout','no_supplier','skipped')
     limit greatest(coalesce(p_limit, 50), 1)
  loop
    perform public.substitute_ask_notify_close(r.id);
    v_notified := v_notified + 1;
  end loop;

  return jsonb_build_object('ok', true, 'enabled', true,
    'opened', v_opened, 'applied', v_applied, 'timed_out', v_timeout,
    'no_supplier', v_none, 'notified', v_notified);
end $$;

create or replace function public.substitute_ask_notify_close(p_ask_id bigint)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  a public.order_substitute_ask%rowtype; o public.orders%rowtype;
  v_phone text; v_name text; v_sub public."MEDICINE"%rowtype;
begin
  select * into a from public.order_substitute_ask where id = p_ask_id;
  if a.id is null or a.closed_notified_at is not null then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  update public.order_substitute_ask set closed_notified_at = now() where id = a.id;
  if coalesce(a.is_synthetic, false) then return jsonb_build_object('ok', true, 'synthetic', true); end if;

  select * into o from public.orders where id = a.order_id;
  select coalesce(oi.product_name,'') into v_name
    from public.order_items oi where oi.id = a.order_item_id;
  v_phone := right(regexp_replace(coalesce(public._order_customer_phone(a.order_id),''),'\D','','g'),10);

  begin
    if a.status = 'applied' then
      select * into v_sub from public."MEDICINE" where id = a.applied_product_id;
      perform public.notify('order_substitute_applied', v_phone, jsonb_build_object(
        'order_id', a.order_id::text, 'customer_id', coalesce(a.customer_id::text,''),
        'order_code', coalesce(o.order_code,''),
        'pharmacy_name', coalesce(o.pharmacy_name,''),
        'product_name', v_name,
        'substitute_name', coalesce(v_sub.product_name,''),
        'substitute_company', coalesce(v_sub.marketer,'')));
    else
      perform public.notify('order_substitute_none', v_phone, jsonb_build_object(
        'order_id', a.order_id::text, 'customer_id', coalesce(a.customer_id::text,''),
        'order_code', coalesce(o.order_code,''),
        'pharmacy_name', coalesce(o.pharmacy_name,''),
        'product_name', v_name));
    end if;
  exception when others then null;
  end;
  return jsonb_build_object('ok', true, 'status', a.status);
end $$;

-- ── 12. THE WATERFALL HAS TO SEE PROBE DEMAND ───────────────────────────────
-- inquiry_engine_ranked_suppliers only opens a supplier's window while
-- inquiry_demand_qty() > 0, and that read order_items alone. A ticked
-- substitute has no order line yet — by design — so without this arm the probe
-- would sit in the inquiry table and no distributor would ever be asked.
-- Signature unchanged; the order_items arm is byte-for-byte what it was.

create or replace function public.inquiry_demand_qty(
  p_product_id bigint, p_supplier text, p_today_only boolean default true)
returns numeric
language sql stable security definer set search_path to 'books', 'public'
as $$
  with sz as (
    select sp.zone_id
    from supplier_profiles sp
    where lower(btrim(sp.supplier_name)) = lower(btrim(p_supplier))
      and not coalesce(sp.is_deleted,false)
    limit 1
  ), line_demand as (
    select coalesce(sum(oi.quantity), 0) as q
    from order_items oi
    join orders o on o.id = oi.order_id
    where oi.product_id = p_product_id
      and o.status = 'accepted'
      and o.fulfillment_status not in ('shipped','cancelled')
      and coalesce(oi.received_qty,0) = 0
      and not coalesce(oi.collect_locked,false)
      and not coalesce(oi.received_locked,false)
      and not coalesce(oi.at_warehouse,false)
      and oi.fulfillment_state not in ('received','packed','shipped','short','wrong','not_coming')
      and (oi.zone_id IS NOT DISTINCT FROM (select zone_id from sz)
           or (select zone_id from sz) is null)
      and exists (
        select 1 from inquiry i
         where i.product_id = p_product_id
           and i.batch_date = oi.order_date
           and i.current_supplier = p_supplier
           and i.zone_id IS NOT DISTINCT FROM oi.zone_id)
      and ( not p_today_only
            or oi.order_date = (now() at time zone 'Asia/Kolkata')::date )
  ), probe_demand as (
    -- CHANGE #698 — a substitute the customer ticked. Real demand from a real
    -- order, waiting on exactly this waterfall, which simply has not earned an
    -- order line yet because no distributor has said Available.
    select coalesce(sum(p.qty), 0) as q
    from order_substitute_probe p
    join order_substitute_ask a on a.id = p.ask_id
    join orders o on o.id = a.order_id
    join inquiry i on i.id = p.inquiry_id
    where p.product_id = p_product_id
      and p.status = 'probing'
      and a.status in ('submitted','inquiring')
      and o.status = 'accepted'
      and o.fulfillment_status not in ('shipped','cancelled')
      and i.current_supplier = p_supplier
      and (a.zone_id IS NOT DISTINCT FROM (select zone_id from sz)
           or (select zone_id from sz) is null)
      and ( not p_today_only
            or i.batch_date = (now() at time zone 'Asia/Kolkata')::date )
  )
  select (select q from line_demand) + (select q from probe_demand);
$$;

-- ── 13. THE TRIGGER POINT ───────────────────────────────────────────────────
-- The ask opens the instant a line is split out as unfulfilled, inside the one
-- funnel that sets the flag. Wrapped so a substitute problem can never stop an
-- order from being finalized.

create or replace function public.order_finalize_unfulfilled(
  p_order_id uuid, p_force boolean default false)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare
  v_state jsonb; v_marked int := 0; v_unf int; v_removed numeric; v_new_total numeric;
  o orders%rowtype; v_asked int := 0; v_sub_row record; v_res jsonb;
begin
  select * into o from orders where id = p_order_id;
  if o.id is null then return jsonb_build_object('ok',false,'error','order_not_found'); end if;

  v_state := public.order_inquiry_state(p_order_id);
  if not coalesce((v_state->>'inquiry_finished')::boolean,false) and not p_force then
    return jsonb_build_object('ok',false,'error','inquiry_not_finished',
      'awaiting', v_state->'awaiting', 'state', v_state);
  end if;

  with tgt as (
    select (r->>'order_item_id')::uuid as id, r->>'reason' as reason
    from jsonb_array_elements(v_state->'items') r
    where r->>'verdict' = 'unfulfillable'
  ), upd as (
    update order_items oi
       set unfulfillable = true,
           unfulfillable_reason = coalesce(t.reason,'Not available'),
           unfulfillable_at = coalesce(oi.unfulfillable_at, now())
      from tgt t
     where oi.id = t.id and oi.unfulfillable = false
    returning coalesce(oi.line_total, oi.quantity * coalesce(oi.price, oi.mrp, 0)) as removed
  )
  select count(*), coalesce(sum(removed),0) into v_marked, v_removed from upd;

  select count(*) into v_unf from order_items where order_id = p_order_id and unfulfillable;

  -- only reduce the total by what was removed THIS call; never rebuild it
  if v_marked > 0 and v_removed > 0 then
    update orders
       set total_amount = greatest(coalesce(total_amount,0) - v_removed, 0)
     where id = p_order_id;
  end if;

  -- CHANGE #646: conditional. The sweep re-reads every unfinalized order every
  -- 120 s; without this predicate each pass rewrote the same rows for ever.
  update orders
     set unfulfilled_count = v_unf,
         unfulfilled_finalized_at = coalesce(unfulfilled_finalized_at, now())
   where id = p_order_id
     and (unfulfilled_count is distinct from v_unf
          or unfulfilled_finalized_at is null);

  -- CHANGE #698 — ASK BEFORE SHIPPING WITHOUT IT. One ask per unfulfilled
  -- line (a unique index enforces that), no candidates means no ask at all,
  -- and any failure here leaves the finalization it is riding on untouched.
  for v_sub_row in
    select oi.id from order_items oi
     where oi.order_id = p_order_id and oi.unfulfillable
       and not exists (select 1 from public.order_substitute_ask a
                        where a.order_item_id = oi.id)
  loop
    begin
      v_res := public.substitute_ask_open(v_sub_row.id);
      if coalesce((v_res->>'ok')::boolean,false)
         and not coalesce((v_res->>'skipped')::boolean,false) then
        v_asked := v_asked + 1;
      end if;
    exception when others then null;
    end;
  end loop;

  select total_amount into v_new_total from orders where id = p_order_id;

  return jsonb_build_object(
    'ok', true, 'order_id', p_order_id, 'order_code', o.order_code,
    'pharmacy_name', o.pharmacy_name,
    'newly_marked', v_marked,
    'removed_value', v_removed,
    'unfulfilled_count', v_unf,
    'substitute_asks', v_asked,
    'new_total', v_new_total,
    'new_total_display', public.inr_money(coalesce(v_new_total,0)),
    'state', v_state);
end $$;

-- ── 14. THE IN-APP SURFACES ─────────────────────────────────────────────────

-- Every open ask on an order, for the card inside the order and for the
-- customer order tab's "the pair" view.
create or replace function public.substitute_ask_for_order(p_order_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_open jsonb; v_pairs jsonb;
begin
  select coalesce(jsonb_agg(public._substitute_ask_payload(a.id) order by a.asked_at), '[]'::jsonb)
    into v_open
    from public.order_substitute_ask a
   where a.order_id = p_order_id
     and a.status in ('asked','submitted','inquiring');

  -- The pair: what was ordered, and what was actually supplied in its place.
  select coalesce(jsonb_agg(jsonb_build_object(
           'ordered_name',    coalesce(orig.product_name, ''),
           'ordered_qty',     coalesce(orig.quantity, 0),
           'supplied_name',   coalesce(sub.product_name, ''),
           'supplied_company', coalesce(m.marketer, ''),
           'supplied_qty',    coalesce(sub.quantity, 0),
           'label', replace(replace(public._c('substitute.applied_title'),
                      '{product}', coalesce(sub.product_name,'')),
                      '{company}', coalesce(m.marketer,''))
         ) order by sub.created_at), '[]'::jsonb)
    into v_pairs
    from public.order_items sub
    join public.order_items orig on orig.id = sub.substitute_for
    left join public."MEDICINE" m on m.id = sub.product_id
   where sub.order_id = p_order_id and sub.substitute_for is not null;

  return jsonb_build_object(
    'has',      (jsonb_array_length(v_open) > 0) or (jsonb_array_length(v_pairs) > 0),
    'has_open', jsonb_array_length(v_open) > 0,
    'cta',      public._c('substitute.card_cta'),
    'pending_label', public._c('substitute.card_pending'),
    'asks',     v_open,
    'pairs',    v_pairs,
    'pair_count', jsonb_array_length(v_pairs));
end $$;

-- ── 15. ADMIN — THE NEVER-SUBSTITUTE LIST ───────────────────────────────────

create or replace function public.substitute_block_rules(p_include_inactive boolean default false)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v jsonb;
begin
  if not coalesce((public.my_session()->>'is_admin')::boolean, false) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'kind', r.kind, 'value', r.value,
           'reason', r.reason, 'active', r.active,
           'kind_label', case r.kind when 'salt' then 'Salt'
                                     when 'therapeutic_class' then 'Therapeutic class'
                                     else 'Company' end)
         order by r.kind, lower(r.value)), '[]'::jsonb)
    into v from public.substitute_block_rule r
   where p_include_inactive or r.active;
  return jsonb_build_object('ok', true, 'rules', v, 'count', jsonb_array_length(v),
    'title', 'Never substitute',
    'note',  'Narrow-therapeutic-index molecules and Schedule X drugs. A product matching any active rule is never offered as a substitute, and is never replaced by one.',
    'kinds', jsonb_build_array(
      jsonb_build_object('key','salt','label','Salt'),
      jsonb_build_object('key','therapeutic_class','label','Therapeutic class'),
      jsonb_build_object('key','company','label','Company')));
end $$;

create or replace function public.substitute_block_rule_save(
  p_kind text, p_value text, p_reason text default '',
  p_active boolean default true, p_id bigint default null)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_id bigint;
begin
  if not coalesce((public.my_session()->>'is_admin')::boolean, false) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  if coalesce(btrim(p_value),'') = '' then
    return jsonb_build_object('ok', false, 'error','value_required');
  end if;
  if p_id is not null then
    update public.substitute_block_rule
       set kind = p_kind, value = btrim(p_value), reason = coalesce(p_reason,''),
           active = coalesce(p_active, true)
     where id = p_id returning id into v_id;
  else
    insert into public.substitute_block_rule (kind, value, reason, active, created_by)
    values (p_kind, btrim(p_value), coalesce(p_reason,''), coalesce(p_active,true), auth.uid())
    on conflict (kind, lower(btrim(value))) do update
      set reason = excluded.reason, active = excluded.active
    returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'rules', public.substitute_block_rules(true));
end $$;

create or replace function public.substitute_product_flag(p_product_id bigint, p_no_substitute boolean)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
begin
  if not coalesce((public.my_session()->>'is_admin')::boolean, false) then
    return jsonb_build_object('ok', false, 'error','not_authorized');
  end if;
  update public."MEDICINE" set no_substitute = p_no_substitute where id = p_product_id;
  return jsonb_build_object('ok', true, 'product_id', p_product_id,
                            'no_substitute', p_no_substitute,
                            'substitutable', public.med_substitutable(p_product_id));
end $$;

-- ── 16. THE CLOCK LIVES ON THE ONE DISPATCHER ───────────────────────────────
-- Gated, so a queue with nothing in it costs a boolean and never a scan. Never
-- its own pg_cron entry: every bare */N schedule collides on minute 0, which
-- is how the fleet took the database out for 29 minutes on 2026-08-18.

insert into public.cron_task (name, ord, mode, gate_sql, work_sql, base_interval_s, enabled, dml, note)
values (
  'substitute_ask_tick', 22, 'poll',
  $g$select exists (
       select 1 from public.order_substitute_ask a
        where a.status in ('asked','submitted','inquiring')
           or (a.closed_at is not null and a.closed_notified_at is null))
     or exists (
       select 1 from public.order_items oi
        where oi.unfulfillable
          and oi.unfulfillable_at > now() - interval '2 days'
          and not exists (select 1 from public.order_substitute_ask a2
                           where a2.order_item_id = oi.id))$g$,
  'select public.substitute_ask_tick(50)', 60, true, true,
  'CHANGE #698 — opens substitute asks, expires the 10-minute timer, applies the first Available, notifies the outcome.')
on conflict (name) do update
  set gate_sql = excluded.gate_sql, work_sql = excluded.work_sql,
      base_interval_s = excluded.base_interval_s, note = excluded.note;

-- ── 17. WHO MAY CALL WHAT ───────────────────────────────────────────────────
-- The public page is anonymous by design (the token is the authorisation, the
-- same contract /stock-update/<token> already ships). Everything that changes
-- an order beyond answering the ask stays behind a session.

grant execute on function public.substitute_ask_page(text)                        to anon, authenticated;
grant execute on function public.substitute_ask_submit(text, bigint[], boolean)    to anon, authenticated;
grant execute on function public.substitute_ask_skip(text)                         to anon, authenticated;
grant execute on function public.substitute_ask_for_order(uuid)                    to authenticated;
grant execute on function public.substitute_candidates(bigint, smallint, uuid, integer) to authenticated;
grant execute on function public.med_substitutable(bigint)                         to authenticated;
grant execute on function public.substitute_block_rules(boolean)                   to authenticated;
grant execute on function public.substitute_block_rule_save(text, text, text, boolean, bigint) to authenticated;
grant execute on function public.substitute_product_flag(bigint, boolean)          to authenticated;
grant execute on function public.substitute_ask_open(uuid)                         to authenticated;
grant execute on function public.substitute_ask_tick(integer)                      to authenticated;
grant execute on function public.substitute_apply(bigint, bigint)                  to authenticated;
grant execute on function public.substitute_ask_close(bigint, text)                to authenticated;

alter table public.order_substitute_ask   enable row level security;
alter table public.order_substitute_probe enable row level security;
alter table public.customer_substitute_pref enable row level security;
alter table public.substitute_block_rule  enable row level security;
-- No policies on purpose: every read and write goes through the security
-- definer RPCs above, so the tables themselves stay closed to PostgREST.

-- ── 18. THE ORDER CARD CARRIES THE ASK ─────────────────────────────────
-- Re-emitted whole (there is no extension point); the only change is the
-- 'substitute' key.

create or replace function public._order_customer_card(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o public.orders%rowtype;
  st jsonb; v_n int; v_amount numeric; v_amount_label text; v_billed boolean;
  v_paid boolean; v_awaiting boolean; v_act text; v_sit text;
  v_map jsonb := coalesce((select value from app_settings where key='orders_card_action_map'),
                          '{}'::jsonb);
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then return null; end if;
  st := public._order_customer_stage(p_order_id);

  select count(distinct oi.product_id) into v_n
    from public.order_items oi where oi.order_id = p_order_id;

  v_amount := coalesce(o.total_amount, 0);
  v_billed := (nullif(btrim(coalesce(o.invoice_no,'')),'') is not null)
              or (nullif(btrim(coalesce(o.cust_bill_path,'')),'') is not null);

  -- ₹0.00 was rendering as a price and reading like a bug. Zero is never a
  -- price here: on a live order it means the rate is not fixed yet, and on a
  -- finished one it means no bill was raised. Two facts, two sentences.
  if v_amount > 0 then
    v_amount_label := public.inr_money(v_amount);
  elsif coalesce((st->>'is_active')::boolean,false) and not v_billed then
    v_amount_label := public._c('orders.rate_on_confirmation');
  else
    v_amount_label := public._c('orders.not_billed');
  end if;

  select exists (select 1 from public.payment_claims c
                  where c.order_id = p_order_id
                    and lower(coalesce(c.status,'')) in ('verified','received'))
    into v_paid;
  v_awaiting := (v_amount > 0) and (not v_paid)
                and (v_billed or coalesce(o.dispatch_ready,false)
                     or coalesce((st->>'is_delivered')::boolean,false));

  -- WHICH action a card offers is DATA. The card works out the SITUATION —
  -- five facts, not five labels — and app_settings.orders_card_action_map says
  -- what each situation is worth tapping. Om changed this once already (a
  -- pre-inquiry Pending order offers the change window, not a tracker), and
  -- that change must never again be a deploy.
  if coalesce((st->>'is_cancelled')::boolean,false) then
    v_sit := 'cancelled';
  elsif v_awaiting then
    v_sit := 'awaiting_payment';
  elsif coalesce((st->>'is_active')::boolean,false) then
    v_sit := case when coalesce((public._order_change_gate(p_order_id)->>'open')::boolean,false)
                  then 'change_window_open' else 'active' end;
  else
    v_sit := 'finished';
  end if;
  v_act := coalesce(nullif(v_map->>v_sit,''), 'track');

  return jsonb_build_object(
    'id',              coalesce(o.id::text,''),
    'order_code',      coalesce(o.order_code,''),
    'placed_at',       coalesce(o.created_at::text,''),
    'date_label',      public._ist_stamp(o.created_at),
    'header_label',    coalesce(nullif(o.order_code,''), '') ,
    'item_count',      coalesce(v_n,0),
    'item_count_label',
      replace(case when coalesce(v_n,0) = 1 then public._c('orders.item_count_one')
                   else public._c('orders.item_count_many') end,
              '{n}', coalesce(v_n,0)::text),
    'amount',          v_amount,
    'amount_label',    v_amount_label,
    'amount_is_money', (v_amount > 0),
    'stage_key',       st->>'key',
    'stage_label',     st->>'label',
    'progress',        jsonb_build_object(
                          'show',  (st->>'show_progress')::boolean,
                          'index', (st->>'index')::int,
                          'steps', st->'steps'),
    'placed_by_admin', coalesce(o.placed_by_admin,false),
    'placed_by_admin_label', case when coalesce(o.placed_by_admin,false)
                                  then public._c('orders.placed_by_admin') else '' end,
    'unfulfilled_count', coalesce(o.unfulfilled_count,0),
    'primary_action',  jsonb_build_object(
                          'key',   v_act,
                          'label', public._c('orders.action_' || v_act),
                          'tone',  coalesce(nullif(v_map->'_tones'->>v_act,''),
                                            case v_act when 'reorder' then 'outline'
                                                       else 'brand' end)),
    -- CHANGE #691 (gap 122/126): the countdown on the card, and the proof
    -- once the order is closed. Both are finished strings.
    'eta',             public._delivery_eta_for_order(p_order_id),
    'proof',           public._delivery_proof_block(p_order_id),
    -- CHANGE #698 — the substitute ask lives ON the order card, because
    -- that is where the customer already is when an item falls out. The
    -- card carries the ask, its countdown sentence and, once it is over,
    -- the pair: what was ordered and what was supplied instead.
    'substitute',      public.substitute_ask_for_order(p_order_id),
    'situation',       v_sit);
end $function$;

-- ── 19. THE ORDER TIMELINE REPORTS THE PAIR (#689) ────────────────────
-- Re-emitted whole; the only change is section 2b.

create or replace function public._order_timeline_events(p_order_id uuid, p_access text, p_can_act boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  o        public.orders%rowtype;
  v_raw    jsonb := '[]'::jsonb;
  v_out    jsonb := '[]'::jsonb;
  r        record;
  v_cust   text; v_cust_phone text;
  v_n      int;  v_amt text; v_ts timestamptz;
  v_open   boolean;
  v_due    numeric;
begin
  select * into o from public.orders where id = p_order_id;
  if not found then return '[]'::jsonb; end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''), nullif(btrim(o.pharmacy_name),''), ''),
         coalesce(nullif(btrim(pp.whatsapp_no),''), nullif(btrim(pp.phone),''), nullif(btrim(o.phone),''), '')
    into v_cust, v_cust_phone
    from public.orders o2 left join public.pharmacy_profiles pp on pp.id = o2.customer_id
   where o2.id = p_order_id;
  v_cust := coalesce(v_cust,''); v_cust_phone := coalesce(v_cust_phone,'');

  -- ── 1. placed ─────────────────────────────────────────────────────────────
  select count(*)::int into v_n from public.order_items where order_id = p_order_id;
  v_amt := public.inr_money(coalesce(o.total_amount, 0));
  v_raw := v_raw || jsonb_build_array(jsonb_build_object(
    'ts', o.created_at, 'stage','placed','hint',0,'internal',false,
    'label',  public._otl_fill('order_timeline.ev_placed','Order placed'),
    'detail', public._otl_fill('order_timeline.ev_placed_detail','{n} items · {amount}',
                jsonb_build_object('n', v_n::text, 'amount', v_amt)),
    'tone','neutral',
    'actor_kind','customer','actor_name',v_cust,'actor_phone',v_cust_phone,
    'action_kind','call_customer','action_args','{}'::jsonb));

  -- ── 2. inquiry: asked / answered / advanced / nobody had it ───────────────
  for r in
    select i.current_supplier as sup, min(i.asked_at) as ts, count(*)::int as n
      from public.order_items oi join public.inquiry i on i.id = oi.inquiry_id
     where oi.order_id = p_order_id and i.asked_at is not null
       and coalesce(btrim(i.current_supplier),'') <> ''
     group by i.current_supplier
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.ts, 'stage','inquiry','hint',1,'internal',false,
      'label',  public._otl_fill('order_timeline.ev_inq_asked','Asked {supplier}',
                  jsonb_build_object('supplier', r.sup)),
      'detail', public._otl_fill('order_timeline.ev_inq_asked_detail','{n} items on the inquiry',
                  jsonb_build_object('n', r.n::text)),
      'tone','neutral',
      'actor_kind','supplier','actor_name',r.sup,'actor_phone','',
      'action_kind','nudge_supplier','action_args', jsonb_build_object('supplier_name', r.sup)));
  end loop;

  for r in
    select i.responsed_by as sup, max(coalesce(i.asked_at, i.created_at)) as ts, count(*)::int as n
      from public.order_items oi join public.inquiry i on i.id = oi.inquiry_id
     where oi.order_id = p_order_id
       and coalesce(btrim(i.responsed_by),'') <> ''
       and (coalesce(i.available,false) or coalesce(i.out_of_stock,false)
            or coalesce(i.we_dont_stock_this_product,false))
     group by i.responsed_by
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.ts, 'stage','inquiry','hint',2,'internal',false,
      'label',  public._otl_fill('order_timeline.ev_inq_answered','{supplier} answered',
                  jsonb_build_object('supplier', r.sup)),
      'detail', public._otl_fill('order_timeline.ev_inq_answered_detail','{n} items answered',
                  jsonb_build_object('n', r.n::text)),
      'tone','green',
      'actor_kind','supplier','actor_name',r.sup,'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  for r in
    select i.next_supplier as sup, max(i.asked_at) as ts
      from public.order_items oi join public.inquiry i on i.id = oi.inquiry_id
     where oi.order_id = p_order_id and coalesce(btrim(i.next_supplier),'') <> ''
       and i.asked_at is not null
     group by i.next_supplier
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.ts, 'stage','inquiry','hint',3,'internal',true,
      'label', public._otl_fill('order_timeline.ev_inq_advanced','Moved on to {supplier}',
                 jsonb_build_object('supplier', r.sup)),
      'detail','','tone','amber',
      'actor_kind','supplier','actor_name',r.sup,'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  select count(*)::int, max(unfulfillable_at) into v_n, v_ts
    from public.order_items where order_id = p_order_id and coalesce(unfulfillable,false);
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','inquiry','hint',4,'internal',false,
      'label', public._otl_fill('order_timeline.ev_unfulfillable','{n} items nobody could supply',
                 jsonb_build_object('n', v_n::text)),
      'detail','','tone','red',
      'actor_kind','medibo','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 2b. the substitute offer (CHANGE #698) ────────────────────────────────
  -- Asked, answered, applied, closed. The pair is visible to the admin and the
  -- partner on the one timeline everything else already reports into.
  for r in
    select a.id, a.asked_at, a.decided_at, a.closed_at, a.status, a.close_reason,
           jsonb_array_length(a.options) as n_opt,
           jsonb_array_length(a.picked)  as n_pick,
           coalesce(oi.product_name,'')  as orig_name,
           coalesce(sm.product_name,'')  as sub_name
      from public.order_substitute_ask a
      left join public.order_items oi on oi.id = a.order_item_id
      left join public."MEDICINE" sm on sm.id = a.applied_product_id
     where a.order_id = p_order_id
     order by a.asked_at
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.asked_at, 'stage','inquiry','hint',5,'internal',false,
      'label',  public._otl_fill('order_timeline.ev_sub_asked','Asked {name} about a substitute',
                  jsonb_build_object('name', v_cust)),
      'detail', public._otl_fill('order_timeline.ev_sub_asked_detail',
                  '{n} options offered · 10 minutes to answer',
                  jsonb_build_object('n', r.n_opt::text)),
      'tone','neutral',
      'actor_kind','customer','actor_name',v_cust,'actor_phone',v_cust_phone,
      'action_kind','call_customer','action_args','{}'::jsonb));

    if r.decided_at is not null and coalesce(r.n_pick,0) > 0 then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.decided_at, 'stage','inquiry','hint',6,'internal',false,
        'label',  public._otl_fill('order_timeline.ev_sub_picked','Customer accepted {n} substitutes',
                    jsonb_build_object('n', r.n_pick::text)),
        'detail', '', 'tone','neutral',
        'actor_kind','customer','actor_name',v_cust,'actor_phone',v_cust_phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;

    if r.status = 'applied' and r.closed_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.closed_at, 'stage','inquiry','hint',7,'internal',false,
        'label',  public._otl_fill('order_timeline.ev_sub_applied','{product} supplied instead',
                    jsonb_build_object('product', r.sub_name)),
        'detail', public._otl_fill('order_timeline.ev_sub_applied_detail','Substitute for {original}',
                    jsonb_build_object('original', r.orig_name)),
        'tone','green',
        'actor_kind','medibo','actor_name','','actor_phone','',
        'action_kind','','action_args','{}'::jsonb));
    elsif r.closed_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.closed_at, 'stage','inquiry','hint',7,'internal',false,
        'label',  public._otl_fill('order_timeline.ev_sub_closed','Substitute offer closed'),
        'detail', public._otl_fill('order_timeline.ev_sub_closed_detail','{reason}',
                    jsonb_build_object('reason', coalesce(r.close_reason,''))),
        'tone','red',
        'actor_kind','medibo','actor_name','','actor_phone','',
        'action_kind','','action_args','{}'::jsonb));
    end if;
  end loop;

  -- ── 3. supplier orders ────────────────────────────────────────────────────
  for r in
    select so.supplier_name as sup, so.created_at, so.accepted_at, so.packed_at,
           so.settled_at, so.accept_state, coalesce(so.decline_reason,'') as decline_reason,
           coalesce(nullif(btrim(sp.whatsapp_no),''), nullif(btrim(sp.phone),''), '') as phone
      from public.supplier_orders so
      left join public.supplier_profiles sp on sp.id = so.supplier_id
     where so.order_id = p_order_id
  loop
    if r.created_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.created_at, 'stage','sourcing','hint',1,'internal',false,
        'label', public._otl_fill('order_timeline.ev_so_sent','Supplier order sent to {supplier}',
                   jsonb_build_object('supplier', r.sup)),
        'detail','','tone','neutral',
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','nudge_supplier','action_args', jsonb_build_object('supplier_name', r.sup)));
    end if;
    if r.accepted_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.accepted_at, 'stage','sourcing','hint',2,'internal',false,
        'label', public._otl_fill(
                   case when coalesce(r.accept_state,'') = 'declined'
                        then 'order_timeline.ev_so_declined' else 'order_timeline.ev_so_accepted' end,
                   '{supplier} accepted', jsonb_build_object('supplier', r.sup)),
        'detail', r.decline_reason,
        'tone', case when coalesce(r.accept_state,'') = 'declined' then 'red' else 'green' end,
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
    if r.packed_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.packed_at, 'stage','sourcing','hint',3,'internal',false,
        'label', public._otl_fill('order_timeline.ev_so_packed','{supplier} packed the order',
                   jsonb_build_object('supplier', r.sup)),
        'detail','','tone','green',
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
    if r.settled_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.settled_at, 'stage','sourcing','hint',4,'internal',true,
        'label', public._otl_fill('order_timeline.ev_so_settled','Settled with {supplier}',
                   jsonb_build_object('supplier', r.sup)),
        'detail','','tone','green',
        'actor_kind','supplier','actor_name',r.sup,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
  end loop;

  -- ── 4. receiving + bagging (warehouse: internal) ──────────────────────────
  select count(*)::int, min(created_at) into v_n, v_ts
    from public.receiving_log where order_id = p_order_id;
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','receiving','hint',1,'internal',true,
      'label', public._otl_fill('order_timeline.ev_received','Received at the warehouse'),
      'detail', public._otl_fill('order_timeline.ev_received_detail','{n} entries',
                  jsonb_build_object('n', v_n::text)),
      'tone','neutral',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  select count(distinct bag_no)::int, min(created_at) into v_n, v_ts
    from public.bag_allocations where order_id = p_order_id;
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','receiving','hint',2,'internal',true,
      'label', public._otl_fill('order_timeline.ev_bagged','Bags allocated'),
      'detail', public._otl_fill('order_timeline.ev_bagged_detail','{n} bags',
                  jsonb_build_object('n', v_n::text)),
      'tone','neutral',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 5. pack + dispatch-ready ──────────────────────────────────────────────
  select count(*)::int, max(packed_at) into v_n, v_ts
    from public.order_items where order_id = p_order_id and coalesce(packed,false);
  if coalesce(v_n,0) > 0 and v_ts is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', v_ts, 'stage','pack','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_packed','Packed'),
      'detail', public._otl_fill('order_timeline.ev_packed_detail','{n} items packed',
                  jsonb_build_object('n', v_n::text)),
      'tone','green',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;
  if o.dispatch_ready_at is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', o.dispatch_ready_at, 'stage','pack','hint',2,'internal',false,
      'label', public._otl_fill('order_timeline.ev_dispatch_ready','Ready to dispatch'),
      'detail','','tone','green',
      'actor_kind','warehouse','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 6. delivery: the milestones on the row, then the event log ────────────
  for r in
    select d.id, d.assigned_at, d.accepted_at, d.started_at, d.arrived_at,
           d.delivered_at, coalesce(d.fail_reason,'') as fail_reason,
           coalesce(nullif(btrim(dp.full_name),''),'') as rider,
           coalesce(nullif(btrim(dp.phone),''),'')     as phone
      from public.deliveries d
      left join public.delivery_partner_registrations dp on dp.id = d.partner_id
     where d.order_id = p_order_id
     order by d.created_at
  loop
    if r.assigned_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.assigned_at, 'stage','dispatch','hint',1,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_assigned','Assigned to {rider}',
                   jsonb_build_object('rider', r.rider)),
        'detail','','tone','neutral',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','reassign','action_args', jsonb_build_object('delivery_id', r.id::text)));
    end if;
    if r.accepted_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.accepted_at, 'stage','dispatch','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_accepted','{rider} accepted the run',
                   jsonb_build_object('rider', r.rider)),
        'detail','','tone','green',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    end if;
    if r.started_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.started_at, 'stage','delivery','hint',1,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_started','Out for delivery'),
        'detail','','tone','neutral',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','call_rider','action_args','{}'::jsonb));
    end if;
    if r.arrived_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.arrived_at, 'stage','delivery','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_arrived','Rider arrived'),
        'detail','','tone','green',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','call_rider','action_args','{}'::jsonb));
    end if;
    if r.delivered_at is not null then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', r.delivered_at, 'stage','delivery','hint',3,'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_delivered','Delivered'),
        'detail','','tone','green',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','','action_args','{}'::jsonb));
    elsif r.fail_reason <> '' then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', coalesce(r.arrived_at, r.started_at, r.assigned_at), 'stage','delivery','hint',4,
        'internal',false,
        'label', public._otl_fill('order_timeline.ev_dlv_failed','Delivery attempt failed'),
        'detail', r.fail_reason,'tone','red',
        'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
        'action_kind','reassign','action_args', jsonb_build_object('delivery_id', r.id::text)));
    end if;
  end loop;

  -- delivery_events: an event this build has no sentence for is SKIPPED, never
  -- rendered as its raw key. A new event type is one ui_copy INSERT.
  for r in
    select de.event, de.created_at, coalesce(de.note,'') as note,
           coalesce(nullif(btrim(dp.full_name),''),'') as rider,
           coalesce(nullif(btrim(dp.phone),''),'')     as phone
      from public.delivery_events de
      left join public.delivery_partner_registrations dp on dp.id = de.partner_id
     where de.order_id = p_order_id
       and public.uic('order_timeline.dlv_'||de.event, '') <> ''
     order by de.created_at
     limit 50
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.created_at, 'stage','delivery','hint',5,'internal',false,
      'label', public.uic('order_timeline.dlv_'||r.event, ''),
      'detail', r.note,'tone','neutral',
      'actor_kind','rider','actor_name',r.rider,'actor_phone',r.phone,
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  -- ── 7. payments ───────────────────────────────────────────────────────────
  for r in
    select pc.created_at, pc.received_at, pc.status, coalesce(pc.verify_reason,'') as reason,
           coalesce(pc.amount,0) as amount
      from public.payment_claims pc
     where pc.order_id = p_order_id
     order by pc.created_at
     limit 30
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', coalesce(r.created_at, r.received_at), 'stage','payment','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_pay_claim','Payment claim received'),
      'detail', public.inr_money(r.amount),'tone','neutral',
      'actor_kind','customer','actor_name',v_cust,'actor_phone',v_cust_phone,
      'action_kind','','action_args','{}'::jsonb));
    if r.status = 'verified' then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', coalesce(r.received_at, r.created_at), 'stage','payment','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_pay_verified','Payment verified'),
        'detail', public.inr_money(r.amount),'tone','green',
        'actor_kind','medibo','actor_name','','actor_phone','',
        'action_kind','','action_args','{}'::jsonb));
    elsif r.status = 'rejected' then
      v_raw := v_raw || jsonb_build_array(jsonb_build_object(
        'ts', coalesce(r.received_at, r.created_at), 'stage','payment','hint',2,'internal',false,
        'label', public._otl_fill('order_timeline.ev_pay_rejected','Payment claim rejected'),
        'detail', r.reason,'tone','red',
        'actor_kind','medibo','actor_name','','actor_phone','',
        'action_kind','chase_payment','action_args','{}'::jsonb));
    end if;
  end loop;

  -- ── 8. WhatsApp attempts (ops chatter: internal only) ─────────────────────
  for r in
    select wa.created_at, wa.event_key, coalesce(wa.ok,false) as ok, coalesce(wa.reason,'') as reason
      from public.wa_send_attempts wa
     where wa.order_id = p_order_id
     order by wa.created_at desc
     limit 25
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.created_at, 'stage','message','hint',1,'internal',true,
      'label', public._otl_fill(case when r.ok then 'order_timeline.ev_wa_ok'
                                     else 'order_timeline.ev_wa_failed' end,
                                'WhatsApp sent'),
      'detail', case when r.ok then r.event_key else r.event_key||' · '||r.reason end,
      'tone', case when r.ok then 'neutral' else 'red' end,
      'actor_kind','medibo','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  -- ── 9. closure ────────────────────────────────────────────────────────────
  if o.closed_at is not null then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', o.closed_at, 'stage','closed','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_closed','Order closed'),
      'detail', coalesce(o.closed_reason,''),'tone','green',
      'actor_kind','medibo','actor_name',coalesce(o.closed_by,''),'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  elsif coalesce(o.status,'') = 'cancelled' or coalesce(o.fulfillment_status,'') = 'cancelled' then
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', coalesce(o.shipped_at, o.created_at), 'stage','closed','hint',1,'internal',false,
      'label', public._otl_fill('order_timeline.ev_cancelled','Order cancelled'),
      'detail','','tone','red',
      'actor_kind','medibo','actor_name','','actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end if;

  -- ── 10. the actions that were taken FROM this timeline ────────────────────
  for r in
    select al.created_at, al.action_kind, al.actor_kind, al.actor_name,
           al.ok, coalesce(al.note,'') as note
      from public.order_timeline_action_log al
     where al.order_id = p_order_id
     order by al.created_at
     limit 50
  loop
    v_raw := v_raw || jsonb_build_array(jsonb_build_object(
      'ts', r.created_at, 'stage','action','hint',1,'internal',true,
      'label', public._otl_fill('order_timeline.ev_act_done','{who} used {action}',
                 jsonb_build_object(
                   'who',    coalesce(nullif(r.actor_name,''), public.uic('order_timeline.actor_medibo','mediBO')),
                   'action', public.uic('order_timeline.act_'||r.action_kind, r.action_kind))),
      'detail', r.note, 'tone', case when r.ok then 'neutral' else 'red' end,
      'actor_kind', r.actor_kind,'actor_name', r.actor_name,'actor_phone','',
      'action_kind','','action_args','{}'::jsonb));
  end loop;

  -- ── assemble: filter, order, word, tone, and hang the action on the step ──
  v_open := (o.closed_at is null
             and coalesce(o.status,'') <> 'cancelled'
             and coalesce(o.fulfillment_status,'') <> 'cancelled'
             and not exists (select 1 from public.deliveries d
                              where d.order_id = p_order_id and d.delivered_at is not null));

  select coalesce(jsonb_agg(x.ev order by x.ts, x.hint, x.ord), '[]'::jsonb)
    into v_out
  from (
    select e.ts, e.hint, e.ord,
           jsonb_build_object(
             'ts',        e.ts,
             'ts_label',  public.ist_fmt(e.ts, 'dmy2_time12'),
             'age_label', public.ops_age_label(e.ts),
             'stage',     e.stage,
             'label',     e.label,
             'detail',    e.detail,
             'has_detail',(coalesce(e.detail,'') <> ''),
             'tone',      case when e.is_last_open and e.late_after_min is not null
                                    and e.age_min >= e.late_after_min then 'red'
                               when e.is_last_open and e.amber_after_min is not null
                                    and e.age_min >= e.amber_after_min then 'amber'
                               else e.tone end,
             'late',      (e.is_last_open and e.late_after_min is not null
                           and e.age_min >= e.late_after_min),
             'late_label',case when e.is_last_open and e.late_after_min is not null
                                    and e.age_min >= e.late_after_min
                               then public.uic('order_timeline.late_label','Late') else '' end,
             'is_current',e.is_last,
             'actor',     public._otl_actor(e.actor_kind, e.actor_name, e.actor_phone, p_access),
             'action',    case when p_can_act and p_access = 'full' and e.is_stage_last
                               then public._otl_action(e.action_kind, p_order_id, e.action_args,
                                      case when e.is_last_open and e.late_after_min is not null
                                                and e.age_min >= e.late_after_min
                                           then 'red' else 'neutral' end)
                               else jsonb_build_object('has', false) end) as ev
      from (
        select (v->>'ts')::timestamptz as ts,
               (v->>'hint')::int       as hint,
               row_number() over ()    as ord,
               v->>'stage'  as stage, v->>'label' as label, v->>'detail' as detail,
               v->>'tone'   as tone,
               v->>'actor_kind' as actor_kind, v->>'actor_name' as actor_name,
               v->>'actor_phone' as actor_phone,
               v->>'action_kind' as action_kind, v->'action_args' as action_args,
               floor(extract(epoch from (now() - (v->>'ts')::timestamptz))/60)::int as age_min,
               ots.late_after_min, ots.amber_after_min,
               row_number() over (order by (v->>'ts')::timestamptz desc, (v->>'hint')::int desc) = 1 as is_last,
               (row_number() over (order by (v->>'ts')::timestamptz desc, (v->>'hint')::int desc) = 1)
                 and v_open as is_last_open,
               row_number() over (partition by v->>'stage'
                                  order by (v->>'ts')::timestamptz desc, (v->>'hint')::int desc) = 1 as is_stage_last
          from jsonb_array_elements(v_raw) t(v)
          left join public.order_timeline_stage ots
                 on ots.stage_key = v->>'stage' and ots.is_active
         where nullif(v->>'ts','') is not null
           and (p_access = 'full' or coalesce((v->>'internal')::boolean, false) = false)
      ) e
  ) x;

  return v_out;
end $function$;

-- ── 20. REVOKE PUBLIC FIRST — a GRANT is not a fence (the #436 class) ───────
-- Postgres gives every new function EXECUTE to PUBLIC, so the grants in §17
-- were decoration: anon already held substitute_apply and substitute_ask_tick
-- the moment they were created. #698's own journey caught it. Revoke first,
-- then grant, and only the three token-page functions reach anon.

revoke all on function public.substitute_ask_page(text)                        from public;
revoke all on function public.substitute_ask_submit(text, bigint[], boolean)   from public;
revoke all on function public.substitute_ask_skip(text)                        from public;
revoke all on function public.substitute_ask_for_order(uuid)                   from public, anon;
revoke all on function public.substitute_candidates(bigint, smallint, uuid, integer) from public, anon;
revoke all on function public.med_substitutable(bigint)                        from public, anon;
revoke all on function public.substitute_block_rules(boolean)                  from public, anon;
revoke all on function public.substitute_block_rule_save(text, text, text, boolean, bigint) from public, anon;
revoke all on function public.substitute_product_flag(bigint, boolean)         from public, anon;
revoke all on function public.substitute_ask_open(uuid)                        from public, anon;
revoke all on function public.substitute_ask_send_wa(bigint)                   from public, anon;
revoke all on function public.substitute_ask_tick(integer)                     from public, anon;
revoke all on function public.substitute_apply(bigint, bigint)                 from public, anon;
revoke all on function public.substitute_ask_close(bigint, text)               from public, anon;
revoke all on function public.substitute_start_probes(bigint)                  from public, anon;
revoke all on function public.substitute_cancel_probe(bigint)                  from public, anon;
revoke all on function public.substitute_equivalent_qty(bigint, bigint, numeric) from public, anon;
revoke all on function public._substitute_ask_payload(bigint)                  from public, anon;
revoke all on function public._substitute_mmss(interval)                       from public, anon;

grant execute on function public.substitute_ask_page(text)                     to anon, authenticated;
grant execute on function public.substitute_ask_submit(text, bigint[], boolean) to anon, authenticated;
grant execute on function public.substitute_ask_skip(text)                      to anon, authenticated;
grant execute on function public.substitute_ask_for_order(uuid)                 to authenticated;
grant execute on function public.substitute_candidates(bigint, smallint, uuid, integer) to authenticated;
grant execute on function public.med_substitutable(bigint)                      to authenticated;
grant execute on function public.substitute_block_rules(boolean)                to authenticated;
grant execute on function public.substitute_block_rule_save(text, text, text, boolean, bigint) to authenticated;
grant execute on function public.substitute_product_flag(bigint, boolean)       to authenticated;
