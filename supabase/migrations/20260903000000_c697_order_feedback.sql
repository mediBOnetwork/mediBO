-- CHANGE #697 — Whole-order feedback after closure.
--
-- Today a customer can rate the RIDER (delivery_ratings) or a PRODUCT (product
-- reviews). Nothing asks what the mediBO order EXPERIENCE was like. This adds
-- one card, asked once per order, the moment the order closes: five dimension
-- stars, an NPS score, an optional one-line reason, and — on a low score —
-- four tap-chips that name the usual causes for that dimension.
--
-- Everything a screen prints is DATA here: the dimension list, every label,
-- every chip, the NPS scale ends, the toasts, the empty states. Wording is an
-- UPDATE on ui_copy / order_feedback_dimension, never a deploy.
--
-- Idempotent end to end: a resumed worker re-applies this file as a no-op.

-- ───────────────────────── 1. Tables ─────────────────────────

create table if not exists public.order_feedback (
  order_id        uuid primary key references public.orders(id) on delete cascade,
  customer_id     uuid,
  user_id         uuid,
  zone_id         smallint,
  score_ordering  smallint,
  score_packaging smallint,
  score_delivery  smallint,
  score_products  smallint,
  score_support   smallint,
  nps             smallint,
  reason          text,
  chips           text[] not null default '{}',
  source          text not null default 'app',   -- app | wa | admin
  skipped         boolean not null default false,
  ticket_id       uuid,
  created_at      timestamptz not null default now()
);

alter table public.order_feedback
  add column if not exists chips text[] not null default '{}';
alter table public.order_feedback
  add column if not exists skipped boolean not null default false;
alter table public.order_feedback
  add column if not exists ticket_id uuid;

create index if not exists order_feedback_zone_created_idx
  on public.order_feedback (zone_id, created_at desc);
create index if not exists order_feedback_customer_idx
  on public.order_feedback (customer_id, created_at desc);

-- The dimension list is DATA. `col` names the column the score lands in, so a
-- sixth dimension is a migration, but re-WORDING one is an UPDATE on ui_copy.
create table if not exists public.order_feedback_dimension (
  dim_key    text primary key,
  col        text not null,
  copy_key   text not null,
  sort_order int  not null default 0,
  feeds      text not null default '',   -- partner | rider | supplier | support
  is_active  boolean not null default true
);

-- Four tap-chips per dimension, shown only when that dimension scores low.
create table if not exists public.order_feedback_chip (
  dim_key    text not null references public.order_feedback_dimension(dim_key) on delete cascade,
  chip_key   text not null,
  copy_key   text not null,
  sort_order int not null default 0,
  is_active  boolean not null default true,
  primary key (dim_key, chip_key)
);

-- The WhatsApp link. Same shape as stock_update_forms: the token in the URL is
-- the authorisation, and it expires.
create table if not exists public.order_feedback_token (
  token      text primary key,
  order_id   uuid not null references public.orders(id) on delete cascade,
  created_at timestamptz not null default now(),
  sent_at    timestamptz,
  used_at    timestamptz,
  expires_at timestamptz not null default (now() + interval '14 days')
);
create index if not exists order_feedback_token_order_idx
  on public.order_feedback_token (order_id);

-- The nightly aggregate: NPS by zone and week.
create table if not exists public.order_feedback_weekly (
  zone_id       smallint not null,
  week_start    date     not null,
  responses     int      not null default 0,
  promoters     int      not null default 0,
  passives      int      not null default 0,
  detractors    int      not null default 0,
  nps           numeric,
  avg_ordering  numeric,
  avg_packaging numeric,
  avg_delivery  numeric,
  avg_products  numeric,
  avg_support   numeric,
  low_tickets   int      not null default 0,
  updated_at    timestamptz not null default now(),
  primary key (zone_id, week_start)
);

-- The dimension a low-score ticket was raised for. support_ticket already has
-- topic_code; this is the finer tag the spec asks for.
alter table public.support_ticket
  add column if not exists feedback_dim text;

alter table public.order_feedback         enable row level security;
alter table public.order_feedback_token   enable row level security;
alter table public.order_feedback_weekly  enable row level security;
alter table public.order_feedback_dimension enable row level security;
alter table public.order_feedback_chip      enable row level security;

-- ───────────────────────── 2. The data (dimensions, chips, copy) ─────────────

insert into public.order_feedback_dimension (dim_key, col, copy_key, sort_order, feeds) values
  ('ordering',  'score_ordering',  'feedback.dim_ordering',  10, 'support'),
  ('packaging', 'score_packaging', 'feedback.dim_packaging', 20, 'partner'),
  ('delivery',  'score_delivery',  'feedback.dim_delivery',  30, 'rider'),
  ('products',  'score_products',  'feedback.dim_products',  40, 'supplier'),
  ('support',   'score_support',   'feedback.dim_support',   50, 'support')
on conflict (dim_key) do update
  set col = excluded.col, copy_key = excluded.copy_key,
      sort_order = excluded.sort_order, feeds = excluded.feeds;

insert into public.order_feedback_chip (dim_key, chip_key, copy_key, sort_order) values
  ('ordering','hard_to_find','feedback.chip_ordering_hard_to_find',10),
  ('ordering','price_unclear','feedback.chip_ordering_price_unclear',20),
  ('ordering','out_of_stock','feedback.chip_ordering_out_of_stock',30),
  ('ordering','app_slow','feedback.chip_ordering_app_slow',40),
  ('packaging','damaged','feedback.chip_packaging_damaged',10),
  ('packaging','leaking','feedback.chip_packaging_leaking',20),
  ('packaging','loose_strips','feedback.chip_packaging_loose_strips',30),
  ('packaging','wrong_bag','feedback.chip_packaging_wrong_bag',40),
  ('delivery','late','feedback.chip_delivery_late',10),
  ('delivery','rider_rude','feedback.chip_delivery_rider_rude',20),
  ('delivery','wrong_address','feedback.chip_delivery_wrong_address',30),
  ('delivery','no_call','feedback.chip_delivery_no_call',40),
  ('products','short_expiry','feedback.chip_products_short_expiry',10),
  ('products','wrong_item','feedback.chip_products_wrong_item',20),
  ('products','missing_item','feedback.chip_products_missing_item',30),
  ('products','substitute','feedback.chip_products_substitute',40),
  ('support','no_reply','feedback.chip_support_no_reply',10),
  ('support','slow_reply','feedback.chip_support_slow_reply',20),
  ('support','not_resolved','feedback.chip_support_not_resolved',30),
  ('support','hard_to_reach','feedback.chip_support_hard_to_reach',40)
