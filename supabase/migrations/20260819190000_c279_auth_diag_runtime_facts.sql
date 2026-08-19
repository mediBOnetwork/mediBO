-- CHANGE #279 — stop guessing which certificate the running build carries.
--
-- #275 recorded ONE sha1, read from signingCertificateHistory, whose first
-- element is the OLDEST certificate of a rotation chain and not the certificate
-- the APK is signed with. The device reported
-- 69:37:2B:88:E2:5F:38:D3:23:C1:46:DE:3D:12:BE:39:22:8C:5B:C5 for 1.3.9(22) and
-- 1.3.10(23) while every published APK verifies as
-- CB:88:BD:C5:2B:90:15:04:CD:58:3D:45:B0:69:7D:1E:58:40:60:55 — one number
-- could not tell "the wrong certificate is registered" from "we read the wrong
-- certificate". So the row widens, and the sentence the user reads carries the
-- facts instead of asserting a theory.
--
-- Idempotent by construction: a resumed worker may re-apply this whole file.

alter table public.auth_diag add column if not exists signing_sha256 text;
alter table public.auth_diag add column if not exists client_id      text;
alter table public.auth_diag add column if not exists install_source text;

-- The SQL-side twin of Dart's c(): read one ui_copy string. A backend function
-- that composes a user-visible sentence reads its wording from ui_copy exactly
-- as the app does, so re-wording stays an UPDATE and never a deploy.
create or replace function public._c(p_key text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce((select value #>> '{}' from public.ui_copy where key = p_key), '');
$function$;

insert into public.ui_copy (key, value) values
  ('auth_diag.fact_sha1',    '"This build''s certificate SHA-1: %s"'::jsonb),
  ('auth_diag.fact_client',  '"Client id sent: %s"'::jsonb),
  ('auth_diag.fact_source',  '"Installed from: %s"'::jsonb),
  ('auth_diag.fact_none',    '"This build did not report a signing certificate."'::jsonb),
  ('auth_diag.source_sideload', '"a downloaded APK (not the Play Store)"'::jsonb)
on conflict (key) do nothing;

update public.auth_diag_copy
   set message = 'Google closed the sign-in sheet before it finished (canceled). '
              || 'If you did not close it yourself, Google refused this build: the '
              || 'certificate below has to be registered as an Android OAuth client '
              || 'for in.medibo.app, in the same project as the client id below.',
       hint    = 'Credential Manager reports a provider-side refusal as a cancellation. '
              || 'Compare the certificate SHA-1 on the row with the fingerprints '
              || 'registered on the Android OAuth clients: a value matching neither '
              || 'means the phone is running a build nobody registered.'
 where code = 'canceled';

create or replace function public.auth_diag_note(
  p_platform       text default 'unknown',
  p_stage          text default 'unknown',
  p_code           text default 'unknown',
  p_description    text default null,
  p_details        text default null,
  p_elapsed_ms     integer default null,
  p_app_version    text default null,
  p_version_code   integer default null,
  p_package_name   text default null,
  p_signing_sha1   text default null,
  p_extra          jsonb default '{}'::jsonb,
  p_signing_sha256 text default null,
  p_client_id      text default null,
  p_install_source text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_copy  public.auth_diag_copy%rowtype;
  v_msg   text;
  v_facts text := '';
  v_src   text;
begin
  insert into public.auth_diag (
    platform, stage, code, description, details, elapsed_ms,
    app_version, version_code, package_name, signing_sha1, extra,
    signing_sha256, client_id, install_source)
  values (
    coalesce(nullif(p_platform,''),'unknown'),
    coalesce(nullif(p_stage,''),'unknown'),
    coalesce(nullif(p_code,''),'unknown'),
    nullif(p_description,''), nullif(p_details,''), p_elapsed_ms,
    nullif(p_app_version,''), p_version_code,
    nullif(p_package_name,''), nullif(p_signing_sha1,''),
    coalesce(p_extra,'{}'::jsonb),
    nullif(p_signing_sha256,''), nullif(p_client_id,''),
    nullif(p_install_source,''));

  -- Android only: on web there is no signing certificate, so nothing is
  -- appended and the web sentence stays byte-for-byte what it was.
  if coalesce(p_platform,'') = 'android' then
    if nullif(p_signing_sha1,'') is null then
      v_facts := E'\n' || public._c('auth_diag.fact_none');
    else
      v_facts := E'\n' || format(public._c('auth_diag.fact_sha1'), p_signing_sha1);
    end if;
    if nullif(p_client_id,'') is not null then
      v_facts := v_facts || E'\n' ||
                 format(public._c('auth_diag.fact_client'), p_client_id);
    end if;
    v_src := nullif(p_install_source,'');
    if v_src is not null then
      v_facts := v_facts || E'\n' || format(
        public._c('auth_diag.fact_source'),
        case when v_src = 'sideload'
             then public._c('auth_diag.source_sideload') else v_src end);
    end if;
  end if;

  select * into v_copy from public.auth_diag_copy where code = p_code;

  if not found then
    -- An unmapped code is still never silent: the code itself is the message.
    return jsonb_build_object(
      'ok', true, 'show', true, 'tone', 'error',
      'message', 'Google sign-in failed on this device. ['
                 || coalesce(nullif(p_code,''),'unknown') || ']' || v_facts);
  end if;

  v_msg := v_copy.message || ' [' || v_copy.code || ']' || v_facts;

  return jsonb_build_object(
    'ok', true,
    'show', v_copy.show,
    'tone', v_copy.tone,
    'message', case when v_copy.show then v_msg else null end);
end;
$function$;

create or replace function public.auth_diag_list(p_limit integer default 50)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_rows jsonb;
  v_total bigint;
begin
  begin
    perform public._dev_guard();
  exception when others then
    return jsonb_build_object(
      'ok', false,
      'title', 'Sign-in diagnostics',
      'error', coalesce((select value #>> '{}' from public.ui_copy
                          where key = 'dev_queue.signin_diag_forbidden'), ''));
  end;

  select count(*) into v_total from public.auth_diag;

  select coalesce(jsonb_agg(r order by ord), '[]'::jsonb) into v_rows
  from (
    select row_number() over (order by d.at desc) as ord,
           jsonb_build_object(
             'when_label', to_char(d.at at time zone 'Asia/Kolkata','DD Mon, HH24:MI:SS') || ' IST',
             'code_label', d.code,
             'tone', coalesce(c.tone,'danger'),
             'stage_label', d.stage,
             'platform_label', d.platform,
             'description', coalesce(nullif(d.description,''),'—'),
             'details', coalesce(nullif(d.details,''),''),
             'hint', coalesce(c.hint,''),
             'build_label', case
                 when d.app_version is null and d.version_code is null then '—'
                 else coalesce(d.app_version,'?') || ' (' || coalesce(d.version_code::text,'?') || ')'
               end,
             'signing_label', coalesce(nullif(d.signing_sha1,''),'—'),
             'package_label', coalesce(nullif(d.package_name,''),'—'),
             'elapsed_label', case when d.elapsed_ms is null then '—'
                                   else d.elapsed_ms::text || ' ms' end,
             -- Each entry is {label, value}, rendered in this order; an absent
             -- fact is simply not in the list, so the screen never prints '—'
             -- for something the device never reported.
             'facts', (
               select coalesce(jsonb_agg(f order by o), '[]'::jsonb)
               from (
                 select 1 o, 'Certificate SHA-256' l, nullif(d.signing_sha256,'') v
                 union all select 2, 'All signers (SHA-1)', nullif(d.extra->>'signers_sha1','')
                 union all select 3, 'Rotation history (SHA-1)', nullif(d.extra->>'history_sha1','')
                 union all select 4, 'Installed from', nullif(d.install_source,'')
                 union all select 5, 'Client id sent', nullif(d.client_id,'')
                 union all select 6, 'Android SDK', d.extra->>'android_sdk'
               ) x, lateral (select jsonb_build_object('label', l, 'value', v) f) y
               where v is not null)
           ) as r
    from public.auth_diag d
    left join public.auth_diag_copy c on c.code = d.code
    order by d.at desc
    limit greatest(1, least(coalesce(p_limit,50), 200))
  ) s;

  return jsonb_build_object(
    'ok', true,
    'title', 'Sign-in diagnostics',
    'subtitle', 'Every Google sign-in failure recorded on a real device, newest first. Times are IST.',
    'empty_label', 'No sign-in failures recorded yet. Tap Continue with Google on the phone, then Refresh.',
    'refresh_label', 'Refresh',
    'count_label', v_total::text || ' recorded',
    'rows', v_rows);
end;
$function$;
