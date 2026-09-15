-- CMD #1852 (b) — THE FINGERPRINT BECOMES A PROOF.
--
-- #573's fingerprint hashed the ordered ids of every non-synthetic row. That
-- catches a business row DELETED and a business row INSERTED, and nothing
-- else — the exact failure the WHY of this command names (a denormalised
-- counter bumped on a real pharmacy row, an aggregate cache rewritten) leaves
-- the id list byte-identical and sails through.
--
-- v2 hashes the CONTENT of each row. Same scan, so the same cost: the old
-- statement already read every non-synthetic row of the table to build the
-- id list.
--
-- The version is stamped into the payload. A session started before this
-- migration carries a v1 before_fp; comparing it to a v2 after_fp would
-- report a mismatch that is an artefact of the upgrade, so the diff says
-- `unavailable` for that pair rather than crying wolf.
--
-- Idempotent.

begin;

-- The single-argument form is DROPPED, not left beside the new one. Adding a
-- second defaulted parameter creates an overload, and `test_fingerprint()`
-- then resolves to neither: "function test_fingerprint() is not unique" —
-- which is a session that cannot start, from inside the migration that was
-- meant to make its proof better.
drop function if exists public.test_fingerprint(bigint);

create or replace function public.test_fingerprint(
  p_hash_max bigint default 20000,
  p_tables   text[] default null)
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $fn$
declare t text; v_out jsonb := '{}'::jsonb; v_n bigint; v_h text; v_pk text;
        v_list text[];
