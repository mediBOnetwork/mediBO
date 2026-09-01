-- CHANGE #350 — the card must SAY the checklist is untrusted.
--
-- dev_cmd_list is a 7.8 KB function that is edited by every second command, so
-- this patches it by anchor instead of re-pasting the whole body (which is how
-- an unrelated field gets silently reverted). Every anchor is asserted unique
-- before the rewrite and asserted present after it, so a future edit that moves
-- the anchor fails this migration loudly rather than skipping the chip.
do $do$
declare v_src text; v_new text; v_a text; v_b text; v_c text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='dev_cmd_list';
  if v_src is null then raise exception 'dev_cmd_list not found'; end if;

  -- already patched (a re-applied migration must be a silent no-op)
  if position('steps_stale_chip' in v_src) > 0 then return; end if;

  v_a := 't_steps text; t_live text; t_stall text; t_resume text;';
  v_b := 'into t_resume from ui_copy where key=''dev_queue.resume_chip'';';
  v_c := 'else '''' end as stall_chip,';
  if position(v_a in v_src) = 0 or position(v_b in v_src) = 0 or position(v_c in v_src) = 0 then
    raise exception 'c350: dev_cmd_list anchors moved — patch it by hand and fix this migration';
  end if;

  v_new := replace(v_src, v_a, v_a || ' t_ssteps text; t_shint text;');
  v_new := replace(v_new, v_b, v_b || E'\n  select value#>>''{}'' into t_ssteps from ui_copy where key=''dev_queue.steps_stale_chip'';'
                                   || E'\n  select value#>>''{}'' into t_shint  from ui_copy where key=''dev_queue.steps_stale_hint'';');
  v_new := replace(v_new, v_c, v_c || E'\n'
    || E'           -- CHANGE #350 — a checklist that stopped moving while the build\n'
    || E'           -- kept spending is visibly UNTRUSTED, never silently wrong.\n'
    || E'           case when dc.status=''building'' and coalesce(dc.steps_stale_flagged,false)\n'
    || E'                then replace(coalesce(t_ssteps,''Steps not being reported — checklist may be stale ({age})''), ''{age}'',\n'
    || E'                       _fmt_dur(coalesce(extract(epoch from now()-dc.steps_stale_at), 0)))\n'
    || E'                else '''' end as steps_stale_chip,\n'
    || E'           case when dc.status=''building'' and coalesce(dc.steps_stale_flagged,false)\n'
    || E'                then coalesce(t_shint,'''') else '''' end as steps_stale_hint,\n'
    || E'           coalesce(dc.steps_auto_count,0) as steps_auto_count,\n'
    || E'           coalesce(dc.steps_nudge_count,0) as steps_nudge_count,');

  execute v_new;

  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='dev_cmd_list';
  if position('steps_stale_chip' in v_src) = 0 then
    raise exception 'c350: dev_cmd_list rewrite did not take';
  end if;
end $do$;
