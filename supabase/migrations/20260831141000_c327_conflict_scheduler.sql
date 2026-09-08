-- CHANGE #327 · LAYER 2 — the collision is decided in SQL, before a worker
-- boots and before a single token is spent.
--
-- What went wrong: #325 CLAIMED, loaded its whole context, planned its files,
-- and only THEN discovered that #326 was holding lib/screens/home_shell.dart.
-- It then sat parked, holding a loaded context, waiting for a file. The lease
-- was doing its job (two writers must not share a file) — the mistake was
-- asking the question at the latest possible moment instead of the earliest.
--
-- So: every command gets a PREDICTED file set at ADD time. Two queued commands
-- whose predictions intersect are auto-chained through depends_on, which
-- dev_cmd_claim already honours — the second one simply stays pending. It never
-- claims, never loads a context, never parks. Non-overlapping work is untouched
-- and keeps full parallelism.

alter table dev_commands add column if not exists predicted_files text[];
alter table dev_commands add column if not exists chain_reason    text;
create index if not exists dev_commands_predicted_idx on dev_commands using gin (predicted_files);

-- ── The prediction rules ────────────────────────────────────────────────────
-- Backend data, not Dart and not hard-coded SQL: a new hot spot is one INSERT.
-- `paths` may hold exact repo paths or LIKE globs ('lib/screens/admin/dev_queue/%').
create table if not exists file_predict_rule (
  id       bigserial primary key,
  label    text    not null,
  pattern  text,                       -- regex matched against lower(title||' '||spec)
  area     text,                       -- or/and the router's area
  paths    text[]  not null,
  active   boolean not null default true,
  note     text,
  hits     bigint  not null default 0,
  created_at timestamptz not null default now()
);
create unique index if not exists file_predict_rule_label_key on file_predict_rule (label);
alter table file_predict_rule enable row level security;
drop policy if exists file_predict_rule_no_public on file_predict_rule;
create policy file_predict_rule_no_public on file_predict_rule for select using (false);

insert into file_predict_rule (label, pattern, area, paths, note) values
  ('App shell / boot / routing', '(home_?shell|app shell|boot|routing|route |lands on|redirect)', null,
   array['lib/screens/shell/%','lib/screens/home_shell.dart','lib/main.dart'],
   'The #1 contended path in the fleet. Sharded by LAYER 1 into lib/screens/shell/.'),
  ('Admin nav / dashboard / registry', '(admin nav|dashboard|feature_registry|nav registry|command palette|entry point)', null,
   array['lib/screens/admin/admin_dashboard_screen.dart','lib/screens/admin/admin_nav_entries.dart','lib/screens/admin/nav_registry_view.dart','lib/screens/admin/command_palette.dart'],
   'Contended by #312/#325.'),
  ('Cart', '(cart|checkout|sticky bar|discount bar)', null,
   array['lib/screens/cart_screen.dart','lib/screens/shell/shell_cart.dart','lib/widgets/cust_pay_panel.dart'], null),
  ('Login / auth surface', '(login|sign ?in|otp|password|auth surface)', null,
   array['lib/screens/shell/shell_login.dart','lib/screens/admin/dev_queue/signin_diag_screen.dart'], null),
  ('Storefront', '(storefront|product card|pdp|product detail|search medicines)', 'storefront',
   array['lib/screens/storefront_screen.dart','lib/screens/product_detail_screen.dart','lib/widgets/product_card.dart'], null),
  ('Dev Queue surface', '(dev queue|runner|worker pool|lease|deploy lane|cron health)', 'devops',
   array['lib/screens/admin/dev_queue/%'], null),
  ('Partner surface', '(partner|zone|settlement)', null,
   array['lib/screens/partner/%'], null),
  ('Delivery', '(delivery|rider|run sheet|dispatch)', 'delivery',
   array['lib/screens/delivery/%'], null),
  ('Supplier / inquiry', '(supplier|inquiry|waterfall|spn)', 'supplier',
   array['lib/screens/admin/admin_supplier_screen_web.dart','lib/screens/supplier/%'], null),
  ('Fulfilment / pack / count', '(pack|warehouse|bag|barcode|count)', 'fulfillment',
   array['lib/screens/admin/admin_fulfillment_screen_web.dart','lib/screens/pack/%','lib/screens/count/%'], null),
  ('WhatsApp', '(whatsapp|wa_|template|campaign)', 'whatsapp',
   array['lib/features/whatsapp/%'], null),
  ('Billing', '(bill|invoice|utr|payment|gst)', 'billing',
   array['lib/screens/admin/admin_upi_screen.dart','lib/widgets/cust_pay_panel.dart'], null)
