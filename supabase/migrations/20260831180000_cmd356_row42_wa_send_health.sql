-- CHANGE — feature_gaps #42 (admin / WhatsApp switchboard, critical).
--
-- THE BUG. On 2026-08-30 two login_otp sends to a real customer number failed
-- with Meta's reason "Business eligibility payment issue" — that customer could
-- not sign in. The WhatsApp Ops account-health card read APPROVED / GREEN /
-- TIER_250 the whole time, because wa_waba_status() reports what META SAYS
-- ABOUT THE ACCOUNT and nothing about what actually happened to our sends. Two
-- different questions, one card, and the card answered the one nobody asked.
--
-- THE FIX. Derive a second health state from the send errors THEMSELVES and
-- print it above the Meta card. The classification is DATA (wa_send_fault_rule)
-- so a new Meta reason tomorrow is one INSERT, not a deploy, and the reason
-- string is carried to the screen VERBATIM — we never re-word Meta.
--
-- Idempotent: create-if-not-exists + on conflict do update + create or replace.

-- ── The rules: reason text -> class, wording, tone, blocking-ness ────────────
create table if not exists public.wa_send_fault_rule (
  key           text primary key,
  match_kind    text        not null default 'ilike',   -- 'ilike' | 'exact'
  match_text    text        not null,
  class_key     text        not null,
  title         text        not null,
  what_it_means text        not null,
  action_label  text        not null,
  tone          text        not null default 'bad',     -- good | warn | bad | muted
  rank          int         not null default 50,        -- higher wins the banner
  is_blocking   boolean     not null default false,     -- account-level stoppage
  enabled       boolean     not null default true,
  updated_at    timestamptz not null default now()
);

alter table public.wa_send_fault_rule enable row level security;
drop policy if exists wa_send_fault_rule_admin_all on public.wa_send_fault_rule;
create policy wa_send_fault_rule_admin_all on public.wa_send_fault_rule
  for all to authenticated
  using (public.get_my_role() = any (array['admin','super_admin']))
  with check (public.get_my_role() = any (array['admin','super_admin']));

insert into public.wa_send_fault_rule
  (key, match_kind, match_text, class_key, title, what_it_means, action_label, tone, rank, is_blocking)
values
  ('billing', 'ilike', '%eligibility payment%', 'billing',
   'WhatsApp sending is blocked by a billing problem on the Meta account',
   'Meta is refusing our sends for payment reasons. Every message on this number is affected, including sign-in codes — a customer hitting this cannot log in at all.',
   'Open Meta Business Manager and clear the payment method on the WhatsApp Business Account', 'bad', 100, true),
  ('account_restricted', 'ilike', '%account has been restricted%', 'billing',
   'The WhatsApp Business Account is restricted by Meta',
   'Meta has restricted the account. Sends are refused until the restriction is lifted.',
   'Open Meta Business Manager and read the account restriction notice', 'bad', 95, true),
  ('rate_limit', 'ilike', '%rate limit%', 'rate',
   'Meta is rate-limiting our sends',
   'We are sending faster than the messaging tier allows. Later messages in a burst are dropped.',
   'Slow the campaign or raise the messaging tier', 'bad', 80, true),
  ('tier_cap', 'ilike', '%limit reached%', 'rate',
   'The daily messaging limit for this tier has been reached',
   'The tier caps how many people we may start a conversation with per day. Anything past the cap is refused until the window rolls over.',
   'Wait for the daily window to roll over or raise the messaging tier', 'bad', 78, true),
  ('reengagement', 'exact', 'Re-engagement message', 'window',
   'Sends outside the 24-hour window need a template',
   'The customer has not messaged us in 24 hours, so a free-form message is not allowed. This is normal WhatsApp policy, not an account fault.',
   'Route this event to an approved template', 'warn', 40, false),
  ('undeliverable', 'exact', 'Message undeliverable', 'undeliverable',
   'Messages are not reaching some numbers',
   'Meta could not deliver to the number — usually no WhatsApp account on it, or a wrong number.',
   'Check the number on the contact ledger', 'warn', 30, false),
  ('missing_media', 'exact', 'missing_header_media', 'content',
   'A template needs a header image we did not supply',
   'The template has a media header and the send carried no image, so Meta rejected it before delivery.',
   'Attach the header media on the template', 'warn', 25, false),
  ('route_disabled', 'exact', 'route_disabled', 'routing',
   'An event is switched off in the switchboard',
   'The event fired but its route is disabled, so nothing was sent. This is our own setting, not Meta.',
   'Enable the route in Event routes above', 'warn', 22, false),
  ('no_route', 'ilike', 'no_event_route_for_%', 'routing',
   'An event has no route at all',
   'The event fired and there is no template mapped to it, so nothing was sent.',
   'Map a template to this event in Event routes above', 'warn', 20, false)
