-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #686 — ROUND 3. Hostile QA round 2 found two blockers and two majors.
-- One of the blockers was mine to begin with: the RPC round 2 added to guard
-- ui_copy could itself be called by any logged-in account.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. the last Aug-9 casualty, on a customer-facing surface ─────────────
-- cust_pay.qr_image_title held the Dart literal 'UPI ID: $vpa' and is painted
-- onto the UPI QR image a paying customer downloads. Its neighbour is worse
-- than broken: qr_image_upi_line wears the NEXT line's label, so the image
-- printed "Banking Name:" twice and never said which value was the UPI ID.
-- The title is reconstructed (decision logged on the command); the UPI line is
-- not — qr_image_name_line already owns 'Banking Name: {name}'.
update public.ui_copy set value = to_jsonb(v.val)
from (values
  ('cust_pay.qr_image_title',    'Scan to pay'),
  ('cust_pay.qr_image_upi_line', 'UPI ID: {vpa}')
) as v(k, val)
where ui_copy.key = v.k;

-- ── 2. two holes in the widened detector ─────────────────────────────────
-- (a) A BARE $identifier. Round 2 looked for '${' and missed '$vpa' — which is
--     exactly how the row above survived a guard written to catch it.
--     '$5' and 'US$ 20' stay legal: the rule needs a letter or underscore.
-- (b) '\.length\b' never matched anything. In POSIX ARE \b is BACKSPACE, not a
--     word boundary — Postgres spells that \y. Proof: 'items.length' ~
--     '\.length\b' is false, '\.length\y' is true.
create or replace function public.ui_copy_is_source_code(p_value text)
returns boolean language sql immutable as $fn$
  select case when coalesce(p_value, '') = '' then false else
       position('${' in p_value) > 0                 -- Dart interpolation
    or p_value ~ '\$[A-Za-z_]'                       -- a bare $identifier
    or p_value ~ '\\u\{'                             -- a literal \u{1F4B5}
    or p_value ~ ('(\.toString\(|\.toStringAsFixed\(|\.isNotEmpty|\.isEmpty'
         || '|\.length\y|\.map\(|\.where\(|\.join\(|\.split\(|\.trim\('
         || '|\.substring\(|\.toLowerCase\(|\.toUpperCase\(|\.replaceAll\('
         || '|\.replaceFirst\(|\.contains\(|\.startsWith\(|\.endsWith\()')
    or p_value ~ '(!=\s*null|==\s*null|\?\?)'        -- null-aware operators
    or p_value ~ '^\s*[\]\})]'                       -- a fragment's own tail
  end;
$fn$;

-- ── 3. the brace rule, tightened from "strip and inspect" to "consume" ───
-- Round 2 removed every {{…}} first and then looked at the innermost braces,
-- so '{{ b[0] ; return x }}', '{{items.length}}', '{ if (x) {ok} }' and
-- '{a: {b}}' all walked in. Consume only the two shapes that are LEGAL —
-- {slot} and the backend's {{slot}} — and refuse anything that leaves a brace
-- behind. There is no ordering to exploit, because nothing else is consumed.
create or replace function public.ui_copy_brace_is_source(p_value text)
returns boolean language sql immutable as $fn$
  select case when coalesce(p_value, '') = '' then false else
    regexp_replace(
      regexp_replace(coalesce(p_value, ''), '\{\{[A-Za-z0-9_]+\}\}', '', 'g'),
      '\{[A-Za-z0-9_]+\}', '', 'g') ~ '[{}]'
  end;
$fn$;

