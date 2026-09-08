-- CMD #451 — the approved_zone_gate behaviour guard, moved to the contract
-- register rows 84 and 85 approved: anon sees the CATALOGUE truth (never a
-- forced 'available'), and a non-sellable catalogue status blocks everyone.
update rg_behavior_tests set note = 'CMD #451 (register rows 84 + 85): anon sees the CATALOGUE truth (supplier_count), never a forced "available"; a non-sellable status blocks everyone; an approved customer still sees own-zone standby truth.', body = 'do $rg$
declare v_pid bigint; v_blocked bigint; v_av jsonb;
begin
  -- fixture 1: sellable, supplied catalogue-wide, no zone rows for our viewer
  select id into v_pid from "MEDICINE"
   where lower(coalesce(buyable::text,'''')) in (''true'',''t'')
     and coalesce(array_length(z_rpr_sup,1),0)=0
     and public.med_status_sellable(status)
     and coalesce(supplier_count,0) >= 1
   limit 1;
  if v_pid is null then raise exception ''RG_ROLLBACK''; end if;  -- no fixture, treat as pass

  perform set_config(''request.jwt.claims'','''', true);
  v_av := public.product_detail(v_pid)->''availability'';
  -- #451 row 85: signed out we show the catalogue truth. This row HAS a
  -- supplier, so it must read available -- but never because anon is forced.
  if not coalesce((v_av->>''is_available'')::boolean,false) then
    raise exception ''RG_FAIL: anon must see the catalogue truth (supplied row = available)''; end if;

  perform set_config(''request.jwt.claims'', json_build_object(''sub'',''d3684a1d-a695-40e2-b4f0-46bcdaafc6d7'',''role'',''authenticated'')::text, true);
  if coalesce((public.product_detail(v_pid)->''availability''->>''is_available'')::boolean,true) then
    raise exception ''RG_FAIL: approved viewer must see zone truth (unavailable)''; end if;

  -- #451 row 84: a non-sellable catalogue status blocks EVERYONE, signed in or
  -- out, and says so on `blocked_by` rather than on the supplier count.
  select id into v_blocked from "MEDICINE"
   where lower(coalesce(buyable::text,'''')) in (''true'',''t'')
     and not public.med_status_sellable(status)
   limit 1;
  if v_blocked is not null then
    perform set_config(''request.jwt.claims'','''', true);
    v_av := public.product_detail(v_blocked)->''availability'';
    if coalesce((v_av->>''can_add'')::boolean,true) then
      raise exception ''RG_FAIL: a non-sellable status must never be addable''; end if;
    if coalesce(v_av->>''blocked_by'','''') <> ''status'' then
      raise exception ''RG_FAIL: a non-sellable status must block on status, not on supplier count''; end if;
  end if;

  raise exception ''RG_ROLLBACK'';
end $rg$;' where name = 'approved_zone_gate';
