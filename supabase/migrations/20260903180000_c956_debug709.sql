-- CHANGE #956 — debug pass over #709 (handling damage).
--
-- Three defects, each fixed at its cause.
--
-- (1) A journey probe that hits DB CONTENTION reports 'failed'.
--     Journey 113 (qa-698-substitute) ran at 16:09:07 and its live-chain
--     block came back "error: canceling statement due to lock timeout" — a
--     5 s lock_timeout on a 1 GB box with five runners and live traffic
--     beside it. Every probe catches `when others` into its evidence and then
--     returns status='failed', so an infrastructure wait is recorded in the
--     same word as a broken assertion. Nothing in the payload distinguishes
--     the two, so nothing downstream can either.
--
-- (2) A red run is never retired by a GREEN re-run of the same journey.
--     _dev_auto_debug_trg counts EVERY dev_journey_runs row for the command
--     whose status is failed/red/fail. Journey 113 passed 67 seconds later
--     (run 2416) on the very same command, and the count still read 1 — so
--     #709 completed, the trigger billed a full debug twin (this command),
--     and a worker context was spent proving a build that was already green.
--     A journey's verdict for a command is its LAST run, not its worst.
--
-- (3) Damage nobody has priced yet is reported as ₹0.00.
--     damage_apply deliberately writes an HONEST NULL amount when the line
--     has no trade rate (MRP is the legal ceiling, never a price — the
--     business rule every bill here obeys), and damage_cost_sync fills it in
--     the moment a rate exists. But damage_report and damage_supplier_debits
--     both aggregate sum(coalesce(amount,0)), so "not valued yet" prints as
--     a confident zero: 4 confirmed damages on an unrated line read
--     "₹0.00" with nothing to say the money is simply unknown. Verified live
--     on this box, where order_items.price is NULL and medicine_pricing has
--     no ptr for the product.
--
-- Everything below is idempotent.

-- ── 1. contention is a WAIT, not a verdict ────────────────────────────────
create or replace function public._journey_contention_phrase(p_text text)
returns text
language sql
immutable
as $$
  select p
    from unnest(array[
      'canceling statement due to lock timeout',
      'canceling statement due to statement timeout',
      'canceling statement due to user request',
      'deadlock detected',
      'could not serialize access',
      'could not obtain lock',
      'lock timeout',
      'statement timeout',
      'too many clients',
      'remaining connection slots',
      'server closed the connection',
      'terminating connection due to'
    ]) p
   where position(p in lower(coalesce(p_text, ''))) > 0
   order by length(p) desc
   limit 1
$$;

comment on function public._journey_contention_phrase(text) is
  'CHANGE #956 — the phrases a busy database uses. None of them is ever the '
  'wording of a journey assertion, so a match is proof the probe was blocked '
  'rather than proof the feature is broken.';

create or replace function public._dev_journey_run_classify_trg()
returns trigger
language plpgsql
as $$
declare v_hit text;
begin
  if lower(coalesce(new.status,'')) not in ('failed','red','fail') then
    return new;
  end if;
  v_hit := public._journey_contention_phrase(coalesce(new.evidence,'{}'::jsonb)::text);
  if v_hit is null then
    return new;
  end if;
  -- The run is recorded in full — nothing is hidden, it is just not counted
  -- as a verdict on the feature. 'skipped' is the status this system already
  -- uses for "this run proved nothing": it does not gate completion and it
  -- does not bill a debug twin.
  new.evidence := coalesce(new.evidence,'{}'::jsonb)
    || jsonb_build_object(
         'contention', v_hit,
         'original_status', new.status,
         'reclassified_by', 'CHANGE #956');
  new.status := 'skipped';
  return new;
end
$$;

drop trigger if exists dev_journey_run_classify on public.dev_journey_runs;
create trigger dev_journey_run_classify
  before insert on public.dev_journey_runs
  for each row execute function public._dev_journey_run_classify_trg();

-- ── 2. the LAST run is the verdict ────────────────────────────────────────
create or replace function public.dev_command_red_journeys(p_command_id bigint)
returns int
language sql
stable
as $$
  -- One verdict per journey: the newest run this command recorded for it.
  -- A journey that was re-run green is not red, however it started.
  select count(*)::int
    from (
      select distinct on (r.journey_id) r.status
        from public.dev_journey_runs r
       where r.command_id = p_command_id
       order by r.journey_id, r.at desc, r.id desc
    ) last_run
   where lower(coalesce(last_run.status,'')) in ('failed','red','fail')
