-- CHANGE #354 — feature_gaps row 88 (surface delivery / step "failure reasons", critical)
--
-- delivery_mark_failed(p_delivery_id, p_reason, p_lat, p_lng) was SECURITY DEFINER
-- with EXECUTE granted to anon AND authenticated, and its body contained no
-- auth.uid(), no get_my_role(), no _is_admin() and no partner-ownership test of any
-- kind: it selected the row and immediately set status='failed', bumped attempt_no
-- and wrote a delivery_events row. Anyone holding a delivery uuid could fail
-- anyone's delivery. It is also dead code — no Dart caller exists; delivery_fail()
-- is the real, guarded implementation the proof sheet uses.
--
-- DECISION: not dropped. A DROP FUNCTION is on the runner's escalation list, and
-- the register's own "at minimum" is exactly this: close the grants and add the
-- guard delivery_fail uses. The body now delegates to delivery_fail() so there is
-- ONE failure implementation to keep correct instead of two that can drift.
-- Proof: rg behaviour test `delivery_mark_failed_closed`.
create or replace function public.delivery_mark_failed(p_delivery_id uuid, p_reason text, p_lat numeric DEFAULT NULL::numeric, p_lng numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare d deliveries%rowtype;
begin
  select * into d from deliveries where id = p_delivery_id;
  if d.id is null then return jsonb_build_object('ok',false,'error','not_found'); end if;

  -- CHANGE #354 (row 88): the same ownership test delivery_fail() applies. This
  -- function had NO authorisation at all and was reachable by anon.
  if not exists(select 1 from delivery_partner_registrations
                 where id = d.partner_id and user_id = auth.uid())
     and not public._is_admin() then
    return jsonb_build_object('ok',false,'error','not_authorized');
  end if;

  -- One implementation of "this drop failed". delivery_fail() owns the reason
  -- label, the reattempt date and the event row.
  return public.delivery_fail(p_delivery_id, null, p_reason, p_lat, p_lng);
end $function$;

-- Revoke from PUBLIC as well as the two roles: anon inherits the default PUBLIC
-- grant, so revoking a direct grant it never held is a no-op (learned in #305).
revoke execute on function public.delivery_mark_failed(uuid, text, numeric, numeric) from public;
revoke execute on function public.delivery_mark_failed(uuid, text, numeric, numeric) from anon;
revoke execute on function public.delivery_mark_failed(uuid, text, numeric, numeric) from authenticated;
grant execute on function public.delivery_mark_failed(uuid, text, numeric, numeric) to service_role;
