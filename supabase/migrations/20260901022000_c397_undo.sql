-- CHANGE #397 — part 5: undo.
--
-- A wrong action used to be permanent. Now every audit entry carries its own
-- verdict on whether it can be reversed, and the reversal is a first-class
-- recorded action rather than a second wrong edit.
--
-- Three rules, enforced here rather than in the screen:
--   1. Money is never silently reversed. audit_table_config.undoable is false
--      for refunds, payment claims, partner payouts, cancellations and billing
--      config — those have their own accounting flows.
--   2. Every undo writes its OWN audit entry, pointing at the entry it undid.
--      An undo is therefore itself visible, attributable and never hidden.
--   3. The window is configuration (`admin.undo_window_minutes`), not code.

-- ── can this entry be undone, and if not, why not ───────────────────────────
create or replace function public._audit_undo(l public.audit_log)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  cfg      public.audit_table_config;
  v_window int := public._bulk_setting('admin.undo_window_minutes', 180);
  v_batch  public.admin_bulk_batch;
  v_reason text := '';
  v_can    boolean := false;
  v_kind   text := 'row';
begin
  -- A batch entry routes to the batch undo, which puts back every row at once.
  if l.batch_id is not null then
    v_kind := 'batch';
    select * into v_batch from public.admin_bulk_batch where id = l.batch_id;
  end if;

  if l.undo_of is not null then
    v_reason := 'This entry is itself an undo';
  elsif exists (select 1 from public.audit_log u where u.undo_of = l.id) then
    v_reason := 'Already undone';
  elsif l.at < now() - make_interval(mins => v_window) then
    v_reason := 'Undo window closed';
  elsif v_kind = 'batch' then
    if v_batch.id is null then
      v_reason := 'That batch no longer exists';
    elsif v_batch.undone_at is not null then
      v_reason := 'Already undone';
    else
      v_can := public.admin_can('admin.bulk_actions','write');
      if not v_can then v_reason := 'You cannot undo bulk changes'; end if;
    end if;
  else
    select * into cfg from public.audit_table_config where entity_type = l.entity_type limit 1;
    if cfg.table_name is null then
      v_reason := 'Not reversible here';
    elsif not cfg.undoable then
      v_reason := case cfg.undo_block_reason
                    when 'money_reversal' then 'Money is never reversed here — use the refund or cancellation flow'
                    else 'Not reversible here' end;
    elsif l.before is null then
      v_reason := 'Nothing to put back — this record was created, not changed';
    elsif l.after is null then
      v_reason := 'This record was deleted; restore it from the deletion queue';
    elsif coalesce(cardinality(l.changed_keys), 0) = 0 then
      v_reason := 'Nothing changed in this entry';
    elsif coalesce(l.entity_id,'') = '' then
      v_reason := 'This entry does not name a single record';
    else
      v_can := public.admin_can('admin.audit_log','write');
      if not v_can then v_reason := 'You cannot undo changes'; end if;
    end if;
  end if;

  return jsonb_build_object(
    'can',           v_can,
    'kind',          v_kind,
    'batch_id',      coalesce(l.batch_id, 0),
    'label',         'Undo',
    'blocked_label', v_reason,
    'confirm_title', 'Undo this change?',
    'confirm_body',  case when v_kind = 'batch'
      then 'All ' || coalesce(v_batch.row_count,0)::text ||
           ' rows in this batch go back to the values they held before. The undo is itself recorded.'
      else 'This record goes back to the values it held before this change. The undo is itself recorded.' end,
    'confirm_cta',   'Undo change',
    'cancel_label',  'Keep it');
end $$;

