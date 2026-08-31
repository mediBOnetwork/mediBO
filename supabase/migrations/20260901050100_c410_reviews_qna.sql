-- CMD #410 part 2 — PHARMACY REVIEWS AND Q&A.
--
-- Zero review tables existed. This is the whole feature: who may write, what
-- happens before it is public, and every word either surface shows.
--
-- The rules that shape the schema, all of them from the spec and the business
-- doc (mediBO is B2B trade — the reviewer is a licensed pharmacy, not a
-- patient):
--
--  * VERIFIED PURCHASERS ONLY. A review or an answer may only come from an
--    account that has a DELIVERED order containing that product. Delivery is
--    the truth (deliveries.delivered_at), not order status — an accepted
--    order that never arrived is not experience of the product. The gate is
--    _product_purchase_proof(), one place, used by every write path.
--  * NOTHING IS PUBLIC UNTIL AN ADMIN APPROVES IT. Every row starts
--    'pending'. Rejection carries a REASON, and the author sees their own
--    pending/rejected row (nobody else does) so moderation is never silent.
--  * ONE REVIEW PER ACCOUNT PER PRODUCT, editable — a re-submission returns
--    to 'pending', because editing after approval would otherwise publish
--    unmoderated text.
--  * THE AGGREGATE COUNTS APPROVED ROWS ONLY, and is absent rather than zero:
--    product_rating_summary().has is false below the floor, so the product
--    page shows nothing instead of a lonely "1 review" or a 5.0 from one
--    friendly customer. The compare table reads the same block.
--  * ABUSE FLAGS are a first-class row, not a mailto: link. A flagged item
--    surfaces at the top of the admin queue.
--  * EVERY VISIBLE STRING lives in storefront_ui_label. Dart writes none.