on conflict (dim_key, chip_key) do update
  set copy_key = excluded.copy_key, sort_order = excluded.sort_order;

insert into public.ui_copy (key, value) values
  ('feedback.title',            to_jsonb('How was this order?'::text)),
  ('feedback.subtitle',         to_jsonb('Five taps. It takes about 30 seconds and it decides who we keep on your route.'::text)),
  ('feedback.dim_ordering',     to_jsonb('Ordering experience'::text)),
  ('feedback.dim_packaging',    to_jsonb('Packaging'::text)),
  ('feedback.dim_delivery',     to_jsonb('Delivery'::text)),
  ('feedback.dim_products',     to_jsonb('Products'::text)),
  ('feedback.dim_support',      to_jsonb('Customer support'::text)),
  ('feedback.nps_question',     to_jsonb('How likely are you to recommend mediBO to another pharmacy?'::text)),
  ('feedback.nps_low',          to_jsonb('Not at all'::text)),
  ('feedback.nps_high',         to_jsonb('Very likely'::text)),
  ('feedback.reason_hint',      to_jsonb('Anything we should fix? (optional)'::text)),
  ('feedback.chips_hint',       to_jsonb('What went wrong?'::text)),
  ('feedback.submit',           to_jsonb('Send feedback'::text)),
  ('feedback.skip',             to_jsonb('Not now'::text)),
  ('feedback.thanks',           to_jsonb('Thank you — this is read every morning.'::text)),
  ('feedback.thanks_ticket',    to_jsonb('Thank you. We have opened a ticket and your zone partner will call you back.'::text)),
  ('feedback.already',          to_jsonb('You have already rated this order.'::text)),
  ('feedback.err_not_closed',   to_jsonb('This order is not closed yet.'::text)),
  ('feedback.err_not_yours',    to_jsonb('This order is not on your account.'::text)),
  ('feedback.err_scores',       to_jsonb('Please give every row a star.'::text)),
  ('feedback.err_expired',      to_jsonb('This feedback link has expired.'::text)),
  ('feedback.err_used',         to_jsonb('This feedback has already been sent.'::text)),
  ('feedback.err_unknown',      to_jsonb('This feedback link is not valid.'::text)),
  ('feedback.chip_ordering_hard_to_find',   to_jsonb('Hard to find products'::text)),
  ('feedback.chip_ordering_price_unclear',  to_jsonb('Price was unclear'::text)),
  ('feedback.chip_ordering_out_of_stock',   to_jsonb('Too many items unavailable'::text)),
  ('feedback.chip_ordering_app_slow',       to_jsonb('App was slow'::text)),
  ('feedback.chip_packaging_damaged',       to_jsonb('Box or strip damaged'::text)),
  ('feedback.chip_packaging_leaking',       to_jsonb('Something was leaking'::text)),
  ('feedback.chip_packaging_loose_strips',  to_jsonb('Loose strips in the bag'::text)),
  ('feedback.chip_packaging_wrong_bag',     to_jsonb('Bag was not sealed'::text)),
  ('feedback.chip_delivery_late',           to_jsonb('Arrived late'::text)),
  ('feedback.chip_delivery_rider_rude',     to_jsonb('Rider behaviour'::text)),
  ('feedback.chip_delivery_wrong_address',  to_jsonb('Went to the wrong shop'::text)),
  ('feedback.chip_delivery_no_call',        to_jsonb('No call before arriving'::text)),
  ('feedback.chip_products_short_expiry',   to_jsonb('Short expiry stock'::text)),
  ('feedback.chip_products_wrong_item',     to_jsonb('Wrong item sent'::text)),
  ('feedback.chip_products_missing_item',   to_jsonb('Item missing from the bag'::text)),
  ('feedback.chip_products_substitute',     to_jsonb('Substitute I did not want'::text)),
  ('feedback.chip_support_no_reply',        to_jsonb('Nobody replied'::text)),
  ('feedback.chip_support_slow_reply',      to_jsonb('Reply took too long'::text)),
  ('feedback.chip_support_not_resolved',    to_jsonb('Problem not resolved'::text)),
  ('feedback.chip_support_hard_to_reach',   to_jsonb('Hard to reach anyone'::text)),
  ('feedback.wa_title',         to_jsonb('Rate your mediBO order'::text)),
  ('feedback.wa_intro',         to_jsonb('Tap a star on each row. It takes 30 seconds.'::text)),
  ('feedback.ticket_message',   to_jsonb('Low score on {dim} ({score}/5) for order {order}. Customer note: {reason}'::text)),
  ('feedback.ticket_message_nps', to_jsonb('NPS {nps}/10 on order {order}. Customer note: {reason}'::text)),
  ('feedback.no_reason',        to_jsonb('(no note)'::text)),
  ('feedback.topic_label',      to_jsonb('Feedback on this order'::text)),
  ('feedback.screen_title',     to_jsonb('Feedback'::text)),
  ('feedback.nps_heading',      to_jsonb('NPS trend'::text)),
  ('feedback.dims_heading',     to_jsonb('Dimension averages'::text)),
  ('feedback.worst_heading',    to_jsonb('Needs a callback'::text)),
  ('feedback.empty_title',      to_jsonb('No feedback yet'::text)),
  ('feedback.empty_note',       to_jsonb('Scores appear here as customers rate closed orders.'::text)),
  ('feedback.responses_noun',   to_jsonb('responses'::text)),
  ('feedback.open_order',       to_jsonb('Open order'::text)),
  ('feedback.zone_all',         to_jsonb('All zones'::text)),
  ('orders.action_feedback',    to_jsonb('Rate this order'::text))
