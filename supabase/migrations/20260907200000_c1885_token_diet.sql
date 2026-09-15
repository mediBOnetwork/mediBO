-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #1885 — A TOKEN READING IS MEASURED, OR IT DOES NOT EXIST
--
-- #1864's series carries a sample at 22:31 IST reading exactly +600,000 input
-- and +40,000 output. No CLI emits round numbers like that: they were the
-- BUILDER'S ESTIMATE, typed straight into `devcmd.sh heartbeat`'s third and
-- fourth arguments, and once stored they were indistinguishable from a reading.
-- Every downstream number quoted them as fact — the cost cards, the anomaly
-- scan's medians, the per-size-class budgets and the ETA estimator.
--
-- The runner half of the fix is that the heartbeat no longer believes its own
-- caller: it PARSES this slot's transcript, and when the transcript cannot be
-- read it sends no token fields at all, so a missing reading leaves a GAP in
-- the series rather than a plausible number.
--
-- This is the data half, and it has two jobs:
--   1. remember which of the 638 existing samples were guesses, and
--   2. make sure a guess can never again reach a card that says "cost".
--
-- HOW A GUESS IS RECOGNISED. A parsed delta is a ragged number: 27,551 in and
-- 3,904 out. A typed one is round on BOTH axes at once, because a person picks
-- both. So the test is exactly the spec's: the movement since this command's
-- previous sample is a non-zero multiple of 100,000 on input AND a non-zero
-- multiple of 10,000 on output. Round on one axis alone is left ALONE — that
-- happens by chance often enough to matter, and a mark that over-claims is the
-- same failure as the number it is replacing.
--
-- HOW EXCLUSION IS MADE TOTAL. Four functions read this series
-- (_dev_token_phase_rows, _dev_token_step_rows, _dev_token_span,
-- _dev_token_waste_rows) and any future one will too. Adding `and not
-- estimated` to each is a filter that the fifth reader forgets. So the physical
-- rows move to dev_token_sample_raw and dev_token_sample BECOMES the filtered
-- view: every existing reader keeps its query verbatim and stops seeing guesses
-- on the same day, and the filter cannot be forgotten because there is nothing
-- to remember. The view is a simple single-table filter, so it stays
-- auto-updatable — _dev_token_sample_trg's INSERT and dev_token_anomaly_scan's
-- retention DELETE go on working untouched, and are deliberately NOT rewritten.
--
-- Idempotent: safe to replay on live, and safe to replay on itself.
-- ═══════════════════════════════════════════════════════════════════════════

do $mig$
declare v_marked int := 0;
begin
  -- Nothing to do on a database that never had the dashboard (#1820 landed on
  -- the dev-queue control plane; a replay on live must not invent the table).
  if to_regclass('public.dev_token_sample') is null
     and to_regclass('public.dev_token_sample_raw') is null then
    raise notice 'c1885: no dev_token_sample here — nothing to migrate';
    return;
  end if;

  -- ── 1. the physical table, renamed once ──────────────────────────────────
  if to_regclass('public.dev_token_sample_raw') is null then
    execute 'alter table public.dev_token_sample rename to dev_token_sample_raw';
  end if;

  -- ── 2. the flag ──────────────────────────────────────────────────────────
  execute 'alter table public.dev_token_sample_raw
             add column if not exists estimated boolean not null default false';

  -- ── 3. mark the guesses that are already in the series ───────────────────
  -- Only ever sets the flag; a row a human has cleared stays cleared.
  with d as (
    select s.id,
           s.tokens_in  - lag(s.tokens_in)  over (partition by s.command_id order by s.at, s.id) as d_in,
           s.tokens_out - lag(s.tokens_out) over (partition by s.command_id order by s.at, s.id) as d_out
      from public.dev_token_sample_raw s
  )
  update public.dev_token_sample_raw t
     set estimated = true
    from d
   where d.id = t.id
     and t.estimated = false
     and d.d_in  is not null and d.d_in  > 0 and d.d_in  % 100000 = 0
     and d.d_out is not null and d.d_out > 0 and d.d_out %  10000 = 0;
  get diagnostics v_marked = row_count;
  raise notice 'c1885: marked % sample(s) estimated', v_marked;

  -- ── 4. the name every reader already uses becomes the filtered view ──────
  if to_regclass('public.dev_token_sample') is null then
    execute 'create view public.dev_token_sample as
               select id, command_id, at, tokens_in, tokens_out, estimated
                 from public.dev_token_sample_raw
                where estimated = false';
  end if;
