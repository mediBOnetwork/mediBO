-- CMD #1961 — The Dev Queue lane card tells the truth about the DIRECT lane.
-- Control plane (medibo-dev). Idempotent, re-runnable.
--
-- "Recent batches" read deploy_batch, whose last row is 7 Sep: since #1859
-- every command deploys its own branch through deploy_direct, so the card sat
-- on a six-day-old "Last batch failed" and misled every read of it. The batches
-- block is replaced by RECENTLY COMPLETED (the last five commands that actually
-- finished), the deploy lock prints one live holder chip, and its forced-release
-- list is capped and de-duplicated in the BACKEND instead of by a .take(3) in
-- Dart. The waiter register under the lock is deploy_wait_card()'s (CMD #1940);
-- only its empty sentence changes here.

begin;

-- ── 1. Recently completed — what actually finished, newest first ────────────
create or replace function public.deploy_recent_completed(p_limit int default 5)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare v jsonb;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('has', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'command_id', r.id,
           'label', '#' || r.id || ' · ' ||
                    left(coalesce(nullif(btrim(r.title_display), ''),
                                  nullif(btrim(r.title), ''),
                                  public._c_or('dev_queue.rc_untitled', 'untitled')), 64),
           -- CHANGE #n · duration · tokens — each part absent when unknown,
           -- never guessed and never padded with a zero.
           'sub_label', concat_ws(' · ',
              case when r.web_deploy_no is not null
                   then 'CHANGE #' || r.web_deploy_no end,
              case when r.started_at is not null and r.finished_at is not null
                   then public._fmt_dur(extract(epoch from r.finished_at - r.started_at)) end,
              case when coalesce(r.cost_input_tokens, 0) + coalesce(r.cost_output_tokens, 0) > 0
                   then public._fmt_tokens(coalesce(r.cost_input_tokens, 0)
                                         + coalesce(r.cost_output_tokens, 0))
                        || ' ' || public._c_or('dev_queue.rc_tokens', 'tokens') end),
           'value_label', case when r.web_deploy_no is not null
                               then 'CHANGE #' || r.web_deploy_no
                               else public._c_or('dev_queue.rc_nodeploy', 'no web deploy') end,
           'tone', case when r.web_deploy_no is not null then 'success' else 'neutral' end,
           'when_label', to_char(r.finished_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST')
         order by r.finished_at desc), '[]'::jsonb)
    into v
    from (select * from dev_commands
           where status = 'completed' and finished_at is not null
           order by finished_at desc
           limit greatest(coalesce(p_limit, 5), 1)) r;

  return jsonb_build_object(
    'has', true,
    'heading', public._c_or('dev_queue.rc_heading', 'Recently completed'),
    'empty_label', public._c_or('dev_queue.rc_empty', 'No command has completed yet.'),
    'footnote', public._c_or('dev_queue.rc_footnote',
       'Each command deploys its own branch under the deploy lock — tap a row to open it.'),
    'rows', v);
end $fn$;

grant execute on function public.deploy_recent_completed(int) to anon, authenticated, service_role;

