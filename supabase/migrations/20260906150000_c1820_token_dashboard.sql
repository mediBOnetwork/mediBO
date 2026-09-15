-- replay-target: control-plane
--
-- THE PRODUCTION PASS RUNS ON THIS FILE TOO — SO THE FILE SAYS NO ITSELF.
-- `-- replay-target: control-plane` above only ADDS the control-plane pass;
-- scripts/migration_replay.sh applies every pending file to production first,
-- whatever it declares. #1761 moved dev_commands / dev_context_event /
-- dev_journey_runs / deploy_queue to medibo-dev and dropped them here, so a
-- file that names them dies on production at CREATE time and takes the whole
-- batch with it (#1817 learned this in batch 599). No dev_commands on this
-- database => nothing here belongs on it => exit 0.
-- THE GUARD IS project_identity, NOT to_regclass('dev_commands'). #1817 used
-- the table's absence and that is not enough: production still carries the
-- pre-#1761 dev_commands as a LEFTOVER — 701 of its 702 rows are literally
-- titled 'fixture N' — so a dev_commands check passes there and this file
-- would install a trigger and a cron task on the wrong database. Only the
-- control plane carries dev_runner_config.project_identity.role =
-- 'dev-queue control plane', so that is what is asked. Two statements, because
-- a table referenced inside one CASE still has to exist at plan time.
select coalesce(to_regclass('public.dev_runner_config')::text,'') = '' as c1820_no_cfg \gset
\if :c1820_no_cfg
\echo 'c1820: no dev_runner_config here — control-plane migration, nothing to apply'
\quit
\endif
select not exists (select 1 from public.dev_runner_config
                    where key = 'project_identity'
                      and value->>'role' = 'dev-queue control plane') as c1820_not_cp \gset
\if :c1820_not_cp
\echo 'c1820: not the dev-queue control plane — nothing to apply'
\quit
\endif

-- ═══════════════════════════════════════════════════════════════════════════
-- CMD #1820 — TOKEN DASHBOARD: WHERE EVERY TOKEN AND RUPEE WENT.
--
-- Om pays for these tokens and could see two things: a live quota percentage
-- and the context-economy strip. Neither answers "where did today go".
--
-- ACCURACY IS THE WHOLE POINT, so three rules are wired into the SQL rather
-- than into a comment:
--
--   1. A COMMAND'S SPEND IS BOOKED TO THE DAY IT FINISHED (started_at, then
--      created_at, when it has not). That is the only booking rule under which
--      the dashboard total equals `select sum(...) from dev_commands where
--      <same window>` — the reconciliation the spec demands. Proration across
--      days would need a token history that does not exist for old rows, and
--      inventing one is exactly what this dashboard exists to expose.
--
--   2. INTRA-COMMAND ATTRIBUTION IS MEASURED, NEVER SPLIT. Tokens per phase
--      and tokens per step come from dev_token_sample — a real reading taken
--      every time the heartbeat moves a row's token counters. A command with
--      no samples contributes to an explicit "not yet attributed" row, so the
--      phase table still sums to the window total with no silent remainder.
--      It never gets a share of the total apportioned to it by duration.
--
--   3. EVERY FIGURE THAT CANNOT BE MEASURED PRINTS '—'. There is no fallback
--      estimate anywhere in this file.
--
-- The self-check recomputes the window's rupees a SECOND way — tokens ×
-- model_rates × usd_inr, per row, from the same config dev_cmd_heartbeat
-- stamps cost_inr with — and reports the drift. Over 1% is drawn in danger
-- tone with the two totals side by side.
--
-- Money note: worker_pool.billing_mode is 'max_subscription', so these rupees
-- are API-EQUIVALENT VALUE, not cash leaving the account. The dashboard says
-- so on its face, from dev_runner_config, not from a string in Dart.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. THE MEASURED SERIES ──────────────────────────────────────────────────
-- One row per observed movement of a command's token counters. dev_cmd_heartbeat
-- is the fleet's hottest function and every worker calls it every 60s; this
-- captures the same beats WITHOUT editing it, by hanging off the two columns it
-- writes. A trigger that can never raise: any failure returns NEW untouched.
create table if not exists public.dev_token_sample (
  id          bigserial primary key,
  command_id  bigint      not null,
  at          timestamptz not null default now(),
  tokens_in   bigint      not null default 0,
  tokens_out  bigint      not null default 0
);
create index if not exists dev_token_sample_cmd_at on public.dev_token_sample (command_id, at);
create index if not exists dev_token_sample_at     on public.dev_token_sample (at);

create or replace function public._dev_token_sample_cfg()
returns jsonb language sql stable as $$
  select coalesce((select value->'token_sample' from public.dev_runner_config where key='worker_pool'),
                  '{}'::jsonb)
$$;

create or replace function public._dev_token_sample_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare v_gap int; v_new bigint; v_old bigint;
begin
  v_new := coalesce(new.cost_input_tokens,0) + coalesce(new.cost_output_tokens,0);
  v_old := coalesce(old.cost_input_tokens,0) + coalesce(old.cost_output_tokens,0);
  -- Only forward movement is a reading. A reset (a row re-claimed from zero)
  -- is not a negative sample; it simply starts the series again.
  if v_new <= v_old then return new; end if;
  v_gap := greatest(coalesce((public._dev_token_sample_cfg()->>'min_gap_s')::int, 45), 5);
  if exists (select 1 from public.dev_token_sample s
              where s.command_id = new.id and s.at > now() - make_interval(secs => v_gap)) then
    return new;
  end if;
  insert into public.dev_token_sample (command_id, at, tokens_in, tokens_out)
  values (new.id, now(), coalesce(new.cost_input_tokens,0), coalesce(new.cost_output_tokens,0));
  return new;
exception when others then
  return new;  -- a dashboard must never be able to stop a heartbeat
end $$;

drop trigger if exists trg_dev_token_sample on public.dev_commands;
create trigger trg_dev_token_sample
  after update of cost_input_tokens, cost_output_tokens on public.dev_commands
  for each row execute function public._dev_token_sample_trg();

-- Anomalies are remembered so the WhatsApp alert fires once per command, not
-- once per dashboard open.
create table if not exists public.dev_token_anomaly (
  command_id     bigint primary key,
  at             timestamptz not null default now(),
  tokens         bigint  not null,
  median_tokens  bigint  not null,
  factor         numeric not null,
  size_class     text,
  title          text,
  notified_at    timestamptz
);
create index if not exists dev_token_anomaly_at on public.dev_token_anomaly (at desc);

-- ── 2. MONEY AND FORMAT HELPERS ─────────────────────────────────────────────
-- Every rupee, token count, percentage and ratio on this screen is a STRING
-- produced here. Dart formats nothing.
create or replace function public._dev_inr(p numeric, p_paise boolean default false)
returns text language sql immutable as $$
  select case
    when p is null then '—'
    when p_paise   then '₹' || to_char(round(p, 2), 'FM999,999,999,990.00')
    else                '₹' || to_char(round(p),    'FM999,999,999,990')
  end
$$;

create or replace function public._dev_pct(p numeric, p_dp int default 1)
returns text language sql immutable as $$
  select case when p is null then '—'
              else trim(to_char(p, case when p_dp = 0 then 'FM999990' else 'FM999990.0' end)) || '%' end
$$;

create or replace function public._dev_tok(p numeric)
returns text language sql stable as $$
  select case when p is null then '—' else public._fmt_tokens(p) end
$$;

-- The rate card dev_cmd_heartbeat stamps cost_inr with. Reading it here is what
-- makes the drift self-check a real second opinion instead of a tautology: the
-- heartbeat priced each beat at the rate live AT THAT MOMENT, this prices the
-- finished row at today's rate, and the difference is the drift.
create or replace function public._dev_rate_for(p_model text, p_mode text)
returns jsonb language sql stable as $$
  with cfg as (select coalesce(value,'{}'::jsonb) v from public.dev_runner_config where key='model_rates'),
       r as (select coalesce((select v->'models'->coalesce(nullif(p_model,''),'claude-opus-5') from cfg),
                             (select v->'models'->'claude-opus-5' from cfg),
                             '{}'::jsonb) m,
                    coalesce((select (v->>'usd_inr')::numeric from cfg), 88) fx)
  select jsonb_build_object(
    'in',  coalesce(case when p_mode='fast' and (m ? 'fast_in')  then (m->>'fast_in')::numeric  else (m->>'in')::numeric  end, 0),
    'out', coalesce(case when p_mode='fast' and (m ? 'fast_out') then (m->>'fast_out')::numeric else (m->>'out')::numeric end, 0),
    'fx',  fx)
  from r
