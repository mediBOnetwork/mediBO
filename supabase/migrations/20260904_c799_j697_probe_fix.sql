-- CHANGE #799 — the qa-697-feedback journey counts only its OWN tickets.
--
-- Not a catalogue change: a REQUIRED storefront journey that had been red since
-- 2026-09-03 21:33 and blocks every completion in this area. It is a probe bug,
-- not a product bug — the feedback loop it tests works, and every other
-- assertion in the journey passes.
--
-- The probe runs the real chain against the newest closed order inside a
-- transaction it throws away. Its own writes vanish; a ticket a real customer
-- opened on that same order does not, because it was never the probe's. The
-- ticket count therefore included strangers, and one genuine 'support' ticket
-- landing on that order made an otherwise green journey read 3 tickets where it
-- had created 2.
--
-- Fix: snapshot the feedback tickets that exist BEFORE the chain and exclude
-- them from the count. Everything else about the journey is unchanged, so it
-- keeps asserting exactly what it asserted before — just about its own rows.
--
-- Idempotent: create or replace.

CREATE OR REPLACE FUNCTION public._journey_c697_feedback()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order   uuid;
  v_uid     uuid;
  v_claims  text := coalesce(current_setting('request.jwt.claims', true), '');
  v_token   text;
  v_prompt  jsonb; v_form jsonb; v_sub jsonb; v_again jsonb; v_twice jsonb;
  v_dims    int := 0; v_chips int := 0;
  v_tickets int := 0; v_dim_tag text := ''; v_feeds int := 0; v_weeks int := 0;
  -- CHANGE #799 — the tickets that were ALREADY on this order before the
  -- probe touched it. See the count below for why they have to be excluded.
  v_pre     uuid[] := '{}';
  v_anon_form boolean := false;
  v_ran     boolean := false;
  -- grants: the two writers must be unreachable, the two token entry points open
  v_writer_closed boolean;
  v_anon_open     boolean;
  v_once_only     boolean;
  v_routes        int;
  v_crons         int;
  v_nav           boolean;
  v_ok            boolean;