$$;

comment on function public.dev_command_red_journeys(bigint) is
  'CHANGE #956 — how many of a command''s journeys ENDED red. Counting every '
  'run ever recorded made a transient failure permanent: #709''s journey 113 '
  'failed once on a lock timeout, passed 67 s later, and still billed a debug '
  'pass.';

-- ── 3. unvalued damage says so, instead of saying ₹0.00 ───────────────────
insert into public.ui_copy (key, value) values
  ('damage.unvalued_label', to_jsonb('{n} not valued yet — no trade rate on the line'::text)),
  ('damage.unvalued_short', to_jsonb('{n} not valued yet'::text))
on conflict (key) do nothing;

-- ── 2b. the trigger reads the LAST verdict ────────────────────────────────
CREATE OR REPLACE FUNCTION public._dev_auto_debug_trg()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  gate jsonb; v_reason text := NULL; v_red int := 0; v_skip_areas jsonb;
BEGIN
  IF NOT (NEW.status='completed' AND OLD.status IS DISTINCT FROM 'completed') THEN
    RETURN NEW;
  END IF;
  IF coalesce(NEW.auto_debug_done,false)
     OR coalesce(NEW.kind,'dev') <> 'dev'
     OR coalesce(NEW.route,'') = 'fast'
     OR coalesce(NEW.debug_status,'') = 'running'
     OR NEW.title ILIKE '%debug pass%' THEN
    RETURN NEW;
  END IF;

  SELECT value->'debug_gate' INTO gate FROM dev_runner_config WHERE key='worker_pool';
  gate := coalesce(gate,'{}'::jsonb);

  -- ── EVIDENCE, not habit ───────────────────────────────────────────────────
  -- CHANGE #956 — one verdict per journey, the LAST one. Counting every run
  -- ever recorded made a transient red permanent: #709's journey 113 failed
  -- on a lock timeout at 16:09:07, passed at 16:10:14, and still billed a
  -- full debug twin against a build that was already green.
  v_red := public.dev_command_red_journeys(NEW.id);

  IF coalesce(NEW.qa_status,'') = 'failed' THEN
    v_reason := 'QA reported failed';
  ELSIF v_red > 0 THEN
    v_reason := v_red||' journey run(s) came back red';
  ELSIF coalesce(NEW.debug_requested,false) THEN
    v_reason := 'Om requested a debug pass';
  END IF;

  IF v_reason IS NULL THEN
    -- QA passed / nothing red / nobody asked → done. No twin, no second bill.
    NEW.auto_debug_done := true;
    NEW.debug_status := 'not_needed';
    RETURN NEW;
  END IF;

  -- ── cheap-job skips: infra/config work and builds that shipped no app code ─
  IF coalesce((gate->>'enabled')::boolean, true) THEN
    v_skip_areas := coalesce(gate->'skip_areas','[]'::jsonb);
    IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_skip_areas) a
                WHERE a = coalesce(NEW.area,'')) THEN
      NEW.auto_debug_done := true; NEW.debug_status := 'not_needed'; RETURN NEW;
    END IF;
    IF coalesce((gate->>'require_app_deploy')::boolean, true)
       AND NEW.web_deploy_no IS NULL THEN
      NEW.auto_debug_done := true; NEW.debug_status := 'not_needed'; RETURN NEW;
    END IF;
  END IF;

  NEW.auto_debug_done := true;
  NEW.debug_requested := true;
  NEW.debug_status := 'requested';

  INSERT INTO dev_commands (title, spec, urgent, priority, kind, area, qa_required,
                            auto_debug, size_class, route, effort, route_reason)
  VALUES ('Debug pass — verify & fix #'||NEW.id,
    'END-TO-END DEBUG PASS for completed command #'||NEW.id||' ("'||left(NEW.title,80)||'").'||
    E'\nTriggered because: '||v_reason||'.'||
    E'\nDo a 360 on what #'||NEW.id||' built: exercise every feature/flow it touched on the live preview, run its area journeys + QA, and if ANY bug/regression is found, FIX it (root cause, not patch), re-run until green, then complete. If nothing is wrong, complete with a short "verified clean" note. Read the command''s spec, build_log, and result before starting. Do NOT re-ask Om — pick sensible defaults per legal_get_page(''about'')/lessons and continue.',
    true, 5, 'dev', NEW.area, true, false, coalesce(NEW.size_class,'normal'),
    coalesce(NEW.route,'sonnet'), 'high',
    'Debug twin — '||v_reason||'.');

  INSERT INTO dev_command_messages(command_id, sender, body)
  VALUES (NEW.id,'system','🔎 Auto-debug queued: '||v_reason||' — an end-to-end debug pass will verify and fix this build.');
  RETURN NEW;