on conflict (key) do nothing;

insert into public.support_topic (code, label, hint, sort, active, needs_order)
values ('feedback', 'Feedback on this order',
        'Something about the ordering, packaging, delivery or products', 95, true, true)
on conflict (code) do update set label = excluded.label, hint = excluded.hint;

-- The card action map already decides WHICH action a card offers. A closed,
-- unrated order now offers the feedback card instead of a tracker.
update public.app_settings
   set value = coalesce(value,'{}'::jsonb) || jsonb_build_object('feedback_due','feedback')
 where key = 'orders_card_action_map';
insert into public.app_settings (key, value)
select 'orders_card_action_map', jsonb_build_object('feedback_due','feedback')
 where not exists (select 1 from public.app_settings where key='orders_card_action_map');

-- Two WhatsApp routes: the link the customer gets, and the callback alert the
-- zone partner gets on a low score. auto_manage lets the template pipeline
-- build and submit them; until Meta approves, notify() logs and skips — it
-- never throws into the submit path.
insert into public.wa_event_routes
  (event_key, label, description, language, audience, enabled, auto_manage,
   auto_template_name, wa_category, variable_map, dedupe_minutes,
   push_enabled, push_title, push_body, email_enabled, email_subject, email_body)
values
  ('order_feedback_request', 'Order feedback link to customer',
   'Sent once when an order closes. Opens the public /feedback/<token> page.',
   'en', 'customer', true, true, 'order_feedback_request', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{feedback_link}}"]'::jsonb, 1440,
   true, 'How was order {{order_code}}?',
   'Tap to rate ordering, packaging, delivery, products and support. 30 seconds.',
   true, 'How was mediBO order {{order_code}}?',
   E'Dear {{pharmacy_name}},\n\nHow was order {{order_code}}? Five taps, about 30 seconds:\n\n{{feedback_link}}'),
  ('order_feedback_low', 'Low feedback score — partner callback',
   'Fires when any dimension scores 2 or less, or NPS is 6 or less. The zone partner calls the pharmacy back.',
   'en', 'admin', true, true, 'order_feedback_low', 'utility',
   '["{{pharmacy_name}}", "{{order_code}}", "{{dimension}}", "{{score}}"]'::jsonb, 0,
   true, 'Low score: {{dimension}}',
   '{{pharmacy_name}} scored {{dimension}} {{score}} on order {{order_code}}. Call back today.',
   true, 'Low feedback score on order {{order_code}}',
   E'{{pharmacy_name}} scored {{dimension}} {{score}} on order {{order_code}}.\n\nPlease call the pharmacy back within the callback SLA.')
on conflict (event_key) do nothing;

-- ───────────────────────── 3. Helpers ─────────────────────────

-- Closed = #229's closure state, or the plain business fact behind it
-- (delivered AND the bill settled). Either one opens the feedback window.
create or replace function public._order_feedback_closed(p_order_id uuid)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare o public.orders%rowtype; st jsonb; v_paid boolean; v_amt numeric;
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then return false; end if;
  if o.closed_at is not null then return true; end if;

  st := public._order_customer_stage(p_order_id);
  if not coalesce((st->>'is_delivered')::boolean, false) then return false; end if;

  v_amt := coalesce(o.total_amount, 0);

  select exists (select 1 from public.payment_claims c
                  where c.order_id = p_order_id
                    and lower(coalesce(c.status,'')) in ('verified','received'))
    into v_paid;

  return v_paid or coalesce(v_amt,0) = 0;
end $$;

-- The delivery star the customer already gave the rider, if any. The feedback
-- card pre-fills from it so the two numbers can never disagree.
create or replace function public._order_feedback_rider_stars(p_order_id uuid)
returns smallint language sql stable security definer set search_path to 'public' as $$
  select r.stars from public.delivery_ratings r
   where r.order_id = p_order_id
   order by r.created_at desc limit 1;
$$;