on conflict (label) do update set pattern = excluded.pattern, area = excluded.area, paths = excluded.paths, note = excluded.note, active = true;

-- ── The predictor ───────────────────────────────────────────────────────────
create or replace function public.dev_cmd_predict_files(p_title text, p_spec text, p_area text default null)
returns text[] language plpgsql stable security definer set search_path to 'public' as $$
DECLARE t text; v text[];
BEGIN
  t := lower(coalesce(p_title,'') || ' ' || coalesce(p_spec,''));
  SELECT coalesce(array_agg(DISTINCT p), '{}')
    INTO v
  FROM file_predict_rule r, unnest(r.paths) p
  WHERE r.active
    AND ( (r.pattern IS NOT NULL AND t ~ r.pattern)
       OR (r.area    IS NOT NULL AND r.area = p_area) );
  RETURN v;
END $$;

-- Two path sets overlap when any pair matches exactly OR either side's glob
-- covers the other. 'lib/screens/admin/dev_queue/%' must collide with a real
-- file under it, in both directions.
create or replace function public.dev_paths_overlap(a text[], b text[])
returns boolean language sql immutable set search_path to 'public' as $$
  -- '_' is a LIKE wildcard and every Dart filename is full of them, so a bare
  -- `x LIKE y` would call admin_upi_screen.dart a match for admin_upa_screen.dart.
  -- Only a member that actually carries '%' is treated as a glob, and its
  -- underscores are escaped first.
  SELECT EXISTS (
    SELECT 1 FROM unnest(coalesce(a,'{}')) x, unnest(coalesce(b,'{}')) y
    WHERE x = y
       OR (position('%' in y) > 0 AND x LIKE replace(y, '_', '\_'))
       OR (position('%' in x) > 0 AND y LIKE replace(x, '_', '\_'))
  );
$$;

