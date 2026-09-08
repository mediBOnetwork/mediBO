-- CHANGE #697 — the feedback loop, retired as a JOURNEY rather than as a
-- screenshot.
--
-- Spec item 7 asks for the whole chain to be proven: close an order, be asked
-- once, submit a low score, watch a ticket open and the scorecards move, and
-- prove the WhatsApp page works with no login at all. A browser cannot prove
-- any of that — every assertion here is about a row, a grant or an RPC's
-- answer — so the probe runs the REAL chain against a REAL closed order and
-- then rolls itself back: the writes happen inside a block whose exception
-- handler discards them, while the answers it collected live on in plpgsql
-- variables. Nothing is left behind, and nothing is simulated.

create or replace function public._journey_c697_feedback()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_order   uuid;
  v_uid     uuid;
  v_claims  text := coalesce(current_setting('request.jwt.claims', true), '');
  v_token   text;
  v_prompt  jsonb; v_form jsonb; v_sub jsonb; v_again jsonb; v_twice jsonb;
  v_dims    int := 0; v_chips int := 0;
  v_tickets int := 0; v_dim_tag text := ''; v_feeds int := 0; v_weeks int := 0;
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
       where order_id = v_order and topic_code = 'feedback';

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
end $$;

revoke execute on function public._journey_c697_feedback() from public, anon, authenticated;

insert into public.dev_journeys (name, area, kind, steps, assertions, source_bug, required, enabled)
values (
  'qa-697-feedback', 'storefront', 'api',
  jsonb_build_array(
    'An order closes (delivered and settled, or the #229 closure state).',
    'The customer is asked exactly once: order_feedback_prompt returns show:true with five dimensions, each carrying its own low-score chips.',
    'The same order is also sent as a WhatsApp link, and order_feedback_form(token) answers a signed-out browser.',
    'A low score is submitted through that anonymous link.',
    'A support ticket opens tagged with the dimension, the zone partner is notified, and the scorecard inputs and weekly NPS rollup move.',
    'Neither the in-app card nor the link ever asks again.'),
  jsonb_build_array(
    '_order_feedback_write and _order_feedback_open_ticket are executable by neither anon nor authenticated',
    'order_feedback_form and order_feedback_submit_token ARE executable by anon',
    'order_feedback.order_id carries a unique index, so "asked once" is a constraint',
    'wa_event_routes order_feedback_request and order_feedback_low are both active',
    'cron_task order_feedback_sweep and order_feedback_rollup are both enabled',
    'feature_registry admin.feedback is active on route_key feedback',
    'the live chain: prompt show:true with 5 dimensions all carrying chips, anon form ok, token submit ok with ticket_opened, 2 tickets tagged packaging+support, >=3 scorecard inputs, >=1 weekly row, prompt then show:false, token reuse refused as used',
    'every write the probe made is rolled back before it returns'),
  697, false, true)
on conflict do nothing;
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

  -- CHANGE #686 (round 5) — the five QA blockers filed against this command,
  -- each retired as the CLASS it belongs to rather than as the row that was
  -- photographed. They arrived as stubs reading "TODO implement before
  -- completing #686" and so fell through to the external-proof branch below,
  -- which reported 'skipped — browser runner needs 2 more run(s)' forever:
  -- no browser can prove a statement about a table.
  if p_name = 'qa-686-365' then return public._journey_c686_header_slots();     end if;
  if p_name = 'qa-686-366' then return public._journey_c686_sweep_complete();   end if;
  if p_name = 'qa-686-367' then return public._journey_c686_detector_battery(); end if;
  if p_name = 'qa-686-378' then return public._journey_c686_bare_dollar();      end if;
  if p_name = 'qa-686-379' then return public._journey_c686_drift_rpc_fenced(); end if;

  -- CHANGE #745 — the two hostile-QA blockers filed against the payload-driven
  -- customer menu. They arrived as journeys whose only step read "TODO
  -- implement before completing #745", so they fell through to the
  -- external-proof branch at the bottom and reported "skipped — browser runner
  -- needs 2 more run(s)" forever. No browser can prove a statement about a
  -- registry row or an RPC's own source: the backend half belongs here, and
  -- the client half is held by test/protected/customer_menu_placement_test.dart,
  -- which runs before every deploy.
  if p_name = 'qa-745-425' then return public._journey_c745_logout_always(); end if;
  if p_name = 'qa-745-426' then return public._journey_c745_offline_menu();  end if;

  -- CHANGE #697 — the whole-order feedback loop. The probe runs the REAL chain
  -- against a real closed order (prompt once, WhatsApp link as anon, low score,
  -- ticket, scorecard feeds, rollup, never asked twice) and rolls every write
  -- back before it answers, so the journey costs nothing and simulates nothing.
  if p_name = 'qa-697-feedback' then return public._journey_c697_feedback(); end if;


  -- CMD #418 — a model provider's raw error reaching a pharmacy's till,
  -- retired as a class (see _journey_c418_provider_error).
  if p_name = 'qa-418-233' then return public._journey_c418_provider_error(); end if;


  -- CHANGE #436 — the default PUBLIC EXECUTE grant, closed as a class.
  if p_name = 'bug-436' then return public._journey_bug436(); end if;
  -- CHANGE #683 — the same default-PUBLIC-grant class on the zone and
  -- storefront maintenance surface: unguarded refresh/rebuild jobs are
  -- tokenless compute on a 1 GB instance, and zone_supplier_names was
  -- handing the supplier roster to the bundled anon key.
  if p_name = 'bug-683' then return public._journey_bug683(); end if;
  -- CMD #467 — the same default-PUBLIC-grant class, on the partner audit
  -- surface this command added. Writing it found the quieter half: a grant is
  -- not a guard, and admin_partner_audit_preview() had EXECUTE for every
  -- authenticated login with no role check in its body.
  if p_name = 'qa-467-323' then return public._journey_c467_partner_audit_fence(); end if;
  -- CMD #633 — a raw copy template rendered at a reader, retired as a
  -- class: cf() reports every unfilled slot on the render log.
  if p_name = 'bug-633' then return public._journey_bug633(); end if;
  -- CMD #450 — the three QA blockers this command found, each retired as a
  -- class rather than as one fix: a write action naming an event key nobody
  -- registered (both of #450's actions shipped that way), and a save-time
  -- guard that a TRIGGER walked around.
  if p_name in ('qa-450-250','qa-450-251') then
    return public._journey_c450_live_event_keys();
  end if;
  if p_name = 'qa-450-252' then return public._journey_c450_autoenable_gated(); end if;
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
  -- CHANGE #424 — the same class in the inference engine, caught by qa-414-227
  -- on #424 itself: an engine internal that takes a shop id must never be
  -- client-reachable, and fencing it must not fence the owner out.
  if p_name = 'qa-424-237' then return public._journey_c424_shop_fence(); end if;
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
         and d.id > 0   -- CHANGE #646: reserved-negative ids are rg probes
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



