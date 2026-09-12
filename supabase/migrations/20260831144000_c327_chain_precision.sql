-- CHANGE #327 — the first run of scripts/build_lane_proof.sh failed honestly,
-- so this is the fix it demanded. Four probes were added; ALL FOUR chained, a
-- WhatsApp copy tweak chained behind a dashboard rebuild, and two of them
-- chained behind #154 "Scheduled: Weekly disk snapshot". A scheduler that
-- prevents every collision by serialising the whole fleet has not fixed
-- anything — it has replaced one queue with a worse one.
--
-- Three distinct causes, all fixed here:
--
-- 1. NO WORD BOUNDARIES. 'count' matched inside "account" and 'bag' inside
--    other words, so a disk-snapshot row predicted the warehouse screens. Every
--    pattern is rebuilt with \m...\M.
--
-- 2. THE WHOLE SPEC WAS THE SUBJECT. #327's own spec names cart, delivery,
--    dashboard and partner while being about none of them, so it predicted
--    half the repo. Prediction now reads the title plus the first
--    `predict_spec_chars` of the spec — what the command is ABOUT, not every
--    word of its rationale.
--
-- 3. A DEAD ROW BLOCKED FOREVER. Chaining is enforced by dev_cmd_claim, which
--    demands every depends_on row be 'completed'. #154 and #289 have sat at
--    needs_input for weeks, so anything chained behind them was starved, not
--    scheduled. Only 'pending' and 'building' rows can block now, auto-added
--    dependencies are tracked separately from Om's own in chain_auto, and a
--    sweep on the cron dispatcher releases them the moment the blocker moves.

alter table dev_commands add column if not exists chain_auto bigint[] default '{}';

update file_predict_rule set pattern = v.pattern from (values
  ('App shell / boot / routing',      '(\mhome_?shell\M|\mapp shell\M|\mboot\M|\mrouting\M|\mroute\M|\mlands on\M|\mredirect\M)'),
  ('Admin nav / dashboard / registry','(\madmin nav\M|\mdashboard\M|\mfeature_registry\M|\mnav registry\M|\mcommand palette\M|\mentry point\M)'),
  ('Cart',                            '(\mcart\M|\mcheckout\M|\msticky bar\M|\mdiscount bar\M)'),
  ('Login / auth surface',            '(\mlogin\M|\msign ?in\M|\motp\M|\mpassword\M|\mauth surface\M)'),
  ('Storefront',                      '(\mstorefront\M|\mproduct card\M|\mpdp\M|\mproduct detail\M|\msearch medicines\M)'),
  ('Dev Queue surface',               '(\mdev queue\M|\mrunner\M|\mworker pool\M|\mlease\M|\mdeploy lane\M|\mcron health\M)'),
  ('Partner surface',                 '(\mpartner\M|\mzone\M|\msettlement\M)'),
  ('Delivery',                        '(\mdelivery\M|\mrider\M|\mrun sheet\M|\mdispatch\M)'),
  ('Supplier / inquiry',              '(\msupplier\M|\minquiry\M|\mwaterfall\M|\mspn\M)'),
  ('Fulfilment / pack / count',       '(\mpack\M|\mwarehouse\M|\mbag\M|\mbarcode\M|\mcount\M)'),
  ('WhatsApp',                        '(\mwhatsapp\M|\mwa_|\mtemplate\M|\mcampaign\M)'),
  ('Billing',                         '(\mbill\M|\minvoice\M|\mutr\M|\mpayment\M|\mgst\M)')
) as v(label, pattern) where file_predict_rule.label = v.label;

-- The subject of the command, not every word of its rationale.
create or replace function public.dev_cmd_predict_files(p_title text, p_spec text, p_area text default null)
returns text[] language plpgsql stable security definer set search_path to 'public' as $$
DECLARE t text; v text[]; v_chars int;
BEGIN
  SELECT coalesce((value->'routing'->>'predict_spec_chars')::int, 600)
    INTO v_chars FROM dev_runner_config WHERE key='worker_pool';
  v_chars := coalesce(v_chars, 600);
  t := lower(coalesce(p_title,'') || ' ' || left(coalesce(p_spec,''), v_chars));
  SELECT coalesce(array_agg(DISTINCT p), '{}')
    INTO v
  FROM file_predict_rule r, unnest(r.paths) p
  WHERE r.active
    AND ( (r.pattern IS NOT NULL AND t ~ r.pattern)
       OR (r.area    IS NOT NULL AND r.area = p_area) );
  RETURN v;
