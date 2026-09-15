-- CHANGE #290 — fix the fast-lane-writes recipe: ui_copy.value is jsonb.
--
-- The recipe wrote `set value='MUTATED_NOT_OK'`, which is not valid JSON, so the
-- statement raised and mutation_trial recorded verdict='not_applied'. An
-- undecided trial is not a pass, but it is not a challenge either — the journey
-- would have gone unaudited forever while the sweep looked complete.
-- Spliced off the LIVE definition and marker-guarded, so re-applying is a no-op.
do $c290r$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = '_mutation_recipe';
  if v_def is null then raise exception 'c290: _mutation_recipe not found'; end if;
  if position($m$value='"MUTATED_NOT_OK"'::jsonb$m$ in v_def) > 0 then return; end if;

  v_new := replace(v_def,
    $a$update ui_copy set value='MUTATED_NOT_OK' where key='journey.test'$a$,
    $a$update ui_copy set value='"MUTATED_NOT_OK"'::jsonb where key='journey.test'$a$);
  if v_new = v_def then
    raise exception 'c290: fast-lane-writes recipe anchor moved';
  end if;
  execute v_new;
end $c290r$;