-- ── the tables ──────────────────────────────────────────────────────────────
create table if not exists public.product_review (
  id           bigserial primary key,
  product_id   bigint      not null,
  account_id   uuid        not null,
  stars        smallint    not null check (stars between 1 and 5),
  body         text        not null default '',
  status       text        not null default 'pending'
                 check (status in ('pending','approved','rejected')),
  reject_reason text,
  moderated_by uuid,
  moderated_at timestamptz,
  flag_count   integer     not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create unique index if not exists ux_product_review_one_per_account
  on public.product_review (product_id, account_id);
create index if not exists ix_product_review_public
  on public.product_review (product_id, created_at desc) where status = 'approved';
create index if not exists ix_product_review_queue
  on public.product_review (created_at) where status = 'pending';

create table if not exists public.product_question (
  id           bigserial primary key,
  product_id   bigint      not null,
  account_id   uuid        not null,
  body         text        not null,
  status       text        not null default 'pending'
                 check (status in ('pending','approved','rejected')),
  reject_reason text,
  moderated_by uuid,
  moderated_at timestamptz,
  flag_count   integer     not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists ix_product_question_public
  on public.product_question (product_id, created_at desc) where status = 'approved';
create index if not exists ix_product_question_queue
  on public.product_question (created_at) where status = 'pending';

create table if not exists public.product_answer (
  id           bigserial primary key,
  question_id  bigint      not null references public.product_question(id) on delete cascade,
  account_id   uuid,
  is_official  boolean     not null default false,
  body         text        not null,
  status       text        not null default 'pending'
                 check (status in ('pending','approved','rejected')),
  reject_reason text,
  moderated_by uuid,
  moderated_at timestamptz,
  flag_count   integer     not null default 0,
  created_at   timestamptz not null default now()
);
create index if not exists ix_product_answer_q
  on public.product_answer (question_id, created_at) where status = 'approved';

create table if not exists public.content_flag (
  id           bigserial primary key,
  kind         text   not null check (kind in ('review','question','answer')),
  target_id    bigint not null,
  account_id   uuid,
  reason       text   not null default '',
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz
);
create unique index if not exists ux_content_flag_once
  on public.content_flag (kind, target_id, account_id) where account_id is not null;

alter table public.product_review   enable row level security;
alter table public.product_question enable row level security;
alter table public.product_answer   enable row level security;
alter table public.content_flag     enable row level security;

-- No table policies: every read and write goes through a SECURITY DEFINER RPC
-- that applies the purchaser gate and the moderation gate. Direct table access
-- would be a second, weaker copy of those rules.
revoke all on public.product_review   from anon, authenticated;
revoke all on public.product_question from anon, authenticated;
revoke all on public.product_answer   from anon, authenticated;
revoke all on public.content_flag     from anon, authenticated;
revoke all on sequence public.product_review_id_seq   from anon, authenticated;
revoke all on sequence public.product_question_id_seq from anon, authenticated;
revoke all on sequence public.product_answer_id_seq   from anon, authenticated;
revoke all on sequence public.content_flag_id_seq     from anon, authenticated;

-- ── the tuning knobs (no deploy to change them) ─────────────────────────────
insert into public.app_settings (key, value)
values ('product_review_config', jsonb_build_object(
          'min_reviews_to_show', 1,
          'body_max_chars',      600,
          'question_max_chars',  300,
          'page_size',           5))
on conflict (key) do nothing;

-- ── the copy ────────────────────────────────────────────────────────────────
insert into public.storefront_ui_label (key, value, note) values
  ('rv_title',            'Ratings & reviews',                                               'Reviews block heading'),
  ('rv_qna_title',        'Questions & answers',                                             'Q&A block heading'),
  ('rv_empty',            'No reviews yet.',                                                 'Reviews empty state'),
  ('rv_qna_empty',        'No questions yet.',                                               'Q&A empty state'),
  ('rv_write_cta',        'Write a review',                                                  'Opens the review composer'),
  ('rv_ask_cta',          'Ask a question',                                                  'Opens the question composer'),
  ('rv_answer_cta',       'Answer',                                                          'Opens the answer composer'),
  ('rv_submit',           'Submit',                                                          'Composer submit button'),
  ('rv_cancel',           'Cancel',                                                          'Composer cancel button'),
  ('rv_stars_hint',       'Tap a star to rate',                                              'Star picker hint'),
  ('rv_body_hint',        'What should other pharmacies know?',                              'Review body placeholder'),
  ('rv_question_hint',    'Ask about pack, supply or storage',                               'Question placeholder'),
  ('rv_gate_not_bought',  'Only pharmacies that have received this product can review it.',  'Refusal — no delivered order'),
  ('rv_gate_not_customer','Sign in as an approved customer to review.',                      'Refusal — no customer account'),
  ('rv_pending_note',     'Sent for review. It appears once our team approves it.',          'Own pending row note'),
  ('rv_rejected_note',    'Not published.',                                                  'Own rejected row note'),
  ('rv_submitted_toast',  'Thanks — sent for review.',                                       'Toast after a submit'),
  ('rv_flag_cta',         'Report',                                                          'Abuse flag button'),
  ('rv_flagged_toast',    'Reported. Our team will look at it.',                             'Toast after a flag'),
  ('rv_verified_badge',   'Verified buyer',                                                  'Badge on an approved review'),
  ('rv_official_badge',   'mediBO',                                                          'Badge on an official answer'),
  ('rv_more',             'Show more',                                                       'Pagination button'),
  ('rv_star_suffix',      'out of 5',                                                        'Aggregate suffix'),
  ('rv_count_one',        '1 review',                                                        'Aggregate count, singular'),
  ('rv_count_many',       '{n} reviews',                                                     'Aggregate count, plural'),
  ('rv_no_rating',        'Not rated yet',                                                   'Compare cell when below the floor')
on conflict (key) do nothing;

-- ═══════════════════════════════════════════════════════════════════════════
-- THE GATE — one definition of "verified purchaser", used by every writer.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public._product_purchase_proof(p_product_id bigint, p_account uuid)
returns boolean
language sql
stable security definer
set search_path to 'public'
as $function$
  -- DELIVERED, not merely ordered. deliveries.delivered_at is stamped by the
  -- rider flow with OTP/photo/signature proof, so this is the strongest
  -- evidence the platform holds that the pharmacy actually received the item.
  select exists (
    select 1
      from public.order_items oi
      join public.orders o     on o.id = oi.order_id
      join public.deliveries d on d.order_id = o.id
     where oi.product_id = p_product_id
       and o.customer_id = p_account
       and d.delivered_at is not null);
$function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- THE AGGREGATE — approved rows only, absent rather than zero.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.product_rating_summary(p_product_id bigint)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_cfg   jsonb := coalesce((select value from app_settings where key='product_review_config'), '{}'::jsonb);
  v_floor int   := greatest(coalesce((v_cfg->>'min_reviews_to_show')::int, 1), 1);
  v_n     int;
  v_avg   numeric;
begin
  select count(*), round(avg(stars)::numeric, 1)
    into v_n, v_avg
    from product_review
   where product_id = p_product_id and status = 'approved';

  if coalesce(v_n, 0) < v_floor then
    -- Below the floor the page shows NOTHING. A 5.0 from one review is not a
    -- rating, it is an anecdote, and printing it on a buying screen is the
    -- kind of invented number the substitute block already refuses to print.
    return jsonb_build_object(
      'has', false, 'count', coalesce(v_n, 0), 'stars', null,
      'stars_label', '', 'count_label', '',
      'empty', coalesce((select value from storefront_ui_label where key='rv_no_rating'), ''));
  end if;

  return jsonb_build_object(
    'has',         true,
    'count',       v_n,
    'stars',       v_avg,
    'stars_label', public._num_label(v_avg) || ' ' ||
                   coalesce((select value from storefront_ui_label where key='rv_star_suffix'), ''),
    'count_label', case when v_n = 1
                        then coalesce((select value from storefront_ui_label where key='rv_count_one'), '')
                        else replace(coalesce((select value from storefront_ui_label where key='rv_count_many'), ''),
                                     '{n}', v_n::text) end,
    'empty',       '');
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- THE PUBLIC BLOCK — reviews + Q&A for one product, render-ready.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.product_reviews(p_product_id bigint, p_offset integer default 0)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_cfg    jsonb := coalesce((select value from app_settings where key='product_review_config'), '{}'::jsonb);
  v_page   int   := greatest(coalesce((v_cfg->>'page_size')::int, 5), 1);
  v_off    int   := greatest(coalesce(p_offset, 0), 0);
  v_acct   uuid  := public.my_customer_id();
  v_bought boolean := false;
  v_total  int;
  v_items  jsonb;
  v_qs     jsonb;
  v_gate   text := '';
begin
  if v_acct is not null then
    v_bought := public._product_purchase_proof(p_product_id, v_acct);
  end if;

  -- Why the composer is closed, in the backend's words. The app prints this
  -- and decides nothing.
  if v_acct is null then
    v_gate := coalesce((select value from storefront_ui_label where key='rv_gate_not_customer'), '');
  elsif not v_bought then
    v_gate := coalesce((select value from storefront_ui_label where key='rv_gate_not_bought'), '');
  end if;

  select count(*) into v_total
    from product_review r
   where r.product_id = p_product_id
     and (r.status = 'approved' or (v_acct is not null and r.account_id = v_acct));

  -- An author always sees their OWN row, whatever its status, with the
  -- backend's note attached. Everyone else sees approved rows only.
  select coalesce(jsonb_agg(x.row order by x.mine, x.at desc), '[]'::jsonb) into v_items
    from (
      select jsonb_build_object(
               'id',        r.id::text,
               'stars',     r.stars,
               'body',      r.body,
               'author',    coalesce(nullif(btrim(pp.pharmacy_name), ''), ''),
               'when',      to_char(r.created_at at time zone 'Asia/Kolkata', 'DD Mon YYYY'),
               'is_mine',   (v_acct is not null and r.account_id = v_acct),
               'badge',     case when r.status = 'approved'
                                 then coalesce((select value from storefront_ui_label where key='rv_verified_badge'), '')
                                 else '' end,
               'status',    r.status,
               'has_note',  (r.status <> 'approved'),
               'note',      case r.status
                              when 'pending'  then coalesce((select value from storefront_ui_label where key='rv_pending_note'), '')
                              when 'rejected' then trim(coalesce((select value from storefront_ui_label where key='rv_rejected_note'), '')
                                                        || ' ' || coalesce(r.reject_reason, ''))
                              else '' end,
               'can_flag',  (r.status = 'approved' and v_acct is not null and r.account_id <> v_acct)) as row,
             -- Two ordering columns, not one: the author's OWN row floats to
             -- the top (so a pending submission is visible to the person who
             -- wrote it) and everything else is newest-first.
             (case when v_acct is not null and r.account_id = v_acct then 0 else 1 end) as mine,
             r.created_at as at
        from product_review r
        left join pharmacy_profiles pp on pp.id = r.account_id
       where r.product_id = p_product_id
         and (r.status = 'approved' or (v_acct is not null and r.account_id = v_acct))
       order by mine, at desc
       limit v_page offset v_off) x;

  -- Q&A: an approved question carries its approved answers, in payload order.
  select coalesce(jsonb_agg(x.row order by x.at desc), '[]'::jsonb) into v_qs
    from (
      select jsonb_build_object(
               'id',      q.id::text,
               'body',    q.body,
               'author',  coalesce(nullif(btrim(pp.pharmacy_name), ''), ''),
               'when',    to_char(q.created_at at time zone 'Asia/Kolkata', 'DD Mon YYYY'),
               'is_mine', (v_acct is not null and q.account_id = v_acct),
               'status',  q.status,
               'has_note',(q.status <> 'approved'),
               'note',    case q.status
                            when 'pending'  then coalesce((select value from storefront_ui_label where key='rv_pending_note'), '')
                            when 'rejected' then trim(coalesce((select value from storefront_ui_label where key='rv_rejected_note'), '')
                                                      || ' ' || coalesce(q.reject_reason, ''))
                            else '' end,
               'can_answer', (v_bought and q.status = 'approved'),
               'can_flag',   (q.status = 'approved' and v_acct is not null and q.account_id <> v_acct),
               'answers', coalesce((
                  select jsonb_agg(jsonb_build_object(
                           'id',    a.id::text,
                           'body',  a.body,
                           'badge', case when a.is_official
                                         then coalesce((select value from storefront_ui_label where key='rv_official_badge'), '')
                                         else coalesce((select value from storefront_ui_label where key='rv_verified_badge'), '') end,
                           'when',  to_char(a.created_at at time zone 'Asia/Kolkata', 'DD Mon YYYY'),
                           'can_flag', (v_acct is not null and coalesce(a.account_id, '00000000-0000-0000-0000-000000000000'::uuid) <> v_acct))
                         order by a.created_at)
                    from product_answer a
                   where a.question_id = q.id and a.status = 'approved'), '[]'::jsonb)) as row,
             q.created_at as at
        from product_question q
        left join pharmacy_profiles pp on pp.id = q.account_id
       where q.product_id = p_product_id
         and (q.status = 'approved' or (v_acct is not null and q.account_id = v_acct))
       order by at desc
       limit v_page) x;

  return jsonb_build_object(
    'ok',            true,
    'product_id',    p_product_id::text,
    'summary',       public.product_rating_summary(p_product_id),
    'title',         coalesce((select value from storefront_ui_label where key='rv_title'), ''),
    'qna_title',     coalesce((select value from storefront_ui_label where key='rv_qna_title'), ''),
    'empty',         coalesce((select value from storefront_ui_label where key='rv_empty'), ''),
    'qna_empty',     coalesce((select value from storefront_ui_label where key='rv_qna_empty'), ''),
    -- can_write is the BACKEND's verdict. The app never re-derives it from
    -- "is the user signed in" — that is how a gate ends up implemented twice
    -- and enforced once.
    'can_write',     (v_acct is not null and v_bought),
    'gate_note',     v_gate,
    'labels', jsonb_build_object(
      'write_cta',    coalesce((select value from storefront_ui_label where key='rv_write_cta'), ''),
      'ask_cta',      coalesce((select value from storefront_ui_label where key='rv_ask_cta'), ''),
      'answer_cta',   coalesce((select value from storefront_ui_label where key='rv_answer_cta'), ''),
      'submit',       coalesce((select value from storefront_ui_label where key='rv_submit'), ''),
      'cancel',       coalesce((select value from storefront_ui_label where key='rv_cancel'), ''),
      'stars_hint',   coalesce((select value from storefront_ui_label where key='rv_stars_hint'), ''),
      'body_hint',    coalesce((select value from storefront_ui_label where key='rv_body_hint'), ''),
      'question_hint',coalesce((select value from storefront_ui_label where key='rv_question_hint'), ''),
      'flag_cta',     coalesce((select value from storefront_ui_label where key='rv_flag_cta'), ''),
      'more',         coalesce((select value from storefront_ui_label where key='rv_more'), '')),
    'body_max',      coalesce((v_cfg->>'body_max_chars')::int, 600),
    'question_max',  coalesce((v_cfg->>'question_max_chars')::int, 300),
    'items',         v_items,
    'questions',     v_qs,
    'has_more',      (v_off + v_page) < coalesce(v_total, 0),
    'next_offset',   v_off + v_page);
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- THE WRITES — each one refuses with the backend's own sentence, never a raise.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.review_submit(p_product_id bigint, p_stars integer, p_body text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_acct uuid := public.my_customer_id();
  v_cfg  jsonb := coalesce((select value from app_settings where key='product_review_config'), '{}'::jsonb);
  v_max  int   := coalesce((v_cfg->>'body_max_chars')::int, 600);
  v_id   bigint;
begin
  if v_acct is null then
    return jsonb_build_object('ok', false, 'error', 'not_customer',
      'message', coalesce((select value from storefront_ui_label where key='rv_gate_not_customer'), ''));
  end if;
  if not public._product_purchase_proof(p_product_id, v_acct) then
    return jsonb_build_object('ok', false, 'error', 'not_purchased',
      'message', coalesce((select value from storefront_ui_label where key='rv_gate_not_bought'), ''));
  end if;
  if coalesce(p_stars, 0) not between 1 and 5 then
    return jsonb_build_object('ok', false, 'error', 'bad_stars',
      'message', coalesce((select value from storefront_ui_label where key='rv_stars_hint'), ''));
  end if;

  -- An edit returns to 'pending'. Publishing an edit made after approval
  -- would put unmoderated text on the page under an approved badge.
  insert into product_review (product_id, account_id, stars, body, status, updated_at)
  values (p_product_id, v_acct, p_stars, left(coalesce(p_body, ''), v_max), 'pending', now())
  on conflict (product_id, account_id) do update
    set stars = excluded.stars, body = excluded.body, status = 'pending',
        reject_reason = null, moderated_by = null, moderated_at = null, updated_at = now()
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id::text, 'status', 'pending',
    'message', coalesce((select value from storefront_ui_label where key='rv_submitted_toast'), ''));
end $function$;

create or replace function public.question_submit(p_product_id bigint, p_body text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_acct uuid := public.my_customer_id();
  v_cfg  jsonb := coalesce((select value from app_settings where key='product_review_config'), '{}'::jsonb);
  v_max  int   := coalesce((v_cfg->>'question_max_chars')::int, 300);
  v_id   bigint;
begin
  if v_acct is null then
    return jsonb_build_object('ok', false, 'error', 'not_customer',
      'message', coalesce((select value from storefront_ui_label where key='rv_gate_not_customer'), ''));
  end if;
  if not public._product_purchase_proof(p_product_id, v_acct) then
    return jsonb_build_object('ok', false, 'error', 'not_purchased',
      'message', coalesce((select value from storefront_ui_label where key='rv_gate_not_bought'), ''));
  end if;
  if coalesce(btrim(p_body), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'empty',
      'message', coalesce((select value from storefront_ui_label where key='rv_question_hint'), ''));
  end if;

  insert into product_question (product_id, account_id, body, status)
  values (p_product_id, v_acct, left(btrim(p_body), v_max), 'pending')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id::text, 'status', 'pending',
    'message', coalesce((select value from storefront_ui_label where key='rv_submitted_toast'), ''));
end $function$;

create or replace function public.answer_submit(p_question_id bigint, p_body text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_acct uuid := public.my_customer_id();
  v_prod bigint;
  v_id   bigint;
begin
  select product_id into v_prod from product_question where id = p_question_id and status = 'approved';
  if v_prod is null then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'message', '');
  end if;
  if v_acct is null then
    return jsonb_build_object('ok', false, 'error', 'not_customer',
      'message', coalesce((select value from storefront_ui_label where key='rv_gate_not_customer'), ''));
  end if;
  if not public._product_purchase_proof(v_prod, v_acct) then
    return jsonb_build_object('ok', false, 'error', 'not_purchased',
      'message', coalesce((select value from storefront_ui_label where key='rv_gate_not_bought'), ''));
  end if;
  if coalesce(btrim(p_body), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'empty', 'message', '');
  end if;

  insert into product_answer (question_id, account_id, body, status)
  values (p_question_id, v_acct, btrim(p_body), 'pending')
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id::text, 'status', 'pending',
    'message', coalesce((select value from storefront_ui_label where key='rv_submitted_toast'), ''));