END $$;

-- Only a row that can actually finish may block another one.
create or replace function public.dev_cmd_autochain(p_id bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE r record; v_blockers bigint[]; v_reason text; v_tpl text; n int := 0; v_out jsonb := '[]'::jsonb;
BEGIN
  SELECT value#>>'{}' INTO v_tpl FROM ui_copy WHERE key='dev_queue.chain_chip';
  v_tpl := coalesce(v_tpl, 'Queued after {ids} — same files');

  FOR r IN
    SELECT c.id, c.predicted_files, c.depends_on, coalesce(c.chain_auto,'{}') AS chain_auto
    FROM dev_commands c
    WHERE c.status = 'pending'
      AND (p_id IS NULL OR c.id = p_id)
    ORDER BY c.id
  LOOP
    SELECT coalesce(array_agg(o.id ORDER BY o.id), '{}') INTO v_blockers
    FROM dev_commands o
    WHERE o.id < r.id
      -- needs_input / failed / cancelled can sit for weeks. Blocking on one is
      -- starvation, not scheduling.
      AND o.status IN ('pending','building')
      AND coalesce(array_length(r.predicted_files,1),0) > 0
      AND dev_paths_overlap(o.predicted_files, r.predicted_files);

    -- Whatever this function added last time comes off first, so a chain
    -- RELEASES as soon as its blocker moves. Om's own depends_on is untouched.
    UPDATE dev_commands
       SET depends_on = (SELECT coalesce(array_agg(DISTINCT d), '{}')
                         FROM unnest(coalesce(depends_on,'{}')) d
                         WHERE NOT (d = ANY(r.chain_auto)) OR d = ANY(v_blockers))
     WHERE id = r.id;

    IF coalesce(array_length(v_blockers,1),0) = 0 THEN
      UPDATE dev_commands SET chain_auto = '{}', chain_reason = NULL
       WHERE id = r.id AND (chain_reason IS NOT NULL OR coalesce(chain_auto,'{}') <> '{}');
      CONTINUE;
    END IF;

    v_reason := replace(v_tpl, '{ids}',
      (SELECT string_agg('#'||b::text, ', ' ORDER BY b) FROM unnest(v_blockers) b));

    UPDATE dev_commands
       SET depends_on = (SELECT coalesce(array_agg(DISTINCT d), '{}')
                         FROM unnest(coalesce(depends_on,'{}') || v_blockers) d),
           chain_auto = v_blockers,
           chain_reason = v_reason
     WHERE id = r.id;
    n := n + 1;
    v_out := v_out || jsonb_build_object('id', r.id, 'after', to_jsonb(v_blockers), 'reason', v_reason);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'chained', n, 'rows', v_out);
END $$;

-- A chain must also release when the blocker finishes, not only when something
-- new is added. One sweep on the existing dispatcher, no new cron schedule.
insert into cron_task (name, mode, gate_sql, work_sql, enabled, note, base_interval_s)
select 'autochain_sweep', 'poll',
       -- Only wake when a chain could actually have gone stale: a pending row
       -- whose auto-blocker has left pending/building.
       $g$select exists (
         select 1 from public.dev_commands c
          where c.status = 'pending' and coalesce(c.chain_auto,'{}') <> '{}'
            and exists (select 1 from public.dev_commands b
                         where b.id = any(c.chain_auto) and b.status not in ('pending','building')))$g$,
       'select public.dev_cmd_autochain()', true,
       'CHANGE #327 — releases a file chain the moment its blocker finishes, so a chained command becomes claimable without waiting for the next add.',
       120
where not exists (select 1 from cron_task where name = 'autochain_sweep');

-- Re-predict and re-chain everything with the sharper rules.
update dev_commands set predicted_files = dev_cmd_predict_files(title, spec, area)
 where status in ('pending','building');