$$;

create or replace function public._dev_inr_recompute(p_in bigint, p_out bigint, p_model text, p_mode text)
returns numeric language sql stable as $$
  select round((coalesce(p_in,0) * (public._dev_rate_for(p_model, p_mode)->>'in')::numeric
              + coalesce(p_out,0) * (public._dev_rate_for(p_model, p_mode)->>'out')::numeric)
              * (public._dev_rate_for(p_model, p_mode)->>'fx')::numeric / 1000000.0, 2)
$$;

-- THE BOOKING RULE, in one place so the dashboard and the proof script cannot
-- drift apart.
create or replace function public._dev_book_at(p_finished timestamptz, p_started timestamptz, p_created timestamptz)
returns timestamptz language sql immutable as $$
  select coalesce(p_finished, p_started, p_created)
$$;

-- ── 3. PHASE AND STEP ATTRIBUTION (measured from dev_token_sample) ──────────
-- The window's commands with the four boundaries a phase can be read from:
-- the first step that landed, the push into the merge lane, and the span of
-- journey runs. Nothing here is a guess about what the agent was doing — each
-- boundary is a timestamp some other part of the system already wrote down.
create or replace function public._dev_token_cmd_window(p_from timestamptz, p_to timestamptz)
returns table (
  id bigint, model text, mode text, size_class text, area text, status text,
  tin bigint, tout bigint, inr numeric, started_at timestamptz, finished_at timestamptz,
  first_step_at timestamptz, push_at timestamptz, qa_from timestamptz, qa_to timestamptz)
language sql stable as $$
  select c.id,
         coalesce(nullif(c.actual_model,''), nullif(c.model,''), 'claude-opus-5'),
         c.price_mode,
         coalesce(nullif(c.size_class,''), 'normal'),
         nullif(c.area,''),
         c.status,
         coalesce(c.cost_input_tokens,0), coalesce(c.cost_output_tokens,0), coalesce(c.cost_inr,0),
         c.started_at, c.finished_at,
         (select min((s->>'at')::timestamptz)
            from jsonb_array_elements(coalesce(c.steps,'[]'::jsonb)) s
           where s->>'status' = 'done' and coalesce(s->>'at','') <> ''),
         (select min(q.pushed_at) from public.deploy_queue q where q.command_id = c.id),
         (select min(j.at) from public.dev_journey_runs j where j.command_id = c.id),
         (select max(j.at) from public.dev_journey_runs j where j.command_id = c.id)
    from public.dev_commands c
   where public._dev_book_at(c.finished_at, c.started_at, c.created_at) >= p_from
     and public._dev_book_at(c.finished_at, c.started_at, c.created_at) <  p_to
$$;

create or replace function public._dev_token_phase_rows(p_from timestamptz, p_to timestamptz)
returns table (phase text, tokens bigint, inr numeric, cmds int)
language sql stable as $$
  with cmd as (select * from public._dev_token_cmd_window(p_from, p_to)),
  d as (
    select s.command_id, s.at,
           greatest(s.tokens_in  - coalesce(lag(s.tokens_in)  over w, 0), 0) din,
           greatest(s.tokens_out - coalesce(lag(s.tokens_out) over w, 0), 0) dout
      from public.dev_token_sample s
     where s.command_id in (select id from cmd)
    window w as (partition by s.command_id order by s.at)
  ),
  tagged as (
    select c.id, c.model, c.mode, d.din, d.dout,
           case
             when c.first_step_at is not null and d.at <  c.first_step_at then 'planning'
             when c.qa_from is not null and d.at >= c.qa_from
                                       and d.at <= coalesce(c.qa_to, d.at)  then 'qa'
             when c.push_at  is not null and d.at >= c.push_at              then 'merge_deploy'
             else 'building'
           end ph
      from d join cmd c on c.id = d.command_id
  ),
  per as (
    select id, ph, sum(din) din, sum(dout) dout,
           sum(sum(din + dout)) over (partition by id) attributed
      from tagged group by id, ph
  ),
  -- A command's measured deltas can never be allowed to exceed what the row
  -- itself says it spent (a re-claim resets the counters and restarts the
  -- series), so the attributed part is capped and the rest is stated as
  -- unattributed rather than quietly rescaled.
  capped as (
    select p.id, p.ph,
           case when p.attributed > 0
                then floor((p.din + p.dout)::numeric
                     * least(c.tin + c.tout, p.attributed) / p.attributed)::bigint
                else 0 end tok,
           c.model, c.mode,
           case when p.attributed > 0 then p.din::numeric * least(c.tin + c.tout, p.attributed) / p.attributed else 0 end din,
           case when p.attributed > 0 then p.dout::numeric * least(c.tin + c.tout, p.attributed) / p.attributed else 0 end dout
      from per p join cmd c on c.id = p.id
  ),
  rest as (
    select c.id, 'unattributed'::text ph,
           greatest(c.tin + c.tout - coalesce((select sum(k.tok) from capped k where k.id = c.id), 0), 0) tok,
           c.model, c.mode,
           greatest(c.tin  - coalesce((select sum(k.din)  from capped k where k.id = c.id), 0), 0) din,
           greatest(c.tout - coalesce((select sum(k.dout) from capped k where k.id = c.id), 0), 0) dout
      from cmd c
  ),
  allrows as (select * from capped union all select * from rest)
  select ph,
         sum(tok)::bigint,
         round(sum(public._dev_inr_recompute(round(din)::bigint, round(dout)::bigint, model, mode)), 2),
         count(distinct id) filter (where tok > 0)::int
    from allrows
   group by ph
$$;

-- Which STEP of the plan a command's tokens went into. Boundaries are the
-- step's own `at` stamps (devcmd.sh step_done writes them); the first step's
-- window opens at started_at.
create or replace function public._dev_token_step_rows(p_from timestamptz, p_to timestamptz)
returns table (step_n int, tokens bigint, cmds int, top_title text, top_tokens bigint)
language sql stable as $$
  with cmd as (select * from public._dev_token_cmd_window(p_from, p_to)),
  steps as (
    select c.id, (s->>'n')::int n, s->>'title' title, (s->>'at')::timestamptz at
      from public.dev_commands c
      join cmd on cmd.id = c.id,
           lateral jsonb_array_elements(coalesce(c.steps,'[]'::jsonb)) s
     where s->>'status' = 'done' and coalesce(s->>'at','') <> ''
  ),
  bounds as (
    select st.id, st.n, st.title, st.at,
           coalesce(lag(st.at) over (partition by st.id order by st.n), c.started_at) from_at
      from steps st join cmd c on c.id = st.id
  ),
  d as (
    select s.command_id, s.at,
           greatest((s.tokens_in + s.tokens_out)
                    - coalesce(lag(s.tokens_in + s.tokens_out) over (partition by s.command_id order by s.at), 0), 0) tok
      from public.dev_token_sample s
     where s.command_id in (select id from cmd)
  ),
  per as (
    select b.n, b.id, b.title,
           coalesce(sum(d.tok) filter (where d.at > b.from_at and d.at <= b.at), 0) tok
      from bounds b left join d on d.command_id = b.id
     group by b.n, b.id, b.title
  )
  select n,
         sum(tok)::bigint,
         count(*) filter (where tok > 0)::int,
         (array_agg(title order by tok desc))[1],
         max(tok)
    from per
   where tok > 0
   group by n
$$;

