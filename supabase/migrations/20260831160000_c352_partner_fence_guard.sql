-- CHANGE #352 — make the fence permanent.
--
-- The c307 registry guard was written but never wired into anything, so it
-- could go red for a day without stopping a single deploy — which is how rows
-- 136 and 145 stayed open through two QA rounds. This registers the fence as
-- an rg_behavior_tests row, so rg_check() runs it and a red fence blocks every
-- dev_cmd_complete on the box until it is green again.
insert into public.rg_behavior_tests(name, enabled, body) values (
  'partner_fence_enforced', true, $body$
do $rg$
declare a jsonb;
begin
  a := public.c352_partner_fence_audit();
  if coalesce((a->>'enforce')::boolean, false) is not true then
    raise exception 'partner fence switched OFF (app_settings.partner_fence.enforce)';
  end if;
  if coalesce((a->>'scoped_unclamped')::int, 999) <> 0 then
    raise exception 'zone clamp missing on %', a->>'scoped_unclamped_list';
  end if;
  if coalesce((a->>'medibo_only_ok')::boolean, false) is not true then
    raise exception 'a mediBO-only RPC went back to a bare get_my_role()';
  end if;
  if coalesce((a->>'ok')::boolean, false) is not true then
    raise exception 'c352_partner_fence_audit() is red: %', a::text;
  end if;
  raise exception 'RG_ROLLBACK';
end $rg$;
$body$)
on conflict (name) do update set body = excluded.body, enabled = true;