select dev_cmd_autochain(null);
-- CHANGE #327 — the refinement, corrected.
--
-- It used to UNION the actuals into the guess, which means a prediction can
-- only ever grow. The proof run showed why that is wrong: #327's own spec names
-- cart, delivery, dashboard and partner while touching none of them, so it
-- chained a WhatsApp copy tweak and a delivery caption behind itself. Once a
-- runner has PLANNED its files, the plan is the truth and it REPLACES the
-- guess — that is the whole point of refining at claim time.
create or replace function public.dev_cmd_files_learn(p_command_id bigint, p_paths text[])
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_before text[]; v_after text[];
BEGIN
  PERFORM _dev_guard();
  SELECT predicted_files INTO v_before FROM dev_commands WHERE id = p_command_id;
  UPDATE dev_commands
     SET predicted_files = (SELECT coalesce(array_agg(DISTINCT d), '{}') FROM unnest(coalesce(p_paths,'{}')) d)
   WHERE id = p_command_id
   RETURNING predicted_files INTO v_after;
  -- Everything queued behind this row is re-judged against the better data, so
  -- a command chained on a phantom overlap is released immediately.
  PERFORM dev_cmd_autochain(NULL);
  RETURN jsonb_build_object('ok', true,
    'was', coalesce(array_length(v_before,1),0),
    'now', coalesce(array_length(v_after,1),0),
    'files', to_jsonb(coalesce(v_after,'{}')));
END $$;
-- CHANGE #327 — the second proof run demanded this one.
--
-- Run 2: a WhatsApp copy tweak and a delivery caption still chained behind
-- #325 "Dashboard becomes the single entry point". #325 is not going anywhere
-- near either surface — but it is a 4,000-char spec that mentions half the
-- product, and a guess made from its text says so.
--
-- The thing is, for a command that is already BUILDING we do not have to
-- guess at all: it holds actual leases, and those are its real footprint. So
-- the footprint of a row is its leases when it has any, and only otherwise the
-- prediction. A running command stops blocking work it was never going to
-- touch, the moment its worker plans its files.
create or replace function public.dev_cmd_footprint(p_id bigint)
returns text[] language sql stable security definer set search_path to 'public' as $$
  select case
           when exists (select 1 from file_leases where command_id = p_id)
             then (select array_agg(path) from file_leases where command_id = p_id)
           else coalesce((select predicted_files from dev_commands where id = p_id), '{}')
         end;
$$;

create or replace function public.dev_cmd_autochain(p_id bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE r record; v_blockers bigint[]; v_reason text; v_tpl text; n int := 0; v_out jsonb := '[]'::jsonb;
BEGIN
  SELECT value#>>'{}' INTO v_tpl FROM ui_copy WHERE key='dev_queue.chain_chip';
  v_tpl := coalesce(v_tpl, 'Queued after {ids} — same files');

  FOR r IN
    SELECT c.id, c.predicted_files, c.depends_on, coalesce(c.chain_auto,'{}') AS chain_auto
    FROM dev_commands c
    WHERE c.status = 'pending'
      AND (p_id IS NULL OR c.id = p_id)
    ORDER BY c.id
  LOOP
    SELECT coalesce(array_agg(o.id ORDER BY o.id), '{}') INTO v_blockers
    FROM dev_commands o
    WHERE o.id < r.id
      AND o.status IN ('pending','building')
      AND coalesce(array_length(r.predicted_files,1),0) > 0
      AND dev_paths_overlap(dev_cmd_footprint(o.id), r.predicted_files);

    UPDATE dev_commands
       SET depends_on = (SELECT coalesce(array_agg(DISTINCT d), '{}')
                         FROM unnest(coalesce(depends_on,'{}')) d
                         WHERE NOT (d = ANY(r.chain_auto)) OR d = ANY(v_blockers))
     WHERE id = r.id;

    IF coalesce(array_length(v_blockers,1),0) = 0 THEN
      UPDATE dev_commands SET chain_auto = '{}', chain_reason = NULL
       WHERE id = r.id AND (chain_reason IS NOT NULL OR coalesce(chain_auto,'{}') <> '{}');
      CONTINUE;
    END IF;

    v_reason := replace(v_tpl, '{ids}',
      (SELECT string_agg('#'||b::text, ', ' ORDER BY b) FROM unnest(v_blockers) b));

    UPDATE dev_commands
       SET depends_on = (SELECT coalesce(array_agg(DISTINCT d), '{}')
                         FROM unnest(coalesce(depends_on,'{}') || v_blockers) d),
           chain_auto = v_blockers,
           chain_reason = v_reason
     WHERE id = r.id;
    n := n + 1;
    v_out := v_out || jsonb_build_object('id', r.id, 'after', to_jsonb(v_blockers), 'reason', v_reason);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'chained', n, 'rows', v_out);
END $$;