-- ── 4. WASTE ATTRIBUTION ────────────────────────────────────────────────────
-- The buckets are DISJOINT and are taken out of each command's own total in a
-- fixed order, so bucket tokens + "everything else" is the window total exactly
-- — no overlap, no unexplained remainder. A bucket that cannot yet be measured
-- (it needs the dev_token_sample series, which starts the day this ships)
-- reports '—' and its spend stays inside "everything else". It is never
-- apportioned.
create or replace function public._dev_token_waste_rows(p_from timestamptz, p_to timestamptz)
returns table (bucket text, tokens bigint, inr numeric, cmds int, measured boolean, detail text)
language sql stable as $$
  with cmd as (select * from public._dev_token_cmd_window(p_from, p_to)),
  raw as (
    select c.id, c.model, c.mode, c.tin + c.tout total, c.status,
           coalesce(dc.wait_turn_tokens, 0) waiting,
           coalesce((select sum(r.tokens_added) from public.dev_resume_ledger r
                      where r.command_id = c.id and coalesce(r.tokens_added,0) > 0), 0) resumed,
           -- The abandoned work in front of the LAST retry marker, read from the
           -- sample series. Zero until a retried command has samples.
           coalesce((select max(s.tokens_in + s.tokens_out) from public.dev_token_sample s
                      where s.command_id = c.id
                        and s.at <= (select max(m.created_at) from public.dev_command_messages m
                                      where m.command_id = c.id
                                        and (m.body like '%Auto-heal: retry%' or m.body like '%Re-queued%'))), 0) retried,
           -- Everything spent after a QA round came back failed.
           coalesce((select sum(x.d) from (
                      select greatest((s.tokens_in + s.tokens_out)
                             - coalesce(lag(s.tokens_in + s.tokens_out) over (order by s.at), 0), 0) d, s.at
                        from public.dev_token_sample s where s.command_id = c.id) x
                     where x.at > (select min(m.created_at) from public.dev_command_messages m
                                    where m.command_id = c.id and m.body like '%QA failed%')), 0) requa,
           (c.status in ('failed','cancelled','superseded')) never_shipped,
           coalesce(dc.wait_turns, 0) wait_turns,
           (dc.needs_input_kind = 'waiting_burn') burn_kill,
           greatest(coalesce(dc.retry_count,0) + coalesce(dc.auto_retry_count,0), 0) retries,
           coalesce(dc.qa_rounds, 0) qa_rounds
      from cmd c join public.dev_commands dc on dc.id = c.id
  ),
  -- Take the buckets out of the row's own total, in order, so they can never
  -- overlap or exceed it.
  cut as (
    select id, model, mode, total, status, never_shipped, wait_turns, burn_kill, retries, qa_rounds,
           least(waiting, total)                                                        b_wait,
           least(resumed, greatest(total - least(waiting, total), 0))                   b_resume,
           least(retried, greatest(total - least(waiting, total)
                                         - least(resumed, greatest(total - least(waiting,total),0)), 0)) b_retry
      from raw
  ),
  cut2 as (
    select c.*, least(r.requa, greatest(c.total - c.b_wait - c.b_resume - c.b_retry, 0)) b_qa
      from cut c join raw r on r.id = c.id
  ),
  cut3 as (
    select c.*,
           case when c.never_shipped
                then greatest(c.total - c.b_wait - c.b_resume - c.b_retry - c.b_qa, 0) else 0 end b_fail
      from cut2 c
  ),
  final as (
    select c.*, greatest(c.total - c.b_wait - c.b_resume - c.b_retry - c.b_qa - c.b_fail, 0) b_rest
      from cut3 c
  ),
  -- Long form, one row per bucket per command, so pricing uses that command's
  -- own rate card.
  long as (
    select 'waiting'  b, id, model, mode, b_wait   t from final union all
    select 'resumes',   id, model, mode, b_resume    from final union all
    select 'retries',   id, model, mode, b_retry     from final union all
    select 'repeat_qa', id, model, mode, b_qa        from final union all
    select 'failure',   id, model, mode, b_fail      from final union all
    select 'rest',      id, model, mode, b_rest      from final
  ),
  agg as (
    select b, sum(t)::bigint tok, count(*) filter (where t > 0)::int n
      from long group by b
  ),
  -- Rupees for a bucket are the bucket's share of that command's own rupees —
  -- priced from the row's model, never from a blended average.
  money as (
    select l.b, round(sum(case when f.total > 0 then f_inr.inr * l.t / f.total else 0 end), 2) inr
      from long l
      join final f on f.id = l.id
      join (select c.id, c.inr from public._dev_token_cmd_window(p_from, p_to) c) f_inr on f_inr.id = l.id
     group by l.b
  ),
  smp as (select count(*) n from public.dev_token_sample s
           where s.command_id in (select id from cmd))
  select a.b, a.tok, m.inr, a.n,
         case a.b
           when 'retries'   then (select n from smp) > 0
           when 'repeat_qa' then (select n from smp) > 0
           else true
         end,
         case a.b
           when 'waiting'   then (select count(*) filter (where b_wait > 0)::text from final)
                                 || ' command(s) burned tokens while asleep · '
                                 || (select count(*) filter (where burn_kill)::text from final)
                                 || ' killed by the waiting-burn backstop'
           when 'resumes'   then 'measured per resumed segment (dev_resume_ledger)'
           when 'retries'   then (select count(*) filter (where retries > 0)::text from final) || ' command(s) retried'
           when 'repeat_qa' then (select count(*) filter (where qa_rounds > 1)::text from final) || ' command(s) needed a second QA round'
           when 'failure'   then (select count(*) filter (where never_shipped)::text from final) || ' command(s) never shipped'
           else 'the window total less every bucket above'
         end
    from agg a join money m on m.b = a.b
$$;

-- ── 5. WHAT A COMMAND WILL PROBABLY COST, BEFORE IT IS APPROVED ─────────────
-- Median of comparable finished builds, nudged by how this spec compares on the
-- two things known before a worker ever claims it: how long the spec is, and
-- how many files the predictor thinks it touches. Fewer than `min_n` comparable
-- builds and it refuses to guess.
create or replace function public.dev_cmd_cost_estimate(
  p_size_class text default 'normal',
  p_spec_chars int default null,
  p_files int default null,
  p_days int default 60)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v jsonb; v_med numeric; v_p25 numeric; v_p75 numeric; v_n int;
        v_spec numeric; v_fil numeric; v_f numeric := 1; v_fs numeric := 1; v_ff numeric := 1;
        v_tok numeric; v_min_n int;
begin
  v_min_n := greatest(coalesce((public._dev_token_sample_cfg()->>'estimate_min_n')::int, 5), 2);
  select count(*),
         percentile_cont(0.5)  within group (order by coalesce(cost_input_tokens,0)+coalesce(cost_output_tokens,0)),
         percentile_cont(0.25) within group (order by coalesce(cost_input_tokens,0)+coalesce(cost_output_tokens,0)),
         percentile_cont(0.75) within group (order by coalesce(cost_input_tokens,0)+coalesce(cost_output_tokens,0)),
         percentile_cont(0.5)  within group (order by length(coalesce(spec,''))),
         percentile_cont(0.5)  within group (order by coalesce(array_length(predicted_files,1),0))
    into v_n, v_med, v_p25, v_p75, v_spec, v_fil
    from dev_commands
   where status = 'completed'
     and coalesce(size_class,'normal') = coalesce(nullif(p_size_class,''),'normal')
     and coalesce(cost_input_tokens,0) + coalesce(cost_output_tokens,0) > 0
     and finished_at >= now() - make_interval(days => greatest(coalesce(p_days,60),7));

  if coalesce(v_n,0) < v_min_n or coalesce(v_med,0) <= 0 then
    return jsonb_build_object('ok', true, 'has', false,
      'value', '—', 'sub', 'not enough finished ' || coalesce(nullif(p_size_class,''),'normal')
                            || ' builds to compare (' || coalesce(v_n,0) || ')');
  end if;

  if p_spec_chars is not null and coalesce(v_spec,0) > 0 then
    v_fs := least(greatest(p_spec_chars::numeric / v_spec, 0.5), 2.0);
  end if;
  if p_files is not null and coalesce(v_fil,0) > 0 then
    v_ff := least(greatest(p_files::numeric / v_fil, 0.5), 2.0);
  end if;
  -- Geometric mean: a long spec that touches many files is one signal seen
  -- twice, not two independent reasons to double the number.
  v_f   := sqrt(v_fs * v_ff);
  v_tok := round(v_med * v_f);

  v := public._dev_rate_for('claude-opus-5', 'standard');
  return jsonb_build_object('ok', true, 'has', true,
    'tokens', v_tok,
    'value', public._dev_tok(v_tok) || ' · ' || public._dev_inr(public._dev_inr_recompute(
                round(v_tok * 0.82)::bigint, round(v_tok * 0.18)::bigint, 'claude-opus-5','standard')),
    'range', public._dev_tok(round(v_p25 * v_f)) || ' – ' || public._dev_tok(round(v_p75 * v_f)),
    'sub', 'median of ' || v_n || ' finished ' || coalesce(nullif(p_size_class,''),'normal')
           || ' builds × ' || trim(to_char(v_f,'FM990.00')) || ' (spec length, predicted files)');
