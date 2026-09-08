-- CHANGE #707 (6/6) — spec item 5: the three QA journeys.
--
-- "assign -> worker completes count -> task closed with metrics", "auto-assign"
-- and "override" are already asserted end-to-end by c707_fulfil_proof(), which
-- builds a real zone, real workers, real shifts and a real order, runs the REAL
-- RPCs against them and rolls every write back before it answers. So the
-- journeys do not re-simulate anything: each one runs that chain and reports
-- the slice of it that IS the journey. A journey that invents its own fixture
-- is a second implementation of the feature, and it drifts.
--
-- The mapping is by ASSERTION NAME rather than by index: renumbering the proof
-- must not silently re-point a journey at a different claim. A name the proof
-- no longer emits fails the journey — loudly — instead of passing vacuously,
-- which is the failure mode that made #686's five stubs report "skipped"
-- forever.

create or replace function public._c707_journey_slice(p_names text[], p_label text)
returns jsonb
language plpgsql
security definer set search_path to 'public' as $fn$
declare v_proof jsonb; v_found int; v_bad text; v_detail text;
begin
  v_proof := public.c707_fulfil_proof();

  select count(*)::int,
         string_agg(c->>'name', '; ') filter (where (c->>'ok')::boolean is not true),
         string_agg((c->>'name') || '=' || (c->>'ok'), ' | ' order by c->>'name')
    into v_found, v_bad, v_detail
    from jsonb_array_elements(v_proof->'checks') c
   where c->>'name' = any (p_names);

  -- A name that has gone missing is a FAILURE, never a pass with fewer checks.
  if v_found <> array_length(p_names, 1) then
    return jsonb_build_object('status','failed','evidence', jsonb_build_object('db_proof',
      p_label || ' — the proof no longer emits every assertion this journey names: expected '
      || array_length(p_names,1)::text || ', found ' || v_found::text
      || '. Named: ' || array_to_string(p_names, '; ')));
  end if;

  return jsonb_build_object(
    'status', case when v_bad is null then 'passed' else 'failed' end,
    'evidence', jsonb_build_object('db_proof',
      p_label || ' — ' || v_found::text || ' assertions, run against real rows and rolled back'
      || case when v_bad is null then '' else '. FAILED: ' || v_bad end
      || ' | ' || coalesce(v_detail,'')));
end $fn$;

comment on function public._c707_journey_slice(text[], text) is
  'CHANGE #707 — reports one named slice of c707_fulfil_proof() as a journey verdict.';

-- ── the three paths the spec names ──────────────────────────────────────────
create or replace function public._journey_c707_assign()
returns jsonb language sql security definer set search_path to 'public' as $fn$
  select public._c707_journey_slice(array[
    'a stage materialises one task',
    'asking twice returns the SAME task',
    'one OPEN task per order-stage',
    'the actor starts the task',
    'the item is counted onto the task',
    'the quantity lands on the task',
    'quantities accumulate, they do not replace',
    'nothing counted yet says so in words',
    'productivity answers for an authorised caller',
    'the proof workers appear on it',
    'a worker with no hours reads the backend dash',
    'the board answers for an authorised caller',
    'the board offers only on-shift workers as chips'
  ], 'assign -> the worker counts -> the task closes carrying its metrics')
$fn$;

create or replace function public._journey_c707_auto()
returns jsonb language sql security definer set search_path to 'public' as $fn$
  select public._c707_journey_slice(array[
    'auto-assign picks an on-shift counter',
    'an unmarked worker is never picked',
    'a packer is not picked for the count stage',
    'the pack stage reaches the packer',
    'round-robin fans out to the idle worker',
    'an ASSIGNED task keeps its worker',
    'an UNASSIGNED task adopts the actor'
  ], 'auto-assign: round-robin across the on-shift roster, by stage role')
$fn$;

create or replace function public._journey_c707_override()
returns jsonb language sql security definer set search_path to 'public' as $fn$
  select public._c707_journey_slice(array[
    'a stranger cannot close the stage',
    'the refusal names the assigned worker',
    'the refused stage is still open',
    'a partner override CAN close it',
    'the close is reported as an override',
    'the override is stamped on the row',
    'the override keeps the name it was taken from',
    'a fresh unowned stage is NOT an exception yet',
    'an AGED unowned stage is an exception',
    'the exception reason is registered and enabled',
    'assigning it clears the exception',
    'the ops board owner block names the worker'
  ], 'the guard: a stranger is refused by name, a partner override is logged')
