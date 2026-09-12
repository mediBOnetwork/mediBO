-- CHANGE #401 hardening: supplier_closure and supplier_coverage shipped without
-- RLS and kept the default anon table grants, so the key in the web bundle could
-- INSERT a closure row and take any supplier out of the waterfall.
-- Both tables are reached ONLY through SECURITY DEFINER RPCs (supplier_availability_get,
-- supplier_close/reopen, supplier_coverage_get/set), which are unaffected by this.

alter table public.supplier_closure  enable row level security;
alter table public.supplier_coverage enable row level security;
alter table public.supplier_closure  force row level security;
alter table public.supplier_coverage force row level security;

revoke all on table public.supplier_closure  from public, anon, authenticated;
revoke all on table public.supplier_coverage from public, anon, authenticated;

grant all on table public.supplier_closure  to service_role;
grant all on table public.supplier_coverage to service_role;

-- supplier_set_packed was recreated with two new args in this change (the 3-arg
-- overload was dropped), and the new signature inherited the default PUBLIC
-- EXECUTE grant. The body already refuses an unauthenticated caller
-- ('not_authorized', verified writing nothing), so this is defence in depth on
-- the layer above: the only callers are the supplier orders screen and admin,
-- both authenticated.
revoke execute on function public.supplier_set_packed(text, boolean, text, timestamptz, integer) from public, anon;
grant  execute on function public.supplier_set_packed(text, boolean, text, timestamptz, integer) to authenticated, service_role;

-- Design QA (live capture): the home tile reused the full-screen empty sentence
-- and truncated mid-word at tile width. supplier_coverage_get() now returns its
-- own short tile_sub, pluralised in SQL like every other count string.
insert into ui_copy(key, value) values
  ('supplier.cov_tile_none', to_jsonb('None declared yet'::text)),
  ('supplier.cov_tile_n',    to_jsonb('{n} declared'::text))
on conflict (key) do update set value = excluded.value;
