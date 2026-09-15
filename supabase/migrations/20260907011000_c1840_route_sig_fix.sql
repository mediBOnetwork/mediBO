-- CMD #1840 (follow-up) — the cost gate now actually holds.
--
-- _c1840_route_sig() carried a comment saying "a stop being COMPLETED does not
-- change the signature (no new call)" while its own body excluded delivered and
-- cancelled stops from the aggregate. So every completion shrank the string,
-- minted a fresh signature, and delivery_google_budget() allowed ANOTHER Google
-- route call — one per stop on a multi-stop run, which is the precise cost the
-- spec forbids. Proven on a synthetic 3-stop run: sig 2d6bd93c… before the
-- stop completed, 48454652… after, calls_for_run 1 -> 2.
--
-- The signature is now the trip's ASSIGNMENT identity: when the run started,
-- and which rider holds which stop since when. A completion touches none of
-- those, so it cannot buy a call. A reassignment changes partner_id and
-- assigned_at, so it buys exactly one — which is what the spec asks for.
--
-- Idempotent: create-or-replace only, no schema change, no data change.

begin;

create or replace function public._c1840_route_sig(p_run_id uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $fn$
  select md5(
    coalesce((select started_at::text from public.delivery_runs where id = p_run_id), '-')
    || '|' ||
    coalesce((select string_agg(d.id::text || ':' || coalesce(d.partner_id::text,'-')
                                || ':' || coalesce(d.assigned_at::text,'-'), ','
                                order by d.id)
                from public.deliveries d
               where d.run_id = p_run_id), '-'));
$fn$;

comment on function public._c1840_route_sig(uuid) is
  'CMD #1840 — the trip identity delivery_google_budget() prices. Every stop of the run counts REGARDLESS of status: completing a stop must not mint a new Google route call, only starting the trip or reassigning a stop may.';

revoke all on function public._c1840_route_sig(uuid) from public, anon;
grant execute on function public._c1840_route_sig(uuid) to authenticated, service_role;

commit;
