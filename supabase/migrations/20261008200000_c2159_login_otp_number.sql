-- CMD #2159 — login_request_otp answers with the clean 10-digit `number` it
-- actually addressed, so the web box can show exactly what the backend used
-- after an autofill/paste of 08…, +91 …, or 91… (never cleaned in Dart).
-- The original body is kept intact as _login_request_otp_core; the public
-- name is a thin wrapper that adds `number`. Idempotent.
do $$
begin
  if not exists (select 1 from pg_proc where proname = '_login_request_otp_core'
                   and pronamespace = 'public'::regnamespace) then
    alter function public.login_request_otp(text) rename to _login_request_otp_core;
  end if;
end $$;

revoke all on function public._login_request_otp_core(text) from public, anon, authenticated;

create or replace function public.login_request_otp(p_input text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r jsonb; k text;
begin
  r := public._login_request_otp_core(p_input);
  k := public.identity_norm(p_input);
  if k is not null then
    r := r || jsonb_build_object('number', k);
  end if;
  return r;
end
$function$;

grant execute on function public.login_request_otp(text) to anon, authenticated, service_role;