begin
  perform public._dev_guard();

  -- ── Structure. These hold whether or not a fixture order exists.
  v_writer_closed :=
    not has_function_privilege('anon',
      'public._order_feedback_write(uuid,jsonb,integer,text,text[],text,uuid,uuid)', 'execute')
    and not has_function_privilege('authenticated',
      'public._order_feedback_write(uuid,jsonb,integer,text,text[],text,uuid,uuid)', 'execute');

  v_anon_open :=
    has_function_privilege('anon', 'public.order_feedback_form(text)', 'execute')
    and has_function_privilege('anon',
      'public.order_feedback_submit_token(text,jsonb,integer,text,text[])', 'execute');

  -- One row per order is a CONSTRAINT, not a convention — that is what makes
  -- "never asked twice" true even when two tabs answer at once.
  select exists (
    select 1 from pg_index i
      join pg_class c on c.oid = i.indrelid
      join pg_attribute a on a.attrelid = c.oid and a.attnum = i.indkey[0]
     where c.relname = 'order_feedback' and i.indisunique
       and i.indnatts = 1 and a.attname = 'order_id')
    into v_once_only;

  select count(*) into v_routes from public.wa_event_routes
   where event_key in ('order_feedback_request','order_feedback_low') and enabled;

  select count(*) into v_crons from public.cron_task
   where name in ('order_feedback_sweep','order_feedback_rollup') and enabled;

  select (route_key = 'feedback' and is_active) into v_nav
    from public.feature_registry where feature_key = 'admin.feedback';

  -- ── The live chain, against a real closed order, then rolled back.
  select o.id, pp.user_id into v_order, v_uid
    from public.orders o
    join public.pharmacy_profiles pp on pp.id = o.customer_id
   where o.closed_at is not null and pp.user_id is not null
   order by o.closed_at desc limit 1;

  -- CHANGE #799 — remember what was there first.
  --
  -- The probe picks the NEWEST closed order and rolls its own writes back, but
  -- a ticket a real customer opened on that order does not roll back — it was
  -- never the probe's. Counting every feedback ticket on the order therefore
  -- counts strangers: on 2026-09-03 a genuine 'support' ticket (MB-2609-0004)
  -- landed on exactly that order and this journey read 3 where it had made 2,
  -- and went red for every command after it while the feedback loop itself was
  -- working perfectly. A probe must assert on what IT did.
  select coalesce(array_agg(t.id), '{}') into v_pre
    from public.support_ticket t
   where t.order_id = v_order and t.topic_code = 'feedback';

  if v_order is not null then
    begin
      v_ran := true;
      -- The order may already carry an answer; inside this block that is ours
      -- to clear, because none of it survives the raise at the bottom.
      delete from public.order_feedback where order_id = v_order;
      delete from public.order_feedback_token where order_id = v_order;

      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role', 'authenticated')::text, true);

      v_prompt := public.order_feedback_prompt(v_order);
      v_dims   := jsonb_array_length(coalesce(v_prompt->'dimensions','[]'::jsonb));
      select count(*)::int into v_chips
        from jsonb_array_elements(coalesce(v_prompt->'dimensions','[]'::jsonb)) d
       where jsonb_array_length(coalesce(d->'chips','[]'::jsonb)) > 0;

      v_token := public.order_feedback_send_wa(v_order) ->> 'token';

      -- The WhatsApp page, as a signed-out browser sees it.
      perform set_config('request.jwt.claims',
        json_build_object('role','anon')::text, true);
      v_form := public.order_feedback_form(v_token);
      v_anon_form := coalesce((v_form->>'ok')::boolean, false)
                 and coalesce(v_form->>'title','') <> '';

      v_sub := public.order_feedback_submit_token(v_token,
        '{"ordering":5,"packaging":1,"delivery":4,"products":5,"support":2}'::jsonb,
        5, 'boxes arrived crushed', array['pkg_damaged']);

      select count(*)::int, coalesce(string_agg(distinct feedback_dim, ','), '')
        into v_tickets, v_dim_tag
        from public.support_ticket
       where order_id = v_order and topic_code = 'feedback'
         and not (id = any (v_pre));

      select count(*)::int into v_feeds
        from public.exception_scorecard_input
       where exception_id like 'ofb:' || v_order::text || '%';

      perform public.order_feedback_rollup(4);
      select count(*)::int into v_weeks from public.order_feedback_weekly;

      -- Asked once: the customer's own prompt, and the link, both close.
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_uid::text, 'role','authenticated')::text, true);
      v_again := public.order_feedback_prompt(v_order);
      v_twice := public.order_feedback_submit_token(v_token,
        '{"ordering":5,"packaging":5,"delivery":5,"products":5,"support":5}'::jsonb, 10);

      raise exception using errcode = 'ZZ697', message = 'c697 journey rollback';
    exception when sqlstate 'ZZ697' then
      null;  -- every write above is gone; the answers are still in the variables
    end;
  end if;

  perform set_config('request.jwt.claims', v_claims, true);

  v_ok := v_writer_closed and v_anon_open and coalesce(v_once_only,false)
      and v_routes = 2 and v_crons = 2 and coalesce(v_nav,false)
      and v_ran
      and coalesce((v_prompt->>'show')::boolean,false)
      and v_dims = 5 and v_chips = 5
      and v_anon_form
      and coalesce((v_sub->>'ok')::boolean,false)
      and coalesce((v_sub->>'ticket_opened')::boolean,false)
      and v_tickets = 2 and v_dim_tag like '%packaging%'
      and v_feeds >= 3
      and v_weeks >= 1
      and coalesce((v_again->>'show')::boolean, true) = false
      and coalesce(v_twice->>'error','') = 'used';

  return jsonb_build_object(
    'status', case when v_ok then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
        'internal writers closed to anon+authenticated=' || v_writer_closed::text
     || ' | anon may read+submit the token page=' || v_anon_open::text
     || ' | one feedback row per order is a unique index=' || coalesce(v_once_only::text,'?')
     || ' | wa routes live=' || v_routes || '/2'
     || ' | cron tasks enabled=' || v_crons || '/2'
     || ' | Feedback desk registered at route feedback=' || coalesce(v_nav::text,'?')
     || ' | live chain ran=' || v_ran::text
     || ' | prompt.show=' || coalesce(v_prompt->>'show','-')
     || ' dimensions=' || v_dims || ' of 5, all with chips=' || v_chips
     || ' | anon form ok=' || v_anon_form::text
     || ' | token submit ok=' || coalesce(v_sub->>'ok','-')
     || ' ticket_opened=' || coalesce(v_sub->>'ticket_opened','-')
     || ' | tickets=' || v_tickets || ' tagged ' || coalesce(nullif(v_dim_tag,''),'-')
     || ' | scorecard inputs=' || v_feeds
     || ' | weekly rollup rows=' || v_weeks
     || ' | asked twice=' || coalesce(v_again->>'show','-')
     || ' | token reused=' || coalesce(v_twice->>'error','-')
     || ' | every write above was rolled back'));
end $function$

;