-- The claim uses the same footprint, so the belt-and-braces check behind the
-- chain cannot be coarser than the chain itself.
create or replace function public.dev_cmd_claim(p_agent text, p_routes text[] default null, p_prefer_area text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
DECLARE v jsonb; v_res jsonb; v_blocked int;
BEGIN
  PERFORM _dev_guard();
  IF (_sec_cfg()->>'frozen')::boolean THEN RETURN jsonb_build_object('empty',true,'frozen',true); END IF;
  IF (sec_check_budget()->>'over')::boolean THEN RETURN jsonb_build_object('empty',true,'budget_paused',true); END IF;
  UPDATE dev_commands dc SET status='building', claimed_by=p_agent, started_at=now(), heartbeat_at=now(),
         resume_count = resume_count + CASE WHEN dc.steps_done > 0 THEN 1 ELSE 0 END
  WHERE dc.id = (
    SELECT c.id FROM dev_commands c
    WHERE c.status='pending'
      AND (p_routes IS NULL OR c.route = ANY(p_routes))
      AND NOT EXISTS (SELECT 1 FROM dev_commands d WHERE d.id = ANY(c.depends_on) AND d.status <> 'completed')
      AND NOT EXISTS (
        SELECT 1 FROM dev_commands b
        WHERE b.status = 'building' AND b.id <> c.id
          AND dev_paths_overlap(dev_cmd_footprint(b.id), c.predicted_files))
    ORDER BY c.urgent DESC,
             (p_prefer_area IS NOT NULL AND c.area IS NOT DISTINCT FROM p_prefer_area) DESC,
             c.priority, c.id
    FOR UPDATE OF c SKIP LOCKED LIMIT 1
  )
  RETURNING to_jsonb(dc) INTO v;
  IF v IS NULL THEN
    SELECT count(*) INTO v_blocked FROM dev_commands c
     WHERE c.status='pending' AND (p_routes IS NULL OR c.route = ANY(p_routes));
    RETURN jsonb_build_object('empty', true, 'pending_blocked', v_blocked,
      'reason', CASE WHEN v_blocked > 0
        THEN 'Every pending command is chained behind work in flight — nothing to build without a file collision.'
        ELSE 'Queue empty.' END);
  END IF;
  v_res := _dev_resume_block(v);
  RETURN v || jsonb_build_object('resume', v_res,
                                 'is_resume', coalesce((v_res->>'is_resume')::boolean, false));
END $function$;

select dev_cmd_autochain(null);
-- CHANGE #327 — LAYER 1 and LAYER 2 have to agree, or the sharding buys
-- nothing. The App-shell rule predicted the blanket glob 'lib/screens/shell/%',
-- which would have made every shard collide with every other shard: a cart
-- command and a login command would still have chained even though they now
-- touch different files. Each concern points at ITS OWN shard instead, and the
-- shell rule keeps only what is genuinely shared — the shell file and main.dart.
update file_predict_rule set paths = array['lib/screens/home_shell.dart','lib/main.dart']
 where label = 'App shell / boot / routing';
update file_predict_rule set paths = array['lib/screens/cart_screen.dart','lib/screens/shell/shell_cart_panel.dart','lib/widgets/cust_pay_panel.dart']
 where label = 'Cart';
update file_predict_rule set paths = array['lib/screens/shell/shell_login_panel.dart','lib/screens/admin/dev_queue/signin_diag_screen.dart']
 where label = 'Login / auth surface';
update file_predict_rule set paths = paths || array['lib/screens/shell/shell_admin_chrome.dart']
 where label = 'Admin nav / dashboard / registry';
update file_predict_rule set paths = paths || array['lib/screens/shell/shell_sidebar.dart','lib/screens/shell/shell_mobile_chrome.dart']
 where label = 'Storefront';

insert into file_predict_rule (label, pattern, area, paths, note) values
  ('Shell chrome — headers and bars', '(\mheader\M|\mbottom bar\M|\mnav bar\M|\msidebar\M|\mtop nav\M)', null,
   array['lib/screens/shell/shell_header_chrome.dart','lib/screens/shell/shell_bottom_bars.dart','lib/screens/shell/shell_mobile_chrome.dart'],
   'The chrome shards — separate from the shell itself so a header tweak never blocks a routing fix.'),
  ('View-as / impersonation', '(\mview as\M|\mview-as\M|\bimpersonat)', null,
   array['lib/screens/shell/shell_view_as.dart','lib/view_as_state.dart'], null)
on conflict (label) do update set pattern = excluded.pattern, paths = excluded.paths, note = excluded.note, active = true;

update dev_commands set predicted_files = dev_cmd_predict_files(title, spec, area) where status = 'pending';
select dev_cmd_autochain(null);