on conflict (key) do update set
  match_kind    = excluded.match_kind,
  match_text    = excluded.match_text,
  class_key     = excluded.class_key,
  title         = excluded.title,
  what_it_means = excluded.what_it_means,
  action_label  = excluded.action_label,
  tone          = excluded.tone,
  rank          = excluded.rank,
  is_blocking   = excluded.is_blocking,
  updated_at    = now();

-- ── Which event keys are auth-critical (a failure here blocks a sign-in) ─────
create table if not exists public.wa_send_event_kind (
  event_key text primary key,
  kind      text    not null,            -- 'auth' | 'order' | 'ops' | 'marketing'
  label     text    not null,
  enabled   boolean not null default true
);

alter table public.wa_send_event_kind enable row level security;
drop policy if exists wa_send_event_kind_admin_all on public.wa_send_event_kind;
create policy wa_send_event_kind_admin_all on public.wa_send_event_kind
  for all to authenticated
  using (public.get_my_role() = any (array['admin','super_admin']))
  with check (public.get_my_role() = any (array['admin','super_admin']));

insert into public.wa_send_event_kind (event_key, kind, label) values
  ('login_otp',         'auth',  'sign-in code'),
  ('user_notify_login', 'auth',  'sign-in notice'),
  ('customer_approved', 'auth',  'approval notice'),
  ('order_placed',      'order', 'order confirmation'),
  ('order_accepted',    'order', 'order update'),
  ('order_rejected',    'order', 'order update'),
  ('order_updated',     'order', 'order update'),
  ('payment_qr',        'order', 'payment request')
on conflict (event_key) do update set
  kind  = excluded.kind,
  label = excluded.label;

create index if not exists wa_send_attempts_fail_idx
  on public.wa_send_attempts (created_at desc) where ok = false;