end $$;

-- ── 6. THE ANOMALY WATCH ────────────────────────────────────────────────────
-- A command costing `factor`× the median of its own size class is recorded once
-- and told to Om once, down the same road every other runner alert takes.
create or replace function public.dev_token_anomaly_scan()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_factor numeric; v_found int := 0; v_sent int := 0; v_keep int; r record;
begin
  v_factor := greatest(coalesce((public._dev_token_sample_cfg()->>'anomaly_factor')::numeric, 5), 2);
  v_keep   := greatest(coalesce((public._dev_token_sample_cfg()->>'retain_days')::int, 30), 7);

  with med as (
    select coalesce(size_class,'normal') sc,
           percentile_cont(0.5) within group (
             order by coalesce(cost_input_tokens,0)+coalesce(cost_output_tokens,0)) m
      from dev_commands
     where status='completed' and coalesce(cost_input_tokens,0)+coalesce(cost_output_tokens,0) > 0
     group by 1
  ),
  hits as (
    select c.id, coalesce(c.cost_input_tokens,0)+coalesce(c.cost_output_tokens,0) tok,
           med.m::numeric m, coalesce(c.size_class,'normal') sc, c.title
      from dev_commands c join med on med.sc = coalesce(c.size_class,'normal')
     where c.finished_at is not null
       and c.finished_at >= now() - make_interval(days => v_keep)
       and med.m > 0
       and coalesce(c.cost_input_tokens,0)+coalesce(c.cost_output_tokens,0) >= med.m::numeric * v_factor
  )
  insert into dev_token_anomaly (command_id, tokens, median_tokens, factor, size_class, title)
  select id, tok, round(m::numeric)::bigint, round(tok::numeric / m::numeric, 1), sc, left(coalesce(title,''), 160) from hits
  on conflict (command_id) do nothing;
  get diagnostics v_found = row_count;

  -- A backlog is recorded but never blasted: only a command that finished
  -- inside the alert window is worth waking Om for. Everything older is
  -- stamped as seen in the same pass so the queue stays short.
  update dev_token_anomaly a set notified_at = now()
   where a.notified_at is null
     and not exists (select 1 from dev_commands c
                      where c.id = a.command_id
                        and c.finished_at >= now() - make_interval(hours =>
                              greatest(coalesce((public._dev_token_sample_cfg()->>'alert_window_h')::int, 24), 1)));

  for r in select * from dev_token_anomaly where notified_at is null order by at limit 5 loop
    perform public.runner_ops_alert('ops_token_anomaly', jsonb_build_object(
      'command_id', r.command_id,
      'title',      coalesce(r.title, '#' || r.command_id),
      'tokens',     public._fmt_tokens(r.tokens),
      'median',     public._fmt_tokens(r.median_tokens),
      'factor',     trim(to_char(r.factor,'FM990.0')) || '×',
      'size_class', coalesce(r.size_class,'normal')));
    update dev_token_anomaly set notified_at = now() where command_id = r.command_id;
    v_sent := v_sent + 1;
  end loop;

  delete from dev_token_sample where at < now() - make_interval(days => v_keep);
  return jsonb_build_object('ok', true, 'new', v_found, 'alerted', v_sent, 'factor', v_factor);
end $$;

insert into public.cron_task (name, ord, mode, work_sql, base_interval_s, enabled, dml, note)
values ('token-anomaly-scan', 450, 'poll', 'select public.dev_token_anomaly_scan()', 600, true, true,
        'CMD #1820 — records any command costing 5x its size-class median, alerts Om once, prunes dev_token_sample')
on conflict (name) do update set work_sql = excluded.work_sql, enabled = true, note = excluded.note;

-- Tokens the series actually measured for one command inside one span. NULL
-- (not zero) when there is no reading at all, so the screen can print '—'.
create or replace function public._dev_token_span(p_cmd bigint, p_from timestamptz, p_to timestamptz)
returns bigint language sql stable as $$
  with d as (
    select s.at,
           greatest((s.tokens_in + s.tokens_out)
             - coalesce(lag(s.tokens_in + s.tokens_out) over (order by s.at), 0), 0) tok
      from public.dev_token_sample s where s.command_id = p_cmd)
  select nullif(coalesce(sum(tok), 0), 0)::bigint
    from d where d.at > p_from and d.at <= p_to
$$;

-- ── 7. THE ONE RPC THE SCREEN CALLS ─────────────────────────────────────────
-- Every string on the Token dashboard is built here. Flutter renders sections
-- in payload order and computes nothing — not a total, not a percentage, not a
-- rupee sign. An unknown section kind is skipped in silence (forward compat).
create or replace function public.dev_token_report(p_scope text default 'today')
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_scope text; v_day date; v_d0 timestamptz; v_d1 timestamptz;
  v_from timestamptz; v_to timestamptz; v_scope_label text;
  v_sections jsonb := '[]'::jsonb;
  v_tok bigint; v_in bigint; v_out bigint; v_inr numeric; v_n int;
  v_re numeric; v_drift numeric; v_drift_pct numeric;
  v_rows jsonb; v_tmp jsonb; v_txt text; v_num numeric; v_num2 numeric;
  v_usage jsonb; v_pct numeric; v_reset timestamptz; v_wstart timestamptz;
  v_hours numeric; v_rate numeric; v_eta timestamptz;
  v_limit int; v_zone smallint;