-- ── The auto-chain ──────────────────────────────────────────────────────────
-- A pending command that would fight an OLDER command for a file gets that
-- command appended to depends_on. dev_cmd_claim already refuses to claim a row
-- whose dependencies are unfinished, so the chain IS the scheduling. Only ever
-- chains to a LOWER id, so the graph can never contain a cycle.
create or replace function public.dev_cmd_autochain(p_id bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE r record; v_blockers bigint[]; v_reason text; v_tpl text; n int := 0; v_out jsonb := '[]'::jsonb;
BEGIN
  SELECT value#>>'{}' INTO v_tpl FROM ui_copy WHERE key='dev_queue.chain_chip';
  v_tpl := coalesce(v_tpl, 'Queued after {ids} — same files');

  FOR r IN
    SELECT c.id, c.predicted_files, c.depends_on
    FROM dev_commands c
    WHERE c.status = 'pending'
      AND (p_id IS NULL OR c.id = p_id)
      AND coalesce(array_length(c.predicted_files,1),0) > 0
    ORDER BY c.id
  LOOP
    SELECT coalesce(array_agg(o.id ORDER BY o.id), '{}') INTO v_blockers
    FROM dev_commands o
    WHERE o.id < r.id
      AND o.status IN ('pending','building','needs_input')
      AND dev_paths_overlap(o.predicted_files, r.predicted_files);

    IF coalesce(array_length(v_blockers,1),0) = 0 THEN
      IF coalesce(r.depends_on,'{}') = '{}' THEN
        UPDATE dev_commands SET chain_reason = NULL WHERE id = r.id AND chain_reason IS NOT NULL;
      END IF;
      CONTINUE;
    END IF;

    v_reason := replace(v_tpl, '{ids}',
      (SELECT string_agg('#'||b::text, ', ') FROM unnest(v_blockers) b));

    UPDATE dev_commands
       SET depends_on = (SELECT coalesce(array_agg(DISTINCT d), '{}')
                         FROM unnest(coalesce(depends_on,'{}') || v_blockers) d),
           chain_reason = v_reason
     WHERE id = r.id;
    n := n + 1;
    v_out := v_out || jsonb_build_object('id', r.id, 'after', to_jsonb(v_blockers), 'reason', v_reason);
  END LOOP;

  RETURN jsonb_build_object('ok', true, 'chained', n, 'rows', v_out);
END $$;

insert into ui_copy (key, value) values
  ('dev_queue.chain_chip', to_jsonb('Queued after {ids} — same files'::text))
on conflict (key) do update set value = excluded.value;

-- Predict on the way in, chain immediately after.
create or replace function public._dev_predict_files_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $$
BEGIN
  IF NEW.predicted_files IS NULL THEN
    NEW.predicted_files := dev_cmd_predict_files(NEW.title, NEW.spec, NEW.area);
  END IF;
  RETURN NEW;
END $$;

create or replace function public._dev_autochain_trg()
returns trigger language plpgsql security definer set search_path to 'public' as $$
BEGIN
  PERFORM dev_cmd_autochain(NEW.id);
  RETURN NULL;
END $$;

drop trigger if exists trg_dev_predict_files on dev_commands;
create trigger trg_dev_predict_files BEFORE INSERT ON dev_commands
  FOR EACH ROW EXECUTE FUNCTION _dev_predict_files_trg();

drop trigger if exists trg_dev_autochain on dev_commands;
create trigger trg_dev_autochain AFTER INSERT ON dev_commands
  FOR EACH ROW WHEN (NEW.status = 'pending') EXECUTE FUNCTION _dev_autochain_trg();

-- ── The claim gets conflict-aware ───────────────────────────────────────────
-- Belt and braces behind the chain: even an UNCHAINED pending row (added
-- before this change, or predicted after the fact) is skipped while its files
-- are actually held or predicted by something in flight. The runner is handed
-- a command it can build start-to-finish, never one it will park on.
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
      -- #327: never hand out a command whose files are already spoken for.
      AND NOT EXISTS (
        SELECT 1 FROM dev_commands b
        WHERE b.status = 'building' AND b.id <> c.id
          AND dev_paths_overlap(b.predicted_files, c.predicted_files))
      AND NOT EXISTS (
        SELECT 1 FROM file_leases fl
        WHERE fl.command_id <> c.id
          AND dev_paths_overlap(array[fl.path], c.predicted_files))
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

-- ── LAYER 3 — split lanes ───────────────────────────────────────────────────
-- lease_try_all stays all-or-nothing and stays the correctness guard. This is
-- the OTHER shape: grant everything that is free, name what is not, and let the
-- runner do the backend + the free files NOW and the contended Dart patch when
-- it frees. A build must never sit idle holding a loaded context because one
-- file is busy.
create or replace function public.lease_try_split(p_command_id bigint, p_worker text, p_paths text[])
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_deferred jsonb; v_free text[]; v_n int;
BEGIN
  PERFORM _dev_guard();
  IF p_paths IS NULL OR array_length(p_paths,1) IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'leased', '[]'::jsonb, 'deferred', '[]'::jsonb);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('file_leases_gate'));

  SELECT coalesce(jsonb_agg(jsonb_build_object('path', fl.path, 'command_id', fl.command_id, 'worker', fl.worker)), '[]')
    INTO v_deferred
  FROM file_leases fl
  WHERE fl.path = ANY(p_paths) AND fl.command_id <> p_command_id;

  SELECT coalesce(array_agg(p), '{}') INTO v_free
  FROM unnest(p_paths) p
  WHERE NOT EXISTS (SELECT 1 FROM file_leases fl WHERE fl.path = p AND fl.command_id <> p_command_id);

  INSERT INTO file_leases (path, command_id, worker)
  SELECT p, p_command_id, p_worker FROM unnest(v_free) p
  ON CONFLICT (path) DO NOTHING;

  INSERT INTO lease_event (kind, path, command_id, worker)
  SELECT 'granted', p, p_command_id, p_worker FROM unnest(v_free) p;

  INSERT INTO lease_event (kind, path, command_id, worker, holder_command_id, holder_worker)
  SELECT 'deferred', d->>'path', p_command_id, p_worker, (d->>'command_id')::bigint, d->>'worker'
  FROM jsonb_array_elements(v_deferred) d;

  v_n := coalesce(array_length(v_free,1),0);
  RETURN jsonb_build_object(
    'ok', true,
    'leased', to_jsonb(v_free),
    'leased_count', v_n,
    'deferred', v_deferred,
    'deferred_count', jsonb_array_length(v_deferred),
    'next_step', CASE WHEN jsonb_array_length(v_deferred) > 0
      THEN 'Build the backend and every granted file NOW. Re-call lease_try_split for the deferred paths when you reach them — do not idle.'
      ELSE 'Everything granted — build straight through.' END);