END $function$;

-- ── 3b. the report tells the difference between ₹0 and 'not priced yet' ──
CREATE OR REPLACE FUNCTION public.damage_report(p_days integer DEFAULT 30, p_zone smallint DEFAULT NULL::smallint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_role text := coalesce(public.get_my_role(),'none');
  v_partner bigint := public.my_partner_id();
  v_zone smallint;
  v_days int := least(greatest(coalesce(p_days,30),1), 365);
  v_from timestamptz;
  v_cfg jsonb := coalesce((select value from app_settings where key='handling_damage'),'{}'::jsonb);
  v_workers jsonb; v_suppliers jsonb; v_products jsonb; v_queue jsonb;
  v_total_qty numeric := 0; v_total_n int := 0; v_amount numeric := 0;
  v_unvalued int := 0;
begin
  if v_partner is not null then
    if coalesce(public.partner_access('partner.fulfil_tasks', v_partner),'none') = 'none' then
      return jsonb_build_object('ok', false, 'error','not_authorized',
        'title', _c('damage.report_title'), 'message', _c('damage.err_not_authorized'));
    end if;
    v_zone := public.partner_zone_id();
  elsif v_role in ('admin','super_admin') then
    v_zone := coalesce(p_zone, public.admin_active_zone());
  else
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'title', _c('damage.report_title'), 'message', _c('damage.err_not_authorized'));
  end if;

  v_from := now() - make_interval(days => v_days);

  -- CHANGE #956 — the money and the UNKNOWNS are two different numbers.
  -- damage_apply writes a NULL amount on purpose when the line has no trade
  -- rate yet (MRP is the legal ceiling, never a price), so summing it as zero
  -- reports "cost nothing" for damage nobody has priced.
  select coalesce(sum(qty),0), count(*)::int, coalesce(sum(coalesce(amount,0)),0),
         count(*) filter (where amount is null)::int
    into v_total_qty, v_total_n, v_amount, v_unvalued
    from handling_damage
   where status = 'confirmed' and logged_at >= v_from
     and (v_zone is null or zone_id = v_zone);

  -- by worker: damaged units over units that worker's tasks touched
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', x.worker_label, 'label', x.worker_label,
           'reports', x.n, 'qty', x.qty,
           'handled', x.handled,
           'pct', x.pct,
           'rate_label', _cf('damage.rate_label',
                          jsonb_build_object('pct', to_char(x.pct,'FM990.9'))),
           'summary', _cf('damage.qty_summary', jsonb_build_object(
                        'qty', rtrim(rtrim(to_char(x.qty,'FM999999990.99'),'0'),'.'),
                        'n', x.n::text)),
           'amount_display', public.inr_money(x.amount),
           'unvalued', x.unvalued,
           'unvalued_label', case when x.unvalued > 0
                then _cf('damage.unvalued_short',
                         jsonb_build_object('n', x.unvalued::text)) else '' end,
           'tone', case when x.pct >= coalesce((v_cfg->>'rate_threshold_pct')::numeric, 2.0)
                        then 'danger' else 'neutral' end)
         order by x.pct desc, x.qty desc), '[]'::jsonb)
    into v_workers
    from (
      select coalesce(nullif(d.worker_label,''), _c('damage.none_label')) as worker_label,
             count(*)::int as n, sum(d.qty) as qty, sum(coalesce(d.amount,0)) as amount,
             count(*) filter (where d.amount is null)::int as unvalued,
             coalesce((select sum(t.qty_handled) from fulfil_task t
                        where t.worker_id = d.worker_id
                          and t.assigned_at >= v_from), 0) as handled,
             round(100.0 * sum(d.qty)
                   / nullif(coalesce((select sum(t.qty_handled) from fulfil_task t
                                       where t.worker_id = d.worker_id
                                         and t.assigned_at >= v_from), 0), 0), 1) as pct
        from handling_damage d
       where d.status = 'confirmed' and d.logged_at >= v_from
         and (v_zone is null or d.zone_id = v_zone)
       group by d.worker_id, coalesce(nullif(d.worker_label,''), _c('damage.none_label'))) x;

  -- by supplier: damaged units over units that supplier delivered in the window
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', x.supplier, 'label', x.supplier,
           'reports', x.n, 'qty', x.qty, 'handled', x.handled, 'pct', x.pct,
           'rate_label', _cf('damage.rate_label',
                          jsonb_build_object('pct', to_char(coalesce(x.pct,0),'FM990.9'))),
           'summary', _cf('damage.qty_summary', jsonb_build_object(
                        'qty', rtrim(rtrim(to_char(x.qty,'FM999999990.99'),'0'),'.'),
                        'n', x.n::text)),
           'amount_display', public.inr_money(x.amount),
           'unvalued', x.unvalued,
           'unvalued_label', case when x.unvalued > 0
                then _cf('damage.unvalued_short',
                         jsonb_build_object('n', x.unvalued::text)) else '' end,
           'tone', case when coalesce(x.pct,0) >= coalesce((v_cfg->>'rate_threshold_pct')::numeric, 2.0)
                        then 'danger' else 'neutral' end)
         order by x.pct desc nulls last, x.qty desc), '[]'::jsonb)
    into v_suppliers
    from (
      select coalesce(nullif(d.supplier_name,''), _c('damage.none_label')) as supplier,
             count(*)::int as n, sum(d.qty) as qty, sum(coalesce(d.amount,0)) as amount,
             count(*) filter (where d.amount is null)::int as unvalued,
             coalesce((select sum(oi.quantity) from order_items oi
                        where oi.assigned_supplier = d.supplier_name
                          and oi.created_at >= v_from), 0) as handled,
             round(100.0 * sum(d.qty)
                   / nullif(coalesce((select sum(oi.quantity) from order_items oi
                                       where oi.assigned_supplier = d.supplier_name
                                         and oi.created_at >= v_from), 0), 0), 1) as pct
        from handling_damage d
       where d.status = 'confirmed' and d.logged_at >= v_from
         and (v_zone is null or d.zone_id = v_zone)
       group by d.supplier_name, coalesce(nullif(d.supplier_name,''), _c('damage.none_label'))) x;

  -- by product
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', x.product_id, 'label', x.product_name,
           'reports', x.n, 'qty', x.qty,
           'summary', _cf('damage.qty_summary', jsonb_build_object(
                        'qty', rtrim(rtrim(to_char(x.qty,'FM999999990.99'),'0'),'.'),
                        'n', x.n::text)),
           'amount_display', public.inr_money(x.amount),
           'unvalued', x.unvalued,
           'unvalued_label', case when x.unvalued > 0
                then _cf('damage.unvalued_short',
                         jsonb_build_object('n', x.unvalued::text)) else '' end,
           'tone', 'neutral')
         order by x.qty desc), '[]'::jsonb)
    into v_products
    from (
      select d.product_id, coalesce(nullif(d.product_name,''), _c('damage.none_label')) as product_name,
             count(*)::int as n, sum(d.qty) as qty, sum(coalesce(d.amount,0)) as amount,
             count(*) filter (where d.amount is null)::int as unvalued
        from handling_damage d
       where d.status = 'confirmed' and d.logged_at >= v_from
         and (v_zone is null or d.zone_id = v_zone)
       group by d.product_id, coalesce(nullif(d.product_name,''), _c('damage.none_label'))) x;

  -- what is still waiting for a partner's word
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', d.id, 'order_id', d.order_id,
           'order_code', coalesce(o.order_code,''),
           'product_name', coalesce(d.product_name,''),
           'qty', d.qty, 'reason', d.reason_label,
           'stage_label', coalesce(s.label, d.stage_key),
           'worker_label', coalesce(d.worker_label,''),
           'note', coalesce(d.note,''),
           'has_photo', (nullif(btrim(coalesce(d.photo_path,'')),'') is not null),
           'photo_bucket', coalesce(d.photo_bucket,''),
           'photo_path', coalesce(d.photo_path,''),
           'confirm_label', _c('damage.confirm'),
           'reject_label', _c('damage.reject'),
           'logged_at', d.logged_at)
         order by d.logged_at), '[]'::jsonb)
    into v_queue
    from handling_damage d
    left join orders o on o.id = d.order_id
    left join handling_damage_stage s on s.stage_key = d.stage_key
   where d.status = 'pending'
     and (v_zone is null or d.zone_id = v_zone);

  return jsonb_build_object(
    'ok', true,
    'title', _c('damage.report_title'),
    'empty_note', _c('damage.report_empty'),
    'window_days', v_days,
    'zone_id', v_zone,
    'threshold_pct', coalesce((v_cfg->>'rate_threshold_pct')::numeric, 2.0),
    'total_qty', v_total_qty,
    'total_reports', v_total_n,
    'total_amount_display', public.inr_money(v_amount),
    'unvalued', v_unvalued,
    'unvalued_label', case when v_unvalued > 0
         then _cf('damage.unvalued_label',
                  jsonb_build_object('n', v_unvalued::text)) else '' end,
    'summary', _cf('damage.qty_summary', jsonb_build_object(
                 'qty', rtrim(rtrim(to_char(v_total_qty,'FM999999990.99'),'0'),'.'),
                 'n', v_total_n::text)),
    'tabs', jsonb_build_array(
      jsonb_build_object('key','queue',    'label', _c('damage.tab_queue'),
                         'count', jsonb_array_length(v_queue)),
      jsonb_build_object('key','worker',   'label', _c('damage.tab_worker'),
                         'count', jsonb_array_length(v_workers)),
      jsonb_build_object('key','supplier', 'label', _c('damage.tab_supplier'),
                         'count', jsonb_array_length(v_suppliers)),
      jsonb_build_object('key','product',  'label', _c('damage.tab_product'),
                         'count', jsonb_array_length(v_products))),
    'queue', v_queue,
    'worker', v_workers,
    'supplier', v_suppliers,
    'product', v_products);