-- The whole card, in one place, so the in-app sheet and the public WhatsApp
-- page render byte-for-byte the same thing.
create or replace function public._order_feedback_card(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_pre smallint; o public.orders%rowtype;
begin
  select * into o from public.orders where id = p_order_id;
  v_pre := public._order_feedback_rider_stars(p_order_id);

  return jsonb_build_object(
    'order_id',      coalesce(o.id::text,''),
    'order_code',    coalesce(o.order_code,''),
    'title',         public._c('feedback.title'),
    'subtitle',      public._c('feedback.subtitle'),
    'nps_question',  public._c('feedback.nps_question'),
    'nps_low',       public._c('feedback.nps_low'),
    'nps_high',      public._c('feedback.nps_high'),
    'nps_min',       0,
    'nps_max',       10,
    'stars_max',     5,
    'low_score_at',  2,
    'reason_hint',   public._c('feedback.reason_hint'),
    'chips_hint',    public._c('feedback.chips_hint'),
    'submit_label',  public._c('feedback.submit'),
    'skip_label',    public._c('feedback.skip'),
    'dimensions',
      coalesce((select jsonb_agg(jsonb_build_object(
                  'key',      d.dim_key,
                  'label',    public._c(d.copy_key),
                  'prefill',  case when d.dim_key = 'delivery' then v_pre end,
                  'chips',    coalesce((select jsonb_agg(jsonb_build_object(
                                          'key',   ch.chip_key,
                                          'label', public._c(ch.copy_key))
                                        order by ch.sort_order, ch.chip_key)
                                        from public.order_feedback_chip ch
                                       where ch.dim_key = d.dim_key and ch.is_active),
                                       '[]'::jsonb))
                order by d.sort_order, d.dim_key)
                from public.order_feedback_dimension d where d.is_active), '[]'::jsonb));
end $$;

-- The system-raised ticket. It is support_ticket_open's own two inserts, with
-- the same ref generator, the same topic table and the same message row — the
-- only difference is that this one may run with no auth.uid() at all, because
-- the WhatsApp link path is anonymous by design.
create or replace function public._order_feedback_open_ticket(
  p_order_id uuid, p_dim text, p_dim_label text, p_score int,
  p_reason text, p_customer uuid, p_user uuid, p_is_nps boolean default false)
returns uuid language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_ref text; v_msg text; o public.orders%rowtype;
begin
  select * into o from public.orders where id = p_order_id;
  v_ref := public._support_next_ref();

  v_msg := case when p_is_nps
    then public._cf('feedback.ticket_message_nps', jsonb_build_object(
           'nps', p_score::text, 'order', coalesce(o.order_code,''),
           'reason', coalesce(nullif(btrim(coalesce(p_reason,'')),''),
                              public._c('feedback.no_reason'))))
    else public._cf('feedback.ticket_message', jsonb_build_object(
           'dim', coalesce(p_dim_label, p_dim), 'score', p_score::text,
           'order', coalesce(o.order_code,''),
           'reason', coalesce(nullif(btrim(coalesce(p_reason,'')),''),
                              public._c('feedback.no_reason')))) end;

  insert into public.support_ticket (ref, customer_id, user_id, order_id, topic_code, feedback_dim)
  values (v_ref, p_customer, p_user, p_order_id, 'feedback', p_dim)
  returning id into v_id;

  insert into public.support_ticket_message (ticket_id, body, sender_role, sender_id)
  values (v_id, v_msg, 'customer', p_user);

  -- The zone partner gets the callback, on the phone the zone registry holds.
  perform public.notify('order_feedback_low',
    coalesce(
      (select z.contact_phone from public.zones z where z.id = o.zone_id),
      (select pu.identity from public.partner_users pu
         join public.region_partners rp on rp.id = pu.partner_id
        where rp.zone_id = o.zone_id and pu.is_active
          and pu.identity ~ '^[0-9]{10}$' limit 1)),
    jsonb_build_object(
      'order_id',      p_order_id::text,
      'order_code',    coalesce(o.order_code,''),
      'pharmacy_name', coalesce((select pp.pharmacy_name from public.pharmacy_profiles pp
                                  where pp.id = p_customer),''),
      'dimension',     coalesce(p_dim_label, p_dim),
      'score',         p_score::text));

  return v_id;
end $$;

-- ───────────────────────── 4. The one writer ─────────────────────────
--
-- Every path — the in-app sheet, the WhatsApp token page, an admin entering it
-- for a phone call — lands here. Scoring, the low-score rule, the rider
-- write-back and the scorecard feeds all happen exactly once, in this function.
create or replace function public._order_feedback_write(
  p_order_id uuid, p_scores jsonb, p_nps int, p_reason text, p_chips text[],
  p_source text, p_customer uuid, p_user uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  o public.orders%rowtype;
  d record;
  v_scores jsonb := coalesce(p_scores, '{}'::jsonb);
  v_missing boolean := false;
  v_val int;
  v_ticket uuid;
  v_first_ticket uuid;
  v_low_n int := 0;
  v_deliv smallint;
  v_del_id uuid;
  v_reason text := nullif(btrim(coalesce(p_reason,'')),'');
  v_chips text[] := coalesce(p_chips, '{}');
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then
    return jsonb_build_object('ok', false, 'error','not_found',
      'message', public._c('feedback.err_unknown'));
  end if;

  if exists (select 1 from public.order_feedback f
              where f.order_id = p_order_id and not f.skipped) then
    return jsonb_build_object('ok', false, 'error','already',
      'message', public._c('feedback.already'));
  end if;

  -- Every active dimension needs a star. Absence is an error, never a default.
  for d in select * from public.order_feedback_dimension where is_active loop
    v_val := nullif(v_scores->>d.dim_key,'')::int;
    if v_val is null or v_val < 1 or v_val > 5 then v_missing := true; end if;
  end loop;
  if v_missing then
    return jsonb_build_object('ok', false, 'error','scores_required',
      'message', public._c('feedback.err_scores'));
  end if;
  if p_nps is null or p_nps < 0 or p_nps > 10 then
    return jsonb_build_object('ok', false, 'error','nps_required',
      'message', public._c('feedback.err_scores'));
  end if;

  insert into public.order_feedback (
    order_id, customer_id, user_id, zone_id,
    score_ordering, score_packaging, score_delivery, score_products, score_support,
    nps, reason, chips, source, skipped)
  values (
    p_order_id, coalesce(p_customer, o.customer_id), p_user, o.zone_id,
    (v_scores->>'ordering')::int,  (v_scores->>'packaging')::int,
    (v_scores->>'delivery')::int,  (v_scores->>'products')::int,
    (v_scores->>'support')::int,
    p_nps, v_reason, v_chips, coalesce(nullif(p_source,''),'app'), false)
  on conflict (order_id) do update set
    customer_id = excluded.customer_id, user_id = excluded.user_id,
    zone_id = excluded.zone_id,
    score_ordering = excluded.score_ordering, score_packaging = excluded.score_packaging,
    score_delivery = excluded.score_delivery, score_products = excluded.score_products,
    score_support  = excluded.score_support,
    nps = excluded.nps, reason = excluded.reason, chips = excluded.chips,
    source = excluded.source, skipped = false, created_at = now();

  -- ── Rider write-back. The delivery star and delivery_ratings are ONE number.
  v_deliv := (v_scores->>'delivery')::int;
  select dl.id into v_del_id from public.deliveries dl
   where dl.order_id = p_order_id and dl.status = 'delivered'
   order by dl.delivered_at desc limit 1;
  if v_del_id is not null and v_deliv between 1 and 5 then
    insert into public.delivery_ratings
      (delivery_id, order_id, partner_id, customer_id, stars, comment)
    select v_del_id, p_order_id, dl.partner_id, coalesce(p_customer, o.customer_id),
           v_deliv, v_reason
      from public.deliveries dl where dl.id = v_del_id
    on conflict (delivery_id) do update
      set stars = excluded.stars,
          comment = coalesce(excluded.comment, public.delivery_ratings.comment);
  end if;

  -- ── Low-score rule: any dimension <= 2, or NPS <= 6, opens a ticket tagged
  -- with the dimension and pings the zone partner for a callback.
  for d in select * from public.order_feedback_dimension where is_active
            order by sort_order, dim_key loop
    v_val := (v_scores->>d.dim_key)::int;
    if v_val <= 2 then
      v_low_n := v_low_n + 1;
      v_ticket := public._order_feedback_open_ticket(
        p_order_id, d.dim_key, public._c(d.copy_key), v_val, v_reason,
        coalesce(p_customer, o.customer_id), p_user, false);
      v_first_ticket := coalesce(v_first_ticket, v_ticket);
    end if;
  end loop;

  if p_nps <= 6 and v_low_n = 0 then
    v_low_n := v_low_n + 1;
    v_first_ticket := public._order_feedback_open_ticket(
      p_order_id, 'nps', public._c('feedback.nps_question'), p_nps, v_reason,
      coalesce(p_customer, o.customer_id), p_user, true);
  end if;

  if v_first_ticket is not null then
    update public.order_feedback set ticket_id = v_first_ticket where order_id = p_order_id;
  end if;

  -- ── Scorecard feeds. One ledger, the one the exception scorecards already
  -- read, so #693 and supplier_scorecard pick these up with no new plumbing.
  for d in select * from public.order_feedback_dimension where is_active and feeds <> '' loop
    v_val := (v_scores->>d.dim_key)::int;
    if d.feeds = 'partner' or d.feeds = 'support' then
      insert into public.exception_scorecard_input
        (subject_kind, subject_key, reason_code, outcome_code, weight, exception_id, zone_id, closed_at, closed_by)
      select case when d.feeds='partner' then 'partner' else 'support' end,
             coalesce((select rp.id::text from public.region_partners rp
                        where rp.zone_id = o.zone_id and rp.is_active limit 1), o.zone_id::text),
             'feedback_' || d.dim_key, 'score_' || v_val::text,
             (v_val - 3)::numeric, 'ofb:' || p_order_id::text || ':' || d.dim_key,
             o.zone_id, now(), 'order_feedback'
      where not exists (select 1 from public.exception_scorecard_input e
                         where e.exception_id = 'ofb:' || p_order_id::text || ':' || d.dim_key);
    elsif d.feeds = 'supplier' then
      insert into public.exception_scorecard_input
        (subject_kind, subject_key, reason_code, outcome_code, weight, exception_id, zone_id, closed_at, closed_by)
      select 'supplier', s.assigned_supplier,
             'feedback_products', 'score_' || v_val::text,
             (v_val - 3)::numeric,
             'ofb:' || p_order_id::text || ':products:' || s.assigned_supplier,
             o.zone_id, now(), 'order_feedback'
        from (select distinct nullif(btrim(coalesce(oi.assigned_supplier,'')),'') as assigned_supplier
                from public.order_items oi where oi.order_id = p_order_id) s
       where s.assigned_supplier is not null
         and not exists (select 1 from public.exception_scorecard_input e
                          where e.exception_id = 'ofb:' || p_order_id::text || ':products:' || s.assigned_supplier);
    end if;
  end loop;

  update public.order_feedback_token set used_at = now()
   where order_id = p_order_id and used_at is null;

  return jsonb_build_object(
    'ok', true,
    'ticket_opened', (v_first_ticket is not null),
    'ticket_id', coalesce(v_first_ticket::text,''),
    'low_count', v_low_n,
    'message', case when v_first_ticket is not null
                    then public._c('feedback.thanks_ticket')
                    else public._c('feedback.thanks') end);
end $$;

-- ───────────────────────── 5. Customer RPCs ─────────────────────────

-- show:true exactly once per order: closed, mine, and not yet answered or
-- skipped. The card itself is `_order_feedback_card`, so the WhatsApp page and
-- this sheet can never drift apart.
create or replace function public.order_feedback_prompt(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_has boolean;
begin
  if not public._order_is_mine(p_order_id) then
    return jsonb_build_object('show', false, 'error','not_your_order',
      'message', public._c('feedback.err_not_yours'));
  end if;
  if not public._order_feedback_closed(p_order_id) then
    return jsonb_build_object('show', false, 'error','not_closed',
      'message', public._c('feedback.err_not_closed'));
  end if;
  select exists(select 1 from public.order_feedback f where f.order_id = p_order_id)
    into v_has;
  if v_has then
    return jsonb_build_object('show', false, 'rated', true,
      'message', public._c('feedback.already'));
  end if;
  return jsonb_build_object('show', true, 'rated', false)
         || public._order_feedback_card(p_order_id);
end $$;

-- The next closed order this pharmacy has not answered for. The Orders tab
-- asks this once per load so the card can appear without a deep link.
create or replace function public.order_feedback_pending()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_cust uuid := public.my_customer_id(); v_id uuid;
begin
  if v_cust is null then return jsonb_build_object('show', false); end if;
  select o.id into v_id
    from public.orders o
   where o.customer_id = v_cust
     and public._order_feedback_closed(o.id)
     and not exists (select 1 from public.order_feedback f where f.order_id = o.id)
   order by coalesce(o.closed_at, o.created_at) desc
   limit 1;
  if v_id is null then return jsonb_build_object('show', false); end if;
  return jsonb_build_object('show', true, 'rated', false)
         || public._order_feedback_card(v_id);
end $$;

create or replace function public.order_feedback_submit(
  p_order_id uuid, p_scores jsonb, p_nps int,
  p_reason text default null, p_chips text[] default '{}')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  if not public._order_is_mine(p_order_id) then
    return jsonb_build_object('ok', false, 'error','not_your_order',
      'message', public._c('feedback.err_not_yours'));
  end if;
  if not public._order_feedback_closed(p_order_id) then
    return jsonb_build_object('ok', false, 'error','not_closed',
      'message', public._c('feedback.err_not_closed'));
  end if;
  return public._order_feedback_write(p_order_id, p_scores, p_nps, p_reason,
    p_chips, 'app', public.my_customer_id(), auth.uid());
end $$;

-- Skippable, and never asked twice: the skip is a row like any other answer.
create or replace function public.order_feedback_skip(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare o public.orders%rowtype;
begin
  if not public._order_is_mine(p_order_id) then
    return jsonb_build_object('ok', false, 'error','not_your_order',
      'message', public._c('feedback.err_not_yours'));
  end if;
  select * into o from public.orders where id = p_order_id;
  insert into public.order_feedback (order_id, customer_id, user_id, zone_id, source, skipped)
  values (p_order_id, o.customer_id, auth.uid(), o.zone_id, 'app', true)
  on conflict (order_id) do nothing;
  update public.order_feedback_token set used_at = now()
   where order_id = p_order_id and used_at is null;
  return jsonb_build_object('ok', true, 'skipped', true);
end $$;

-- ───────────────────────── 6. The public WhatsApp link (anon) ────────────────
-- Same pattern as /stock-update/<token>: the token in the URL is the whole
-- authorisation. Anonymous by design — a pharmacy that never opens the app
-- still gets asked, and still gets a callback when the score is low.

create or replace function public.order_feedback_form(p_token text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare t public.order_feedback_token%rowtype;
begin
  select * into t from public.order_feedback_token where token = p_token;
  if t.token is null then
    return jsonb_build_object('ok', false, 'error','unknown',
      'title', public._c('feedback.wa_title'),
      'message', public._c('feedback.err_unknown'));
  end if;
  if t.used_at is not null
     or exists (select 1 from public.order_feedback f
                 where f.order_id = t.order_id and not f.skipped) then
    return jsonb_build_object('ok', false, 'error','used',
      'title', public._c('feedback.wa_title'),
      'message', public._c('feedback.err_used'));
  end if;
  if t.expires_at < now() then
    return jsonb_build_object('ok', false, 'error','expired',
      'title', public._c('feedback.wa_title'),
      'message', public._c('feedback.err_expired'));
  end if;
  return jsonb_build_object('ok', true, 'intro', public._c('feedback.wa_intro'))
         || public._order_feedback_card(t.order_id);
end $$;

create or replace function public.order_feedback_submit_token(
  p_token text, p_scores jsonb, p_nps int,
  p_reason text default null, p_chips text[] default '{}')
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare t public.order_feedback_token%rowtype; o public.orders%rowtype;
begin
  select * into t from public.order_feedback_token where token = p_token;
  if t.token is null then
    return jsonb_build_object('ok', false, 'error','unknown',
      'message', public._c('feedback.err_unknown'));
  end if;
  if t.used_at is not null then
    return jsonb_build_object('ok', false, 'error','used',
      'message', public._c('feedback.err_used'));
  end if;
  if t.expires_at < now() then
    return jsonb_build_object('ok', false, 'error','expired',
      'message', public._c('feedback.err_expired'));
  end if;
  select * into o from public.orders where id = t.order_id;
  return public._order_feedback_write(t.order_id, p_scores, p_nps, p_reason,
    p_chips, 'wa', o.customer_id, null);
end $$;

-- One token per order, minted once and re-used, so a resend is the same link.
create or replace function public.order_feedback_send_wa(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_token text; o public.orders%rowtype; v_phone text;
begin
  select * into o from public.orders where id = p_order_id;
  if o.id is null then return jsonb_build_object('ok', false, 'error','not_found'); end if;
  if exists (select 1 from public.order_feedback f where f.order_id = p_order_id) then
    return jsonb_build_object('ok', false, 'error','already');
  end if;

  select token into v_token from public.order_feedback_token
   where order_id = p_order_id and used_at is null and expires_at > now()
   order by created_at desc limit 1;

  if v_token is null then
    v_token := encode(gen_random_bytes(16), 'hex');
    insert into public.order_feedback_token (token, order_id) values (v_token, p_order_id);
  end if;

  select right(regexp_replace(coalesce(nullif(btrim(pp.whatsapp_no),''), pp.phone, ''),'\D','','g'),10)
    into v_phone from public.pharmacy_profiles pp where pp.id = o.customer_id;

  perform public.notify('order_feedback_request', v_phone, jsonb_build_object(
    'order_id',      p_order_id::text,
    'customer_id',   coalesce(o.customer_id::text,''),
    'order_code',    coalesce(o.order_code,''),
    'pharmacy_name', coalesce((select pp.pharmacy_name from public.pharmacy_profiles pp
                                where pp.id = o.customer_id),''),
    'feedback_link', 'https://medibo.in/feedback/' || v_token));

  update public.order_feedback_token set sent_at = now() where token = v_token;
  return jsonb_build_object('ok', true, 'token', v_token,
                            'link', 'https://medibo.in/feedback/' || v_token);
end $$;

-- The sweep: every order that closed in the last 3 days, has no feedback and
-- has never been asked, gets exactly one WhatsApp link.
create or replace function public.order_feedback_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r record; v_n int := 0;
begin
  for r in
    select o.id from public.orders o
     where o.closed_at is not null
       and o.closed_at > now() - interval '3 days'
       and not exists (select 1 from public.order_feedback f where f.order_id = o.id)
       and not exists (select 1 from public.order_feedback_token t where t.order_id = o.id)
     order by o.closed_at desc
     limit 200
  loop
    perform public.order_feedback_send_wa(r.id);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'sent', v_n);
end $$;

-- ───────────────────────── 7. Nightly aggregate ─────────────────────────

create or replace function public.order_feedback_rollup(p_weeks int default 12)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_n int;
begin
  insert into public.order_feedback_weekly (
    zone_id, week_start, responses, promoters, passives, detractors, nps,
    avg_ordering, avg_packaging, avg_delivery, avg_products, avg_support,
    low_tickets, updated_at)
  select coalesce(f.zone_id, 0)::smallint,
         (date_trunc('week', (f.created_at at time zone 'Asia/Kolkata'))::date),
         count(*)::int,
         count(*) filter (where f.nps >= 9)::int,
         count(*) filter (where f.nps between 7 and 8)::int,
         count(*) filter (where f.nps <= 6)::int,
         round(100.0 * (count(*) filter (where f.nps >= 9)
                        - count(*) filter (where f.nps <= 6))::numeric
               / nullif(count(*),0), 1),
         round(avg(f.score_ordering)::numeric, 2),
         round(avg(f.score_packaging)::numeric, 2),
         round(avg(f.score_delivery)::numeric, 2),
         round(avg(f.score_products)::numeric, 2),
         round(avg(f.score_support)::numeric, 2),
         count(*) filter (where f.ticket_id is not null)::int,
         now()
    from public.order_feedback f
   where not f.skipped
     and f.created_at > now() - make_interval(weeks => greatest(coalesce(p_weeks,12), 1))
   group by 1, 2
  on conflict (zone_id, week_start) do update set
    responses = excluded.responses, promoters = excluded.promoters,
    passives = excluded.passives, detractors = excluded.detractors,
    nps = excluded.nps,
    avg_ordering = excluded.avg_ordering, avg_packaging = excluded.avg_packaging,
    avg_delivery = excluded.avg_delivery, avg_products = excluded.avg_products,
    avg_support = excluded.avg_support, low_tickets = excluded.low_tickets,
    updated_at = now();
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'weeks_written', v_n);
end $$;

insert into public.cron_task (name, ord, mode, work_sql, step_timeout_ms, enabled, note,
                              base_interval_s, max_interval_s, run_at_ist, dml)
values ('order_feedback_rollup', 592, 'poll',
        'select public.order_feedback_rollup(12);', 30000, true,
        'CHANGE #697 — nightly NPS + dimension averages by zone and week.',
        3600, 3600, '02:40:00', true),
       ('order_feedback_sweep', 594, 'poll',
        'select public.order_feedback_sweep();', 30000, true,
        'CHANGE #697 — one WhatsApp feedback link per newly closed order.',
        3600, 3600, '11:20:00', true)
on conflict (name) do update
  set work_sql = excluded.work_sql, note = excluded.note,
      run_at_ist = excluded.run_at_ist, enabled = excluded.enabled;

-- ───────────────────────── 8. The admin / partner screen ─────────────────────
-- Zone-scoped for a partner (their own zone, no picker), all zones for an
-- admin. Every number, label and tone is finished here.
create or replace function public.order_feedback_screen(
  p_zone int default null, p_weeks int default 8)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_role    text   := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_zone    int    := p_zone;
  v_locked  boolean := false;
  v_weeks   int    := greatest(least(coalesce(p_weeks, 8), 26), 2);
  v_trend   jsonb; v_dims jsonb; v_worst jsonb; v_zones jsonb;
  v_total   int; v_nps numeric;
begin
  if v_partner is not null then
    select rp.zone_id into v_zone from public.region_partners rp where rp.id = v_partner;
    v_locked := true;
  elsif v_role not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title', public._c('feedback.screen_title'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'week_start',  w.week_start::text,
           'label',       to_char(w.week_start, 'DD Mon'),
           'nps',         w.nps,
           'nps_label',   coalesce(w.nps::text, '—'),
           'responses',   w.responses,
           'responses_label', w.responses::text || ' ' || public._c('feedback.responses_noun'),
           'tone',        case when w.nps is null then 'info'
                               when w.nps >= 50 then 'success'
                               when w.nps >= 0  then 'warning'
                               else 'danger' end)
           order by w.week_start), '[]'::jsonb)
    into v_trend
    from public.order_feedback_weekly w
   where w.week_start >= (current_date - (v_weeks * 7))
     and (v_zone is null or w.zone_id = v_zone);

  select count(*)::int,
         round(100.0 * (count(*) filter (where f.nps >= 9)
                        - count(*) filter (where f.nps <= 6))::numeric
               / nullif(count(*),0), 1)
    into v_total, v_nps
    from public.order_feedback f
   where not f.skipped
     and f.created_at >= now() - make_interval(weeks => v_weeks)
     and (v_zone is null or f.zone_id = v_zone);

  select coalesce(jsonb_agg(x.js order by x.sort_order), '[]'::jsonb) into v_dims
    from (
      select d.sort_order,
             jsonb_build_object(
               'key',   d.dim_key,
               'label', public._c(d.copy_key),
               'avg',   a.v,
               'avg_label', coalesce(to_char(a.v, 'FM990.0'), '—'),
               'tone',  case when a.v is null then 'info'
                             when a.v >= 4.0 then 'success'
                             when a.v >= 3.0 then 'warning'
                             else 'danger' end) as js
        from public.order_feedback_dimension d
        left join lateral (
          select round(avg(
                   case d.dim_key
                     when 'ordering'  then f.score_ordering
                     when 'packaging' then f.score_packaging
                     when 'delivery'  then f.score_delivery
                     when 'products'  then f.score_products
                     when 'support'   then f.score_support end)::numeric, 2) as v
            from public.order_feedback f
           where not f.skipped
             and f.created_at >= now() - make_interval(weeks => v_weeks)
             and (v_zone is null or f.zone_id = v_zone)) a on true
       where d.is_active) x;

  select coalesce(jsonb_agg(jsonb_build_object(
           'order_id',    f.order_id::text,
           'order_code',  coalesce(o.order_code,''),
           'customer',    coalesce(pp.pharmacy_name,''),
           'when_label',  public._ist_stamp(f.created_at),
           'nps_label',   'NPS ' || f.nps::text,
           'worst_label', lo.label || ' ' || lo.score::text || '/5',
           'reason',      coalesce(f.reason,''),
           'has_reason',  (nullif(btrim(coalesce(f.reason,'')),'') is not null),
           'ticket',      (f.ticket_id is not null),
           'tone',        'danger',
           'open_label',  public._c('feedback.open_order'))
           order by f.created_at desc), '[]'::jsonb)
    into v_worst
    from public.order_feedback f
    join public.orders o on o.id = f.order_id
    left join public.pharmacy_profiles pp on pp.id = f.customer_id
    cross join lateral (
      select v.label, v.score from (values
        (public._c('feedback.dim_ordering'),  f.score_ordering),
        (public._c('feedback.dim_packaging'), f.score_packaging),
        (public._c('feedback.dim_delivery'),  f.score_delivery),
        (public._c('feedback.dim_products'),  f.score_products),
        (public._c('feedback.dim_support'),   f.score_support)
      ) as v(label, score)
      order by v.score nulls last limit 1) lo
   where not f.skipped
     and (v_zone is null or f.zone_id = v_zone)
     and (f.nps <= 6 or least(coalesce(f.score_ordering,5), coalesce(f.score_packaging,5),
                              coalesce(f.score_delivery,5), coalesce(f.score_products,5),
                              coalesce(f.score_support,5)) <= 2)
     and f.created_at >= now() - make_interval(weeks => v_weeks)
   limit 20;

  if not v_locked then
    select jsonb_agg(jsonb_build_object('id', z.id, 'label', z.name,
                                        'selected', (v_zone = z.id))
                     order by z.id)
      into v_zones from public.zones z where z.is_active;
    v_zones := jsonb_build_array(jsonb_build_object(
                 'id', null, 'label', public._c('feedback.zone_all'),
                 'selected', (v_zone is null))) || coalesce(v_zones, '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'ok', true,
    'title',          public._c('feedback.screen_title'),
    'nps_heading',    public._c('feedback.nps_heading'),
    'dims_heading',   public._c('feedback.dims_heading'),
    'worst_heading',  public._c('feedback.worst_heading'),
    'empty_title',    public._c('feedback.empty_title'),
    'empty_note',     public._c('feedback.empty_note'),
    'zone_locked',    v_locked,
    'zone_id',        v_zone,
    'zones',          coalesce(v_zones, '[]'::jsonb),
    'weeks',          v_weeks,
    'responses',      coalesce(v_total, 0),
    'responses_label',coalesce(v_total,0)::text || ' ' || public._c('feedback.responses_noun'),
    'nps',            v_nps,
    'nps_label',      coalesce(v_nps::text, '—'),
    'nps_tone',       case when v_nps is null then 'info'
                           when v_nps >= 50 then 'success'
                           when v_nps >= 0  then 'warning'
                           else 'danger' end,
    'has_rows',       (coalesce(v_total,0) > 0),
    'trend',          v_trend,
    'dimensions',     v_dims,
    'worst',          v_worst);
end $$;

-- ───────────────────────── 9. Access ─────────────────────────

insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, owner,
   partner_eligible, default_access, is_active, category, surface,
   roles_allowed, deep_link, search_terms, description, canonical_key)
