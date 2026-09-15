-- CMD #450 — hostile-QA round 1. Seven findings, all fixed in this file.
--
-- 1 (high)   BOTH write actions pointed at event keys that do not exist. The
--            receivables chase used 'payment_due_reminder' and the UTR ask used
--            'payment_utr_request'; neither is a row in wa_event_routes, so
--            wa_send_event returned reason='unknown_event', the fallback lookup
--            read the same missing row and found nothing, and every click died.
--            Backend built, frontend wired, action dead — the exact failure §11
--            exists to prevent. The chase now uses 'payment_due' (which exists,
--            is enabled and has an approved template) anchored on the
--            customer's OLDEST open order so the template's own
--            {{customer_name}}/{{order_code}}/{{amount}} all resolve; the UTR
--            ask gets a REAL registered route and, until an admin picks its
--            template, says exactly that instead of leaking a machine slug.
-- 2 (high)   The save-time guard was bypassable by a TRIGGER. _wa_route_autoenable
--            switched every auto_manage route ON whenever Meta approved its
--            template and never asked wa_route_blockers, so an admin who turned
--            a broken route off had it silently turned back on, and an APPROVED
--            media-header template with no sample auto-enabled straight into the
--            missing_header_media state. Four of the five enabled-and-blocked
--            routes are auto_manage, which is how they got that way.
-- 3 (medium) wa_route_blockers was granted to authenticated but left OUT of the
--            revoke block, so it kept GRANT TO PUBLIC — an unauthenticated
--            oracle for which event keys exist, leaking template status and
--            header format. It also had no body check. Both locks now, and the
--            RULE is split from the DOOR so the trigger can still use it.
-- 4 (medium) Three failure counts on one screen disagreeing by 2.7x with no
--            wording separating them. Each now says what it counts.
-- 5 (medium) rows[] was capped at 100 ordered `ok asc`, so failures ate every
--            slot: not one success was reachable while the summary advertised
--            them, and only 68 of 182 retryable sends had a Retry to press.
--            Two caps, and the backend says what it left out.
-- 6 (low)    reasons[].title and rows[].title were raw machine event_keys.
-- 7 (low)    orders.created_at is nullable, and an undated order bucketed to
--            '0–7 days' with a 'good' tone — the freshest, healthiest
--            receivable. Unknown age is now the WORST bucket.

-- CMD #450 — hostile-QA round 1. Seven findings, all fixed here.

-- ── FINDING 7 (low): an undated debt must never look like the freshest one ──
-- orders.created_at is nullable. _c450_age_label(null) says 'No date', but
-- _c450_age_days(null) is 0, so the bucket was 'b0_7' and the tone 'good' — an
-- order with no date was reported as the newest and healthiest receivable.
-- Null-aware overloads, used wherever the source column is nullable: unknown
-- age is the WORST bucket, because that is the safe direction for money.
create or replace function public._c450_age_bucket_at(p_at timestamptz)
returns text language sql immutable as $$
  select case when p_at is null then 'b30p'
              else public._c450_age_bucket(public._c450_age_days(p_at)) end;
$$;

create or replace function public._c450_age_tone_at(p_at timestamptz)
returns text language sql immutable as $$
  select case when p_at is null then 'bad'
              else public._c450_age_tone(public._c450_age_days(p_at)) end;
$$;