end $mig$;

comment on view public.dev_token_sample is
  'CMD #1885: the MEASURED token series. Physical rows live in '
  'dev_token_sample_raw; a row flagged estimated=true was a builder''s typed '
  'guess (round on both axes) and is excluded here so no cost card, median or '
  'anomaly factor can quote it. Read the raw table directly only to audit the '
  'guesses themselves.';

-- ── 5. the audit door ───────────────────────────────────────────────────────
-- Strings, not raw numbers: the dashboard renders this verbatim like every
-- other card on that screen.
create or replace function public.dev_token_estimated_report()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'ok', true,
    'has', true,
    'title', 'Estimated samples (excluded)',
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'label', 'Command #' || r.command_id,
               'value', to_char(r.n, 'FM999,999') || ' sample' || case when r.n = 1 then '' else 's' end,
               'sub',   'first ' || to_char(r.first_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
               'tone',  'warning')
             order by r.n desc, r.command_id desc)
        from (select command_id, count(*) n, min(at) first_at
                from public.dev_token_sample_raw
               where estimated group by command_id limit 20) r), '[]'::jsonb),
    'footnote', (select case when count(*) = 0
                   then 'No estimated samples — every reading on this screen was parsed from a CLI transcript.'
                   else to_char(count(*), 'FM999,999') || ' sample(s) were typed estimates, not readings, and are excluded from every figure here.'
                 end from public.dev_token_sample_raw where estimated));
$$;
revoke all on function public.dev_token_estimated_report() from public, anon;
grant execute on function public.dev_token_estimated_report() to authenticated, service_role;

-- ── 6. THE SCREEN SAYS SO ITSELF ────────────────────────────────────────────
-- A flag nobody can see is a flag nobody trusts. dev_token_report() is the one
-- payload the Token dashboard renders, and it already draws a `tiles` section
-- from label/value/sub/tone — the exact shape dev_token_estimated_report()
-- returns. So the excluded guesses get their own tile block on the screen that
-- excludes them, and NO Dart changes: the renderer walks sections[] by kind and
-- has drawn tiles since #1820.
--
-- Done as a wrapper rather than by re-issuing 500 lines of the original: the
-- core keeps its own definition and its own future edits, and this file stays
-- replayable on top of itself.
do $wrap$
begin
  if to_regclass('public.dev_token_sample_raw') is null then return; end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = '_dev_token_report_core') then
    if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname = 'public' and p.proname = 'dev_token_report') then
      execute 'alter function public.dev_token_report(text) rename to _dev_token_report_core';
    else
      return;   -- no dashboard on this database
    end if;
  end if;
end $wrap$;

do $wrap2$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = '_dev_token_report_core') then
    return;
  end if;
  execute $fn$
    create or replace function public.dev_token_report(p_scope text default 'today')
    returns jsonb language plpgsql stable security definer set search_path to 'public' as $body$
    declare v jsonb; v_est jsonb; v_n int;
    begin
      v := public._dev_token_report_core(p_scope);
      select count(*) into v_n from public.dev_token_sample_raw where estimated;
      if v_n = 0 then return v; end if;
      v_est := public.dev_token_estimated_report();
      return jsonb_set(v, '{sections}',
        coalesce(v->'sections','[]'::jsonb) || jsonb_build_array(jsonb_build_object(
          'key','estimated','kind','tiles',
          'title', v_est->>'title',
          'sub',   v_est->>'footnote',
          'rows',  coalesce(v_est->'rows','[]'::jsonb),
          'empty_label','No estimated samples.')));
    end $body$;
  $fn$;
  execute 'revoke all on function public.dev_token_report(text) from public, anon';
  execute 'grant execute on function public.dev_token_report(text) to authenticated, service_role';
end $wrap2$;