END $$;

-- "Is it free yet?" — one cheap read, so a runner polls instead of parking.
create or replace function public.lease_free_check(p_command_id bigint, p_paths text[])
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
DECLARE v jsonb;
BEGIN
  PERFORM _dev_guard();
  SELECT coalesce(jsonb_agg(jsonb_build_object('path', fl.path, 'command_id', fl.command_id, 'worker', fl.worker)), '[]')
    INTO v
  FROM file_leases fl WHERE fl.path = ANY(coalesce(p_paths,'{}')) AND fl.command_id <> p_command_id;
  RETURN jsonb_build_object('ok', true, 'free', jsonb_array_length(v) = 0, 'held', v);
END $$;

-- The refinement the spec asks for: whatever the runner ACTUALLY leased is the
-- truth, so it replaces the prediction on the row and re-chains anything queued
-- behind it against the better data.
create or replace function public.dev_cmd_files_learn(p_command_id bigint, p_paths text[])
returns jsonb language plpgsql security definer set search_path to 'public' as $$
BEGIN
  PERFORM _dev_guard();
  UPDATE dev_commands
     SET predicted_files = (SELECT coalesce(array_agg(DISTINCT d), '{}')
                            FROM unnest(coalesce(predicted_files,'{}') || coalesce(p_paths,'{}')) d)
   WHERE id = p_command_id;
  PERFORM dev_cmd_autochain(NULL);
  RETURN jsonb_build_object('ok', true);
END $$;

-- Backfill: every row already in the queue gets a prediction, then the whole
-- pending set is chained once against it.
update dev_commands
   set predicted_files = dev_cmd_predict_files(title, spec, area)
 where predicted_files is null;
select dev_cmd_autochain(null);
-- CHANGE #327 — leasing IS learning.
--
-- The final proof run showed the residual cost of prediction: #325 has a
-- 4,000-char spec that mentions WhatsApp and delivery in passing, so its guess
-- claims lib/features/whatsapp/% and lib/screens/delivery/% and a WhatsApp copy
-- tweak chains behind it. dev_cmd_files_learn already fixes exactly this — but
-- only if the runner remembers to call it, and a rule that depends on runner
-- discipline is a rule that decays.
--
-- So the lease call does it. The moment a worker names the files it will touch,
-- those files REPLACE the guess on the row and everything queued behind it is
-- re-judged. The guess only ever survives until the first real plan.
create or replace function public._lease_learn_internal(p_command_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
DECLARE v text[];
BEGIN
  SELECT array_agg(path) INTO v FROM file_leases WHERE command_id = p_command_id;
  IF coalesce(array_length(v,1),0) = 0 THEN RETURN; END IF;
  UPDATE dev_commands SET predicted_files = v WHERE id = p_command_id;
  PERFORM dev_cmd_autochain(NULL);
END $$;

create or replace function public.lease_try_split(p_command_id bigint, p_worker text, p_paths text[])
returns jsonb language plpgsql security definer set search_path to 'public' as $$
DECLARE v_deferred jsonb; v_free text[]; v_n int;
BEGIN
  PERFORM _dev_guard();
  IF p_paths IS NULL OR array_length(p_paths,1) IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'leased', '[]'::jsonb, 'deferred', '[]'::jsonb);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('file_leases_gate'));

  SELECT coalesce(jsonb_agg(jsonb_build_object('path', fl.path, 'command_id', fl.command_id, 'worker', fl.worker)), '[]')
    INTO v_deferred
  FROM file_leases fl
  WHERE fl.path = ANY(p_paths) AND fl.command_id <> p_command_id;

  SELECT coalesce(array_agg(p), '{}') INTO v_free
  FROM unnest(p_paths) p
  WHERE NOT EXISTS (SELECT 1 FROM file_leases fl WHERE fl.path = p AND fl.command_id <> p_command_id);

  INSERT INTO file_leases (path, command_id, worker)
  SELECT p, p_command_id, p_worker FROM unnest(v_free) p
  ON CONFLICT (path) DO NOTHING;

  INSERT INTO lease_event (kind, path, command_id, worker)
  SELECT 'granted', p, p_command_id, p_worker FROM unnest(v_free) p;

  INSERT INTO lease_event (kind, path, command_id, worker, holder_command_id, holder_worker)
  SELECT 'deferred', d->>'path', p_command_id, p_worker, (d->>'command_id')::bigint, d->>'worker'
  FROM jsonb_array_elements(v_deferred) d;

  PERFORM _lease_learn_internal(p_command_id);

  v_n := coalesce(array_length(v_free,1),0);
  RETURN jsonb_build_object(
    'ok', true,
    'leased', to_jsonb(v_free),
    'leased_count', v_n,
    'deferred', v_deferred,
    'deferred_count', jsonb_array_length(v_deferred),
    'next_step', CASE WHEN jsonb_array_length(v_deferred) > 0
      THEN 'Build the backend and every granted file NOW. Re-call lease_try_split for the deferred paths when you reach them — do not idle.'
      ELSE 'Everything granted — build straight through.' END);