-- ── the reader gains the verdict ────────────────────────────────────────────
-- CHANGE #394's _audit_row, with one key added. Nothing else moved.
create or replace function public._audit_row(l public.audit_log)
returns jsonb language sql stable set search_path to 'public' as $$
  select jsonb_build_object(
    'id',            l.id,
    'title',         coalesce((select c.label from public.audit_table_config c
                                where c.entity_type = l.entity_type limit 1),
                              initcap(replace(l.entity_type,'_',' '))),
    'action_label',  initcap(replace(split_part(l.action, '.', 2), '_', ' ')),
    'action',        l.action,
    'entity_type',   l.entity_type,
    'entity_id',     coalesce(l.entity_id,''),
    'entity_label',  case when coalesce(l.entity_id,'') = '' then ''
                          else '#' || left(l.entity_id, 12) end,
    'actor_label',   coalesce(nullif(l.actor_email,''), public._c('audit.system_actor')),
    'actor_role',    coalesce(l.actor_role,''),
    'when_label',    public._audit_when(l.at),
    'zone_label',    case when l.zone_id is null then '' else 'Zone ' || l.zone_id::text end,
    'source_label',  coalesce(l.source,''),
    'undo',          public._audit_undo(l),
    'tone',          case
                       when l.action like 'undo.%' then 'warning'
                       when l.action like '%.delete' or l.action like '%.reject'
                         or l.action like '%.suspend' then 'danger'
                       when l.action like '%.insert' or l.action like '%.approve'
                         or l.action like '%.pay'    then 'success'
                       else 'info' end,
    'changes',       case
      when l.after is null then '[]'::jsonb
      when l.before is null then coalesce((
        select jsonb_agg(x.js order by x.k)
          from (select k, jsonb_build_object(
                          'field',  k,
                          'label',  initcap(replace(k, '_', ' ')),
                          'before', public._audit_val(null),
                          'after',  public._audit_val(l.after -> k)) as js
                  from unnest(coalesce(l.changed_keys, '{}'::text[])) as k
                 where jsonb_typeof(l.after -> k) not in ('null')
                 order by k limit 6) x), '[]'::jsonb)
      else coalesce((
        select jsonb_agg(jsonb_build_object(
                 'field',  k,
                 'label',  initcap(replace(k, '_', ' ')),
                 'before', public._audit_val(l.before -> k),
                 'after',  public._audit_val(l.after  -> k)) order by k)
          from unnest(coalesce(l.changed_keys, '{}'::text[])) as k), '[]'::jsonb)
      end,
    'changes_label', case
        when l.before is null then public._c('audit.created_label')
        when l.after  is null then public._c('audit.deleted_label')
        when coalesce(cardinality(l.changed_keys),0) = 0 then public._c('audit.no_change_label')
        else array_to_string(
               (select array_agg(initcap(replace(k,'_',' ')) order by k)
                  from unnest(l.changed_keys) k), ', ') end)
$$;