values
  ('admin.feedback', 'Feedback', 'Admin & System', 'stars', 'feedback', 906,
   'medibo', true, 'read', true, 'system', 'dashboard',
   array['admin','super_admin','partner'], '/admin/go/feedback',
   'feedback nps rating score packaging delivery products support experience',
   'NPS trend, dimension averages and the recent orders that need a callback.',
   'admin.feedback')
on conflict (feature_key) do update
  set label = excluded.label, route_key = excluded.route_key,
      partner_eligible = excluded.partner_eligible,
      roles_allowed = excluded.roles_allowed, is_active = true,
      deep_link = excluded.deep_link, description = excluded.description;

-- order_feedback_screen scopes ITSELF: my_partner_id() pins the zone and drops
-- the picker, so a partner cannot ask for a zone that is not theirs. It is not
-- an admin_% name, so the partner RPC gate has nothing to open.

grant execute on function public.order_feedback_prompt(uuid)              to authenticated;
grant execute on function public.order_feedback_pending()                 to authenticated;
grant execute on function public.order_feedback_submit(uuid, jsonb, int, text, text[]) to authenticated;
grant execute on function public.order_feedback_skip(uuid)                to authenticated;
grant execute on function public.order_feedback_screen(int, int)          to authenticated;
grant execute on function public.order_feedback_send_wa(uuid)             to authenticated, service_role;

-- The WhatsApp page is anonymous, exactly like /stock-update/<token>.
grant execute on function public.order_feedback_form(text)                to anon, authenticated;
grant execute on function public.order_feedback_submit_token(text, jsonb, int, text, text[]) to anon, authenticated;

revoke execute on function public.order_feedback_sweep()   from anon;
revoke execute on function public.order_feedback_rollup(int) from anon;
revoke execute on function public._order_feedback_write(uuid, jsonb, int, text, text[], text, uuid, uuid) from anon, authenticated;
revoke execute on function public._order_feedback_open_ticket(uuid, text, text, int, text, uuid, uuid, boolean) from anon, authenticated;
