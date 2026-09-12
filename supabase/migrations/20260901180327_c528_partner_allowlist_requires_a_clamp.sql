-- CHANGE #528 — feature_gaps row 180, the real scope.
--
-- CHANGE #352 inverted the partner surface to opt-IN: get_my_role() answers
-- 'admin' for a partner ONLY when the rpc being called is on partner_rpc_allow.
-- The list was then SEEDED WHOLESALE (source='seed_closure_c352', 273 rows),
-- handing back exactly what the inversion was built to take away. The proof
-- written this command found dozens of those are SECURITY DEFINER, take an
-- order/supplier/delivery-shaped argument, and carry no zone clamp at all.
--
-- Fixing them one body at a time is how the round-2 half-fix happened. The
-- clamp goes where the AUTHORITY is: an rpc is allowed to a partner only when
-- it is on the list AND its own body carries a clamp (or is an explicitly
-- reasoned exemption). A function written without one is closed on the day it
-- is written and re-opens by itself the moment it is guarded.
alter table public.partner_rpc_allow
  add column if not exists clamp_ok boolean not null default false,
  add column if not exists clamp_checked_at timestamptz;

create or replace function public.partner_rpc_allowed()
returns boolean
language plpgsql stable security definer set search_path to 'public'
as $fn$
declare v_fn text; v_enforce boolean; v_path text;
begin
  v_enforce := coalesce((select (value->>'enforce')::boolean
                           from app_settings where key = 'partner_fence'), true);
  if not v_enforce then return true; end if;
  v_path := nullif(current_setting('request.path', true), '');
  v_fn   := public.current_rpc_name();
  -- Not an rpc call at all (a direct table read, a trigger, cron, psql).
  -- Table access is RLS's job and is already zone-clamped.
  if v_fn is null then return v_path is not null; end if;
  -- CHANGE #528 row 180 — on the list is no longer enough.
  return exists (select 1 from public.partner_rpc_allow a
                  where a.proname = v_fn and a.clamp_ok);
end $fn$;