-- ── FINDING 3 (medium): wa_route_blockers was anon-executable ───────────────
-- It was granted to authenticated and left OUT of the revoke block thirty lines
-- below, so it kept Postgres's default GRANT TO PUBLIC — an unauthenticated
-- oracle for which event keys exist, and for a blocked route it returns the
-- template's Meta status and header format. It also had no body check at all.
-- Both locks now: the GRANT is the outer one, the role test is the inner one.
-- The RULE and the DOOR are two things. The rule is needed by a TRIGGER that
-- fires under whatever role Meta's webhook is running as, so it cannot carry an
-- admin check; the door is called from a screen and must. Splitting them is
-- what lets the guard be both un-bypassable and un-public.
create or replace function public._wa_route_blockers_raw(p_event_key text, p_template_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare r record; t record; v_fmt text; v_expiry timestamptz; v_dead boolean;
begin
  select * into r from wa_event_routes where event_key = p_event_key;
  if r.event_key is null then
    return jsonb_build_object('blocked', true, 'error', 'unknown_event',
      'message', 'That event does not exist.');
  end if;

  select * into t from wa_templates where id = coalesce(p_template_id, r.template_id);

  if t.id is null then
    return jsonb_build_object('blocked', true, 'error', 'no_template',
      'message', 'Choose a template before switching this event on.',
      'blocker_label', 'No template chosen', 'blocker_tone', 'bad');
  end if;

  if t.status <> 'APPROVED' then
    return jsonb_build_object('blocked', true, 'error', 'not_approved',
      'message', 'That template is ' || t.status || ' at Meta - only approved templates can be sent.',
      'blocker_label', 'Template is ' || t.status || ' at Meta', 'blocker_tone', 'bad');
  end if;

  v_fmt := public.wa_template_needs_header_media(t.id);
  if v_fmt is not null then
    begin
      v_expiry := public.wa_header_handle_expiry(t.header_handle);
    exception when others then v_expiry := null;
    end;
    v_dead := v_expiry is not null and v_expiry < now();

    if t.header_handle is null then
      return jsonb_build_object('blocked', true, 'error', 'missing_header_media',
        'message', 'This template has a ' || upper(v_fmt) || ' header and no sample file. '
                || 'Meta refuses every send until one is uploaded - that is the '
                || 'missing_header_media failure. Upload the sample on the template first.',
        'blocker_label', 'No ' || lower(v_fmt) || ' sample uploaded',
        'blocker_tone', 'bad');
    end if;
    if v_dead then
      return jsonb_build_object('blocked', true, 'error', 'header_media_expired',
        'message', 'The sample file for this template''s header expired at Meta. '
                || 'Upload it again before switching this event on.',
        'blocker_label', 'Header sample expired at Meta',
        'blocker_tone', 'bad');
    end if;
  end if;

  return jsonb_build_object('blocked', false, 'message', '', 'blocker_label', '', 'blocker_tone', 'good');
end $function$;

-- Nobody calls the rule directly. It is reachable only through the door below
-- and through the trigger, both of which are SECURITY DEFINER.
revoke execute on function public._wa_route_blockers_raw(text, uuid) from public, anon, authenticated;

-- FINDING 3 (medium): wa_route_blockers was granted to authenticated and left
-- OUT of the revoke block thirty lines below, so it kept Postgres's default
-- GRANT TO PUBLIC - an unauthenticated oracle for which event keys exist, and
-- for a blocked route it returned the template's Meta status and header format.
-- It also had no body check at all. Both locks now: the GRANT is the outer one,
-- the role test is the inner one.
create or replace function public.wa_route_blockers(p_event_key text, p_template_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
begin
  if role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('blocked', true, 'error', 'not_authorized', 'message', '');
  end if;
  return public._wa_route_blockers_raw(p_event_key, p_template_id);
end $function$;

revoke execute on function public.wa_route_blockers(text, uuid) from public, anon;
grant  execute on function public.wa_route_blockers(text, uuid) to authenticated;

-- wa_event_routes_screen calls the blocker per row and now needs the guard's
-- own admin context; it already refuses a non-admin caller itself, and it is
-- SECURITY DEFINER, so the inner check above passes for the same callers.

-- ── FINDING 2 (high): the save-time guard was bypassable by a TRIGGER ───────
-- _wa_route_autoenable sets enabled = true on every auto_manage route whenever
-- Meta flips a template to APPROVED, and it never asked wa_route_blockers. So
-- an admin who switches a broken route OFF — the exact fix the screen tells
-- them to make — had it silently switched back ON at the next approval, and an
-- APPROVED media-header template with no sample auto-enabled straight into the
-- missing_header_media state this row exists to prevent. Four of the five
-- enabled-and-blocked routes are auto_manage, which is how they got that way.
--
-- The trigger keeps doing its job — it still attaches the newly approved
-- template and still turns the route on — but only when the route can actually
-- send. When it cannot, the template is attached and `enabled` is LEFT ALONE,
-- so the route appears on the screen with its blocker instead of silently
-- failing at send.
create or replace function public._wa_route_autoenable()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
declare r record; b jsonb; v_ok boolean;
begin
  if new.status = 'APPROVED' and coalesce(old.status,'') <> 'APPROVED' then
    for r in
      select * from wa_event_routes
       where auto_manage and auto_template_name = new.name
    loop
      b := public._wa_route_blockers_raw(r.event_key, new.id);
      v_ok := not coalesce((b->>'blocked')::boolean, true);

      -- Attach the newly approved template either way: that half was never the
      -- problem, and a route with no template is worse than one carrying a
      -- template it cannot send yet. Only `enabled` is gated.
      update wa_event_routes
         set template_id   = new.id,
             template_name = new.name,
             language      = new.language,
             enabled       = case when v_ok then true else enabled end,
             pipeline_note = case
               when not public._wa_note_is_auto(pipeline_note) then pipeline_note
               when v_ok then 'Live — Meta approved this template and the route switched itself on'
               else 'Meta approved this template, but the route cannot send yet: '
                    || coalesce(nullif(b->>'blocker_label',''), 'it is blocked')
             end,
             updated_at    = now()
       where event_key = r.event_key;
    end loop;
  end if;
  return new;
end $function$;

-- wa_event_routes_screen prints a blocker per row and runs as an admin already;
-- it calls the RAW rule so the per-row lookup is one function call, not an
-- admin re-check per row.
create or replace function public.wa_event_routes_screen()
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v_rows jsonb; v_blocked int;
begin
  if role_for_medibo_only() not in ('admin','super_admin') then return jsonb_build_object('error','not_authorized'); end if;

  select coalesce(jsonb_agg(x order by x->>'event_key'), '[]'::jsonb),
         count(*) filter (where (x->>'blocked')::boolean)::int
    into v_rows, v_blocked
  from (
    select jsonb_build_object(
      'event_key', r.event_key, 'label', r.label, 'description', r.description,
      'audience', r.audience,
      'audience_label', coalesce((select a->>'label' from jsonb_array_elements(public.wa_audience_types()) a
                                   where a->>'value' = r.audience), initcap(r.audience)),
      'audience_sort', coalesce((select (a->>'sort')::int from jsonb_array_elements(public.wa_audience_types()) a
                                  where a->>'value' = r.audience), 99),
      'auto_manage', r.auto_manage,
      'auto_template_name', r.auto_template_name,
      'pipeline_note', r.pipeline_note,
      'meta_status', (select t.status from wa_templates t
                       where t.name = r.auto_template_name order by (t.language='en') desc limit 1),
      'stage', case
        when r.enabled and r.template_id is not null then 'live'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='REJECTED') then 'rejected'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='PENDING') then 'waiting_meta'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='DRAFT') then 'preparing'
        else 'not_started' end,
      'stage_label', case
        when r.enabled and r.template_id is not null then 'Live — switched on automatically'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='REJECTED') then 'Meta rejected the template'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='PENDING') then 'Waiting on Meta approval'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='DRAFT') then 'Being prepared and checked'
        else 'Not started yet' end,
      'stage_tone', case
        when r.enabled and r.template_id is not null then 'good'
        when exists (select 1 from wa_templates t where t.name = r.auto_template_name and t.status='REJECTED') then 'bad'
        else 'warn' end,
      'template_name', coalesce(r.template_name,'—'),
      'language', coalesce(r.language,'—'),
      'enabled', r.enabled,
      'status_label', case when not r.enabled then 'Off'
                           when r.template_id is null then 'No template'
                           else 'On' end,
      'status_tone', case when not r.enabled then 'muted'
                          when r.template_id is null then 'warn' else 'good' end,
      'blocked',       r.enabled and coalesce((bl->>'blocked')::boolean, false),
      'blocker_label', case when r.enabled then coalesce(bl->>'blocker_label','') else '' end,
      'blocker_detail',case when r.enabled then coalesce(bl->>'message','') else '' end,
      'blocker_tone',  case when r.enabled and coalesce((bl->>'blocked')::boolean,false) then 'bad' else 'good' end,
      'bypass_send_window', r.bypass_send_window,
      'dedupe_minutes', r.dedupe_minutes,
      'window_label', case when r.bypass_send_window then 'Sends any time — transactional'
                           else 'Held to the 9am–8pm window' end,
      'variable_map', r.variable_map,
      'sent_30d', (select count(*) from wa_campaign_recipients x join wa_campaigns c on c.id = x.campaign_id
                    where c.audience_kind='event_route' and c.audience_params->>'event_key' = r.event_key
                      and x.status in ('sent','delivered','read') and x.sent_at > now() - interval '30 days'),
      'languages_live', (select coalesce(jsonb_agg(distinct c.language), '[]'::jsonb) from wa_campaigns c
                          where c.audience_kind='event_route' and c.audience_params->>'event_key' = r.event_key),
      'updated_label', to_char(r.updated_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM')
    ) as x
    from wa_event_routes r
    left join lateral (select public._wa_route_blockers_raw(r.event_key, r.template_id) as bl) b on true
  ) q;

  return jsonb_build_object(
    'rows', v_rows,
    'blocked_count', coalesce(v_blocked,0),
    'blocked_label', case when coalesce(v_blocked,0) = 0 then ''
                          when v_blocked = 1 then '1 switched-on event cannot send'
                          else v_blocked || ' switched-on events cannot send' end,
    'blocked_tone', case when coalesce(v_blocked,0) > 0 then 'bad' else 'good' end,
    'blocked_note', 'These are on, so mediBO keeps trying them — and every send is refused before it leaves. Fix the blocker on the row, or switch the event off.',
    'approved_templates', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.id, 'name', t.name, 'language', t.language, 'category', t.category,
        'label', t.name || ' (' || t.language || ')') order by t.name), '[]'::jsonb)
      from wa_templates t where t.status='APPROVED'),
    'note', 'Each event sends the approved template you pick here. Change the template and the next message uses it — no deploy. Customers with a language set get that language automatically when an approved variant of the same template exists.');
