-- CHANGE #290 — strengthen every journey whose mutation ESCAPED.
--
-- Pre-fix sweep (mutation_audit_run, one atomic break-probe-rollback per
-- journey): 11 caught, 7 escaped, 1 undecided.
--
--   escaped  reply-media-live            images '[""]' still "carries 1 image"
--   escaped  fast-lane-writes            any non-null ui_copy value passed
--   escaped  menu-reachability           self-certifying pass count
--   escaped  qa-274-54                   self-certifying pass count
--   escaped  qa-274-57                   no probe at all (fell to the fallback)
--   escaped  worker-grid-loads           no probe at all (fell to the fallback)
--   escaped  devqueue-buttons-change-db  no probe at all (fell to the fallback)
--   undecided qa-273-47                  permanently 'skipped' — and a skipped
--                                        REQUIRED journey blocks completion for
--                                        its whole area exactly like a failure
--
-- The headline defect is the fallback branch. It passed a journey once it had
-- >= 2 passed runs on record — but its OWN pass writes a dev_journey_runs row,
-- and that row counted. devqueue-buttons-change-db and worker-grid-loads each
-- had 40 passed runs of which 40 were its own and 0 came from any external
-- runner. The branch was certifying itself, forever, on evidence it minted.
--
-- Fixed here by (a) counting only externally reported passes, and (b) giving
-- the four journeys that can be proven in SQL a real probe so they never reach
-- the fallback at all.
--
-- SPLICED, never CREATE OR REPLACE'd: dev_journey_probe carries one branch per
-- command and a full-body replace built from a definition read minutes ago
-- silently deletes another worker's branch (that is how #191 erased #192's).
-- Every edit below reads the LIVE pg_get_functiondef, returns early when its
-- marker is already present, and RAISEs when an anchor moved.