-- ── 4. the RPC round 2 added was reachable by every logged-in account ────
-- It is SECURITY DEFINER and opens with an unqualified DELETE, so the EXECUTE
-- grant 'authenticated' carries straight through the RLS round 2 had just
-- switched on: any signed-in user could wipe the drift table to hide real
-- drift, or plant a row to turn rg_check red and RAISE dev_cmd_complete for
-- every command in the queue. Its siblings (qa_report, journey_report,
-- dev_cmd_complete) are service_role-only; so is this now, in the grants AND
-- in the body, because a grant is one ALTER away from being wrong again.
create or replace function public.ui_copy_param_drift_report(p_report jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare v_n int;
begin
  if current_setting('request.jwt.claim.role', true) is distinct from 'service_role'
     and session_user not in ('postgres', 'supabase_admin', 'service_role')
     and current_user not in ('postgres', 'supabase_admin', 'service_role') then
    raise exception 'ui_copy_param_drift_report: service_role only';
  end if;
  delete from public.ui_copy_param_drift;   -- the scan is always a full picture
  insert into public.ui_copy_param_drift (kind, key, param, file, line, template)
  select f->>'kind', f->>'key', f->>'param', f->>'file',
         coalesce((f->>'line')::int, 0), coalesce(f->>'template', '')
    from jsonb_array_elements(coalesce(p_report->'findings', '[]'::jsonb)) f
  on conflict (kind, key, param) do nothing;
  select count(*) into v_n from public.ui_copy_param_drift;
  return jsonb_build_object('ok', true, 'count', v_n);
end $fn$;
revoke all on function public.ui_copy_param_drift_report(jsonb)
  from public, anon, authenticated;
grant execute on function public.ui_copy_param_drift_report(jsonb) to service_role;

-- ── 5. re-validate against every row, with the stricter rules ────────────
alter table public.ui_copy drop constraint if exists ui_copy_no_dart_source;
alter table public.ui_copy add constraint ui_copy_no_dart_source
  check (not public.ui_copy_is_source_code(value #>> '{}'));

-- ── 6. the last shape QA got through: a bare dotted identifier ───────────
-- 'items.first.name' has no braces, no $, and no call parentheses, so neither
-- rule above sees it — yet it is plainly source. A whole value that is nothing
-- but dotted identifiers is never a sentence: no row in the 6,115 live today
-- matches. It goes on the TRIGGER side rather than the CHECK, because a future
-- legitimate value of this shape (a bare domain, say) can then be admitted as
-- a visible ui_copy_source_exempt row with a reason.
create or replace function public.ui_copy_bare_expression(p_value text)
returns boolean language sql immutable as $fn$
  select coalesce(p_value, '') ~ '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$';
$fn$;

create or replace function public.ui_copy_guard_trg()
returns trigger language plpgsql as $fn$
declare v text := new.value #>> '{}';
begin
  if (public.ui_copy_brace_is_source(v) or public.ui_copy_bare_expression(v))
     and not exists (select 1 from public.ui_copy_source_exempt e where e.key = new.key)
  then
    raise exception
      'C686: ui_copy.% is Dart source, not copy: % — a brace that is not a '
      '{slot}, or a value that is nothing but a dotted identifier. If this row '
      'is never rendered to a human, add it to ui_copy_source_exempt with a reason.',
      new.key, left(v, 120);
  end if;
  return new;
end $fn$;

-- ── 7. the behaviour test learns the two new rules ───────────────────────
update public.rg_behavior_tests set body = $body$
do $x$
declare v_bad text; v_n int;
begin
  select count(*), string_agg(key || ' = ' || left(value #>> '{}', 60), ' | ' order by key)
    into v_n, v_bad
    from public.ui_copy
   where public.ui_copy_is_source_code(value #>> '{}')
      or ((public.ui_copy_brace_is_source(value #>> '{}')
           or public.ui_copy_bare_expression(value #>> '{}'))
          and not exists (select 1 from public.ui_copy_source_exempt e
                           where e.key = ui_copy.key));
  if v_n > 0 then
    raise exception
      'C686: % ui_copy row(s) contain Dart source instead of copy — a user sees this verbatim: %',
      v_n, v_bad;
  end if;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.ui_copy'::regclass
                    and conname = 'ui_copy_no_dart_source') then
    raise exception 'C686: the ui_copy_no_dart_source CHECK constraint has been dropped';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.ui_copy'::regclass
                    and tgname = 'ui_copy_guard_trg' and not tgisinternal) then
    raise exception 'C686: the ui_copy_guard_trg source guard has been dropped';
  end if;

  -- ROUND 3: the guard's own RPC must stay service_role-only. It is SECURITY
  -- DEFINER over a table under RLS, so an EXECUTE grant to authenticated is a
  -- way for any signed-in account to red the guard for the whole queue.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'ui_copy_param_drift_report'
                and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                  or has_function_privilege('anon', p.oid, 'EXECUTE'))) then
    raise exception 'C686: ui_copy_param_drift_report is callable by anon/authenticated';
  end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$body$
where name = 'c686_ui_copy_is_copy';