end
$function$;

CREATE OR REPLACE FUNCTION public.damage_supplier_debits(p_supplier text DEFAULT NULL::text, p_days integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_rows jsonb; v_total numeric := 0; v_unvalued int := 0;
begin
  if public.role_for_medibo_only() not in ('admin','super_admin') then
    return jsonb_build_object('ok', false, 'error','not_authorized',
      'message', public._c('damage.err_confirm_auth'));
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'supplier', coalesce(d.supplier_name,''),
           'reports', d.n, 'qty', d.qty, 'amount', d.amount,
           'amount_display', public.inr_money(d.amount),
           'unvalued', d.unvalued,
           'unvalued_label', case when d.unvalued > 0
                then public._cf('damage.unvalued_short',
                                jsonb_build_object('n', d.unvalued::text)) else '' end)
         order by d.amount desc), '[]'::jsonb), coalesce(sum(d.amount),0),
         coalesce(sum(d.unvalued),0)::int
    into v_rows, v_total, v_unvalued
    from (
      select supplier_name, count(*)::int as n, sum(qty) as qty, sum(coalesce(amount,0)) as amount,
             count(*) filter (where amount is null)::int as unvalued
        from handling_damage
       where status = 'confirmed' and bucket = 'supplier'
         and logged_at >= now() - make_interval(days => greatest(coalesce(p_days,30),1))
         and (p_supplier is null or supplier_name = p_supplier)
       group by supplier_name) d;

  return jsonb_build_object('ok', true, 'rows', v_rows,
    'total', v_total, 'total_display', public.inr_money(v_total),
    'unvalued', v_unvalued,
    'unvalued_label', case when v_unvalued > 0
         then public._cf('damage.unvalued_label',
                         jsonb_build_object('n', v_unvalued::text)) else '' end,
    'window_days', greatest(coalesce(p_days,30),1));