-- ── 2. The deploy lock: one holder chip, and a de-duplicated release list ───
create or replace function public.deploy_lock_banner()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare h jsonb; v_recent jsonb; v_busy boolean; v_chip text;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('has', false);
  end if;
  h := public.deploy_lock_holder(null);
  v_busy := coalesce((h->>'busy')::boolean, false);

  -- CMD #1961 — the same command being reaped four times in a row filled the
  -- whole list with one incident. One row per command, newest first, capped at
  -- three HERE so the widget can render every row it is sent.
  with ev as (
    select distinct on (coalesce(e.command_id::text, coalesce(e.holder, 'lock')))
           e.*
      from deploy_lock_event e
     where e.action in ('reaped', 'refused')
     order by coalesce(e.command_id::text, coalesce(e.holder, 'lock')), e.at desc)
  select coalesce(jsonb_agg(jsonb_build_object(
           'label', case when t.command_id is null then coalesce(t.holder, 'lock')
                         else '#' || t.command_id::text end,
           'value_label', coalesce(t.reason, t.action),
           'at_label', to_char(t.at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
           'tone', case when t.reason in ('max_hold_exceeded', 'holder_mismatch', 'command_reassigned')
                        then 'error' when t.action = 'refused' then 'warning' else 'neutral' end)
           order by t.at desc), '[]'::jsonb)
    into v_recent
    from (select * from ev order by at desc limit 3) t;

  -- The live holder, as ONE chip: #id · runner · elapsed · frees in ~x.
  v_chip := case when v_busy then concat_ws(' · ',
                   case when h->>'command_id' is not null then '#' || (h->>'command_id') end,
                   nullif(coalesce(h->>'holder', ''), ''),
                   public._fmt_dur((h->>'held_s')::numeric),
                   replace(public._c_or('dev_queue.lock_frees_in', 'frees in ~{t}'),
                           '{t}', public._fmt_dur((h->>'cap_left_s')::numeric)))
                 else public._c_or('dev_queue.lock_free', 'Lock free') end;

  return jsonb_build_object(
    'has', true,
    'title', 'Deploy lock',
    'banner', h->>'banner',
    'label', h->>'label',
    'detail', h->>'detail',
    'tone', h->>'tone',
    'busy', h->'busy',
    'command_id', h->'command_id',
    'holder', h->>'holder',
    'held_s', h->'held_s',
    'max_hold_s', h->'max_hold_s',
    'holder_chip', v_chip,
    'holder_chip_tone', case when v_busy then coalesce(h->>'tone', 'info') else 'success' end,
    'cap_label', 'cap ' || ((h->>'max_hold_s')::int / 60) || ' min',
    'renewals_label', case when v_busy
                           then 'renewed ' || coalesce(h->>'renewals', '0') || '×' else '' end,
    'recent', v_recent,
    'recent_label', case when jsonb_array_length(v_recent) = 0
                         then public._c_or('dev_queue.lock_releases_empty', 'No forced releases recorded.')
                         else public._c_or('dev_queue.lock_releases', 'Recent forced releases') end);
end $fn$;

grant execute on function public.deploy_lock_banner() to anon, authenticated, service_role;

-- ── 3. The waiter register's empty sentence, in the spec's words ────────────
insert into ui_copy (key, value) values
  ('dev_queue.dw_empty',
   to_jsonb('No one waiting — the next deploy takes the lock straight away.'::text))
on conflict (key) do update set value = excluded.value, updated_at = now();

-- ── 4. The lane card: Recently completed where Recent batches used to be ────
create or replace function public.deploy_lane_status(p_limit integer default 12)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare l deploy_lock%rowtype; cfg jsonb := _mq_cfg();
        v_wait int; v_target int; v_busy boolean;
        v_hold_avg numeric; v_wait_avg numeric; v_n int;
        v_touch int; v_held int; v_exp_in int; v_ren int;
        v_ren_label text; v_ren_chip text; v_ren_tone text; lb deploy_batch%rowtype;
        v_lock jsonb;
begin
  if not public.deploy_lane_guarded_ok() then
    return jsonb_build_object('ok', false,
      'error', 'Deploy lane is visible to super-admins only.');
  end if;
  select * into l from deploy_lock where id = 1;
  v_lock   := public.deploy_lock_banner();
  v_busy   := l.token is not null and l.expires_at > now();
  v_target := coalesce((cfg->>'target_hold_s')::int, 60);
  v_touch  := greatest(coalesce((cfg->>'touch_every_s')::int, 30), 5);
  select count(*) into v_wait from deploy_queue where status = 'waiting';

  select count(*), avg(hold_s), avg(wait_s) into v_n, v_hold_avg, v_wait_avg
    from deploy_registry
   where deployed_at is not null and deployed_at > now() - interval '7 days';

  -- CHANGE #1822 — THE RENEWAL LINE. A lane that is quietly expiring must be
  -- readable here, not inferred from a wall of failed batches.
  if v_busy then
    v_ren    := coalesce(l.renewals, 0);
    v_held   := extract(epoch from now() - coalesce(l.acquired_at, now()))::int;
    v_exp_in := greatest(extract(epoch from l.expires_at - now())::int, 0);
    v_ren_label := format('lane renewed %s, held %ss · expires in %ss',
                     case v_ren when 1 then 'once' else v_ren || ' times' end, v_held, v_exp_in);
    if v_exp_in <= v_touch then
      v_ren_chip := 'expiring'; v_ren_tone := 'danger';
      v_ren_label := v_ren_label || ' — renewals stopped';
    elsif v_ren = 0 and v_held > v_touch * 2 then
      v_ren_chip := 'not renewing'; v_ren_tone := 'warning';
    else
      v_ren_chip := v_ren || '×'; v_ren_tone := 'info';
    end if;
  else
    select * into lb from deploy_batch
     where closed_at is not null order by closed_at desc limit 1;
    -- CMD #1961 — a batch renewal line is only true while the merge lane is
    -- ON. With the lane off the last batch is from 7 Sep, and printing its
    -- renewals is the same stale sentence this command removes.
    if public.merge_lane_enabled() and lb.id is not null and coalesce(lb.renewals, 0) > 0 then
      v_ren_label := format('last batch %s renewed %s, held %ss',
                       lb.id, case lb.renewals when 1 then 'once' else lb.renewals || ' times' end,
                       coalesce(lb.hold_s, 0));
      v_ren_chip := lb.renewals || '×';
      v_ren_tone := case lb.status when 'deployed' then 'success' else 'neutral' end;
    else
      v_ren_label := public._c_or('dev_queue.lane_no_renewals', 'no lane renewals recorded yet');
      v_ren_chip := ''; v_ren_tone := 'neutral';
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    -- CMD #1961 — Recently completed replaces the batches block. deploy_batch
    -- stopped moving on 7 Sep when #1859 turned the merge lane off, so the card
    -- reported a six-day-old failure as the state of the lane.
    'completed', public.deploy_recent_completed(5),
    'title', 'Deploy lane',
    'subtitle', public._deploy_lane_subtitle(),
    'mode_label', case when not merge_lane_enabled() then 'DIRECT (deploy_lock)' else 'MERGE QUEUE' end,
    'direct', public.deploy_direct_recent(8),
    'mode_tone',  case when not merge_lane_enabled() then 'info' else 'success' end,
    'lane', jsonb_build_object(
      'busy', v_busy,
      'label', case when v_busy then 'Lane held by ' || coalesce(l.holder,'?') else 'Lane free' end,
      'detail', case when v_busy
        then coalesce(l.title,'a deploy') || ' · held ' ||
             extract(epoch from now() - l.acquired_at)::int || 's'
        else 'Nothing deploying right now.' end,
      'held_label', case when v_busy then extract(epoch from now() - l.acquired_at)::int || 's' else '—' end,
      'over_target', case when v_busy then extract(epoch from now() - l.acquired_at)::int > v_target else false end,
      'tone', case when not v_busy then 'success'
                   when extract(epoch from now() - l.acquired_at)::int > v_target then 'error'
                   else 'info' end,
      'renewals', case when v_busy then coalesce(l.renewals, 0) else 0 end,
      'expires_in_s', case when v_busy then v_exp_in end,
      'renewal_label', v_ren_label,
      'renewal_chip', v_ren_chip,
      'renewal_tone', v_ren_tone,
      -- CMD #1866 — WHOSE deploy holds the lock, said once by the backend.
      -- CMD #1961 — and the same holder chip the Dev Queue card prints.
      'lock_label', v_lock->>'label',
      'lock_tone',  v_lock->>'tone',
      'holder_chip', v_lock->>'holder_chip',
      'holder_chip_tone', v_lock->>'holder_chip_tone'),
    'queue', jsonb_build_object(
      'count', v_wait,
      'label', case when v_wait = 0 then 'Queue empty'
                    when v_wait = 1 then '1 branch waiting'
                    else v_wait || ' branches waiting' end,
      'empty_hint', 'Runners push a branch here and go straight back to building. Nothing waits on a lock.',
      'rows', (select coalesce(jsonb_agg(jsonb_build_object(
                 'entry_id', id, 'command_id', command_id,
                 'label', case when command_id is null then title else '#'||command_id||' · '||title end,
                 'detail', agent || ' · ' || branch,
                 'value_label', 'waiting ' || extract(epoch from now() - pushed_at)::int || 's',
                 'tone', 'info') order by pushed_at), '[]'::jsonb)
               from deploy_queue where status = 'waiting'),
      'window_label', (select case
          when coalesce((cfg->>'window_s')::int, 0) <= 0 then 'Batch window off — every branch deploys alone.'
          when v_wait = 0 then 'Batch window ' || (cfg->>'window_s') || 's · nothing waiting.'
          when v_wait >= greatest(coalesce((cfg->>'window_min_branches')::int, 3), 1)
            then 'Batch window full — ' || v_wait || ' branch(es) ship together.'
          else 'Batch window open — ' || v_wait || ' of ' ||
               greatest(coalesce((cfg->>'window_min_branches')::int, 3), 1) ||
               ' branch(es), up to ' || (cfg->>'window_s') || 's.' end)),
    'batch', (select jsonb_build_object(
                 'id', b.id, 'status', b.status,
                 'label', 'Batch ' || b.id || ' · ' || b.entries || ' branch(es)'
                          || case when b.resumed_from is not null then ' · resumed from ' || b.resumed_from else '' end,
                 'value_label', b.status,
                 'tone', case b.status when 'deployed' then 'success' when 'failed' then 'error' else 'info' end,
                 'change_no', b.change_no, 'evicted', b.evicted,
                 'phases', public.merge_batch_phases(b.id),
                 'slowest_label', coalesce((
                    select (e->>'phase') || ' · ' || (e->>'seconds') || 's'
                      from jsonb_array_elements(public.merge_batch_phases(b.id)) e
                     order by (e->>'seconds')::int desc limit 1), '—'),
                 'locked_s', coalesce((
                    select sum((e->>'seconds')::int)
                      from jsonb_array_elements(public.merge_batch_phases(b.id)) e
                     where (e->>'locked')::boolean), 0),
                 'renewals', coalesce(b.renewals, 0),
                 'renewal_label', case when coalesce(b.renewals, 0) = 0 then ''
                    else 'batch renewed the lane ' ||
                         case b.renewals when 1 then 'once' else b.renewals || ' times' end end)
               from deploy_batch b
              where b.status in ('merging','testing','deploying')
              order by b.id desc limit 1),
    'metrics', jsonb_build_object(
      'heading', 'Wait vs hold, last 7 days',
      'samples', v_n,
      'avg_hold_label', case when v_hold_avg is null then 'no hold time recorded yet'
                             else 'avg lane hold ' || round(v_hold_avg)::int || 's' end,
      'avg_wait_label', case when v_wait_avg is null then 'no queue wait recorded yet'
                             else 'avg queue wait ' || round(v_wait_avg)::int || 's' end,
      'target_label', 'target hold under ' || v_target || 's',
      'tone', case when v_hold_avg is null then 'info'
                   when v_hold_avg > v_target then 'warning' else 'success' end),
    'recent_heading', 'Recent deploys',
    'recent', (select coalesce(jsonb_agg(jsonb_build_object(
                 'change_no', r.change_no,
                 'label', '#' || r.change_no || ' · ' || r.title,
                 'detail', coalesce(r.agent,'?'),
                 'value_label', case
                    when r.deployed_at is null and r.status = 'claimed'
                      then 'claimed ' || extract(epoch from now() - r.claimed_at)::int || 's ago · never released'
                    when r.deployed_at is null then r.status
                    else 'held ' || coalesce(r.hold_s, extract(epoch from r.deployed_at - r.claimed_at)::int) || 's'
                         || case when r.wait_s is not null then ' · waited ' || r.wait_s || 's' else '' end end,
                 'tone', case r.status when 'success' then 'success'
                                     when 'expired' then 'warning'
                                     when 'failed'  then 'error' else 'info' end
                 ) order by r.change_no desc), '[]'::jsonb)
               from (select * from deploy_registry order by change_no desc limit greatest(coalesce(p_limit,12),1)) r),
    'stale_heading', 'Stale claims',
    'stale_empty', 'No claim is holding a queue slot past its TTL.',
    'stale', (select coalesce(jsonb_agg(jsonb_build_object(
                 'change_no', change_no,
                 'label', '#' || change_no || ' · ' || title,
                 'detail', coalesce(agent,'?'),
                 'value_label', 'held since ' || to_char(claimed_at at time zone 'Asia/Kolkata', 'DD Mon HH24:MI') || ' IST',
                 'tone', 'warning')
                 order by change_no), '[]'::jsonb)
               from deploy_registry
              where status = 'claimed'
                and claimed_at < now() - make_interval(mins => greatest(coalesce((cfg->>'claim_ttl_minutes')::int,20),5))),
    -- CHANGE #1823 — the critical-path smoke verdict, printed verbatim by the
    -- Deploy lane card. Kept through #1822's follow-up; absent → has:false.
    'smoke', case when to_regproc('public.merge_batch_smoke_status') is not null
                  then public.merge_batch_smoke_status()
                  else jsonb_build_object('has', false) end,
    -- CMD #1866 — the wait gate's own decisions: kind, holder, verdict.
    'gate', case when to_regproc('public.dev_wait_gate_recent') is not null
                  then public.dev_wait_gate_recent(8)
                  else jsonb_build_object('has', false) end,
    'config', cfg);
end $fn$;

grant execute on function public.deploy_lane_status(integer) to anon, authenticated, service_role;

commit;