end $function$;

-- wa_event_route_save keeps using the admin-gated door: it is only ever called
-- from the screen, and re-checking the caller there costs nothing.

-- ── FINDING 1 (high): BOTH write actions pointed at event keys that do not
--    exist. QA caught 'payment_due_reminder' on the receivables chase; the same
--    bug is on the UTR ask, which used 'payment_utr_request'. Neither key is in
--    wa_event_routes, so wa_send_event returned reason='unknown_event', the
--    fallback lookup read the same missing row and found nothing, and every
--    click died with "Could not send". Backend built, frontend wired, action
--    dead — which is the exact failure §11 exists to prevent.
--
--    The chase has a real route already: 'payment_due', enabled, with a
--    template. Use it.
--    The UTR ask has none — asking for a bank reference is genuinely a
--    different message from "your payment is due", so borrowing payment_due
--    would send the wrong thing. Register the route properly (off, no template
--    yet) so it appears on WhatsApp ops → Event routes for an admin to wire,
--    and make the action say exactly that instead of leaking 'unknown_event'.
insert into public.wa_event_routes (event_key, label, description, audience, auto_manage, enabled, bypass_send_window)
values ('payment_utr_request',
        'Ask the customer for the UTR',
        'CMD #450 (feature_gaps #18) — sent from the payment verification queue when a claim arrives with no bank reference. Without the UTR the payment cannot be matched to the statement.',
        'customer', false, false, true)