begin
  perform _dev_guard();
  v_scope := lower(coalesce(nullif(p_scope,''), 'today'));
  if v_scope not in ('today','week','all') then v_scope := 'today'; end if;
  v_limit := greatest(coalesce((_dev_token_sample_cfg()->>'list_limit')::int, 12), 3);

  -- Zone and date come from the header picker, never from this screen.
  v_zone := admin_active_zone();
  v_day  := admin_active_date();
  v_d0   := (v_day::text || ' 00:00:00')::timestamp at time zone 'Asia/Kolkata';
  v_d1   := v_d0 + interval '1 day';

  if    v_scope = 'today' then v_from := v_d0;                    v_to := v_d1; v_scope_label := 'Today';
  elsif v_scope = 'week'  then v_from := v_d1 - interval '7 days';v_to := v_d1; v_scope_label := 'This week';
  else                         v_from := '-infinity'::timestamptz;v_to := 'infinity'::timestamptz; v_scope_label := 'All time';
  end if;

  -- ══ 1. WHERE IT WENT — spend today / week / all time ══════════════════════
  select jsonb_agg(jsonb_build_object('cells', jsonb_build_array(
           jsonb_build_object('text', w.label),
           jsonb_build_object('text', _dev_tok(w.tin),  'align','right'),
           jsonb_build_object('text', _dev_tok(w.tout), 'align','right'),
           jsonb_build_object('text', _dev_tok(w.tin + w.tout), 'align','right'),
           jsonb_build_object('text', _dev_inr(w.inr),  'align','right')),
           'sub', w.n || ' command(s)', 'key', w.k) order by w.ord)
    into v_rows
    from (
      select 'today' k, 'Today' label, 1 ord,
             coalesce(sum(c.tin),0) tin, coalesce(sum(c.tout),0) tout,
             coalesce(sum(c.inr),0) inr, count(*) n
        from _dev_token_cmd_window(v_d0, v_d1) c
      union all
      select 'week', 'This week (7 days)', 2,
             coalesce(sum(c.tin),0), coalesce(sum(c.tout),0), coalesce(sum(c.inr),0), count(*)
        from _dev_token_cmd_window(v_d1 - interval '7 days', v_d1) c
      union all
      select 'all', 'All time', 3,
             coalesce(sum(c.tin),0), coalesce(sum(c.tout),0), coalesce(sum(c.inr),0), count(*)
        from _dev_token_cmd_window('-infinity'::timestamptz, 'infinity'::timestamptz) c
    ) w;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','spend', 'kind','table', 'title','Where it went',
    'sub','A build is booked to the day it finished — the same rule the reconciliation SQL uses.',
    'columns', jsonb_build_array(
      jsonb_build_object('label','Window'), jsonb_build_object('label','Input','align','right'),
      jsonb_build_object('label','Output','align','right'), jsonb_build_object('label','Tokens','align','right'),
      jsonb_build_object('label','₹','align','right')),
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','Nothing booked yet.'));

  -- The scope window's own totals — every section below reads these.
  select coalesce(sum(tin),0), coalesce(sum(tout),0), coalesce(sum(inr),0), count(*)
    into v_in, v_out, v_inr, v_n
    from _dev_token_cmd_window(v_from, v_to);
  v_tok := v_in + v_out;

  -- ══ 2. PER COMMAND ════════════════════════════════════════════════════════
  select jsonb_agg(jsonb_build_object('cells', jsonb_build_array(
           jsonb_build_object('text','#'||r.id, 'sub', left(coalesce(r.title,''),44)),
           jsonb_build_object('text', _dev_tok(r.tin),  'align','right'),
           jsonb_build_object('text', _dev_tok(r.tout), 'align','right'),
           jsonb_build_object('text', case when r.files is null then '—' else r.files::text end, 'align','right'),
           jsonb_build_object('text', case when coalesce(r.files,0) > 0
                                           then _dev_tok(round((r.tin + r.tout)::numeric / r.files)) else '—' end, 'align','right'),
           jsonb_build_object('text', case when coalesce(r.files,0) > 0
                                           then _dev_inr(r.inr / r.files, true) else '—' end, 'align','right')),
           'key', r.id::text) order by r.ord)
    into v_rows
    from (select c.id, dc.title, c.tin, c.tout, c.inr, nullif(dc.diff_files,0) files,
                 row_number() over (order by c.tin + c.tout desc) ord
            from _dev_token_cmd_window(v_from, v_to) c
            join dev_commands dc on dc.id = c.id
           order by c.tin + c.tout desc limit v_limit) r;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','per_command', 'kind','table', 'title','Per command',
    'sub', 'Dearest ' || v_limit || ' of ' || v_n || ' in ' || lower(v_scope_label)
           || '. Files shipped is diff_files — "—" where the deploy never recorded one.',
    'columns', jsonb_build_array(
      jsonb_build_object('label','Command'), jsonb_build_object('label','Input','align','right'),
      jsonb_build_object('label','Output','align','right'), jsonb_build_object('label','Files','align','right'),
      jsonb_build_object('label','Tokens/file','align','right'), jsonb_build_object('label','₹/file','align','right')),
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','No commands in this window.'));

  -- ══ 3. COST BY PHASE ══════════════════════════════════════════════════════
  select jsonb_agg(jsonb_build_object('cells', jsonb_build_array(
           jsonb_build_object('text', p.label),
           jsonb_build_object('text', _dev_tok(p.tokens), 'align','right'),
           jsonb_build_object('text', _dev_inr(p.inr),    'align','right'),
           jsonb_build_object('text', case when v_tok > 0 then _dev_pct(p.tokens * 100.0 / v_tok) else '—' end, 'align','right')),
           'tone', p.tone, 'sub', p.sub, 'key', p.phase) order by p.ord)
    into v_rows
    from (
      select r.phase, r.tokens, r.inr,
             case r.phase when 'planning' then 'Planning' when 'building' then 'Building'
                          when 'qa' then 'QA & journeys' when 'merge_deploy' then 'Merge & deploy'
                          else 'Not yet attributed' end label,
             case r.phase when 'unattributed' then 'warning' else 'info' end tone,
             case r.phase when 'unattributed'
                          then 'these builds ran before the token series existed — nothing is apportioned to a phase by guesswork'
                          else r.cmds || ' command(s)' end sub,
             case r.phase when 'planning' then 1 when 'building' then 2 when 'qa' then 3
                          when 'merge_deploy' then 4 else 5 end ord
        from _dev_token_phase_rows(v_from, v_to) r
       where r.tokens > 0
    ) p;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','phase', 'kind','table', 'title','Cost by phase',
    'sub','Read from real token readings against the step, push and journey stamps — never split by duration.',
    'columns', jsonb_build_array(
      jsonb_build_object('label','Phase'), jsonb_build_object('label','Tokens','align','right'),
      jsonb_build_object('label','₹','align','right'), jsonb_build_object('label','Share','align','right')),
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','Nothing spent in this window.'));

  -- ══ 4. BY SIZE CLASS · BY MODEL · BY AREA ═════════════════════════════════
  select jsonb_agg(jsonb_build_object('label', _dev_size_label(g.k), 'value', _dev_tok(g.t),
           'sub', g.n || ' command(s) · ' || _dev_inr(g.i), 'tone','info',
           'pct', case when v_tok > 0 then round(g.t * 100.0 / v_tok) else 0 end) order by g.t desc)
    into v_rows
    from (select size_class k, sum(tin+tout) t, sum(inr) i, count(*) n
            from _dev_token_cmd_window(v_from, v_to) group by 1 having sum(tin+tout) > 0) g;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','by_size', 'kind','bars', 'title','By size class', 'sub', null,
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','No spend to split.'));

  select jsonb_agg(jsonb_build_object('label', _dev_model_label(g.k), 'value', _dev_tok(g.t),
           'sub', g.n || ' command(s) · ' || _dev_inr(g.i), 'tone','info',
           'pct', case when v_tok > 0 then round(g.t * 100.0 / v_tok) else 0 end) order by g.t desc)
    into v_rows
    from (select model k, sum(tin+tout) t, sum(inr) i, count(*) n
            from _dev_token_cmd_window(v_from, v_to) group by 1 having sum(tin+tout) > 0) g;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','by_model', 'kind','bars', 'title','By model',
    'sub','The model the session actually ran on, not the one the row asked for.',
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','No spend to split.'));

  select jsonb_agg(jsonb_build_object('label', coalesce(g.k,'unassigned'), 'value', _dev_tok(g.t),
           'sub', g.n || ' command(s) · ' || _dev_inr(g.i), 'tone', case when g.k is null then 'warning' else 'info' end,
           'pct', case when v_tok > 0 then round(g.t * 100.0 / v_tok) else 0 end) order by g.t desc)
    into v_rows
    from (select area k, sum(tin+tout) t, sum(inr) i, count(*) n
            from _dev_token_cmd_window(v_from, v_to) group by 1 having sum(tin+tout) > 0) g;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','by_area', 'kind','bars', 'title','By area of the codebase', 'sub', null,
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','No spend to split.'));

  -- ══ 5. WHERE IT WAS WASTED — the buckets ══════════════════════════════════
  select jsonb_agg(jsonb_build_object('cells', jsonb_build_array(
           jsonb_build_object('text', w.label),
           jsonb_build_object('text', case when w.measured then _dev_tok(w.tokens) else '—' end, 'align','right'),
           jsonb_build_object('text', case when w.measured then _dev_inr(w.inr)    else '—' end, 'align','right'),
           jsonb_build_object('text', case when w.measured and v_tok > 0 then _dev_pct(w.tokens * 100.0 / v_tok) else '—' end, 'align','right')),
           'tone', w.tone, 'sub', w.sub, 'key', w.bucket) order by w.ord)
    into v_rows
    from (
      select r.bucket, r.tokens, r.inr, r.measured,
             case r.bucket when 'waiting' then 'Waiting' when 'resumes' then 'Resumes'
                           when 'retries' then 'Retries' when 'repeat_qa' then 'Repeated QA'
                           when 'failure' then 'Failure tax' else 'Everything else' end label,
             case r.bucket when 'rest' then 'info'
                           when 'failure' then 'danger' else 'warning' end tone,
             case when r.measured then r.detail
                  else r.detail || ' — not measurable before the token series existed; this spend sits in Everything else' end sub,
             case r.bucket when 'waiting' then 1 when 'resumes' then 2 when 'retries' then 3
                           when 'repeat_qa' then 4 when 'failure' then 5 else 6 end ord
        from _dev_token_waste_rows(v_from, v_to) r
    ) w;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','waste', 'kind','table', 'title','Where it was wasted',
    'sub','Buckets are cut out of each command''s own total in order, so they never overlap and always add back to '
          || _dev_tok(v_tok) || ' — the window total.',
    'columns', jsonb_build_array(
      jsonb_build_object('label','Bucket'), jsonb_build_object('label','Tokens','align','right'),
      jsonb_build_object('label','₹','align','right'), jsonb_build_object('label','Share','align','right')),
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','Nothing spent in this window.'));

  -- ══ 6/7. FAILURE TAX AND WHAT WAS ABANDONED ═══════════════════════════════
  select jsonb_agg(jsonb_build_object('cells', jsonb_build_array(
           jsonb_build_object('text','#'||f.id, 'sub', left(coalesce(f.title,''),44)),
           jsonb_build_object('text', f.status),
           jsonb_build_object('text', f.steps_line),
           jsonb_build_object('text', _dev_tok(f.tok), 'align','right'),
           jsonb_build_object('text', _dev_inr(f.inr), 'align','right')),
           'tone','danger', 'key', f.id::text) order by f.tok desc)
    into v_rows
    from (select c.id, dc.title, c.status, c.tin + c.tout tok, c.inr,
                 coalesce(dc.steps_done,0) || '/' || coalesce(nullif(dc.steps_total,0), 0) steps_line
            from _dev_token_cmd_window(v_from, v_to) c
            join dev_commands dc on dc.id = c.id
           where c.status in ('failed','cancelled','superseded')
           order by c.tin + c.tout desc limit v_limit) f;
  select coalesce(sum(c.tin + c.tout),0), coalesce(sum(c.inr),0), count(*)
    into v_num, v_num2, v_n
    from _dev_token_cmd_window(v_from, v_to) c where c.status in ('failed','cancelled','superseded');
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','abandoned', 'kind','table',
    'title','Failure tax — ' || _dev_tok(v_num) || ' · ' || _dev_inr(v_num2),
    'sub', v_n || ' command(s) that never shipped'
           || case when v_tok > 0 then ' · ' || _dev_pct(v_num * 100.0 / v_tok) || ' of the window' else '' end,
    'columns', jsonb_build_array(
      jsonb_build_object('label','Command'), jsonb_build_object('label','Ended'),
      jsonb_build_object('label','Steps'), jsonb_build_object('label','Tokens','align','right'),
      jsonb_build_object('label','₹','align','right')),
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','Everything in this window shipped.'));

  -- ══ 8. THE SAME JOURNEY, RUN AGAIN AND AGAIN ══════════════════════════════
  select jsonb_agg(jsonb_build_object('cells', jsonb_build_array(
           jsonb_build_object('text','#'||j.command_id),
           jsonb_build_object('text', j.name),
           jsonb_build_object('text', j.runs::text, 'align','right'),
           jsonb_build_object('text', (j.runs - 1)::text, 'align','right'),
           jsonb_build_object('text', case when j.tok is null then '—' else _dev_tok(j.tok) end, 'align','right')),
           'tone', case when j.runs >= 5 then 'danger' else 'warning' end, 'key', j.command_id || '-' || j.journey_id) order by j.runs desc, j.command_id desc)
    into v_rows
    from (
      select r.command_id, r.journey_id, jj.name, count(*) runs,
             _dev_token_span(r.command_id, min(r.at), max(r.at)) tok
        from dev_journey_runs r
        join dev_journeys jj on jj.id = r.journey_id
       where r.command_id in (select id from _dev_token_cmd_window(v_from, v_to))
       group by r.command_id, r.journey_id, jj.name
      having count(*) > 1
       order by count(*) desc limit v_limit
    ) j;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','repeat_journeys', 'kind','table', 'title','The same journey, run again',
    'sub','Tokens are what the series measured between that journey''s first and last run — "—" where there is no reading.',
    'columns', jsonb_build_array(
      jsonb_build_object('label','Command'), jsonb_build_object('label','Journey'),
      jsonb_build_object('label','Runs','align','right'), jsonb_build_object('label','Repeats','align','right'),
      jsonb_build_object('label','Tokens','align','right')),
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','No journey ran twice for one command.'));

  -- ══ 9. READ / WRITE RATIO ═════════════════════════════════════════════════
  select jsonb_agg(jsonb_build_object('cells', jsonb_build_array(
           jsonb_build_object('text','#'||q.id, 'sub', left(coalesce(q.title,''),44)),
           jsonb_build_object('text', _dev_tok(q.tin),  'align','right'),
           jsonb_build_object('text', _dev_tok(q.tout), 'align','right'),
           jsonb_build_object('text', trim(to_char(q.ratio,'FM990.0')) || ':1', 'align','right')),
           'tone', case when q.ratio > q.flag then 'danger' else 'info' end,
           'sub', case when q.ratio > q.flag then 'over ' || trim(to_char(q.flag,'FM990')) || ':1 — reading far more than it writes' else null end,
           'key', q.id::text) order by q.ratio desc)
    into v_rows
    from (select c.id, dc.title, c.tin, c.tout, c.tin::numeric / nullif(c.tout,0) ratio,
                 greatest(coalesce((_dev_token_sample_cfg()->>'rw_flag')::numeric, 8), 1) flag
            from _dev_token_cmd_window(v_from, v_to) c
            join dev_commands dc on dc.id = c.id
           where c.tout > 0
           order by c.tin::numeric / nullif(c.tout,0) desc limit v_limit) q;
  select count(*) into v_n from _dev_token_cmd_window(v_from, v_to) c
   where c.tout > 0 and c.tin::numeric / c.tout > greatest(coalesce((_dev_token_sample_cfg()->>'rw_flag')::numeric, 8), 1);
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','read_write', 'kind','table', 'title','Read / write ratio',
    'sub', v_n || ' command(s) over the '
           || trim(to_char(greatest(coalesce((_dev_token_sample_cfg()->>'rw_flag')::numeric, 8),1),'FM990')) || ':1 line.',
    'columns', jsonb_build_array(
      jsonb_build_object('label','Command'), jsonb_build_object('label','Input','align','right'),
      jsonb_build_object('label','Output','align','right'), jsonb_build_object('label','Ratio','align','right')),
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','No command wrote anything in this window.'));

  -- ══ 10. TOKEN HEATMAP BY STEP ═════════════════════════════════════════════
  select jsonb_agg(jsonb_build_object('label','Step ' || h.step_n, 'value', _dev_tok(h.tokens),
           'sub', h.cmds || ' command(s) · dearest: ' || left(coalesce(h.top_title,''), 48),
           'tone','info',
           'pct', case when (select max(tokens) from _dev_token_step_rows(v_from, v_to)) > 0
                       then round(h.tokens * 100.0 / (select max(tokens) from _dev_token_step_rows(v_from, v_to)))
                       else 0 end) order by h.step_n)
    into v_rows
    from _dev_token_step_rows(v_from, v_to) h;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','step_heatmap', 'kind','bars', 'title','Token heatmap by step',
    'sub','Measured between each step''s own landing stamp. Empty until a build in this window carried the token series.',
    'rows', coalesce(v_rows,'[]'::jsonb),
    'empty_label','No step-level readings in this window yet.'));

  -- ══ 11. SAME-FILE REWORK ══════════════════════════════════════════════════
  -- lease_event, not predicted_files: a prediction is not evidence of a touch.
  select jsonb_agg(jsonb_build_object('cells', jsonb_build_array(
           jsonb_build_object('text', f.path),
           jsonb_build_object('text', f.cmds::text, 'align','right'),
           jsonb_build_object('text', _dev_tok(f.tok), 'align','right'),
           jsonb_build_object('text', _dev_inr(f.inr), 'align','right')),
           'tone', case when f.cmds >= 5 then 'danger' else 'warning' end,
           'sub', 'commands: ' || f.ids, 'key', f.path) order by f.cmds desc, f.tok desc)
    into v_rows
    from (
      select le.path, count(distinct le.command_id) cmds,
             sum(distinct_c.tok) tok, sum(distinct_c.inr) inr,
             string_agg(distinct '#' || le.command_id::text, ' ' order by '#' || le.command_id::text) ids
        from lease_event le
        join lateral (select c.tin + c.tout tok, c.inr
                        from _dev_token_cmd_window(v_from, v_to) c where c.id = le.command_id) distinct_c on true
       where le.kind = 'granted'
       group by le.path
      having count(distinct le.command_id) >= greatest(coalesce((_dev_token_sample_cfg()->>'rework_min')::int, 3), 2)
       order by count(distinct le.command_id) desc limit v_limit
    ) f;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','rework', 'kind','table', 'title','Same file, again and again',
    'sub','Files three or more commands in this window actually took a lease on, with the combined spend of those commands.',
    'columns', jsonb_build_array(
      jsonb_build_object('label','File'), jsonb_build_object('label','Commands','align','right'),
      jsonb_build_object('label','Combined tokens','align','right'), jsonb_build_object('label','₹','align','right')),
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','No file was taken by three commands in this window.'));

  -- ══ 12. SPEC LENGTH VS COST ═══════════════════════════════════════════════
  select corr(length(coalesce(dc.spec,''))::numeric, (c.tin + c.tout)::numeric), count(*)
    into v_num, v_n
    from _dev_token_cmd_window(v_from, v_to) c join dev_commands dc on dc.id = c.id
   where c.tin + c.tout > 0 and length(coalesce(dc.spec,'')) > 0;
  with t as (
    select ntile(4) over (order by length(coalesce(dc.spec,''))) q, c.tin + c.tout tok
      from _dev_token_cmd_window(v_from, v_to) c join dev_commands dc on dc.id = c.id
     where c.tin + c.tout > 0 and length(coalesce(dc.spec,'')) > 0),
  b as (
    select q, count(*) n, percentile_cont(0.5) within group (order by tok)::numeric med from t group by q),
  m as (select max(med) mx from b)
  select jsonb_agg(jsonb_build_object(
           'label', case b.q when 1 then 'Shortest quarter of specs' when 2 then 'Second quarter'
                             when 3 then 'Third quarter' else 'Longest quarter of specs' end,
           'value', _dev_tok(round(b.med::numeric)),
           'sub', b.n || ' command(s) · median spend', 'tone','info',
           'pct', case when m.mx > 0 then round(b.med::numeric * 100.0 / m.mx::numeric) else 0 end) order by b.q)
    into v_rows from b, m;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','spec_length', 'kind','bars',
    'title','Spec length vs cost — ' || case when v_n >= 5 and v_num is not null
                                             then 'r = ' || trim(to_char(v_num,'FM990.00')) else 'r = —' end,
    'sub', case when v_n < 5 then 'fewer than five priced commands with a spec in this window — no correlation stated'
                when v_num is null then 'no correlation could be computed'
                when v_num >= 0.5 then 'a longer spec has strongly meant a dearer build here'
                when v_num >= 0.2 then 'a longer spec has meant a somewhat dearer build here'
                when v_num > -0.2 then 'spec length has barely moved the cost here'
                else 'longer specs have run cheaper here' end
           || ' · ' || v_n || ' command(s)',
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','No priced commands with a spec in this window.'));

  -- ══ 13. ANOMALIES ═════════════════════════════════════════════════════════
  select jsonb_agg(jsonb_build_object('cells', jsonb_build_array(
           jsonb_build_object('text','#'||a.command_id, 'sub', left(coalesce(a.title,''),44)),
           jsonb_build_object('text', _dev_size_label(a.size_class)),
           jsonb_build_object('text', _dev_tok(a.tokens), 'align','right'),
           jsonb_build_object('text', _dev_tok(a.median_tokens), 'align','right'),
           jsonb_build_object('text', trim(to_char(a.factor,'FM990.0')) || '×', 'align','right')),
           'tone','danger',
           'sub', case when a.notified_at is null then 'not sent yet' else 'told to Om ' || to_char(a.notified_at at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' IST' end,
           'key', a.command_id::text) order by a.factor desc)
    into v_rows
    from (select * from dev_token_anomaly
           where command_id in (select id from _dev_token_cmd_window(v_from, v_to))
           order by factor desc limit v_limit) a;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','anomalies', 'kind','table',
    'title','Costing far more than its class',
    'sub','Any build past '
          || trim(to_char(greatest(coalesce((_dev_token_sample_cfg()->>'anomaly_factor')::numeric,5),2),'FM990'))
          || '× the median for its size class. Recorded once, sent to Om once, by WhatsApp.',
    'columns', jsonb_build_array(
      jsonb_build_object('label','Command'), jsonb_build_object('label','Class'),
      jsonb_build_object('label','Tokens','align','right'), jsonb_build_object('label','Class median','align','right'),
      jsonb_build_object('label','Over','align','right')),
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','Nothing in this window ran away with itself.'));

  -- ══ 14. FORECAST — when the weekly quota runs out ═════════════════════════
  select coalesce(value,'{}'::jsonb) into v_usage from dev_runner_config where key='claude_usage';
  select (l->>'percent')::numeric, (l->>'resets_at')::timestamptz
    into v_pct, v_reset
    from jsonb_array_elements(coalesce(v_usage->'limits','[]'::jsonb)) l
   where l->>'kind' = 'weekly_all' limit 1;
  v_rows := '[]'::jsonb;
  if v_pct is null or v_reset is null then
    v_rows := jsonb_build_array(jsonb_build_object('label','Weekly quota','value','—',
      'sub','no weekly reading has been synced yet','tone','warning'));
  else
    v_wstart := v_reset - interval '7 days';
    v_hours  := greatest(extract(epoch from (now() - v_wstart)) / 3600.0, 0.25);
    v_rate   := v_pct / v_hours;                       -- percent per hour, measured
    v_rows := jsonb_build_array(
      jsonb_build_object('label','Weekly quota used', 'value', _dev_pct(v_pct, 0),
        'sub','window opened ' || to_char(v_wstart at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' IST',
        'tone', case when v_pct >= 85 then 'danger' when v_pct >= 60 then 'warning' else 'success' end),
      jsonb_build_object('label','Burn', 'value', _dev_pct(v_rate * 24, 1) || ' / day',
        'sub', trim(to_char(v_hours,'FM9990.0')) || ' hours into the window', 'tone','info'));
    if v_rate <= 0 then
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('label','Exhausted', 'value','—',
        'sub','nothing has been drawn from this window yet','tone','info'));
    else
      v_eta := now() + make_interval(secs => ((100 - v_pct) / v_rate) * 3600);
      v_rows := v_rows || jsonb_build_array(jsonb_build_object('label','Exhausted',
        'value', case when v_eta >= v_reset then 'not before the reset'
                      else to_char(v_eta at time zone 'Asia/Kolkata','DD Mon, HH24:MI') || ' IST' end,
        'sub', case when v_eta >= v_reset
                    then 'at this burn the window resets first, ' || to_char(v_reset at time zone 'Asia/Kolkata','DD Mon HH24:MI') || ' IST'
                    else 'at this burn, ' || _fmt_dur(extract(epoch from (v_eta - now()))) || ' from now' end,
        'tone', case when v_eta >= v_reset then 'success' else 'danger' end));
    end if;
  end if;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','forecast', 'kind','tiles', 'title','Looking forward',
    'sub','Burn is measured from the live weekly reading against the hours the window has been open.',
    'rows', v_rows, 'empty_label','No quota reading.'));

  -- ══ 15. WHAT THE QUEUE WILL COST, BEFORE IT IS APPROVED ═══════════════════
  select jsonb_agg(jsonb_build_object('cells', jsonb_build_array(
           jsonb_build_object('text', p.ref, 'sub', left(coalesce(p.title,''),44)),
           jsonb_build_object('text', _dev_size_label(p.size_class)),
           jsonb_build_object('text', p.chars::text, 'align','right'),
           jsonb_build_object('text', coalesce(p.files::text,'—'), 'align','right'),
           jsonb_build_object('text', coalesce(p.est->>'value','—'), 'align','right')),
           'sub', p.est->>'sub', 'key', p.ref) order by p.ord, p.ref)
    into v_rows
    from (
      select '#' || c.id ref, c.title, coalesce(c.size_class,'normal') size_class,
             length(coalesce(c.spec,'')) chars, array_length(c.predicted_files,1) files, 1 ord,
             dev_cmd_cost_estimate(coalesce(c.size_class,'normal'), length(coalesce(c.spec,'')),
                                   array_length(c.predicted_files,1)) est
        from dev_commands c where c.status = 'pending'
      union all
      select 'draft ' || d.id, left(coalesce(d.spec,''),80), 'normal',
             length(coalesce(d.spec,'')), null, 2,
             dev_cmd_cost_estimate('normal', length(coalesce(d.spec,'')), null)
        from dev_command_drafts d where d.status in ('ready','pending','open')
      limit 24
    ) p;
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','estimate', 'kind','table', 'title','Before you approve it',
    'sub','Median of finished builds in the same size class, nudged by this spec''s length and its predicted files. "—" where too few builds compare.',
    'columns', jsonb_build_array(
      jsonb_build_object('label','Waiting'), jsonb_build_object('label','Class'),
      jsonb_build_object('label','Spec chars','align','right'), jsonb_build_object('label','Files','align','right'),
      jsonb_build_object('label','Likely cost','align','right')),
    'rows', coalesce(v_rows,'[]'::jsonb), 'empty_label','Nothing is waiting to be approved.'));

  -- ══ 16. WHAT-IF: NO WAITING AT ALL ════════════════════════════════════════
  select r.tokens, r.inr into v_num, v_num2
    from _dev_token_waste_rows(v_from, v_to) r where r.bucket = 'waiting';
  v_sections := v_sections || jsonb_build_array(jsonb_build_object(
    'key','whatif', 'kind','tiles', 'title','With zero waiting',
    'sub','Waiting is meant to be a shell sleep (CHANGE #1817). This is what ' || lower(v_scope_label)
          || ' would have cost had no worker taken a single turn while it was asleep.',
    'rows', jsonb_build_array(
      jsonb_build_object('label', v_scope_label || ' as it happened', 'value', _dev_inr(v_inr),
        'sub', _dev_tok(v_tok) || ' tokens', 'tone','info'),
      jsonb_build_object('label','With zero waiting', 'value', _dev_inr(v_inr - coalesce(v_num2,0)),
        'sub', _dev_tok(v_tok - coalesce(v_num,0)) || ' tokens', 'tone','success'),
      jsonb_build_object('label','Difference', 'value', _dev_inr(coalesce(v_num2,0)),
        'sub', case when coalesce(v_num,0) = 0 then 'no worker woke while asleep — this is the target'
                    else _dev_tok(v_num) || ' tokens burned waiting' end,
        'tone', case when coalesce(v_num,0) = 0 then 'success' else 'danger' end)),
    'empty_label',''));

  -- ══ THE SELF-CHECK — the same rupees, computed a second way ═══════════════
  -- cost_inr was stamped beat by beat at whatever rate was live then. This
  -- prices the finished rows once, today, from the same model_rates card. The
  -- two should agree; the gap is drift, and over the threshold it is drawn red.
  select coalesce(sum(_dev_inr_recompute(c.tin, c.tout, c.model, c.mode)),0)
    into v_re from _dev_token_cmd_window(v_from, v_to) c;
  v_drift     := v_re - v_inr;
  v_drift_pct := case when v_inr > 0 then abs(v_drift) * 100.0 / v_inr else 0 end;
  v_num       := greatest(coalesce((_dev_token_sample_cfg()->>'drift_pct')::numeric, 1), 0.01);

  return jsonb_build_object(
    'ok', true, 'has', true,
    'title', 'Token dashboard',
    'subtitle', 'Where every token and rupee went.',
    'scope', jsonb_build_object('key', v_scope, 'label', v_scope_label,
      'options', jsonb_build_array(
        jsonb_build_object('key','today','label','Today','selected', v_scope='today'),
        jsonb_build_object('key','week', 'label','This week','selected', v_scope='week'),
        jsonb_build_object('key','all',  'label','All time','selected', v_scope='all'))),
    'zone_label', case when v_zone is null then 'All zones' else 'Zone ' || v_zone end,
    'date_label', to_char(v_day, 'DD Mon YYYY'),
    'basis_label', case
        when coalesce((select value->>'billing_mode' from dev_runner_config where key='worker_pool'),'') = 'max_subscription'
        then 'Rupees are API-equivalent value — the runner is on a Max subscription, so no cash leaves the account.'
        else 'Rupees are real API spend at the live rate card.' end,
    'headline', jsonb_build_object(
      'label', v_scope_label, 'value', _dev_inr(v_inr),
      'sub', _dev_tok(v_tok) || ' tokens over ' || v_n || ' command(s)'),
    'selfcheck', jsonb_build_object(
      'label', 'Self-check',
      'value', case when v_inr <= 0 then '—' else _dev_pct(v_drift_pct, 2) || ' drift' end,
      'tone', case when v_inr <= 0 then 'info'
                   when v_drift_pct > v_num then 'danger' else 'success' end,
      'sub', case when v_inr <= 0 then 'nothing priced in this window'
                  else 'stored ' || _dev_inr(v_inr, true) || ' vs recomputed ' || _dev_inr(v_re, true)
                       || ' · flagged over ' || _dev_pct(v_num, 0) end),
    'sections', v_sections,
    'footnote', 'Spend is booked to the day a command finished, so every total here equals '
                || 'select sum(cost_input_tokens + cost_output_tokens) from dev_commands over the same window. '
                || 'Phase, step, retry and repeated-QA figures come from dev_token_sample — a real reading taken '
                || 'each time a heartbeat moved a row''s counters — and print "—" where no reading exists. '
                || 'Nothing on this screen is apportioned, prorated or estimated from duration.');
