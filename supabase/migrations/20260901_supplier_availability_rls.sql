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