END $$;

create or replace function public.lease_try_all(p_command_id bigint, p_worker text, p_paths text[])
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
DECLARE v_conflicts jsonb; v_owned int;
BEGIN
  PERFORM _dev_guard();
  IF p_paths IS NULL OR array_length(p_paths,1) IS NULL THEN
    RETURN jsonb_build_object('ok', true, 'leased', 0);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('file_leases_gate'));
  SELECT coalesce(jsonb_agg(jsonb_build_object('path', fl.path, 'command_id', fl.command_id, 'worker', fl.worker)), '[]')
    INTO v_conflicts
  FROM file_leases fl
  WHERE fl.path = ANY(p_paths) AND fl.command_id <> p_command_id;
  IF jsonb_array_length(v_conflicts) > 0 THEN
    INSERT INTO lease_event (kind, path, command_id, worker, holder_command_id, holder_worker)
    SELECT 'conflict', c->>'path', p_command_id, p_worker,
           (c->>'command_id')::bigint, c->>'worker'
    FROM jsonb_array_elements(v_conflicts) c;
    RETURN jsonb_build_object('ok', false, 'conflicts', v_conflicts,
      'next_step', 'Do not poll this. Use lease_try_split: take what is free, build it, and come back for the rest with lease_free_check.');
  END IF;
  INSERT INTO file_leases (path, command_id, worker)
  SELECT p, p_command_id, p_worker FROM unnest(p_paths) p
  ON CONFLICT (path) DO NOTHING;
  SELECT count(*) INTO v_owned FROM file_leases WHERE command_id=p_command_id AND path = ANY(p_paths);
  IF v_owned <> array_length(p_paths,1) THEN
    DELETE FROM file_leases WHERE command_id=p_command_id AND path = ANY(p_paths);
    v_conflicts := (SELECT coalesce(jsonb_agg(jsonb_build_object('path',path,'command_id',command_id,'worker',worker)),'[]')
                    FROM file_leases WHERE path=ANY(p_paths) AND command_id<>p_command_id);
    INSERT INTO lease_event (kind, path, command_id, worker, holder_command_id, holder_worker)
    SELECT 'conflict', c->>'path', p_command_id, p_worker,
           (c->>'command_id')::bigint, c->>'worker'
    FROM jsonb_array_elements(v_conflicts) c;
    RETURN jsonb_build_object('ok', false, 'conflicts', v_conflicts);
  END IF;
  INSERT INTO lease_event (kind, path, command_id, worker)
  SELECT 'granted', p, p_command_id, p_worker FROM unnest(p_paths) p;
  PERFORM _lease_learn_internal(p_command_id);
  RETURN jsonb_build_object('ok', true, 'leased', v_owned);
END $function$;
