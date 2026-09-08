-- CMD #1851 — control plane (medibo-dev): a recorded walkthrough arrives as a
-- journey that carries its own replayable body.
--
-- Applied ON medibo-dev with:
--   psql "$(cat ~/.medibo/dev_dburl)" -f supabase/dev/c1851_recording_journeys.sql
-- It is idempotent; re-running it changes nothing.
--
-- The plan is the ordered RPC steps and the payloads they returned. Production
-- keeps the authoritative copy in `recording_journey_plan` (that is what the
-- probe replays); this copy exists so a journey is self-describing and so a
-- fresh build branch can be seeded from the library rather than from a test
-- session that has long since been purged.

alter table public.dev_journeys add column if not exists plan jsonb not null default '[]'::jsonb;

comment on column public.dev_journeys.plan is
  'CMD #1851 — for a recorded walkthrough (name rec-<recording>-<slug>): the '
  'ordered steps and the answers they got, replayed by recording_journey_probe.';

-- journey_save is the door recording_promote posts through. It now carries the
-- plan and the lane, and DEFAULTS required to false for a recorded walkthrough:
-- a journey becomes required only after dev_journeys_record has seen it green
-- twice, so a bad recording can never block the command that comes after it.
create or replace function public.journey_save(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare v_id bigint; v_required boolean; v_recorded boolean;
begin
  perform _dev_guard();
  v_recorded := coalesce(p->>'name','') ~ '^rec-[0-9]+-';
  v_required := coalesce((p->>'required')::boolean, not v_recorded);
  if v_recorded then v_required := false; end if;
  insert into dev_journeys(name, area, kind, steps, assertions, source_bug, required,
                           enabled, plan, probe_on)
  values (p->>'name', p->>'area', coalesce(p->>'kind','api'),
          coalesce(p->'steps','[]'), coalesce(p->'assertions','[]'),
          (p->>'source_bug')::bigint, v_required,
          coalesce((p->>'enabled')::boolean, true),
          coalesce(p->'plan','[]'::jsonb),
          coalesce(nullif(p->>'probe_on',''), 'branch'))
  on conflict (name) do update set
    area = excluded.area, kind = excluded.kind, steps = excluded.steps,
    assertions = excluded.assertions, enabled = excluded.enabled,
    plan = excluded.plan, probe_on = excluded.probe_on,
    -- a journey that has EARNED required keeps it; a save never demotes it and
    -- a recorded one never grants it.
    required = dev_journeys.required or excluded.required
  returning id into v_id;
  perform _audit(_actor(),'journey_save', v_id::text,
                 jsonb_build_object('name', p->>'name', 'recorded', v_recorded,
                                    'required', v_required));
  return jsonb_build_object('ok', true, 'id', v_id, 'required', v_required,
                            'recorded', v_recorded);
end $c1851$;

-- The mirror to production sends the row minus the plan: production already
-- holds the authoritative plan in recording_journey_plan, and a walkthrough's
-- payloads have no business travelling twice.
create or replace function public._dev_journeys_mirror_trg()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $c1851$
declare v_url text; v_key text; v_row jsonb;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'PROD_SUPABASE_URL';
  select decrypted_secret into v_key from vault.decrypted_secrets where name = 'PROD_SERVICE_ROLE_KEY';
  if v_url is null or v_key is null then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    perform net.http_delete(
      url := v_url || '/rest/v1/dev_journeys?id=eq.' || old.id,
      headers := jsonb_build_object('apikey', v_key, 'Authorization', 'Bearer ' || v_key),
      timeout_milliseconds := 8000);
    return old;
  end if;
  v_row := to_jsonb(new) - 'plan';
  perform net.http_post(
    url := v_url || '/rest/v1/dev_journeys?on_conflict=id',
    headers := jsonb_build_object('Content-Type', 'application/json', 'apikey', v_key,
                                  'Authorization', 'Bearer ' || v_key,
                                  'Prefer', 'resolution=merge-duplicates,return=minimal'),
    body := jsonb_build_array(v_row),
    timeout_milliseconds := 8000);
  return new;
exception when others then
  return coalesce(new, old);
end $c1851$;