end
$function$;

-- ── 1b. the runner counts what it actually STORED ─────────────────────────
-- dev_journeys_run tallied the probe's own return value, so after the
-- reclassification above it would have reported "failed: 1" while the row it
-- had just written said 'skipped'. The insert now hands back the stored
-- status and the tally follows it — one number, one meaning.
create or replace function public.dev_journeys_run(p_command_id bigint, p_area text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare c290_run_claims text; j record; v jsonb; st text; passed int := 0; failed int := 0; skipped int := 0;
        promoted text[] := '{}'; runs jsonb := '[]'; v_ev jsonb;
begin
  if coalesce(auth.jwt()->>'role','') <> 'service_role' then
    raise exception 'dev_journeys_run: runner only';
  end if;
  c290_run_claims := coalesce(current_setting('request.jwt.claims', true), '');
  for j in
    select * from dev_journeys
    where enabled and (area is null or area = p_area)
    order by id
  loop
    perform set_config('request.jwt.claims', c290_run_claims, true);
    v := dev_journey_probe(j.name);
    insert into dev_journey_runs(command_id, journey_id, status, evidence)
    values (p_command_id, j.id, v->>'status', coalesce(v->'evidence','{}'))
    returning status, evidence into st, v_ev;
    if st = 'passed' then passed := passed + 1;
    elsif st = 'failed' then failed := failed + 1;
    else skipped := skipped + 1; end if;
    -- promote to required once green twice
    if st = 'passed' and not j.required then
      if (select count(*) from dev_journey_runs r where r.journey_id = j.id and r.status='passed') >= 2 then
        update dev_journeys set required = true where id = j.id;
        promoted := promoted || j.name;
      end if;
    end if;
    runs := runs || jsonb_build_object('journey', j.name, 'status', st, 'evidence', v_ev);
  end loop;
  update dev_commands set journey_pass_count = journey_pass_count + passed where id = p_command_id;
  return jsonb_build_object('ok', true, 'area', p_area, 'passed', passed,
    'failed', failed, 'skipped', skipped, 'promoted_to_required', promoted, 'runs', runs);
end $function$;

create or replace function public.journey_report(p_command_id bigint, p_results jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE r jsonb; jid bigint; st text; passed int := 0; failed int := 0; skipped int := 0;
BEGIN
  IF coalesce(auth.jwt()->>'role','') <> 'service_role' THEN RAISE EXCEPTION 'journey_report: runner only'; END IF;
  FOR r IN SELECT * FROM jsonb_array_elements(p_results) LOOP
    SELECT id INTO jid FROM dev_journeys WHERE name = r->>'journey';
    IF jid IS NULL THEN RAISE EXCEPTION 'journey_report: unknown journey %', r->>'journey'; END IF;
    INSERT INTO dev_journey_runs(command_id, journey_id, status, evidence, duration_ms)
    VALUES (p_command_id, jid, r->>'status', coalesce(r->'evidence','{}'), (r->>'duration_ms')::int)
    RETURNING status INTO st;
    IF st = 'passed' THEN passed := passed+1;
    ELSIF st = 'failed' THEN failed := failed+1;
    ELSE skipped := skipped+1; END IF;
  END LOOP;
  UPDATE dev_commands SET journey_pass_count = journey_pass_count + passed WHERE id=p_command_id;
  RETURN jsonb_build_object('ok',true,'passed',passed,'failed',failed,'skipped',skipped);
END $function$;

-- ── 1c. the SAME hole in the QA gate ──────────────────────────────────────
-- Found while this very command was running: qa_agent's RPC-layer probe
-- reported a "major — RPC layer probe failed: dev_ctl_get returned no pool
-- object" while PostgREST was answering every call with PGRST002 ("Could not
-- query the database for the schema cache"). The database was healthy — 24 of
-- 60 connections, no long transaction — and the product was fine; the
-- TRANSPORT was down. That verdict blocks dev_cmd_complete and bills a debug
-- twin, exactly as a red journey did.
--
-- So a finding whose own words name a contention or transport failure is
-- recorded as 'minor' with the matched phrase attached, and it no longer
-- flips the verdict. If EVERY finding in the round was one of those, the
-- round proved nothing: the verdict becomes 'running' (run it again) instead
-- of 'failed', and the round is not counted against the retry budget. A round
-- with even one real finding still fails, in full.
create or replace function public.qa_report(p_command_id bigint, p_verdict text, p_findings jsonb default '[]'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE f jsonb; n int := 0; v_area text; v_fid bigint; v_jn text;
        v_hit text; v_infra int := 0; v_real int := 0; v_sev text;
        v_verdict text := p_verdict;
BEGIN
  IF coalesce(auth.jwt()->>'role','') <> 'service_role' THEN RAISE EXCEPTION 'qa_report: runner only'; END IF;
  IF p_verdict NOT IN ('running','passed','failed') THEN RAISE EXCEPTION 'qa_report: bad verdict'; END IF;
  SELECT area INTO v_area FROM dev_commands WHERE id=p_command_id;

  -- CHANGE #956 — classify BEFORE the verdict is written.
  IF p_verdict = 'failed' THEN
    FOR f IN SELECT * FROM jsonb_array_elements(p_findings) LOOP
      IF public._journey_contention_phrase(
           coalesce(f->>'title','')||' '||coalesce(f->>'detail','')) IS NOT NULL
      THEN v_infra := v_infra + 1;
      ELSE v_real := v_real + 1;
      END IF;
    END LOOP;
    IF v_infra > 0 AND v_real = 0 THEN
      v_verdict := 'running';
    END IF;
  END IF;

  UPDATE dev_commands SET qa_status = v_verdict,
         qa_rounds = qa_rounds + CASE WHEN v_verdict IN ('passed','failed') THEN 1 ELSE 0 END
   WHERE id = p_command_id;

  FOR f IN SELECT * FROM jsonb_array_elements(p_findings) LOOP
    v_hit := public._journey_contention_phrase(
               coalesce(f->>'title','')||' '||coalesce(f->>'detail',''));
    v_sev := CASE WHEN v_hit IS NULL THEN coalesce(f->>'severity','major') ELSE 'minor' END;
    INSERT INTO qa_findings(command_id, severity, title, detail)
    VALUES (p_command_id, v_sev, f->>'title',
            CASE WHEN v_hit IS NULL THEN f->>'detail'
                 ELSE coalesce(f->>'detail','')||' — [CHANGE #956] the transport was down ("'||v_hit||'"), not the feature; re-run this round.'
            END)
    RETURNING id INTO v_fid;
    n := n+1;
    IF v_sev = 'blocker' THEN
      v_jn := 'qa-'||p_command_id||'-'||v_fid;
      INSERT INTO dev_journeys(name, area, kind, steps, source_bug, required, enabled)
      VALUES (v_jn, v_area, 'api',
              jsonb_build_array('TODO implement before completing #'||p_command_id||' — must reproduce QA blocker: '||left(coalesce(f->>'title',''),150)),
              p_command_id, false, true)
      ON CONFLICT (name) DO NOTHING;
    END IF;
  END LOOP;

  IF v_verdict='failed' THEN
    INSERT INTO dev_command_messages(command_id, sender, body)
    VALUES (p_command_id,'system','🔍 QA failed: '||n||' finding(s). Fix and re-run QA before completing.');
  ELSIF p_verdict='failed' AND v_verdict='running' THEN
    INSERT INTO dev_command_messages(command_id, sender, body)
    VALUES (p_command_id,'system','⏸ QA round did not count: all '||v_infra||' finding(s) were transport/contention errors, not product defects. Re-running.');
  END IF;

  RETURN jsonb_build_object('ok',true,'findings',n,'verdict',v_verdict,
    'infra_findings',v_infra,'real_findings',v_real,'scope',dev_qa_scope(p_command_id));
END $function$;

-- ── 1d. the transport layer speaks its own dialect ────────────────────────
-- PostgREST does not say "lock timeout"; it says PGRST002, "Could not query
-- the database for the schema cache". That is what it answered every RPC with
-- while this command ran — with the database healthy at 24 of 60 connections —
-- because 3,754 functions in public and another worker's continuous DDL kept
-- the cache reload from finishing. A gate that cannot read that sentence
-- cannot tell a dead transport from a broken feature.
create or replace function public._journey_contention_phrase(p_text text)
returns text
language sql
immutable
as $$
  select p
    from unnest(array[
      -- the database under contention
      'canceling statement due to lock timeout',
      'canceling statement due to statement timeout',
      'canceling statement due to user request',
      'deadlock detected',
      'could not serialize access',
      'could not obtain lock',
      'lock timeout',
      'statement timeout',
      'too many clients',
      'remaining connection slots',
      'server closed the connection',
      'terminating connection due to',
      'unable to check out connection from the pool',
      -- the transport in front of it
      'could not query the database for the schema cache',
      'schema cache',
      'pgrst002',
      'pgrst001',
      'pgrst000',
      '503 service unavailable',
      '504 gateway',
      'connection refused',
      'connection reset by peer'
    ]) p
   where position(p in lower(coalesce(p_text, ''))) > 0
   order by length(p) desc
   limit 1
$$;
