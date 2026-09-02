-- ═══════════════════════════════════════════════════════════════════════════
-- CHANGE #686 — ROUND 2. Hostile QA failed round 1 with three blockers; this
-- migration answers all three.
--
-- Round 1 fixed the 15 keys Om's report named and guarded the ONE shape that
-- report contained ("${"). QA's point was that the Aug-9 copy sweep is a
-- CLASS of damage, not fifteen rows: ten more user-visible casualties were
-- still live, and the guard accepted fourteen of sixteen broken shapes it was
-- shown — including Om's own sentence minus a single dollar sign.
--
-- What lands here:
--   1. Every remaining row whose value is Dart residue or a truncated
--      fragment, repaired from its own call site (or, where the key is dead,
--      from its sibling keys — never invented).
--   2. ui_copy_is_source_code() widened to the shapes it was letting through:
--      a literal \u{…} escape, a null-aware operator, a leading fragment
--      bracket, and eight more method calls.
--   3. A SECOND rule the CHECK cannot express: a brace that is neither a
--      {slot} nor the backend's own {{slot}} is source code. It needs an
--      exemption list (the four Gemini prompts legitimately carry JSON), and
--      a CHECK cannot read a table — so it is a TRIGGER over
--      ui_copy_source_exempt, where every exemption is a visible row with a
--      reason instead of a silent hole in a regex.
--   4. ui_copy_param_drift + ui_copy_param_drift_report(): the OTHER half of
--      Om's bug. His header was broken twice over — the value was Dart AND
--      the call site passed {a}/{b} at a {name} template. Nothing could see
--      that second half, because SQL cannot read Dart and a protected test
--      cannot reach the database. scripts/ui_copy_param_check.sh reads both
--      and files what it finds here; the rg behaviour test turns those rows
--      red, and dev_cmd_complete() refuses a red guard.
-- ═══════════════════════════════════════════════════════════════════════════

-- the scratch detector used while sizing this change; never part of the API
drop function if exists public.ui_copy_is_source_code_v2(text);

-- ── 1. the remaining Aug-9 casualties ─────────────────────────────────────
-- Each value is reconstructed from the call site that reads it. Where a key
-- has no call site left, the sibling keys give the answer (staging_subtitle_*
-- next to staging_subtitle_company = 'Company'); nothing here is invented.
update public.ui_copy set value = to_jsonb(v.val)
from (values
  -- "Enter a name for the new column "{column}"}"" — the sweep kept the Dart
  -- string's own closing quote and brace.
  ('admin_add_medicine.err_new_column_name_empty',
   'Enter a name for the new column "{column}"'),
  -- Both of these held the literal word drug_license: the sweep read the NEXT
  -- map key instead of the sentence. The call sites pass {v} = r['gst_no'] and
  -- r['drug_license'], three lines apart in admin_company_screen.dart, next to
  -- 'Reviewed by: {v}' which survived intact and gives the house style.
  ('admin_company.gst_prefix', 'GST: {v}'),
  ('admin_company.dl_prefix',  'DL: {v}'),
  -- '] != null ? ' — a bare ternary tail. No call site reads either key; the
  -- sibling admin_supplier.staging_subtitle_company is simply 'Company'.
  ('admin_supplier.staging_subtitle_medicine', 'Medicine'),
  ('admin_supplier.staging_subtitle_mrp',      'MRP'),
  -- '\u{1F4B5}  Collect Cash' — the Dart escape survived as six literal
  -- characters on the button. Same glyph, actually encoded.
  ('cash_payment.btn_collect_cash', '💵  Collect Cash'),
  -- '} payment recorded ✓' — {kind} was cut off. sup_pay_panel.dart:213 passes
  -- kind = 'Advance' | 'Balance'.
  ('sup_pay.toast_payment_recorded', '{kind} payment recorded ✓'),
  -- ']} → {raw}' — unmapped_companies_screen.dart:97 passes BOTH raw and name;
  -- the toast says which raw name was mapped to which company.
  ('unmapped_companies.toast_mapped', '{raw} → {name}'),
  -- Truncated at the value: profile_screen.dart:935 passes {name}, and without
  -- the slot the sentence ended on "SAVED to ".
  ('profile.viewas_confirm_body',
   'Any changes (cart, orders, profile) will be SAVED to {name}.'),
  -- Truncated mid-clause; read with c() and takes no values.
  ('notifications.allowlist_note',
   'Numbers here always receive these notifications, even when a toggle is off.'),
  -- Truncated mid-clause with no call site left. The dangling "including when"
  -- is dropped rather than completed: the first sentence is the whole rule.
  ('admin_supplier.dlg_pause_ordering_body',
   'While the inquiry runs, YOU cannot place orders.'),
  -- Only a trailing space; the sentence itself survived.
  ('admin_customer.delete_customer_body',
   'This will remove their login access and all registration data.'),
  -- The screen printed this template and then CONCATENATED two more counts in
  -- Dart. All six counts are slots now; the Dart concatenation goes away.
  ('admin_customer.enrich_summary',
   'Enriched {enriched} · {errors} errors · {photos} photos · {hours} with hours · {websites} websites · {emails} emails'),
  -- wa_campaigns_screen.dart:189 passes {name}; the title is the generic
  -- "Cancel this campaign?", so the body is where the campaign gets named.
  ('wa_campaigns.cancel_body',
   '"{name}" will be cancelled. Pending recipients are dropped and will not be sent.')
) as v(k, val)
where ui_copy.key = v.k;