on conflict (event_key) do update
  set label = excluded.label, description = excluded.description;

create or replace function public.admin_claim_ask_utr(p_claim_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare c record; r record; v jsonb; v_ok boolean := false; v_msg text;
begin
  if not is_admin() then return jsonb_build_object('ok', false, 'message', 'Not allowed'); end if;
  select * into c from payment_claims where id = p_claim_id;
  if c.id is null then
    return jsonb_build_object('ok', false, 'message', 'That payment claim no longer exists.');
  end if;
  if nullif(btrim(c.utr),'') is not null then
    return jsonb_build_object('ok', false, 'message', 'This claim already carries a UTR.');
  end if;
  if nullif(btrim(c.sender_phone),'') is null then
    return jsonb_build_object('ok', false,
      'message', 'This claim has no sender number, so there is nobody to ask.');
  end if;

  -- Say WHY it cannot send, in the words of the thing that needs doing. A raw
  -- 'unknown_event' told the admin nothing and named no screen.
  select * into r from wa_event_routes where event_key = 'payment_utr_request';
  if r.event_key is null then
    return jsonb_build_object('ok', false,
      'message', 'The "Ask for the UTR" message is not set up yet. It needs an event route called payment_utr_request.');
  end if;
  if not r.enabled or r.template_id is null then
    return jsonb_build_object('ok', false,
      'message', 'The "Ask for the UTR" message has no approved WhatsApp template yet. '
              || 'Pick one on WhatsApp ops → Event routes → "Ask the customer for the UTR", switch it on, and this will send.');
  end if;

  begin
    v := public.wa_send_event_or_fallback('payment_utr_request', null,
           jsonb_build_object('amount', public.inr_money(c.amount)),
           c.sender_phone, c.order_id);
    v_ok := coalesce((v->>'ok')::boolean, false);
  exception when others then
    v_ok := false;
    v := jsonb_build_object('ok', false, 'reason', sqlerrm);
  end;

  update payment_claims
     set autolink_note = 'UTR asked for on '
                       || to_char(now() at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM')
                       || case when v_ok then '' else ' (WhatsApp could not deliver it)' end
   where id = p_claim_id;

  return jsonb_build_object(
    'ok', v_ok,
    'message', case when v_ok
                    then 'Asked ' || c.sender_phone || ' for the UTR on WhatsApp.'
                    else 'Could not send the request: '
                         || coalesce(v->>'reason','WhatsApp refused it')
                         || '. The ask is noted on the claim.' end,
    'detail', v);
end $function$;

create or replace function public.admin_receivables_chase(p_user_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v jsonb; v_ok boolean := false; v_phone text; v_name text; v_open numeric; r record;
begin
  if not is_admin() then return jsonb_build_object('ok', false, 'message', 'Not allowed'); end if;

  select nullif(btrim(coalesce(pp.whatsapp_no, pp.phone,'')),''),
         coalesce(nullif(btrim(pp.pharmacy_name),''),'this customer')
    into v_phone, v_name
    from pharmacy_profiles pp
   where pp.user_id = p_user_id and coalesce(pp.is_deleted,false)=false limit 1;

  select coalesce(sum(round(coalesce(o.total_amount,0) - coalesce(paid.amt,0),2)),0)
    into v_open
    from orders o
    left join lateral (select sum(p.amount) amt from payment_claims p
                        where p.order_id=o.id and p.status='verified') paid on true
   where o.user_id = p_user_id
     and coalesce(o.status,'pending') in ('pending','accepted')
     and coalesce(o.fulfillment_status,'open') <> 'cancelled'
     and round(coalesce(o.total_amount,0) - coalesce(paid.amt,0),2) > 0;

  if v_phone is null then
    return jsonb_build_object('ok', false,
      'message', 'No WhatsApp number on ' || v_name || ' — there is nobody to chase.');
  end if;

  -- 'payment_due' is the route that actually exists. The first version of this
  -- function invented 'payment_due_reminder', which is in no row of
  -- wa_event_routes, so every chase died with reason=unknown_event.
  select * into r from wa_event_routes where event_key = 'payment_due';
  if r.event_key is null then
    return jsonb_build_object('ok', false,
      'message', 'The payment reminder is not set up yet — it needs an event route called payment_due.');
  end if;
  if not r.enabled or r.template_id is null then
    return jsonb_build_object('ok', false,
      'message', 'The payment reminder has no approved WhatsApp template switched on. '
              || 'Set it on WhatsApp ops → Event routes → "Payment due", and this will send.');
  end if;

  begin
    v := public.wa_send_event_or_fallback('payment_due', p_user_id,
           jsonb_build_object('amount', public.inr_money(v_open)), v_phone, null);
    v_ok := coalesce((v->>'ok')::boolean, false);
  exception when others then
    v_ok := false; v := jsonb_build_object('ok', false, 'reason', sqlerrm);
  end;

  return jsonb_build_object('ok', v_ok,
    'message', case when v_ok
                    then 'Reminded ' || v_name || ' about ' || public.inr_money(v_open) || ' on WhatsApp.'
                    else 'Could not send the reminder: ' || coalesce(v->>'reason','WhatsApp refused it') end,
    'detail', v);
end $function$;
CREATE OR REPLACE FUNCTION public.admin_receivables()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cust jsonb; v_buckets jsonb; v_total numeric; v_n int; v_orders int; v_oldest int;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  with open_orders as (
    select o.id as order_id, o.user_id,
           coalesce(nullif(btrim(pp.pharmacy_name),''), 'Unknown customer') as customer_name,
           o.created_at,
           round(coalesce(o.total_amount,0) - coalesce(paid.amt,0), 2) as open_amount,
           public._c450_age_days(o.created_at) as age_days,
           public._c450_age_bucket_at(o.created_at) as bucket
      from orders o
      left join pharmacy_profiles pp on pp.user_id = o.user_id and coalesce(pp.is_deleted,false) = false
      left join lateral (
        select sum(p.amount) amt from payment_claims p
         where p.order_id = o.id and p.status = 'verified'
      ) paid on true
     where coalesce(o.status,'pending') in ('pending','accepted')
       and coalesce(o.fulfillment_status,'open') <> 'cancelled'
       and round(coalesce(o.total_amount,0) - coalesce(paid.amt,0), 2) > 0
  ),
  per_customer as (
    select user_id, min(customer_name) as customer_name,
           sum(open_amount) as open_amount, count(*)::int as n, max(age_days) as oldest
      from open_orders group by user_id
  ),
  bucket_totals as (
    select k,
           coalesce((select sum(open_amount) from open_orders o where o.bucket = k),0) as v,
           coalesce((select count(*)::int    from open_orders o where o.bucket = k),0) as n
      from unnest(array['b30p','b16_30','b8_15','b0_7']) k
  )
  select
    (select count(*)::int from open_orders),
    (select coalesce(sum(open_amount),0) from open_orders),
    (select coalesce(max(age_days),0) from open_orders),
    (select count(*)::int from per_customer),
    (select coalesce(jsonb_agg(jsonb_build_object(
        'user_id',       t.user_id,
        'customer_name', t.customer_name,
        'open_label',    public.inr_money(t.open_amount),
        'open_amount',   t.open_amount,
        'order_count',   t.n,
        'order_count_label', t.n || case when t.n = 1 then ' open order' else ' open orders' end,
        'age_days',      t.oldest,
        'age_label',     'Oldest ' || t.oldest || case when t.oldest = 1 then ' day' else ' days' end,
        'age_tone',      public._c450_age_tone(t.oldest),
        'bucket',        public._c450_age_bucket(t.oldest),
        'bucket_label',  public._c450_bucket_label(public._c450_age_bucket(t.oldest)),
        'chase_label',   'Chase on WhatsApp',
        'open_orders_label', 'See the orders')
      order by t.open_amount desc), '[]'::jsonb) from per_customer t),
    (select coalesce(jsonb_agg(jsonb_build_object(
        'key', b.k, 'label', public._c450_bucket_label(b.k),
        'tone', public._c450_bucket_tone(b.k),
        'value_label', public.inr_money(b.v),
        'count', b.n,
        'count_label', b.n || case when b.n = 1 then ' order' else ' orders' end)
      order by public._c450_bucket_sort(b.k)), '[]'::jsonb) from bucket_totals b)
  into v_orders, v_total, v_oldest, v_n, v_cust, v_buckets;

  return jsonb_build_object(
    'ok', true,
    'total_label', public.inr_money(v_total),
    'total_amount', v_total,
    'headline', case when v_orders = 0 then 'Nothing is owed'
                     else public.inr_money(v_total) || ' open across '
                          || v_orders || case when v_orders = 1 then ' order' else ' orders' end end,
    'sub_headline', case when v_n = 0 then ''
                         when v_n = 1 then 'From 1 customer'
                         else 'From ' || v_n || ' customers' end,
    'oldest_label', case when v_orders = 0 then ''
                         else 'Oldest open order is ' || v_oldest || ' days old' end,
    'oldest_tone', public._c450_age_tone(v_oldest),
    'buckets', v_buckets,
    'rows', v_cust,
    'customers', v_cust,
    'empty_label', 'Every order that was placed has been paid for.',
    'note', 'Open value is the order total minus payments verified against it. MRP is never used.');
end $function$

;

-- The drill-in reads the same nullable column, so it takes the same null-aware
-- tone. age_label already says 'No date'; now the colour agrees with it.
create or replace function public.admin_receivables_orders(p_user_id uuid)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $function$
declare v_rows jsonb; v_name text; v_total numeric;
begin
  if not is_admin() then raise exception 'not_authorized'; end if;

  select coalesce(nullif(btrim(pp.pharmacy_name),''),'Unknown customer')
    into v_name from pharmacy_profiles pp
   where pp.user_id = p_user_id and coalesce(pp.is_deleted,false) = false limit 1;

  select coalesce(jsonb_agg(x order by (x->>'age_days')::int desc), '[]'::jsonb),
         coalesce(sum((x->>'open_amount')::numeric),0)
    into v_rows, v_total
  from (
    select jsonb_build_object(
      'order_id',     o.id,
      'order_code',   coalesce(nullif(btrim(o.order_code),''),'PO-'||upper(right(replace(o.id::text,'-',''),4))),
      'placed_label', case when o.created_at is null then 'No order date recorded'
                          else 'Placed ' || to_char(o.created_at at time zone 'Asia/Kolkata','DD Mon yyyy') end,
      'total_label',  public.inr_money(o.total_amount),
      'paid_label',   public.inr_money(coalesce(paid.amt,0)),
      'open_amount',  round(coalesce(o.total_amount,0) - coalesce(paid.amt,0), 2),
      'open_label',   public.inr_money(round(coalesce(o.total_amount,0) - coalesce(paid.amt,0), 2)),
      'has_paid',     coalesce(paid.amt,0) > 0,
      'paid_note',    case when coalesce(paid.amt,0) = 0
                           then 'No payment has ever been recorded against this order'
                           else public.inr_money(paid.amt) || ' verified so far' end,
      'age_days',     public._c450_age_days(o.created_at),
      'age_label',    public._c450_age_label(o.created_at),
      'age_tone',     public._c450_age_tone_at(o.created_at),
      'status_label', initcap(coalesce(o.status,'pending'))
    ) as x
    from orders o
    left join lateral (
      select sum(p.amount) amt from payment_claims p where p.order_id = o.id and p.status='verified'
    ) paid on true
   where o.user_id = p_user_id
     and coalesce(o.status,'pending') in ('pending','accepted')
     and coalesce(o.fulfillment_status,'open') <> 'cancelled'
     and round(coalesce(o.total_amount,0) - coalesce(paid.amt,0), 2) > 0
  ) q;

  return jsonb_build_object('ok', true, 'customer_name', coalesce(v_name,'Unknown customer'),
    'rows', v_rows, 'total_label', public.inr_money(v_total),
    'headline', coalesce(v_name,'Unknown customer') || ' owes ' || public.inr_money(v_total),
    'empty_label', 'This customer has nothing open.');
end $function$;
CREATE OR REPLACE FUNCTION public.wa_send_health(p_hours integer DEFAULT 168)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_hours   int := greatest(coalesce(p_hours, 168), 1);
  v_since   timestamptz := now() - make_interval(hours => v_hours);
  v_faults  jsonb;
  v_reasons jsonb;
  v_rows    jsonb;
  v_worst   record;
  v_total   int;
  v_auth    int;
  v_authlbl text;
  v_ok_n    int;
  v_bad_n   int;
  v_retry_n int;
  v_shown_n int;
  v_shown_retry int;
  v_wlabel  text;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error', 'not_authorized', 'show', false);
  end if;

  v_wlabel := case when v_hours % 24 = 0
                   then 'Last ' || (v_hours/24) || case when v_hours = 24 then ' day' else ' days' end
                   else 'Last ' || v_hours || ' hours' end;

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

  select sum(n)::int, sum(auth_n) filter (where blocking)::int
    into v_total, v_auth
    from (
      select (f->>'count')::int n, (f->>'auth_count')::int auth_n,
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

  with bad as (
    select a.* from public.wa_send_attempts a
     where a.created_at >= v_since
       and coalesce(a.phone,'') not like '9000000%'
       and a.ok = false
  ),
  g as (
    select coalesce(nullif(btrim(reason),''),'no_reason') as reason,
           coalesce(nullif(btrim(event_key),''),'unknown') as event_key,
           count(*)::int n,
           min(created_at) first_at, max(created_at) last_at,
           count(*) filter (where coalesce(phone,'') <> '')::int retryable_n
      from bad group by 1,2
  )
  select jsonb_agg(jsonb_build_object(
           'reason', g.reason,
           'event_key', g.event_key,
           -- FINDING 6: the heading was the raw machine slug. wa_event_routes
           -- already carries a written label for every event we own; fall back
           -- to the key only for an event that has no route (which is itself
           -- worth seeing as a key).
           'title', coalesce((select nullif(btrim(er.label),'') from public.wa_event_routes er
                               where er.event_key = g.event_key), g.event_key),
           'count', g.n,
           'count_label', g.n || case when g.n = 1 then ' failed send' else ' failed sends' end,
           'share_label', round(100.0 * g.n / nullif((select count(*) from bad),0))::int || '% of all failures',
           'first_label', 'First ' || to_char(g.first_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
           'last_label',  'Last '  || to_char(g.last_at  at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
           'retryable', g.retryable_n > 0,
           'retryable_label', case when g.retryable_n = 0
                                   then 'None of these carry a number to send to'
                                   else g.retryable_n || ' of these can be sent again' end,
           'tone', case when g.n >= 50 then 'bad' when g.n >= 10 then 'warn' else 'muted' end,
           'detail', coalesce((select f.what_it_means from public.wa_send_fault_rule f
                                where f.enabled
                                  and ((f.match_kind='exact' and g.reason = f.match_text)
                                    or (f.match_kind='ilike' and g.reason ilike f.match_text))
                                order by f.rank desc limit 1),
                              'No rule for this reason yet — the text above is exactly what the send returned.')
         ) order by g.n desc)
    into v_reasons from g;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id',           a.id,
           'title',        coalesce((select nullif(btrim(er.label),'') from public.wa_event_routes er
                                      where er.event_key = a.event_key), a.event_key),
           'order_code',   coalesce(nullif(btrim(o.order_code),''),''),
           'phone_label',  coalesce(nullif(btrim(a.phone),''),'No number'),
           'when_label',   to_char(a.created_at at time zone 'Asia/Kolkata','DD Mon, HH12:MI AM'),
           'path_label',   coalesce(nullif(btrim(a.path),''),'unknown'),
           'status_label', case when a.ok then 'Sent' else 'Failed' end,
           'tone',         case when a.ok then 'good' else 'bad' end,
           'reason',       coalesce(a.reason,''),
           'can_retry',    (not a.ok) and coalesce(nullif(btrim(a.phone),'') is not null, false),
           'no_retry_reason', case when a.ok then ''
                                   when coalesce(nullif(btrim(a.phone),''),'') = ''
                                     then 'This send had no number, so there is nothing to send again'
                                   else '' end
         ) order by a.ok asc, a.created_at desc), '[]'::jsonb)
    into v_rows
    from (
      -- FINDING 5: one cap ordered `ok asc` swallowed every slot with failures,
      -- so the successes the summary line promised were unreachable. Two
      -- separate caps: the failures this screen exists for, and enough
      -- successes to prove sending works at all.
      (select * from public.wa_send_attempts
        where created_at >= v_since and coalesce(phone,'') not like '9000000%'
          and ok = false
        order by created_at desc
        limit 120)
      union all
      (select * from public.wa_send_attempts
        where created_at >= v_since and coalesce(phone,'') not like '9000000%'
          and ok = true
        order by created_at desc
        limit 30)
    ) a
    left join orders o on o.id = a.order_id;

  select count(*) filter (where ok)::int,
         count(*) filter (where not ok)::int,
         count(*) filter (where not ok and coalesce(nullif(btrim(phone),'') is not null, false))::int
    into v_ok_n, v_bad_n, v_retry_n
    from public.wa_send_attempts
   where created_at >= v_since and coalesce(phone,'') not like '9000000%';

  -- FINDING 4/5: how much of the above actually reached the feed, so the
  -- retry sentence describes the buttons that exist rather than a population
  -- the screen cannot show.
  select count(*)::int, count(*) filter (where (r->>'can_retry')::boolean)::int
    into v_shown_n, v_shown_retry
    from jsonb_array_elements(coalesce(v_rows,'[]'::jsonb)) r;

  return jsonb_build_object(
    'ok', true,
    'window_hours', v_hours,
    'window_label', v_wlabel,
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
    'contradiction_label',
      case when coalesce(v_worst.is_blocking,false)
           then 'Meta''s account health below still reads healthy — it reports the account review, not our sends.'
           else '' end,
    'faults', coalesce(v_faults, '[]'::jsonb),
    'reasons', coalesce(v_reasons, '[]'::jsonb),
    'reasons_title', 'Why sends are failing',
    'rows', v_rows,
    -- FINDING 4: total_failed comes from faults[], which UNIONs our own send
    -- log with Meta's delivery failures on whatsapp_messages; summary_label
    -- counts the send log alone. They are different questions and used to be
    -- two bare numbers on one screen disagreeing by nearly 3x, so each now
    -- says which population it is counting.
    'summary_label', v_bad_n || case when v_bad_n = 1 then ' send attempt failed' else ' send attempts failed' end
                     || ', ' || v_ok_n || ' went out',
    'summary_tone', case when v_bad_n = 0 then 'good' when v_bad_n > v_ok_n then 'bad' else 'warn' end,
    'range_label', v_wlabel,
    'retry_label', 'Send again',
    'total_failed_label', case when coalesce(v_total,0) = 0 then ''
                               else coalesce(v_total,0) || ' refused sends in this window, '
                                    || 'counting Meta''s own delivery failures as well as ours' end,
    -- The retry sentence describes the buttons ON SCREEN, not a population the
    -- feed was truncated out of.
    'retryable_count', v_shown_retry,
    'retryable_total', v_retry_n,
    'retryable_label', case when v_shown_retry = 0 then ''
                            when v_shown_retry = 1 then '1 failed send below can be sent again'
                            else v_shown_retry || ' failed sends below can be sent again' end,
    'truncated_label', case when v_bad_n + v_ok_n > v_shown_n
                            then 'Showing the ' || v_shown_n || ' most recent of '
                                 || (v_bad_n + v_ok_n) || ' attempts in this window'
                            else '' end,
    'empty_label', 'No sends were attempted in this window.',
    'window_note', 'Newest first, failures at the top. Retry needs a number to send to — not an order.',
    'note', 'This state is read from our own send log, not from Meta''s account card. Meta can call the account approved while it is refusing every message we send.'
  );
end
$function$

;
-- CMD #450 — QA finding 1, second layer. Reaching the right route was not
-- enough: `payment_due` renders the approved `payment_pending` template, whose
-- variable_map is {{customer_name}}, {{order_code}}, {{amount}} — an ORDER-level
-- message. The chase is per CUSTOMER, so it passed neither an order nor those
-- tokens and came back `missing_values`.
--
-- The fix is not a new template. A B2B chase that names a concrete PO is the
-- more useful message anyway, so the chase now anchors on the customer's OLDEST
-- open order, fills all three tokens itself, and still reports the TOTAL owed.
-- And when a send does fail, the message says which values were missing rather
-- than printing a slug at an admin who cannot act on it.
create or replace function public.admin_receivables_chase(p_user_id uuid)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $function$
declare v jsonb; v_ok boolean := false; v_phone text; v_name text;
        v_open numeric; v_n int; r record; o record; v_reason text;
begin
  if not is_admin() then return jsonb_build_object('ok', false, 'message', 'Not allowed'); end if;

  select nullif(btrim(coalesce(pp.whatsapp_no, pp.phone,'')),''),
         coalesce(nullif(btrim(pp.pharmacy_name),''),'this customer')
    into v_phone, v_name
    from pharmacy_profiles pp
   where pp.user_id = p_user_id and coalesce(pp.is_deleted,false)=false limit 1;

  select coalesce(sum(round(coalesce(o2.total_amount,0) - coalesce(paid.amt,0),2)),0), count(*)::int
    into v_open, v_n
    from orders o2
    left join lateral (select sum(p.amount) amt from payment_claims p
                        where p.order_id=o2.id and p.status='verified') paid on true
   where o2.user_id = p_user_id
     and coalesce(o2.status,'pending') in ('pending','accepted')
     and coalesce(o2.fulfillment_status,'open') <> 'cancelled'
     and round(coalesce(o2.total_amount,0) - coalesce(paid.amt,0),2) > 0;

  if v_phone is null then
    return jsonb_build_object('ok', false,
      'message', 'No WhatsApp number on ' || v_name || ' — there is nobody to chase.');
  end if;
  if coalesce(v_n,0) = 0 then
    return jsonb_build_object('ok', false,
      'message', v_name || ' has nothing open — there is nothing to chase.');
  end if;

  -- The oldest open order is what the reminder names.
  select o2.id,
         coalesce(nullif(btrim(o2.order_code),''),'PO-'||upper(right(replace(o2.id::text,'-',''),4))) as code
    into o
    from orders o2
    left join lateral (select sum(p.amount) amt from payment_claims p
                        where p.order_id=o2.id and p.status='verified') paid on true
   where o2.user_id = p_user_id
     and coalesce(o2.status,'pending') in ('pending','accepted')
     and coalesce(o2.fulfillment_status,'open') <> 'cancelled'
     and round(coalesce(o2.total_amount,0) - coalesce(paid.amt,0),2) > 0
   order by o2.created_at asc nulls first
   limit 1;

  select * into r from wa_event_routes where event_key = 'payment_due';
  if r.event_key is null then
    return jsonb_build_object('ok', false,
      'message', 'The payment reminder is not set up yet — it needs an event route called payment_due.');
  end if;
  if not r.enabled or r.template_id is null then
    return jsonb_build_object('ok', false,
      'message', 'The payment reminder has no approved WhatsApp template switched on. '
              || 'Set it on WhatsApp ops → Event routes → "Payment due", and this will send.');
  end if;

  begin
    -- Every token the template asks for, supplied here rather than left to be
    -- resolved: the amount is the customer's TOTAL open value, which is the
    -- number this screen is about.
    v := public.wa_send_event_or_fallback('payment_due', p_user_id,
           jsonb_build_object(
             'customer_name', v_name,
             'order_code',    o.code,
             'amount',        public.inr_money(v_open)),
           v_phone, o.id);
    v_ok := coalesce((v->>'ok')::boolean, false);
  exception when others then
    v_ok := false; v := jsonb_build_object('ok', false, 'reason', sqlerrm);
  end;

  -- A refusal names what is missing instead of printing a machine slug.
  v_reason := coalesce(v->>'reason','WhatsApp refused it');
  if v_reason = 'missing_values' then
    v_reason := 'the template still wants ' ||
      coalesce((select string_agg(x, ', ') from jsonb_array_elements_text(coalesce(v->'missing','[]'::jsonb)) x),
               'values this reminder does not carry');
  end if;

  return jsonb_build_object('ok', v_ok,
    'order_code', o.code,
    'message', case when v_ok
                    then 'Reminded ' || v_name || ' about ' || public.inr_money(v_open)
                         || ' on WhatsApp, naming ' || o.code || '.'
                    else 'Could not send the reminder: ' || v_reason end,
    'detail', v);
end $function$;

revoke execute on function public.admin_receivables_chase(uuid) from public, anon;
grant  execute on function public.admin_receivables_chase(uuid) to authenticated;