-- ── The health state, computed from what actually happened ──────────────────
--
-- Two sources, because a send can die in two places: wa_send_attempts records
-- our own refusals AND Meta's, whatsapp_messages carries the status callback
-- Meta sends back later. Dummy supplier numbers (9000000xxx) are excluded, per
-- the register row.
create or replace function public.wa_send_health(p_hours int default 168)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_hours   int := greatest(coalesce(p_hours, 168), 1);
  v_since   timestamptz := now() - make_interval(hours => v_hours);
  v_faults  jsonb;
  v_worst   record;
  v_total   int;
  v_auth    int;
  v_authlbl text;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'show', false);
  end if;

  with raw as (
    select a.reason, a.event_key, a.created_at, a.phone
      from public.wa_send_attempts a
     where a.ok = false
       and a.created_at >= v_since
       and coalesce(a.reason,'') <> ''
       and coalesce(a.phone,'') not like '9000000%'
    union all
    select m.wa_fail_reason, null::text, coalesce(m.wa_status_at, m.received_at), m.sender_phone
      from public.whatsapp_messages m
     where m.direction = 'out'
       and m.wa_status = 'failed'
       and coalesce(m.wa_status_at, m.received_at) >= v_since
       and coalesce(m.wa_fail_reason,'') <> ''
       and coalesce(m.sender_phone,'') not like '9000000%'
  ),
  -- One rule per reason: the highest-ranked ENABLED rule that matches.
  classified as (
    select r.reason, r.event_key, r.created_at,
           ru.key, ru.class_key, ru.title, ru.what_it_means, ru.action_label,
           ru.tone, ru.rank, ru.is_blocking
      from raw r
      left join lateral (
        select f.* from public.wa_send_fault_rule f
         where f.enabled
           and ((f.match_kind = 'exact' and r.reason = f.match_text)
             or (f.match_kind = 'ilike' and r.reason ilike f.match_text))
         order by f.rank desc
         limit 1
      ) ru on true
  ),
  -- Grouped by the VERBATIM Meta reason, never by our paraphrase of it.
  grouped as (
    select coalesce(class_key,'other')  as class_key,
           reason                        as meta_reason,
           coalesce(title, 'WhatsApp refused these sends') as title,
           coalesce(what_it_means, 'This reason has no rule yet — the text above is exactly what Meta returned.') as what_it_means,
           coalesce(action_label, 'Add a rule for this reason in wa_send_fault_rule') as action_label,
           coalesce(tone, 'warn')        as tone,
           coalesce(rank, 10)            as rank,
           coalesce(is_blocking, false)  as is_blocking,
           count(*)::int                 as n,
           max(created_at)               as last_at,
           count(*) filter (
             where event_key in (select event_key from public.wa_send_event_kind
                                  where kind = 'auth' and enabled)
           )::int                        as auth_n
      from classified
     group by 1,2,3,4,5,6,7,8
  )
  select jsonb_agg(jsonb_build_object(
           'class_key',   g.class_key,
           'title',       g.title,
           'meta_reason', g.meta_reason,
           'detail',      g.what_it_means,
           'action_label',g.action_label,
           'tone',        g.tone,
           'is_blocking', g.is_blocking,
           'count',       g.n,
           'count_label', g.n || case when g.n = 1 then ' send refused' else ' sends refused' end,
           'auth_count',  g.auth_n,
           'last_label',  'Last ' || to_char(g.last_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM')
         ) order by g.is_blocking desc, g.rank desc, g.n desc)
    into v_faults
    from grouped g;

  -- v_total counts every refused send in the window; v_auth counts only the
  -- sign-in sends killed by a BLOCKING class, because that is the sentence the
  -- banner prints beside the blocking reason. Counting auth failures from the
  -- non-blocking classes too would put a number in the banner that the reason
  -- above it does not explain.
  select sum(n)::int,
         sum(auth_n) filter (where blocking)::int
    into v_total, v_auth
    from (
      select (f->>'count')::int n,
             (f->>'auth_count')::int auth_n,
             (f->>'is_blocking')::boolean blocking
        from jsonb_array_elements(coalesce(v_faults,'[]'::jsonb)) f
    ) t;

  select (f->>'class_key') class_key, (f->>'title') title, (f->>'meta_reason') meta_reason,
         (f->>'detail') detail, (f->>'action_label') action_label, (f->>'tone') tone,
         (f->>'count')::int n, (f->>'last_label') last_label, (f->>'is_blocking')::boolean is_blocking
    into v_worst
    from jsonb_array_elements(coalesce(v_faults,'[]'::jsonb)) f
   limit 1;

  v_authlbl := case
    when coalesce(v_auth,0) = 0 then ''
    when v_auth = 1 then '1 of them was a sign-in message — that person could not log in'
    else v_auth || ' of them were sign-in messages — those people could not log in'
  end;

  return jsonb_build_object(
    'ok', true,
    'window_hours', v_hours,
    'window_label', case when v_hours % 24 = 0
                         then 'Last ' || (v_hours/24) || case when v_hours = 24 then ' day' else ' days' end
                         else 'Last ' || v_hours || ' hours' end,
    -- The banner shows only when sends are actually being refused at account
    -- level. A handful of undeliverable numbers is not an outage and must not
    -- cry wolf above the Meta card.
    'show',        coalesce(v_worst.is_blocking, false),
    'tone',        coalesce(v_worst.tone, 'good'),
    'title',       coalesce(v_worst.title, 'No account-level send failures'),
    'meta_reason', coalesce(v_worst.meta_reason, ''),
    'detail',      coalesce(v_worst.detail, ''),
    'action_label',coalesce(v_worst.action_label, ''),
    'count_label', case when coalesce(v_worst.n,0) = 0 then ''
                        else v_worst.n || case when v_worst.n = 1 then ' send refused' else ' sends refused' end
                             || ' for this reason' end,
    'last_label',  coalesce(v_worst.last_label, ''),
    'total_failed', coalesce(v_total,0),
    'auth_blocked', coalesce(v_auth,0) > 0,
    'auth_count',   coalesce(v_auth,0),
    'auth_label',   v_authlbl,
    -- The whole point of the row: say out loud that the green card below is
    -- answering a different question.
    'contradiction_label',
      case when coalesce(v_worst.is_blocking,false)
           then 'Meta''s account health below still reads healthy — it reports the account review, not our sends.'
           else '' end,
    'faults', coalesce(v_faults, '[]'::jsonb),
    'note', 'This state is read from our own send log, not from Meta''s account card. Meta can call the account approved while it is refusing every message we send.'
  );
end
$function$;

revoke all on function public.wa_send_health(int) from public;
grant execute on function public.wa_send_health(int) to authenticated, service_role;

-- ── The Ops screen reads ONE payload, so the banner rides wa_waba_status ─────
create or replace function public.wa_waba_status()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare s wa_waba_state%rowtype; v_used int; v_pct numeric;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then return jsonb_build_object('error','not_authorized'); end if;
  select * into s from wa_waba_state where id = 1;
  v_used := coalesce(s.template_count, (select count(*) from wa_templates where meta_id is not null));
  v_pct  := case when coalesce(s.template_limit,250) > 0
                 then round(100.0 * v_used / s.template_limit) end;

  return jsonb_build_object(
    'waba_name', coalesce(s.waba_name,'—'),
    'review_status', coalesce(s.review_status,'—'),
    'templates_label', v_used || ' of ' || coalesce(s.template_limit,250) || ' templates used',
    'templates_used', v_used,
    'templates_limit', coalesce(s.template_limit,250),
    'templates_pct', coalesce(v_pct,0),
    'templates_tone', case when coalesce(v_pct,0) >= 90 then 'bad'
                           when coalesce(v_pct,0) >= 75 then 'warn' else 'good' end,
    'tier_label', case when s.messaging_tier is null then 'Messaging tier unknown'
                       else 'Messaging tier: ' || s.messaging_tier end,
    'quality_label', case when s.phone_quality is null then 'Quality rating unknown'
                          else 'Number quality: ' || s.phone_quality end,
    'quality_tone', case lower(coalesce(s.phone_quality,'')) when 'green' then 'good'
                         when 'yellow' then 'warn' when 'red' then 'bad' else 'muted' end,
    'checked_label', case when s.checked_at is null then 'Never checked'
                          else 'Checked ' || to_char(s.checked_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM') end,
    'error', s.error,
    -- #42: what Meta says about the ACCOUNT and what happens to our SENDS are
    -- two questions. This card answers the first; send_health answers the
    -- second and is painted ABOVE it.
    'send_health', public.wa_send_health(168),
    'note', 'Meta caps a WhatsApp Business Account at 250 templates and limits how many people you can message per day by tier. A cost estimate means nothing if the tier stops you first.');
end $function$;