-- admin_supplier_screen_web.dart built "Column ${col.index + 1}" inline. Same
-- key the add-medicine screen already has, so the two screens now say the same
-- thing from the same place.
insert into public.ui_copy (key, value)
values ('admin_supplier.column_fallback', to_jsonb('Column {n}'::text))
on conflict (key) do update set value = excluded.value;

-- ── 2. the CHECK, widened ─────────────────────────────────────────────────
-- Absolute rules only: none of these can appear in a sentence a human wrote.
create or replace function public.ui_copy_is_source_code(p_value text)
returns boolean language sql immutable as $fn$
  select case when coalesce(p_value, '') = '' then false else
       position('${' in p_value) > 0                 -- Dart interpolation
    or p_value ~ '\\u\{'                              -- a literal \u{1F4B5}
    or p_value ~ ('(\.toString\(|\.toStringAsFixed\(|\.isNotEmpty|\.isEmpty'
         || '|\.length\b|\.map\(|\.where\(|\.join\(|\.split\(|\.trim\('
         || '|\.substring\(|\.toLowerCase\(|\.toUpperCase\(|\.replaceAll\('
         || '|\.replaceFirst\(|\.contains\(|\.startsWith\(|\.endsWith\()')
    or p_value ~ '(!=\s*null|==\s*null|\?\?)'        -- null-aware operators
    or p_value ~ '^\s*[\]\})]'                         -- a fragment's own tail
  end;
$fn$;
comment on function public.ui_copy_is_source_code(text) is
  'CHANGE #686 — absolute shapes that are never a sentence. Enforced by the '
  'validated CHECK ui_copy_no_dart_source; no exemptions exist or should.';

-- ── 3. the brace rule, as a trigger (it needs an exemption table) ─────────
create table if not exists public.ui_copy_source_exempt (
  key        text primary key,
  reason     text not null,
  created_at timestamptz not null default now()
);
comment on table public.ui_copy_source_exempt is
  'CHANGE #686 — ui_copy rows that are NOT rendered to a human (model prompts) '
  'and may therefore carry JSON braces. Every hole in the brace guard is a row '
  'here with a reason, never a widened regex.';

insert into public.ui_copy_source_exempt (key, reason) values
  ('paper429.prompt',     'Gemini prompt — carries the JSON result schema, never rendered'),
  ('phstock.ocr_prompt',  'Gemini prompt — carries the JSON result schema, never rendered'),
  ('phvault.prompt_bill', 'Gemini prompt — carries the JSON result schema, never rendered'),
  ('phvault.prompt_shelf','Gemini prompt — carries the JSON result schema, never rendered')
on conflict (key) do nothing;

-- A brace in rendered copy is either a {slot} cf() fills or the backend's own
-- {{slot}}. Anything else — a ternary, a map lookup, an unbalanced fragment —
-- is source. This is the rule that catches Om's sentence minus its dollar sign.
create or replace function public.ui_copy_brace_is_source(p_value text)
returns boolean language plpgsql immutable as $fn$
declare v text := coalesce(p_value, ''); inner_txt text;
begin
  if v = '' then return false; end if;
  v := regexp_replace(v, '\{\{[^{}]*\}\}', '', 'g');   -- backend's own slots
  if (length(v) - length(replace(v, '{', '')))
     <> (length(v) - length(replace(v, '}', ''))) then
    return true;                                       -- unbalanced = fragment
  end if;
  for inner_txt in select (regexp_matches(v, '\{([^{}]*)\}', 'g'))[1] loop
    if inner_txt !~ '^[A-Za-z0-9_]+$' then return true; end if;
  end loop;
  return false;
end $fn$;