end $$;

grant execute on function public.dev_token_report(text)                       to authenticated, service_role;
grant execute on function public.dev_cmd_cost_estimate(text,int,int,int)      to authenticated, service_role;
grant execute on function public.dev_token_anomaly_scan()                     to service_role;

-- ── 8. THE ANOMALY, LIVE ON THE COMMAND CARD ────────────────────────────────
-- The dashboard is a place you go; the card is a place you already are. A
-- command past the multiple gets a chip on its own row in the Dev Queue list,
-- so the anomaly is visible without opening anything.
--
-- This is done in _dev_card_strip (twelve lines) rather than in _dev_cmd_rows
-- (two hundred and sixty), on purpose: several runners edit this schema live
-- and redefining the big row builder to add one column is how a concurrent
-- change gets silently reverted.
create or replace function public._dev_card_keys()
returns text[] language sql immutable as $$
  select array[
    'id','title','status','kind','area','area_label','batch_label','priority',
    'urgent','is_danger','effort','route','route_label','route_tone',
    'claimed_by','model','model_chip','model_label','effort_label','retry_count',
    'created_at','started_at','finished_at','heartbeat_at','eta_at',
    'age_display','elapsed_display','remaining_display','tat_display',
    'ttt_display','speed_display','tokens_display','cost_display','cost_note',
    'has_eta','has_tokens','is_live','is_waiting','is_overrun','msg_count',
    'steps_done','steps_total','steps_chip','steps_stale_chip','steps_stale_hint',
    'spec_chip','spec_tone','spec_open','spec_total',
    'qa_chip','qa_tone','qa_status','qa_required','qa_open_findings',
    'journey_chip','preview_chip','preview_tone','preview_status',
    'chain_chip','chain_tone','finish_chip','finish_tone',
    'wait_chip','wait_tone','wait_kind','wait_reason','wait_hint','wait_state',
    'live_chip','stall_chip','resume_chip','debug_status','debug_requested',
    'size_class','qa_scope','diff_files','diff_rows','grade_chip','grade_tone','grade_reason',
    'auto_finished','auto_finish_source','rolled_back',
    -- CHANGE #1023 — agent liveness, next to the worker liveness it is not
    'agent_chip','agent_tone','agent_rc_session','session_lost_count','started_flags',
    'web_deploy_no','android_status','ios_status',
    'targets_web','targets_android','targets_ios',
    -- CMD #1820 — this build cost far more than its size class usually does
    'anomaly_chip','anomaly_tone'
  ]::text[];
$$;

create or replace function public._dev_card_strip(p_row jsonb)
returns jsonb language sql stable as $$
  select coalesce(
    (select jsonb_object_agg(k, p_row -> k)
       from unnest(public._dev_card_keys()) k
      where p_row ? k
        and p_row -> k is distinct from 'null'::jsonb
        and p_row ->> k is distinct from ''), '{}'::jsonb)
    || case when coalesce(p_row->>'plain_summary','') = '' then '{}'::jsonb
            else jsonb_build_object(
                   'plain_summary', left(p_row->>'plain_summary', 200)) end
    || coalesce((select jsonb_build_object(
                   'anomaly_chip', trim(to_char(a.factor,'FM990.0')) || '× its class',
                   'anomaly_tone', 'danger')
                   from public.dev_token_anomaly a
                  where a.command_id = (p_row->>'id')::bigint), '{}'::jsonb);
$$;