$fn$;

-- ── the probe learns the three names ────────────────────────────────────────
-- dev_journey_probe dispatches by name before it reaches its external-proof
-- branch; a name it does not know reports 'skipped — browser runner needs 2
-- more run(s)' forever, which is how a stub becomes a permanent no-op.
do $mig$
declare v_src text;
begin
  select prosrc into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='dev_journey_probe';
  if v_src is null then
    raise exception 'dev_journey_probe is missing — the journey layer moved';
  end if;
  if position('_journey_c707_assign' in v_src) = 0 then
    v_src := replace(v_src,
      '  perform public._dev_guard();',
      '  perform public._dev_guard();' || E'\n\n' ||
      '  -- CHANGE #707 — the fulfilment task journeys. Each reports one named' || E'\n' ||
      '  -- slice of c707_fulfil_proof(), which runs the real RPCs against real' || E'\n' ||
      '  -- rows and rolls every write back, so nothing here simulates anything.' || E'\n' ||
      '  if p_name = ''qa-707-assign''   then return public._journey_c707_assign();   end if;' || E'\n' ||
      '  if p_name = ''qa-707-auto''     then return public._journey_c707_auto();     end if;' || E'\n' ||
      '  if p_name = ''qa-707-override'' then return public._journey_c707_override(); end if;');
    execute format(
      'create or replace function public.dev_journey_probe(p_name text) returns jsonb '
      'language plpgsql security definer set search_path to ''public'' as %L', v_src);
  end if;
end $mig$;

-- ── the rows ────────────────────────────────────────────────────────────────
-- required stays FALSE: a journey earns required=true by passing green TWICE,
-- and the backend promotes it. Shipping one pre-required would be marking your
-- own homework.
insert into public.dev_journeys (name, area, kind, steps, assertions, source_bug, required, enabled)
values
  ('qa-707-assign', 'fulfillment', 'api',
   jsonb_build_array(
     'The board discovers an order sitting at a stage this zone runs and materialises ONE open task for it.',
     'The partner assigns that stage to an on-shift worker.',
     'The worker starts it, then counts items onto it (voice or barcode — the writer binds the actor to the task).',
     'The stage closes and the day''s productivity reports the tasks, the items/hour and the variance.'),
   jsonb_build_array(
     'Asking for the same order-stage twice returns the SAME task, never a second one.',
     'Counted quantities ACCUMULATE onto the task rather than replacing the last write.',
     'A worker with no closed task reads the backend dash, not a zero this app invented.',
     'The board offers only workers the backend says are on shift.'),
   null, false, true),
  ('qa-707-auto', 'fulfillment', 'api',
   jsonb_build_array(
     'A zone turns auto-assign on.',
     'The board discovers unowned stages and hands each to the next on-shift worker for that stage''s role.'),
   jsonb_build_array(
     'A worker with no shift row marked present is never picked.',
     'A packer is not picked for the count stage, and the pack stage reaches the packer.',
     'Round-robin fans out to the idle worker rather than piling onto the first one.',
     'An ALREADY ASSIGNED task keeps its worker; only an unassigned one adopts the actor.'),
   null, false, true),
  ('qa-707-override', 'fulfillment', 'api',
   jsonb_build_array(
     'A stage is assigned to one worker and a DIFFERENT person tries to close it.',
     'The partner closes it as an override instead.',
     'A stage nobody owns ages past the zone''s threshold.'),
   jsonb_build_array(
     'The stranger is refused with the backend''s own sentence, which NAMES the assigned worker, and the stage stays open.',
     'A partner override closes it, is reported as an override, and is stamped on the row with the name it was taken from.',
     'A fresh unowned stage is not an exception; an aged one is, and assigning it clears it.',
     'Every ops board row carries the owner block.'),
   null, false, true)
on conflict (name) do update
   set area       = excluded.area,
       kind       = excluded.kind,
       steps      = excluded.steps,
       assertions = excluded.assertions,
       enabled    = excluded.enabled;