create or replace function public.ui_copy_guard_trg()
returns trigger language plpgsql as $fn$
declare v text := new.value #>> '{}';
begin
  if public.ui_copy_brace_is_source(v)
     and not exists (select 1 from public.ui_copy_source_exempt e where e.key = new.key)
  then
    raise exception
      'C686: ui_copy.% carries a brace that is not a {slot}: % — that is Dart '
      'source, not copy. If this row is a model prompt and is never rendered, '
      'add it to ui_copy_source_exempt with a reason.',
      new.key, left(v, 120);
  end if;
  return new;
end $fn$;

drop trigger if exists ui_copy_guard_trg on public.ui_copy;
create trigger ui_copy_guard_trg
  before insert or update on public.ui_copy
  for each row execute function public.ui_copy_guard_trg();

-- ── 4. the half nothing could see: call site vs template ──────────────────
create table if not exists public.ui_copy_param_drift (
  id          bigserial primary key,
  kind        text not null,          -- missing_param | unused_param | unfilled_c
  key         text not null,
  param       text not null,
  file        text not null,
  line        int  not null,
  template    text not null,
  reported_at timestamptz not null default now(),
  unique (kind, key, param)
);
comment on table public.ui_copy_param_drift is
  'CHANGE #686 — where a cf() call site and its ui_copy template disagree. '
  'Filled by scripts/ui_copy_param_check.sh after every deploy; any row here '
  'turns rg behaviour c686_ui_copy_params red.';

create or replace function public.ui_copy_param_drift_report(p_report jsonb)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare v_n int;
begin
  delete from public.ui_copy_param_drift;   -- the scan is always a full picture
  insert into public.ui_copy_param_drift (kind, key, param, file, line, template)
  select f->>'kind', f->>'key', f->>'param', f->>'file',
         coalesce((f->>'line')::int, 0), coalesce(f->>'template', '')
    from jsonb_array_elements(coalesce(p_report->'findings', '[]'::jsonb)) f
  on conflict (kind, key, param) do nothing;
  select count(*) into v_n from public.ui_copy_param_drift;
  return jsonb_build_object('ok', true, 'count', v_n);
end $fn$;
revoke all on function public.ui_copy_param_drift_report(jsonb) from public, anon;

-- ── 5. the guards' own guards ─────────────────────────────────────────────
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c686_ui_copy_params', $body$
do $x$
declare v_n int; v_bad text;
begin
  select count(*), string_agg(kind || ' ' || key || ' {' || param || '} @ '
                              || file || ':' || line, ' | ' order by key)
    into v_n, v_bad
    from public.ui_copy_param_drift;
  if v_n > 0 then
    raise exception
      'C686: % cf() call site(s) disagree with their ui_copy template — a '
      'value is being dropped or a slot printed raw: %', v_n, v_bad;
  end if;
  raise exception 'RG_ROLLBACK';
end $x$;
$body$, true,
'CHANGE #686 — the OTHER half of the reported bug. The value being a sentence '
'is not enough: the call site must pass the slots the sentence asks for. '
'Filled by scripts/ui_copy_param_check.sh on the post-deploy rg pass.')
on conflict (name) do update
  set body = excluded.body, enabled = excluded.enabled, note = excluded.note;

-- Round 1's test kept, extended to the brace rule and the trigger.
insert into public.rg_behavior_tests (name, body, enabled, note) values
('c686_ui_copy_is_copy', $body$
do $x$
declare v_bad text; v_n int;
begin
  select count(*), string_agg(key || ' = ' || left(value #>> '{}', 60), ' | ' order by key)
    into v_n, v_bad
    from public.ui_copy
   where public.ui_copy_is_source_code(value #>> '{}')
      or (public.ui_copy_brace_is_source(value #>> '{}')
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
    raise exception 'C686: the ui_copy_guard_trg brace guard has been dropped';
  end if;

  raise exception 'RG_ROLLBACK';
end $x$;
$body$, true,
'CHANGE #686 — no ui_copy value may be Dart source. The Aug 9 copy sweep left '
'25 rows as raw fragments; one of them was the customer order header Om '
'photographed. Round 2 added the brace rule and the trigger to this test.')
on conflict (name) do update
  set body = excluded.body, enabled = excluded.enabled, note = excluded.note;

-- ── 6. re-validate the CHECK against every existing row ──────────────────
-- The function got stricter, and a CHECK is not re-run on rows already stored.
-- Re-adding it VALIDATED is the only thing that proves the widened rule holds
-- across all of ui_copy; if a row survived section 1, this migration fails.
alter table public.ui_copy drop constraint if exists ui_copy_no_dart_source;
alter table public.ui_copy add constraint ui_copy_no_dart_source
  check (not public.ui_copy_is_source_code(value #>> '{}'));
