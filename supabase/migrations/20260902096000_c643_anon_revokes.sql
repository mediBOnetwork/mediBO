-- CHANGE #643 (7/7) — every function this change added is closed to anon.
--
-- Postgres grants EXECUTE to PUBLIC on a new function by default, and the anon
-- key ships inside the web bundle and the APK — so a SECURITY DEFINER function
-- with no explicit revoke is a public endpoint. rg_check's
-- `privileged_rpcs_are_not_anon` caught admin_alert_new_since immediately;
-- these revokes cover every function the change introduced, not just that one.
--
-- realtime_plan() is deliberately left readable by anon: it is the storefront's
-- own answer to "may I open a channel on this table, and how often do I poll if
-- not". It names no rows and carries no data — a signed-out visitor's cart and
-- product pages need it to behave.

revoke execute on function public.admin_alert_new_since(timestamptz, integer) from public, anon;
grant  execute on function public.admin_alert_new_since(timestamptz, integer) to authenticated, service_role;

revoke execute on function public.dev_cmd_get(bigint) from public, anon;
grant  execute on function public.dev_cmd_get(bigint) to authenticated, service_role;

revoke execute on function public.dev_cmd_messages(bigint, integer, bigint) from public, anon;
grant  execute on function public.dev_cmd_messages(bigint, integer, bigint) to authenticated, service_role;

revoke execute on function public.dev_cmd_list(text, text, text, integer, text, timestamptz) from public, anon;
grant  execute on function public.dev_cmd_list(text, text, text, integer, text, timestamptz) to authenticated, service_role;

revoke execute on function public.dev_cmd_list_full(text, text, text, integer) from public, anon;
grant  execute on function public.dev_cmd_list_full(text, text, text, integer) to authenticated, service_role;

revoke execute on function public.dev_runner_tick(text, bigint, boolean) from public, anon;
grant  execute on function public.dev_runner_tick(text, bigint, boolean) to service_role;

revoke execute on function public.login_binding_is_current(text, uuid) from public, anon;
grant  execute on function public.login_binding_is_current(text, uuid) to authenticated, service_role;

revoke execute on function public.realtime_publication_sync() from public, anon, authenticated;
grant  execute on function public.realtime_publication_sync() to service_role;

revoke execute on function public.realtime_suppress_noop_install() from public, anon, authenticated;
grant  execute on function public.realtime_suppress_noop_install() to service_role;

revoke execute on function public._dev_card_keys() from public, anon;
revoke execute on function public._dev_card_strip(jsonb) from public, anon;
