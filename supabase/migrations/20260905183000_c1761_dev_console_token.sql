-- CHANGE #1761 — production side, part 1 (additive).
-- The dev-queue control plane now lives on its own Supabase project (medibo-dev,
-- ref brorshtqrkyqqdhmhclw). The app's Dev Queue screen reaches it with the anon key
-- plus an HMAC console token minted HERE for a super admin; medibo-dev verifies it
-- with the same vault secret (DEV_CONSOLE_SECRET). No dev URL or key lives in Dart:
-- this RPC hands the screen everything it needs.
--
-- Also: admin_version_panel stops reading deploy_lock/deploy_registry (they move).

create or replace function public.dev_console_token()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_email text; v_secret text; v_url text; v_anon text; v_exp bigint; v_sig text; v_ttl int := 43200;
begin
  if get_my_role() <> 'super_admin' then
    raise exception 'dev_console: super admin only';
  end if;
  select lower(btrim(u.email)) into v_email from auth.users u where u.id = auth.uid();
  if v_email is null then
    raise exception 'dev_console: no email on this session';
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'DEV_CONSOLE_SECRET';
  select decrypted_secret into v_url    from vault.decrypted_secrets where name = 'MEDIBO_DEV_URL';
  select decrypted_secret into v_anon   from vault.decrypted_secrets where name = 'MEDIBO_DEV_ANON_KEY';
  if v_secret is null or v_url is null or v_anon is null then
    raise exception 'dev_console: medibo-dev is not configured in the vault';
  end if;
  v_exp := extract(epoch from now())::bigint + v_ttl;
  v_sig := encode(extensions.hmac(convert_to(v_email || '|' || v_exp, 'utf8'),
                                  convert_to(v_secret, 'utf8'), 'sha256'), 'hex');
  return jsonb_build_object(
    'ok', true,
    'token', 'v1.' || v_exp || '.' || translate(encode(convert_to(v_email, 'utf8'), 'base64'), E'\n', '') || '.' || v_sig,
    'exp', v_exp, 'ttl_s', v_ttl,
    'url', v_url, 'anon_key', v_anon,
    'email', v_email, 'project', 'medibo-dev');
end $$;
revoke execute on function public.dev_console_token() from public, anon;
grant execute on function public.dev_console_token() to authenticated, service_role;

create or replace function public.admin_version_panel()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_live int; v_commit text; v_built timestamptz; v_check timestamptz;
begin
  if get_my_role() not in ('admin', 'super_admin') then
    return jsonb_build_object('error', 'not_authorized');
  end if;
  select change_no, commit, built_at, checked_at into v_live, v_commit, v_built, v_check
    from app_version_state where id = 1;
  return jsonb_build_object(
    'title',         'App version',
    'live_change',   v_live,
    'chip_label',    '#' || coalesce(v_live::text, '—'),
    'chip_sub',      'Live build',
    'commit_label',  'commit ' || coalesce(left(v_commit, 8), '—'),
    'built_label',   case when v_built is null then 'Build time unknown'
                          else 'Built ' || to_char(v_built at time zone 'Asia/Kolkata', 'DD Mon, HH12:MI AM') end,
    'checked_label', case when v_check is null then 'Never checked'
                          else 'Checked ' || to_char(v_check at time zone 'Asia/Kolkata', 'HH12:MI AM') end,
    'lane_busy',     false,
    'lane_label',    'Deploy lane lives on medibo-dev — see Dev Queue → Cron health',
    'lane_tone',     'muted',
    'lane_agent',    null,
    'rows',          '[]'::jsonb,
    'rows_note',     'Recent deploys are listed on the Dev Queue (medibo-dev).');
end $$;