end $function$;

create or replace function public.content_flag_raise(p_kind text, p_target_id bigint, p_reason text default '')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_acct uuid := public.my_customer_id();
begin
  if p_kind not in ('review','question','answer') then
    return jsonb_build_object('ok', false, 'error', 'bad_kind', 'message', '');
  end if;
  if v_acct is null then
    return jsonb_build_object('ok', false, 'error', 'not_customer',
      'message', coalesce((select value from storefront_ui_label where key='rv_gate_not_customer'), ''));
  end if;

  insert into content_flag (kind, target_id, account_id, reason)
  values (p_kind, p_target_id, v_acct, coalesce(btrim(p_reason), ''))
  on conflict (kind, target_id, account_id) where account_id is not null do nothing;

  -- The counter is what floats an item to the top of the moderation queue.
  if p_kind = 'review' then
    update product_review   set flag_count = (select count(*) from content_flag f
                                               where f.kind='review'   and f.target_id = p_target_id and f.resolved_at is null)
     where id = p_target_id;
  elsif p_kind = 'question' then
    update product_question set flag_count = (select count(*) from content_flag f
                                               where f.kind='question' and f.target_id = p_target_id and f.resolved_at is null)
     where id = p_target_id;
  else
    update product_answer   set flag_count = (select count(*) from content_flag f
                                               where f.kind='answer'   and f.target_id = p_target_id and f.resolved_at is null)
     where id = p_target_id;
  end if;

  return jsonb_build_object('ok', true,
    'message', coalesce((select value from storefront_ui_label where key='rv_flagged_toast'), ''));