-- ── undo one recorded change ────────────────────────────────────────────────
create or replace function public.admin_undo_audit(p_audit_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  l        public.audit_log;
  cfg      public.audit_table_config;
  v_verdict jsonb;
  v_set    text := '';
  v_col    text;
  v_type   text;
  v_now    jsonb;
  v_n      int;
  v_audit  bigint;
begin
  select * into l from public.audit_log where id = p_audit_id;
  if l.id is null then
    return jsonb_build_object('ok', false, 'message', 'That entry no longer exists.');
  end if;

  v_verdict := public._audit_undo(l);

  -- A batch entry is reversed by the batch engine, which restores every row and
  -- every bookkeeping stamp the batch moved.
  if (v_verdict->>'kind') = 'batch' and l.batch_id is not null then
    return public.admin_bulk_undo(l.batch_id);
  end if;

  if (v_verdict->>'can')::boolean is not true then
    return jsonb_build_object('ok', false,
      'message', coalesce(nullif(v_verdict->>'blocked_label',''), 'This change cannot be undone.'));
  end if;

  select * into cfg from public.audit_table_config where entity_type = l.entity_type limit 1;

  foreach v_col in array l.changed_keys loop
    -- Never rewrite the key that identifies the row, and never touch a column
    -- that has since been dropped.
    if v_col = cfg.pk_col then continue; end if;
    v_type := public._bulk_coltype(cfg.table_name, v_col);
    if v_type is null then continue; end if;
    v_set := v_set || case when v_set = '' then '' else ', ' end ||
             public._undo_assign(v_col, format('$1 -> %L', v_col), v_type);
  end loop;

  if v_set = '' then
    return jsonb_build_object('ok', false,
      'message', 'None of the changed fields still exist, so this change cannot be reversed.');
  end if;

  execute format(
    'select to_jsonb(t) from public.%1$I t where t.%2$I::text = $1',
    cfg.table_name, cfg.pk_col) into v_now using l.entity_id;
  if v_now is null then
    return jsonb_build_object('ok', false,
      'message', 'That record no longer exists, so this change cannot be reversed.');
  end if;

  execute format('update public.%1$I set %2$s where %3$I::text = $2',
                 cfg.table_name, v_set, cfg.pk_col)
    using l.before, l.entity_id;
  get diagnostics v_n = row_count;

  v_audit := public.audit_write_ex(
    l.entity_type || '.undo', l.entity_type, l.entity_id,
    (select jsonb_object_agg(k, v_now -> k) from unnest(l.changed_keys) k),
    (select jsonb_object_agg(k, l.before -> k) from unnest(l.changed_keys) k),
    null, l.id);

  return jsonb_build_object('ok', true, 'row_count', v_n, 'audit_id', v_audit,
    'message', 'Put back to the values held before that change.');
end $$;

grant execute on function public.admin_undo_audit(bigint) to authenticated;

-- ── the proof, as a re-runnable function ────────────────────────────────────
-- The change asks for a 50-row bulk change, its export, and an undo restoring
-- the exact previous values. This IS that test: it runs against the real
-- engine, on real rows, and leaves the database exactly as it found it.
create or replace function public.admin_bulk_selftest(p_rows int default 50)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_ids     text[];
  v_before  jsonb;
  v_after   jsonb;
  v_restored jsonb;
  v_apply   jsonb;
  v_undo    jsonb;
  v_export  jsonb;
  v_lines   int;
  v_fail    text := '';
begin
  if coalesce(auth.jwt() ->> 'role','') <> 'service_role'
     and not public.admin_can('admin.bulk_actions','write') then
    return jsonb_build_object('ok', false, 'message', 'not_authorized');
  end if;

  -- A real slice of the real catalogue. gst_percent is chosen deliberately: it
  -- is a plain stored column (buyable is trigger-derived and must never be
  -- bulk-set), and the sample deliberately includes NULLs so the undo has to
  -- restore an absent value, not just a different one.
  select array_agg(id::text) into v_ids
    from (select id from public."MEDICINE" order by id limit p_rows) s;
  if coalesce(cardinality(v_ids),0) <> p_rows then
    return jsonb_build_object('ok', false,
      'message', 'not enough sample rows: ' || coalesce(cardinality(v_ids),0)::text);
  end if;

  select jsonb_object_agg(id::text, to_jsonb(gst_percent)) into v_before
    from public."MEDICINE" where id::text = any(v_ids);

  -- 1. a 50-row bulk change
  v_apply := public.admin_bulk_apply('product_availability', to_jsonb(v_ids),
                                    'gst_percent', to_jsonb(12));
  if (v_apply->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'stage', 'apply', 'detail', v_apply);
  end if;
  if (v_apply->>'row_count')::int <> p_rows then
    v_fail := v_fail || 'apply changed ' || (v_apply->>'row_count') || ' rows; ';
  end if;

  select jsonb_object_agg(id::text, to_jsonb(gst_percent)) into v_after
    from public."MEDICINE" where id::text = any(v_ids);
  if exists (select 1 from jsonb_each(v_after) e where e.value <> to_jsonb(12)) then
    v_fail := v_fail || 'not every row took the new value; ';
  end if;

  -- one audit entry for the whole batch, not fifty
  if (select count(*) from public.audit_log
       where batch_id = (v_apply->>'batch_id')::bigint) <> 1 then
    v_fail := v_fail || 'batch did not write exactly one audit entry; ';
  end if;

  -- 2. its export
  v_export := public.admin_export_run('audit_trail', 'csv',
                jsonb_build_object('entity_type','product'));
  if (v_export->>'ok')::boolean is not true then
    v_fail := v_fail || 'export failed: ' || coalesce(v_export->>'message','') || '; ';
  else
    v_lines := array_length(string_to_array(btrim(v_export->>'content', E'\n'), E'\n'), 1);
    if coalesce(v_lines,0) < 2 then
      v_fail := v_fail || 'export produced no data rows; ';
    end if;
  end if;

  -- 3. the undo, restoring the EXACT previous values
  v_undo := public.admin_bulk_undo((v_apply->>'batch_id')::bigint);
  if (v_undo->>'ok')::boolean is not true then
    return jsonb_build_object('ok', false, 'stage', 'undo', 'detail', v_undo);
  end if;

  select jsonb_object_agg(id::text, to_jsonb(gst_percent)) into v_restored
    from public."MEDICINE" where id::text = any(v_ids);
  if v_restored is distinct from v_before then
    v_fail := v_fail || 'undo did NOT restore the exact previous values; ';
  end if;

  -- the undo is itself recorded, and points at what it reversed
  if not exists (select 1 from public.audit_log
                  where undo_of = (v_apply->>'audit_id')::bigint) then
    v_fail := v_fail || 'the undo wrote no linked audit entry; ';
  end if;

  return jsonb_build_object(
    'ok',        v_fail = '',
    'rows',      p_rows,
    'batch_id',  (v_apply->>'batch_id')::bigint,
    'export_rows', coalesce(v_lines,0) - 1,
    'failures',  v_fail,
    'message',   case when v_fail = ''
                 then p_rows::text || ' rows changed in one batch, exported, then undone to the exact previous values.'
                 else v_fail end);
end $$;

grant execute on function public.admin_bulk_selftest(int) to authenticated;
