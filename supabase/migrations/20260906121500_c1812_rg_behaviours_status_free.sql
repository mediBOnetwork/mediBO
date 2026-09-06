-- replay-target: production
-- CMD #1812 — Part C. Two regression-guard behaviours picked their fixture with
-- `status = 'Available'`. That column no longer exists, so on the first replay
-- after Part B they would fail with 42703 and the guard would read red for a
-- reason that has nothing to do with what it guards. Both keep exactly the
-- behaviour they were written to hold; only the fixture predicate changes,
-- because after #1812 there is no unsellable catalogue row to exclude.

UPDATE public.rg_behavior_tests
   SET body = $c1812a$
do $z$
declare v_pid bigint;
begin
  -- FIXTURE (#447): a row whose ONLY possible blocker is the ZONE gate, and
  -- ORDER BY id so the probe is deterministic.
  -- CHANGE #685: bounded candidate window — a missing fixture must be cheap to
  -- discover, because it is the common case now.
  -- CMD #1812: the old predicate also required status = 'Available'. There is
  -- no catalogue status any more — zone standby is the only availability truth
  -- — so the window is buyable rows with an empty zone supplier list.
  select m.id into v_pid
    from (select id, z_rpr_sup
            from "MEDICINE"
           where lower(coalesce(buyable::text,'')) in ('true','t')
           order by id
           limit 5000) m
   where coalesce(array_length(m.z_rpr_sup,1),0) = 0
   order by m.id
   limit 1;
  if v_pid is null then raise exception 'RG_ROLLBACK'; end if;  -- no fixture, treat as pass
  perform set_config('request.jwt.claims','', true);
  if not coalesce((public.product_detail(v_pid)->'availability'->>'is_available')::boolean,false) then
    raise exception 'RG_FAIL: anon must always see available'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub','d3684a1d-a695-40e2-b4f0-46bcdaafc6d7','role','authenticated')::text, true);
  if coalesce((public.product_detail(v_pid)->'availability'->>'is_available')::boolean,true) then
    raise exception 'RG_FAIL: approved viewer must see zone truth (unavailable)'; end if;
  raise exception 'RG_ROLLBACK';
end $z$;
$c1812a$
 WHERE name = 'approved_zone_gate';

UPDATE public.rg_behavior_tests
   SET body = $c1812b$
do $rg$
declare v_pid bigint; v_av jsonb;
begin
  -- a product with NO supplier anywhere. CMD #1812: "sellable" is not a thing
  -- the catalogue says any more, so no status predicate — an anonymous viewer
  -- must see EVERY product as available, which is the whole point of #678.
  select id into v_pid from "MEDICINE"
   where coalesce(supplier_count,0) = 0
   order by id limit 1;
  if v_pid is null then raise exception 'RG_ROLLBACK'; end if;
  perform set_config('request.jwt.claims','', true);
  v_av := public.product_detail(v_pid)->'availability';
  if not coalesce((v_av->>'is_available')::boolean, false) or not coalesce((v_av->>'can_add')::boolean, false) then
    raise exception 'RG_FAIL: anon must see every product as available, got %', v_av;
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$c1812b$
 WHERE name = 'c678_anon_sees_everything_available';