end $function$;

-- ═══════════════════════════════════════════════════════════════════════════
-- MODERATION — the admin queue and the two verdicts.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.review_moderation_queue(p_status text default 'pending')
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_role text := public.get_my_role();
  v_st   text := case when coalesce(p_status,'') in ('pending','approved','rejected','flagged')
                      then p_status else 'pending' end;
  v_rows jsonb;
begin
  if coalesce(v_role,'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized',
      'title', 'Reviews & Q&A', 'message', 'Admins only.', 'rows', '[]'::jsonb, 'tabs', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(x.row order by x.ord), '[]'::jsonb) into v_rows
    from (
      select jsonb_build_object(
               'kind',      'review',
               'id',        r.id::text,
               'product',   coalesce(m.product_name, ''),
               'product_id',r.product_id::text,
               'author',    coalesce(nullif(btrim(pp.pharmacy_name),''), ''),
               'stars',     r.stars,
               'body',      r.body,
               'status',    r.status,
               'flags',     r.flag_count,
               'when',      to_char(r.created_at at time zone 'Asia/Kolkata', 'DD Mon YYYY HH24:MI'),
               'reason',    coalesce(r.reject_reason, '')) as row,
             (-r.flag_count, r.created_at) as ord
        from product_review r
        join "MEDICINE" m on m.id = r.product_id
        left join pharmacy_profiles pp on pp.id = r.account_id
       where (v_st = 'flagged' and r.flag_count > 0) or (v_st <> 'flagged' and r.status = v_st)
      union all
      select jsonb_build_object(
               'kind',      'question',
               'id',        q.id::text,
               'product',   coalesce(m.product_name, ''),
               'product_id',q.product_id::text,
               'author',    coalesce(nullif(btrim(pp.pharmacy_name),''), ''),
               'stars',     null,
               'body',      q.body,
               'status',    q.status,
               'flags',     q.flag_count,
               'when',      to_char(q.created_at at time zone 'Asia/Kolkata', 'DD Mon YYYY HH24:MI'),
               'reason',    coalesce(q.reject_reason, '')),
             (-q.flag_count, q.created_at)
        from product_question q
        join "MEDICINE" m on m.id = q.product_id
        left join pharmacy_profiles pp on pp.id = q.account_id
       where (v_st = 'flagged' and q.flag_count > 0) or (v_st <> 'flagged' and q.status = v_st)
      union all
      select jsonb_build_object(
               'kind',      'answer',
               'id',        a.id::text,
               'product',   coalesce(m.product_name, ''),
               'product_id',q.product_id::text,
               'author',    coalesce(nullif(btrim(pp.pharmacy_name),''), ''),
               'stars',     null,
               'body',      a.body,
               'status',    a.status,
               'flags',     a.flag_count,
               'when',      to_char(a.created_at at time zone 'Asia/Kolkata', 'DD Mon YYYY HH24:MI'),
               'reason',    coalesce(a.reject_reason, '')),
             (-a.flag_count, a.created_at)
        from product_answer a
        join product_question q on q.id = a.question_id
        join "MEDICINE" m on m.id = q.product_id
        left join pharmacy_profiles pp on pp.id = a.account_id
       where (v_st = 'flagged' and a.flag_count > 0) or (v_st <> 'flagged' and a.status = v_st)
       order by ord
       limit 100) x;

  return jsonb_build_object(
    'ok',     true,
    'title',  'Reviews & Q&A',
    'active', v_st,
    'tabs',   jsonb_build_array(
      jsonb_build_object('key','pending',  'label','Pending',
        'count', (select count(*) from product_review where status='pending')
               + (select count(*) from product_question where status='pending')
               + (select count(*) from product_answer where status='pending')),
      jsonb_build_object('key','flagged',  'label','Reported',
        'count', (select count(*) from content_flag where resolved_at is null)),
      jsonb_build_object('key','approved', 'label','Published',
        'count', (select count(*) from product_review where status='approved')
               + (select count(*) from product_question where status='approved')
               + (select count(*) from product_answer where status='approved')),
      jsonb_build_object('key','rejected', 'label','Rejected',
        'count', (select count(*) from product_review where status='rejected')
               + (select count(*) from product_question where status='rejected')
               + (select count(*) from product_answer where status='rejected'))),
    'approve_label', 'Approve',
    'reject_label',  'Reject',
    'reason_hint',   'Why is it not published?',
    'empty',         'Nothing waiting here.',
    'rows',   v_rows);