do $c290s$
declare v_def text; v_new text; v_before text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'dev_journey_probe';
  if v_def is null then raise exception 'c290: dev_journey_probe not found'; end if;
  if position('c290-strengthen' in v_def) > 0 then return; end if;   -- idempotent
  v_new := v_def;

  -- ── 1. reply-media-live: a blank path is not a photo ──────────────────────
  -- It reported "carries 1 image(s)" for images '[""]'. add-media-survives got
  -- this right already (bool_and non-empty); this branch never did.
  v_before := v_new;
  v_new := replace(v_new,
$a$    return jsonb_build_object('status','passed',
      'evidence', jsonb_build_object('db_proof','reply message #'||v_row.id||' carries '||
        jsonb_array_length(v_row.images)::text||' image(s)'));$a$,
$a$    -- c290-strengthen: presence is not content. bool_and over the paths.
    select bool_and(coalesce(trim(x),'') <> '') into v_ok
    from jsonb_array_elements_text(v_row.images) x;
    return jsonb_build_object('status', case when coalesce(v_ok,false) then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof','reply message #'||v_row.id||' carries '||
        jsonb_array_length(v_row.images)::text||' image(s); every path non-empty='||
        coalesce(v_ok,false)::text));$a$);
  if v_new = v_before then raise exception 'c290: reply-media-live anchor moved'; end if;

  -- ── 2. fast-lane-writes: the VALUE is the point, not the row ──────────────
  -- The fast lane's whole claim is "ui_copy journey.test = X lands verbatim".
  -- Asserting `value is not null` passed for any wrong value, including the
  -- audit's own MUTATED_NOT_OK.
  v_before := v_new;
  v_new := replace(v_new,
$b$    return jsonb_build_object('status','passed','evidence',
      jsonb_build_object('db_proof',
        'ui_copy journey.test='||(select value::text from ui_copy where key='journey.test')));$b$,
$b$    -- c290-strengthen: compare the exact stored value, not its nullness.
    select value = '"journey_probe_ok"'::jsonb into v_ok
      from ui_copy where key='journey.test';
    return jsonb_build_object('status', case when coalesce(v_ok,false) then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'ui_copy journey.test='||(select value::text from ui_copy where key='journey.test')||
        '; equals the fast-lane marker="journey_probe_ok"='||coalesce(v_ok,false)::text));$b$);
  if v_new = v_before then raise exception 'c290: fast-lane-writes anchor moved'; end if;

  -- ── 3. the fallback may not count its own passes ──────────────────────────
  v_before := v_new;
  v_new := replace(v_new,
$c$    select count(*) into v_pass_count
    from dev_journey_runs
    where journey_id = v_jid and status = 'passed';$c$,
$c$    -- c290-strengthen: ONLY externally reported passes count. This branch
    -- writes evidence.db_proof on its own pass, so counting every passed run
    -- let it certify itself: two journeys stood at 40 passes, 40 of them its
    -- own and 0 from any runner. An external runner (journey_report from
    -- Playwright or a widget test) files evidence WITHOUT db_proof, and that
    -- is the only proof this branch is allowed to count.
    select count(*) into v_pass_count
    from dev_journey_runs
    where journey_id = v_jid and status = 'passed'
      and not (coalesce(evidence,'{}'::jsonb) ? 'db_proof');$c$);
  if v_new = v_before then raise exception 'c290: fallback pass-count anchor moved'; end if;

  -- ── 4. four real branches, inserted ahead of the fallback ─────────────────
  v_before := v_new;
  v_new := replace(v_new,
$d$  else
    -- Browser journeys (menu-reachability, devqueue-buttons-change-db, worker-grid-loads).$d$,
$e$  elsif p_name = 'qa-273-47' then
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
    select count(*) = 0 into v_a2
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname='public'
       and p.proname in ('cron_wake','cron_dispatch','cron_run','cron_add',
                         'cron_guard_sweep','cron_health')
       and (has_function_privilege('anon', p.oid, 'execute')
         or has_function_privilege('authenticated', p.oid, 'execute'));
    select not (has_function_privilege('anon','public.cron_wake(text)','execute')) into v_a3;
    select count(*) = 0 into v_a4
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname='public'
       and c.relname in ('cron_task','cron_signal','cron_guard_config','cron_dispatch_state')
       and (has_table_privilege('anon', c.oid, 'select')
         or has_table_privilege('anon', c.oid, 'insert'));
    v_ok := coalesce(v_a1,false) and coalesce(v_a2,false)
        and coalesce(v_a3,false) and coalesce(v_a4,false);
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'all six cron RPCs present='||coalesce(v_a1,false)::text||
        ' | none EXECUTE-able by anon/authenticated='||coalesce(v_a2,false)::text||
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
    select count(*),
           count(*) filter (where (card->'pricing') ?| array['ptr_display','ptr_caption','raw','has_ptr']),
           count(*) filter (where coalesce((card->'pricing'->'card_price'->>'has_ptr')::boolean, true)),
           count(*) filter (where coalesce(card->'pricing'->'card_price'->>'has_note','') <> 'true'
                              and coalesce(card->'pricing'->'card_price'->>'note','') = ''),
           count(*) filter (where coalesce(card->'pricing'->>'display_mode','') <> 'mrp_only')
      into v_pass_count, v_a1, v_a2, v_a3, v_a4
    from cards;

    v_ok := coalesce(v_pass_count,0) > 0
        and v_a1::text = '0' and v_a2::text = '0'
        and v_a3::text = '0' and v_a4::text = '0';
    return jsonb_build_object('status', case when v_ok then 'passed' else 'failed' end,
      'evidence', jsonb_build_object('db_proof',
        'anon cards walked='||coalesce(v_pass_count,0)::text||
        ' | cards leaking a ptr key='||v_a1::text||
        ' | cards with card_price.has_ptr not false='||v_a2::text||
        ' | cards missing the locked note='||v_a3::text||
        ' | cards not in display_mode=mrp_only='||v_a4::text));

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
    -- can read is a run somebody else filed through journey_report.$e$);
  if v_new = v_before then raise exception 'c290: fallback else anchor moved'; end if;

  execute v_new;
end $c290s$;

-- The probe now calls storefront_home_v2 over the whole catalogue on top of the
-- rg_check work bug-191 already does. Set the ceiling on the FUNCTION rather
-- than replacing it, so another worker's branch is never lost to this line.
alter function public.dev_journey_probe(text) set statement_timeout to '180000';