begin
  -- The caller may pin the exact table set — an after_fp must be measured over
  -- the SAME tables as the before_fp it will be compared with, whatever the
  -- default list has grown into since.
  v_list := coalesce(p_tables, public._test_session_tables());

  foreach t in array v_list loop
    if t like '\_%' then continue; end if;             -- the metadata keys
    if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
                    where n.nspname = 'public' and c.relname = t and c.relkind = 'r')
      then continue; end if;
    select a.attname into v_pk
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
     where n.nspname = 'public' and c.relname = t
       and a.attname in ('id','session_key','pharmacy_id')
     order by case a.attname when 'id' then 1 when 'session_key' then 2 else 3 end
     limit 1;
    if v_pk is null then continue; end if;

    execute format('select count(*) from public.%I where not coalesce(is_synthetic,false)', t)
      into v_n;

    -- The COUNT is taken on every table. The CONTENT hash is taken only where
    -- it is cheap: hashing whatsapp_messages and notification_log whole, twice
    -- per session, on a 1 GB instance is a self-inflicted outage, not a proof.
    -- Each table says which half it got, so a comparison never pretends to
    -- know more than it measured.
    if v_n <= p_hash_max then
      execute format(
        'select coalesce(md5(string_agg(md5(x::text), '','' order by x.%I::text)),''-'')
           from public.%I x where not coalesce(x.is_synthetic,false)', v_pk, t)
        into v_h;
      v_out := v_out || jsonb_build_object(t, jsonb_build_object('n', v_n, 'h', v_h, 'hashed', true));
    else
      v_out := v_out || jsonb_build_object(t, jsonb_build_object('n', v_n, 'hashed', false));
    end if;
  end loop;

  -- v2 = content-hashed. The version travels WITH the measurement, because a
  -- fingerprint you cannot date is a fingerprint you cannot trust.
  return v_out || jsonb_build_object('_v', 2, '_at', to_jsonb(now()));
end $fn$;

comment on function public.test_fingerprint(bigint, text[]) is
  'CMD #1852 — count + full-row content hash per table, over NON-synthetic '
  'rows only: this is the business data that must not move. Leftover test '
  'rows are measured by test_session_residue(), not here.';

-- ---------------------------------------------------------------------------
-- WHICH TABLE STILL DIFFERS — the sentence the purge is not allowed to skip
-- ---------------------------------------------------------------------------
-- p_touched is the set of tables the SESSION actually wrote to (its journal).
-- A table it never touched that has moved is the platform doing real business
-- while the test ran; a table it DID touch that has moved is the purge being
-- incomplete. Reporting those two as the same thing is how a real failure
-- stops being read.
create or replace function public.test_fingerprint_diff(
  p_before jsonb, p_after jsonb, p_touched text[] default '{}')
 returns jsonb
 language plpgsql stable security definer set search_path to 'public'
as $fn$
declare k text; a jsonb; b jsonb; v_reason text;
        v_diffs jsonb := '[]'::jsonb; v_conc jsonb := '[]'::jsonb;
        v_checked int := 0; v_touched boolean; v_names text;
begin
  if p_before is null or p_after is null then
    return jsonb_build_object('has', false, 'matched', null, 'available', false,
      'line', public.uic('test_session.fp_unavailable',
                'No before/after fingerprint was recorded for this session.'));
  end if;
  if coalesce(p_before->>'_v','1') <> coalesce(p_after->>'_v','1') then
    return jsonb_build_object('has', true, 'matched', null, 'available', false,
      'line', public.uic('test_session.fp_version',
                'This session was measured by an older fingerprint — the two cannot be compared.'));
  end if;

  for k in select jsonb_object_keys(p_before) loop
    continue when k like '\_%';
    a := p_before -> k;
    b := p_after  -> k;
    v_checked := v_checked + 1;
    v_reason := null;
    if b is null then
      v_reason := 'table_gone';
    elsif (a->>'n') is distinct from (b->>'n') then
      v_reason := 'row_count';
    elsif coalesce((a->>'hashed')::boolean,false) and coalesce((b->>'hashed')::boolean,false)
          and (a->>'h') is distinct from (b->>'h') then
      v_reason := 'row_content';
    end if;
    continue when v_reason is null;

    v_touched := k = any(coalesce(p_touched,'{}'));
    if v_touched then
      v_diffs := v_diffs || jsonb_build_object(
        'table', k, 'reason', v_reason,
        'reason_label', public.uic('test_session.fp_reason_'||v_reason, v_reason),
        'before', a, 'after', b);
    else
      v_conc := v_conc || jsonb_build_object(
        'table', k, 'reason', v_reason,
        'reason_label', public.uic('test_session.fp_reason_'||v_reason, v_reason),
        'before', a, 'after', b);
    end if;
  end loop;

  select string_agg(d->>'table', ', ') into v_names from jsonb_array_elements(v_diffs) d;

  return jsonb_build_object(
    'has', true,
    'available', true,
    'checked', v_checked,
    'matched', (jsonb_array_length(v_diffs) = 0),
    'diffs', v_diffs,
    'concurrent', v_conc,
    -- Never a computed sentence in Dart, and never a bare boolean here.
    'line', case
      when jsonb_array_length(v_diffs) > 0 then
        public.uic('test_session.fp_mismatch','Purge incomplete — these tables still differ:') || ' ' || v_names
      when jsonb_array_length(v_conc) > 0 then
        public.uic('test_session.fp_match_busy',
          'Every table this session touched is back exactly as it was. Other tables moved on their own while the test ran.')
      else
        public.uic('test_session.fp_match',
          'Every table is byte-identical to before the session started.') end,
    'tone', case when jsonb_array_length(v_diffs) > 0 then 'danger' else 'success' end);
end $fn$;

revoke all on function public.test_fingerprint(bigint, text[]) from public, anon, authenticated;
grant execute on function public.test_fingerprint(bigint, text[]) to service_role;
revoke all on function public.test_fingerprint_diff(jsonb, jsonb, text[]) from public, anon, authenticated;
grant execute on function public.test_fingerprint_diff(jsonb, jsonb, text[]) to service_role;

insert into public.ui_copy (key, value) values
  ('test_session.fp_unavailable',   to_jsonb('No before/after fingerprint was recorded for this session.'::text)),
  ('test_session.fp_version',       to_jsonb('This session was measured by an older fingerprint — the two cannot be compared.'::text)),
  ('test_session.fp_mismatch',      to_jsonb('Purge incomplete — these tables still differ:'::text)),
  ('test_session.fp_match',         to_jsonb('Every table is byte-identical to before the session started.'::text)),
  ('test_session.fp_match_busy',    to_jsonb('Every table this session touched is back exactly as it was. Other tables moved on their own while the test ran.'::text)),
  ('test_session.fp_reason_row_count',   to_jsonb('row count changed'::text)),
  ('test_session.fp_reason_row_content', to_jsonb('a row was left changed'::text)),
  ('test_session.fp_reason_table_gone',  to_jsonb('the table is no longer there'::text))
on conflict (key) do update set value = excluded.value;

commit;