end $function$;

create or replace function public.review_moderate(p_kind text, p_id bigint, p_verdict text, p_reason text default '')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_role text := public.get_my_role();
  v_new  text := case when p_verdict = 'approve' then 'approved' else 'rejected' end;
  v_n    int  := 0;
begin
  if coalesce(v_role,'') not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'message', 'Admins only.');
  end if;
  if p_verdict not in ('approve','reject') then
    return jsonb_build_object('ok', false, 'error', 'bad_verdict', 'message', '');
  end if;
  -- A rejection without a reason is a silent deletion as far as the author is
  -- concerned. The spec says rejected-with-a-reason, so the reason is required.
  if v_new = 'rejected' and coalesce(btrim(p_reason), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'reason_required',
      'message', 'Give a reason so the pharmacy knows why.');
  end if;

  if p_kind = 'review' then
    update product_review set status = v_new, reject_reason = nullif(btrim(p_reason), ''),
           moderated_by = auth.uid(), moderated_at = now(), updated_at = now()
     where id = p_id;
    get diagnostics v_n = row_count;
  elsif p_kind = 'question' then
    update product_question set status = v_new, reject_reason = nullif(btrim(p_reason), ''),
           moderated_by = auth.uid(), moderated_at = now()
     where id = p_id;
    get diagnostics v_n = row_count;
  elsif p_kind = 'answer' then
    update product_answer set status = v_new, reject_reason = nullif(btrim(p_reason), ''),
           moderated_by = auth.uid(), moderated_at = now()
     where id = p_id;
    get diagnostics v_n = row_count;
  else
    return jsonb_build_object('ok', false, 'error', 'bad_kind', 'message', '');
  end if;

  if v_n = 0 then
    return jsonb_build_object('ok', false, 'error', 'not_found', 'message', '');
  end if;

  update content_flag set resolved_at = now()
   where kind = p_kind and target_id = p_id and resolved_at is null;

  perform public.audit_write('review_moderate', p_kind, p_id::text, null,
            jsonb_build_object('verdict', v_new, 'reason', coalesce(p_reason, '')));

  return jsonb_build_object('ok', true, 'status', v_new, 'message', '');
