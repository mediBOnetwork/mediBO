-- CHANGE #327 · LAYER 0 — the lane can only be fixed once it can be measured.
--
-- file_leases is a LIVE table: a lease row is deleted the moment the command
-- completes, and lease_sweep() deletes the rest. So "how often did builds
-- collide?" had no answer at all — #325 sat parked on #326's home_shell.dart
-- lease and nothing recorded that it happened. lease_event is the permanent
-- history: every grant, every refusal, every deferral, every release. The
-- before/after conflict count this command is judged on reads from here.
create table if not exists lease_event (
  id                 bigserial primary key,
  at                 timestamptz not null default now(),
  kind               text        not null check (kind in ('granted','conflict','deferred','released')),
  path               text        not null,
  command_id         bigint,
  worker             text,
  holder_command_id  bigint,
  holder_worker      text,
  waited_s           numeric
);
create index if not exists lease_event_at_idx      on lease_event (at desc);
create index if not exists lease_event_path_idx    on lease_event (path);
create index if not exists lease_event_kind_at_idx on lease_event (kind, at desc);

-- Ordinary reads/writes: no DB lane lock, tiny rows, append only.
alter table lease_event enable row level security;
drop policy if exists lease_event_no_public on lease_event;
create policy lease_event_no_public on lease_event for select using (false);

-- ── lease_try_all: unchanged contract, now it writes history ────────────────
-- Still all-or-nothing (true same-file writes MUST serialise — that is the
-- last-resort correctness guard this command explicitly KEEPS). The only new
-- behaviour is the audit row, so a refusal is countable afterwards.
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
    RETURN jsonb_build_object('ok', false, 'conflicts', v_conflicts);
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
  RETURN jsonb_build_object('ok', true, 'leased', v_owned);
END $function$;

-- Releases are history too, so "held for how long" is answerable.
create or replace function public._lease_release_internal(p_command_id bigint)
returns integer language plpgsql security definer set search_path to 'public' as $function$
DECLARE n int;
BEGIN
  INSERT INTO lease_event (kind, path, command_id, worker)
  SELECT 'released', fl.path, fl.command_id, fl.worker FROM file_leases fl WHERE fl.command_id = p_command_id;
  DELETE FROM file_leases WHERE command_id = p_command_id;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;

create or replace function public.lease_sweep()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
DECLARE n int;
BEGIN
  INSERT INTO lease_event (kind, path, command_id, worker)
  SELECT 'released', fl.path, fl.command_id, fl.worker FROM file_leases fl
  WHERE NOT EXISTS (SELECT 1 FROM dev_commands c WHERE c.id = fl.command_id AND c.status = 'building');
  DELETE FROM file_leases fl
  WHERE NOT EXISTS (SELECT 1 FROM dev_commands c WHERE c.id = fl.command_id AND c.status = 'building');
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN jsonb_build_object('swept', n);
END $function$;