end $function$;

grant execute on function public.product_rating_summary(bigint)                  to anon, authenticated;
grant execute on function public.product_reviews(bigint, integer)                to anon, authenticated;
grant execute on function public.review_submit(bigint, integer, text)            to authenticated;
grant execute on function public.question_submit(bigint, text)                   to authenticated;
grant execute on function public.answer_submit(bigint, text)                     to authenticated;
grant execute on function public.content_flag_raise(text, bigint, text)          to authenticated;
grant execute on function public.review_moderation_queue(text)                   to authenticated;
grant execute on function public.review_moderate(text, bigint, text, text)       to authenticated;
revoke execute on function public._product_purchase_proof(bigint, uuid)          from anon, authenticated;

-- The admin entry point. #397 proved a feature with no registry row is a
-- feature Om cannot reach; the row and the shell switch case land together.
insert into public.feature_registry
  (feature_key, label, group_label, icon_key, route_key, sort_order, category, surface,
   roles_allowed, deep_link, description, search_terms, is_active)
values
  ('admin.reviews', 'Reviews & Q&A', 'Admin & System', 'stars', 'reviews', 905, 'system', 'dashboard',
   array['admin','super_admin'], '/admin/go/reviews',
   'Approve or reject product reviews, questions and answers before they go public.',
   'review rating question answer moderation flag report', true)
on conflict (feature_key) do update
  set label = excluded.label, route_key = excluded.route_key, deep_link = excluded.deep_link,
      roles_allowed = excluded.roles_allowed, description = excluded.description,
      search_terms = excluded.search_terms, is_active = true;

-- ═══════════════════════════════════════════════════════════════════════════
-- THE PRODUCT PAGE READS THE AGGREGATE. One extra key on the SAME wrapper
-- #366 used, for the same reason it used one: product_detail() itself is
-- pinned byte-for-byte by test/protected/product_detail_test.dart, and a
-- rating block bolted into it would break a protected contract to add a
-- feature. v2 is where the page's extensions live.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.product_detail_v2(p_product_id bigint, p_pincode text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v jsonb;
begin
  v := public.product_detail(p_product_id);
  if coalesce((v->>'ok')::boolean, false) = false then
    return v;
  end if;
  return v || jsonb_build_object(
    'substitutes',      public.same_composition_options(p_product_id, 10),
    'delivery_promise', public.delivery_promise(p_pincode),
    -- has:false below the review floor, so the header shows nothing at all
    -- rather than a 5.0 that one customer wrote.
    'rating',           public.product_rating_summary(p_product_id),
    -- The compare checkbox on a same-salt row needs a label, and the label is
    -- the backend's. The tray's contents are the only thing the app owns.
    'compare',          jsonb_build_object(
      'add_label', coalesce((select value from storefront_ui_label where key='cmp_add'), ''),
      'cta_label', coalesce((select value from storefront_ui_label where key='cmp_cta'), ''),
      'max',       3));
end $function$;

grant execute on function public.product_detail_v2(bigint, text) to anon, authenticated, service_role;
